# 手动启动 Route C Python 链（不经 native）：upstream + broker + headroom + gateway
# 然后测 gateway 直连的 SSE 终态
$ErrorActionPreference = 'Continue'
$projectRoot = 'D:\新建文件夹\headroom for codex++'
$python = "$projectRoot\runtime\python\Scripts\python.exe"
$moduleRoot = "$projectRoot\src"
$stateRoot = "$projectRoot\runtime\canary\manual-chain\state"
$logRoot = "$projectRoot\runtime\canary\manual-chain\logs"
New-Item -ItemType Directory -Path $stateRoot, $logRoot -Force | Out-Null

# 端口
$UpstreamPort = 18901
$BrokerPort = 18900
$GatewayPort = 18897
$HeadroomPort = 18899
$EgressPort = 18902

function Wait-Http([string]$Url, [int]$TimeoutSeconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $r = Invoke-WebRequest -Uri $Url -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 3
            if ([int]$r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

# 1. fake upstream
$upEnv = @{ PYTHONPATH = $moduleRoot; ROUTE_C_CANARY_UPSTREAM_STATE = "$stateRoot\fake-upstream.json" }
$up = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','route_c_poc.upstream:app','--app-dir',"`"$moduleRoot`"",'--host','127.0.0.1','--port',$UpstreamPort.ToString(),'--no-access-log') -Environment $upEnv -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput "$logRoot\upstream.out" -RedirectStandardError "$logRoot\upstream.err" -PassThru
Wait-Http "http://127.0.0.1:$UpstreamPort/health" 20 | Out-Null
Write-Output "upstream pid=$($up.Id) ready"

# 2. broker
$brokerEnv = @{ PYTHONPATH = $moduleRoot; KOMPRESS_BROKER_STATE_PATH = "$stateRoot\broker.json"; KOMPRESS_PROVIDER_BACKEND = 'cpu'; KOMPRESS_WORKER_PYTHON = $python; KOMPRESS_WORKER_STDERR_PATH = "$logRoot\worker.err"; HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'; HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = '12'; HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'; HEADROOM_ONNX_CPU_ARENA = '1'; HF_HOME = "$projectRoot\runtime\cache\huggingface"; HF_HUB_CACHE = "$projectRoot\runtime\cache\huggingface\hub"; TRANSFORMERS_CACHE = "$projectRoot\runtime\cache\huggingface\transformers"; TRANSFORMERS_OFFLINE = '1'; HF_HUB_OFFLINE = '1' }
$bk = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','kompress_broker.app:app','--app-dir',"`"$moduleRoot`"",'--host','127.0.0.1','--port',$BrokerPort.ToString(),'--no-access-log') -Environment $brokerEnv -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput "$logRoot\broker.out" -RedirectStandardError "$logRoot\broker.err" -PassThru
Start-Sleep -Seconds 3
# broker warm
try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$BrokerPort/v1/compress" -Method Post -Body '{}' -ContentType 'application/json' -NoProxy -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck } catch { }
Wait-Http "http://127.0.0.1:$BrokerPort/readyz" 60 | Out-Null
Write-Output "broker pid=$($bk.Id) ready"

# 3. headroom
$env:HEADROOM_MODE = 'cache'
$env:HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
$env:HEADROOM_ONNX_CPU_ARENA = '1'
$env:HEADROOM_SKIP_UPSTREAM_CHECK = '1'
$env:HEADROOM_WS_FAIL_OPEN_ON_COMPRESSION_FAILURE = '1'
$env:HEADROOM_KOMPRESS_TIME_BUDGET_SECONDS = '25'
$env:HEADROOM_KOMPRESS_ENDPOINT = "http://127.0.0.1:$BrokerPort"
$env:HEADROOM_WORKERS = '1'
$env:HEADROOM_RUNTIME_ROOT = "$projectRoot\runtime"
$env:HEADROOM_CACHE_DIR = "$projectRoot\runtime\cache\headroom"
$env:HEADROOM_TELEMETRY = 'off'
$env:HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
$env:OPENAI_API_BASE = "http://127.0.0.1:$UpstreamPort/v1"
$env:OPENAI_BASE_URL = "http://127.0.0.1:$UpstreamPort/v1"
$env:HF_HOME = "$projectRoot\runtime\cache\huggingface"
$env:HF_HUB_CACHE = "$projectRoot\runtime\cache\huggingface\hub"
$env:TRANSFORMERS_OFFLINE = '1'
$hr = Start-Process -FilePath $python -ArgumentList @("`"$projectRoot\src\headroom\codexpp-headroom\headroom-launcher.py`"",'proxy','--host','127.0.0.1','--port',$HeadroomPort.ToString(),'--no-http2','--openai-api-url',("http://127.0.0.1:{0}/v1" -f $UpstreamPort),'--no-telemetry','--workers','1') -Environment $env -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput "$logRoot\headroom.out" -RedirectStandardError "$logRoot\headroom.err" -PassThru
Wait-Http "http://127.0.0.1:$HeadroomPort/health" 30 | Out-Null
Write-Output "headroom pid=$($hr.Id) ready"

# 4. gateway（生产方式：app-dir 指向 gateway.py 所在目录）
$gw = Start-Process -FilePath $python -ArgumentList @('-m','uvicorn','gateway:app','--app-dir',"`"$projectRoot\src\headroom\codexpp-headroom`"",'--host','127.0.0.1','--port',$GatewayPort.ToString(),'--no-access-log') -Environment @{ PYTHONPATH = $moduleRoot; HEADROOM_URL = "http://127.0.0.1:$HeadroomPort"; HELPER_URL = "http://127.0.0.1:$EgressPort"; KOMPRESS_ENDPOINT = "http://127.0.0.1:$BrokerPort" } -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput "$logRoot\gateway.out" -RedirectStandardError "$logRoot\gateway.err" -PassThru
Wait-Http "http://127.0.0.1:$GatewayPort/livez" 20 | Out-Null
Write-Output "gateway pid=$($gw.Id) ready"

# 5. 测 gateway SSE（模拟 native ingress 转发）
Write-Output "=== 测试 gateway SSE ==="
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$GatewayPort/v1/responses" -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 30 -ContentType 'application/json' -Headers @{ 'Accept' = 'text/event-stream'; 'x-headroom-synthetic-run-id' = 'manual-chain' } -Body '{"model":"canary-model","input":"manual","stream":true}'
    Write-Output "gateway HTTP $($r.StatusCode) len=$($r.Content.Length) completed=$($r.Content -match 'response.completed')"
    if ($r.Content.Length -gt 0) { Write-Output "content: $($r.Content.Substring(0,[Math]::Min(300),$r.Content.Length))" }
} catch { Write-Output "gateway SSE ERR: $($_.Exception.Message)" }

# 6. upstream state
$upState = "$stateRoot\fake-upstream.json"
if (Test-Path $upState) { Write-Output "upstream state: $(Get-Content $upState -Raw)" }

Write-Output "=== 链路测试完成（进程保持）==="
