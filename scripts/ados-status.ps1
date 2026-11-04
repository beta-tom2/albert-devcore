[CmdletBinding()]
param(
    [string]$ProjectPath='.',
    [string]$SkillsRoot='',
    [string]$ExpectedRuntimeCommit='',
    [switch]$IncludeSchedules,
    [switch]$Json
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

# Deliberately independent of setup/export/scheduler commands: observing status
# must not create directories, refresh an index, write reports, or run task actions.
function Get-StatusProperty {
    param($Value,[string]$Name)
    if ($null -eq $Value) { return $null }
    $property=$Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Invoke-StatusGit {
    param([string]$Path,[string[]]$Arguments)
    $gitCommand=Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $gitCommand) { return [pscustomobject]@{success=$false;text='';reason='GIT_UNAVAILABLE'} }
    $previousPreference=$ErrorActionPreference
    try {
        # Native stderr must not become a terminating error under Windows PS 5.1.
        $ErrorActionPreference='Continue'
        $output=@(& $gitCommand.Source --no-optional-locks -c core.fsmonitor=false -C $Path @Arguments 2>$null)
        $code=$LASTEXITCODE
        return [pscustomobject]@{success=($code -eq 0);text=(($output | Out-String).Trim());reason='GIT_QUERY_FAILED'}
    }
    catch { return [pscustomobject]@{success=$false;text='';reason='GIT_QUERY_FAILED'} }
    finally { $ErrorActionPreference=$previousPreference }
}

function Get-StatusRepository {
    param([string]$Path)
    $result=[pscustomobject][ordered]@{path=$Path;available=$false;status='PATH_NOT_FOUND';commit=$null;branch=$null;dirty=$null}
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }
        $result.path=(Resolve-Path -LiteralPath $Path).ProviderPath
        $root=Invoke-StatusGit $result.path @('rev-parse','--show-toplevel')
        if (-not $root.success) {
            $result.status=if ($root.reason -eq 'GIT_UNAVAILABLE') { 'GIT_UNAVAILABLE' } else { 'NOT_A_REPOSITORY' }
            return $result
        }
        $result.path=[IO.Path]::GetFullPath($root.text)
        $result.available=$true
        $result.status='OBSERVED'
        $head=Invoke-StatusGit $result.path @('rev-parse','--verify','--quiet','HEAD')
        if ($head.success) { $result.commit=$head.text }
        else { $result.status='HEAD_UNAVAILABLE' }
        $branch=Invoke-StatusGit $result.path @('symbolic-ref','--quiet','--short','HEAD')
        if ($branch.success) { $result.branch=$branch.text }
        elseif ($head.success) { $result.branch='(detached)' }
        $changes=Invoke-StatusGit $result.path @('status','--porcelain=v1','--untracked-files=normal','--ignore-submodules=none')
        if ($changes.success) { $result.dirty=([bool]$changes.text) }
        else { $result.status='WORKTREE_STATUS_UNAVAILABLE' }
    }
    catch { $result.status='UNREADABLE' }
    return $result
}

function Get-StatusExpectedRevision {
    param($Repository,[string]$Requested)
    $result=[pscustomobject][ordered]@{requested=$Requested;resolvedCommit=$null;resolution=$null;status='NOT_PROVIDED'}
    if (-not $Requested) { return $result }
    $result.status='UNRESOLVED'
    if ($Requested -match '^[a-fA-F0-9]{40}$') {
        $result.resolvedCommit=$Requested.ToLowerInvariant()
        $result.resolution='EXPLICIT_COMMIT'
    }
    elseif ($Repository.available -and $Requested -notmatch '^[\s-]|[\x00-\x20]') {
        $resolved=Invoke-StatusGit $Repository.path @('rev-parse','--verify','--quiet','--end-of-options',($Requested + '^{commit}'))
        if ($resolved.success -and $resolved.text -match '^[a-f0-9]{40}$') {
            $result.resolvedCommit=$resolved.text
            $result.resolution='LOCAL_REF_ONLY'
        }
    }
    if ($result.resolvedCommit -and $Repository.commit) {
        $result.status=if ($result.resolvedCommit -eq $Repository.commit) { 'MATCH' } else { 'MISMATCH' }
    }
    return $result
}

