# Route C Canary 链路诊断：启动后逐段测试
param([string]$CanaryScript = 'D:\新建文件夹\headroom for codex++\scripts\Start-RouteCCanary.ps1')
$ErrorActionPreference = 'Continue'
$out = 'D:\新建文件夹\headroom for codex++\runtime\canary\route-c\diag-output.txt'
function Log([string]$msg) { Add-Content -Path $out -Value "$(Get-Date -Format 'HH:mm:ss.fff') $msg" -Encoding UTF8 }

Log "=== 启动 Canary（KeepRunning）==="
$proc = Start-Process -FilePath 'pwsh.exe' -ArgumentList "-NoProfile -File `"$CanaryScript`" -KeepRunning" -WindowStyle Hidden -PassThru
Log "canary 脚本 pid=$($proc.Id)"

# 等待端口就绪（最多 120s）
$deadline = [DateTime]::UtcNow.AddSeconds(120)
while ([DateTime]::UtcNow -lt $deadline) {
    $ingress = Get-NetTCPConnection -LocalPort 58321 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    $upstream = Get-NetTCPConnection -LocalPort 18891 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ingress -and $upstream) { break }
    Start-Sleep -Seconds 3
}
Log "ingress=$(if($ingress){$ingress.OwningProcess}else{'none'}) upstream=$(if($upstream){$upstream.OwningProcess}else{'none'})"

# 逐段测试
Start-Sleep -Seconds 5
foreach ($port in 58321, 18887, 18889, 58322, 18891) {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    Log "port $port : $(if($c){'LISTEN pid=' + $c.OwningProcess}else{'free'})"
}

# 1. fake upstream 直连
try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18891/v1/responses' -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 10 -ContentType 'application/json' -Body '{"model":"canary-model","input":"direct","stream":true}'
    Log "upstream direct: HTTP $($r.StatusCode) has_completed=$($r.Content -match 'response.completed')"
} catch { Log "upstream direct ERR: $($_.Exception.Message)" }

# 2. ingress 测试（native Route C 入口）
try {
    $r2 = Invoke-WebRequest -Uri 'http://127.0.0.1:58321/v1/responses' -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 30 -ContentType 'application/json' -Headers @{ 'Accept' = 'text/event-stream'; 'x-headroom-synthetic-run-id' = 'route-c-diag' } -Body '{"model":"canary-model","input":"diag","stream":true}'
    Log "ingress: HTTP $($r2.StatusCode) content_len=$($r2.Content.Length) has_completed=$($r2.Content -match 'response.completed')"
    if ($r2.Content.Length -gt 0) { Log "ingress content: $($r2.Content.Substring(0,[Math]::Min(200),$r2.Content.Length))" }
} catch { Log "ingress ERR: $($_.Exception.Message)" }

# 3. gateway 直连
try {
    $r3 = Invoke-WebRequest -Uri 'http://127.0.0.1:18887/v1/responses' -Method Post -NoProxy -SkipHttpErrorCheck -TimeoutSec 30 -ContentType 'application/json' -Headers @{ 'Accept' = 'text/event-stream'; 'x-headroom-synthetic-run-id' = 'route-c-gw' } -Body '{"model":"canary-model","input":"gw","stream":true}'
    Log "gateway: HTTP $($r3.StatusCode) has_completed=$($r3.Content -match 'response.completed')"
} catch { Log "gateway ERR: $($_.Exception.Message)" }

# 4. fake upstream state
$state = 'D:\新建文件夹\headroom for codex++\runtime\canary\route-c\state\fake-upstream.json'
if (Test-Path $state) { Log "upstream state: $(Get-Content $state -Raw)" } else { Log "upstream state missing: $state" }

Log "=== 诊断完成（KeepRunning 保持）==="
