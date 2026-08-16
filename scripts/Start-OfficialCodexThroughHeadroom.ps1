[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoPause,
    [int]$ReadinessTimeoutSeconds = 30,
    [int]$InspectorPort = 9329,
    [int]$AppCdpPort = 9229,
    [int]$OfficialRouteWaitSeconds = 30,
    [switch]$UseRouteCIngress,
    [string]$CodexCliPath,
    [string]$ChatGptPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $projectRoot 'runtime\official-route'
$stateRoot = Join-Path $projectRoot 'runtime\state'
$shimPath = Join-Path $runtimeRoot 'shim\codex-cli-headroom-shim.exe'
$receiptPath = Join-Path $stateRoot 'official-route-a-start.json'
$settingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json'
$configPath = 'C:\Users\ma dao\.codex-plus-plus-cli\config.toml'
$authPath = 'C:\Users\ma dao\.codex-plus-plus-cli\auth.json'
$gatewayUrl = 'http://127.0.0.1:18787'
$headroomUrl = 'http://127.0.0.1:18789'
$relayPort = 57321
$ingressPort = if ($UseRouteCIngress) { $relayPort } else { 18787 }
$ingressBaseUrl = "http://127.0.0.1:$ingressPort/v1"

Set-StrictMode -Version Latest

function Get-Sha256OrEmpty {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-RouteReceipt {
    param([Parameter(Mandatory)][hashtable]$Document)
    New-Item -ItemType Directory -Path (Split-Path -Parent $receiptPath) -Force | Out-Null
    $Document.updated_at_utc = [DateTime]::UtcNow.ToString('o')
    $targets = [Collections.Generic.List[string]]::new()
    [void]$targets.Add($receiptPath)
    if ($Document.status -eq 'not_proven') {
        $evidenceRoot = Join-Path $projectRoot 'evidence'
        New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
        [void]$targets.Add((Join-Path $evidenceRoot ('route-a-not-proven-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')))
    }
    foreach ($target in $targets) {
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $tmp = Join-Path $parent ('.official-route-a-' + [IO.Path]::GetRandomFileName())
        try {
            [IO.File]::WriteAllText($tmp, (($Document | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($tmp, $target, $true)
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Test-HttpReady {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
        return [pscustomobject]@{ ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500); status = [int]$response.StatusCode }
    }
    catch {
        return [pscustomobject]@{ ok = $false; status = $null }
    }
}

function Assert-InspectorPortAvailable {
    param([Parameter(Mandatory)][int]$Port)
    $listener = Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue
    if ($null -ne $listener) { throw "route_a_inspector_port_in_use_$Port" }
}

function Get-NodeInspectorTarget {
    param([Parameter(Mandatory)][int]$Port)
    $targets = @(Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3)
    $target = $targets |
        Where-Object { [string]$_.type -eq 'node' -and -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl) } |
        Select-Object -First 1
    if ($null -eq $target) { throw 'route_a_node_inspector_target_missing' }
    return $target
}

function Wait-NodeInspectorTarget {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $lastError = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        try { return Get-NodeInspectorTarget -Port $Port }
        catch {
            $lastError = ($_.Exception.Message -replace '[\r\n]+', ' ')
            Start-Sleep -Milliseconds 150
        }
    }
    throw "route_a_node_inspector_timeout:$lastError"
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
    $Socket.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [Threading.CancellationToken]::None
    ).GetAwaiter().GetResult() | Out-Null
    $buffer = [byte[]]::new(65536)
    do {
        $builder = [Text.StringBuilder]::new()
        do {
            $result = $Socket.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'route_a_node_inspector_socket_closed'
            }
            [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        } while (-not $result.EndOfMessage)
        $message = $builder.ToString() | ConvertFrom-Json
        if ($null -eq $message) { continue }
        $messageIdProperty = $message.PSObject.Properties['id']
        if ($null -eq $messageIdProperty -or $messageIdProperty.Value -ne $id) { continue }
        $errorProperty = $message.PSObject.Properties['error']
        if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
            throw "route_a_cdp_error:$($errorProperty.Value | ConvertTo-Json -Compress)"
        }
        return $message
    } while ($true)
}

function Set-OfficialAppServerRouteEnvironment {
    param([Parameter(Mandatory)]$Target)
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    try {
        $socket.ConnectAsync([Uri]$Target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        $nextId = 1
        $routeJson = $ingressBaseUrl | ConvertTo-Json -Compress
        $expression = "(() => { const route = $routeJson; process.env.CODEX_APP_SERVER_CHATGPT_BASE_URL = route; process.env.CODEX_APP_SERVER_OPENAI_BASE_URL = route; return JSON.stringify({ applied: true, pid: process.pid, chatgpt_base_url_applied: process.env.CODEX_APP_SERVER_CHATGPT_BASE_URL === route, openai_base_url_applied: process.env.CODEX_APP_SERVER_OPENAI_BASE_URL === route }); })()"
        $evaluation = Send-CdpCommand -Socket $socket -Method 'Runtime.evaluate' -Params @{ expression = $expression; returnByValue = $true; awaitPromise = $false } -NextId ([ref]$nextId)
        $evaluationResultProperty = $evaluation.PSObject.Properties['result']
        if ($null -eq $evaluationResultProperty) { throw 'route_a_cdp_result_missing' }
        $runtimeResultProperty = $evaluationResultProperty.Value.PSObject.Properties['result']
        if ($null -eq $runtimeResultProperty) { throw 'route_a_runtime_result_missing' }
        $valueProperty = $runtimeResultProperty.Value.PSObject.Properties['value']
        if ($null -eq $valueProperty -or [string]::IsNullOrWhiteSpace([string]$valueProperty.Value)) { throw 'route_a_runtime_value_missing' }
        $value = [string]$valueProperty.Value | ConvertFrom-Json
        if ($value.applied -ne $true -or $value.chatgpt_base_url_applied -ne $true -or $value.openai_base_url_applied -ne $true) {
            throw 'route_a_environment_not_applied'
        }
        [void](Send-CdpCommand -Socket $socket -Method 'Runtime.runIfWaitingForDebugger' -Params @{} -NextId ([ref]$nextId))
        return [pscustomobject]@{
            target_id = [string]$Target.id
            target_pid = [int]$value.pid
            chatgpt_base_url_applied = [bool]$value.chatgpt_base_url_applied
            openai_base_url_applied = [bool]$value.openai_base_url_applied
            resumed = $true
        }
    }
    finally {
        $socket.Dispose()
    }
}

function Get-OfficialAppServerProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -match '(?i)\bapp-server\b' })
}