function Get-StatusContainedPath {
    param([string]$Root,[string]$Relative)
    if ($Relative -notmatch '^[A-Za-z0-9_.@/-]+$' -or $Relative.StartsWith('/') -or
        @($Relative.Split('/') | Where-Object { $_ -in @('','..','.') }).Count -gt 0) { throw 'Unsafe relative path.' }
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $full=[IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    $prefix=$rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes root.' }
    $cursor=$full
    while ($cursor.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point not followed.' }
        }
        if ($cursor -eq $rootPath) { break }
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}

function Read-StatusJson {
    param([string]$Root,[string]$Relative)
    $result=[pscustomobject]@{path=(Join-Path $Root $Relative);status='MISSING';sha256=$null;data=$null}
    try { $path=Get-StatusContainedPath $Root $Relative }
    catch { $result.status='UNSAFE_PATH'; return $result }
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $result }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.status='NOT_A_FILE'; return $result }
        if ((Get-Item -LiteralPath $path).Length -gt 131072) { $result.status='TOO_LARGE'; return $result }
        $result.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $text=Get-Content -LiteralPath $path -Raw -Encoding UTF8
        try {
            $convert=@{InputObject=$text;ErrorAction='Stop'}
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $convert['DateKind']='String' }
            $data=ConvertFrom-Json @convert
            if ($data -isnot [pscustomobject]) { throw 'Expected object.' }
            $result.data=$data
            $result.status='OBSERVED'
        }
        catch { $result.status='INVALID_JSON' }
    }
    catch { $result.status='UNREADABLE' }
    return $result
}

