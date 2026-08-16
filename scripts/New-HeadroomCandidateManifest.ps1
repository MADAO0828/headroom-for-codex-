[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateKind,

    [Parameter(Mandatory = $true)]
    [string]$CandidateProfile,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validCandidateKinds = @('simple', 'complex', 'build')
$validCandidateProfiles = @('source', 'release', 'canary')

function Exit-CandidateContractError {
    param([string]$ErrorCode)
    [pscustomobject]@{status='untrusted_or_malformed';error_code=$ErrorCode} | ConvertTo-Json -Compress
    exit 2
}

if ($CandidateKind -notin $validCandidateKinds) {
    if ($CandidateKind -in $validCandidateProfiles) {
        Exit-CandidateContractError -ErrorCode 'candidate_kind_legacy_value_requires_candidate_profile'
    } else {
        Exit-CandidateContractError -ErrorCode 'candidate_kind_invalid'
    }
}
if ($CandidateProfile -notin $validCandidateProfiles) {
    Exit-CandidateContractError -ErrorCode 'candidate_profile_invalid'
}

function Get-RelativeProjectPath {
    param([string]$FullPath)
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath($FullPath)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "candidate_path_outside_project_root"
    }
    return ([IO.Path]::GetRelativePath($root, $full)).Replace('\', '/')
}

function Test-ExcludedCandidatePath {
    param([string]$RelativePath)
    $path = $RelativePath.ToLowerInvariant()
    # WORK.md is the volatile task ledger; exclude only the project-root ledger.
    if ($path -eq 'work.md') {
        return $true
    }
    if ($path -match '^runtime/(?!src/)') {
        return $true
    }
    if ($path -match '(^|/)\.(git|reasonix)(/|$)') {
        return $true
    }
    if ($path -match '(^|/)(__pycache__|\.pytest_cache|\.mypy_cache)(/|$)') {
        return $true
    }
    if ($path -match '^runtime/src/[^/]+\.(recovery|userzip-staging|staging)(/|$)') {
        return $true
    }
    if ($path -match '(^|/)official-codeload-staging(/|$)') {
        return $true
    }
    if ($path -match '\.(part|download)$') {
        return $true
    }
    if ($path -match '(^|/)(runtime/private|runtime/cache|runtime/logs|runtime/state|runtime/backups|backups|models|target|node_modules)(/|$)') {
        return $true
    }
    # Runtime-artifacts (logs, pids, locks, deploy state) must never enter the
    # candidate; the segment differs from runtime/ so match it explicitly.
    if ($path -match '(^|/)runtime-artifacts(/|$)') {
        return $true
    }
    # Build outputs and IDE caches: bin/obj directories and common artifact
    # extensions are never publishable.
    if ($path -match '(^|/)(bin|obj)(/|$)') {
        return $true
    }
    # Lockfiles that are legitimate source artifacts (Cargo.lock etc.) must be
    # preserved for reproducible builds; only runtime lock files are excluded.
    if ($path -match '\.(log|pid|lock|cache|tmp)$' -and $path -notmatch '(^|/)(Cargo\.lock|poetry\.lock|package-lock\.json|pnpm-lock\.yaml)$') {
        return $true
    }
    if ($path -match '^evidence/candidate-manifest-[^/]+\.json$') {
        return $true
    }
    if ($path -match '^evidence/prod-closure-c0-c4-[^/]+\.json$') {
        return $true
    }
    # Review receipts may record the final candidate manifest hash.  Exclude
    # them from source candidates to avoid a self-referential hash cycle.
    if ($path -match '^evidence/prod-closure-r1-r3-codex-reverification-[^/]+\.json$') {
        return $true
    }
    if ($path -match '\.(onnx|onnx_data|bin|safetensors|pt|pth|gguf|dmp|sqlite|db|jsonl|pyc)$') {
        return $true
    }
    if ($path -match '(^|/)(auth|credentials|secrets?|tokens?)([^/]*)(/|\.|$)') {
        return $true
    }
    return $false
}

function Test-ReleasePath {
    param([string]$RelativePath)
    $path = $RelativePath.ToLowerInvariant()
    if ($path -match '(^|/)(runtime|runtime-artifacts|evidence|acceptance|private|cache|logs|state|backups|models|trace|session)(/|$)') {
        return $false
    }
    if ($path -match '(^|/)(bin|obj)(/|$)') {
        return $false
    }
    if ($path -match '\.(exe|dll|pdb|onnx|onnx_data|bin|safetensors|pt|pth|gguf|dmp|sqlite|db|jsonl|log|pid|lock|cache|tmp)$') {
        return $false
    }
    return $true
}

function Test-SecretLikeContent {
    param([string]$Text)
    $Text = $Text -replace '(?i)__codexHeadroomStatusIndicator', 'PLACEHOLDER'
    $Text = $Text -replace '(?i)FIXTURE_[A-Z0-9_]+', 'PLACEHOLDER'
    $patterns = @(
        '(?i)-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)authorization\s*[:=]\s*bearer\s+[A-Za-z0-9._~+/=-]{20,}',
        '(?i)(api[_-]?key|access[_-]?token|secret)\s*[:=]\s*["''][A-Za-z0-9._~+/=-]{24,}["'']',
        '(?i)\bsk-[A-Za-z0-9]{20,}',
        '(?i)\bx-api-key\s*[:=]\s*["''][A-Za-z0-9._~+/=-]{20,}["'']'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }
    return $false
}

$root = [IO.Path]::GetFullPath($ProjectRoot)
$output = if ([IO.Path]::IsPathRooted($OutputPath)) {
    [IO.Path]::GetFullPath($OutputPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
}
$outputParent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { $_.FullName -ne $output } |
    Sort-Object FullName

$entries = [Collections.Generic.List[object]]::new()
$excluded = [Collections.Generic.List[string]]::new()
$excludedReasons = [Collections.Generic.List[object]]::new()
$secretLike = [Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $relative = Get-RelativeProjectPath -FullPath $file.FullName
    if (Test-ExcludedCandidatePath -RelativePath $relative) {
        $excluded.Add($relative)
        if ($relative -eq 'WORK.md') {
            $excludedReasons.Add([ordered]@{path=$relative;reason='volatile_work_ledger'})
        }
        continue
    }
    if ($CandidateProfile -eq 'release' -and -not (Test-ReleasePath -RelativePath $relative)) {
        $excluded.Add($relative)
        continue
    }
    if ($file.Length -gt 25MB) {
        $excluded.Add($relative)
        continue
    }

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    if ($file.Extension -in @('.md', '.txt', '.ps1', '.psm1', '.py', '.rs', '.toml', '.json', '.yaml', '.yml', '.js', '.vbs')) {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if (Test-SecretLikeContent -Text $text) {
            $secretLike.Add($relative)
        }
    }
    $entries.Add([ordered]@{
            path       = $relative
            size_bytes = [int64]$file.Length
            sha256     = $hash
        })
}

$sortedEntries = @($entries | ForEach-Object {
        [ordered]@{
            path       = [string]$_.path
            size_bytes = [int64]$_.size_bytes
            sha256     = ([string]$_.sha256).ToLowerInvariant()
        }
    } | Sort-Object -Property @{ Expression = { [string]$_['path'] } })
$entryCanonical = ($sortedEntries | ForEach-Object {
        "{0}`t{1}`t{2}" -f $_.path, $_.size_bytes, $_.sha256
    }) -join "`n"
$entryBytes = [Text.Encoding]::UTF8.GetBytes($entryCanonical)
$manifestHash = ([Security.Cryptography.SHA256]::Create().ComputeHash($entryBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

$manifest = [ordered]@{
    version         = 1
    algorithm       = 'sha256'
    candidate_id    = "headroom-$CandidateKind-$CandidateProfile-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
    candidate_kind  = $CandidateKind
    candidate_profile = $CandidateProfile
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    project_root    = (Get-RelativeProjectPath -FullPath $root)
    entries         = $sortedEntries
    manifest_hash   = $manifestHash
    excluded_count  = $excluded.Count
    excluded_reasons = @($excludedReasons | ForEach-Object { $_ })
    secret_like_paths = @($secretLike | Sort-Object -Unique)
}

$json = $manifest | ConvertTo-Json -Depth 8
$json = $json.Replace("`r`n", "`n")
[IO.File]::WriteAllText($output, $json + "`n", [Text.UTF8Encoding]::new($false))

if ($secretLike.Count -gt 0) {
    Write-Error "candidate_secret_like_paths_detected"
    exit 2
}

[pscustomobject]@{
    status         = 'created'
    candidate_kind = $CandidateKind
    candidate_profile = $CandidateProfile
    output         = $output
    entry_count    = $sortedEntries.Count
    excluded_count = $excluded.Count
    manifest_hash  = $manifestHash
} | ConvertTo-Json -Compress
