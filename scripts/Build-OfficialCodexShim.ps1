[CmdletBinding()]
param(
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectPath = Join-Path $projectRoot 'src\official-route\CodexCliShim\CodexCliShim.csproj'
$outputRoot = Join-Path $projectRoot 'runtime\official-route\shim'

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw 'route_a_shim_project_missing'
}

if ($Clean -and (Test-Path -LiteralPath $outputRoot)) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
dotnet publish $projectPath -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -o $outputRoot

$shimPath = Join-Path $outputRoot 'codex-cli-headroom-shim.exe'
if (-not (Test-Path -LiteralPath $shimPath -PathType Leaf)) {
    throw 'route_a_shim_build_output_missing'
}

$hash = (Get-FileHash -LiteralPath $shimPath -Algorithm SHA256).Hash
[ordered]@{
    schema = 'route-a-shim-build/v1'
    status = 'succeeded'
    shim_path = $shimPath
    sha256 = $hash
    project_path = $projectPath
    built_at_utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 5
