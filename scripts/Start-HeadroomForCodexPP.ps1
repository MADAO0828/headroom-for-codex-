[CmdletBinding()]
param(
    [ValidateSet(1, 2)]
    [int]$Workers = 1,
    [switch]$ServicesOnly,
    [switch]$PhaseB,
    [int]$ReadinessTimeoutSeconds = 600,
    [ValidateRange(1024, 65535)]
    [int]$BrokerPort = 18790
)

$ErrorActionPreference = 'Stop'

if (-not ('HeadroomProcessPathProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HeadroomProcessPathProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(
        IntPtr process,
        uint flags,
        StringBuilder executablePath,
        ref uint size);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static string Read(int processId)
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)processId);
        if (handle == IntPtr.Zero) return String.Empty;
        try
        {
            uint size = 32768;
            var executablePath = new StringBuilder((int)size);
            return QueryFullProcessImageName(handle, 0, executablePath, ref size)
                ? executablePath.ToString()
                : String.Empty;
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
# The repository is the single source of truth for the managed proxy.  The
# external Codex++ bootstrap remains an integration point, but Headroom and
# Gateway code/state must not silently come from an older user-cache copy.
$runtimeHeadroom = Join-Path $projectRoot 'src\headroom\codexpp-headroom'
$runtimeCodexSource = Join-Path $projectRoot 'src\codexpp\Codex++'
$runtimeRoot = Join-Path $projectRoot 'runtime'
$runtimeStateRoot = Join-Path $runtimeRoot 'state'
$runtimeLogRoot = Join-Path $runtimeRoot 'logs'
$runtimeCacheRoot = Join-Path $runtimeRoot 'cache'
$runtimePrivateRoot = Join-Path $runtimeRoot 'private'
$runtimePythonRoot = Join-Path $runtimeRoot 'python'
$ensureScript = Join-Path $runtimeHeadroom 'ensure-headroom.ps1'
$startupGate = Join-Path $runtimeCodexSource 'codexpp-startup-gate.ps1'
$managerBootstrap = Join-Path $runtimeCodexSource 'codex-manager-bootstrap.vbs'
$clientBootstrap = Join-Path $runtimeCodexSource 'codex-wrapper-bootstrap.vbs'
$managerExe = 'D:\program\Codex++\codex-plus-plus-manager.exe'
$clientExe = 'D:\program\Codex++\codex-plus-plus.exe'
$managerCodexHome = 'C:\Users\ma dao\.codex-plus-plus-cli'
$managerConfig = Join-Path $managerCodexHome 'config.toml'
$routeKeeper = Join-Path $runtimeCodexSource 'codexpp-route-keeper.ps1'
$monitorScript = Join-Path $projectRoot 'src\codexpp\Codex++\codexpp-headroom-monitor.ps1'
$resultPath = Join-Path $runtimeStateRoot 'headroom-start-result.json'
$phaseBResultPath = Join-Path $runtimeStateRoot 'phase-b-activation-result.json'
$aggregateRemovalScript = Join-Path $projectRoot 'scripts\Remove-HeadroomAggregateRelay.ps1'
$aggregateSettingsPath = 'C:\Users\ma dao\.codex-session-delete\settings.json'
$aggregateBackupPath = Join-Path $projectRoot 'backups\phase-b\settings.before-remove.json'
$indicatorRegisterScript = Join-Path $projectRoot 'scripts\Register-HeadroomUserScript.ps1'
$indicatorMetadataPath = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts.json'
$indicatorUserScriptsDir = 'C:\Users\ma dao\AppData\Roaming\Codex++\user_scripts'
$indicatorBackupPath = Join-Path $projectRoot 'backups\metadata\user_scripts.json.before-headroom-register'
$brokerModuleRoot = Join-Path $projectRoot 'src'
$brokerPython = Join-Path $runtimePythonRoot 'Scripts\python.exe'
$brokerStatePath = Join-Path $runtimeStateRoot 'kompress-broker-state.json'
$brokerRuntimeStatePath = Join-Path $runtimeStateRoot 'kompress-broker-runtime.json'
$brokerRequestTimeoutSeconds = '20'
$responsesCompressionSoftBudgetSeconds = '20'
$runtimePatchRoot = Join-Path $projectRoot 'src\headroom\site-packages-patches\headroom'
$runtimePackageRoot = Join-Path $runtimePythonRoot 'Lib\site-packages\headroom'
$patchSyncScript = Join-Path $projectRoot 'scripts\Sync-HeadroomRuntimePatches.ps1'
$patchSyncReceiptPath = Join-Path $runtimeStateRoot 'headroom-runtime-patch-sync.json'
$patchSyncReceipt = $null
$brokerLogRoot = $runtimeLogRoot
$routeStatePath = Join-Path $runtimeStateRoot 'codexpp-route-state.json'
$routeWatchStatePath = Join-Path $runtimeStateRoot 'codexpp-route-watch.json'
$routeReadySignalPath = Join-Path $runtimeStateRoot 'codexpp-route-ready.signal'
$startupResultPath = Join-Path $runtimeStateRoot 'startup-result.json'
$managedCodexStatePath = Join-Path $runtimeStateRoot 'managed-codex-processes.json'
$monitorStatePath = Join-Path $runtimeStateRoot 'codexpp-headroom-monitor-state.json'
$monitorStatusStatePath = Join-Path $runtimeStateRoot 'codexpp-headroom-monitor-status.json'
$gatewayUrl = 'http://127.0.0.1:18787'
$headroomUrl = 'http://127.0.0.1:18789'
$monitorUrl = 'http://127.0.0.1:18788'
$brokerUrl = "http://127.0.0.1:$BrokerPort"
$startMutex = [Threading.Mutex]::new($false, 'Local\HeadroomForCodexPP.Start')
$startMutexHeld = $false
$previousKompressEndpoint = [Environment]::GetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', 'Process')
$sourceHashesBefore = @{}
$managerConfigHashBefore = ''
$managerConfigHashAfter = ''
$managerConfigProtectedBefore = $null
$managerConfigProtectedAfter = $null
$managerConfigChangedByManager = $false

foreach ($requiredDirectory in @($runtimeRoot, $runtimeStateRoot, $runtimeLogRoot, $runtimeCacheRoot, $runtimePrivateRoot)) {
    [IO.Directory]::CreateDirectory($requiredDirectory) | Out-Null
}

function Write-StartResult {
    param(
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed')][string]$Status,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorCode,
        [string]$Detail = ''
    )

    $document = [ordered]@{
        schema_version = 1
        status = $Status
        stage = $Stage
        error_code = $ErrorCode
        detail = ($Detail -replace '[\r\n\t]+', ' ').Substring(0, [Math]::Min(500, ($Detail -replace '[\r\n\t]+', ' ').Length))
        workers = $Workers
        gateway_url = $gatewayUrl
        headroom_url = $headroomUrl
        monitor_url = $monitorUrl
        broker_url = $brokerUrl
        broker_port = $BrokerPort
        broker_module_hash = if ($sourceHashesBefore.ContainsKey('broker')) { $sourceHashesBefore['broker'] } else { '' }
        patch_sync_version = if ($null -ne $patchSyncReceipt) { [int]$patchSyncReceipt.sync_version } else { 0 }
        patch_sync_manifest_sha256 = if ($null -ne $patchSyncReceipt) { [string]$patchSyncReceipt.manifest_sha256 } else { '' }
        config_sha256 = if (Test-Path -LiteralPath $managerConfig -PathType Leaf) { try { (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash } catch { '' } } else { '' }
        config_sha256_before = $managerConfigHashBefore
        config_sha256_after = $managerConfigHashAfter
        config_changed_after_manager = $managerConfigChangedByManager
        config_protected_contract_unchanged = ($null -ne $managerConfigProtectedBefore -and $null -ne $managerConfigProtectedAfter -and (Test-ConfigProtectedContract -Before $managerConfigProtectedBefore -After $managerConfigProtectedAfter))
        route_state_path = $routeStatePath
        project_root = $projectRoot
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $parent = Split-Path -Parent $resultPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.headroom-start-result-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $resultPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-PhaseBResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    $parent = Split-Path -Parent $phaseBResultPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.phase-b-result-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($Document | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $phaseBResultPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ListenerPid {
    param([Parameter(Mandatory)][int]$Port)
    $connections = @(Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue)
    $pids = @($connections | ForEach-Object { [int]$_.OwningProcess } | Select-Object -Unique)
    if ($pids.Count -gt 1) { throw "multiple_listeners:$Port" }
    if ($pids.Count -eq 0) { return $null }
    return [int]$pids[0]
}

function Get-ProcessCommandLine {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $snapshot) { return '' }
        return [string]$snapshot.CommandLine
    }
    catch { return '' }
}

function Get-ProcessExecutablePath {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        $cimPath = if ($null -eq $snapshot) { '' } else { [string]$snapshot.ExecutablePath }
        if (-not [string]::IsNullOrWhiteSpace($cimPath)) { return $cimPath }
    }
    catch { }
    try { return [string][HeadroomProcessPathProbe]::Read($ProcessId) } catch { return '' }
}

function Get-ModuleHash {
    param([Parameter(Mandatory)][string[]]$Paths)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in ($Paths | Sort-Object)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        [void]$parts.Add(([IO.Path]::GetFullPath($path).ToLowerInvariant() + ':' + $hash))
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($parts -join "`n"))
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes))).Replace('-', '')
}

