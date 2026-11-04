[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('adapter','checkpoint','resume','queue-add','queue-next','queue-complete','night','health','usage','benchmark')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$Task = '',
    [string]$QueueId = '',
    [string]$Phase = 'prepared',
    [ValidateSet('low','normal','high','protected')]
    [string]$Priority = 'normal',
    [ValidateSet('pending','completed','failed','cancelled','blocked')]
    [string]$QueueStatus = 'completed',
    [ValidateSet('auto','small','medium','large','protected')]
    [string]$ContextTier = 'auto',
    [int]$MaxFiles = 2000,
    [ValidateRange(2,365)]
    [int]$HealthHistoryLimit = 90
)

$ErrorActionPreference = 'Stop'
$ScriptsRoot = $PSScriptRoot
$Common = Join-Path $ScriptsRoot 'ados-common.ps1'
$Index = Join-Path $ScriptsRoot 'ados-index.ps1'
$MemoryV3 = Join-Path $ScriptsRoot 'ados-memory-v3.ps1'
$NightAudit = Join-Path $ScriptsRoot 'ados-night-audit.ps1'
$Health = Join-Path $ScriptsRoot 'ados-health.ps1'
. $Common

function Get-AdosProjectAdapter {
    param([string]$Root)

    $repoName = (Split-Path $Root -Leaf).ToLowerInvariant()
    $package = $null
    $packagePath = Join-Path $Root 'package.json'
    if (Test-Path -LiteralPath $packagePath) {
        try { $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json } catch { $package = $null }
    }
    $packageText = if ($package) { ($package | ConvertTo-Json -Depth 8).ToLowerInvariant() } else { '' }
    $hasSupabase = (Test-Path -LiteralPath (Join-Path $Root 'supabase')) -or $packageText.Contains('supabase')
    $hasExpo = $packageText.Contains('expo') -or (Test-Path -LiteralPath (Join-Path $Root 'app.json'))
    $hasBpmn = $packageText.Contains('bpmn') -or $repoName.Contains('bpmn')

    $adapter = 'generic'
    $detectedBy = 'fallback'
    $tech = @()
    $boundaries = @('secrets','credentials','production','release','architecture','dependencies')
    $roots = @('src','app','tests','docs')
    $checks = @('git diff --check')
    $entrypoints = @()

    if ($repoName -match 'atlas.*market|market.*atlas') {
        $adapter = 'atlas-market-os'
        $detectedBy = 'repository name'
        $tech = @('market data','simulation','risk controls','audit')
        $boundaries += @('live trading','broker connectivity','real money','risk gates','UTC loss gate')
        $roots = @('src','tests','docs','scripts')
        $checks += @('simulation tests','risk-gate tests','audit checks')
    }
    elseif ($repoName -match 'navira|masha-albert-health' -or ($hasExpo -and $hasSupabase)) {
        $adapter = 'navira'
        $detectedBy = if ($repoName -match 'navira|masha-albert-health') { 'repository name' } else { 'Expo and Supabase signals' }
        $tech = @('Expo','React Native','Supabase','EAS')
        $boundaries += @('Supabase RLS','SQL migrations','authentication','EAS production builds','notifications')
        $roots = @('app','src','components','services','supabase','tests')
        $checks += @('typecheck','focused social-flow tests','Supabase security checks')
        $entrypoints += @(
            'docs/project-brain/README.md',
            'docs/project-brain/CURRENT_FOCUS.md',
            'docs/project-brain/AGENT_ENTRYPOINTS.md'
        )
    }
    elseif ($hasBpmn) {
        $adapter = 'bpmn-studio'
        $detectedBy = 'BPMN dependency or repository name'
        $tech = @('BPMN 2.0','DMN','XML','diagram graph')
        $boundaries += @('BPMN schema compatibility','DMN semantics','round-trip XML fidelity')
        $roots = @('src','packages','tests','fixtures','docs')
        $checks += @('schema validation','round-trip tests','layout tests')
    }
    elseif ($package) {
        $adapter = 'generic-web-mobile'
        $detectedBy = 'package.json'
        $tech = @('Node.js')
        if ($packageText.Contains('react')) { $tech += 'React' }
        if ($hasExpo) { $tech += 'Expo' }
        if ($hasSupabase) { $tech += 'Supabase'; $boundaries += @('Supabase RLS','SQL migrations','authentication') }
        $checks += @('typecheck when available','focused tests when available')
    }

    $adapterConfigPath = Join-Path $Root '.ados\adapter.json'
    if (Test-Path -LiteralPath $adapterConfigPath -PathType Leaf) {
        $adapterConfig = Read-AdosJson $adapterConfigPath $null
        if ($adapterConfig) {
            $propertyNames = @($adapterConfig.PSObject.Properties | ForEach-Object { $_.Name })
            if ($propertyNames -contains 'name' -and $adapterConfig.name) { $adapter = [string]$adapterConfig.name }
            if ($propertyNames -contains 'technologies' -and $adapterConfig.technologies) { $tech = @($adapterConfig.technologies) }
            if ($propertyNames -contains 'protectedBoundaries' -and $adapterConfig.protectedBoundaries) { $boundaries += @($adapterConfig.protectedBoundaries) }
            if ($propertyNames -contains 'contextRoots' -and $adapterConfig.contextRoots) { $roots = @($adapterConfig.contextRoots) }
            if ($propertyNames -contains 'verificationHints' -and $adapterConfig.verificationHints) { $checks += @($adapterConfig.verificationHints) }
            if ($propertyNames -contains 'contextEntrypoints' -and $adapterConfig.contextEntrypoints) { $entrypoints += @($adapterConfig.contextEntrypoints) }
            $detectedBy = '.ados/adapter.json'
        }
    }

    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        adapter = $adapter
        detectedBy = $detectedBy
        repository = $repoName
        technologies = @($tech | Sort-Object -Unique)
        protectedBoundaries = @($boundaries | Sort-Object -Unique)
        contextRoots = @($roots | Sort-Object -Unique)
        contextEntrypoints = @($entrypoints | Sort-Object -Unique)
        verificationHints = @($checks | Sort-Object -Unique)
        mutationPolicy = 'adapter is advisory and never edits product configuration'
    }
    $jsonPath = Join-Path $Root '.ai\context\project-adapter.generated.json'
    Write-AdosJson $jsonPath $payload 8
    $lines = @('# ADOS project adapter','',"Adapter: $adapter","Detected by: $detectedBy",'', '## Technologies')
    $lines += ConvertTo-AdosMarkdownList $payload.technologies
    $lines += @('','## Protected boundaries')
    $lines += ConvertTo-AdosMarkdownList $payload.protectedBoundaries
    $lines += @('','## Context roots')
    $lines += ConvertTo-AdosMarkdownList $payload.contextRoots
    $lines += @('','## Context entrypoints')
    $lines += ConvertTo-AdosMarkdownList $payload.contextEntrypoints
    $lines += @('','## Safety','- Advisory only. Existing project configuration was not changed.')
    Write-AdosUtf8 (Join-Path $Root '.ai\context\project-adapter.generated.md') ($lines -join "`r`n")
    Write-Host "Project adapter: $adapter ($detectedBy)"
    return $payload
}

