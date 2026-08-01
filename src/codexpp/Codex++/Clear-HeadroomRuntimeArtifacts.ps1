[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Execute,
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$allowedRoots = @(
    'C:\Users\ma dao\.headroom\logs',
    'C:\Users\ma dao\.headroom\codexpp-headroom',
    'C:\Users\ma dao\AppData\Roaming\Codex++'
) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }

function Test-AllowedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in $allowedRoots) {
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$patterns = @(
    @{ Root = 'C:\Users\ma dao\.headroom\logs'; Filter = '*' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.log' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.stdout.log' },
    @{ Root = 'C:\Users\ma dao\.headroom\codexpp-headroom'; Filter = '*.stderr.log' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*.log' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*-state.json' },
    @{ Root = 'C:\Users\ma dao\AppData\Roaming\Codex++'; Filter = '*headroom*-status.json' }
)

$targets = @(
    foreach ($entry in $patterns) {
        if (-not (Test-Path -LiteralPath $entry.Root -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $entry.Root -Filter $entry.Filter -File -Force -ErrorAction SilentlyContinue
    }
) | Where-Object { Test-AllowedPath -Path $_.FullName } | Sort-Object FullName -Unique

$manifest = [ordered]@{
    schema_version = 1
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    execute = $Execute.IsPresent
    files = @($targets | ForEach-Object {
        $hash = $null
        $hashError = $null
        try { $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        catch { $hashError = 'locked_or_unreadable' }
        [ordered]@{ path = $_.FullName; length = $_.Length; sha256 = $hash; read_error = $hashError }
    })
}
$manifestPath = Join-Path $ProjectRoot 'evidence\runtime-clear-manifest.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

foreach ($file in $targets) {
    if (-not $Execute) {
        Write-Output ("would-remove: " + $file.FullName)
        continue
    }
    if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove Headroom runtime log/state artifact')) {
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Output ("removed: " + $file.FullName)
    }
}

if (-not $Execute) {
    Write-Output ("dry-run: " + @($targets).Count + ' files; use -Execute after services are stopped')
}