function Get-ManagedSourceHashes {
    $hashes = @{}
    $hashes['startup_gate'] = Get-ModuleHash -Paths @($startupGate)
    $hashes['route_keeper'] = Get-ModuleHash -Paths @($routeKeeper)
    $hashes['monitor'] = Get-ModuleHash -Paths @($monitorScript)
    $hashes['gateway'] = Get-ModuleHash -Paths @((Join-Path $runtimeHeadroom 'gateway.py'))
    $hashes['broker'] = Get-ModuleHash -Paths @(
        (Join-Path $brokerModuleRoot 'kompress_broker\app.py'),
        (Join-Path $brokerModuleRoot 'kompress_broker\worker.py')
    )
    foreach ($key in $hashes.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$hashes[$key])) { throw "source_hash_missing:$key" }
    }
    return $hashes
}

function Get-HeadroomPatchSyncReceipt {
    if (-not (Test-Path -LiteralPath $patchSyncReceiptPath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $patchSyncReceiptPath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-HeadroomRuntimeActive {
    foreach ($port in @($BrokerPort, 18787, 18789, 18788)) {
        if ($null -ne (Get-ListenerPid -Port $port)) { return $true }
    }
    if (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe)).Count -gt 0) { return $true }
    return $false
}

function Invoke-HeadroomPatchSync {
    if (-not (Test-Path -LiteralPath $patchSyncScript -PathType Leaf)) { throw "patch_sync_script_missing:$patchSyncScript" }
    if (-not (Test-Path -LiteralPath $runtimePatchRoot -PathType Container)) { throw "patch_sync_source_missing:$runtimePatchRoot" }
    if (-not (Test-Path -LiteralPath $runtimePackageRoot -PathType Container)) { throw "patch_sync_target_missing:$runtimePackageRoot" }

    $active = Test-HeadroomRuntimeActive
    $syncOutput = if ($active) {
        @(& $patchSyncScript -PatchRoot $runtimePatchRoot -RuntimePackageRoot $runtimePackageRoot -ReceiptPath $patchSyncReceiptPath -DryRun 2>&1)
    }
    else {
        @(& $patchSyncScript -PatchRoot $runtimePatchRoot -RuntimePackageRoot $runtimePackageRoot -ReceiptPath $patchSyncReceiptPath 2>&1)
    }
    $receipt = Get-HeadroomPatchSyncReceipt
    if ($active -and $null -ne $receipt -and [string]$receipt.status -eq 'drift') {
        throw 'runtime_patch_drift_requires_quiescence'
    }
    if ($LASTEXITCODE -ne 0) {
        $detail = (($syncOutput | ForEach-Object { [string]$_ }) -join ' ')
        throw "runtime_patch_sync_failed:$($detail.Substring(0, [Math]::Min(500, $detail.Length)))"
    }
    if ($null -eq $receipt -or [string]$receipt.status -notin @('synced', 'in_sync') -or [int]$receipt.sync_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$receipt.manifest_sha256)) {
        throw 'runtime_patch_sync_receipt_invalid'
    }
    return $receipt
}

function Test-SourceHashesUnchanged {
    param([Parameter(Mandatory)][hashtable]$Expected)
    $actual = Get-ManagedSourceHashes
    foreach ($key in $Expected.Keys) {
        if (-not $actual.ContainsKey($key) -or $actual[$key] -ne $Expected[$key]) { return $false }
    }
    return $true
}

function Get-JsonEndpoint {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 15
        $body = $null
        try { if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) { $body = $response.Content | ConvertFrom-Json } } catch { }
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $body; TransportOk = $true }
    }
    catch {
        return [pscustomobject]@{ StatusCode = 0; Body = $null; TransportOk = $false }
    }
}

function Get-PropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ConfigProtectedContract {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$FallbackPath = $null
    )

    # The protected contract protects the supplier base_url from being
    # rewritten by Headroom.  Under Codex++ aggregate mode the Manager's
    # config.toml (.codex-plus-plus-cli) intentionally carries no
    # model_provider section - Codex++ writes the active supplier contract
    # into the official home (~/.codex/config.toml) and routes through the
    # local protocol proxy.  When the primary path has no root provider,
    # fall back to the official home so the contract remains verifiable
    # without weakening the "base_url not rewritten" invariant.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Provider = $null
            ProviderPresent = $false
            ProviderSectionSha256 = $null
            BaseUrlPresent = $false
            BaseUrl = $null
            WireApiPresent = $false
            WireApi = $null
            RequiresOpenAIAuthPresent = $false
            RequiresOpenAIAuth = $null
            ExperimentalBearerTokenPresent = $false
            ProtectedContractSha256 = $null
            Error = 'config_missing'
        }
    }

    try {
        $content = [IO.File]::ReadAllText($Path)
        $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $usedFallback = $false
        if (-not $providerMatch.Success -and -not [string]::IsNullOrWhiteSpace($FallbackPath) -and (Test-Path -LiteralPath $FallbackPath -PathType Leaf)) {
            $content = [IO.File]::ReadAllText($FallbackPath)
            $providerMatch = [regex]::Match($content, '(?im)^\s*model_provider\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
            $usedFallback = $providerMatch.Success
        }
        if (-not $providerMatch.Success) {
            return [pscustomobject]@{ Exists = $true; Provider = $null; ProviderPresent = $false; ProviderSectionSha256 = $null; BaseUrlPresent = $false; BaseUrl = $null; WireApiPresent = $false; WireApi = $null; RequiresOpenAIAuthPresent = $false; RequiresOpenAIAuth = $null; ExperimentalBearerTokenPresent = $false; ProtectedContractSha256 = $null; Error = 'root_model_provider_missing' }
        }
        $provider = if ($providerMatch.Groups['double'].Success) { $providerMatch.Groups['double'].Value } else { $providerMatch.Groups['single'].Value }
        $sectionMatch = [regex]::Match($content, '(?ims)^\s*\[model_providers\.' + [regex]::Escape($provider) + '\]\s*(?<section>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) {
            return [pscustomobject]@{ Exists = $true; Provider = $provider; ProviderPresent = $true; ProviderSectionSha256 = $null; BaseUrlPresent = $false; BaseUrl = $null; WireApiPresent = $false; WireApi = $null; RequiresOpenAIAuthPresent = $false; RequiresOpenAIAuth = $null; ExperimentalBearerTokenPresent = $false; ProtectedContractSha256 = $null; Error = 'provider_section_missing' }
        }
        $section = $sectionMatch.Groups['section'].Value
        $baseMatch = [regex]::Match($section, '(?im)^\s*base_url\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $wireMatch = [regex]::Match($section, '(?im)^\s*wire_api\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
        $authMatch = [regex]::Match($section, '(?im)^\s*requires_openai_auth\s*=\s*(?<value>true|false)\s*(?:#.*)?$')
        $tokenMatch = [regex]::Match($section, '(?im)^\s*experimental_bearer_token\s*=')
        # Only the active supplier contract is protected.  Manager-owned
        # metadata may legitimately change inside this section, so do not
        # hash the raw provider section.  The bearer token value is never
        # persisted in the contract or its fingerprint, only its presence.
        $providerPresent = $true
        $baseUrlPresent = $baseMatch.Success
        $wireApiPresent = $wireMatch.Success
        $requiresOpenAIAuthPresent = $authMatch.Success
        $bearerTokenPresent = $tokenMatch.Success
        $baseUrl = if ($baseUrlPresent) { if ($baseMatch.Groups['double'].Success) { $baseMatch.Groups['double'].Value } else { $baseMatch.Groups['single'].Value } } else { $null }
        $wireApi = if ($wireApiPresent) { if ($wireMatch.Groups['double'].Success) { $wireMatch.Groups['double'].Value } else { $wireMatch.Groups['single'].Value } } else { $null }
        $requiresOpenAIAuth = if ($requiresOpenAIAuthPresent) { $authMatch.Groups['value'].Value.ToLowerInvariant() } else { $null }
        $canonical = @(
            "provider_present=$([int][bool]$providerPresent)"
            "provider=$provider"
            "base_url_present=$([int][bool]$baseUrlPresent)"
            "base_url=$baseUrl"
            "wire_api_present=$([int][bool]$wireApiPresent)"
            "wire_api=$wireApi"
            "requires_openai_auth_present=$([int][bool]$requiresOpenAIAuthPresent)"
            "requires_openai_auth=$requiresOpenAIAuth"
            "bearer_token_present=$([int][bool]$bearerTokenPresent)"
        ) -join "`n"
        $sectionBytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
        $sectionHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($sectionBytes))).Replace('-', '')
        return [pscustomobject]@{
            Exists = $true
            Provider = $provider
            ProviderPresent = $providerPresent
            ProviderSectionSha256 = $sectionHash
            BaseUrlPresent = $baseUrlPresent
            BaseUrl = $baseUrl
            WireApiPresent = $wireApiPresent
            WireApi = $wireApi
            RequiresOpenAIAuthPresent = $requiresOpenAIAuthPresent
            RequiresOpenAIAuth = $requiresOpenAIAuth
            ExperimentalBearerTokenPresent = $bearerTokenPresent
            ProtectedContractSha256 = $sectionHash
            UsedFallback = $usedFallback
            Error = if (-not $baseMatch.Success) { 'base_url_missing' } elseif (-not $wireMatch.Success) { 'wire_api_missing' } else { $null }
        }
    }
    catch {
        return [pscustomobject]@{ Exists = $true; Provider = $null; ProviderPresent = $false; ProviderSectionSha256 = $null; BaseUrlPresent = $false; BaseUrl = $null; WireApiPresent = $false; WireApi = $null; RequiresOpenAIAuthPresent = $false; RequiresOpenAIAuth = $null; ExperimentalBearerTokenPresent = $false; ProtectedContractSha256 = $null; Error = 'config_read_error' }
    }
}

