[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$BrokerPort = 18890,
    [ValidateRange(1024, 65535)][int]$HeadroomPort = 18889
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$python = Join-Path $projectRoot 'runtime\python\Scripts\python.exe'
$moduleRoot = Join-Path $projectRoot 'src'
$stateRoot = Join-Path $projectRoot 'runtime\state\isolated-smoke'
$logRoot = Join-Path $projectRoot 'runtime\logs\isolated-smoke'
$cacheRoot = Join-Path $projectRoot 'runtime\cache'
$startHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom\start-headroom.ps1'
$stopHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom\stop-headroom.ps1'
$brokerUrl = "http://127.0.0.1:$BrokerPort"
$headroomUrl = "http://127.0.0.1:$HeadroomPort"
$brokerProcess = $null
$resultDocument = $null
$runFailure = $null

foreach ($port in @($BrokerPort, $HeadroomPort)) {
    if ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { throw "smoke_port_in_use:$port" }
}
foreach ($directory in @($stateRoot, $logRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

function Wait-JsonReady {
    param([Parameter(Mandatory)][string]$Url,[Parameter(Mandatory)][int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 15
            if ([int]$response.StatusCode -eq 200) { return ($response.Content | ConvertFrom-Json) }
        }
        catch { }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "readiness_timeout:$Url"
}

try {
    $environment = @{
        PYTHONPATH = $moduleRoot
        KOMPRESS_BROKER_STATE_PATH = (Join-Path $stateRoot 'broker.json')
        KOMPRESS_PROVIDER_BACKEND = 'cpu'
        KOMPRESS_WORKER_PYTHON = $python
        KOMPRESS_WORKER_STDERR_PATH = (Join-Path $logRoot 'worker.stderr.log')
        HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
        HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = '12'
        HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
        HEADROOM_ONNX_CPU_ARENA = '1'
        HF_HOME = (Join-Path $cacheRoot 'huggingface')
        TRANSFORMERS_CACHE = (Join-Path $cacheRoot 'huggingface\transformers')
        TRANSFORMERS_OFFLINE = '1'
        HF_HUB_OFFLINE = '1'
    }
    $quotedModuleRoot = '"' + $moduleRoot + '"'
    $brokerProcess = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','kompress_broker.app:app','--app-dir',$quotedModuleRoot,'--host','127.0.0.1','--port',$BrokerPort.ToString(),'--no-access-log') -Environment $environment -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logRoot 'broker.stdout.log') -RedirectStandardError (Join-Path $logRoot 'broker.stderr.log') -PassThru
    $brokerHealth = Wait-JsonReady -Url ($brokerUrl + '/readyz') -TimeoutSeconds 120
    if ($brokerHealth.ready -ne $true -or [string]$brokerHealth.provider -ne 'CPUExecutionProvider') { throw 'broker_canary_contract_failed' }

    # Invoke in-process. A nested native pwsh keeps waiting for EOF when the
    # long-lived Headroom child inherits one of its pipeline handles.
    & $startHeadroom -Port $HeadroomPort -Workers 1 -PythonPath $python -RuntimeStateRoot $stateRoot -RuntimeLogRoot $logRoot -KompressEndpoint $brokerUrl | Out-Null
    $headroomHealth = Wait-JsonReady -Url ($headroomUrl + '/health') -TimeoutSeconds 90
    $kompress = $headroomHealth.checks.kompress
    if ($headroomHealth.ready -ne $true -or $kompress.ready -ne $true -or [string]$kompress.status -eq 'deferred') { throw 'headroom_remote_kompress_not_ready' }

    $content = ('Headroom isolated integration validates broker compression strict readiness failure recovery and exact token accounting. ' * 220)
    $requestJson = @{
        model = 'gpt-5.3-codex'
        messages = @(@{ role = 'user'; content = $content })
        config = @{ target_ratio = 0.5; protect_recent = 0; compress_user_messages = $true }
    } | ConvertTo-Json -Depth 6 -Compress
    $compression = Invoke-RestMethod -Uri ($headroomUrl + '/v1/compress') -Method Post -ContentType 'application/json' -Body $requestJson -NoProxy -TimeoutSec 60
    if (@($compression.messages).Count -ne 1) { throw 'headroom_compression_output_missing' }
    if ([int]$compression.tokens_before -le 0 -or [int]$compression.tokens_after -le 0) { throw 'headroom_token_contract_invalid' }
    if ([int]$compression.tokens_after -ge [int]$compression.tokens_before -or [int]$compression.tokens_saved -le 0) { throw 'headroom_real_compression_missing' }

    $resultDocument = [pscustomobject]@{
        status = 'passed'
        broker_provider = [string]$brokerHealth.provider
        broker_backend = [string]$brokerHealth.backend
        headroom_ready = [bool]$headroomHealth.ready
        kompress_ready = [bool]$kompress.ready
        kompress_status = [string]$kompress.status
        kompress_provider = [string]$kompress.provider
        kompress_backend = [string]$kompress.backend
        tokens_before = [int]$compression.tokens_before
        tokens_after = [int]$compression.tokens_after
        tokens_saved = [int]$compression.tokens_saved
        output_is_messages = $true
    }
}
catch {
    $runFailure = $_
}
finally {
    try { & $stopHeadroom -Port $HeadroomPort -RuntimeStateRoot $stateRoot | Out-Null } catch { }
    $brokerListener = Get-NetTCPConnection -State Listen -LocalPort $BrokerPort -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $brokerListener) {
        $listenerProcessId = [int]$brokerListener.OwningProcess
        $listenerSnapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $listenerProcessId" -ErrorAction SilentlyContinue | Select-Object -First 1
        $listenerCommandLine = if ($null -eq $listenerSnapshot) { '' } else { [string]$listenerSnapshot.CommandLine }
        if ($listenerCommandLine -match '(?i)kompress_broker\.app:app' -and $listenerCommandLine -match ('(?i)--port\s+' + [regex]::Escape($BrokerPort.ToString()))) {
            try { Stop-Process -Id $listenerProcessId -Force -ErrorAction Stop } catch { }
        }
    }
    if ($null -ne $brokerProcess) {
        try { $brokerProcess.Refresh(); if (-not $brokerProcess.HasExited) { Stop-Process -Id $brokerProcess.Id -Force -ErrorAction Stop } } catch { }
    }
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $cleanupDeadline) {
        $remaining = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -In @($BrokerPort, $HeadroomPort))
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
}

foreach ($port in @($BrokerPort, $HeadroomPort)) {
    if ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) { throw "smoke_cleanup_failed:$port" }
}
if ($null -ne $runFailure) { throw $runFailure }
$resultDocument
