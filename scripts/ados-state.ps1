[CmdletBinding()]
param(
    [Parameter(Position=0,Mandatory=$true)]
    [ValidateSet('export','validate','read')]
    [string]$Command,
    [string]$ProjectPath='.',
    [string]$ConfigPath='.ados/state-export.json',
    [string]$SnapshotPath='',
    [string]$ExpectedSnapshotSha256=''
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ados-common.ps1')

function Assert-StateKeys {
    param($Value,[string[]]$Keys,[string]$Label)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw "$Label must be an object." }
    $actual=@($Value.PSObject.Properties.Name)
    foreach ($key in $Keys) { if ($actual -notcontains $key) { throw "$Label is missing $key." } }
    foreach ($key in $actual) { if ($Keys -notcontains $key) { throw "$Label contains unsupported field $key." } }
}

function Assert-StateText {
    param($Value,[string]$Label,[int]$MaxLength=400)
    if ($Value -isnot [string] -or -not $Value.Trim() -or $Value.Length -gt $MaxLength -or $Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
        throw "$Label must be bounded text."
    }
    $secret='(?i)(api[_-]?key|secret|password|passwd|private[_-]?key|client[_-]?secret|(?:access[_-]?|auth[_-]?|refresh[_-]?)?token)\s*["'']?\s*[:=]\s*["'']?[^\s"'']{8,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|authorization\s*:\s*bearer\s+\S+|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|(postgres(ql)?|mysql|mongodb(\+srv)?|redis)://[^\s]+|https?://[^\s/@]+:[^\s/@]+@'
    if ($Value -match $secret) { throw "$Label contains credential-like text; export blocked." }
}

function Assert-StateSummary {
    param($Value)
    Assert-StateText $Value 'task summary' 1200
    # Heuristics reduce accidental disclosure; arbitrary prose still needs review.
    $localPath='(?i)\b[a-z]:[\\/]|\\\\[^\s\\]+\\|(?:^|[\s"''=(])(?:/|~/)\S+|\bfile://'
    if ($Value -match $localPath) { throw 'Task summary contains an absolute local path; export blocked.' }
}

function Assert-StateHash {
    param($Value,[string]$Label,[int]$Length=40,[switch]$Nullable)
    if ($Nullable -and $null -eq $Value) { return }
    if ($Value -isnot [string] -or $Value -cnotmatch ('^[a-f0-9]{' + $Length + '}$')) { throw "$Label must be a lowercase hash." }
}

function Assert-StateDate {
    param($Value,[string]$Label,[switch]$Nullable)
    if ($Nullable -and $null -eq $Value) { return }
    Assert-StateText $Value $Label 48
    $date=[datetimeoffset]::MinValue
    if ($Value -notmatch '(Z|[+-]\d\d:\d\d)$' -or -not [datetimeoffset]::TryParse($Value,[ref]$date)) { throw "$Label must include a valid timestamp and timezone." }
}

function Assert-StateRelativePath {
    param($Value)
    Assert-StateText $Value 'source path' 240
    if ($Value -match '\\|:|\*|\?|\[|\]|[\r\n]' -or $Value.StartsWith('/') -or @($Value.Split('/') | Where-Object { $_ -in @('','..','.') }).Count -gt 0) { throw 'Source must be an explicit repository-relative path.' }
    if ($Value -match '(?i)(^|/)(\.git|\.ai|node_modules|\.env[^/]*|secrets?|credentials?)(/|\.|$)' -or $Value -notmatch '(?i)\.(md|json|txt)$') { throw 'Only explicit non-secret document sources are allowed.' }
}

function Read-StateJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "State input is missing: $Path" }
    if ((Get-Item -LiteralPath $Path).Length -gt 131072) { throw 'State input exceeds 128 KiB.' }
    try {
        $convert=@{ InputObject=(Get-Content -LiteralPath $Path -Raw -Encoding UTF8); ErrorAction='Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $convert['DateKind']='String' }
        $value=ConvertFrom-Json @convert
    }
    catch { throw "State input is invalid JSON: $Path" }
    if ($null -eq $value) { throw 'State input must not be null.' }
    return $value
}

