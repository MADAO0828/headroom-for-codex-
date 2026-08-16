[CmdletBinding()]
param(
    [string]$OutputPath = 'evidence/p72-kompress-capacity-followup-20260816.json'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-JsonEndpointBody {
    param([Parameter(Mandatory)][string]$Url)
    (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri $Url).Content | ConvertFrom-Json
}

$status = Get-JsonEndpointBody -Url 'http://127.0.0.1:18788/status'
$broker = Get-JsonEndpointBody -Url 'http://127.0.0.1:18790/health'
$hashPaths = @(
    'src/headroom/codexpp-headroom/start-headroom.ps1',
    'src/headroom/codexpp-headroom/ensure-headroom.ps1',
    'src/headroom/codexpp-headroom/headroom-launcher.py',
    'src/headroom/codexpp-headroom/test-headroom-activation.ps1',
    'scripts/Invoke-KompressCapacityBenchmark.py',
    'scripts/Invoke-KompressWorkerPoolBenchmark.py'
)
$sourceHashes = foreach ($relativePath in $hashPaths) {
    $absolutePath = Join-Path $projectRoot $relativePath
    [ordered]@{
        path = $relativePath
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $absolutePath).Hash
    }
}
$legacyProcesses = @(
    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -match '(?i)C:\\Users\\ma dao\\\.headroom|C:\\Users\\ma dao\\\.headroom-venv' } |
        ForEach-Object {
            [ordered]@{
                pid = [int]$_.ProcessId
                parent_pid = [int]$_.ParentProcessId
                name = [string]$_.Name
                path = [string]$_.ExecutablePath
            }
        }
)
$items = @(
    $status.items | ForEach-Object {
        [ordered]@{
            key = [string]$_.key
            state = [string]$_.state
            summary = [string]$_.summary
            issue_code = [string]$_.issue_code
        }
    }
)
$evidence = [ordered]@{
    schema_version = 1
    package_id = 'P72-kompress-capacity-followup-20260816/v1'
    author = 'Codex'
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    production_touched = $false
    production_restart_performed = $false
    config_supplier_auth_session_modified = $false
    runtime = [ordered]@{
        monitor_pid = $status.monitor.pid
        monitor_source_sha256 = $status.monitor.source_sha256
        monitor_status_generated_at = $status.generated_at
        overall = $status.overall
        items = $items
        official_dataplane = $status.official_dataplane.classification
        broker = [ordered]@{
            ready = $broker.ready
            provider = $broker.provider
            backend = $broker.backend
            queue_limit = $broker.queue_limit
            total = $broker.counters.total
            compressed = $broker.counters.compressed
            passthrough = $broker.counters.passthrough
            queue_full = $broker.counters.queue_full
            timeout = $broker.counters.timeout
            worker_restart = $broker.counters.worker_restart
            device_removal = $broker.counters.device_removal
            error = $broker.counters.error
        }
    }
    legacy_c_drive_processes = $legacyProcesses
    isolated_matrix = [ordered]@{
        matrix_file = 'evidence/p72f-kompress-capacity-benchmark-20260816.json'
        requests_per_case = 60
        queue_limits = @(4, 8, 16)
        queue_wait_seconds = @(0.1, 0.3, 0.6)
        result = 'no queue-only candidate: 58-59 queue_full per 60 requests; p95 548-1430ms'
    }
    isolated_concurrency = [ordered]@{
        concurrency1 = '60/60 compressed, queue_full=0, p95=666.826ms'
        concurrency2 = '10/60 compressed, queue_full=50, p95=682.966ms'
        concurrency4 = '4/60 compressed, queue_full=56, p95=659.43ms'
        files = @(
            'evidence/p72f-kompress-concurrency1-20260816.json',
            'evidence/p72f-kompress-concurrency2-20260816.json',
            'evidence/p72f-kompress-concurrency4-20260816.json'
        )
    }
    worker_pool = [ordered]@{
        file = 'evidence/p72f-kompress-worker-pool-2-20260816.json'
        result = '2 isolated broker processes still 2/60 compressed, queue_full=58; not a candidate'
    }
    correction = [ordered]@{
        packet_version = 1
        packet_id = 'P72f-kompress-serialization-v1'
        failure_class = 'implementation_defect'
        observed = 'Headroom default Responses unit parallelism=4 while broker has one serialized worker; same request/correlation shows compressed plus queue_full receipts'
        expected = 'effective startup paths set HEADROOM_TOOL_OUTPUT_COMPRESSION_PARALLELISM=1'
        correction = 'Set serialized Responses unit concurrency in start-headroom.ps1, ensure-headroom.ps1 and headroom-launcher.py; add activation assertion'
        verification = @(
            'py_compile PASS',
            'activation_fixture_tests_ok',
            'broker unittest 12/12',
            'remote Kompress 6/6',
            'Responses compression 10/10',
            'monitor semantics 10 assertions PASS'
        )
        runtime_apply = 'PENDING_USER_OR_REASONIX_RESTART'
        rollback = 'Revert candidate files by recorded SHA-256; no production process was stopped'
    }
    source_hashes = $sourceHashes
    next = @(
        'User/Reasonix restart the Headroom chain so new environment contract is loaded',
        'Re-sample /status and broker queue_full delta',
        'Only if natural traffic remains saturated, design a separately benchmarked multi-session provider pool; do not increase queue/worker parameters blindly'
    )
}
$absoluteOutput = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $projectRoot $OutputPath }
[IO.Directory]::CreateDirectory((Split-Path -Parent $absoluteOutput)) | Out-Null
$json = ($evidence | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
[IO.File]::WriteAllText($absoluteOutput, ($json + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output $absoluteOutput