function Save-AdosCheckpoint {
    param([string]$Root, [string]$TaskText, [string]$CurrentPhase)

    if (-not $TaskText) { throw 'Task is required for checkpoint.' }
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        taskId = Get-AdosTaskId $TaskText
        task = $TaskText
        phase = $CurrentPhase
        branch = Get-AdosBranch $Root
        head = Get-AdosHead $Root
        evidenceFingerprint = Get-AdosEvidenceFingerprint $Root
        baselineChangedFiles = @(Get-AdosChangedFiles $Root | Where-Object { $_ -notmatch '(?i)^\.ai[\\/]' })
        outputs = [ordered]@{
            promptPacket = '.ai\context\prompt-packet.generated.md'
            elasticContext = '.ai\context\elastic-context.generated.md'
            handoff = '.ai\context\handoff.generated.md'
            evidence = '.ai\evidence\evidence-gate.generated.md'
            prEvidenceSummary = '.ai\evidence\pr-evidence-summary.generated.md'
        }
    }
    $path = Join-Path $Root '.ai\checkpoints\current.json'
    Write-AdosJson $path $payload 8
    Write-Host "Checkpoint saved: $($payload.taskId) at $CurrentPhase"
    return $payload
}

function Resume-AdosCheckpoint {
    param([string]$Root)

    $path = Join-Path $Root '.ai\checkpoints\current.json'
    $checkpoint = Read-AdosJson $path $null
    if (-not $checkpoint) { throw 'No ADOS checkpoint exists for this project.' }
    $currentBranch = Get-AdosBranch $Root
    $currentHead = Get-AdosHead $Root
    $branchChanged = [string]$checkpoint.branch -cne $currentBranch
    $headChanged = [string]$checkpoint.head -cne $currentHead
    $currentFingerprint = Get-AdosEvidenceFingerprint $Root
    $fingerprintProperty = $checkpoint.PSObject.Properties['evidenceFingerprint']
    $checkpointFingerprint = $null
    if ($null -ne $fingerprintProperty -and $fingerprintProperty.Value -is [string] -and
        $fingerprintProperty.Value -cmatch '^[a-f0-9]{64}$') {
        $checkpointFingerprint = [string]$fingerprintProperty.Value
    }
    $fingerprintKnown = $null -ne $checkpointFingerprint
    $fingerprintChanged = $null
    if ($fingerprintKnown) { $fingerprintChanged = $checkpointFingerprint -cne $currentFingerprint }

    $reasons = @()
    if ($branchChanged) { $reasons += 'BRANCH_CHANGED' }
    if ($headChanged) { $reasons += 'HEAD_CHANGED' }
    if (-not $fingerprintKnown) {
        $reasons += $(if ($null -eq $fingerprintProperty) { 'CHECKPOINT_FINGERPRINT_MISSING' } else { 'CHECKPOINT_FINGERPRINT_UNKNOWN' })
    }
    elseif ($fingerprintChanged -and -not $branchChanged -and -not $headChanged) {
        $reasons += 'WORKTREE_CHANGED'
    }

    if ($branchChanged) {
        $status = 'BRANCH_CHANGED'
        $nextAction = 'Review the current branch and task scope before choosing where to continue; reconcile the handoff and run Scope Guard, Verification Ladder, and Evidence Gate before completion.'
    }
    elseif ($headChanged) {
        $status = 'HEAD_CHANGED'
        $nextAction = 'Review commits and working-tree changes since the checkpoint, refresh the handoff, then continue on this branch; run Scope Guard, Verification Ladder, and Evidence Gate before completion.'
    }
    elseif (-not $fingerprintKnown) {
        $status = 'BASELINE_UNKNOWN'
        $nextAction = 'Review the working tree and handoff, then save a new checkpoint to establish a fingerprint baseline; continue with Scope Guard, Verification Ladder, and Evidence Gate before completion.'
    }
    elseif ($fingerprintChanged) {
        $status = 'WORKTREE_CHANGED'
        $nextAction = 'Review staged, unstaged, and untracked changes since the checkpoint, refresh the handoff, then continue; run Scope Guard, Verification Ladder, and Evidence Gate before completion.'
    }
    else {
        $status = 'UNCHANGED'
        $reasons += 'BASELINE_UNCHANGED'
        $nextAction = 'Re-read project rules and the handoff, then continue from the saved phase; Scope Guard, Verification Ladder, and Evidence Gate still determine completion.'
    }
    $files = @(Get-AdosChangedFiles $Root | Where-Object { $_ -notmatch '(?i)^\.ai[\\/]' })
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        checkpoint = $checkpoint
        currentBranch = $currentBranch
        currentHead = $currentHead
        branchChanged = $branchChanged
        headChanged = $headChanged
        checkpointFingerprint = $checkpointFingerprint
        currentFingerprint = $currentFingerprint
        fingerprintChanged = $fingerprintChanged
        currentChangedFiles = @($files)
        status = $status
        reasons = @($reasons)
        revalidationRequired = ($status -ne 'UNCHANGED')
        verificationStatus = 'NOT_EVALUATED'
        nextAction = $nextAction
        # Compatibility advisory only: this does not authorize edits or validate evidence.
        safeToResume = ($status -eq 'UNCHANGED')
    }
    Write-AdosJson (Join-Path $Root '.ai\context\resume.generated.json') $payload 10
    $lines = @(
        '# ADOS resume packet','',"Task: $($checkpoint.task)","Phase: $($checkpoint.phase)",
        "Checkpoint branch: $($checkpoint.branch)","Current branch: $currentBranch",
        "Checkpoint HEAD: $($checkpoint.head)","Current HEAD: $currentHead",
        "Resume status: $status",("Reasons: " + ($reasons -join ', ')),
        "Revalidation required by baseline drift: $($payload.revalidationRequired)",
        'Verification status: NOT_EVALUATED',
        "Safe to resume (compatibility advisory only): $($payload.safeToResume)",
        '', 'This packet does not validate prior evidence or grant permission to edit. A changed HEAD can be normal progress; review the change and continue with current checks.',
        '', '## Next action', $nextAction, '', '## Current changed files'
    )
    $lines += ConvertTo-AdosMarkdownList $files
    $lines += @('','## Resume order','1. Re-read AGENTS.md and project rules.','2. Review the elastic context and handoff.','3. Confirm the branch and working tree.','4. Continue from the saved phase.','5. Run Scope Guard, Verification Ladder, and Evidence Gate before completion.')
    Write-AdosUtf8 (Join-Path $Root '.ai\context\resume.generated.md') ($lines -join "`r`n")
    Write-Host "Resume packet written (status: $status, revalidation required: $($payload.revalidationRequired), phase: $($checkpoint.phase))"
    return $payload
}

