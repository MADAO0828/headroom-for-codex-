[CmdletBinding()]
param(
    [int]$InspectorPort = 9329,
    [string]$IngressBaseUrl = 'http://127.0.0.1:18787/v1',
    [int]$WaitSeconds = 30,
    [switch]$Apply,
    [switch]$ResumeIfPaused
)

$ErrorActionPreference = 'Stop'

function Assert-LoopbackIngress {
    param([Parameter(Mandatory)][string]$Value)
    $uri = [Uri]$Value
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.AbsolutePath -ne '/v1' -or $uri.Query -or $uri.UserInfo) {
        throw 'official_route_ingress_must_be_http_loopback_v1'
    }
}

function Get-NodeTarget {
    param([Parameter(Mandatory)][int]$Port)
    $targets = @(Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3)
    $target = $targets | Where-Object { $_.type -eq 'node' -and -not [string]::IsNullOrWhiteSpace($_.webSocketDebuggerUrl) } | Select-Object -First 1
    if ($null -eq $target) { throw 'official_route_node_target_missing' }
    return $target
}

function Wait-NodeTarget {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $Seconds))
    $lastError = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        try { return Get-NodeTarget -Port $Port }
        catch { $lastError = $_.Exception.Message; Start-Sleep -Milliseconds 150 }
    }
    throw "official_route_node_target_timeout:$lastError"
}

function Send-CdpCommand {
    param(
        [Parameter(Mandatory)][Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)]$Params,
        [Parameter(Mandatory)][ref]$NextId
    )
    $id = $NextId.Value
    $NextId.Value++
    $payload = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $buffer = [byte[]]::new(65536)
    do {
        $builder = [Text.StringBuilder]::new()
        do {
            $result = $Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).GetAwaiter().GetResult()
            [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        } while (-not $result.EndOfMessage)
        $message = $builder.ToString() | ConvertFrom-Json
        if ($null -eq $message) { continue }
        $messageIdProperty = $message.PSObject.Properties['id']
        if ($null -eq $messageIdProperty -or $messageIdProperty.Value -ne $id) { continue }
        $errorProperty = $message.PSObject.Properties['error']
        if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
            throw "official_route_cdp_error:$($errorProperty.Value | ConvertTo-Json -Compress)"
        }
        return $message
    } while ($true)
}

Assert-LoopbackIngress -Value $IngressBaseUrl
$target = Wait-NodeTarget -Port $InspectorPort -Seconds $WaitSeconds
$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
$nextId = 1
$routeJson = $IngressBaseUrl | ConvertTo-Json -Compress
if ($Apply) {
    $expression = "(() => { const route = $routeJson; process.env.CODEX_APP_SERVER_CHATGPT_BASE_URL = route; process.env.CODEX_APP_SERVER_OPENAI_BASE_URL = route; return JSON.stringify({ applied: true, pid: process.pid, chatgpt_base_url_applied: process.env.CODEX_APP_SERVER_CHATGPT_BASE_URL === route, openai_base_url_applied: process.env.CODEX_APP_SERVER_OPENAI_BASE_URL === route }); })()"
}
else {
    $expression = 'JSON.stringify({ applied: false, pid: process.pid, chatgpt_base_url_present: !!process.env.CODEX_APP_SERVER_CHATGPT_BASE_URL, openai_base_url_present: !!process.env.CODEX_APP_SERVER_OPENAI_BASE_URL })'
}
$evaluation = Send-CdpCommand -Socket $socket -Method 'Runtime.evaluate' -Params @{ expression = $expression; returnByValue = $true; awaitPromise = $false } -NextId ([ref]$nextId)
$evaluationResultProperty = $evaluation.PSObject.Properties['result']
if ($null -eq $evaluationResultProperty) { throw 'official_route_cdp_result_missing' }
$runtimeResultProperty = $evaluationResultProperty.Value.PSObject.Properties['result']
if ($null -eq $runtimeResultProperty) { throw 'official_route_runtime_result_missing' }
$valueProperty = $runtimeResultProperty.Value.PSObject.Properties['value']
if ($null -eq $valueProperty -or [string]::IsNullOrWhiteSpace([string]$valueProperty.Value)) { throw 'official_route_runtime_value_missing' }
$value = [string]$valueProperty.Value | ConvertFrom-Json
if ($Apply -and $value.applied -ne $true) { throw 'official_route_environment_not_applied' }
$resumed = $false
if ($Apply -and $ResumeIfPaused) {
    [void](Send-CdpCommand -Socket $socket -Method 'Runtime.runIfWaitingForDebugger' -Params @{} -NextId ([ref]$nextId))
    $resumed = $true
}
$receipt = [ordered]@{
    schema = 'official-app-server-route-injection/v1'
    status = if ($Apply) { 'applied' } else { 'dry_run' }
    inspector_port = $InspectorPort
    target_id = [string]$target.id
    target_type = [string]$target.type
    target_pid = [int]$value.pid
    ingress = $IngressBaseUrl
    environment_contract = @('CODEX_APP_SERVER_CHATGPT_BASE_URL','CODEX_APP_SERVER_OPENAI_BASE_URL')
    applied = [bool]$Apply
    resumed = $resumed
    requires_app_server_restart = $true
    config_write = $false
    supplier_write = $false
    vortex_write = $false
    secrets_logged = $false
    session_body_logged = $false
    note = 'Only future app-server spawns inherit this process environment; current codex.exe must be restarted by the user. Default ingress is the legacy production Gateway 18787; Route C managed callers must pass 57321 explicitly.'
}
$socket.Dispose()
$receipt | ConvertTo-Json -Depth 8
