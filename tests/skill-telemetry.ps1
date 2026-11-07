[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Fixture = Join-Path $RepoRoot 'tests\.work\skill-telemetry'
$Tool = Join-Path $RepoRoot 'scripts\skill-telemetry.ps1'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

if (Test-Path -LiteralPath $Fixture) {
    Remove-Item -LiteralPath $Fixture -Recurse -Force
}
New-Item -ItemType Directory -Path $Fixture -Force | Out-Null

try {
    Push-Location $Fixture
    try {
        & git init -q
        & git config user.name 'Skill Telemetry Test'
        & git config user.email 'skill-test@example.invalid'
        [IO.File]::WriteAllText((Join-Path $Fixture 'README.md'), "# Fixture`n")
        & git add README.md
        & git commit -q -m 'seed'
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit the isolated fixture.' }
    }
    finally { Pop-Location }

    & $Tool -Action record -ProjectPath $Fixture -Task 'pilot successful' -Skills @('albert-design-director') -Outcome completed -Benefit 4 -Cost 1 -FirstPass yes -ReworkCount 0 -Verification passed -ElapsedMinutes 25 -Evidence 'UI smoke passed at fixture HEAD'
    $data = Join-Path $Fixture '.ai\analytics\skill-telemetry.jsonl'
    $lines = @(Get-Content -LiteralPath $data)
    Assert-True ($lines.Count -eq 1) 'Expected one telemetry entry.'
    $row = $lines[0] | ConvertFrom-Json
    Assert-True ($row.first_pass -eq 'yes') 'First-pass outcome must be recorded.'
    Assert-True ($row.rework_count -eq 0) 'Zero must be preserved as a measured rework count.'
    Assert-True ($row.verification -eq 'passed') 'Verification status must be preserved.'
    Assert-True ($row.evidence -match 'UI smoke passed') 'Verification requires concrete evidence.'
    Assert-True ($row.elapsed_minutes -eq 25) 'Measured elapsed minutes must be recorded.'

    & $Tool -Action record -ProjectPath $Fixture -Task 'old-style record' -Skills @('albert-design-director') -Outcome completed -Benefit 2 -Cost 1
    $rows = @(Get-Content -LiteralPath $data | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rows.Count -eq 2) 'Legacy invocation must remain usable.'
    Assert-True ($null -eq $rows[1].rework_count) 'Unmeasured rework must not become a fake zero.'
    Assert-True ($rows[1].first_pass -eq 'unknown') 'Unmeasured first pass must remain unknown.'

    $summary = (& $Tool -Action summary -ProjectPath $Fixture | Out-String)
    Assert-True ($summary -match 'firstPassMeasured') 'Summary must expose the new measured denominator.'
    Assert-True ($summary -match 'albert-design-director') 'Summary must include the recorded skill.'

    $rejected = $false
    try {
        & $Tool -Action record -ProjectPath $Fixture -Task invalid -Verification passed -Skills @('albert-design-director') | Out-Null
    }
    catch { $rejected = $_.Exception.Message -match 'requires concrete Evidence' }
    Assert-True $rejected 'Passed verification with no evidence must be rejected.'

    $rejected = $false
    try {
        & $Tool -Action record -ProjectPath $Fixture -Task invalid -FirstPass yes -Skills @('albert-design-director') | Out-Null
    }
    catch { $rejected = $_.Exception.Message -match 'requires Verification passed' }
    Assert-True $rejected 'FirstPass yes without passed verification must be rejected.'

    Assert-True (@(Get-Content -LiteralPath $data).Count -eq 2) 'Rejected telemetry must not modify the ledger.'
    Write-Host 'Skill telemetry regression: PASS (legacy, metrics, evidence and rejection)'
}
finally {
    if (Test-Path -LiteralPath $Fixture) {
        Remove-Item -LiteralPath $Fixture -Recurse -Force
    }
}