function Assert-ProjectState {
    param($State)
    Assert-StateKeys $State @('schemaVersion','projectId','repository','observedAt','source','checkpoint','evidence','sources','limitations','workstreams') 'snapshot'
    if ($State.schemaVersion -ne 1) { throw 'Unsupported project-state schema.' }
    Assert-StateText $State.projectId 'projectId' 64
    if ($State.projectId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'Invalid projectId.' }
    Assert-StateKeys $State.repository @('fullName','visibility') 'repository'
    if ($State.repository.fullName -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $State.repository.visibility -cnotin @('private','public')) { throw 'Invalid repository identity or visibility.' }
    Assert-StateDate $State.observedAt 'observedAt'
    Assert-StateKeys $State.source @('kind','branch','commit','worktreeDirty','evidenceFingerprint') 'source'
    if ($State.source.kind -cnotin @('local-git','github')) { throw 'Invalid source kind.' }
    Assert-StateText $State.source.branch 'source branch' 240
    Assert-StateHash $State.source.commit 'source commit'
    Assert-StateHash $State.source.evidenceFingerprint 'source fingerprint' 64 -Nullable
    if ($State.source.kind -eq 'github') {
        if ($null -ne $State.source.worktreeDirty -or $null -ne $State.source.evidenceFingerprint) { throw 'GitHub observations cannot assert a local worktree state.' }
    } elseif ($State.source.worktreeDirty -isnot [bool] -or $null -eq $State.source.evidenceFingerprint) { throw 'Local observations require worktree state and fingerprint.' }
    if ($null -ne $State.checkpoint) {
        Assert-StateKeys $State.checkpoint @('taskId','phase','branch','head','recordedAt','summary') 'checkpoint'
        Assert-StateText $State.checkpoint.taskId 'taskId' 100
        Assert-StateText $State.checkpoint.phase 'phase' 100
        Assert-StateText $State.checkpoint.branch 'checkpoint branch' 240
        Assert-StateHash $State.checkpoint.head 'checkpoint head'
        Assert-StateDate $State.checkpoint.recordedAt 'checkpoint recordedAt'
        if ($null -ne $State.checkpoint.summary) { Assert-StateSummary $State.checkpoint.summary }
    }
    Assert-StateKeys $State.evidence @('status','current','recordedAt','head','fingerprint') 'evidence'
    if ($State.evidence.status -cnotin @('VERIFIED','UNVERIFIED','MISSING','UNKNOWN') -or $State.evidence.current -isnot [bool]) { throw 'Invalid evidence status.' }
    Assert-StateDate $State.evidence.recordedAt 'evidence recordedAt' -Nullable
    Assert-StateHash $State.evidence.head 'evidence head' 40 -Nullable
    Assert-StateHash $State.evidence.fingerprint 'evidence fingerprint' 64 -Nullable
    if ($State.evidence.current) {
        if ($State.source.kind -ne 'local-git' -or $State.evidence.status -ne 'VERIFIED' -or $null -eq $State.evidence.recordedAt -or $State.evidence.head -ne $State.source.commit -or $State.evidence.fingerprint -ne $State.source.evidenceFingerprint -or $null -eq $State.checkpoint -or $State.checkpoint.head -ne $State.source.commit -or $State.checkpoint.branch -ne $State.source.branch) { throw 'Current evidence must match the local source and checkpoint.' }
        if ([datetimeoffset]$State.evidence.recordedAt -lt [datetimeoffset]$State.checkpoint.recordedAt) { throw 'Evidence predates the task checkpoint.' }
    }
    if ($State.sources -isnot [array] -or @($State.sources).Count -lt 1 -or @($State.sources).Count -gt 24) { throw 'Provide 1-24 explicit document sources.' }
    $seen=@{}
    foreach ($item in @($State.sources)) {
        Assert-StateKeys $item @('path','committedBlobSha','sha256') 'document source'
        Assert-StateRelativePath $item.path
        if ($seen.ContainsKey($item.path.ToLowerInvariant())) { throw 'Duplicate document source.' }
        $seen[$item.path.ToLowerInvariant()]=$true
        Assert-StateHash $item.committedBlobSha 'document blob SHA'
        Assert-StateHash $item.sha256 'document SHA-256' 64
    }
    if ($State.limitations -isnot [array] -or @($State.limitations).Count -gt 24) { throw 'Limitations must be a bounded array.' }
    foreach ($item in @($State.limitations)) { Assert-StateText $item 'limitation' 1000 }
    Assert-StateKeys $State.workstreams @('accepted','drafts') 'workstreams'
    if ($null -ne $State.workstreams.accepted) {
        Assert-StateKeys $State.workstreams.accepted @('branch','commit') 'accepted workstream'
        Assert-StateText $State.workstreams.accepted.branch 'accepted branch' 240
        Assert-StateHash $State.workstreams.accepted.commit 'accepted commit'
    }
    if ($State.workstreams.drafts -isnot [array] -or @($State.workstreams.drafts).Count -gt 30) { throw 'Drafts must be a bounded array.' }
    foreach ($item in @($State.workstreams.drafts)) {
        Assert-StateKeys $item @('number','headBranch','headCommit','baseBranch','draft','url') 'draft workstream'
        if ($item.number -isnot [int] -and $item.number -isnot [long]) { throw 'PR number must be an integer.' }
        if ($item.number -lt 1 -or $item.draft -isnot [bool]) { throw 'Invalid PR number or draft flag.' }
        Assert-StateText $item.headBranch 'PR head branch' 240
        Assert-StateText $item.baseBranch 'PR base branch' 240
        Assert-StateHash $item.headCommit 'PR head commit'
        if ($item.url -cne ('https://github.com/' + $State.repository.fullName + '/pull/' + $item.number)) { throw 'PR URL must belong to this repository and PR number.' }
    }
}