function Test-ConfigProtectedContract {
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )

    if (-not $Before.Exists -or -not $After.Exists -or $null -ne $Before.Error -or $null -ne $After.Error) { return $false }
    return (
        [bool]$Before.ProviderPresent -eq [bool]$After.ProviderPresent -and
        [string]$Before.Provider -eq [string]$After.Provider -and
        [bool]$Before.BaseUrlPresent -eq [bool]$After.BaseUrlPresent -and
        [string]$Before.BaseUrl -eq [string]$After.BaseUrl -and
        [bool]$Before.WireApiPresent -eq [bool]$After.WireApiPresent -and
        [string]$Before.WireApi -eq [string]$After.WireApi -and
        [bool]$Before.RequiresOpenAIAuthPresent -eq [bool]$After.RequiresOpenAIAuthPresent -and
        [string]$Before.RequiresOpenAIAuth -eq [string]$After.RequiresOpenAIAuth -and
        [bool]$Before.ExperimentalBearerTokenPresent -eq [bool]$After.ExperimentalBearerTokenPresent
    )
}

function ConvertTo-ConfigProtectedContractRecord {
    param([AllowNull()][object]$Contract)
    if ($null -eq $Contract) { return $null }
    return [ordered]@{
        provider_present = [bool](Get-PropertyValue -Object $Contract -Name 'ProviderPresent')
        provider = [string](Get-PropertyValue -Object $Contract -Name 'Provider')
        base_url_present = [bool](Get-PropertyValue -Object $Contract -Name 'BaseUrlPresent')
        base_url = [string](Get-PropertyValue -Object $Contract -Name 'BaseUrl')
        wire_api_present = [bool](Get-PropertyValue -Object $Contract -Name 'WireApiPresent')
        wire_api = [string](Get-PropertyValue -Object $Contract -Name 'WireApi')
        requires_openai_auth_present = [bool](Get-PropertyValue -Object $Contract -Name 'RequiresOpenAIAuthPresent')
        requires_openai_auth = [string](Get-PropertyValue -Object $Contract -Name 'RequiresOpenAIAuth')
        bearer_token_present = [bool](Get-PropertyValue -Object $Contract -Name 'ExperimentalBearerTokenPresent')
        fingerprint = [string](Get-PropertyValue -Object $Contract -Name 'ProtectedContractSha256')
    }
}

