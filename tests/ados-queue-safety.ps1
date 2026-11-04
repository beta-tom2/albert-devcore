[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('ados-queue-safety-' + [guid]::NewGuid().ToString('N'))
$Operations = Join-Path $RepoRoot 'scripts\ados-operations.ps1'
$Dispatcher = Join-Path $RepoRoot 'scripts\ados-dispatch.ps1'
$Quality = Join-Path $RepoRoot 'scripts\ados-quality.ps1'
. (Join-Path $RepoRoot 'scripts\ados-common.ps1')

function Assert-QueueSafety {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-QueueRejection {
    param([scriptblock]$Action, [string]$Expected, [string]$Message)
    $failure = ''
    try { & $Action | Out-Null }
    catch { $failure = [string]$_.Exception.Message }
    Assert-QueueSafety ([bool]$failure -and $failure -match $Expected) "$Message (observed: $failure)"
}

function Read-QueueFixture {
    param([string]$Relative)
    return (Get-Content -LiteralPath (Join-Path $Fixture $Relative) -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-QueueEvidence {
    param([string]$TaskText)
    & $Operations checkpoint -ProjectPath $Fixture -Task $TaskText -Phase 'verification'
    & $Quality scope -ProjectPath $Fixture -Task $TaskText -AllowedScope @('src')
    & $Quality verify -ProjectPath $Fixture -MaxLevel 1
    & $Quality evidence -ProjectPath $Fixture -RequireDiff $false
    Assert-QueueSafety ((Read-QueueFixture '.ai\evidence\evidence-gate.generated.json').status -eq 'VERIFIED') 'fixture must produce observed verification evidence'
}

try {
    New-Item -ItemType Directory -Path $Fixture -Force | Out-Null
    Write-AdosUtf8 (Join-Path $Fixture 'src\sample.ps1') "Write-Output 'baseline'`n"
    Push-Location $Fixture
    try {
        & git init -q
        & git config user.name 'ADOS Queue Safety Test'
        & git config user.email 'ados-queue@example.invalid'
        & git add .
        & git commit -q -m 'test: seed queue fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize queue fixture.' }
    }
    finally { Pop-Location }
    Ensure-AdosLocalExclude $Fixture
    $queuePath = Join-Path $Fixture '.ai\queue\tasks.json'
    $lockPath = Join-Path $Fixture '.ai\queue\dispatcher.lock'

    & $Operations queue-next -ProjectPath $Fixture
    Assert-QueueSafety (-not (Test-Path -LiteralPath $queuePath)) 'a missing queue may be read as empty without writing it'

    $invalidQueues = @(
        '{',
        'null',
        '[]',
        '{}',
        '{"schemaVersion":99,"tasks":[]}',
        '{"schemaVersion":2,"tasks":null}',
        '{"schemaVersion":2,"tasks":{}}',
        '{"schemaVersion":2,"tasks":[null]}',
        '{"schemaVersion":2,"tasks":[{"id":"only-an-id"}]}',
        '[{"schemaVersion":2,"tasks":[]}]'
    )
    foreach ($invalid in $invalidQueues) {
        Write-AdosUtf8 $queuePath $invalid
        $before = (Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash
        Assert-QueueRejection { & $Operations queue-add -ProjectPath $Fixture -Task 'Must not replace a damaged queue' } 'Invalid ADOS queue' 'queue-add must fail closed for malformed data'
        Assert-QueueSafety ((Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash -eq $before) 'queue-add must preserve the damaged queue bytes'
        Assert-QueueRejection { & $Dispatcher run -ProjectPath $Fixture -PrepareContext:$false -UseOllama:$false } 'Invalid ADOS queue' 'dispatch must fail closed for malformed data'
        Assert-QueueSafety ((Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash -eq $before) 'dispatch must preserve the damaged queue bytes'
        Assert-QueueSafety (-not (Test-Path -LiteralPath $lockPath)) 'a rejected queue read must release its lock'
    }
    Remove-Item -LiteralPath $queuePath -Force

    & $Operations queue-add -ProjectPath $Fixture -Task 'Verify the queue sample' -Priority high
    $initial = Read-QueueFixture '.ai\queue\tasks.json'
    $initial.schemaVersion = 1
    Write-AdosJson $queuePath $initial
    & $Operations queue-next -ProjectPath $Fixture
    Assert-QueueSafety ((Read-QueueFixture '.ai\queue\next.generated.json').next.task -eq 'Verify the queue sample') 'valid schema v1 queues must remain readable'

    $duplicate = [pscustomobject]@{ schemaVersion=2; tasks=@($initial.tasks[0], $initial.tasks[0]) }
    Write-AdosJson $queuePath $duplicate
    $duplicateHash = (Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash
    Assert-QueueRejection { & $Dispatcher run -ProjectPath $Fixture -PrepareContext:$false -UseOllama:$false } 'duplicate task ID' 'duplicate IDs must be rejected before mutation'
    Assert-QueueSafety ((Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash -eq $duplicateHash) 'duplicate queue records must not be silently collapsed'
    Write-AdosJson $queuePath $initial

    & $Dispatcher run -ProjectPath $Fixture -PrepareContext:$false -UseOllama:$false -LeaseMinutes 10
    $claim = Read-QueueFixture '.ai\queue\dispatch.generated.json'
    $claimedTask = @((Read-QueueFixture '.ai\queue\tasks.json').tasks)[0]
    $leaseStarted = $claimedTask.leaseStarted
    $beforeRenewal = [DateTimeOffset]::Parse($claim.leaseUntil)
    Assert-QueueRejection { & $Dispatcher renew -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId 'wrong-lease' } 'Lease mismatch' 'renewal requires the exact lease'
    & $Dispatcher renew -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId $claim.leaseId -LeaseMinutes 20
    $renewed = Read-QueueFixture '.ai\queue\dispatch.generated.json'
    $renewedTask = @((Read-QueueFixture '.ai\queue\tasks.json').tasks)[0]
    Assert-QueueSafety ($renewed.state -eq 'RENEWED' -and $renewed.leaseId -eq $claim.leaseId) 'renewal must preserve ownership'
    Assert-QueueSafety ([DateTimeOffset]::Parse($renewed.leaseUntil) -gt $beforeRenewal) 'renewal must extend the expiration'
    Assert-QueueSafety ($renewedTask.leaseStarted -eq $leaseStarted) 'renewal must preserve the start of this claim'

    $expired = Read-QueueFixture '.ai\queue\tasks.json'
    $expired.tasks[0].leaseUntil = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    Write-AdosJson $queuePath $expired
    $expiredHash = (Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId $claim.leaseId } 'Lease expired' 'an expired lease must not complete before reclamation'
    Assert-QueueRejection { & $Dispatcher renew -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId $claim.leaseId } 'Lease expired' 'an expired lease must not renew itself'
    Assert-QueueSafety ((Get-FileHash -LiteralPath $queuePath -Algorithm SHA256).Hash -eq $expiredHash) 'expired-owner updates must leave the queue unchanged'

    & $Dispatcher run -ProjectPath $Fixture -PrepareContext:$false -UseOllama:$false
    $reclaimed = Read-QueueFixture '.ai\queue\dispatch.generated.json'
    Assert-QueueSafety ($reclaimed.leaseId -ne $claim.leaseId) 'reclaim must issue a different lease'
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId $claim.leaseId } 'Lease mismatch' 'the old lease must not complete a reclaimed task'
    Assert-QueueRejection { & $Dispatcher renew -ProjectPath $Fixture -QueueId $claim.queueId -LeaseId $claim.leaseId } 'Lease mismatch' 'the old lease must not renew a reclaimed task'
    Assert-QueueRejection { & $Operations queue-complete -ProjectPath $Fixture -QueueId $reclaimed.queueId } 'exact lease ID' 'legacy completion must not bypass a claim'
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'VERIFIED Evidence Gate' 'completion requires observed evidence'

    New-QueueEvidence 'A different task'
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'same queued task' 'evidence for another task must not complete the claim'
    New-QueueEvidence $reclaimed.task
    & $Quality scope -ProjectPath $Fixture -Task 'A different scope task' -AllowedScope @('src')
    & $Quality evidence -ProjectPath $Fixture -RequireDiff $false
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'same queued task' 'scope evidence must refer to the queued task even when the checkpoint matches'
    New-QueueEvidence $reclaimed.task
    $gatePath = Join-Path $Fixture '.ai\evidence\evidence-gate.generated.json'
    $freshGate = Read-QueueFixture '.ai\evidence\evidence-gate.generated.json'
    $freshGate.generated = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
    Write-AdosJson $gatePath $freshGate
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'predates' 'evidence from an earlier attempt must not complete the claim'

    New-QueueEvidence $reclaimed.task
    $verificationPath = Join-Path $Fixture '.ai\evidence\verification.generated.json'
    $oldVerification = Read-QueueFixture '.ai\evidence\verification.generated.json'
    $oldVerification.generated = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
    Write-AdosJson $verificationPath $oldVerification
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'predates' 'a fresh gate must not launder verification from an earlier attempt'

    New-QueueEvidence $reclaimed.task
    Write-AdosUtf8 (Join-Path $Fixture 'src\sample.ps1') "Write-Output 'changed after evidence'`n"
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'current repository state' 'worktree changes must invalidate completion evidence'
    Push-Location $Fixture
    try {
        & git restore -- src/sample.ps1
        & git commit -q --allow-empty -m 'test: advance head after evidence'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to advance fixture HEAD.' }
    }
    finally { Pop-Location }
    Assert-QueueRejection { & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId } 'current repository state' 'HEAD changes must invalidate completion evidence'

    New-QueueEvidence $reclaimed.task
    Write-AdosUtf8 (Join-Path $Fixture 'src\sample.ps1') "Write-Output 'changed before rerunning only the gate'`n"
    & $Quality evidence -ProjectPath $Fixture -RequireDiff $false
    Assert-QueueSafety ((Read-QueueFixture '.ai\evidence\evidence-gate.generated.json').status -eq 'UNVERIFIED') 'rerunning only the gate must reject checks from a different worktree'
    Push-Location $Fixture
    try { & git restore -- src/sample.ps1 }
    finally { Pop-Location }

    New-QueueEvidence $reclaimed.task
    $legacyVerification = Read-QueueFixture '.ai\evidence\verification.generated.json'
    $legacyVerification.PSObject.Properties.Remove('evidenceFingerprint')
    Write-AdosJson $verificationPath $legacyVerification
    & $Quality evidence -ProjectPath $Fixture -RequireDiff $false
    Assert-QueueSafety ((Read-QueueFixture '.ai\evidence\evidence-gate.generated.json').status -eq 'UNVERIFIED') 'legacy PASS results without a source fingerprint must require new verification'

    Write-AdosJson (Join-Path $Fixture 'package.json') ([ordered]@{ scripts=@{ typecheck='node -e "process.exit(2)"' } })
    New-QueueEvidence $reclaimed.task
    & $Quality verify -ProjectPath $Fixture -MaxLevel 2
    $latestVerification = Read-QueueFixture '.ai\evidence\verification.generated.json'
    Assert-QueueSafety ($latestVerification.status -eq 'FAIL' -and $latestVerification.repositoryUnchanged) 'the fixture must fail a later check without changing repository content'
    & $Quality pr-summary -ProjectPath $Fixture -Task $reclaimed.task
    Assert-QueueSafety ((Read-QueueFixture '.ai\evidence\pr-evidence-summary.generated.json').status -eq 'NOT_READY') 'a cached gate must not hide a newer failed verification on the same revision'

    Write-AdosUtf8 (Join-Path $Fixture 'package.json') '{"scripts":{"typecheck":"node mutate-during-verify.cjs"}}'
    Write-AdosUtf8 (Join-Path $Fixture 'mutate-during-verify.cjs') 'require("node:fs").appendFileSync("src/sample.ps1", "# changed during verification\n");'
    & $Quality verify -ProjectPath $Fixture -MaxLevel 2
    $mutatingVerification = Read-QueueFixture '.ai\evidence\verification.generated.json'
    Assert-QueueSafety ($mutatingVerification.status -eq 'FAIL' -and -not $mutatingVerification.repositoryUnchanged) 'a passing command that changes source files must fail verification'
    Assert-QueueSafety (@($mutatingVerification.checks | Where-Object { $_.name -eq 'npm run typecheck' -and $_.status -eq 'PASS' }).Count -eq 1) 'the mutation fixture must run its command successfully'
    Remove-Item -LiteralPath (Join-Path $Fixture 'package.json'), (Join-Path $Fixture 'mutate-during-verify.cjs') -Force
    Push-Location $Fixture
    try { & git restore -- src/sample.ps1 }
    finally { Pop-Location }

    New-QueueEvidence $reclaimed.task
    & $Dispatcher complete -ProjectPath $Fixture -QueueId $reclaimed.queueId -LeaseId $reclaimed.leaseId -ResultStatus completed
    $completed = @((Read-QueueFixture '.ai\queue\tasks.json').tasks)[0]
    Assert-QueueSafety ($completed.status -eq 'completed' -and -not $completed.leaseId) 'fresh verified evidence must allow completion and clear the active lease'
    Assert-QueueSafety ($completed.completionEvidence.leaseId -eq $reclaimed.leaseId) 'completion evidence must retain the lease it verified'
    Assert-QueueSafety ($completed.completionEvidence.head -eq (Get-AdosHead $Fixture)) 'completion must retain its verified revision'

    & $Operations queue-add -ProjectPath $Fixture -Task 'Verify a manually executed task'
    $manual = @((Read-QueueFixture '.ai\queue\tasks.json').tasks | Where-Object { $_.status -eq 'pending' })[0]
    Assert-QueueRejection { & $Operations queue-complete -ProjectPath $Fixture -QueueId $manual.id } 'same queued task' 'manual completion must also require task-specific evidence'
    New-QueueEvidence $manual.task
    & $Operations queue-complete -ProjectPath $Fixture -QueueId $manual.id
    Assert-QueueSafety (@((Read-QueueFixture '.ai\queue\tasks.json').tasks | Where-Object { $_.id -eq $manual.id -and $_.status -eq 'completed' }).Count -eq 1) 'manual completion may succeed with fresh matching evidence'

    & $Operations queue-add -ProjectPath $Fixture -Task 'Blocked on explicit production approval' -Priority protected
    & $Dispatcher run -ProjectPath $Fixture -PrepareContext:$false -UseOllama:$false
    $blockedClaim = Read-QueueFixture '.ai\queue\dispatch.generated.json'
    Remove-Item -LiteralPath $gatePath -Force
    & $Dispatcher complete -ProjectPath $Fixture -QueueId $blockedClaim.queueId -LeaseId $blockedClaim.leaseId -ResultStatus blocked -ResultNote 'No production approval'
    Assert-QueueSafety (@((Read-QueueFixture '.ai\queue\tasks.json').tasks | Where-Object { $_.id -eq $blockedClaim.queueId -and $_.status -eq 'blocked' }).Count -eq 1) 'blocked outcomes must remain recordable without success evidence'

    Write-Host 'ADOS queue safety: PASS'
}
finally {
    if (Test-Path -LiteralPath $Fixture) { Remove-Item -LiteralPath $Fixture -Recurse -Force }
}