function Get-AdosQueuePath {
    param([string]$Root)
    return Join-Path $Root '.ai\queue\tasks.json'
}

function Read-AdosQueue {
    param([string]$Root)
    return Read-AdosQueueFile $Root
}

function Write-AdosQueue {
    param([string]$Root, [object[]]$Tasks)
    $path = Get-AdosQueuePath $Root
    $temporary = "$path.$PID.tmp"
    Write-AdosJson $temporary ([ordered]@{ schemaVersion=2; updated=(Get-Date -Format o); tasks=@($Tasks) }) 12
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Add-AdosQueueTask {
    param([string]$Root, [string]$TaskText, [string]$TaskPriority)

    if (-not $TaskText) { throw 'Task is required for queue-add.' }
    $lockPath = Enter-AdosQueueLock $Root
    try {
        $queue = Read-AdosQueue $Root
        $tasks = @($queue.tasks)
        $created = Get-Date -Format o
        $id = (Get-AdosTextHash ($TaskText + '|' + $created)).Substring(0, 16)
        $added = [pscustomobject]@{
            id=$id; created=$created; updated=$created; task=$TaskText; priority=$TaskPriority;
            status='pending'; attempts=0; note='Queue preparation is local and does not invoke a model or edit product code.'
        }
        $tasks += $added
        Write-AdosQueue $Root $tasks
    }
    finally { Exit-AdosQueueLock $lockPath }
    Write-Host "Queued task: $id ($TaskPriority)"
    return $added
}

function Get-AdosNextQueueTask {
    param([string]$Root)

    $queue = Read-AdosQueue $Root
    $rank = @{ protected=0; high=1; normal=2; low=3 }
    $pending = @($queue.tasks | Where-Object { $_.status -eq 'pending' } | ForEach-Object {
        [pscustomobject]@{ rank=$rank[[string]$_.priority]; task=$_ }
    } | Sort-Object rank, @{Expression={$_.task.created};Descending=$false})
    if ($pending.Count -eq 0) { Write-Host 'Queue is empty.'; return $null }
    $next = $pending[0].task
    $payload = [ordered]@{ generated=(Get-Date -Format o); next=$next; safety='Preparation only; execution still follows routing and protected-domain gates.' }
    Write-AdosJson (Join-Path $Root '.ai\queue\next.generated.json') $payload 8
    Write-Host "Next queued task: $($next.id) - $($next.task)"
    return $next
}

function Complete-AdosQueueTask {
    param([string]$Root, [string]$Id, [string]$NewStatus)

    if (-not $Id) { throw 'QueueId is required for queue-complete.' }
    $lockPath = Enter-AdosQueueLock $Root
    try {
        $queue = Read-AdosQueue $Root
        $tasks = @()
        $found = $false
        foreach ($item in @($queue.tasks)) {
            if ([string]$item.id -eq $Id) {
                if ([string]$item.status -eq 'claimed') {
                    throw "Queue task is leased by the autonomous dispatcher; use dispatch complete with the exact lease ID: $Id"
                }
                $completionEvidence = $null
                if ($NewStatus -eq 'completed') {
                    $completionEvidence = Get-AdosQueueCompletionEvidence $Root ([string]$item.task) ([string]$item.created)
                }
                $found = $true
                $tasks += [pscustomobject]@{
                    id=$item.id; created=$item.created; updated=(Get-Date -Format o); task=$item.task;
                    priority=$item.priority; status=$NewStatus; attempts=([int]$item.attempts + 1); note=$item.note;
                    completionEvidence=$completionEvidence
                }
            }
            else { $tasks += $item }
        }
        if (-not $found) { throw "Queue task not found: $Id" }
        Write-AdosQueue $Root $tasks
    }
    finally { Exit-AdosQueueLock $lockPath }
    Write-Host "Queue task $Id -> $NewStatus"
}

function Write-AdosUsageSummary {
    param([string]$Root)

    $data = Read-AdosJson (Join-Path $Root '.ai\analytics\usage-events.json') $null
    $events = @()
    if ($data -and $data.events) { $events = @($data.events) }
    $groups = @($events | Group-Object stage | Sort-Object Name)
    $payloadGroups = @()
    foreach ($group in $groups) {
        $duration = [long](($group.Group | Measure-Object durationMs -Sum).Sum)
        $input = [long](($group.Group | Measure-Object inputBytes -Sum).Sum)
        $selected = [long](($group.Group | Measure-Object selectedBytes -Sum).Sum)
        $payloadGroups += [pscustomobject]@{ stage=$group.Name; runs=$group.Count; durationMs=$duration; inputBytes=$input; selectedBytes=$selected }
    }
    $payload = [ordered]@{ schemaVersion=1; generated=(Get-Date -Format o); eventCount=$events.Count; stages=@($payloadGroups) }
    Write-AdosJson (Join-Path $Root '.ai\analytics\usage-summary.generated.json') $payload 8
    $lines = @('# ADOS usage analytics','',"Events: $($events.Count)",'','| Stage | Runs | Duration ms | Input bytes | Selected bytes |','|---|---:|---:|---:|---:|')
    foreach ($group in $payloadGroups) { $lines += "| $($group.stage) | $($group.runs) | $($group.durationMs) | $($group.inputBytes) | $($group.selectedBytes) |" }
    if ($payloadGroups.Count -eq 0) { $lines += '| none | 0 | 0 | 0 | 0 |' }
    $lines += @('','Analytics are local estimates. They do not claim exact Codex billing or token usage.')
    Write-AdosUtf8 (Join-Path $Root '.ai\analytics\usage-summary.generated.md') ($lines -join "`r`n")
    Write-Host "Usage summary written ($($events.Count) events)"
    return $payload
}

function Get-AdosTermHitCount {
    param([string]$Text, [string[]]$Terms)
    $count = 0
    $lower = $Text.ToLowerInvariant()
    foreach ($term in $Terms) { if ($lower.Contains($term)) { $count++ } }
    return $count
}

function Invoke-AdosBenchmark {
    param([string]$Root, [string]$TaskText, [string]$Tier, [int]$Limit)

    if (-not $TaskText) { throw 'Task is required for benchmark.' }
    & $Index all -ProjectPath $Root -Task $TaskText -ContextTier $Tier -MaxFiles $Limit
    $first = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null
    & $Index index -ProjectPath $Root -MaxFiles $Limit
    $second = Read-AdosJson (Join-Path $Root '.ai\index\hash-index.generated.json') $null
    $elastic = Read-AdosJson (Join-Path $Root '.ai\context\elastic-context.generated.json') $null
    $terms = @(Get-AdosTaskTerms $TaskText)

    $baselineBudget = 160000
    $baselineFiles = @()
    $baselineBytes = 0
    $baselineHits = 0
    foreach ($entry in @($first.files | Sort-Object path)) {
        $full = Join-Path $Root ([string]$entry.path)
        $text = [string]$entry.path
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try { $text += ' ' + (Get-Content -LiteralPath $full -Raw -Encoding UTF8) } catch { }
        }
        $hits = Get-AdosTermHitCount $text $terms
        $isBase = @('AGENTS.md','README.md') -contains [string]$entry.path
        if (($hits -gt 0 -or $isBase) -and ($baselineBytes + [long]$entry.bytes) -le $baselineBudget) {
            $baselineFiles += [string]$entry.path
            $baselineBytes += [long]$entry.bytes
            $baselineHits += $hits
        }
    }

    $elasticHits = 0
    $elasticSourceBytes = 0
    $elasticSourceFiles = 0
    foreach ($selected in @($elastic.selectedFiles)) {
        $entry = @($first.files | Where-Object { [string]$_.path -eq [string]$selected.path } | Select-Object -First 1)
        $text = [string]$selected.path
        if ($entry.Count -gt 0) {
            $elasticSourceBytes += [long]$entry[0].bytes
            $elasticSourceFiles++
            $selectedFullPath = Join-Path $Root ([string]$entry[0].path)
            if (Test-Path -LiteralPath $selectedFullPath -PathType Leaf) {
                try { $text += ' ' + (Get-Content -LiteralPath $selectedFullPath -Raw -Encoding UTF8) } catch { }
            }
            $text += ' ' + ((@($entry[0].symbols) | ForEach-Object { $_.name }) -join ' ')
            $text += ' ' + ((@($entry[0].imports)) -join ' ')
        }
        $elasticHits += Get-AdosTermHitCount $text $terms
    }
    $baselineDensity = if ($baselineBytes -gt 0) { [math]::Round(($baselineHits * 10000.0) / $baselineBytes, 3) } else { 0 }
    $elasticDensity = if ($elasticSourceBytes -gt 0) { [math]::Round(($elasticHits * 10000.0) / $elasticSourceBytes, 3) } else { 0 }
    $reduction = if ($baselineBytes -gt 0) { [math]::Round((1 - ($elasticSourceBytes / [double]$baselineBytes)) * 100, 2) } else { 0 }
    $payload = [ordered]@{
        schemaVersion=2; generated=(Get-Date -Format o); task=$TaskText; branch=(Get-AdosBranch $Root); head=(Get-AdosHead $Root);
        A=[ordered]@{ name='fixed lexical context'; budgetBytes=$baselineBudget; selectedBytes=$baselineBytes; files=$baselineFiles.Count; relevantTermHits=$baselineHits; relevanceDensity=$baselineDensity };
        B=[ordered]@{ name='elastic symbol-aware context'; tier=$elastic.tier; budgetBytes=$elastic.budgetBytes; selectedBytes=$elasticSourceBytes; files=$elasticSourceFiles; relevantTermHits=$elasticHits; relevanceDensity=$elasticDensity };
        contextByteReductionPercent=$reduction;
        incremental=[ordered]@{ firstUpdated=$first.stats.updated; firstReused=$first.stats.reused; secondUpdated=$second.stats.updated; secondReused=$second.stats.reused };
        note='Deterministic proxy benchmark; no model API was called.'
    }
    Write-AdosJson (Join-Path $Root '.ai\analytics\ab-benchmark.generated.json') $payload 10
    $lines = @(
        '# ADOS A/B benchmark','',"Task: $TaskText",'',
        '| Metric | A: fixed lexical | B: elastic symbol-aware |','|---|---:|---:|',
        "| Budget bytes | $($payload.A.budgetBytes) | $($payload.B.budgetBytes) |",
        "| Selected bytes | $($payload.A.selectedBytes) | $($payload.B.selectedBytes) |",
        "| Files | $($payload.A.files) | $($payload.B.files) |",
        "| Relevant term hits | $($payload.A.relevantTermHits) | $($payload.B.relevantTermHits) |",
        "| Relevance density | $($payload.A.relevanceDensity) | $($payload.B.relevanceDensity) |",'',
        "Context byte reduction from A to B: $reduction%",'',
        "Second index pass: $($payload.incremental.secondReused) reused, $($payload.incremental.secondUpdated) updated.",'',
        'This is a deterministic proxy benchmark. It does not claim exact token billing or model-quality gains.'
    )
    Write-AdosUtf8 (Join-Path $Root '.ai\analytics\ab-benchmark.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'ab-benchmark' 'PASS' 0 $baselineBytes $elasticSourceBytes @{ reductionPercent=$reduction; secondReused=$second.stats.reused }
    Write-Host "A/B benchmark written (context reduction $reduction%)"
    return $payload
}

function Invoke-AdosNightMode {
    param([string]$Root, [int]$Limit, [int]$HistoryLimit)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = Get-AdosProjectAdapter $Root
    & $Index all -ProjectPath $Root -MaxFiles $Limit
    & $MemoryV3 decisions -ProjectPath $Root -Task ''
    & $NightAudit -ProjectPath $Root
    & $Health -ProjectPath $Root -MaxHistory $HistoryLimit
    $healthResult = Read-AdosJson (Join-Path $Root '.ai\analytics\health.generated.json') $null
    $healthStatus = if ($healthResult) { [string]$healthResult.status } else { 'MISSING' }
    $queue = Read-AdosQueue $Root
    $pending = @($queue.tasks | Where-Object { $_.status -eq 'pending' })
    $timer.Stop()
    Add-AdosUsageEvent $Root 'night-mode' 'PASS' $timer.ElapsedMilliseconds 0 0 @{ pendingQueue=$pending.Count; health=$healthStatus; modelCalls=0; productCodeChanges=0 }
    $null = Write-AdosUsageSummary $Root
    $lines = @(
        '# ADOS night mode summary','',"Generated: $(Get-Date -Format o)","Duration ms: $($timer.ElapsedMilliseconds)",
        "Pending queue tasks: $($pending.Count)","Project health: $healthStatus",'','## Safety',
        '- No paid API or model was called.','- No product-code file was edited.','- Queue tasks were reported but not executed.',
        '- Findings remain advisory until deterministic checks and Codex review are complete.'
    )
    Write-AdosUtf8 (Join-Path $Root '.ai\analytics\night-mode.generated.md') ($lines -join "`r`n")
    Write-Host "Night mode completed ($($pending.Count) queued tasks, no model calls)"
}

function Invoke-AdosHealthMode {
    param([string]$Root, [int]$Limit, [int]$HistoryLimit)

    $null = Get-AdosProjectAdapter $Root
    & $Index all -ProjectPath $Root -MaxFiles $Limit
    & $NightAudit -ProjectPath $Root
    & $Health -ProjectPath $Root -MaxHistory $HistoryLimit
    $null = Write-AdosUsageSummary $Root
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
switch ($Command) {
    'adapter' { $null = Get-AdosProjectAdapter $root }
    'checkpoint' { $null = Save-AdosCheckpoint $root $Task $Phase }
    'resume' { $null = Resume-AdosCheckpoint $root }
    'queue-add' { $null = Add-AdosQueueTask $root $Task $Priority }
    'queue-next' { $null = Get-AdosNextQueueTask $root }
    'queue-complete' { Complete-AdosQueueTask $root $QueueId $QueueStatus }
    'night' { Invoke-AdosNightMode $root $MaxFiles $HealthHistoryLimit }
    'health' { Invoke-AdosHealthMode $root $MaxFiles $HealthHistoryLimit }
    'usage' { $null = Write-AdosUsageSummary $root }
    'benchmark' { $null = Invoke-AdosBenchmark $root $Task $ContextTier $MaxFiles }
}