function Get-StateContainedPath {
    param([string]$Root,[string]$Relative)
    Assert-StateRelativePath $Relative
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    $prefix=$Root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes repository.' }
    $cursor=$full
    while ($cursor.Length -gt $Root.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Symlink/reparse-point sources are not allowed.' }
        }
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}

function Write-StateAtomic {
    param([string]$Path,[string]$Json,[string]$ExpectedHash)
    Ensure-AdosDirectory (Split-Path -Parent $Path)
    $lockPath=$Path + '.lock'
    $lock=$null
    $temporary=$Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None) }
        catch { throw 'Snapshot destination is locked; do not overwrite another writer.' }
        $exists=Test-Path -LiteralPath $Path -PathType Leaf
        if ($exists) {
            Assert-ProjectState (Read-StateJson $Path)
            $actual=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not $ExpectedHash -or $ExpectedHash -cne $actual) { throw 'Snapshot changed or replacement hash is missing; inspect it before retrying.' }
        } elseif ($ExpectedHash) { throw 'Expected snapshot does not exist.' }
        Write-AdosUtf8 $temporary $Json
        if ($exists) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if ($null -ne $lock) { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force }
    }
}

function Get-StateCommittedHash {
    param([string]$Root,[string]$BlobSha)
    Assert-StateHash $BlobSha 'document blob SHA'
    $info=New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName='git'
    $info.Arguments='cat-file blob ' + $BlobSha
    $info.WorkingDirectory=$Root
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $process=New-Object System.Diagnostics.Process
    $process.StartInfo=$info
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        if (-not $process.Start()) { throw 'Unable to read committed document bytes.' }
        $hash=$sha.ComputeHash($process.StandardOutput.BaseStream)
        $null=$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Unable to read committed document bytes.' }
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose(); $process.Dispose() }
}

if ($Command -ne 'export') {
    if (-not $SnapshotPath) { throw 'SnapshotPath is required.' }
    $snapshot=Read-StateJson $SnapshotPath
    Assert-ProjectState $snapshot
    if ($Command -eq 'validate') { Write-Host 'Project state: VALID' }
    else { $snapshot | ConvertTo-Json -Depth 12 }
    return
}