function Get-StatusInventory {
    param([string]$Root)
    $files=@()
    $pending=@($Root)
    $visited=0
    try {
        while ($pending.Count -gt 0) {
            $directory=$pending[0]
            $pending=@($pending | Select-Object -Skip 1)
            foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                $visited++
                if ($visited -gt 1024) { return [pscustomobject]@{status='LIMIT_EXCEEDED';files=$files} }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject]@{status='UNSAFE_PATH';files=$files} }
                if ($item.PSIsContainer) { $pending+=@($item.FullName) }
                else { $files+=@($item.FullName.Substring($Root.TrimEnd('\','/').Length + 1).Replace('\','/')) }
            }
        }
        return [pscustomobject]@{status='COMPLETE';files=$files}
    }
    catch { return [pscustomobject]@{status='UNREADABLE';files=$files} }
}

function Get-StatusLineage {
    param([string]$Root,[string]$Name,[string]$ContractVersion)
    $read=Read-StatusJson $Root ($Name + '/references/lineage.json')
    $result=[pscustomobject][ordered]@{status='UNKNOWN';contractVersion=$null;adapter=$null;sourceRepository=$null;baselineSourceCommit=$null}
    if ($read.status -eq 'MISSING') { return $result }
    $result.status='INVALID'
    if ($read.status -ne 'OBSERVED') { return $result }
    $data=$read.data
    if ((Get-StatusProperty $data 'schemaVersion') -ne 1 -or (Get-StatusProperty $data 'skillName') -cne $Name -or
        (Get-StatusProperty $data 'contractVersion') -notmatch '^\d+\.\d+\.\d+$' -or
        (Get-StatusProperty $data 'adapter') -notin @('codex','chatgpt') -or
        (Get-StatusProperty $data 'sourceRepository') -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        (Get-StatusProperty $data 'baselineSourceCommit') -notmatch '^[a-f0-9]{40}$') { return $result }
    foreach ($field in @('contractVersion','adapter','sourceRepository','baselineSourceCommit')) { $result.$field=Get-StatusProperty $data $field }
    $result.status=if (-not $ContractVersion) { 'UNKNOWN' } elseif ($result.contractVersion -ceq $ContractVersion) { 'MATCH' } else { 'MISMATCH' }
    return $result
}

function Get-StatusSkills {
    param([string]$RuntimeRoot,[string]$InstalledRoot,[string]$ContractVersion)
    $read=Read-StatusJson $RuntimeRoot 'skills/skills-lock.json'
    $result=[pscustomobject][ordered]@{root=$InstalledRoot;manifestPath=$read.path;manifestSha256=$read.sha256;status=$read.status;core=@()}
    if ($read.status -ne 'OBSERVED') { return $result }
    $entries=Get-StatusProperty $read.data 'skills'
    $core=@($entries | Where-Object { (Get-StatusProperty $_ 'kind') -ceq 'repository-owned' })
    $result.status='INVALID_MANIFEST'
    if ((Get-StatusProperty $read.data 'schemaVersion') -ne 1 -or $entries -isnot [array] -or $core.Count -lt 1 -or $core.Count -gt 16) { return $result }
    # Validate the complete selected manifest before inspecting any installed path.
    $names=@{}
    foreach ($entry in $core) {
        $name=Get-StatusProperty $entry 'name'
        $files=Get-StatusProperty $entry 'files'
        if ($name -isnot [string] -or $name.Length -gt 80 -or $name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
            $names.ContainsKey($name) -or (Get-StatusProperty $entry 'state') -cne 'verified-local' -or
            $files -isnot [array] -or $files.Count -lt 1 -or $files.Count -gt 128) { return $result }
        $names[$name]=$true
        $paths=@{}
        foreach ($file in $files) {
            $relative=Get-StatusProperty $file 'path'
            $hash=Get-StatusProperty $file 'sha256'
            if ($relative -isnot [string] -or $relative -notmatch '^[A-Za-z0-9_.@/-]+$' -or $relative.StartsWith('/') -or
                @($relative.Split('/') | Where-Object { $_ -in @('','..','.') }).Count -gt 0 -or
                $paths.ContainsKey($relative) -or $hash -isnot [string] -or $hash -cnotmatch '^[a-f0-9]{64}$') { return $result }
            $paths[$relative]=$true
        }
    }
    if (-not $InstalledRoot) { $result.status='SKILLS_ROOT_UNAVAILABLE'; return $result }
    foreach ($entry in $core) {
        $checks=@()
        $inventory=[pscustomobject]@{status='MISSING';files=@()}
        $folder=Join-Path $InstalledRoot $entry.name
        $folderPresent=$false
        try {
            $folder=Get-StatusContainedPath $InstalledRoot $entry.name
            $folderPresent=Test-Path -LiteralPath $folder -PathType Container
            if ($folderPresent) { $inventory=Get-StatusInventory $folder }
        }
        catch { $inventory.status='UNSAFE_PATH' }
        foreach ($file in $entry.files) {
            $check=[pscustomobject][ordered]@{path=$file.path;expectedSha256=$file.sha256;actualSha256=$null;status='MISSING'}
            try {
                $installed=Get-StatusContainedPath $InstalledRoot ($entry.name + '/' + $file.path)
                if (Test-Path -LiteralPath $installed) {
                    if (Test-Path -LiteralPath $installed -PathType Leaf) {
                        if ((Get-Item -LiteralPath $installed).Length -gt 16777216) { $check.status='TOO_LARGE' }
                        else {
                            $check.actualSha256=(Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
                            $check.status=if ($check.actualSha256 -ceq $file.sha256) { 'MATCH' } else { 'MISMATCH' }
                        }
                    }
                    else { $check.status='NOT_A_FILE' }
                }
            }
            catch { $check.status='UNREADABLE_OR_UNSAFE' }
            $checks+=@($check)
        }
        $expectedPaths=@($entry.files | ForEach-Object { $_.path })
        $unexpected=@($inventory.files | Where-Object { $expectedPaths -notcontains $_ })
        $state=if ($inventory.status -eq 'MISSING') { 'MISSING' } elseif ($inventory.status -ne 'COMPLETE') { 'UNREADABLE_OR_UNSAFE' } elseif (@($checks | Where-Object { $_.status -ne 'MATCH' }).Count -gt 0 -or $unexpected.Count -gt 0) { 'DIFFERENT' } else { 'MATCH' }
        $result.core+=@([pscustomobject][ordered]@{name=$entry.name;path=$folder;status=$state;files=$checks;inventoryStatus=$inventory.status;unexpectedFiles=$unexpected;lineage=(Get-StatusLineage $InstalledRoot $entry.name $ContractVersion)})
    }
    $result.status=if (@($result.core | Where-Object { $_.status -ne 'MATCH' }).Count -eq 0) { 'MATCH' } else { 'ATTENTION' }
    return $result
}

function Get-StatusMemory {
    param($Repository)
    if (-not $Repository.available) { return [pscustomobject]@{status='PROJECT_UNAVAILABLE';configuration=$null;export=$null;publication=$null;cloudFreshness='UNKNOWN'} }
    $config=Read-StatusJson $Repository.path '.ados/state-export.json'
    $snapshot=Read-StatusJson $Repository.path '.ai/local-output/project-state.json'
    $receipt=Read-StatusJson $Repository.path '.ai/local-output/state-publish.receipt.json'
    $configuration=[pscustomobject][ordered]@{path=$config.path;status=$config.status;validation='METADATA_ONLY';projectId=$null;repository=$null}
    if ($config.status -eq 'OBSERVED') {
        $identity=Get-StatusProperty $config.data 'repository'
        $id=Get-StatusProperty $config.data 'projectId'
        $sources=Get-StatusProperty $config.data 'sources'
        $configuration.status='INVALID_METADATA'
        if ((Get-StatusProperty $config.data 'schemaVersion') -eq 1 -and $id -is [string] -and $id -cmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -and
            (Get-StatusProperty $identity 'fullName') -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
            (Get-StatusProperty $identity 'visibility') -in @('public','private') -and
            $sources -is [array] -and $sources.Count -ge 1 -and $sources.Count -le 24 -and (Get-StatusProperty $config.data 'includeTaskSummary') -is [bool]) {
            $configuration.status='CONFIGURED'
            $configuration.projectId=$id
            $configuration.repository=[pscustomobject]@{fullName=(Get-StatusProperty $identity 'fullName');visibility=(Get-StatusProperty $identity 'visibility')}
        }
    }
    $export=[pscustomobject][ordered]@{path=$snapshot.path;status=$snapshot.status;validation='METADATA_ONLY';sha256=$snapshot.sha256;projectId=$null;sourceCommit=$null;sourceMatchesCurrentHead=$null;identityMatchesConfiguration=$null}
    if ($snapshot.status -eq 'OBSERVED') {
        $source=Get-StatusProperty $snapshot.data 'source'
        $commit=Get-StatusProperty $source 'commit'
        $id=Get-StatusProperty $snapshot.data 'projectId'
        $export.status='INVALID_METADATA'
        if ((Get-StatusProperty $snapshot.data 'schemaVersion') -eq 1 -and $id -is [string] -and $id -cmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -and $commit -is [string] -and $commit -cmatch '^[a-f0-9]{40}$') {
            $export.status='EXPORTED_LOCAL'
            $export.projectId=$id
            $export.sourceCommit=$commit
            if ($Repository.commit) { $export.sourceMatchesCurrentHead=($commit -ceq $Repository.commit) }
            if ($configuration.projectId) {
                $snapshotRepository=Get-StatusProperty $snapshot.data 'repository'
                $export.identityMatchesConfiguration=($id -ceq $configuration.projectId -and (Get-StatusProperty $snapshotRepository 'fullName') -ieq $configuration.repository.fullName)
            }
        }
    }
    # A local receipt can describe a past publication; it is not an observation
    # of the current remote branch. Never turn JSON claims into remote freshness.
    $publication=[pscustomobject][ordered]@{path=$receipt.path;status=$receipt.status;sha256=$receipt.sha256;validation='LOCAL_RECEIPT_ONLY';remoteChecked=$false}
    if ($receipt.status -eq 'OBSERVED') { $publication.status='RECEIPT_OBSERVED' }
    return [pscustomobject][ordered]@{status='OBSERVED';configuration=$configuration;export=$export;publication=$publication;cloudFreshness='UNKNOWN'}
}

function Get-StatusActionArgument {
    param([string]$Arguments,[string]$Name)
    # Only simple -File actions are decoded. Text inside a command/encoded command
    # is not a discoverable executable path, even if it happens to contain -File.
    if ($Arguments -match '(?i)(?:^|\s)-(?:Command|c|EncodedCommand|ec|e)\b') { return $null }
    $pattern='(?i)(?:^|\s)-' + [regex]::Escape($Name) + '\s+(?:"(?<quoted>[^"]+)"|(?<bare>[^\s"]+))'
    $match=[regex]::Match($Arguments,$pattern)
    if (-not $match.Success) { return $null }
    if ($match.Groups['quoted'].Success) { return $match.Groups['quoted'].Value }
    return $match.Groups['bare'].Value
}

function Get-StatusSchedules {
    param([bool]$Requested,[string]$RuntimeRoot)
    $result=[pscustomobject][ordered]@{requested=$Requested;status='NOT_REQUESTED';filter='ADOS-Night-*';tasks=@()}
    if (-not $Requested) { return $result }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { $result.status='UNSUPPORTED_PLATFORM'; return $result }
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { $result.status='UNAVAILABLE'; return $result }
    try {
        $tasks=@(Get-ScheduledTask -TaskName 'ADOS-Night-*' -ErrorAction Stop | Where-Object { $_.TaskName -like 'ADOS-Night-*' })
        $result.status='OBSERVED'
        if ($tasks.Count -gt 100) { $result.status='LIMIT_EXCEEDED'; $tasks=@($tasks | Select-Object -First 100) }
        foreach ($task in $tasks) {
            $actions=@()
            foreach ($action in @($task.Actions)) {
                $arguments=[string](Get-StatusProperty $action 'Arguments')
                $executable=[string](Get-StatusProperty $action 'Execute')
                $scriptPath=$null
                $actionProjectPath=$null
                if ($executable -match '(?i)(?:^|[\\/])(?:powershell|pwsh)(?:\.exe)?$') {
                    $scriptPath=Get-StatusActionArgument $arguments 'File'
                    if ($scriptPath) { $actionProjectPath=Get-StatusActionArgument $arguments 'ProjectPath' }
                }
                $workingDirectory=[string](Get-StatusProperty $action 'WorkingDirectory')
                $resolvedScript=$null
                $scriptRuntime=$null
                $sameRuntime=$null
                if ($scriptPath -and $scriptPath -notmatch '[%$]') {
                    try {
                        if ([IO.Path]::IsPathRooted($scriptPath)) { $resolvedScript=[IO.Path]::GetFullPath($scriptPath) }
                        elseif ($workingDirectory -and [IO.Path]::IsPathRooted($workingDirectory)) { $resolvedScript=[IO.Path]::GetFullPath((Join-Path $workingDirectory $scriptPath)) }
                        if ($resolvedScript -and (Split-Path -Leaf $resolvedScript) -ieq 'ados.ps1') {
                            $scriptRoot=Split-Path -Parent $resolvedScript
                            $sameRuntime=($scriptRoot.TrimEnd('\','/') -ieq $RuntimeRoot.TrimEnd('\','/'))
                            if (Test-Path -LiteralPath $resolvedScript -PathType Leaf) { $scriptRuntime=Get-StatusRepository $scriptRoot }
                        }
                    }
                    catch { $resolvedScript=$null }
                }
                $actions+=@([pscustomobject][ordered]@{executable=$executable;scriptPath=$scriptPath;resolvedScriptPath=$resolvedScript;projectPath=$actionProjectPath;sameRuntimePath=$sameRuntime;runtime=$scriptRuntime})
            }
            $info=$null
            if (Get-Command Get-ScheduledTaskInfo -ErrorAction SilentlyContinue) {
                try { $info=Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop } catch { $info=$null }
            }
            $result.tasks+=@([pscustomobject][ordered]@{name=$task.TaskName;taskPath=(Get-StatusProperty $task 'TaskPath');state=[string]$task.State;lastRunTime=(Get-StatusProperty $info 'LastRunTime');nextRunTime=(Get-StatusProperty $info 'NextRunTime');lastTaskResult=(Get-StatusProperty $info 'LastTaskResult');actions=$actions})
        }
    }
    catch {
        $result.status=if ($_.FullyQualifiedErrorId -match 'CmdletizationQuery_NotFound') { 'OBSERVED' } else { 'QUERY_FAILED' }
    }
    return $result
}

$runtimeRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRepository=Get-StatusRepository $runtimeRoot
$expected=Get-StatusExpectedRevision $runtimeRepository $ExpectedRuntimeCommit
$runtime=[pscustomobject][ordered]@{path=$runtimeRoot;repositoryRoot=$runtimeRepository.path;available=$runtimeRepository.available;status=$runtimeRepository.status;commit=$runtimeRepository.commit;branch=$runtimeRepository.branch;dirty=$runtimeRepository.dirty;expected=$expected}
$contractRead=Read-StatusJson $runtimeRoot 'skills/contract.json'
$contract=[pscustomobject][ordered]@{path=$contractRead.path;status=$contractRead.status;contractVersion=$null}
if ($contractRead.status -eq 'OBSERVED') {
    $version=Get-StatusProperty $contractRead.data 'contractVersion'
    if ((Get-StatusProperty $contractRead.data 'schemaVersion') -eq 1 -and $version -is [string] -and $version -cmatch '^\d+\.\d+\.\d+$') { $contract.contractVersion=$version }
    else { $contract.status='INVALID_METADATA' }
}
if (-not $SkillsRoot) {
    $profileRoot=$env:USERPROFILE
    if (-not $profileRoot) { $profileRoot=[Environment]::GetFolderPath('UserProfile') }
    if ($profileRoot) { $SkillsRoot=Join-Path $profileRoot '.agents/skills' }
}
if ($SkillsRoot) { $SkillsRoot=[IO.Path]::GetFullPath($SkillsRoot) }
$project=Get-StatusRepository $ProjectPath
$project | Add-Member -NotePropertyName memory -NotePropertyValue (Get-StatusMemory $project)
$report=[pscustomobject][ordered]@{
    schemaVersion=1
    observedAt=[datetimeoffset]::UtcNow.ToString('o')
    readOnly=$true
    runtime=$runtime
    contract=$contract
    skills=(Get-StatusSkills $runtimeRoot $SkillsRoot $contract.contractVersion)
    project=$project
    schedules=(Get-StatusSchedules ([bool]$IncludeSchedules) $runtimeRoot)
    limitations=@(
        'Local observations only; no fetch, install, repair, export, publication, or task execution was performed.',
        'Expected refs resolve from local Git only. A matching commit does not imply a clean worktree.',
        'Skill hashes compare the selected installation with this runtime lock; they do not prove host discovery, invocation, or cloud adapter parity.',
        'Memory fields inspect bounded local JSON metadata, not full export readiness or task verification. Use state-validate for snapshot validation.',
        'A missing default snapshot or receipt does not prove that another copy or publication does not exist. Cloud freshness is unknown.'
    )
}
if ($Json) { $report | ConvertTo-Json -Depth 16; return }
Write-Output ('ADOS runtime: {0}' -f $runtime.path)
Write-Output ('  Commit: {0}; branch: {1}; dirty: {2}; expected: {3}' -f $runtime.commit,$runtime.branch,$runtime.dirty,$expected.status)
Write-Output ('Skill contract: {0} ({1})' -f $contract.contractVersion,$contract.status)
Write-Output ('Installed core skills: {0} at {1}' -f $report.skills.status,$SkillsRoot)
foreach ($skill in $report.skills.core) {
    Write-Output ('  {0}: {1}; lineage: {2}' -f $skill.name,$skill.status,$skill.lineage.status)
    foreach ($file in @($skill.files | Where-Object { $_.status -ne 'MATCH' })) { Write-Output ('    {0}: {1}' -f $file.path,$file.status) }
    foreach ($file in $skill.unexpectedFiles) { Write-Output ('    Unlocked file: {0}' -f $file) }
}
Write-Output ('Project: {0} ({1})' -f $project.path,$project.status)
if ($project.available) {
    Write-Output ('  Memory configuration: {0}; local export: {1}; publication receipt: {2}' -f $project.memory.configuration.status,$project.memory.export.status,$project.memory.publication.status)
}
Write-Output 'Cloud freshness: UNKNOWN (no remote query)'
Write-Output ('ADOS schedules: {0}' -f $report.schedules.status)
foreach ($task in $report.schedules.tasks) {
    Write-Output ('  {0}: {1}' -f $task.name,$task.state)
    foreach ($action in $task.actions) { Write-Output ('    Script: {0}; same runtime path: {1}' -f $action.resolvedScriptPath,$action.sameRuntimePath) }
}
Write-Output 'Read-only observation; memory metadata and local receipts do not establish current remote or release readiness.'
