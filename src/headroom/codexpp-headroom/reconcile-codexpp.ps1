[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$PrimaryConfigPath = 'C:\Users\ma dao\.codex\config.toml',
    [switch]$IncludePrimaryCodex,
    [string]$ExpectedProxyBaseUrl = '',
    [string]$ExpectedWorkspacePath = '',
    [string]$ExpectedLauncherPath = '',
    # Retained as no-op compatibility parameters for callers of the former
    # writer.  They are never used to construct or persist configuration.
    [string]$PythonPath = '',
    [string]$LauncherPath = '',
    [string]$WorkspacePath = '',
    [string]$BackupRoot = ''
)

<#
    Read-only compatibility verifier.

    This script deliberately has no configuration writer, TOML builder,
    backup/replace path, or staging file.  It reads the selected config twice,
    reports its SHA-256 before/after, and verifies only the existing contract.
    Route selection is process-scoped and belongs to the startup gate; this
    compatibility command must never repair a provider configuration.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = if ($IncludePrimaryCodex) { $PrimaryConfigPath } else { 'C:\Users\ma dao\.codex-plus-plus-cli\config.toml' }
}
if ([string]::IsNullOrWhiteSpace($ExpectedLauncherPath) -and -not [string]::IsNullOrWhiteSpace($LauncherPath)) {
    $ExpectedLauncherPath = $LauncherPath
}

function Get-ConfigHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
    catch { return '' }
}

function Get-ConfigText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'config_missing'
    }
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Get-QuotedValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [string]$Section = ''
    )

    $sectionText = $Text
    if (-not [string]::IsNullOrWhiteSpace($Section)) {
        $escapedSection = [regex]::Escape($Section)
        $sectionMatch = [regex]::Match($Text, '(?ims)^\s*' + $escapedSection + '\s*(?<body>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) { return $null }
        $sectionText = $sectionMatch.Groups['body'].Value
    }
    $escapedKey = [regex]::Escape($Key)
    $keyMatch = [regex]::Match($sectionText, '(?im)^\s*' + $escapedKey + '\s*=\s*(?:"(?<double>[^"]*)"|''(?<single>[^'']*)'')\s*(?:#.*)?$')
    if (-not $keyMatch.Success) { return $null }
    if ($keyMatch.Groups['double'].Success) { return $keyMatch.Groups['double'].Value }
    return $keyMatch.Groups['single'].Value
}

function Get-ArrayValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Key,
        [string]$Section = ''
    )

    $sectionText = $Text
    if (-not [string]::IsNullOrWhiteSpace($Section)) {
        $escapedSection = [regex]::Escape($Section)
        $sectionMatch = [regex]::Match($Text, '(?ims)^\s*' + $escapedSection + '\s*(?<body>.*?)(?=^\s*\[|\z)')
        if (-not $sectionMatch.Success) { return $null }
        $sectionText = $sectionMatch.Groups['body'].Value
    }
    $escapedKey = [regex]::Escape($Key)
    $keyMatch = [regex]::Match($sectionText, '(?ims)^\s*' + $escapedKey + '\s*=\s*\[(?<body>[^\]]*)\]')
    if (-not $keyMatch.Success) { return $null }
    $values = @()
    foreach ($match in [regex]::Matches($keyMatch.Groups['body'].Value, '"(?<value>[^"]*)"|''(?<single>[^'']*)''')) {
        $values += if ($match.Groups['value'].Success) { $match.Groups['value'].Value } else { $match.Groups['single'].Value }
    }
    return $values
}