function Update-RouteStateConfigHash {
    param(
        [Parameter(Mandatory)][string]$ConfigHash,
        [Parameter(Mandatory)][object]$ProtectedContract
    )
    if ([string]::IsNullOrWhiteSpace($ConfigHash) -or $null -eq $ProtectedContract -or -not (Test-Path -LiteralPath $routeStatePath -PathType Leaf)) { return $false }
    try {
        $state = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json
        if ([string]$state.route_scope -ne 'process' -or [bool]$state.config_mutated) { return $false }
        $protectedRecord = ConvertTo-ConfigProtectedContractRecord -Contract $ProtectedContract
        $existingProtected = Get-PropertyValue -Object $state -Name 'config_protected_contract'
        if ($null -ne $existingProtected -and [string]$existingProtected.fingerprint -ne [string]$protectedRecord.fingerprint) { return $false }
        $state.config_sha256 = $ConfigHash
        $state.config_protected_contract = $protectedRecord
        $state.timestamp_utc = [DateTime]::UtcNow.ToString('o')
        $parent = Split-Path -Parent $routeStatePath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temp = Join-Path $parent ('.codexpp-route-state-refresh-' + [IO.Path]::GetRandomFileName())
        try {
            [IO.File]::WriteAllText($temp, (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temp, $routeStatePath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        return $true
    }
    catch { return $false }
}

function Test-GatewayReadinessSnapshot {
    param(
        [Parameter(Mandatory)][object]$Live,
        [Parameter(Mandatory)][object]$Health,
        [switch]$AllowRelayPending
    )

    $liveReady = $Live.TransportOk -and $Live.StatusCode -eq 200 -and $null -ne $Live.Body -and (Get-PropertyValue -Object $Live.Body -Name 'alive') -eq $true
    $healthReady = $Health.TransportOk -and $Health.StatusCode -eq 200 -and $null -ne $Health.Body -and (Get-PropertyValue -Object $Health.Body -Name 'ready') -eq $true
    if ($liveReady -and $healthReady) { return $true }
    if (-not $AllowRelayPending -or -not $liveReady) { return $false }

    # Before Manager/client launch, a live Gateway may report only the
    # expected missing helper dependency.  Accept that exact degraded
    # snapshot, never an arbitrary 503 or a reachable-but-unhealthy helper.
    $checks = Get-PropertyValue -Object $Health.Body -Name 'checks'
    $headroom = Get-PropertyValue -Object $checks -Name 'headroom'
    $helper = Get-PropertyValue -Object $checks -Name 'helper'
    return (
        $Health.TransportOk -and $Health.StatusCode -eq 503 -and $null -ne $Health.Body -and
        [string](Get-PropertyValue -Object $Health.Body -Name 'service') -eq 'policy-gateway' -and
        [string](Get-PropertyValue -Object $Health.Body -Name 'status') -eq 'degraded' -and
        (Get-PropertyValue -Object $Health.Body -Name 'ready') -eq $false -and
        (Get-PropertyValue -Object $headroom -Name 'ok') -eq $true -and
        (Get-PropertyValue -Object $helper -Name 'ok') -eq $false -and
        $null -eq (Get-PropertyValue -Object $helper -Name 'status_code')
    )
}

function Write-BrokerState {
    param([Parameter(Mandatory)][int]$ProcessId)
    $directory = Split-Path -Parent $brokerStatePath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $document = [ordered]@{
        schema_version = 1
        service = 'kompress-broker'
        state_role = 'managed-process-identity'
        pid = $ProcessId
        port = $BrokerPort
        executable_path = (Get-ProcessExecutablePath -ProcessId $ProcessId)
        invocation_path = [IO.Path]::GetFullPath($brokerPython)
        command_line = (Get-ProcessCommandLine -ProcessId $ProcessId)
        module = 'kompress_broker.app:app'
        module_hash = [string]$sourceHashesBefore['broker']
        endpoint = $brokerUrl
        responses_compression_soft_budget_seconds = $responsesCompressionSoftBudgetSeconds
        request_timeout_seconds = $brokerRequestTimeoutSeconds
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $temp = Join-Path $directory ('.kompress-broker-state-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp, (($document | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $brokerStatePath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BrokerState {
    if (-not (Test-Path -LiteralPath $brokerStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $brokerStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-ManagedBrokerIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    $state = Get-BrokerState
    if ($null -eq $state) { return $false }
    if ([int]$state.port -ne $BrokerPort -or [int]$state.pid -ne $ProcessId) { return $false }
    if ([string]$state.module -ne 'kompress_broker.app:app' -or [string]$state.module_hash -ne [string]$sourceHashesBefore['broker']) { return $false }
    if ([string]$state.responses_compression_soft_budget_seconds -ne $responsesCompressionSoftBudgetSeconds -or [string]$state.request_timeout_seconds -ne $brokerRequestTimeoutSeconds) { return $false }
    $commandLine = Get-ProcessCommandLine -ProcessId $ProcessId
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
    $expectedInvocation = [IO.Path]::GetFullPath($brokerPython)
    $quotedInvocation = '"' + $expectedInvocation + '"'
    if (-not [string]::Equals([string]$state.invocation_path, $expectedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not $commandLine.StartsWith($quotedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $actualExecutable = Get-ProcessExecutablePath -ProcessId $ProcessId
    if (-not [string]::Equals([string]$state.executable_path, $actualExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $commandLine -match '(?i)kompress_broker\.app:app' -and $commandLine -match ('(?i)--port\s+' + [regex]::Escape($BrokerPort.ToString()))
}

function Test-BrokerProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    $commandLine = Get-ProcessCommandLine -ProcessId $ProcessId
    $executablePath = Get-ProcessExecutablePath -ProcessId $ProcessId
    if ([string]::IsNullOrWhiteSpace($commandLine) -or [string]::IsNullOrWhiteSpace($executablePath)) { return $false }
    $expectedPython = [IO.Path]::GetFullPath($brokerPython)
    try { $actualPython = [IO.Path]::GetFullPath($executablePath) } catch { return $false }
    $quotedInvocation = '"' + $expectedPython + '"'
    if (-not $commandLine.StartsWith($quotedInvocation, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $parentPath = ''
    try {
        $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $snapshot) { $parentPath = Get-ProcessExecutablePath -ProcessId ([int]$snapshot.ParentProcessId) }
    }
    catch { }
    $executableMatches = [string]::Equals($actualPython, $expectedPython, [StringComparison]::OrdinalIgnoreCase)
    $parentMatches = -not [string]::IsNullOrWhiteSpace($parentPath) -and [string]::Equals([IO.Path]::GetFullPath($parentPath), $expectedPython, [StringComparison]::OrdinalIgnoreCase)
    return (
        ($executableMatches -or $parentMatches) -and
        $commandLine -match '(?i)kompress_broker\.app:app' -and
        $commandLine -match ('(?i)--port\s+' + [regex]::Escape($BrokerPort.ToString())) -and
        $commandLine.Replace('/', '\').IndexOf($projectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Stop-ManagedProcessGracefully {
    param([Parameter(Mandatory)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    try {
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(3000)) {
                Stop-Process -Id $ProcessId -Force -ErrorAction Stop
                [void]$process.WaitForExit(3000)
            }
        }
        return $null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
    catch { return $false }
}

function Get-MonitorState {
    if (-not (Test-Path -LiteralPath $monitorStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $monitorStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-ProjectMonitorCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $normalized = $CommandLine.Replace('/', '\')
    $expected = [IO.Path]::GetFullPath($monitorScript).Replace('/', '\')
    if ($normalized.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    return $normalized -match '(?i)(?:^|\s)-File(?:\s|$)'
}

function Get-ProjectMonitorProcesses {
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $executablePath = [string]$snapshot.ExecutablePath
        $commandLine = [string]$snapshot.CommandLine
        if ([string]::IsNullOrWhiteSpace($executablePath) -or [IO.Path]::GetFileName($executablePath) -notin @('pwsh.exe', 'powershell.exe')) { continue }
        if (Test-ProjectMonitorCommandLine -CommandLine $commandLine) { [void]$matches.Add($snapshot) }
    }
    return @($matches)
}

function Test-ManagedMonitorIdentity {
    $state = Get-MonitorState
    if ($null -eq $state -or [int]$state.schema_version -ne 2) { return $false }
    try { $expectedMonitorSourceSha256 = (Get-FileHash -LiteralPath $monitorScript -Algorithm SHA256).Hash.ToUpperInvariant() } catch { return $false }
    $processId = 0
    if (-not [int]::TryParse([string]$state.monitor_pid, [ref]$processId) -or $processId -le 0) { return $false }
    try {
        $stateScriptPath = [IO.Path]::GetFullPath([string]$state.monitor_script_path)
        $stateRuntimeRoot = [IO.Path]::GetFullPath([string]$state.runtime_root)
    }
    catch { return $false }
    if (-not [string]::Equals($stateScriptPath, [IO.Path]::GetFullPath($monitorScript), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals($stateRuntimeRoot, [IO.Path]::GetFullPath($runtimeRoot), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([string]$state.monitor_source_sha256 -ne $expectedMonitorSourceSha256 -or [string]$state.monitor_mode -ne 'watch') { return $false }

    $snapshot = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $snapshot -or -not (Test-ProjectMonitorCommandLine -CommandLine ([string]$snapshot.CommandLine))) { return $false }
    $normalizedCommandLine = ([string]$snapshot.CommandLine).Replace('/', '\')
    if ($normalizedCommandLine.IndexOf(([IO.Path]::GetFullPath($runtimeRoot).Replace('/', '\')), [StringComparison]::OrdinalIgnoreCase) -lt 0 -or $normalizedCommandLine -notmatch '(?i)(?:^|\s)-RuntimeRoot(?:\s|$)') { return $false }
    $status = Get-JsonEndpoint -Url ($monitorUrl + '/status')
    if (-not $status.TransportOk -or $status.StatusCode -ne 200 -or $null -eq $status.Body) { return $false }
    $identity = Get-PropertyValue -Object $status.Body -Name 'monitor'
    if ($null -eq $identity -or [int](Get-PropertyValue -Object $identity -Name 'pid') -ne $processId) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'instance_id') -ne [string]$state.monitor_instance_id) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'started_at') -ne [string]$state.monitor_started_at) { return $false }
    if ([string](Get-PropertyValue -Object $identity -Name 'source_sha256') -ne $expectedMonitorSourceSha256) { return $false }
    try {
        $statusScriptPath = [IO.Path]::GetFullPath([string](Get-PropertyValue -Object $identity -Name 'script_path'))
        $statusRuntimeRoot = [IO.Path]::GetFullPath([string](Get-PropertyValue -Object $identity -Name 'runtime_root'))
    }
    catch { return $false }
    return (
        [string]::Equals($statusScriptPath, [IO.Path]::GetFullPath($monitorScript), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($statusRuntimeRoot, [IO.Path]::GetFullPath($runtimeRoot), [StringComparison]::OrdinalIgnoreCase)
    )
}

function Ensure-Monitor {
    if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) { throw "monitor_script_missing:$monitorScript" }
    if ((Test-Listener -Port 18788) -and (Test-ManagedMonitorIdentity)) { return }

    $projectMonitors = @(Get-ProjectMonitorProcesses)
    if ((Test-Listener -Port 18788) -and $projectMonitors.Count -eq 0) { throw 'monitor_port_conflict_unmanaged:18788' }
    foreach ($snapshot in $projectMonitors) {
        if (-not (Stop-ManagedProcessGracefully -ProcessId ([int]$snapshot.ProcessId))) { throw "monitor_shutdown_failed:$($snapshot.ProcessId)" }
    }
    $releaseDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ((Test-Listener -Port 18788) -and [DateTime]::UtcNow -lt $releaseDeadline) { Start-Sleep -Milliseconds 250 }
    if (Test-Listener -Port 18788) { throw 'monitor_port_release_timeout:18788' }

    foreach ($path in @($monitorStatePath, $monitorStatusStatePath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $monitorArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -RuntimeRoot `"$runtimeRoot`" -Watch -NoPopup -PollSeconds 5 -StartupGraceSeconds 120 -PrelaunchGraceSeconds 180"
    $monitorProcess = Start-Process -FilePath 'pwsh.exe' -ArgumentList $monitorArgs -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Test-Listener -Port 18788) -and (Test-ManagedMonitorIdentity)) { return }
        try { $monitorProcess.Refresh(); if ($monitorProcess.HasExited) { throw 'monitor_process_exited' } } catch { if ($_.Exception.Message -eq 'monitor_process_exited') { throw } }
        Start-Sleep -Milliseconds 250
    }
    if ($null -ne (Get-Process -Id $monitorProcess.Id -ErrorAction SilentlyContinue)) { [void](Stop-ManagedProcessGracefully -ProcessId $monitorProcess.Id) }
    throw 'monitor_ready_timeout'
}

function Test-BrokerReady {
    $probe = Get-JsonEndpoint -Url ($brokerUrl + '/readyz')
    if (-not $probe.TransportOk -or $probe.StatusCode -ne 200 -or $null -eq $probe.Body) { return $false }
    return (
        [string]$probe.Body.service -eq 'kompress-broker' -and
        $probe.Body.ready -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string]$probe.Body.provider) -and
        -not [string]::IsNullOrWhiteSpace([string]$probe.Body.backend)
    )
}

function Ensure-KompressBroker {
    if (-not (Test-Path -LiteralPath $brokerPython -PathType Leaf)) { throw "broker_python_missing:$brokerPython" }
    foreach ($path in @(
            (Join-Path $brokerModuleRoot 'kompress_broker\app.py'),
            (Join-Path $brokerModuleRoot 'kompress_broker\worker.py'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "broker_module_missing:$path" }
    }

    $listenerPid = Get-ListenerPid -Port $BrokerPort
    if ($null -ne $listenerPid) {
        if (-not (Test-ManagedBrokerIdentity -ProcessId $listenerPid)) {
            throw "broker_port_conflict_unmanaged:$BrokerPort"
        }
        if (Test-BrokerReady) { return }
        if (-not (Stop-ManagedProcessGracefully -ProcessId $listenerPid)) { throw 'broker_shutdown_failed' }
    }

    [IO.Directory]::CreateDirectory($brokerLogRoot) | Out-Null
    $stdoutPath = Join-Path $brokerLogRoot "kompress-broker-$BrokerPort.stdout.log"
    $stderrPath = Join-Path $brokerLogRoot "kompress-broker-$BrokerPort.stderr.log"
    $environment = @{
        KOMPRESS_BROKER_STATE_PATH = $brokerRuntimeStatePath
        KOMPRESS_PROVIDER_BACKEND = 'cpu'
        KOMPRESS_WORKER_PYTHON = $brokerPython
        KOMPRESS_WORKER_STDERR_PATH = (Join-Path $brokerLogRoot 'kompress-worker.stderr.log')
        # The ONNX worker cold-loads the Kompress model on the first compress
        # (up to several minutes on this host); give the broker's own canary
        # verification and per-request budget enough headroom so a cold start
        # does not trip broker_ready_timeout.
        KOMPRESS_STARTUP_TIMEOUT_SECONDS = '600'
        KOMPRESS_REQUEST_TIMEOUT_SECONDS = $brokerRequestTimeoutSeconds
        PYTHONPATH = $brokerModuleRoot
        HEADROOM_KOMPRESS_ENDPOINT = $brokerUrl
        HEADROOM_KOMPRESS_BACKEND = 'onnx_cpu'
        HEADROOM_RESPONSES_COMPRESSION_SOFT_BUDGET_SECONDS = $responsesCompressionSoftBudgetSeconds
        HEADROOM_KOMPRESS_ONNX_INTRA_THREADS = '12'
        HEADROOM_KOMPRESS_ONNX_INTER_THREADS = '1'
        HEADROOM_ONNX_CPU_ARENA = '1'
        HF_HOME = (Join-Path $runtimeCacheRoot 'huggingface')
        HF_HUB_CACHE = (Join-Path $runtimeCacheRoot 'huggingface\hub')
        TRANSFORMERS_CACHE = (Join-Path $runtimeCacheRoot 'huggingface\transformers')
        HEADROOM_CACHE_DIR = (Join-Path $runtimeCacheRoot 'headroom')
        HEADROOM_RUNTIME_ROOT = $runtimeRoot
        HEADROOM_WORKSPACE_DIR = (Join-Path $runtimePrivateRoot 'headroom-workspace')
        HEADROOM_CONFIG_DIR = (Join-Path $runtimePrivateRoot 'headroom-config')
    }
    $quotedBrokerModuleRoot = '"' + $brokerModuleRoot + '"'
    $arguments = @('-m', 'uvicorn', 'kompress_broker.app:app', '--app-dir', $quotedBrokerModuleRoot, '--host', '127.0.0.1', '--port', $BrokerPort.ToString(), '--no-access-log')
    $process = Start-Process -FilePath $brokerPython -ArgumentList $arguments -WorkingDirectory $projectRoot -Environment $environment -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    # Warm-up: the broker's /compress contract requires {"content": "..."}.
    # The ASGI startup hook already triggers worker spawn + canary verify, but
    # an explicit valid warm request guarantees the worker is actually serving
    # before the readiness wait starts (an empty body returns 400 and spawns
    # nothing).
    $brokerWarmDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $brokerWarmDeadline) {
        try {
            $null = Invoke-WebRequest -Uri ($brokerUrl + '/compress') -Method Post -Body (@{ content = 'warmup' } | ConvertTo-Json) -ContentType 'application/json' -NoProxy -UseBasicParsing -TimeoutSec 30 -SkipHttpErrorCheck
        } catch { }
        if ((Get-JsonEndpoint -Url ($brokerUrl + '/readyz')).Body.ready -eq $true) { break }
        Start-Sleep -Milliseconds 1000
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $listenerPid = Get-ListenerPid -Port $BrokerPort
        if ($null -ne $listenerPid -and (Test-BrokerReady)) { break }
        try { $process.Refresh(); if ($process.HasExited) { throw 'broker_process_exited' } } catch { if ($_.Exception.Message -eq 'broker_process_exited') { throw } }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($null -eq $listenerPid -or -not (Test-BrokerReady) -or -not (Test-BrokerProcessIdentity -ProcessId $listenerPid)) {
        if ($null -ne $listenerPid -and (Test-BrokerProcessIdentity -ProcessId $listenerPid)) { [void](Stop-ManagedProcessGracefully -ProcessId $listenerPid) }
        throw 'broker_ready_timeout'
    }
    Write-BrokerState -ProcessId $listenerPid
    if (-not (Test-ManagedBrokerIdentity -ProcessId $listenerPid)) {
        [void](Stop-ManagedProcessGracefully -ProcessId $listenerPid)
        throw 'broker_identity_publish_failed'
    }
}

function Test-Ready {
    param(
        [switch]$ServiceScope,
        [switch]$AllowRelayPending
    )
    $brokerReady = Get-JsonEndpoint "$brokerUrl/readyz"
    $headroomLive = Get-JsonEndpoint "$headroomUrl/livez"
    $headroomHealth = Get-JsonEndpoint "$headroomUrl/health"
    $gatewayLive = Get-JsonEndpoint "$gatewayUrl/livez"
    $gatewayHealth = Get-JsonEndpoint "$gatewayUrl/health"
    $monitorStatus = Get-JsonEndpoint "$monitorUrl/status"
    $kompress = if ($headroomHealth.Body -and $headroomHealth.Body.PSObject.Properties['checks'] -and $headroomHealth.Body.checks.PSObject.Properties['kompress']) { $headroomHealth.Body.checks.kompress } else { $null }
    $kompressSourceStatus = [string](Get-PropertyValue -Object (Get-PropertyValue -Object $kompress -Name 'info') -Name 'source_status')
    $kompressReady = $null -ne $kompress -and (Get-PropertyValue -Object $kompress -Name 'enabled') -eq $true -and (Get-PropertyValue -Object $kompress -Name 'ready') -eq $true -and [string](Get-PropertyValue -Object $kompress -Name 'status') -ne 'deferred' -and $kompressSourceStatus -ne 'deferred'
    $gatewayReady = Test-GatewayReadinessSnapshot -Live $gatewayLive -Health $gatewayHealth -AllowRelayPending:$AllowRelayPending
    # Headroom's /health also probes the relay helper on 57321, which is owned
    # by the Codex++ client.  Before the client launches, that helper is
    # intentionally absent and Headroom reports 503 (degraded).  The pending
    # phase must accept exactly that missing-helper state instead of waiting
    # out a readiness timeout that can never pass until the client exists.
    $headroomHealthReady = $headroomHealth.TransportOk -and $null -ne $headroomHealth.Body -and (Get-PropertyValue -Object $headroomHealth.Body -Name 'ready') -eq $true -and $kompressReady
    if (-not $headroomHealthReady -and $AllowRelayPending) {
        $hrChecks = Get-PropertyValue -Object $headroomHealth.Body -Name 'checks'
        $hrHelper = Get-PropertyValue -Object $hrChecks -Name 'helper'
        $hrHelperOk = Get-PropertyValue -Object $hrHelper -Name 'ok'
        $hrHelperStatus = Get-PropertyValue -Object $hrHelper -Name 'status_code'
        $headroomHealthReady = (
            $headroomHealth.StatusCode -eq 503 -and
            $null -ne $hrHelper -and $hrHelperOk -eq $false -and $null -eq $hrHelperStatus
        )
    }
    $monitorContractReady = $monitorStatus.TransportOk -and $monitorStatus.StatusCode -eq 200 -and $null -ne $monitorStatus.Body -and [int](Get-PropertyValue -Object $monitorStatus.Body -Name 'schema_version') -eq 2 -and (Test-ManagedMonitorIdentity)
    $monitorOverall = [string](Get-PropertyValue -Object $monitorStatus.Body -Name 'overall')
    # Pre-client startup may observe red while Gateway/helper/route owners
    # are intentionally absent. Identity and schema remain mandatory; only
    # the explicit pending phase may accept red/yellow overall status.
    $monitorReady = $monitorContractReady -and (
        $monitorOverall -in @('green', 'yellow') -or
        ($AllowRelayPending -and $monitorOverall -in @('red', 'yellow'))
    )
    return (
        $brokerReady.TransportOk -and $brokerReady.StatusCode -eq 200 -and $null -ne $brokerReady.Body -and (Get-PropertyValue -Object $brokerReady.Body -Name 'ready') -eq $true -and
        $headroomLive.TransportOk -and $headroomLive.StatusCode -eq 200 -and $null -ne $headroomLive.Body -and (Get-PropertyValue -Object $headroomLive.Body -Name 'alive') -eq $true -and
        $headroomHealthReady -and
        $gatewayReady -and
        $monitorReady
    )
}

function Wait-StrictReadiness {
    param([Parameter(Mandatory)][DateTime]$DeadlineUtc)

    $deadline = $DeadlineUtc.ToUniversalTime()
    do {
        if (Test-Ready) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ($true)
    return $false
}

function Test-Listener {
    param([Parameter(Mandatory)][int]$Port)
    # Get-NetTCPConnection is very slow (~1.5s per call on this host).
    # Test-NetConnection performs a fast loopback TCP probe (~20ms).
    try {
        return [bool](Test-NetConnection -ComputerName '127.0.0.1' -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)
    }
    catch { return $false }
}

function Invoke-ManagerReadiness {
    if (-not (Test-Path -LiteralPath $startupGate -PathType Leaf)) {
        throw "startup_gate_missing:$startupGate"
    }
    if (-not (Test-Path -LiteralPath $managerExe -PathType Leaf)) {
        throw "manager_executable_missing:$managerExe"
    }
    if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) {
        throw "manager_config_missing:$managerConfig"
    }
    if (-not (Test-Path -LiteralPath $routeKeeper -PathType Leaf)) {
        throw "route_keeper_missing:$routeKeeper"
    }

    # The manager may already be open.  ReadinessOnly refreshes the watcher
    # and process-scoped route without launching a second manager or mutating
    # the supplier configuration.
    & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $startupGate `
        -Role manager `
        -ExePath $managerExe `
        -CodexHome $managerCodexHome `
        -ConfigPath $managerConfig `
        -RouteKeeperPath $routeKeeper `
        -RuntimeRoot $runtimeRoot `
        -BrokerBaseUrl $brokerUrl `
        -GatewayBaseUrl $gatewayUrl `
        -HeadroomBaseUrl $headroomUrl `
        -MonitorBaseUrl $monitorUrl `
        -EnsureScript $ensureScript `
        -RouteReadySignalPath $routeReadySignalPath `
        -RouteStatePath $routeStatePath `
        -RouteWatchStatePath $routeWatchStatePath `
        -RouteSettingsPath 'C:\Users\ma dao\.codex-session-delete\settings.json' `
        -StartupResultPath $startupResultPath `
        -AuditPath (Join-Path $runtimeLogRoot 'codexpp-manager-bootstrap.log') `
        -ReadinessOnly `
        -SkipEnsure `
        -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
        throw "manager_readiness_failed:$LASTEXITCODE"
    }
}

function Get-ExactExecutableProcesses {
    param([Parameter(Mandatory)][string[]]$ExecutablePaths)
    $expected = @{}
    $expectedNames = @{}
    foreach ($path in $ExecutablePaths) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $fullPath = [IO.Path]::GetFullPath($path)
            $expected[$fullPath.ToLowerInvariant()] = $true
            $expectedNames[[IO.Path]::GetFileName($fullPath).ToLowerInvariant()] = $true
        }
    }
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $processName = [string]$snapshot.Name
        if ([string]::IsNullOrWhiteSpace($processName) -or -not $expectedNames.ContainsKey($processName.ToLowerInvariant())) { continue }
        $path = [string]$snapshot.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-ProcessExecutablePath -ProcessId ([int]$snapshot.ProcessId) }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try { $normalized = [IO.Path]::GetFullPath($path).ToLowerInvariant() } catch { continue }
        if ($expected.ContainsKey($normalized)) {
            [void]$matches.Add([pscustomobject]@{
                    ProcessId = [int]$snapshot.ProcessId
                    ParentProcessId = [int]$snapshot.ParentProcessId
                    ExecutablePath = [IO.Path]::GetFullPath($path)
                    CommandLine = [string]$snapshot.CommandLine
                })
        }
    }
    return @($matches)
}

function Get-ManagedCodexState {
    if (-not (Test-Path -LiteralPath $managedCodexStatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $managedCodexStatePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-RouteStateContract {
    param(
        [Parameter(Mandatory)][string]$ExpectedConfigHash,
        [switch]$AllowPending
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedConfigHash) -or -not (Test-Path -LiteralPath $routeStatePath -PathType Leaf)) { return $false }
    try {
        $routeState = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json
        $allowedStatuses = if ($AllowPending) { @('ready', 'pending', 'official-bypass') } else { @('ready', 'official-bypass') }
        if ([string]$routeState.status -notin $allowedStatuses) { return $false }
        if ([string]$routeState.route_scope -ne 'process' -or [bool]$routeState.config_mutated) { return $false }
        return [string]$routeState.config_sha256 -eq $ExpectedConfigHash
    }
    catch { return $false }
}

function ConvertTo-UtcDateTimeValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue)) { return $null }
    $parsed = [DateTime]::Parse($textValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    return $parsed.ToUniversalTime()
}

function Wait-RouteStateContract {
    param(
        [Parameter(Mandatory)][string]$ExpectedConfigHash,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object]$ProtectedContractBefore,
        [double]$TimeoutSeconds = 30,
        [double]$PollIntervalSeconds = 0.5,
        [string]$FallbackConfigPath = 'C:\Users\ma dao\.codex\config.toml'
    )
    # P26 race: the one-shot route keeper and a freshly launched Manager may
    # both update config metadata around the same moment, so the route-state
    # config hash can lag the live config hash by a few hundred ms.  Poll the
    # contract (re-refreshing the route-state hash when the live hash moved)
    # instead of failing on the first stale observation.  The protected
    # supplier contract is re-verified on every attempt; any drift is a hard
    # fail-closed error, not a retry condition.
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $expectedHash = $ExpectedConfigHash
    while ([DateTime]::UtcNow -lt $deadline) {
        $liveHash = $null
        try {
            $liveHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
        }
        catch {
            # Config file temporarily missing/locked during the race window:
            # fail closed rather than surfacing an unclassified exception
            # that would bypass the route_state_contract error code.
            return $false
        }
        $liveProtected = Get-ConfigProtectedContract -Path $ConfigPath -FallbackPath $FallbackConfigPath
        if (-not (Test-ConfigProtectedContract -Before $ProtectedContractBefore -After $liveProtected)) {
            throw 'manager_config_protected_contract_changed_before_managed_state'
        }
        if ($liveHash -ne $expectedHash) {
            if (-not (Update-RouteStateConfigHash -ConfigHash $liveHash -ProtectedContract $liveProtected)) {
                # Refresh failed (e.g. route-state missing or contract
                # incompatible): fail closed instead of polling against a
                # route-state that can never satisfy the expected hash.
                return $false
            }
            $expectedHash = $liveHash
        }
        if (Test-RouteStateContract -ExpectedConfigHash $expectedHash -AllowPending) {
            return $true
        }
        Start-Sleep -Milliseconds ([Math]::Max(50, [int]($PollIntervalSeconds * 1000)))
    }
    return $false
}

function Invoke-OfficialRoutePinning {
    param(
        [string]$OfficialConfigPath = 'C:\Users\ma dao\.codex\config.toml',
        [string]$GatewayBaseUrl = 'http://127.0.0.1:18787/v1'
    )
    # Reasonix managed-chain route pinning: after every startup (and after any
    # manager-side supplier switch that rewrites the official config), force
    # the official app-server's codex_local_access provider to point at the
    # local Gateway so the official dataplane always goes through Headroom.
    # The manager's supplier base_url/key (settings.json relayProfiles) is
    # left untouched - this only rewrites the routing provider in the OFFICIAL
    # home config.  Fail-open: never block startup on pinning errors.
    if (-not (Test-Path -LiteralPath $OfficialConfigPath -PathType Leaf)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($OfficialConfigPath)
        # Match base_url strictly inside the codex_local_access section
        # ([^\[]* stops at the next section header), so a missing base_url in
        # this section can never leak the rewrite into a neighbouring
        # provider section.
        $pattern = '(?ms)(\[model_providers\.codex_local_access\][^\[]*?base_url\s*=\s*")[^"]*(")'
        if (-not ($text -match $pattern)) {
            Write-Timing "official route pinning: codex_local_access section not found (skip)" 0
            return $false
        }
        $updated = $text -replace $pattern, ('${1}' + $GatewayBaseUrl + '${2}')
        if ($updated -eq $text) { return $true }
        [IO.File]::WriteAllText($OfficialConfigPath, $updated, [Text.UTF8Encoding]::new($false))
        $check = [IO.File]::ReadAllText($OfficialConfigPath)
        $checkPattern = '(?ms)\[model_providers\.codex_local_access\][^\[]*?base_url\s*=\s*"([^"]+)"'
        $checkMatch = [regex]::Match($check, $checkPattern)
        $pinned = $checkMatch.Success -and $checkMatch.Groups[1].Value -eq $GatewayBaseUrl
        Write-Timing ("official route pinning: base_url -> {0} pinned={1}" -f $GatewayBaseUrl, $pinned) 0
        return $pinned
    }
    catch {
        Write-Timing ("official route pinning failed (fail-open): {0}" -f $_.Exception.Message) 0
        return $false
    }
}

function Test-ManagedCodexProcesses {
    $state = Get-ManagedCodexState
    if ($null -eq $state -or [int]$state.schema_version -ne 1) { return $false }
    $stateEntries = @($state.processes)
    if ($stateEntries.Count -ne 2) { return $false }

    # A stale state file must never make an arbitrary same-path process look
    # managed.  The exact executable inventory is the source of truth for
    # cardinality: one Manager and one Client, no extra copies.
    try {
        $currentProcesses = @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))
    }
    catch { return $false }
    if ($currentProcesses.Count -ne 2) { return $false }
    foreach ($expectedPathValue in @($managerExe, $clientExe)) {
        try { $normalizedExpectedPath = [IO.Path]::GetFullPath($expectedPathValue) }
        catch { return $false }
        if (@($currentProcesses | Where-Object {
                try { [string]::Equals([IO.Path]::GetFullPath([string]$_.ExecutablePath), $normalizedExpectedPath, [StringComparison]::OrdinalIgnoreCase) }
                catch { $false }
            }).Count -ne 1) {
            return $false
        }
    }

    $seenProcessIds = @{}
    foreach ($current in $currentProcesses) {
        $processId = [int]$current.ProcessId
        if ($processId -le 0 -or $seenProcessIds.ContainsKey([string]$processId)) { return $false }
        $seenProcessIds[[string]$processId] = $true
        $entry = @($stateEntries | Where-Object {
                $entryId = 0
                [int]::TryParse([string]$_.pid, [ref]$entryId) -and $entryId -eq $processId
            } | Select-Object -First 1)
        if ($entry.Count -ne 1) { return $false }
        try {
            $actualPath = [IO.Path]::GetFullPath([string]$current.ExecutablePath)
            $expectedPath = [IO.Path]::GetFullPath([string]$entry[0].executable_path)
        }
        catch { return $false }
        if (-not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { return $false }
        try {
            $expectedStarted = ConvertTo-UtcDateTimeValue -Value $entry[0].started_at_utc
            if ($null -eq $expectedStarted) { return $false }
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStarted).TotalSeconds) -gt 2) { return $false }
        }
        catch { return $false }
    }
    return $seenProcessIds.Count -eq 2
}

function Test-StaleRouteKeeperIdentity {
    param(
        [AllowNull()][object]$State,
        [AllowNull()][object]$Process,
        [AllowNull()][string]$CommandLine
    )
    if ($null -eq $State -or $null -eq $Process) { return $false }
    $stateKeeperProperty = $State.PSObject.Properties['route_keeper_script_path']
    $stateModeProperty = $State.PSObject.Properties['route_keeper_mode']
    $stateKeeperPath = if ($stateKeeperProperty) { [string]$stateKeeperProperty.Value } else { '' }
    $stateMode = if ($stateModeProperty) { [string]$stateModeProperty.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($stateKeeperPath)) {
        $legacyKeeperProperty = $State.PSObject.Properties['route_keeper_path']
        $legacyModeProperty = $State.PSObject.Properties['mode']
        $stateKeeperPath = if ($legacyKeeperProperty) { [string]$legacyKeeperProperty.Value } else { '' }
        $stateMode = if ($legacyModeProperty) { [string]$legacyModeProperty.Value } else { '' }
        if ($stateMode -ne 'proxy') { return $false }
    }
    elseif ($stateMode -ne 'watch') { return $false }
    if ([string]::IsNullOrWhiteSpace($stateKeeperPath)) { return $false }
    try {
        if (-not [IO.Path]::GetFullPath($stateKeeperPath).Equals([IO.Path]::GetFullPath($routeKeeper), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    catch { return $false }
    $actualPath = [string]$Process.Path
    if ([string]::IsNullOrWhiteSpace($actualPath)) {
        $actualPath = Get-ProcessExecutablePath -ProcessId ([int]$Process.Id)
    }
    try { $actualName = [IO.Path]::GetFileName([IO.Path]::GetFullPath($actualPath)) } catch { return $false }
    if ($actualName -notin @('pwsh.exe', 'powershell.exe')) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
        $normalizedCommandLine = $CommandLine.Replace('/', '\')
        if ($normalizedCommandLine.IndexOf(([IO.Path]::GetFullPath($routeKeeper).Replace('/', '\')), [StringComparison]::OrdinalIgnoreCase) -lt 0 -or $normalizedCommandLine -notmatch '(?i)(^|\s)-Watch(\s|$)') { return $false }
    }
    return $true
}

function Stop-StaleRouteKeeper {
    # A route watcher is only safe to reclaim after the exact Codex++ owner
    # set is empty.  This prevents a healthy managed session from being
    # interrupted while still removing abandoned mutex holders on cold start.
    if (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe)).Count -gt 0) { return }
    $routeState = $null
    if (Test-Path -LiteralPath $routeStatePath -PathType Leaf) {
        try { $routeState = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json } catch { $routeState = $null }
    }
    $watchState = $null
    if (Test-Path -LiteralPath $routeWatchStatePath -PathType Leaf) {
        try { $watchState = Get-Content -LiteralPath $routeWatchStatePath -Raw | ConvertFrom-Json } catch { $watchState = $null }
    }
    $candidatePid = 0
    foreach ($candidate in @(
            if ($watchState) { $watchState.pid } else { $null }
            if ($routeState) { $routeState.route_keeper_pid } else { $null }
        )) {
        if ([int]::TryParse([string]$candidate, [ref]$candidatePid) -and $candidatePid -gt 0) { break }
        $candidatePid = 0
    }
    if ($candidatePid -le 0) { return }
    $process = Get-Process -Id $candidatePid -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        foreach ($stalePath in @($routeWatchStatePath, $routeReadySignalPath)) {
            Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue
        }
        return
    }
    $stateForIdentity = if ($routeState) { $routeState } else { $watchState }
    $commandLine = Get-ProcessCommandLine -ProcessId $candidatePid
    if (-not (Test-StaleRouteKeeperIdentity -State $stateForIdentity -Process $process -CommandLine $commandLine)) {
        throw 'stale_route_keeper_identity_ambiguous'
    }
    if (-not (Stop-ManagedProcessGracefully -ProcessId $candidatePid)) { throw "stale_route_keeper_shutdown_failed:$candidatePid" }
    foreach ($stalePath in @($routeWatchStatePath, $routeReadySignalPath)) {
        Remove-Item -LiteralPath $stalePath -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-DirectProcessRestart {
    $shell = New-Object -ComObject WScript.Shell
    $choice = $shell.Popup(
        'Codex++ is running outside the managed Headroom launch chain. Restart Manager and Codex++ through Headroom now?',
        0,
        'Headroom for Codex++',
        49
    )
    return $choice -eq 1
}

function Stop-ExactExecutableProcesses {
    param([Parameter(Mandatory)][object[]]$Snapshots)
    foreach ($snapshot in $Snapshots) {
        $processId = [int]$snapshot.ProcessId
        $expectedPath = [IO.Path]::GetFullPath([string]$snapshot.ExecutablePath)
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        [void]$process.CloseMainWindow()
        try { [void]$process.WaitForExit(8000) } catch { }
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            $current = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $current) { continue }
            try { $currentPath = [IO.Path]::GetFullPath((Get-ProcessExecutablePath -ProcessId $processId)) } catch { throw "codex_process_identity_lost:$processId" }
            if (-not [string]::Equals($currentPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw "codex_process_identity_changed:$processId" }
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
    }
}

function Write-ManagedCodexState {
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($snapshot in @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))) {
        $process = Get-Process -Id ([int]$snapshot.ProcessId) -ErrorAction Stop
        [void]$entries.Add([ordered]@{
            pid = [int]$snapshot.ProcessId
            executable_path = [IO.Path]::GetFullPath([string]$snapshot.ExecutablePath)
            started_at_utc = $process.StartTime.ToUniversalTime().ToString('o')
        })
    }
    if ($entries.Count -ne 2) { throw 'managed_codex_process_count_invalid' }
    $document = [ordered]@{
        schema_version = 1
        route_scope = 'process'
        route_state_path = $routeStatePath
        source_hashes = $sourceHashesBefore
        processes = @($entries)
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = Join-Path $runtimeStateRoot ('.managed-codex-' + [IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temporary, (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $managedCodexStatePath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-PhaseBActivation {
    if (-not $PhaseB) {
        return [ordered]@{ requested = $false; status = 'not_requested' }
    }
    if ($ServicesOnly) { throw 'phase_b_requires_full_start' }
    if (-not (Test-Path -LiteralPath $aggregateRemovalScript -PathType Leaf)) { throw "phase_b_remove_script_missing:$aggregateRemovalScript" }
    if (-not (Test-Path -LiteralPath $indicatorRegisterScript -PathType Leaf)) { throw "phase_b_indicator_script_missing:$indicatorRegisterScript" }
    if (-not (Test-Path -LiteralPath $aggregateSettingsPath -PathType Leaf)) { throw "phase_b_settings_missing:$aggregateSettingsPath" }
    if (-not (Test-Path -LiteralPath $indicatorMetadataPath -PathType Leaf)) { throw "phase_b_indicator_metadata_missing:$indicatorMetadataPath" }
    $runningCodex = @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))
    if ($runningCodex.Count -gt 0) { throw 'phase_b_requires_codexpp_quiescent' }

    $startedAt = [DateTime]::UtcNow.ToString('o')
    try {
        $removeOutput = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $aggregateRemovalScript `
            -SettingsPath $aggregateSettingsPath `
            -BackupPath $aggregateBackupPath `
            -Execute -PhaseB)
        if ($LASTEXITCODE -ne 0) { throw "phase_b_aggregate_removal_failed:$LASTEXITCODE" }
        $registerOutput = @(& pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $indicatorRegisterScript `
            -MetadataPath $indicatorMetadataPath `
            -UserScriptsDir $indicatorUserScriptsDir `
            -BackupPath $indicatorBackupPath `
            -Execute)
        if ($LASTEXITCODE -ne 0) { throw "phase_b_indicator_registration_failed:$LASTEXITCODE" }
        $result = [ordered]@{
            schema = 'headroom-phase-b-activation/v1'
            requested = $true
            status = 'succeeded'
            started_at_utc = $startedAt
            aggregate_removal_invoked = $true
            indicator_registration_invoked = $true
            settings_sha256_after = (Get-FileHash -LiteralPath $aggregateSettingsPath -Algorithm SHA256).Hash
            indicator_metadata_sha256_after = (Get-FileHash -LiteralPath $indicatorMetadataPath -Algorithm SHA256).Hash
            indicator_runtime_path = (Join-Path $indicatorUserScriptsDir 'headroom-status-indicator.js')
            aggregate_output_lines = $removeOutput.Count
            indicator_output_lines = $registerOutput.Count
            completed_at_utc = [DateTime]::UtcNow.ToString('o')
        }
        Write-PhaseBResult -Document $result
        return $result
    }
    catch {
        $failure = [ordered]@{
            schema = 'headroom-phase-b-activation/v1'
            requested = $true
            status = 'failed'
            started_at_utc = $startedAt
            error_code = [string]$_.Exception.Message
            completed_at_utc = [DateTime]::UtcNow.ToString('o')
        }
        Write-PhaseBResult -Document $failure
        throw
    }
}

function Focus-ManagedCodexWindow {
    $state = Get-ManagedCodexState
    if ($null -eq $state) { return }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($entry in @($state.processes)) {
        if ([string]$entry.executable_path -like '*codex-plus-plus.exe') {
            [void]$shell.AppActivate([int]$entry.pid)
            return
        }
    }
}

try {
    try {
        $startMutexHeld = $startMutex.WaitOne([TimeSpan]::FromSeconds(15))
    }
    catch [Threading.AbandonedMutexException] {
        $startMutexHeld = $true
    }
    if (-not $startMutexHeld) { throw 'startup_mutex_busy' }
    $patchSyncReceipt = Invoke-HeadroomPatchSync
    $sourceHashesBefore = Get-ManagedSourceHashes
    $phaseBActivation = Invoke-PhaseBActivation
    $managedAlready = $false
    if (-not $ServicesOnly) {
        $managedAlready = Test-ManagedCodexProcesses
        $existingCodexProcesses = @(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe, $clientExe))
        if ($existingCodexProcesses.Count -gt 0 -and -not $managedAlready) {
            # The exact Manager/Client may have restarted outside the startup
            # chain, leaving a stale snapshot.  When the live set is precisely
            # one Manager and one Client at the expected paths, refresh the
            # snapshot atomically instead of forcing a verified restart.
            $managerCount = @($existingCodexProcesses | Where-Object {
                    try { [string]::Equals([IO.Path]::GetFullPath([string]$_.ExecutablePath), [IO.Path]::GetFullPath($managerExe), [StringComparison]::OrdinalIgnoreCase) } catch { $false }
                }).Count
            $clientCount = @($existingCodexProcesses | Where-Object {
                    try { [string]::Equals([IO.Path]::GetFullPath([string]$_.ExecutablePath), [IO.Path]::GetFullPath($clientExe), [StringComparison]::OrdinalIgnoreCase) } catch { $false }
                }).Count
            if ($existingCodexProcesses.Count -eq 2 -and $managerCount -eq 1 -and $clientCount -eq 1) {
                Write-ManagedCodexState
                $managedAlready = Test-ManagedCodexProcesses
            }
            if (-not $managedAlready) {
                if (-not (Confirm-DirectProcessRestart)) { throw 'direct_process_restart_cancelled' }
                Stop-ExactExecutableProcesses -Snapshots $existingCodexProcesses
                Remove-Item -LiteralPath $managedCodexStatePath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $managedAlready) { Stop-StaleRouteKeeper }
    }
    [Environment]::SetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', $brokerUrl, 'Process')

    # The broker is a hard gate.  Headroom is never allowed to start against
    # the helper directly or while the provider canary is deferred.
    $phaseSw = [Diagnostics.Stopwatch]::StartNew()
    $timingLog = Join-Path $runtimeLogRoot 'startup-timing.log'
    function Write-Timing([string]$Label, [double]$Seconds) { try { [IO.File]::AppendAllText($timingLog, "$(Get-Date -Format 'HH:mm:ss.fff') [$Label] $([Math]::Round($Seconds,1))s`n", [Text.UTF8Encoding]::new($false)) } catch { } }
    # Fast path: when the managed Manager/Client chain is already running, the
    # services it depends on (broker/Headroom/Gateway/monitor) must already be
    # listening - a live managed chain cannot exist without them.  Skip the
    # full ensure sequence and only verify the four service ports are bound.
    # Any missing port falls back to the full ensure path.
    $fastPathServicesOk = $false
    if ($managedAlready -and -not $ServicesOnly) {
        $servicePortsOk = $true
        foreach ($svcPort in @($BrokerPort, 18787, 18789, 18788)) {
            if (-not (Test-Listener -Port $svcPort)) { $servicePortsOk = $false; break }
        }
 if ($servicePortsOk) {
 $fastPathServicesOk = $true
 Write-Timing 'fast-path services check' $phaseSw.Elapsed.TotalSeconds
 }
 }
 # Port presence alone is not proof that the currently running services loaded
 # the current source or environment contract. Always run the managed-service
 # validators so stale Headroom/Gateway/Broker instances are reconciled.
 $fastPathServicesOk = $false
 if (-not $fastPathServicesOk) {
    Ensure-KompressBroker
    Write-Timing 'Ensure-KompressBroker' $phaseSw.Elapsed.TotalSeconds
    $phaseSw.Restart()

    if (-not (Test-Path -LiteralPath $ensureScript -PathType Leaf)) {
        throw "ensure_script_missing:$ensureScript"
    }

    # The ensure script is idempotent and refuses unmanaged port conflicts.
    & $ensureScript `
        -Port 18787 `
        -HeadroomPort 18789 `
        -Workers $Workers `
        -PythonPath $brokerPython `
        -RuntimeStateRoot $runtimeStateRoot `
        -RuntimeLogRoot $runtimeLogRoot `
        -KompressEndpoint $brokerUrl `
        -AllowRelayPending
    Write-Timing "ensureScript(Headroom+Gateway)" $phaseSw.Elapsed.TotalSeconds
    $phaseSw.Restart()

    Ensure-Monitor
    Write-Timing "Ensure-Monitor" $phaseSw.Elapsed.TotalSeconds
    $phaseSw.Restart()
    } # end of full ensure path (fast path skips ensure entirely)
    Write-Timing "Test-Ready loop entered" 0
    $phaseSw.Restart()
    $readyOk = $fastPathServicesOk
    if (-not $readyOk) {
        $deadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Ready -ServiceScope:$ServicesOnly -AllowRelayPending) { $readyOk = $true; break }
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Timing "Test-Ready loop exited" $phaseSw.Elapsed.TotalSeconds
    if (-not $readyOk) {
        throw 'readiness_failed'
    }

    if (-not $ServicesOnly) {
        # Pin the official app-server route to the local Gateway BEFORE the
        # protected-contract snapshot, so disk state, contract, and
        # route-state all agree on the pinned base_url from the start.  This
        # also re-pins any supplier base_url the Manager wrote during a relay
        # switch in a previous session.  Fail-open: a pin failure never
        # blocks startup (it surfaces as bypass_vortex in the monitor).
        $null = Invoke-OfficialRoutePinning
        if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) { throw "manager_config_missing:$managerConfig" }
        $managerConfigHashBefore = (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($managerConfigHashBefore)) { throw 'manager_config_hash_unavailable' }
        $managerConfigProtectedBefore = Get-ConfigProtectedContract -Path $managerConfig -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        if (-not $managerConfigProtectedBefore.Exists -or $null -ne $managerConfigProtectedBefore.Error) { throw "manager_config_protected_contract_unavailable:$($managerConfigProtectedBefore.Error)" }
        if (-not (Test-Path -LiteralPath $managerBootstrap -PathType Leaf)) {
            throw "manager_bootstrap_missing:$managerBootstrap"
        }
        if (-not $managedAlready) {
            if (-not (Test-Path -LiteralPath $clientBootstrap -PathType Leaf)) { throw "client_bootstrap_missing:$clientBootstrap" }
            $managerArgs = "//B //Nologo `"$managerBootstrap`""
            Write-Timing "launch manager bootstrap" 0
            $phaseSw.Restart()
            Start-Process -FilePath 'wscript.exe' -ArgumentList $managerArgs -WindowStyle Hidden | Out-Null
            $managerDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            while (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe)).Count -eq 0 -and [DateTime]::UtcNow -lt $managerDeadline) { Start-Sleep -Milliseconds 500 }
            Write-Timing "manager process observed" $phaseSw.Elapsed.TotalSeconds
            if (@(Get-ExactExecutableProcesses -ExecutablePaths @($managerExe)).Count -ne 1) { throw 'manager_process_not_observed' }
            $clientArgs = "//B //Nologo `"$clientBootstrap`" -AllowRelayPending"
            $phaseSw.Restart()
            Start-Process -FilePath 'wscript.exe' -ArgumentList $clientArgs -WindowStyle Hidden | Out-Null
            $clientDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            while (@(Get-ExactExecutableProcesses -ExecutablePaths @($clientExe)).Count -eq 0 -and [DateTime]::UtcNow -lt $clientDeadline) { Start-Sleep -Milliseconds 500 }
            Write-Timing "client process observed" $phaseSw.Elapsed.TotalSeconds
            if (@(Get-ExactExecutableProcesses -ExecutablePaths @($clientExe)).Count -ne 1) { throw 'client_process_not_observed' }
        }
        # Publish exact Manager/client identity before the final monitor gate
        # so the monitor can distinguish a missing state file from an actual
        # unmanaged process. Route state may still be pending here, but it
        # must remain process-scoped, immutable, and hash-bound.
        # Manager may publish ordinary metadata while the one-shot keeper is
        # returning.  Refresh only the route-state hash, after rechecking the
        # protected supplier contract, before publishing managed process state.
        # P26 race: poll the route-state contract inside a bounded window so a
        # late Manager/route-keeper metadata write does not fail the launch.
        $managerConfigHashAtState = (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash
        $managerConfigProtectedAtState = Get-ConfigProtectedContract -Path $managerConfig -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        if (-not (Test-ConfigProtectedContract -Before $managerConfigProtectedBefore -After $managerConfigProtectedAtState)) { throw 'manager_config_protected_contract_changed_before_managed_state' }
        # P26 race: poll the route-state contract inside a bounded window so a
        # late Manager/route-keeper metadata write does not fail the launch.
        if (-not (Wait-RouteStateContract -ExpectedConfigHash $managerConfigHashAtState -ConfigPath $managerConfig -ProtectedContractBefore $managerConfigProtectedBefore -TimeoutSeconds ([Math]::Min(30, $ReadinessTimeoutSeconds)))) { throw 'route_state_contract_invalid_before_managed_state' }
        if (-not $managedAlready) {
            Write-ManagedCodexState
        }
        if (-not (Test-ManagedCodexProcesses)) { throw 'managed_codex_state_identity_invalid_before_final_readiness' }

        # The relay is mandatory once a client is expected. The monitor may
        # need one poll to observe the freshly published managed state, so
        # wait within the existing startup budget while keeping this strict:
        # no AllowRelayPending and no red/yellow acceptance.
        # Fast path: when the chain is already managed, strict post-client
        # readiness and manager re-validation were already satisfied by the
        # launch that created the running chain; re-running them only adds
        # startup latency on every double-click.
        if (-not $managedAlready) {
            $postClientDeadline = [DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
            if (-not (Wait-StrictReadiness -DeadlineUtc $postClientDeadline)) { throw 'readiness_failed_after_client' }
            Invoke-ManagerReadiness
        }
        else {
            # Still confirm the managed identity and route contract quickly.
            if (-not (Test-ManagedCodexProcesses)) { throw 'managed_codex_state_identity_invalid_after_readiness' }
            if (-not (Test-RouteStateContract -ExpectedConfigHash $managerConfigHashAtState)) { throw 'route_state_not_ready_or_config_hash_mismatch' }
        }
        if (-not (Test-SourceHashesUnchanged -Expected $sourceHashesBefore)) { throw 'source_hash_changed_during_startup' }
        if (-not (Test-Path -LiteralPath $managerConfig -PathType Leaf)) { throw 'manager_config_missing_after_start' }
        $configHashAfter = (Get-FileHash -LiteralPath $managerConfig -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($configHashAfter)) { throw 'manager_config_hash_unavailable' }
        $managerConfigHashAfter = $configHashAfter
        $managerConfigProtectedAfter = Get-ConfigProtectedContract -Path $managerConfig -FallbackPath 'C:\Users\ma dao\.codex\config.toml'
        if (-not (Test-ConfigProtectedContract -Before $managerConfigProtectedBefore -After $managerConfigProtectedAfter)) { throw 'manager_config_protected_contract_changed_during_startup' }
        $managerConfigChangedByManager = $configHashAfter -ne $managerConfigHashBefore
        if ($managerConfigChangedByManager -and -not (Update-RouteStateConfigHash -ConfigHash $configHashAfter -ProtectedContract $managerConfigProtectedAfter)) { throw 'route_state_config_hash_refresh_failed_after_manager' }
        if (-not (Test-RouteStateContract -ExpectedConfigHash $configHashAfter)) { throw 'route_state_not_ready_or_config_hash_mismatch' }
        if (-not (Test-ManagedCodexProcesses)) { throw 'managed_codex_state_identity_invalid_after_readiness' }
        if ($managedAlready) { Focus-ManagedCodexWindow }
    }

    # Pin the official app-server route to the local Gateway so the official
    # dataplane goes through Headroom on every launch (supplier base_url/key
    # in the manager settings stay untouched).
    $null = Invoke-OfficialRoutePinning

    $startStage = if ($ServicesOnly) { 'services_ready' } elseif ($managedAlready) { 'already_managed' } else { 'manager_and_client_launched' }
    Write-StartResult -Status succeeded -Stage $startStage -ErrorCode ''
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    Write-StartResult -Status failed -Stage 'startup' -ErrorCode 'headroom_start_failed' -Detail $message
    Write-Error $message
    exit 1
}
finally {
    if ($startMutexHeld) {
        try { $startMutex.ReleaseMutex() } catch { }
    }
    $startMutex.Dispose()
    [Environment]::SetEnvironmentVariable('HEADROOM_KOMPRESS_ENDPOINT', $previousKompressEndpoint, 'Process')
}
