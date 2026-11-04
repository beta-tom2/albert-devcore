[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$updateTestRepo=Split-Path -Parent $PSScriptRoot
$updateTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('devcore-skills-update-' + [guid]::NewGuid().ToString('N'))
$updateTestRuntime=Join-Path $updateTestRoot 'runtime source'
$updateTestProject=Join-Path $updateTestRoot 'project target'
$updateTestTarget=Join-Path $updateTestProject '.agents/skills'
$updateTestBackups=Join-Path $updateTestRoot 'durable backups'
$updateTestManager=Join-Path $updateTestRuntime 'scripts/manage-albert-dev-skills.ps1'
$updateTestChecks=0

function Assert-UpdateTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:updateTestChecks++
    Write-Host "PASS: $Message"
}

function Expect-UpdateTestFailure([scriptblock]$Body,[string]$Pattern,[string]$Message) {
    $failed=$false
    try { & $Body | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure for $Message`: $($_.Exception.Message)" }
        $failed=$true
    }
    Assert-UpdateTest $failed $Message
}

function Write-UpdateTestText([string]$Path,[string]$Text) {
    $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-UpdateTestGit([string[]]$Arguments) {
    $output=@(& git -C $updateTestRuntime @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join ' ')" }
    return (($output | Out-String).Trim())
}

function Get-UpdateTestPlan([string]$Backup='') {
    $parameters=@{ProjectPath=$updateTestProject;BackupRoot=$updateTestBackups;Json=$true}
    if ($Backup) { $parameters.BackupPath=$Backup }
    return ((& $updateTestManager @parameters | Out-String) | ConvertFrom-Json)
}

function Invoke-UpdateTestChange($Plan,[string]$Backup='') {
    $parameters=@{Action='upgrade';ProjectPath=$updateTestProject;BackupRoot=$updateTestBackups;ExpectedInstalledDigest=$Plan.installedDigest;ExpectedSourceDigest=$Plan.sourceDigest;ConfirmChange=$true;Json=$true}
    if ($Backup) { $parameters.Action='restore'; $parameters.BackupPath=$Backup }
    return ((& $updateTestManager @parameters | Out-String) | ConvertFrom-Json)
}

function Get-UpdateTestFileState {
    return (@(Get-ChildItem -LiteralPath $updateTestRoot -Force -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName + '|DIRECTORY' }
        else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n")
}

try {
    $null=[IO.Directory]::CreateDirectory((Join-Path $updateTestRuntime 'scripts'))
    $null=[IO.Directory]::CreateDirectory($updateTestProject)
    Copy-Item -LiteralPath (Join-Path $updateTestRepo 'skills') -Destination $updateTestRuntime -Recurse
    foreach ($scriptName in @('manage-albert-dev-skills.ps1','install-albert-dev-skills.ps1')) {
        Copy-Item -LiteralPath (Join-Path $updateTestRepo ('scripts/' + $scriptName)) -Destination (Join-Path $updateTestRuntime ('scripts/' + $scriptName))
    }
    $null=Invoke-UpdateTestGit @('init','-b','main')
    $null=Invoke-UpdateTestGit @('config','user.name','Skill Update Fixture')
    $null=Invoke-UpdateTestGit @('config','user.email','skill-update-fixture@example.invalid')
    $null=Invoke-UpdateTestGit @('config','core.autocrlf','false')
    $null=Invoke-UpdateTestGit @('add','.')
    $null=Invoke-UpdateTestGit @('commit','-m','Create immutable synthetic source')
    $updateTestSourceHead=Invoke-UpdateTestGit @('rev-parse','HEAD')

    $updateTestOldRouter=Join-Path $updateTestTarget 'albert-skill-router/SKILL.md'
    Write-UpdateTestText $updateTestOldRouter "Old locally adapted router.`r`nKeep my exact bytes.`n"
    Write-UpdateTestText (Join-Path $updateTestTarget 'albert-skill-router/custom/reference.txt') 'User-owned supporting reference'
    $null=[IO.Directory]::CreateDirectory((Join-Path $updateTestTarget 'albert-skill-router/empty/nested'))
    Write-UpdateTestText (Join-Path $updateTestTarget 'albert-architecture-review/SKILL.md') 'Old architecture wrapper'
    $updateTestBinary=Join-Path $updateTestTarget 'albert-architecture-review/local.bin'
    [IO.File]::WriteAllBytes($updateTestBinary,[byte[]]@(0,1,2,13,10,127,128,255))
    # The design director starts absent; restore must recreate that absence.
    $updateTestUnrelated=Join-Path $updateTestTarget 'systematic-debugging/SKILL.md'
    $updateTestVendor=Join-Path $updateTestProject '.agents/.skill-lock.json'
    Write-UpdateTestText $updateTestUnrelated 'Unrelated installed skill must remain byte-identical'
    Write-UpdateTestText $updateTestVendor '{"version":3,"fixture":"preserve vendor lock"}'
    $updateTestUnrelatedHash=(Get-FileHash -LiteralPath $updateTestUnrelated -Algorithm SHA256).Hash
    $updateTestVendorHash=(Get-FileHash -LiteralPath $updateTestVendor -Algorithm SHA256).Hash

    $before=Get-UpdateTestFileState
    $plan=Get-UpdateTestPlan
    Assert-UpdateTest ($plan.state -eq 'PLAN' -and $plan.selection.Count -eq 3 -and $plan.installedDigest -match '^[a-f0-9]{64}$' -and $plan.sourceDigest -match '^[a-f0-9]{64}$' -and $plan.installedDigest -ne $plan.desiredInstalledDigest) 'default plan identifies exact installed and frozen-source digests'
    Assert-UpdateTest ($plan.runtime.commit -eq $updateTestSourceHead -and -not $plan.runtime.dirty -and $plan.source.kind -eq 'runtime-lock') 'source revision and dirty state are separate from artifact and lock digests'
    Assert-UpdateTest ((Get-UpdateTestFileState) -ceq $before) 'planning writes no directories, files, receipts or Git metadata'

    Expect-UpdateTestFailure { & $updateTestManager -Global -ProjectPath $updateTestProject } 'exactly one target' 'ambiguous global plus project target is rejected'
    Expect-UpdateTestFailure { & $updateTestManager -ProjectPath $updateTestProject -BackupRoot $updateTestBackups -Skill 'systematic-debugging' } 'three repository-owned' 'external skills cannot be selected for managed replacement'
    Expect-UpdateTestFailure { & $updateTestManager -Action upgrade -ProjectPath $updateTestProject -BackupRoot $updateTestBackups -ExpectedInstalledDigest $plan.installedDigest -ExpectedSourceDigest $plan.sourceDigest } 'ConfirmChange' 'upgrade requires explicit opt-in'
    Expect-UpdateTestFailure { & $updateTestManager -Action upgrade -ProjectPath $updateTestProject -BackupRoot $updateTestBackups -ExpectedInstalledDigest ('0' * 64) -ExpectedSourceDigest $plan.sourceDigest -ConfirmChange } 'Installed digest mismatch' 'stale installed CAS is rejected before writes'
    Expect-UpdateTestFailure { & $updateTestManager -Action upgrade -ProjectPath $updateTestProject -BackupRoot $updateTestBackups -ExpectedInstalledDigest $plan.installedDigest -ExpectedSourceDigest ('0' * 64) -ConfirmChange } 'Source digest mismatch' 'stale source CAS is rejected before writes'
    Assert-UpdateTest ((Get-UpdateTestFileState) -ceq $before) 'rejected plans and CAS checks leave the entire fixture unchanged'

    $oldRouter=[IO.File]::ReadAllBytes($updateTestOldRouter)
    Write-UpdateTestText $updateTestOldRouter 'New user edit after the reviewed plan'
    $afterUserEdit=Get-UpdateTestFileState
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $plan } 'Installed digest mismatch' 'new user edits after planning block replacement'
    Assert-UpdateTest ((Get-UpdateTestFileState) -ceq $afterUserEdit) 'CAS refusal preserves the new user edit and creates no backup'
    [IO.File]::WriteAllBytes($updateTestOldRouter,$oldRouter)

    $sourceSkill=Join-Path $updateTestRuntime 'skills/albert-skill-router/SKILL.md'
    $sourceSkillBytes=[IO.File]::ReadAllBytes($sourceSkill)
    [IO.File]::AppendAllText($sourceSkill,"`nUnreviewed source edit.")
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $plan } 'Source hash mismatch' 'tampered source bytes cannot pass the lock'
    [IO.File]::WriteAllBytes($sourceSkill,$sourceSkillBytes)
    $sourceLock=Join-Path $updateTestRuntime 'skills/skills-lock.json'
    $sourceLockBytes=[IO.File]::ReadAllBytes($sourceLock)
    [IO.File]::AppendAllText($sourceLock,"`n")
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $plan } 'Source digest mismatch' 'source CAS binds the actual lock bytes as well as skill version labels'
    [IO.File]::WriteAllBytes($sourceLock,$sourceLockBytes)
    $unsafeLock=Get-Content -LiteralPath $sourceLock -Raw | ConvertFrom-Json
    $unsafeLock.skills[0].files[0].path='../outside.md'
    Write-UpdateTestText $sourceLock ($unsafeLock | ConvertTo-Json -Depth 12)
    Expect-UpdateTestFailure { Get-UpdateTestPlan } 'Invalid relative' 'traversal in a locked source path is rejected'
    [IO.File]::WriteAllBytes($sourceLock,$sourceLockBytes)

    $plan=Get-UpdateTestPlan
    $originalDigest=$plan.installedDigest
    $receipt=Invoke-UpdateTestChange $plan
    Assert-UpdateTest ($receipt.state -eq 'COMPLETED' -and $receipt.installedBeforeDigest -eq $originalDigest -and $receipt.installedAfterDigest -eq $plan.desiredInstalledDigest) 'upgrade replaces only the selected complete directory set with verified staged artifacts'
    Assert-UpdateTest ($receipt.runtime.commit -eq $updateTestSourceHead -and $receipt.sourceDigest -eq $plan.sourceDigest -and (Test-Path -LiteralPath (Join-Path $receipt.backupPath 'backup.json'))) 'a durable backup and receipt record actual source revision and both artifact digests'
    Assert-UpdateTest (-not (Test-Path -LiteralPath (Join-Path $updateTestTarget 'albert-skill-router/custom/reference.txt')) -and (Test-Path -LiteralPath (Join-Path $receipt.backupPath 'previous/albert-skill-router/custom/reference.txt')) -and (Test-Path -LiteralPath (Join-Path $receipt.backupPath 'previous/albert-skill-router/empty/nested') -PathType Container)) 'full old catalogs including custom files and empty directories survive in the backup'
    Assert-UpdateTest ((Get-FileHash -LiteralPath $updateTestUnrelated -Algorithm SHA256).Hash -eq $updateTestUnrelatedHash -and (Get-FileHash -LiteralPath $updateTestVendor -Algorithm SHA256).Hash -eq $updateTestVendorHash) 'unrelated skills and the vendor lock are preserved'
    $beforeRepeat=Get-UpdateTestFileState
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $plan } 'Installed digest mismatch' 'repeating old expected digests cannot silently repeat an upgrade'
    Assert-UpdateTest ((Get-UpdateTestFileState) -ceq $beforeRepeat) 'repeated stale upgrade makes no writes'
    $currentPlan=Get-UpdateTestPlan
    $already=Invoke-UpdateTestChange $currentPlan
    Assert-UpdateTest ($already.state -eq 'ALREADY_CURRENT' -and (Get-UpdateTestFileState) -ceq $beforeRepeat) 'a fresh matching plan reports already-current without creating another backup'

    $backupPath=$receipt.backupPath
    $beforeRestorePlan=Get-UpdateTestFileState
    $restorePlan=Get-UpdateTestPlan $backupPath
    Assert-UpdateTest ($restorePlan.action -eq 'restore' -and $restorePlan.source.kind -eq 'backup' -and $restorePlan.desiredInstalledDigest -eq $originalDigest -and (Get-UpdateTestFileState) -ceq $beforeRestorePlan) 'restore planning validates backup contents without writes'
    $backupSkill=Join-Path $backupPath 'previous/albert-skill-router/SKILL.md'
    $backupSkillBytes=[IO.File]::ReadAllBytes($backupSkill)
    [IO.File]::AppendAllText($backupSkill,'tampered backup')
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $restorePlan $backupPath } 'Backup content or manifest was changed' 'tampered backup bytes block restore'
    [IO.File]::WriteAllBytes($backupSkill,$backupSkillBytes)
    $backupManifestPath=Join-Path $backupPath 'backup.json'
    $backupManifestBytes=[IO.File]::ReadAllBytes($backupManifestPath)
    [IO.File]::AppendAllText($backupManifestPath,"`n")
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $restorePlan $backupPath } 'Source digest mismatch' 'restore CAS also detects changed backup manifest bytes'
    [IO.File]::WriteAllBytes($backupManifestPath,$backupManifestBytes)
    $newUserFile=Join-Path $updateTestTarget 'albert-skill-router/new-user-note.txt'
    Write-UpdateTestText $newUserFile 'A new user change must never disappear silently'
    $beforeRestoreConflict=Get-UpdateTestFileState
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $restorePlan $backupPath } 'Installed digest mismatch' 'restore rejects user changes made after its plan'
    Assert-UpdateTest ((Get-UpdateTestFileState) -ceq $beforeRestoreConflict) 'rejected restore preserves the changed installed files'
    $restorePlan=Get-UpdateTestPlan $backupPath
    $restored=Invoke-UpdateTestChange $restorePlan $backupPath
    $afterRestore=Get-UpdateTestPlan
    Assert-UpdateTest ($restored.state -eq 'COMPLETED' -and $afterRestore.installedDigest -eq $originalDigest -and -not (Test-Path -LiteralPath (Join-Path $updateTestTarget 'albert-design-director'))) 'reviewed restore reproduces exact original file bytes, directories and missing-package state'
    Assert-UpdateTest ((Test-Path -LiteralPath (Join-Path $restored.backupPath 'previous/albert-skill-router/new-user-note.txt')) -and ([BitConverter]::ToString([IO.File]::ReadAllBytes($updateTestBinary))) -eq '00-01-02-0D-0A-7F-80-FF') 'restore backs up the current edited installation and preserves original binary bytes'

    # Faults are injected only into this disposable copy, never through a
    # production flag or global command override. Its new source digest must be
    # planned again before each attempt, just like any real source change.
    $managerOriginal=[IO.File]::ReadAllBytes($updateTestManager)
    $managerText=[Text.Encoding]::UTF8.GetString($managerOriginal)
    $renameLine='[IO.Directory]::Move($Source,$Destination)'
    if ([regex]::Matches($managerText,[regex]::Escape($renameLine)).Count -ne 1) { throw 'Expected exactly one fixture rename boundary.' }
    $failureCode=@'