$root=Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
if (-not [IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath=Join-Path $root $ConfigPath }
$config=Read-StateJson $ConfigPath
Assert-StateKeys $config @('schemaVersion','projectId','repository','sources','includeTaskSummary') 'export configuration'
if ($config.schemaVersion -ne 1 -or $config.includeTaskSummary -isnot [bool] -or $config.sources -isnot [array]) { throw 'Invalid export configuration.' }
if (@($config.sources).Count -lt 1 -or @($config.sources).Count -gt 24) { throw 'Provide 1-24 explicit sources.' }
Assert-StateKeys $config.repository @('fullName','visibility') 'repository'
Push-Location $root
try { $origin=(& git remote get-url origin 2>$null | Out-String).Trim() }
finally { Pop-Location }
$origin=$origin -replace '\.git$',''
if ($origin -notmatch '^(?:https://(?:[^/@]+@)?github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$' -or $Matches[1] -ine [string]$config.repository.fullName) { throw 'Configured repository must match the GitHub origin; do not export another project under this identity.' }
$head=Get-AdosHead $root
$branch=Get-AdosBranch $root
$fingerprint=Get-AdosEvidenceFingerprint $root
$documents=@()
Push-Location $root
try {
    foreach ($relative in @($config.sources)) {
        $full=Get-StateContainedPath $root $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing document: $relative" }
        $blob=(& git rev-parse ($head + ':' + $relative) 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $blob -cnotmatch '^[a-f0-9]{40}$') { throw "Source must exist in the observed commit: $relative" }
        $documents += [pscustomobject][ordered]@{ path=$relative; committedBlobSha=$blob; sha256=(Get-StateCommittedHash $root $blob) }
    }
} finally { Pop-Location }
$checkpoint=$null
$checkpointPath=Join-Path $root '.ai/checkpoints/current.json'
if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
    $saved=Read-StateJson $checkpointPath
    $checkpoint=[pscustomobject][ordered]@{
        taskId=[string]$saved.taskId; phase=[string]$saved.phase; branch=[string]$saved.branch
        head=[string]$saved.head; recordedAt=[string]$saved.generated
        summary=$(if ($config.includeTaskSummary) { [string]$saved.task } else { $null })
    }
}
$evidence=[pscustomobject][ordered]@{ status='MISSING'; current=$false; recordedAt=$null; head=$null; fingerprint=$null }
$gatePath=Join-Path $root '.ai/evidence/evidence-gate.generated.json'
if (Test-Path -LiteralPath $gatePath -PathType Leaf) {
    $gate=Read-StateJson $gatePath
    $evidence.status=[string]$gate.status
    $evidence.recordedAt=[string]$gate.generated
    $evidence.head=[string]$gate.head
    $evidence.fingerprint=[string]$gate.evidenceFingerprint
    $verification=$null
    $scope=$null
    $verificationPath=Join-Path $root '.ai/evidence/verification.generated.json'
    $scopePath=Join-Path $root '.ai/evidence/scope-guard.generated.json'
    if (Test-Path -LiteralPath $verificationPath -PathType Leaf) { $verification=Read-StateJson $verificationPath }
    if (Test-Path -LiteralPath $scopePath -PathType Leaf) { $scope=Read-StateJson $scopePath }
    $inputsCurrent=Test-AdosEvidenceGateCurrent $gate $verification $scope $head $branch $fingerprint
    $taskMatches=($null -ne $checkpoint -and $null -ne $scope -and @($scope.PSObject.Properties.Name) -contains 'task' -and [string]$scope.task -ceq [string]$saved.task)
    $evidence.current=($inputsCurrent -and $taskMatches -and $checkpoint.head -eq $head -and $checkpoint.branch -eq $branch -and [datetimeoffset]$evidence.recordedAt -ge [datetimeoffset]$checkpoint.recordedAt)
}
$snapshot=[pscustomobject][ordered]@{
    schemaVersion=1; projectId=$config.projectId; repository=$config.repository
    observedAt=[datetimeoffset]::UtcNow.ToString('o')
    source=[pscustomobject][ordered]@{ kind='local-git'; branch=$branch; commit=$head; worktreeDirty=(@(Get-AdosChangedFiles $root).Count -gt 0); evidenceFingerprint=$fingerprint }
    checkpoint=$checkpoint; evidence=$evidence; sources=@($documents)
    limitations=@('As-of record; recheck the source branch before claiming current state.','Document hashes refer to committed Git bytes; uncommitted document edits are not published.','Task evidence does not establish overall project or release readiness.','Unpublished changes on other devices and unobserved draft branches are unknown.')
    workstreams=[pscustomobject][ordered]@{ accepted=$null; drafts=@() }
}
Assert-ProjectState $snapshot
if ($fingerprint -ne (Get-AdosEvidenceFingerprint $root)) { throw 'Repository changed during export; retry from a stable checkpoint.' }
if (-not $SnapshotPath) { $SnapshotPath=Join-Path $root '.ai/local-output/project-state.json' }
elseif (-not [IO.Path]::IsPathRooted($SnapshotPath)) { $SnapshotPath=Join-Path $root $SnapshotPath }
$fullOutput=[IO.Path]::GetFullPath($SnapshotPath)
$rootPrefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $fullOutput.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase) -or $fullOutput -match '(?i)[\\/]\.git[\\/]' -or [IO.Path]::GetExtension($fullOutput) -cne '.json') { throw 'Snapshot output must be a JSON file inside this repository, outside .git.' }
foreach ($document in $documents) { if ($fullOutput -eq (Join-Path $root $document.path)) { throw 'Snapshot cannot overwrite a canonical source.' } }
$cursor=$fullOutput
while ($cursor.Length -gt $root.Length) {
    if (Test-Path -LiteralPath $cursor) {
        if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Symlink/reparse-point output is not allowed.' }
    }
    $cursor=Split-Path -Parent $cursor
}
$json=$snapshot | ConvertTo-Json -Depth 12
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 131072) { throw 'Snapshot exceeds 128 KiB.' }
Write-StateAtomic $fullOutput $json $ExpectedSnapshotSha256
Write-Host ("Project state exported: $fullOutput (task evidence current: $($evidence.current))")
