[CmdletBinding()]
param(
    [string]$BasePython = 'D:\Python314\python.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $projectRoot 'runtime'
$pythonRoot = Join-Path $runtimeRoot 'python'
$pythonExe = Join-Path $pythonRoot 'Scripts\python.exe'
$wheelhouse = Join-Path $runtimeRoot 'wheelhouse'
$requirements = Join-Path $wheelhouse 'requirements-lock.txt'
$patchRoot = Join-Path $projectRoot 'src\headroom\site-packages-patches\headroom'
$sitePackages = Join-Path $pythonRoot 'Lib\site-packages\headroom'

foreach ($path in @(
        $runtimeRoot,
        (Join-Path $runtimeRoot 'state'),
        (Join-Path $runtimeRoot 'logs'),
        (Join-Path $runtimeRoot 'cache'),
        (Join-Path $runtimeRoot 'private'),
        $wheelhouse,
        (Join-Path $runtimeRoot 'providers'))) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
}

if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $BasePython -PathType Leaf)) { throw "base_python_missing:$BasePython" }
    & $BasePython -m venv $pythonRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) { throw 'venv_create_failed' }
}

if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) { throw "requirements_lock_missing:$requirements" }
& $pythonExe -m pip install --no-index --no-deps --find-links $wheelhouse -r $requirements
if ($LASTEXITCODE -ne 0) { throw 'offline_install_failed' }

if (-not (Test-Path -LiteralPath $sitePackages -PathType Container)) { throw 'headroom_site_packages_missing' }
foreach ($patchFile in Get-ChildItem -LiteralPath $patchRoot -Recurse -File |
        Where-Object { $_.Extension -eq '.py' -and $_.FullName -notmatch '(?i)(\\|/)__pycache__(\\|/)' }) {
    $relativePath = [IO.Path]::GetRelativePath($patchRoot, $patchFile.FullName)
    $targetPath = Join-Path $sitePackages $relativePath
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { throw "patch_target_missing:$relativePath" }
    Copy-Item -LiteralPath $patchFile.FullName -Destination $targetPath -Force
    $sourceHash = (Get-FileHash -LiteralPath $patchFile.FullName -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) { throw "patch_hash_mismatch:$relativePath" }
}

& $pythonExe -m pip check
if ($LASTEXITCODE -ne 0) { throw 'pip_check_failed' }

$versions = & $pythonExe -c "import headroom, onnxruntime, sys; print(sys.version.split()[0]); print(headroom.__version__); print(onnxruntime.__version__)"
if ($LASTEXITCODE -ne 0 -or @($versions).Count -ne 3) { throw 'runtime_import_check_failed' }

[pscustomobject]@{
    status = 'ready'
    python = [string]$versions[0]
    headroom = [string]$versions[1]
    onnxruntime = [string]$versions[2]
    python_path = $pythonExe
    wheelhouse = $wheelhouse
    patch_count = @(Get-ChildItem -LiteralPath $patchRoot -Recurse -File).Count
}
