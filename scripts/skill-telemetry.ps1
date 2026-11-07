[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('record','summary')]
    [string]$Action,
    [string]$ProjectPath='.',
    [string]$Task='',
    [string[]]$Skills=@(),
    [ValidateSet('selected','completed','failed','skipped','rolled-back','unknown')]
    [string]$Outcome='unknown',
    [ValidateRange(0,5)]
    [int]$Benefit=0,
    [ValidateRange(0,5)]
    [int]$Cost=0,
    [string]$Notes='',
    [ValidateSet('unknown','yes','no')]
    [string]$FirstPass='unknown',
    [ValidateRange(0,100000)]
    [int]$ReworkCount=0,
    [ValidateSet('not-run','passed','failed','blocked')]
    [string]$Verification='not-run',
    [ValidateRange(0,100000)]
    [int]$ElapsedMinutes=0,
    [string]$Evidence=''
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot([string]$Path) {
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root)
    }
    finally { Pop-Location }
}

function Write-Utf8NoBom([string]$Path,[string]$Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

$root = Resolve-RepoRoot $ProjectPath
$telemetryDir = Join-Path $root '.ai\analytics'
$telemetryPath = Join-Path $telemetryDir 'skill-telemetry.jsonl'

if ($Action -eq 'record') {
    if (-not $Task) { throw 'Task is required for record.' }
    if ($FirstPass -eq 'yes' -and $Verification -ne 'passed') { throw 'FirstPass yes requires Verification passed.' }
    if ($Verification -eq 'passed' -and -not $Evidence.Trim()) { throw 'Verification passed requires concrete Evidence.' }
    if (-not (Test-Path $telemetryDir)) { New-Item -ItemType Directory -Path $telemetryDir -Force | Out-Null }

    $branch = ''
    $head = ''
    Push-Location $root
    try {
        $branch = (& git branch --show-current | Out-String).Trim()
        $head = (& git rev-parse HEAD | Out-String).Trim()
    }
    finally { Pop-Location }

    $recordedRework = $null
    $recordedElapsed = $null
    if ($PSBoundParameters.ContainsKey('ReworkCount')) { $recordedRework = $ReworkCount }
    if ($PSBoundParameters.ContainsKey('ElapsedMinutes')) { $recordedElapsed = $ElapsedMinutes }

    $entry = [ordered]@{
        timestamp = (Get-Date -Format o)
        project = (Split-Path $root -Leaf)
        repository = $root
        branch = $branch
        head = $head
        task = $Task
        skills = @($Skills | Where-Object { $_ } | Sort-Object -Unique)
        outcome = $Outcome
        benefit = $Benefit
        cost = $Cost
        net = ($Benefit - $Cost)
        notes = $Notes
        first_pass = $FirstPass
        rework_count = $recordedRework
        verification = $Verification
        elapsed_minutes = $recordedElapsed
        evidence = $Evidence
    }

    $line = $entry | ConvertTo-Json -Compress -Depth 5
    [IO.File]::AppendAllText($telemetryPath,($line + [Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    Write-Host "Recorded skill telemetry: $telemetryPath"
    return
}

if (-not (Test-Path $telemetryPath)) {
    Write-Host 'No skill telemetry recorded for this project.'
    return
}

$rows = @()
foreach ($line in (Get-Content -LiteralPath $telemetryPath -ErrorAction Stop)) {
    if (-not $line.Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { }
}

if ($rows.Count -eq 0) {
    Write-Host 'No valid skill telemetry records found.'
    return
}

$stats = @{}
foreach ($row in $rows) {
    foreach ($skill in @($row.skills)) {
        if (-not $stats.ContainsKey($skill)) {
            $stats[$skill] = [ordered]@{ skill=$skill; uses=0; completed=0; failed=0; benefit=0; cost=0; net=0; firstPassYes=0; firstPassMeasured=0; reworkTotal=0; reworkMeasured=0; verified=0; elapsedTotal=0; elapsedMeasured=0 }
        }
        $s = $stats[$skill]
        $s.uses++
        if ($row.outcome -eq 'completed') { $s.completed++ }
        if ($row.outcome -eq 'failed' -or $row.outcome -eq 'rolled-back') { $s.failed++ }
        $s.benefit += [int]$row.benefit
        $s.cost += [int]$row.cost
        $s.net += [int]$row.net
        if ($row.first_pass -eq 'yes' -or $row.first_pass -eq 'no') {
            $s.firstPassMeasured++
            if ($row.first_pass -eq 'yes') { $s.firstPassYes++ }
        }
        if ($null -ne $row.rework_count) {
            $s.reworkMeasured++
            $s.reworkTotal += [int]$row.rework_count
        }
        if ($row.verification -eq 'passed') { $s.verified++ }
        if ($null -ne $row.elapsed_minutes) {
            $s.elapsedMeasured++
            $s.elapsedTotal += [int]$row.elapsed_minutes
        }
    }
}

# Convert dictionary rows to real objects so PowerShell's formatter reliably
# displays each skill name rather than treating it as an opaque collection.
$report = @()
foreach ($stat in $stats.Values) {
    $report += [PSCustomObject]$stat
}
$orderedReport = @($report | Sort-Object @{Expression='net';Descending=$true}, @{Expression='uses';Descending=$true})

# Keep the original readable summary and show optional quality metrics separately.
$orderedReport | Format-Table skill,uses,completed,failed,benefit,cost,net -AutoSize
$orderedReport | Format-Table skill,firstPassYes,firstPassMeasured,reworkTotal,reworkMeasured,verified,elapsedTotal,elapsedMeasured -AutoSize
