Set-StrictMode -Version 2.0

function Resolve-AdosRepoRoot {
    param([string]$Path)

    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    }
    finally { Pop-Location }
}

function Ensure-AdosDirectory {
    param([string]$Path)
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-AdosUtf8 {
    param([string]$Path, [string]$Content)

    Ensure-AdosDirectory (Split-Path -Parent $Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-AdosJson {
    param([string]$Path, $Value, [int]$Depth = 12)
    Write-AdosUtf8 $Path ($Value | ConvertTo-Json -Depth $Depth)
}

function Read-AdosJson {
    param([string]$Path, $DefaultValue = $null)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $DefaultValue }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $DefaultValue }
}

function Read-AdosQueueFile {
    param([string]$Root)

    $path = Join-Path $Root '.ai\queue\tasks.json'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ schemaVersion=2; tasks=@() } }
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($text) -or -not $text.TrimStart().StartsWith('{')) {
            throw 'Expected a JSON object.'
        }
        $queue = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "Invalid ADOS queue: cannot read a JSON object at $path. The original file was not changed." }

    $properties = @($queue.PSObject.Properties | ForEach-Object { $_.Name })
    if ($properties -notcontains 'schemaVersion' -or @('1','2') -notcontains [string]$queue.schemaVersion -or
        $properties -notcontains 'tasks' -or $queue.tasks -isnot [System.Array]) {
        throw "Invalid ADOS queue: expected schemaVersion 1 or 2 and a tasks array at $path. The original file was not changed."
    }
    $ids = @{}
    foreach ($item in $queue.tasks) {
        if ($item -isnot [pscustomobject]) { throw 'Invalid ADOS queue: every task must be an object.' }
        $fields = @($item.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($required in @('id','task','status','priority','created','attempts','note')) {
            if ($fields -notcontains $required) { throw "Invalid ADOS queue: task is missing $required." }
        }
        if ($item.id -isnot [string] -or [string]::IsNullOrWhiteSpace($item.id) -or
            $item.task -isnot [string] -or [string]::IsNullOrWhiteSpace($item.task) -or
            @('pending','claimed','completed','failed','blocked','cancelled') -notcontains [string]$item.status -or
            @('low','normal','high','protected') -notcontains [string]$item.priority) {
            throw 'Invalid ADOS queue: task ID, text, status, or priority is invalid.'
        }
        if ($ids.ContainsKey([string]$item.id)) { throw 'Invalid ADOS queue: duplicate task ID.' }
        $ids[[string]$item.id] = $true
        $attemptCount = 0
        if (-not [int]::TryParse([string]$item.attempts, [ref]$attemptCount) -or $attemptCount -lt 0) {
            throw 'Invalid ADOS queue: attempts must be a nonnegative integer.'
        }
        if ([string]$item.status -eq 'claimed') {
            if ($fields -notcontains 'leaseId' -or [string]::IsNullOrWhiteSpace([string]$item.leaseId) -or
                $fields -notcontains 'leaseUntil' -or [string]::IsNullOrWhiteSpace([string]$item.leaseUntil)) {
                throw 'Invalid ADOS queue: a claimed task requires a lease ID and expiration.'
            }
            try { $null = [DateTimeOffset]::Parse([string]$item.leaseUntil) }
            catch { throw 'Invalid ADOS queue: a claimed task has an invalid lease expiration.' }
        }
    }
    return $queue
}

function Get-AdosRelativePath {
    param([string]$Root, [string]$FullPath)

    $rootUri = New-Object System.Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/', '\')
}

function Get-AdosChangedFiles {
    param([string]$Root)

    Push-Location $Root
    try {
        $files = @()
        $files += @(& git -c core.safecrlf=false diff --name-only 2>$null)
        $files += @(& git -c core.safecrlf=false diff --cached --name-only 2>$null)
        $files += @(& git ls-files --others --exclude-standard 2>$null)
        return @($files | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)
    }
    finally { Pop-Location }
}