if ($Source.Replace('\','/') -like '*/stage/.agents/skills/albert-design-director') { throw 'Injected promotion failure.' }
[IO.Directory]::Move($Source,$Destination)
'@
    Write-UpdateTestText $updateTestManager ($managerText.Replace($renameLine,$failureCode))
    $failurePlan=Get-UpdateTestPlan
    $beforeFailureBackups=@(Get-ChildItem -LiteralPath $updateTestBackups -Directory | ForEach-Object { $_.FullName })
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $failurePlan } 'Injected promotion failure' 'a partial replacement failure is reported'
    [IO.File]::WriteAllBytes($updateTestManager,$managerOriginal)
    $afterFailure=Get-UpdateTestPlan
    $failedBackup=@(Get-ChildItem -LiteralPath $updateTestBackups -Directory | Where-Object { $beforeFailureBackups -notcontains $_.FullName })
    Assert-UpdateTest ($afterFailure.installedDigest -eq $originalDigest -and $failedBackup.Count -eq 1) 'partial promotion restores the exact prior selected directory set'
    $failedReceipt=Get-Content -LiteralPath (Join-Path $failedBackup[0].FullName 'receipt.json') -Raw | ConvertFrom-Json
    Assert-UpdateTest ($failedReceipt.state -eq 'ROLLED_BACK' -and (Test-Path -LiteralPath (Join-Path $failedReceipt.workspace 'failed-new/albert-architecture-review')) -and -not (Test-Path -LiteralPath (Join-Path $updateTestProject '.agents/.albert-skills-update.lock'))) 'rollback keeps failed replacement bytes for inspection and releases its writer lock'

    # Reproduce the check/rename race during rollback. The directory is created
    # after the manager's Test-Path guard, immediately before the real .NET move.
    $concurrentCode=@'
if ($Source.Replace('\','/') -like '*/stage/.agents/skills/albert-design-director') { throw 'Injected promotion failure.' }
if ($Source.Replace('\','/') -like '*/displaced/albert-architecture-review') {
    $null=[IO.Directory]::CreateDirectory($Destination)
    [IO.File]::WriteAllText((Join-Path $Destination 'concurrent.txt'),'Concurrent writer content')
}
[IO.Directory]::Move($Source,$Destination)
'@
    Write-UpdateTestText $updateTestManager ($managerText.Replace($renameLine,$concurrentCode))
    $concurrentPlan=Get-UpdateTestPlan
    $beforeConcurrentBackups=@(Get-ChildItem -LiteralPath $updateTestBackups -Directory | ForEach-Object { $_.FullName })
    Expect-UpdateTestFailure { Invoke-UpdateTestChange $concurrentPlan } 'Injected promotion failure' 'concurrent rollback destination prevents silent nesting'
    [IO.File]::WriteAllBytes($updateTestManager,$managerOriginal)
    $concurrentBackup=@(Get-ChildItem -LiteralPath $updateTestBackups -Directory | Where-Object { $beforeConcurrentBackups -notcontains $_.FullName })
    if ($concurrentBackup.Count -ne 1) { throw 'Expected one concurrent recovery backup.' }
    $concurrentReceipt=Get-Content -LiteralPath (Join-Path $concurrentBackup[0].FullName 'receipt.json') -Raw | ConvertFrom-Json
    $concurrentTarget=Join-Path $updateTestTarget 'albert-architecture-review'
    $displacedOriginal=Join-Path $concurrentReceipt.workspace 'displaced/albert-architecture-review'
    Assert-UpdateTest ($concurrentReceipt.state -eq 'RECOVERY_REQUIRED' -and (Get-Content -LiteralPath (Join-Path $concurrentTarget 'concurrent.txt') -Raw) -eq 'Concurrent writer content' -and -not (Test-Path -LiteralPath (Join-Path $concurrentTarget 'albert-architecture-review'))) 'existing concurrent directory remains intact and receives no nested old package'
    Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $displacedOriginal 'SKILL.md') -Raw) -eq 'Old architecture wrapper' -and $concurrentReceipt.installedAfterDigest -ne $originalDigest) 'original bytes remain in displaced storage and failed rollback never claims the original digest'
    # Complete recovery only inside this known fixture, preserving its synthetic
    # concurrent folder separately before continuing the remaining checks.
    [IO.Directory]::Move($concurrentTarget,(Join-Path $updateTestRoot 'preserved concurrent fixture'))
    [IO.Directory]::Move($displacedOriginal,$concurrentTarget)

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $junction=Join-Path $updateTestTarget 'albert-skill-router/linked-content'
        $junctionTarget=Join-Path $updateTestRoot 'junction target'
        $null=[IO.Directory]::CreateDirectory($junctionTarget)
        Write-UpdateTestText (Join-Path $junctionTarget 'untouched.txt') 'Do not follow this linked directory'
        $null=New-Item -ItemType Junction -Path $junction -Target $junctionTarget
        try { Expect-UpdateTestFailure { Get-UpdateTestPlan } 'Linked skill content' 'reparse-point content is rejected before following the link' }
        finally { [IO.Directory]::Delete($junction) }
        Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $junctionTarget 'untouched.txt') -Raw) -eq 'Do not follow this linked directory') 'the rejected junction target is unchanged'
    }
    Assert-UpdateTest ((Get-FileHash -LiteralPath $updateTestUnrelated -Algorithm SHA256).Hash -eq $updateTestUnrelatedHash -and (Get-FileHash -LiteralPath $updateTestVendor -Algorithm SHA256).Hash -eq $updateTestVendorHash) 'unrelated packages and vendor metadata survive upgrade, restore and rollback'
    Write-Host "DevCore skill update tests passed: $updateTestChecks checks."
}
finally {
    if (Test-Path -LiteralPath $updateTestRoot) { Remove-Item -LiteralPath $updateTestRoot -Recurse -Force }
}
