[CmdletBinding()]
param(
    [int]$Port = 18789,
    [string]$RuntimeStateRoot = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($RuntimeStateRoot)) { $RuntimeStateRoot = Join-Path $projectRoot 'runtime\state' }
$legacyStatePath = Join-Path $RuntimeStateRoot 'headroom-state.json'
$statePath = Join-Path $RuntimeStateRoot ("headroom-state-{0}.json" -f $Port)
$baseUrl = "http://127.0.0.1:$Port"

function Get-ListenerPid {
    param([int]$ListenPort)

    $listenerLines = @(netstat -ano | Select-String -Pattern "^\s*TCP\s+127\.0\.0\.1:$ListenPort\s+.*LISTENING\s+(\d+)\s*$")
    if ($listenerLines.Count -gt 1) {
        throw "Refusing to identify a single listener on 127.0.0.1:$ListenPort; found $($listenerLines.Count) listeners"
    }
    if ($listenerLines.Count -eq 0) {
        return $null
    }
    return [int]$listenerLines[0].Matches[0].Groups[1].Value
}

function Test-HeadroomEndpoint {
    param(
        [string]$Url,
        [ValidateSet('livez', 'health')]
        [string]$Kind
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -NoProxy -UseBasicParsing -TimeoutSec 3
        if ([int]$response.StatusCode -ne 200) {
            return $false
        }
        $body = $response.Content | ConvertFrom-Json
        if ($body.service -ne 'headroom-proxy' -or $body.status -ne 'healthy') {
            return $false
        }
        if ($Kind -eq 'livez') {
            return ($body.alive -eq $true)
        }
        return ($body.ready -eq $true)
    } catch {
        return $false
    }
}

function Assert-HeadroomHealth {
    if (-not (Test-HeadroomEndpoint -Url "$baseUrl/livez" -Kind livez)) {
        throw "Headroom liveness check failed at $baseUrl/livez"
    }
    if (-not (Test-HeadroomEndpoint -Url "$baseUrl/health" -Kind health)) {
        throw "Headroom health check failed at $baseUrl/health"
    }
}

function Get-HeadroomState {
    $candidate = $statePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-Path -LiteralPath $legacyStatePath -PathType Leaf)) { $candidate = $legacyStatePath }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Refusing to stop Headroom; state file is missing: $statePath" }
    try {
        return Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
    } catch {
        throw "Refusing to stop Headroom; state file is invalid: $statePath"
    }
}

function Assert-StateListener {
    param(
        [object]$State,
        [int]$ListenerPid
    )

    $statePort = $State.PSObject.Properties['Port']
    $stateListenerPid = $State.PSObject.Properties['ListenerPid']
    $statePid = $State.PSObject.Properties['Pid']
    $portValue = 0
    $listenerValue = 0
    if (-not $statePort -or -not [int]::TryParse([string]$statePort.Value, [ref]$portValue) -or $portValue -ne $Port) {
        throw "Refusing to stop PID $ListenerPid; state file port does not match $Port"
    }
    if (-not $stateListenerPid -or -not [int]::TryParse([string]$stateListenerPid.Value, [ref]$listenerValue) -or $listenerValue -ne $ListenerPid) {
        throw "Refusing to stop PID $ListenerPid; state file does not identify the listener"
    }
    if ($statePid) {
        $pidValue = 0
        if (-not [int]::TryParse([string]$statePid.Value, [ref]$pidValue) -or $pidValue -ne $ListenerPid) {
            throw "Refusing to stop PID $ListenerPid; state file PID fields disagree"
        }
    }
}

function Test-StateProcessIdentity {
    param(
        [object]$State,
        [object]$Process,
        [ValidateSet('Listener', 'Parent')]
        [string]$Kind
    )

    if ($null -eq $Process -or $Process.Name -notlike 'python*') {
        return $false
    }
    $pathProperty = $State.PSObject.Properties["${Kind}Path"]
    $startedProperty = $State.PSObject.Properties["${Kind}StartedAt"]
    if (-not $pathProperty -or -not $startedProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value) -or [string]::IsNullOrWhiteSpace([string]$startedProperty.Value)) {
        return $false
    }
    try {
        $expectedPath = [System.IO.Path]::GetFullPath([string]$pathProperty.Value)
        $actualPath = [System.IO.Path]::GetFullPath([string]$Process.Path)
        $expectedStart = [DateTime]::Parse([string]$startedProperty.Value).ToUniversalTime()
        $actualStart = $Process.StartTime.ToUniversalTime()
        return ([string]::Equals($expectedPath, $actualPath, [StringComparison]::OrdinalIgnoreCase) -and [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le 10)
    } catch {
        return $false
    }
}

function Get-ProcessDescendantRows {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][int[]]$RootIds
    )

    $childrenByParent = @{}
    foreach ($row in @($Rows)) {
        $childId = 0
        $parentId = 0
        if (-not [int]::TryParse([string]$row.ProcessId, [ref]$childId) -or $childId -le 0) { continue }
        if (-not [int]::TryParse([string]$row.ParentProcessId, [ref]$parentId) -or $parentId -le 0) { continue }
        if (-not $childrenByParent.ContainsKey($parentId)) { $childrenByParent[$parentId] = @() }
        $childrenByParent[$parentId] += $row
    }

    $queue = [System.Collections.Generic.Queue[int]]::new()
    $seen = @{}
    foreach ($rootId in @($RootIds)) {
        if ($rootId -gt 0 -and -not $seen.ContainsKey($rootId)) {
            $seen[$rootId] = $true
            $queue.Enqueue($rootId)
        }
    }

    $descendants = @()
    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        if (-not $childrenByParent.ContainsKey($parentId)) { continue }
        foreach ($row in @($childrenByParent[$parentId])) {
            $childId = 0
            if (-not [int]::TryParse([string]$row.ProcessId, [ref]$childId) -or $childId -le 0) { continue }
            if ($seen.ContainsKey($childId)) { continue }
            $seen[$childId] = $true
            $descendants += $row
            $queue.Enqueue($childId)
        }
    }
    return $descendants
}

