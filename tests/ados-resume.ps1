[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$devcoreRoot = Split-Path -Parent $PSScriptRoot
$operations = Join-Path $devcoreRoot 'scripts/ados-operations.ps1'
. (Join-Path $devcoreRoot 'scripts/ados-common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ados-resume-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-ResumeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

function Invoke-ResumeGit {
    param([string[]]$Arguments)
    $result = @(& git -C $testRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed: $($result -join ' ')" }
    return (($result | Out-String).Trim())
}

function Save-ResumeFixtureCheckpoint {
    & $operations checkpoint -ProjectPath $testRoot -Task 'Continue a synthetic recovery task' -Phase 'implementation'
}

function Read-ResumeFixturePacket {
    & $operations resume -ProjectPath $testRoot
    return (Get-Content -LiteralPath (Join-Path $testRoot '.ai/context/resume.generated.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

try {
    Ensure-AdosDirectory $testRoot
    $null = Invoke-ResumeGit @('init', '-q', '-b', 'main')
    $null = Invoke-ResumeGit @('config', 'user.name', 'ADOS Resume Fixture')
    $null = Invoke-ResumeGit @('config', 'user.email', 'ados-resume-fixture@example.invalid')
    $null = Invoke-ResumeGit @('config', 'core.autocrlf', 'false')
    $readme = Join-Path $testRoot 'README.md'
    Write-AdosUtf8 $readme "# Synthetic resume fixture`nInitial state.`n"
    $null = Invoke-ResumeGit @('add', 'README.md')
    $null = Invoke-ResumeGit @('commit', '-q', '-m', 'Create synthetic resume fixture')

    Save-ResumeFixtureCheckpoint
    $checkpointPath = Join-Path $testRoot '.ai/checkpoints/current.json'
    $saved = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-ResumeTest ($saved.evidenceFingerprint -cmatch '^[a-f0-9]{64}$') 'new checkpoints save the existing evidence fingerprint'
    $checkpointHash = (Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'UNCHANGED' -and $packet.reasons -contains 'BASELINE_UNCHANGED') 'unchanged revision and worktree have an explicit unchanged baseline'
    Assert-ResumeTest ($packet.safeToResume -and -not $packet.revalidationRequired -and -not $packet.fingerprintChanged) 'unchanged baseline keeps the conservative compatibility advisory'
    Assert-ResumeTest ($packet.verificationStatus -eq 'NOT_EVALUATED' -and $packet.nextAction -match 'Evidence Gate') 'unchanged baseline does not claim evidence is verified'
    Assert-ResumeTest ((Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash -eq $checkpointHash) 'resume preserves the saved checkpoint'
    Assert-ResumeTest ((Invoke-ResumeGit @('status', '--porcelain')) -eq '') 'generated checkpoint and resume files leave tracked fixture state clean'

    Write-AdosUtf8 $readme "# Synthetic resume fixture`nFirst local edit.`n"
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'WORKTREE_CHANGED' -and -not $packet.headChanged -and -not $packet.branchChanged) 'same-HEAD worktree changes are distinguished from revision changes'
    Assert-ResumeTest ($packet.revalidationRequired -and -not $packet.safeToResume -and $packet.fingerprintChanged) 'worktree drift requires revalidation without claiming old evidence is current'

    Save-ResumeFixtureCheckpoint
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'UNCHANGED' -and $packet.safeToResume) 'a recorded dirty baseline can be resumed when its bytes are unchanged'
    Write-AdosUtf8 $readme "# Synthetic resume fixture`nSecond local edit in the same file.`n"
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'WORKTREE_CHANGED' -and $packet.reasons -contains 'WORKTREE_CHANGED') 'fingerprint detects changed bytes even when the changed-file list is unchanged'

    $null = Invoke-ResumeGit @('add', 'README.md')
    $null = Invoke-ResumeGit @('commit', '-q', '-m', 'Continue on the same branch')
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'HEAD_CHANGED' -and $packet.headChanged -and -not $packet.branchChanged) 'new commit on the same branch is reported without preventing resume'
    Assert-ResumeTest ($packet.revalidationRequired -and -not $packet.safeToResume -and $packet.nextAction -match 'continue on this branch') 'HEAD drift calls for review and normal continuation with new checks'

    Save-ResumeFixtureCheckpoint
    $null = Invoke-ResumeGit @('checkout', '-q', '-b', 'recovery-review')
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'BRANCH_CHANGED' -and $packet.branchChanged -and -not $packet.headChanged) 'branch change at the same commit is explicit'
    Assert-ResumeTest ($packet.revalidationRequired -and -not $packet.safeToResume -and $packet.nextAction -match 'task scope') 'branch drift asks for scope review before choosing where to continue'

    $null = Invoke-ResumeGit @('checkout', '-q', 'main')
    Save-ResumeFixtureCheckpoint
    $saved = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved.PSObject.Properties.Remove('evidenceFingerprint')
    Write-AdosJson $checkpointPath $saved
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'BASELINE_UNKNOWN' -and $packet.reasons -contains 'CHECKPOINT_FINGERPRINT_MISSING') 'legacy checkpoint without fingerprint remains readable with unknown freshness'
    Assert-ResumeTest ($null -eq $packet.fingerprintChanged -and $packet.revalidationRequired -and -not $packet.safeToResume) 'missing fingerprint is unknown rather than an unchanged baseline'

    $saved | Add-Member -NotePropertyName evidenceFingerprint -NotePropertyValue 'unknown-fingerprint'
    Write-AdosJson $checkpointPath $saved
    $packet = Read-ResumeFixturePacket
    Assert-ResumeTest ($packet.status -eq 'BASELINE_UNKNOWN' -and $packet.reasons -contains 'CHECKPOINT_FINGERPRINT_UNKNOWN') 'unrecognized fingerprint never gives a fresh-baseline advisory'

    Save-ResumeFixtureCheckpoint
    Write-AdosJson (Join-Path $testRoot '.ai/evidence/evidence-gate.generated.json') ([ordered]@{ status = 'VERIFIED'; head = ('0' * 40); evidenceFingerprint = ('0' * 64) })
    $packet = Read-ResumeFixturePacket
    $resumeText = Get-Content -LiteralPath (Join-Path $testRoot '.ai/context/resume.generated.md') -Raw -Encoding UTF8
    Assert-ResumeTest ($packet.status -eq 'UNCHANGED' -and $packet.verificationStatus -eq 'NOT_EVALUATED') 'resume does not promote a cached verified gate to current evidence'
    Assert-ResumeTest ($resumeText -match 'does not validate prior evidence or grant permission to edit') 'human-readable resume states the advisory and evidence boundary'

    Write-Host "ADOS resume tests passed: $passed assertions"
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