function Wait-OfficialAppServerRoute {
    param([Parameter(Mandatory)][int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        $candidates = @(Get-OfficialAppServerProcesses)
        $routed = @($candidates | Where-Object {
                $command = [string]$_.CommandLine
                $command -match [regex]::Escape("chatgpt_base_url=$ingressBaseUrl") -and
                    $command -match [regex]::Escape("openai_base_url=$ingressBaseUrl")
            })
        if ($routed.Count -eq 1) {
            return [pscustomobject]@{
                process_id = [int]$routed[0].ProcessId
                parent_process_id = [int]$routed[0].ParentProcessId
                command_line = [string]$routed[0].CommandLine
                candidates = @($candidates | ForEach-Object { [int]$_.ProcessId })
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return [pscustomobject]@{
        process_id = $null
        parent_process_id = $null
        command_line = ''
        candidates = @($candidates | ForEach-Object { [int]$_.ProcessId })
    }
}

function Get-ListeningPid {
    param([Parameter(Mandatory)][int]$Port)
    $rows = @(Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($rows.Count -gt 1) { throw "route_a_multiple_listeners_$Port" }
    if ($rows.Count -eq 0) { return $null }
    return [int]$rows[0].OwningProcess
}

function Wait-RouteReadiness {
    param([Parameter(Mandatory)][int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        $candidatePorts = [ordered]@{
            gateway = Get-ListeningPid -Port 18787
            headroom = Get-ListeningPid -Port 18789
            relay = Get-ListeningPid -Port $relayPort
        }
        $candidateHealth = [ordered]@{
            gateway = Test-HttpReady -Url ($gatewayUrl + '/livez')
            headroom = Test-HttpReady -Url ($headroomUrl + '/livez')
        }
        if ($candidateHealth.gateway.ok -and $candidateHealth.headroom.ok -and $null -ne $candidatePorts.relay) {
            return [pscustomobject]@{ ports = $candidatePorts; health = $candidateHealth }
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    return [pscustomobject]@{ ports = $candidatePorts; health = $candidateHealth }
}

function Find-JsonUrlValues {
    param([Parameter(Mandatory)]$Node)
    $values = [Collections.Generic.List[string]]::new()
    function Visit-RouteJsonNode {
        param($Value)
        if ($null -eq $Value) { return }
        if ($Value -is [string]) { return }
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                $child = $Value[$key]
                if ([string]$key -match '(?i)^(base_url|baseUrl|upstreamBaseUrl|url)$' -and $child -is [string]) {
                    [void]$values.Add([string]$child)
                }
                if ([string]$key -match '(?i)configContents|config' -and $child -is [string]) {
                    foreach ($match in [regex]::Matches([string]$child, '(?im)(?:base_url|baseUrl)\s*[=:]\s*["''](?<url>[^"'']+)["'']')) {
                        [void]$values.Add([string]$match.Groups['url'].Value)
                    }
                }
                Visit-RouteJsonNode $child
            }
            return
        }
        if ($Value -is [System.Collections.IEnumerable]) {
            foreach ($child in $Value) { Visit-RouteJsonNode $child }
            return
        }
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)^(base_url|baseUrl|upstreamBaseUrl|url)$' -and $property.Value -is [string]) {
                [void]$values.Add([string]$property.Value)
            }
            if ($property.Name -match '(?i)configContents|config' -and $property.Value -is [string]) {
                foreach ($match in [regex]::Matches([string]$property.Value, '(?im)(?:base_url|baseUrl)\s*[=:]\s*["''](?<url>[^"'']+)["'']')) {
                    [void]$values.Add([string]$match.Groups['url'].Value)
                }
            }
            Visit-RouteJsonNode $property.Value
        }
    }
    Visit-RouteJsonNode $Node
    return @($values)
}

function Assert-NoLoopbackUpstream {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'route_a_settings_missing' }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    foreach ($value in (Find-JsonUrlValues -Node $settings)) {
        try {
            $uri = [Uri]$value
            if ($uri.Host -in @('127.0.0.1', 'localhost', '::1') -and $uri.Port -in @(18787, 18789, 57321)) {
                throw 'route_a_upstream_loopback_rejected'
            }
        }
        catch [System.UriFormatException] { }
    }
}

function Resolve-OfficialPaths {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    $defaultChatGpt = if ($package) { Join-Path $package.InstallLocation 'app\ChatGPT.exe' } else { '' }
    $defaultCodex = if ($package) { Join-Path $package.InstallLocation 'app\resources\codex.exe' } else { '' }
    $aumid = ''
    if ($package) {
        # AUMID = {Identity}_{PublisherId}!{AppId}.  IdentityName is not
        # populated by Get-AppxPackage; derive it from PackageFamilyName
        # ({Name}_{PublisherHash}).
        $familyName = [string]$package.PackageFamilyName
        $publisher = if ($package.PublisherId) { [string]$package.PublisherId } else { '' }
        $identity = ''
        if (-not [string]::IsNullOrWhiteSpace($familyName) -and -not [string]::IsNullOrWhiteSpace($publisher)) {
            $suffix = "_$publisher"
            if ($familyName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $identity = $familyName.Substring(0, $familyName.Length - $suffix.Length)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($identity) -and -not [string]::IsNullOrWhiteSpace($publisher)) {
            $aumid = "${identity}_${publisher}!App"
        }
    }
    [pscustomobject]@{
        chatgpt = if ($ChatGptPath) { [IO.Path]::GetFullPath($ChatGptPath) } else { $defaultChatGpt }
        codex = if ($CodexCliPath) { [IO.Path]::GetFullPath($CodexCliPath) } else { $defaultCodex }
        aumid = $aumid
    }
}

New-Item -ItemType Directory -Path $runtimeRoot, $stateRoot -Force | Out-Null
$paths = Resolve-OfficialPaths
$before = [ordered]@{
    config_sha256 = Get-Sha256OrEmpty -Path $configPath
    auth_sha256 = Get-Sha256OrEmpty -Path $authPath
    settings_sha256 = Get-Sha256OrEmpty -Path $settingsPath
}
$readiness = Wait-RouteReadiness -TimeoutSeconds $ReadinessTimeoutSeconds
$ports = $readiness.ports
$health = $readiness.health

$document = @{
    schema = 'official-route-a-start/v1'
    status = 'not_proven'
    phase = if ($DryRun) { 'dry_run' } else { 'launch' }
    route = if ($UseRouteCIngress) {
        'official_codex -> 57321(Route-C ingress) -> 18787 -> 18789 -> 57322 -> selected_external_upstream'
    } else {
        'official_codex -> 18787(Gateway) -> 18789 -> 57321(helper) -> selected_external_upstream'
    }
    ingress_mode = if ($UseRouteCIngress) { 'route_c_managed' } else { 'legacy_gateway' }
    project_root = $projectRoot
    shim_path = $shimPath
    shim_sha256 = Get-Sha256OrEmpty -Path $shimPath
    official_chatgpt_path = $paths.chatgpt
    real_codex_cli_path = $paths.codex
    official_aumid = $paths.aumid
    official_chatgpt_exists = [bool](Test-Path -LiteralPath $paths.chatgpt -PathType Leaf)
    real_codex_cli_exists = [bool](Test-Path -LiteralPath $paths.codex -PathType Leaf)
    existing_official_pids = @()
    ports = $ports
    health = $health
    inspector_port = $InspectorPort
    app_cdp_port = $AppCdpPort
    ingress_base_url = $ingressBaseUrl
    activation_args = ''
    node_inspector = $null
    route_environment = $null
    app_server_route = $null
    before = $before
    config_write = $false
    settings_write = $false
    vortex_write = $false
    secrets_logged = $false
    launched_pid = $null
    error_code = ''
}

try {
    if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) { throw 'route_a_shim_missing_run_build_first' }
    if (-not $document.official_chatgpt_exists -or -not $document.real_codex_cli_exists) { throw 'route_a_official_paths_missing' }
    if (-not $health.gateway.ok -or -not $health.headroom.ok -or $null -eq $ports.relay) { throw 'route_a_services_not_ready' }
    Assert-NoLoopbackUpstream

    $existing = @(Get-Process -Name 'ChatGPT','Codex','codex' -ErrorAction SilentlyContinue)
    $document.existing_official_pids = @($existing | ForEach-Object { [int]$_.Id })
    if (-not $DryRun -and $existing.Count -gt 0) { throw 'route_a_activation_requires_official_processes_closed' }

    if (-not $DryRun) {
        # Route-A activation: use IApplicationActivationManager to launch the
        # packaged ChatGPT app (correct AppX package identity).  Direct
        # CreateProcess of a WindowsApps executable is blocked by AppModel for
        # non-package processes, and the packaged app derives codex.exe with
        # the package identity, which is the only supported way to run it.
        # ActivateApplication accepts command-line arguments (used here to
        # open the CDP debug port for injection) but cannot pass environment
        # variables, so route settings are conveyed via CDP injection after
        # the app is up.
        if (-not ('HeadroomActivationManager' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HeadroomActivationManager
{
    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    public class ApplicationActivationManager { }
    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IApplicationActivationManager
    {
        IntPtr ActivateApplication([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [In, MarshalAs(UnmanagedType.LPWStr)] string arguments,
            [In] uint options, [Out] out uint processId);
        IntPtr ActivateForFile([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [In] IntPtr itemArray, [In, MarshalAs(UnmanagedType.LPWStr)] string verb, [Out] out uint processId);
        IntPtr ActivateForProtocol([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [In] IntPtr itemArray, [Out] out uint processId);
    }
    public static uint Activate(string aumid, string arguments)
    {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        uint pid = 0;
        IntPtr hr = manager.ActivateApplication(aumid, arguments, 0, out pid);
        Marshal.ThrowExceptionForHR(hr.ToInt32());
        return pid;
    }
}
'@
        }
        $aumid = $document.official_aumid
        if ([string]::IsNullOrWhiteSpace($aumid)) { throw 'route_a_aumid_missing' }
        Assert-InspectorPortAvailable -Port $InspectorPort
        # The packaged app must pause before it spawns codex.exe.  The
        # environment contract is read by the Electron main process; setting
        # it after app-server exists is too late and only changes future
        # children.  AppX activation arguments are the only supported point
        # available here that reaches the packaged Electron process.
        $activationArgs = @(
            "--remote-debugging-port=$AppCdpPort",
            "--remote-allow-origins=http://127.0.0.1:$AppCdpPort",
            "--inspect-brk=127.0.0.1:$InspectorPort"
        ) -join ' '
        $document.activation_args = $activationArgs
        Write-Output "官方窗口启动：等待 Node inspector 127.0.0.1:$InspectorPort"
        $activatedPid = [HeadroomActivationManager]::Activate($aumid, $activationArgs)
        if ($null -eq $activatedPid -or [int]$activatedPid -le 0) { throw 'route_a_activation_returned_no_pid' }
        $document.launched_pid = [int]$activatedPid
        $target = Wait-NodeInspectorTarget -Port $InspectorPort -TimeoutSeconds $OfficialRouteWaitSeconds
        Write-Output 'Node inspector 已就绪：注入进程级 Headroom 路由'
        $document.node_inspector = [ordered]@{
            port = $InspectorPort
            target_id = [string]$target.id
            target_type = [string]$target.type
        }
        $environment = Set-OfficialAppServerRouteEnvironment -Target $target
        $document.route_environment = $environment
        Write-Output "等待 app-server 命令行确认 $ingressBaseUrl"
        $appServer = Wait-OfficialAppServerRoute -TimeoutSeconds $OfficialRouteWaitSeconds
        $document.app_server_route = $appServer
        if ($null -eq $appServer.process_id) { throw 'route_a_app_server_route_not_observed' }
        $document.status = 'route_injected_waiting_user_traffic'
    }
    else {
        $document.status = 'dry_run_ready'
    }
}
catch {
    $document.status = 'not_proven'
    $document.error_code = $_.Exception.Message
    # Failure must be visible in the launcher window and captured in stderr;
    # a silent receipt-only failure left the user with a blank console.
    $errorCodeText = [string]$_.Exception.Message
    Write-Output ''
    Write-Output 'Official route-A 启动失败：'
    Write-Output "  error_code=$errorCodeText"
    Write-Output "  gateway_ok=$($health.gateway.ok) headroom_ok=$($health.headroom.ok) relay_pid=$($ports.relay)"
    Write-Output "  收据: $receiptPath"
    Write-Host "route-a launch failed: $errorCodeText" -ForegroundColor Red
}
finally {
    $document.after = [ordered]@{
        config_sha256 = Get-Sha256OrEmpty -Path $configPath
        auth_sha256 = Get-Sha256OrEmpty -Path $authPath
        settings_sha256 = Get-Sha256OrEmpty -Path $settingsPath
    }
    $document.protected_files_unchanged = ($document.before.config_sha256 -eq $document.after.config_sha256 -and $document.before.auth_sha256 -eq $document.after.auth_sha256 -and $document.before.settings_sha256 -eq $document.after.settings_sha256)
    if (-not $document.protected_files_unchanged) {
        $document.status = 'not_proven'
        $document.error_code = 'route_a_protected_hash_changed'
    }
    Write-RouteReceipt -Document $document
}

if ($document.status -eq 'not_proven') {
    Write-Output ''
    Write-Output 'Official route-A 未就绪，收据已写入：'
    Write-Output "  $receiptPath"
    Write-Output "  error_code=$($document.error_code)"
    if (-not $NoPause) { [void](Read-Host '按 Enter 关闭窗口') }
    exit 2
}
Write-Output (($document | ConvertTo-Json -Depth 12))