function Test-HeadroomWorkerIdentity {
    param(
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][object]$State
    )

    $processId = 0
    if (-not [int]::TryParse([string]$Row.ProcessId, [ref]$processId) -or $processId -le 0) { return $false }
    if ([string]$Row.Name -notmatch '(?i)^python(?:\.exe)?$') { return $false }
    $commandLine = [string]$Row.CommandLine
    if ($commandLine -notmatch '(?i)spawn_main|multiprocessing-fork') { return $false }

    $expectedPaths = @()
    foreach ($propertyName in @('ListenerPath', 'ParentPath')) {
        $property = $State.PSObject.Properties[$propertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            try { $expectedPaths += [IO.Path]::GetFullPath([string]$property.Value) } catch { }
        }
    }
    if ($expectedPaths.Count -eq 0) { return $false }
    try {
        $actualPath = [IO.Path]::GetFullPath([string]$Row.ExecutablePath)
        if (-not ($expectedPaths | Where-Object { $_.Equals($actualPath, [StringComparison]::OrdinalIgnoreCase) })) { return $false }
    } catch { return $false }

    try {
        $startedAt = [DateTimeOffset]::Parse([string]$State.StartedAt).UtcDateTime
        $createdAt = if ($Row.CreationDate -is [DateTime]) { ([DateTime]$Row.CreationDate).ToUniversalTime() } else { [DateTimeOffset]::Parse([string]$Row.CreationDate).UtcDateTime }
        if ($createdAt -lt $startedAt.AddSeconds(-2)) { return $false }
    } catch { return $false }
    return $true
}

function Get-VerifiedHeadroomWorkerIds {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][int[]]$RootIds
    )

    $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate)
    $descendants = @(Get-ProcessDescendantRows -Rows $rows -RootIds $RootIds)
    return @($descendants | Where-Object { Test-HeadroomWorkerIdentity -Row $_ -State $State } | ForEach-Object { [int]$_.ProcessId })
}

$listenerPid = Get-ListenerPid -ListenPort $Port
if ($null -eq $listenerPid) {
    exit 0
}
$state = Get-HeadroomState
Assert-StateListener -State $state -ListenerPid $listenerPid
$listenerProcess = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
$parentPidValue = 0
if ($state.ParentPid -and (-not [int]::TryParse([string]$state.ParentPid, [ref]$parentPidValue) -or $parentPidValue -le 0)) {
    throw "Refusing to stop PID $listenerPid; state parent PID is invalid"
}
$rootIds = @($listenerPid)
if ($parentPidValue -gt 0) { $rootIds += $parentPidValue }
$workerIds = @(Get-VerifiedHeadroomWorkerIds -State $state -RootIds $rootIds)
if ($null -eq $listenerProcess) {
    if ($workerIds.Count -eq 0) {
        throw "Refusing to stop PID $listenerPid; listener process is missing and no verified Headroom workers were found"
    }
    foreach ($workerId in $workerIds) { Stop-Process -Id $workerId -Force -ErrorAction Stop }
    $remaining = Get-ListenerPid -ListenPort $Port
    if ($null -ne $remaining) { throw "Headroom listener $remaining remained after stopping verified worker descendants" }
    $workerIds
    exit 0
}
if ($listenerProcess.Name -notlike 'python*') {
    throw "Refusing to stop PID $listenerPid; listener process identity is not Headroom Python"
}
$livezOk = Test-HeadroomEndpoint -Url "$baseUrl/livez" -Kind livez
$healthOk = Test-HeadroomEndpoint -Url "$baseUrl/health" -Kind health
$strongListenerIdentity = Test-StateProcessIdentity -State $state -Process $listenerProcess -Kind Listener
if (-not $livezOk -and -not $healthOk -and -not $strongListenerIdentity) {
    throw "Refusing to stop PID $listenerPid; health endpoints are unavailable and state process identity is not verified"
}

$stopIds = @($workerIds)
$stopIds += $listenerPid
if ($parentPidValue -gt 0) {
    if ($parentPidValue -ne $listenerPid) {
        $parent = Get-Process -Id $parentPidValue -ErrorAction SilentlyContinue
        if ($parent -and (Test-StateProcessIdentity -State $state -Process $parent -Kind Parent)) {
            $stopIds += $parent.Id
        }
    }
}

foreach ($stopId in ($stopIds | Select-Object -Unique)) {
    Stop-Process -Id $stopId -Force
}
$deadline = (Get-Date).AddSeconds(5)
do {
    $remaining = Get-ListenerPid -ListenPort $Port
    if ($null -eq $remaining) { break }
    Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)
if ($null -ne $remaining) { throw "Headroom listener $remaining remained after stop" }
$stopIds | Select-Object -Unique