function Get-AdosSourceFiles {
    param([string]$Root, [int]$Limit = 2000, [switch]$IncludeDocs)

    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.ps1','.psm1','.psd1','.rs','.go','.java','.kt','.kts','.cs','.sql')
    if ($IncludeDocs) { $extensions += @('.md','.txt','.json','.yaml','.yml','.toml') }
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor|target|bin|obj)[\\/]'
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant() -and
            $_.FullName -notmatch $excluded -and
            $_.Length -lt 1000000
        } |
        Sort-Object FullName |
        Select-Object -First $Limit)
}

function Get-AdosTaskTerms {
    param([string]$Text)

    $stop = @(
        'the','and','for','with','from','this','that','into','when','then','fix','fixed',
        'update','updated','change','changed','add','added','remove','removed','error',
        'issue','bug','task','project','code','file','files','please','need','make','check',
        'implement','implementation','improve','using','should','would','could'
    )
    $parts = [regex]::Matches($Text.ToLowerInvariant(), '[\p{L}\p{Nd}_-]{3,}') |
        ForEach-Object { $_.Value }
    return @($parts | Where-Object { $stop -notcontains $_ } | Sort-Object -Unique | Select-Object -First 24)
}

function Get-AdosTextHash {
    param([string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-AdosTaskId {
    param([string]$Task)
    $hash = Get-AdosTextHash $Task
    return $hash.Substring(0, 16)
}

function Get-AdosEvidenceFingerprint {
    param([string]$Root)

    Push-Location $Root
    try {
        $parts = @(
            'HEAD=' + (Get-AdosHead $Root),
            'BRANCH=' + (Get-AdosBranch $Root)
        )
        $changed = @(Get-AdosChangedFiles $Root | Sort-Object)
        foreach ($relative in $changed) {
            $candidate = Join-Path $Root ([string]$relative)
            $gitPath = ([string]$relative).Replace('\', '/')
            $indexState = (& git ls-files -s -- $gitPath 2>$null | Out-String).Trim()
            $worktreeState = 'missing'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                try { $worktreeState = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() }
                catch {
                    $item = Get-Item -LiteralPath $candidate
                    $worktreeState = 'unreadable:' + [string]$item.Length
                }
            }
            $parts += ([string]$relative).Replace('/', '\') + '|index=' + $indexState + '|worktree=' + $worktreeState
        }
        return Get-AdosTextHash ($parts -join "`n")
    }
    finally { Pop-Location }
}

function Get-AdosHead {
    param([string]$Root)
    Push-Location $Root
    try { return ((& git rev-parse HEAD 2>$null | Out-String).Trim()) }
    finally { Pop-Location }
}

function Get-AdosBranch {
    param([string]$Root)
    Push-Location $Root
    try { return ((& git branch --show-current 2>$null | Out-String).Trim()) }
    finally { Pop-Location }
}

function Test-AdosVerificationState {
    param($Value, [string]$Head, [string]$Branch, [string]$Fingerprint)

    if ($null -eq $Value) { return $false }
    $fields = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($required in @('head','branch','evidenceFingerprint','endEvidenceFingerprint','repositoryUnchanged')) {
        if ($fields -notcontains $required) { return $false }
    }
    return [bool](
        $Value.repositoryUnchanged -is [bool] -and $Value.repositoryUnchanged -and
        [string]$Value.head -ceq $Head -and [string]$Value.branch -ceq $Branch -and
        [string]$Value.evidenceFingerprint -ceq $Fingerprint -and
        [string]$Value.endEvidenceFingerprint -ceq $Fingerprint
    )
}

function Test-AdosEvidenceGateCurrent {
    param($Gate, $Verification, $Scope, [string]$Head, [string]$Branch, [string]$Fingerprint)

    if ($null -eq $Gate) { return $false }
    $fields = @($Gate.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($required in @('status','head','branch','evidenceFingerprint','inputsCurrent','generated')) {
        if ($fields -notcontains $required) { return $false }
    }
    if ([string]$Gate.status -cne 'VERIFIED' -or $Gate.inputsCurrent -isnot [bool] -or -not $Gate.inputsCurrent -or
        [string]$Gate.head -cne $Head -or [string]$Gate.branch -cne $Branch -or [string]$Gate.evidenceFingerprint -cne $Fingerprint) {
        return $false
    }
    try { $gateAt = [DateTimeOffset]::Parse([string]$Gate.generated) }
    catch { return $false }
    if ($gateAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { return $false }
    foreach ($artifact in @($Verification, $Scope)) {
        if (-not (Test-AdosVerificationState $artifact $Head $Branch $Fingerprint)) { return $false }
        $fields = @($artifact.PSObject.Properties | ForEach-Object { $_.Name })
        if ($fields -notcontains 'status' -or [string]$artifact.status -cne 'PASS' -or $fields -notcontains 'generated') { return $false }
        try { $artifactAt = [DateTimeOffset]::Parse([string]$artifact.generated) }
        catch { return $false }
        if ($artifactAt -gt $gateAt) { return $false }
    }
    return $true
}

function Get-AdosQueueCompletionEvidence {
    param([string]$Root, [string]$TaskText, [string]$NotBefore = '', [string]$LeaseId = '')

    $gate = Read-AdosJson (Join-Path $Root '.ai\evidence\evidence-gate.generated.json') $null
    $gateFields = if ($null -ne $gate) { @($gate.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
    if ($gateFields -notcontains 'status' -or [string]$gate.status -cne 'VERIFIED') {
        throw 'Completion requires a VERIFIED Evidence Gate. Run ADOS verification for this task first.'
    }
    foreach ($required in @('head','branch','evidenceFingerprint','generated','inputsCurrent')) {
        if ($gateFields -notcontains $required) { throw "Completion requires current Evidence Gate metadata: missing $required." }
    }
    if ($gate.inputsCurrent -isnot [bool] -or -not $gate.inputsCurrent) {
        throw 'Completion requires a VERIFIED Evidence Gate with current scope and verification inputs.'
    }

    $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
    $checkpointFields = if ($null -ne $checkpoint) { @($checkpoint.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
    foreach ($required in @('taskId','task','branch','generated')) {
        if ($checkpointFields -notcontains $required) { throw 'Completion requires a checkpoint for the same queued task.' }
    }
    $taskId = Get-AdosTaskId $TaskText
    if ([string]$checkpoint.taskId -cne $taskId -or [string]$checkpoint.task -cne $TaskText) {
        throw 'Completion requires a checkpoint for the same queued task. Start/checkpoint its exact task text and verify it.'
    }
    $head = Get-AdosHead $Root
    $branch = Get-AdosBranch $Root
    $fingerprint = Get-AdosEvidenceFingerprint $Root
    if ([string]$gate.head -cne $head -or [string]$gate.branch -cne $branch -or
        [string]$checkpoint.branch -cne $branch -or [string]$gate.evidenceFingerprint -cne $fingerprint) {
        throw 'Completion evidence does not match the current repository state. Run ADOS verification again.'
    }
    try {
        $verifiedAt = [DateTimeOffset]::Parse([string]$gate.generated)
        $checkpointAt = [DateTimeOffset]::Parse([string]$checkpoint.generated)
        $minimumAt = if ($NotBefore) { [DateTimeOffset]::Parse($NotBefore) } else { $checkpointAt }
    }
    catch { throw 'Completion requires valid checkpoint, claim, and evidence timestamps.' }
    if ($verifiedAt -lt $checkpointAt -or $verifiedAt -lt $minimumAt) {
        throw 'Completion evidence predates the task checkpoint or current claim. Verify this attempt before completing it.'
    }
    if ($verifiedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) {
        throw 'Completion evidence has a future timestamp. Check the clock and verify this task again.'
    }
    foreach ($artifactName in @('verification','scope-guard')) {
        $artifact = Read-AdosJson (Join-Path $Root ('.ai\evidence\' + $artifactName + '.generated.json')) $null
        $fields = if ($null -ne $artifact) { @($artifact.PSObject.Properties | ForEach-Object { $_.Name }) } else { @() }
        if ($fields -notcontains 'status' -or [string]$artifact.status -cne 'PASS' -or $fields -notcontains 'generated') {
            throw "Completion requires passing $artifactName evidence. Run ADOS verification again."
        }
        if ($artifactName -eq 'scope-guard' -and ($fields -notcontains 'task' -or [string]$artifact.task -cne $TaskText)) {
            throw 'Completion requires scope evidence for the same queued task.'
        }
        if (-not (Test-AdosVerificationState $artifact $head $branch $fingerprint)) {
            throw "Completion $artifactName evidence does not match the current repository state. Run ADOS verification again."
        }
        try { $artifactAt = [DateTimeOffset]::Parse([string]$artifact.generated) }
        catch { throw "Completion requires a valid $artifactName timestamp." }
        if ($artifactAt -lt $checkpointAt -or $artifactAt -lt $minimumAt) {
            throw "Completion $artifactName evidence predates the task checkpoint or current claim. Run verification for this attempt."
        }
        if ($artifactAt -gt $verifiedAt) { throw "Completion Evidence Gate predates the latest $artifactName result. Run the gate again." }
    }
    return [pscustomobject]@{
        taskId=$taskId; generated=[string]$gate.generated; head=$head; branch=$branch;
        evidenceFingerprint=$fingerprint; leaseId=$LeaseId
    }
}

function Add-AdosUsageEvent {
    param(
        [string]$Root,
        [string]$Stage,
        [string]$Status,
        [long]$DurationMs = 0,
        [long]$InputBytes = 0,
        [long]$SelectedBytes = 0,
        [hashtable]$Details = @{}
    )

    $path = Join-Path $Root '.ai\analytics\usage-events.json'
    $existing = Read-AdosJson $path $null
    $events = @()
    if ($existing -and $existing.events) { $events = @($existing.events) }
    $events += [pscustomobject]@{
        generated = (Get-Date -Format o)
        stage = $Stage
        status = $Status
        durationMs = $DurationMs
        inputBytes = $InputBytes
        selectedBytes = $SelectedBytes
        details = [pscustomobject]$Details
    }
    if ($events.Count -gt 1000) { $events = @($events | Select-Object -Last 1000) }
    $payload = [ordered]@{ schemaVersion = 1; events = @($events) }
    Write-AdosJson $path $payload 10
}

function Enter-AdosQueueLock {
    param([string]$Root)

    $directory = Join-Path $Root '.ai\queue'
    Ensure-AdosDirectory $directory
    $path = Join-Path $directory 'dispatcher.lock'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $age = (Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime
        if ($age.TotalMinutes -gt 10) { Remove-Item -LiteralPath $path -Force }
    }
    try {
        New-Item -ItemType File -Path $path -Value ("$PID|" + (Get-Date -Format o)) -ErrorAction Stop | Out-Null
    }
    catch { throw 'ADOS queue is busy: another process owns the queue lock.' }
    return $path
}

function Exit-AdosQueueLock {
    param([string]$Path)
    if ($Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function ConvertTo-AdosMarkdownList {
    param([object[]]$Items, [string]$EmptyText = 'none')
    $lines = @($Items | ForEach-Object { '- `' + [string]$_ + '`' })
    if ($lines.Count -eq 0) { return @("- $EmptyText") }
    return $lines
}

function Ensure-AdosLocalExclude {
    param([string]$Root)

    Push-Location $Root
    try { $exclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
    finally { Pop-Location }
    if (-not $exclude) { throw "Unable to resolve Git exclude path for $Root" }
    if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $Root $exclude }
    $exclude = [IO.Path]::GetFullPath($exclude)
    Ensure-AdosDirectory (Split-Path -Parent $exclude)
    $rules = @('.ai/index/','.ai/evidence/','.ai/checkpoints/','.ai/queue/','.ai/memory/','.ai/analytics/','.ai/local-output/','.ai/test-work/','.ai/context/*.generated.json','.ai/context/*.generated.md')
    $existing = if (Test-Path -LiteralPath $exclude) { @(Get-Content -LiteralPath $exclude) } else { @() }
    foreach ($rule in $rules) {
        if ($existing -notcontains $rule) { Add-Content -LiteralPath $exclude -Value $rule -Encoding UTF8 }
    }
}
