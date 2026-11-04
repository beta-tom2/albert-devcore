[CmdletBinding()]
param(
    [ValidateSet('plan','upgrade','restore')][string]$Action='plan',
    [string]$ProjectPath='',
    [switch]$Global,
    [string[]]$Skill=@(),
    [string]$ExpectedInstalledDigest='',
    [string]$ExpectedSourceDigest='',
    [switch]$ConfirmChange,
    [string]$BackupRoot='',
    [string]$BackupPath='',
    [switch]$Json
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$managedNames=@('albert-architecture-review','albert-design-director','albert-skill-router')
$managerRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Get-UpdateHash([byte[]]$Bytes) {
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-UpdateDigest($Value) {
    return Get-UpdateHash ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 14 -Compress)))
}

function Get-UpdateProperty($Value,[string]$Name) {
    if ($null -eq $Value -or $null -eq $Value.PSObject.Properties[$Name]) { return $null }
    return ,$Value.PSObject.Properties[$Name].Value
}

function Get-UpdateSorted([string[]]$Values) {
    $copy=@($Values)
    [Array]::Sort($copy,[StringComparer]::Ordinal)
    return ,$copy
}

function Assert-UpdateSafePath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked paths are not supported: $cursor" }
        }
        $parent=Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor=$parent
    }
}

