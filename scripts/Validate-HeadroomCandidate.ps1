[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RelativeProjectPath {
    param([string]$FullPath)
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($FullPath)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'candidate_path_outside_project_root'
    }
    return ([IO.Path]::GetRelativePath($root, $full)).Replace('\', '/')
}

function Get-CanonicalEntriesText {
    param([object[]]$Entries)
    $normalized = @($Entries | ForEach-Object {
            [ordered]@{
                path       = [string]$_.path
                size_bytes = [int64]$_.size_bytes
                sha256     = ([string]$_.sha256).ToLowerInvariant()
            }
        } | Sort-Object -Property @{ Expression = { [string]$_['path'] } })
    return (($normalized | ForEach-Object {
                "{0}`t{1}`t{2}" -f $_.path, $_.size_bytes, $_.sha256
            }) -join "`n")
}

try {
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $manifestFull = [IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
        throw 'manifest_missing'
    }
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
    if ($manifest.version -ne 1 -or $manifest.algorithm -ne 'sha256') {
        throw 'manifest_schema_invalid'
    }
    $kindProperty = $manifest.PSObject.Properties['candidate_kind']
    if ($null -eq $kindProperty) {
        throw 'manifest_candidate_contract_missing'
    }
    $candidateKind = [string]$manifest.candidate_kind
    if ($candidateKind -in @('source', 'release', 'canary')) {
        throw 'manifest_candidate_kind_legacy_value'
    }
    if ($candidateKind -notin @('simple', 'complex', 'build')) {
        throw 'manifest_candidate_kind_invalid'
    }
    $profileProperty = $manifest.PSObject.Properties['candidate_profile']
    if ($null -eq $profileProperty) {
        throw 'manifest_candidate_contract_missing'
    }
    $candidateProfile = [string]$manifest.candidate_profile
    if ($candidateProfile -notin @('source', 'release', 'canary')) {
        throw 'manifest_candidate_profile_invalid'
    }
    $entries = @($manifest.entries)
    if ($entries.Count -eq 0) {
        throw 'manifest_entries_empty'
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $drift = [Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $relative = [string]$entry.path
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('..')) {
            throw 'manifest_path_invalid'
        }
        if (-not $seen.Add($relative)) {
            throw 'manifest_duplicate_path'
        }
        $full = Join-Path $root ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $drift.Add("missing:$relative")
            continue
        }
        $item = Get-Item -LiteralPath $full
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.ToLowerInvariant()
        if ([int64]$item.Length -ne [int64]$entry.size_bytes) {
            $drift.Add("size:$relative")
        }
        if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
            $drift.Add("sha256:$relative")
        }
        if ($candidateProfile -eq 'release' -and $relative.ToLowerInvariant() -match '(^|/)(runtime|evidence|private|cache|logs|state|backups|models|trace|session)(/|$)') {
            throw 'release_exclusion_violation'
        }
    }

    $canonical = Get-CanonicalEntriesText -Entries $entries
    $canonicalHash = ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($canonicalHash -ne ([string]$manifest.manifest_hash).ToLowerInvariant()) {
        throw 'manifest_hash_invalid'
    }
    if ($drift.Count -gt 0) {
        [pscustomobject]@{status='drift';drift=@($drift);manifest=$manifestFull} | ConvertTo-Json -Depth 5
        exit 1
    }
    [pscustomobject]@{status='pass';manifest=$manifestFull;candidate_id=$manifest.candidate_id;candidate_kind=$candidateKind;candidate_profile=$candidateProfile;entry_count=$entries.Count;manifest_hash=$canonicalHash} | ConvertTo-Json -Compress
    exit 0
}
catch {
    [pscustomobject]@{status='untrusted_or_malformed';error_code=$_.Exception.Message;manifest=$ManifestPath} | ConvertTo-Json -Compress
    exit 2
}