function Test-ConfigCompatibility {
    param([Parameter(Mandatory)][string]$Text)

    $errors = [System.Collections.Generic.List[string]]::new()
    $provider = Get-QuotedValue -Text $Text -Key 'model_provider'
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = 'CodexPlusPlus' }
    $providerSection = '[model_providers.' + $provider + ']'
    $wireApi = Get-QuotedValue -Text $Text -Key 'wire_api' -Section $providerSection
    $baseUrl = Get-QuotedValue -Text $Text -Key 'base_url' -Section $providerSection
    $websocketMatch = [regex]::Match($Text, '(?ims)^\s*' + [regex]::Escape($providerSection) + '\s*(?<body>.*?)(?=^\s*\[|\z)')
    $supportsWebsockets = $null
    if ($websocketMatch.Success) {
        $socketMatch = [regex]::Match($websocketMatch.Groups['body'].Value, '(?im)^\s*supports_websockets\s*=\s*(?<value>true|false)\s*(?:#.*)?$')
        if ($socketMatch.Success) { $supportsWebsockets = $socketMatch.Groups['value'].Value.ToLowerInvariant() -eq 'true' }
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) { [void]$errors.Add('provider_base_url_missing') }
    if ($wireApi -ne 'responses') { [void]$errors.Add('provider_wire_api_mismatch') }

    $mcpSection = '[mcp_servers.headroom]'
    $command = Get-QuotedValue -Text $Text -Key 'command' -Section $mcpSection
    $args = @(Get-ArrayValue -Text $Text -Key 'args' -Section $mcpSection)

    return [pscustomobject]@{
        Compatible = ($errors.Count -eq 0)
        Errors = @($errors)
        Provider = $provider
        BaseUrl = $baseUrl
        MatchesExpectedProxy = (-not [string]::IsNullOrWhiteSpace($ExpectedProxyBaseUrl) -and $baseUrl -eq $ExpectedProxyBaseUrl)
        WireApi = $wireApi
        SupportsWebsockets = $supportsWebsockets
        MpcCommand = $command
        MpcArgs = $args
    }
}

$beforeHash = ''
$afterHash = ''
$compatibility = $null
try {
    $beforeHash = Get-ConfigHash -Path $ConfigPath
    if ([string]::IsNullOrWhiteSpace($beforeHash)) { throw 'config_missing_or_unreadable' }
    $beforeText = Get-ConfigText -Path $ConfigPath
    $compatibility = Test-ConfigCompatibility -Text $beforeText

    # Re-read the same file; no temporary or candidate config is ever made.
    $afterText = Get-ConfigText -Path $ConfigPath
    $afterHash = Get-ConfigHash -Path $ConfigPath
    $hashUnchanged = $beforeHash -eq $afterHash -and $beforeText -eq $afterText
    $isCompatible = $hashUnchanged -and $compatibility.Compatible
    Write-Output 'STATUS=READ_ONLY'
    Write-Output 'READ_ONLY=true'
    Write-Output ("COMPATIBLE={0}" -f ([bool]$isCompatible).ToString().ToLowerInvariant())
    Write-Output ("CONFIG_HASH_UNCHANGED={0}" -f ([bool]$hashUnchanged).ToString().ToLowerInvariant())
    Write-Output "BEFORE_SHA256=$beforeHash"
    Write-Output "AFTER_SHA256=$afterHash"
    Write-Output ("ERROR_CODE={0}" -f ($(if ($isCompatible) { '' } elseif (-not $hashUnchanged) { 'config_changed_during_read' } else { ($compatibility.Errors -join ',') })))
    Write-Output ("PROVIDER={0}" -f $compatibility.Provider)
    Write-Output ("WIRE_API={0}" -f $compatibility.WireApi)
    Write-Output ("BASE_URL_PRESENT={0}" -f ([bool](-not [string]::IsNullOrWhiteSpace($compatibility.BaseUrl))).ToString().ToLowerInvariant())
    exit ([int](-not $isCompatible))
}
catch {
    if ([string]::IsNullOrWhiteSpace($afterHash)) { $afterHash = $beforeHash }
    Write-Output 'STATUS=READ_ONLY'
    Write-Output 'READ_ONLY=true'
    Write-Output 'COMPATIBLE=false'
    Write-Output 'CONFIG_HASH_UNCHANGED=false'
    Write-Output "BEFORE_SHA256=$beforeHash"
    Write-Output "AFTER_SHA256=$afterHash"
    Write-Output ("ERROR_CODE={0}" -f ([string]$_.Exception.Message))
    exit 1
}