function Get-UpdateChild([string]$Root,[string]$Relative) {
    if (-not $Relative -or $Relative -match '[\\:*?"<>|\x00-\x1F]' -or $Relative.StartsWith('/') -or
        @($Relative.Split('/') | Where-Object { $_ -in @('','..','.') -or $_.EndsWith('.') -or $_.EndsWith(' ') }).Count -gt 0) { throw 'Invalid relative skill or backup path.' }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $path=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith(($base + [IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes its selected root.' }
    Assert-UpdateSafePath $path
    return $path
}

function Read-UpdateBytes([string]$Path,[int]$Limit=16777216) {
    Assert-UpdateSafePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    $before=Get-Item -LiteralPath $Path -Force
    if ($before.Length -gt $Limit) { throw "File exceeds the bounded skill update limit: $Path" }
    [byte[]]$bytes=[IO.File]::ReadAllBytes($Path)
    $after=Get-Item -LiteralPath $Path -Force
    if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc -or $bytes.Length -ne $after.Length) { throw "File changed while being read: $Path" }
    return ,$bytes
}

function Convert-UpdateJson([byte[]]$Bytes) {
    try {
        $data=[Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
        if ($data -isnot [pscustomobject]) { throw 'Expected object.' }
        return $data
    }
    catch { throw 'Invalid skill or backup JSON object.' }
}

function Get-UpdateSelection([string[]]$Names) {
    if (@($Names).Count -eq 0) { $Names=$managedNames }
    $seen=@{}
    foreach ($name in $Names) {
        if ($managedNames -cnotcontains $name -or $seen.ContainsKey($name)) { throw 'Select distinct names from the three repository-owned Albert skills only.' }
        $seen[$name]=$true
    }
    return ,(Get-UpdateSorted $Names)
}

function Get-UpdateSnapshot([string]$Root,[string[]]$Names) {
    Assert-UpdateSafePath $Root
    if ((Test-Path -LiteralPath $Root) -and -not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Skill root is not a directory: $Root" }
    $entries=@()
    $bytesByPath=@{}
    $nodeCount=0
    $totalBytes=0L
    foreach ($name in $Names) {
        $folder=Get-UpdateChild $Root $name
        $present=Test-Path -LiteralPath $folder
        if ($present -and -not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Selected skill is not a directory: $folder" }
        $nodesByPath=@{}
        if ($present) {
            $pending=@($folder)
            while ($pending.Count -gt 0) {
                $directory=$pending[0]
                $pending=@($pending | Select-Object -Skip 1)
                foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                    $nodeCount++
                    if ($nodeCount -gt 2048) { throw 'Selected skills exceed the 2048-entry update limit.' }
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked skill content is not supported: $($item.FullName)" }
                    $relative=$item.FullName.Substring($folder.Length + 1).Replace('\','/')
                    $null=Get-UpdateChild $folder $relative
                    if ($nodesByPath.ContainsKey($relative)) { throw 'Ambiguous case-colliding paths in a selected package.' }
                    if ($item.PSIsContainer) {
                        $nodesByPath[$relative]=[pscustomobject][ordered]@{path=$relative;kind='directory'}
                        $pending+=@($item.FullName)
                    }
                    else {
                        [byte[]]$bytes=Read-UpdateBytes $item.FullName
                        $totalBytes+=$bytes.Length
                        if ($totalBytes -gt 67108864) { throw 'Selected skills exceed the 64 MiB update limit.' }
                        $nodesByPath[$relative]=[pscustomobject][ordered]@{path=$relative;kind='file';sha256=(Get-UpdateHash $bytes);length=$bytes.Length}
                        $bytesByPath[$name + '/' + $relative]=$bytes
                    }
                }
            }
        }
        $nodes=@(foreach ($path in (Get-UpdateSorted @($nodesByPath.Keys))) { $nodesByPath[$path] })
        $entries+=@([pscustomobject][ordered]@{name=$name;present=[bool]$present;nodes=$nodes})
    }
    $manifest=[pscustomobject][ordered]@{schemaVersion=1;entries=$entries}
    return [pscustomobject]@{manifest=$manifest;digest=(Get-UpdateDigest $manifest);bytes=$bytesByPath}
}

function Get-UpdateRuntime {
    $result=[pscustomobject][ordered]@{path=$managerRoot;commit=$null;dirty=$null;managerSha256=(Get-UpdateHash (Read-UpdateBytes $PSCommandPath));observedAt=[datetimeoffset]::UtcNow.ToString('o')}
    $preference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $head=(& git --no-optional-locks -c core.fsmonitor=false -C $managerRoot rev-parse --verify HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) { $result.commit=$head }
        $changes=(& git --no-optional-locks -c core.fsmonitor=false -C $managerRoot status --porcelain=v1 --untracked-files=normal 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) { $result.dirty=[bool]$changes }
    }
    catch { }
    finally { $ErrorActionPreference=$preference }
    return $result
}

function Get-UpdateSource([string[]]$Names) {
    $controls=@()
    foreach ($relative in @('scripts/install-albert-dev-skills.ps1','skills/approved-skills.json','skills/skills-lock.json','skills/contract.json')) {
        $path=Get-UpdateChild $managerRoot $relative
        if ($relative -eq 'skills/contract.json' -and -not (Test-Path -LiteralPath $path)) { continue }
        [byte[]]$bytes=Read-UpdateBytes $path 131072
        $controls+=@([pscustomobject]@{path=$relative;sha256=(Get-UpdateHash $bytes);bytes=$bytes})
    }
    $registry=Convert-UpdateJson (@($controls | Where-Object { $_.path -eq 'skills/approved-skills.json' })[0].bytes)
    $lock=Convert-UpdateJson (@($controls | Where-Object { $_.path -eq 'skills/skills-lock.json' })[0].bytes)
    if ((Get-UpdateProperty $lock 'schemaVersion') -ne 1) { throw 'Unsupported skills-lock schema.' }
    $policy=Get-UpdateProperty $registry 'policy'
    $statuses=Get-UpdateProperty $policy 'installableStatuses'
    $registryEntries=Get-UpdateProperty $registry 'skills'
    $lockEntries=Get-UpdateProperty $lock 'skills'
    if ($statuses -isnot [array] -or $statuses.Count -eq 0 -or $registryEntries -isnot [array] -or $lockEntries -isnot [array]) { throw 'Invalid skill registry or lock.' }
    $registryNames=@{}
    $lockNames=@{}
    foreach ($entry in $registryEntries) {
        $name=[string](Get-UpdateProperty $entry 'name')
        if ($name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or $registryNames.ContainsKey($name)) { throw 'Invalid or duplicate registry name.' }
        $registryNames[$name]=$entry
    }
    foreach ($entry in $lockEntries) {
        $name=[string](Get-UpdateProperty $entry 'name')
        if (-not $registryNames.ContainsKey($name) -or $lockNames.ContainsKey($name)) { throw 'Unknown or duplicate locked name.' }
        $lockNames[$name]=$entry
    }
    foreach ($name in $registryNames.Keys) { if (-not $lockNames.ContainsKey($name)) { throw 'Registry entry is missing from the lock.' } }
    $snapshot=Get-UpdateSnapshot (Join-Path $managerRoot 'skills') $Names
    foreach ($package in $snapshot.manifest.entries) {
        $name=$package.name
        if (-not $lockNames.ContainsKey($name)) { throw "No locked artifact for $name" }
        $entry=$lockNames[$name]
        $files=Get-UpdateProperty $entry 'files'
        if ((Get-UpdateProperty $entry 'kind') -cne 'repository-owned' -or (Get-UpdateProperty $entry 'state') -cne 'verified-local' -or
            (Get-UpdateProperty $entry 'path') -cne ('skills/' + $name) -or $statuses -notcontains (Get-UpdateProperty $registryNames[$name] 'status') -or
            $files -isnot [array] -or $files.Count -lt 1 -or -not $package.present) { throw "No approved repository-owned artifact for $name" }
        $fileMap=@{}
        $directories=@{}
        foreach ($file in $files) {
            $relative=[string](Get-UpdateProperty $file 'path')
            $hash=[string](Get-UpdateProperty $file 'sha256')
            $null=Get-UpdateChild (Join-Path $managerRoot ('skills/' + $name)) $relative
            if ($fileMap.ContainsKey($relative) -or $hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid or duplicate locked file.' }
            $fileMap[$relative]=$hash
            $parts=$relative.Split('/')
            for ($i=1;$i -lt $parts.Count;$i++) { $directories[($parts[0..($i-1)] -join '/') ]=$true }
        }
        if (-not $fileMap.ContainsKey('SKILL.md')) { throw "SKILL.md is not locked for $name" }
        $observedFiles=@($package.nodes | Where-Object { $_.kind -eq 'file' })
        if ($observedFiles.Count -ne $fileMap.Count) { throw "Source file inventory differs from the lock for $name" }
        foreach ($node in $package.nodes) {
            if ($node.kind -eq 'file') {
                if (-not $fileMap.ContainsKey($node.path) -or $node.sha256 -cne $fileMap[$node.path]) { throw "Source hash mismatch for $name/$($node.path)" }
            }
            elseif (-not $directories.ContainsKey($node.path)) { throw "Unlocked source directory for $name/$($node.path)" }
        }
        $text=[Text.Encoding]::UTF8.GetString($snapshot.bytes[$name + '/SKILL.md'])
        if ($text -notmatch ('(?m)^name:\s*' + [regex]::Escape($name) + '\s*$')) { throw "Skill frontmatter name mismatch for $name" }
    }
    $identity=[pscustomobject][ordered]@{kind='runtime-lock';selection=$Names;controls=@($controls | ForEach-Object { [pscustomobject][ordered]@{path=$_.path;sha256=$_.sha256} });artifactDigest=$snapshot.digest;managerSha256=(Get-UpdateHash (Read-UpdateBytes $PSCommandPath))}
    return [pscustomobject]@{kind='runtime-lock';digest=(Get-UpdateDigest $identity);identity=$identity;snapshot=$snapshot;controls=$controls;backupPath=$null}
}

function Get-UpdateBackup([string]$Path,[string]$Target,[string[]]$RequestedNames) {
    $resolved=[IO.Path]::GetFullPath($Path)
    Assert-UpdateSafePath $resolved
    [byte[]]$bytes=Read-UpdateBytes (Get-UpdateChild $resolved 'backup.json') 1048576
    $manifest=Convert-UpdateJson $bytes
    $names=Get-UpdateProperty $manifest 'selection'
    if ((Get-UpdateProperty $manifest 'schemaVersion') -ne 1 -or $names -isnot [array] -or $names.Count -lt 1) { throw 'Invalid backup manifest.' }
    $selected=Get-UpdateSelection $names
    if ((Get-UpdateProperty $manifest 'targetRoot') -ine $Target) { throw 'Backup belongs to a different installation target.' }
    if (@($RequestedNames).Count -gt 0 -and ((Get-UpdateSelection $RequestedNames) -join ',') -cne ($selected -join ',')) { throw 'Restore selection must match the complete backup selection.' }
    $snapshot=Get-UpdateSnapshot (Get-UpdateChild $resolved 'previous') $selected
    $recorded=Get-UpdateProperty $manifest 'snapshot'
    $recordedDigest=[string](Get-UpdateProperty $manifest 'installedDigest')
    if ($recordedDigest -cnotmatch '^[a-f0-9]{64}$' -or (Get-UpdateDigest $recorded) -cne $recordedDigest -or $snapshot.digest -cne $recordedDigest) { throw 'Backup content or manifest was changed; restore is blocked.' }
    $identity=[pscustomobject][ordered]@{kind='backup';manifestSha256=(Get-UpdateHash $bytes);artifactDigest=$snapshot.digest;managerSha256=(Get-UpdateHash (Read-UpdateBytes $PSCommandPath))}
    return [pscustomobject]@{kind='backup';digest=(Get-UpdateDigest $identity);identity=$identity;snapshot=$snapshot;controls=@();backupPath=$resolved;selection=$selected}
}

function New-UpdateDirectory([string]$Path) {
    Assert-UpdateSafePath $Path
    $null=[IO.Directory]::CreateDirectory($Path)
}

function Move-UpdateDirectory([string]$Source,[string]$Destination) {
    Assert-UpdateSafePath $Source
    Assert-UpdateSafePath $Destination
    # Same-volume rename only. Unlike Move-Item, an existing destination is an
    # error, never a request to nest the source inside another writer's folder.
    [IO.Directory]::Move($Source,$Destination)
}

function Write-UpdateBytes([string]$Path,[byte[]]$Bytes) {
    Assert-UpdateSafePath $Path
    New-UpdateDirectory (Split-Path -Parent $Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length) }
    finally { $stream.Dispose() }
}

function Write-UpdateJson([string]$Path,$Value) {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 14))
    $temporary=$Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    Write-UpdateBytes $temporary $bytes
    try {
        Assert-UpdateSafePath $Path
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Write-UpdateSnapshot([string]$Root,$Snapshot) {
    New-UpdateDirectory $Root
    foreach ($entry in $Snapshot.manifest.entries) {
        if (-not $entry.present) { continue }
        $folder=Get-UpdateChild $Root $entry.name
        New-UpdateDirectory $folder
        foreach ($node in $entry.nodes) {
            $path=Get-UpdateChild $folder $node.path
            if ($node.kind -eq 'directory') { New-UpdateDirectory $path }
            else { Write-UpdateBytes $path $Snapshot.bytes[$entry.name + '/' + $node.path] }
        }
    }
}

if ([bool]$Global -eq [bool]$ProjectPath) { throw 'Choose exactly one target: -Global or -ProjectPath.' }
if ($Action -eq 'restore' -and -not $BackupPath) { throw 'Restore requires a concrete -BackupPath.' }
if ($Action -eq 'upgrade' -and $BackupPath) { throw 'BackupPath selects a restore source; do not combine it with upgrade.' }
$profileRoot=$env:USERPROFILE
if (-not $profileRoot) { $profileRoot=[Environment]::GetFolderPath('UserProfile') }
if ($Global) {
    if (-not $profileRoot) { throw 'Cannot resolve the user profile.' }
    $targetRoot=[IO.Path]::GetFullPath((Join-Path $profileRoot '.agents/skills'))
}
else {
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { throw 'ProjectPath must be an existing directory.' }
    $targetRoot=[IO.Path]::GetFullPath((Join-Path (Resolve-Path -LiteralPath $ProjectPath).ProviderPath '.agents/skills'))
}
Assert-UpdateSafePath $targetRoot
if (-not $BackupRoot) {
    if (-not $profileRoot) { throw 'Choose an explicit BackupRoot because the user profile is unavailable.' }
    $BackupRoot=Join-Path $profileRoot '.agents/backups'
}
$BackupRoot=[IO.Path]::GetFullPath($BackupRoot).TrimEnd('\','/')
Assert-UpdateSafePath $BackupRoot
foreach ($protectedRoot in @($targetRoot,$managerRoot)) {
    $prefix=$protectedRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($BackupRoot -ieq $protectedRoot -or $BackupRoot.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'BackupRoot must be outside both the skills directory and source runtime.' }
}
if ((Test-Path -LiteralPath $BackupRoot) -and -not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw 'BackupRoot is not a directory.' }
if ($BackupPath) { $source=Get-UpdateBackup $BackupPath $targetRoot $Skill; $selected=$source.selection; $operation='restore' }
else { $selected=Get-UpdateSelection $Skill; $source=Get-UpdateSource $selected; $operation='upgrade' }
$installed=Get-UpdateSnapshot $targetRoot $selected
$runtime=Get-UpdateRuntime
$plan=[pscustomobject][ordered]@{schemaVersion=1;action=$operation;state='PLAN';targetRoot=$targetRoot;selection=$selected;installedDigest=$installed.digest;sourceDigest=$source.digest;desiredInstalledDigest=$source.snapshot.digest;source=$source.identity;runtime=$runtime;backupRoot=$BackupRoot;restoreFrom=$source.backupPath;installedManifest=$installed.manifest;desiredManifest=$source.snapshot.manifest}
if ($Action -eq 'plan') {
    if ($Json) { $plan | ConvertTo-Json -Depth 14 }
    else {
        Write-Output ("Skill $operation plan: $targetRoot")
        Write-Output ('Selected: ' + ($selected -join ', '))
        Write-Output ('Installed digest: ' + $plan.installedDigest)
        Write-Output ('Source digest:    ' + $plan.sourceDigest)
        Write-Output ('Desired digest:   ' + $plan.desiredInstalledDigest)
        Write-Output ("Backup root: $BackupRoot")
        Write-Output 'Read-only plan. Review both manifests with -Json before confirming a change.'
    }
    return
}
if (-not $ConfirmChange) { throw 'Review plan first, then explicitly pass -ConfirmChange.' }
if ($ExpectedInstalledDigest -cnotmatch '^[a-f0-9]{64}$' -or $ExpectedInstalledDigest -cne $installed.digest) { throw 'Installed digest mismatch. No files were written; inspect a fresh plan.' }
if ($ExpectedSourceDigest -cnotmatch '^[a-f0-9]{64}$' -or $ExpectedSourceDigest -cne $source.digest) { throw 'Source digest mismatch. No files were written; inspect a fresh plan.' }
if ($installed.digest -ceq $source.snapshot.digest) {
    $plan.state='ALREADY_CURRENT'
    if ($Json) { $plan | ConvertTo-Json -Depth 14 } else { Write-Output 'ALREADY_CURRENT: selected directories already match; no files were written.' }
    return
}

$operationId=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
$targetParent=Split-Path -Parent $targetRoot
$lockPath=Join-Path $targetParent '.albert-skills-update.lock'
$workspace=Join-Path $targetParent ('.albert-skills-update-' + $operationId)
$newBackup=Join-Path $BackupRoot ('albert-skills-' + $operationId)
$stageRoot=Join-Path $workspace 'stage/.agents/skills'
$displacedRoot=Join-Path $workspace 'displaced'
$lockStream=$null
$movedOld=@{}
$promoted=@{}
$receipt=$null
try {
    New-UpdateDirectory $targetParent
    try { $lockStream=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw 'Another update or an interrupted transaction owns the target lock. Inspect it; do not remove a live writer lock.' }
    $lockBytes=[Text.Encoding]::UTF8.GetBytes((@{operationId=$operationId;pid=$PID;workspace=$workspace;backupPath=$newBackup} | ConvertTo-Json -Compress))
    $lockStream.Write($lockBytes,0,$lockBytes.Length)
    $lockStream.Flush()
    if ((Get-UpdateSnapshot $targetRoot $selected).digest -cne $ExpectedInstalledDigest) { throw 'Installed content changed before the target lock was acquired.' }
    New-UpdateDirectory $workspace
    New-UpdateDirectory $newBackup
    Write-UpdateSnapshot (Join-Path $newBackup 'previous') $installed
    if ((Get-UpdateSnapshot (Join-Path $newBackup 'previous') $selected).digest -cne $installed.digest) { throw 'Backup verification failed.' }
    $backupManifest=[pscustomobject][ordered]@{schemaVersion=1;operationId=$operationId;createdAt=[datetimeoffset]::UtcNow.ToString('o');targetRoot=$targetRoot;selection=$selected;installedDigest=$installed.digest;snapshot=$installed.manifest;runtime=$runtime;replacementSource=$source.identity}
    Write-UpdateJson (Join-Path $newBackup 'backup.json') $backupManifest
    $receipt=[pscustomobject][ordered]@{schemaVersion=1;operationId=$operationId;action=$operation;state='PREPARED';targetRoot=$targetRoot;selection=$selected;installedBeforeDigest=$installed.digest;installedAfterDigest=$null;sourceDigest=$source.digest;source=$source.identity;runtime=$runtime;backupPath=$newBackup;backupManifestSha256=(Get-UpdateHash (Read-UpdateBytes (Join-Path $newBackup 'backup.json') 1048576));restoredFrom=$source.backupPath;workspace=$workspace;recordedAt=[datetimeoffset]::UtcNow.ToString('o')}
    Write-UpdateJson (Join-Path $newBackup 'receipt.json') $receipt
    if ($operation -eq 'upgrade') {
        $frozenRoot=Join-Path $workspace 'source'
        foreach ($control in $source.controls) { Write-UpdateBytes (Get-UpdateChild $frozenRoot $control.path) $control.bytes }
        Write-UpdateSnapshot (Join-Path $frozenRoot 'skills') $source.snapshot
        $stageProject=Join-Path $workspace 'stage'
        New-UpdateDirectory $stageProject
        # The existing installer sees only the verified frozen bytes and a fresh
        # target. It is never asked to overwrite an installed local adaptation.
        & (Join-Path $frozenRoot 'scripts/install-albert-dev-skills.ps1') -ProjectPath $stageProject -Skill $selected 6>$null
    }
    else { Write-UpdateSnapshot $stageRoot $source.snapshot }
    if ((Get-UpdateSnapshot $stageRoot $selected).digest -cne $source.snapshot.digest) { throw 'Staged skills do not match the reviewed source.' }
    $freshSource=if ($operation -eq 'upgrade') { Get-UpdateSource $selected } else { Get-UpdateBackup $BackupPath $targetRoot $selected }
    if ($freshSource.digest -cne $ExpectedSourceDigest) { throw 'Source changed while staging; installation was not replaced.' }
    if ((Get-UpdateSnapshot $targetRoot $selected).digest -cne $ExpectedInstalledDigest) { throw 'Installed content changed while staging; installation was not replaced.' }
    New-UpdateDirectory $displacedRoot
    New-UpdateDirectory $targetRoot
    foreach ($entry in $installed.manifest.entries) {
        if ($entry.present) {
            Move-UpdateDirectory (Get-UpdateChild $targetRoot $entry.name) (Get-UpdateChild $displacedRoot $entry.name)
            $movedOld[$entry.name]=$true
        }
    }
    if ((Get-UpdateSnapshot $displacedRoot $selected).digest -cne $ExpectedInstalledDigest) { throw 'Previous directories changed during replacement; rolling back.' }
    foreach ($entry in $source.snapshot.manifest.entries) {
        if ($entry.present) {
            Move-UpdateDirectory (Get-UpdateChild $stageRoot $entry.name) (Get-UpdateChild $targetRoot $entry.name)
            $promoted[$entry.name]=$true
        }
    }
    $after=Get-UpdateSnapshot $targetRoot $selected
    if ($after.digest -cne $source.snapshot.digest -or (Get-UpdateSnapshot $displacedRoot $selected).digest -cne $ExpectedInstalledDigest) { throw 'Directories changed during final verification; rolling back.' }
    $receipt.state='COMPLETED'
    $receipt.installedAfterDigest=$after.digest
    $receipt.recordedAt=[datetimeoffset]::UtcNow.ToString('o')
    Write-UpdateJson (Join-Path $newBackup 'receipt.json') $receipt
    # All old bytes already have a verified durable backup. Workspace deletion is
    # cleanup only; a cleanup failure must not undo a successful replacement.
    try { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Update completed; temporary workspace remains: $workspace" }
    if ($Json) { $receipt | ConvertTo-Json -Depth 14 }
    else { Write-Output ("COMPLETED: $operation; backup and receipt: $newBackup"); Write-Output ("Installed digest: $($after.digest)") }
}
catch {
    $failure=$_.Exception.Message
    $rollbackErrors=@()
    foreach ($name in $selected) {
        try {
            $target=Get-UpdateChild $targetRoot $name
            if ($promoted.ContainsKey($name) -and (Test-Path -LiteralPath $target)) {
                $recovery=Get-UpdateChild (Join-Path $workspace 'failed-new') $name
                New-UpdateDirectory (Split-Path -Parent $recovery)
                Move-UpdateDirectory $target $recovery
            }
            if ($movedOld.ContainsKey($name)) {
                if (Test-Path -LiteralPath $target) { throw 'A concurrent writer occupies the restore target.' }
                Move-UpdateDirectory (Get-UpdateChild $displacedRoot $name) $target
            }
        }
        catch { $rollbackErrors+=@($name) }
    }
    $rollbackDigest=$null
    try {
        $rollbackDigest=(Get-UpdateSnapshot $targetRoot $selected).digest
        if ($rollbackDigest -cne $installed.digest) { $rollbackErrors+=@('installed-digest-mismatch') }
    }
    catch { $rollbackErrors+=@('installed-state-unreadable') }
    if ($null -ne $receipt) {
        $receipt.state=if ($rollbackErrors.Count -eq 0) { 'ROLLED_BACK' } else { 'RECOVERY_REQUIRED' }
        $receipt.recordedAt=[datetimeoffset]::UtcNow.ToString('o')
        try { $receipt.installedAfterDigest=$rollbackDigest; Write-UpdateJson (Join-Path $newBackup 'receipt.json') $receipt } catch { }
    }
    throw "$failure Original and staged files are preserved when available. Backup: $newBackup; recovery workspace: $workspace; rollback conflicts: $($rollbackErrors -join ', ')."
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force
    }
}
