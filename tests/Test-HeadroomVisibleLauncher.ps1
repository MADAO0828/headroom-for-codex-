[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceLauncher = Join-Path $projectRoot 'scripts\Start-HeadroomWithProgress.ps1'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function New-Fixture {
    param([Parameter(Mandatory)][string]$Mode)
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('headroom-visible-launcher-' + [IO.Path]::GetRandomFileName())
    $scripts = Join-Path $fixture 'scripts'
    $state = Join-Path $fixture 'runtime\state'
    $logs = Join-Path $fixture 'runtime\logs'
    foreach ($path in @($scripts, $state, $logs)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    Copy-Item -LiteralPath $sourceLauncher -Destination (Join-Path $scripts 'Start-HeadroomWithProgress.ps1') -Force

    $fake = @"
param([int]`$Workers=1,[switch]`$PhaseB,[int]`$ReadinessTimeoutSeconds=120)
`$state = '$state'
[IO.Directory]::CreateDirectory(`$state) | Out-Null
if ('$Mode' -ne 'stale') {
    `$document = [ordered]@{status=if('$Mode' -eq 'success'){'succeeded'}else{'failed'};stage=if('$Mode' -eq 'success'){'fixture_ready'}else{'fixture_failed'};error_code=if('$Mode' -eq 'success'){''}else{'fixture_error'};detail=if('$Mode' -eq 'success'){''}else{'fixture failure'};updated_at_utc=[DateTime]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText((Join-Path `$state 'headroom-start-result.json'), ((`$document | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new(`$false))
}
if ('$Mode' -eq 'success') { exit 0 } elseif ('$Mode' -eq 'stale') { exit 0 } else { exit 1 }
"@
    [IO.File]::WriteAllText((Join-Path $scripts 'Start-HeadroomForCodexPP.ps1'), $fake, [Text.UTF8Encoding]::new($false))
    if ($Mode -eq 'stale') {
        $old = [ordered]@{status='succeeded';stage='old_result';error_code='';detail='old';updated_at_utc='2020-01-01T00:00:00.0000000Z'}
        [IO.File]::WriteAllText((Join-Path $state 'headroom-start-result.json'), (($old | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    return $fixture
}

$fixtures = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($mode in @('success', 'failure', 'stale')) {
        $fixture = New-Fixture -Mode $mode
        [void]$fixtures.Add($fixture)
        $launcher = Join-Path $fixture 'scripts\Start-HeadroomWithProgress.ps1'
        $output = @(& pwsh.exe -NoLogo -NoProfile -File $launcher -OverallTimeoutSeconds 30 -SuccessDisplaySeconds 0 -NoPauseOnFailure 2>&1)
        $code = $LASTEXITCODE
        $text = $output -join "`n"
        if ($mode -eq 'success') {
            Assert-True -Condition ($code -eq 0 -and $text -match '启动成功') -Message "fixture success is visible and returns zero (code=$code; output=$text)"
        }
        elseif ($mode -eq 'failure') {
            Assert-True -Condition ($code -eq 1 -and $text -match 'fixture_error' -and $text -match 'fixture failure') -Message "fixture failure exposes safe receipt fields and returns one (code=$code; output=$text)"
        }
        else {
            Assert-True -Condition ($code -eq 1 -and $text -match '未生成新的 headroom-start-result') -Message "stale receipt is not accepted as this run success (code=$code; output=$text)"
        }
    }
}
finally {
    foreach ($fixture in $fixtures) {
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output 'visible launcher fixture tests: PASS'
