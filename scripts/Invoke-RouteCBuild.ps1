param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [string]$Mode = 'check'  # check | test | clippy | build
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$cargoExe = "D:\新建文件夹\headroom for codex++\runtime\toolchains\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\cargo.exe"
$env:RUSTUP_HOME = "D:\新建文件夹\headroom for codex++\runtime\toolchains\rustup"
$env:CARGO_HOME = "D:\新建文件夹\headroom for codex++\runtime\toolchains\cargo"

# Capture vcvars64 environment into the current session (INCLUDE/LIB/PATH).
$vcvarsOut = & cmd /c "`"$vcvars`" >nul 2>&1 && set" 2>&1
foreach ($line in $vcvarsOut) {
    if ($line -match '^([^=]+)=(.*)$') {
        try { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') } catch { }
    }
}

Write-Output "=== env check ==="
Write-Output "INCLUDE set: $(-not [string]::IsNullOrWhiteSpace($env:INCLUDE))"
Write-Output "LIB set: $(-not [string]::IsNullOrWhiteSpace($env:LIB))"
Write-Output "PATH has cl: $($env:PATH -match 'MSVC')"

Set-Location $SourceRoot
Write-Output "=== cargo $Mode ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
switch ($Mode) {
    'clippy' { & $cargoExe clippy --workspace --all-targets -- -D warnings 2>&1 }
    'test'   { & $cargoExe test --workspace 2>&1 }
    'build'  { & $cargoExe build --workspace 2>&1 }
    default  { & $cargoExe check --workspace 2>&1 }
}
$code = $LASTEXITCODE
$sw.Stop()
Write-Output "=== cargo $Mode exit=$code elapsed=$([Math]::Round($sw.Elapsed.TotalSeconds,1))s ==="
exit $code
