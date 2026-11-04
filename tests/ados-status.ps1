[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$statusTestRepoRoot=Split-Path -Parent $PSScriptRoot
$statusTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('ados-status-' + [guid]::NewGuid().ToString('N'))
$statusTestRuntime=Join-Path $statusTestRoot 'runtime with spaces'
$statusTestProject=Join-Path $statusTestRoot 'project with spaces'
$statusTestSkills=Join-Path $statusTestRoot 'isolated skills'
$statusTestScript=Join-Path $statusTestRuntime 'scripts/ados-status.ps1'
$statusTestChecks=0

function Assert-StatusTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:statusTestChecks++
    Write-Host "PASS: $Message"
}

function Write-StatusTestText {
    param([string]$Path,[string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))
}

function Write-StatusTestJson {
    param([string]$Path,$Value)
    Write-StatusTestText $Path ($Value | ConvertTo-Json -Depth 12)
}

function Invoke-StatusTestGit {
    param([string]$Path,[string[]]$Arguments)
    $output=@(& git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git command failed: $($output -join ' ')" }
    return (($output | Out-String).Trim())
}

function Initialize-StatusTestRepository {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $null=Invoke-StatusTestGit $Path @('init','-b','main')
    $null=Invoke-StatusTestGit $Path @('config','user.name','ADOS Status Fixture')
    $null=Invoke-StatusTestGit $Path @('config','user.email','ados-status-fixture@example.invalid')
    $null=Invoke-StatusTestGit $Path @('config','core.autocrlf','false')
    Write-StatusTestText (Join-Path $Path 'README.md') "# Synthetic fixture`n"
}

function Get-StatusTest {
    param([string]$Project=$statusTestProject,[string]$Expected='', [switch]$Schedules)
    $text=& $statusTestScript -ProjectPath $Project -SkillsRoot $statusTestSkills -ExpectedRuntimeCommit $Expected -IncludeSchedules:$Schedules -Json | Out-String
    return ($text | ConvertFrom-Json)
}

function Get-StatusTestFileState {
    # Include ignored files and Git metadata, so an index refresh or an implicit
    # setup/export/report write cannot pass merely because Git still looks clean.
    return (@(Get-ChildItem -LiteralPath $statusTestRoot -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName + '|DIRECTORY' }
        else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n")
}

try {
    Initialize-StatusTestRepository $statusTestRuntime
    Initialize-StatusTestRepository $statusTestProject
    Write-StatusTestText (Join-Path $statusTestRuntime 'ados.ps1') "throw 'A status query must never execute a scheduled action.'`n"
    New-Item -ItemType Directory -Path (Split-Path -Parent $statusTestScript) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $statusTestRepoRoot 'scripts/ados-status.ps1') -Destination $statusTestScript
    $statusTestNames=@('albert-skill-router','albert-architecture-review','albert-design-director')
    $statusTestManifest=@()
    foreach ($name in $statusTestNames) {
        $files=@()
        $relativeFiles=@('SKILL.md')
        # An older package without a lineage file remains a valid locked package.
        if ($name -ne 'albert-architecture-review') { $relativeFiles+=@('references/lineage.json') }
        if ($name -eq 'albert-skill-router') { $relativeFiles+=@('references/project-state.md') }
        foreach ($relative in $relativeFiles) {
            $target=Join-Path (Join-Path $statusTestSkills $name) $relative
            if ($relative -eq 'references/lineage.json') {
                Write-StatusTestJson $target ([ordered]@{schemaVersion=1;skillName=$name;adapter='codex';contractVersion='1.1.0';sourceRepository='fixture/runtime';baselineSourceCommit=('a' * 40)})
            }
            else { Write-StatusTestText $target ("Synthetic $name $relative`n") }
            $files+=@([ordered]@{path=$relative;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()})
        }
        $statusTestManifest+=@([ordered]@{name=$name;kind='repository-owned';state='verified-local';files=$files})
    }
    # External catalog entries must not be mistaken for installed core packages.
    $statusTestManifest+=@([ordered]@{name='external-candidate';kind='external';state='needs-audit'})
    $statusTestLockPath=Join-Path $statusTestRuntime 'skills/skills-lock.json'
    Write-StatusTestJson $statusTestLockPath ([ordered]@{schemaVersion=1;skills=$statusTestManifest})
    Write-StatusTestJson (Join-Path $statusTestRuntime 'skills/contract.json') ([ordered]@{schemaVersion=1;contractVersion='1.1.0';coreSkills=$statusTestNames})
    $null=Invoke-StatusTestGit $statusTestRuntime @('add','.')
    $null=Invoke-StatusTestGit $statusTestRuntime @('commit','-m','Create synthetic runtime')
    $null=Invoke-StatusTestGit $statusTestProject @('add','.')
    $null=Invoke-StatusTestGit $statusTestProject @('commit','-m','Create synthetic project')
    $statusTestRuntimeHead=Invoke-StatusTestGit $statusTestRuntime @('rev-parse','HEAD')
    $statusTestProjectHead=Invoke-StatusTestGit $statusTestProject @('rev-parse','HEAD')

    $statusTestBefore=Get-StatusTestFileState
    $status=Get-StatusTest -Expected $statusTestRuntimeHead
    Assert-StatusTest ($status.readOnly -and $status.runtime.available -and $status.runtime.commit -eq $statusTestRuntimeHead -and -not $status.runtime.dirty -and $status.runtime.expected.status -eq 'MATCH') 'actual runtime path, clean revision and explicitly expected commit are observed'
    Assert-StatusTest ($status.runtime.path -eq $statusTestRuntime -and $status.skills.core.Count -eq 3 -and $status.skills.status -eq 'MATCH') 'only locked core packages are inspected at the supplied SkillsRoot'
    Assert-StatusTest ($status.contract.contractVersion -eq '1.1.0' -and $status.skills.core[0].lineage.status -eq 'MATCH' -and $status.skills.core[1].lineage.status -eq 'UNKNOWN' -and $status.skills.core[1].status -eq 'MATCH') 'lineage contract is observed while legacy missing lineage remains unknown'
    Assert-StatusTest ($status.project.memory.configuration.status -eq 'MISSING' -and $status.project.memory.export.status -eq 'MISSING' -and $status.project.memory.publication.status -eq 'MISSING' -and $status.project.memory.cloudFreshness -eq 'UNKNOWN' -and $status.schedules.status -eq 'NOT_REQUESTED') 'absent memory stages and unrequested schedules are distinguished without claiming remote state'
    Assert-StatusTest ((Get-StatusTestFileState) -ceq $statusTestBefore) 'status leaves all fixture bytes, timestamps and Git metadata unchanged'

    $status=Get-StatusTest -Expected ('0' * 40)
    Assert-StatusTest ($status.runtime.expected.status -eq 'MISMATCH' -and $status.runtime.expected.resolution -eq 'EXPLICIT_COMMIT') 'an explicit different commit is a mismatch even when its object is unavailable locally'
    $status=Get-StatusTest -Expected 'missing-local-ref'
    Assert-StatusTest ($status.runtime.expected.status -eq 'UNRESOLVED') 'missing refs do not fetch or guess the latest version'
    $status=Get-StatusTest -Expected 'main'
    Assert-StatusTest ($status.runtime.expected.status -eq 'MATCH' -and $status.runtime.expected.resolution -eq 'LOCAL_REF_ONLY') 'a supplied local ref is resolved explicitly'
    Write-StatusTestText (Join-Path $statusTestRuntime 'README.md') "# Locally changed runtime`n"
    $status=Get-StatusTest -Expected $statusTestRuntimeHead
    Assert-StatusTest ($status.runtime.dirty -and $status.runtime.expected.status -eq 'MATCH') 'matching HEAD does not conceal dirty runtime files'

    $statusTestOutside=Join-Path $statusTestRoot 'outside repository'
    New-Item -ItemType Directory -Path $statusTestOutside -Force | Out-Null
    $status=Get-StatusTest -Project $statusTestOutside
    Assert-StatusTest (-not $status.project.available -and $status.project.status -eq 'NOT_A_REPOSITORY' -and $status.runtime.available -and $status.skills.status -eq 'MATCH') 'status outside a project still reports runtime and skills'
    $status=Get-StatusTest -Project (Join-Path $statusTestRoot 'missing directory')
    Assert-StatusTest (-not $status.project.available -and $status.project.status -eq 'PATH_NOT_FOUND') 'a nonexistent project does not abort diagnostics'

    $statusTestCore=Join-Path $statusTestSkills 'albert-skill-router'
    $statusTestSkillPath=Join-Path $statusTestCore 'SKILL.md'
    $statusTestSkillOriginal=[IO.File]::ReadAllBytes($statusTestSkillPath)
    Write-StatusTestText $statusTestSkillPath "Changed local skill`n"
    Remove-Item -LiteralPath (Join-Path $statusTestCore 'references/project-state.md')
    Write-StatusTestText (Join-Path $statusTestCore 'unlocked.ps1') "throw 'Never execute this file.'`n"
    $status=Get-StatusTest
    $router=@($status.skills.core | Where-Object { $_.name -eq 'albert-skill-router' })[0]
    Assert-StatusTest ($status.skills.status -eq 'ATTENTION' -and $router.status -eq 'DIFFERENT' -and @($router.files | Where-Object { $_.status -eq 'MISMATCH' }).Count -eq 1 -and @($router.files | Where-Object { $_.status -eq 'MISSING' }).Count -eq 1 -and $router.unexpectedFiles -contains 'unlocked.ps1') 'hash drift, missing references and unlocked files are reported separately'
    [IO.File]::WriteAllBytes($statusTestSkillPath,$statusTestSkillOriginal)
    Write-StatusTestText (Join-Path $statusTestCore 'references/project-state.md') "Synthetic albert-skill-router references/project-state.md`n"
    Remove-Item -LiteralPath (Join-Path $statusTestCore 'unlocked.ps1')
    $statusTestLineagePath=Join-Path $statusTestCore 'references/lineage.json'
    $statusTestLineage=Get-Content -LiteralPath $statusTestLineagePath -Raw | ConvertFrom-Json
    $statusTestLineage.contractVersion='9.9.9'
    Write-StatusTestJson $statusTestLineagePath $statusTestLineage
    $status=Get-StatusTest
    Assert-StatusTest ($status.skills.core[0].lineage.status -eq 'MISMATCH') 'different adapter contract versions are visible separately from byte hashes'

    $statusTestConfig=Join-Path $statusTestProject '.ados/state-export.json'
    $statusTestSnapshot=Join-Path $statusTestProject '.ai/local-output/project-state.json'
    $statusTestReceipt=Join-Path $statusTestProject '.ai/local-output/state-publish.receipt.json'
    Write-StatusTestJson $statusTestConfig ([ordered]@{schemaVersion=1;projectId='FIXTURE';repository=@{fullName='fixture/project';visibility='private'};sources=@('README.md');includeTaskSummary=$false})
    Write-StatusTestJson $statusTestSnapshot ([ordered]@{schemaVersion=1;projectId='FIXTURE';repository=@{fullName='fixture/project';visibility='private'};source=@{commit=$statusTestProjectHead};privateBody='PRIVATE-PAYLOAD-MUST-NOT-APPEAR'})
    Write-StatusTestJson $statusTestReceipt ([ordered]@{schemaVersion=1;published=$true;cloudFreshness='CURRENT';privateBody='PRIVATE-PAYLOAD-MUST-NOT-APPEAR'})
    $statusTestBefore=Get-StatusTestFileState
    $status=Get-StatusTest
    Assert-StatusTest ($status.project.memory.configuration.status -eq 'CONFIGURED' -and $status.project.memory.export.status -eq 'EXPORTED_LOCAL' -and $status.project.memory.export.validation -eq 'METADATA_ONLY' -and $status.project.memory.export.sourceMatchesCurrentHead -and $status.project.memory.export.identityMatchesConfiguration) 'configuration and exported metadata are separate observations with revision and identity checks'
    Assert-StatusTest ($status.project.memory.publication.status -eq 'RECEIPT_OBSERVED' -and -not $status.project.memory.publication.remoteChecked -and $status.project.memory.cloudFreshness -eq 'UNKNOWN' -and ($status | ConvertTo-Json -Depth 16) -notmatch 'PRIVATE-PAYLOAD') 'local receipts cannot assert cloud freshness or leak arbitrary document fields'
    Assert-StatusTest ((Get-StatusTestFileState) -ceq $statusTestBefore) 'observing configured memory does not refresh, replace or publish it'
    Write-StatusTestJson $statusTestSnapshot ([ordered]@{schemaVersion=1;projectId='OTHER';repository=@{fullName='fixture/other';visibility='private'};source=@{commit=('f' * 40)}})
    $status=Get-StatusTest
    Assert-StatusTest (-not $status.project.memory.export.sourceMatchesCurrentHead -and -not $status.project.memory.export.identityMatchesConfiguration) 'stale and wrong-project snapshots are not treated as current project state'
    Write-StatusTestText $statusTestConfig '{ broken json'
    $status=Get-StatusTest
    Assert-StatusTest ($status.project.memory.configuration.status -eq 'INVALID_JSON' -and $status.runtime.available) 'corrupt local metadata is reported without suppressing other diagnostics'

    $statusTestLockOriginal=[IO.File]::ReadAllBytes($statusTestLockPath)
    $statusTestUnsafe=Get-Content -LiteralPath $statusTestLockPath -Raw | ConvertFrom-Json
    $statusTestUnsafe.skills[0].files[0].path='../outside.md'
    Write-StatusTestJson $statusTestLockPath $statusTestUnsafe
    $status=Get-StatusTest
    Assert-StatusTest ($status.skills.status -eq 'INVALID_MANIFEST' -and $status.skills.core.Count -eq 0) 'unsafe manifest paths fail before any installed file is inspected'
    [IO.File]::WriteAllBytes($statusTestLockPath,$statusTestLockOriginal)

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $statusTestOtherRuntime=Join-Path $statusTestRoot 'older scheduled runtime'
        Initialize-StatusTestRepository $statusTestOtherRuntime
        Write-StatusTestText (Join-Path $statusTestOtherRuntime 'ados.ps1') "throw 'Never execute the older scheduled action.'`n"
        $null=Invoke-StatusTestGit $statusTestOtherRuntime @('add','.')
        $null=Invoke-StatusTestGit $statusTestOtherRuntime @('commit','-m','Create separate scheduled runtime')
        $statusTestOtherHead=Invoke-StatusTestGit $statusTestOtherRuntime @('rev-parse','HEAD')
        # Functions shadow ScheduledTasks only in this test script's scope.
        # No global command, scheduled task, environment or user profile changes.
        function Get-ScheduledTask {
            [CmdletBinding()]
            param([string]$TaskName)
            if ($TaskName -ne 'ADOS-Night-*') { throw 'Unbounded scheduler query.' }
            [pscustomobject]@{TaskName='ADOS-Night-fixture';TaskPath='\';State='Ready';Actions=@([pscustomobject]@{Execute='powershell.exe';WorkingDirectory=$statusTestRuntime;Arguments=('-NoProfile -File "' + (Join-Path $statusTestRuntime 'ados.ps1') + '" night -ProjectPath "' + $statusTestProject + '" -Secret PRIVATE-ARGUMENT')})}
            [pscustomobject]@{TaskName='ADOS-Night-older';TaskPath='\';State='Ready';Actions=@([pscustomobject]@{Execute='powershell.exe';WorkingDirectory=$statusTestOtherRuntime;Arguments=('-File "' + (Join-Path $statusTestOtherRuntime 'ados.ps1') + '" night')})}
            [pscustomobject]@{TaskName='ADOS-Night-command';TaskPath='\';State='Disabled';Actions=@([pscustomobject]@{Execute='powershell.exe';WorkingDirectory=$statusTestRuntime;Arguments='-Command "Write-Output -File C:\not-a-script.ps1"'})}
            [pscustomobject]@{TaskName='Unrelated-task';TaskPath='\';State='Ready';Actions=@()}
        }
        function Get-ScheduledTaskInfo {
            [CmdletBinding()]
            param($InputObject)
            [pscustomobject]@{LastRunTime=[datetime]'2026-01-01T03:00:00';NextRunTime=[datetime]'2026-01-02T03:00:00';LastTaskResult=0}
        }
        $statusTestBefore=Get-StatusTestFileState
        $status=Get-StatusTest -Schedules
        Assert-StatusTest ($status.schedules.status -eq 'OBSERVED' -and $status.schedules.tasks.Count -eq 3 -and $status.schedules.tasks[0].actions[0].resolvedScriptPath -eq (Join-Path $statusTestRuntime 'ados.ps1') -and $status.schedules.tasks[0].actions[0].sameRuntimePath -and $status.schedules.tasks[0].actions[0].runtime.commit -eq $statusTestRuntimeHead) 'filtered schedule metadata identifies the exact script and actual runtime revision without executing it'
        Assert-StatusTest (-not $status.schedules.tasks[1].actions[0].sameRuntimePath -and $status.schedules.tasks[1].actions[0].runtime.commit -eq $statusTestOtherHead) 'a task invoking another runtime reports that path and revision rather than the active status version'
        Assert-StatusTest ($null -eq $status.schedules.tasks[2].actions[0].resolvedScriptPath -and $null -eq $status.schedules.tasks[2].actions[0].runtime) 'command text is not mistaken for a discoverable -File action'
        Assert-StatusTest (($status | ConvertTo-Json -Depth 16) -notmatch 'PRIVATE-ARGUMENT' -and (Get-StatusTestFileState) -ceq $statusTestBefore) 'schedule observation emits no raw arguments and leaves fixture state unchanged'
    }
    else {
        $status=Get-StatusTest -Schedules
        Assert-StatusTest ($status.schedules.status -eq 'UNSUPPORTED_PLATFORM') 'non-Windows schedule metadata is explicitly unavailable'
    }

    Write-Host "ADOS status tests passed: $statusTestChecks checks."
}
finally {
    if (Test-Path -LiteralPath $statusTestRoot) { Remove-Item -LiteralPath $statusTestRoot -Recurse -Force }
}
