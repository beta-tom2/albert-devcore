[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','status','start','checkpoint','analyze','night','scheduler','dispatch','health','handoff','resume','verify','pr-summary','queue','benchmark','stats','failure','remember-regression','remember-negative','state-export','state-read','state-validate','state-publish')]
    [string]$Command,

    [string]$ProjectPath = '.',
    [string]$Task = '',
    [int]$ContextBudgetBytes = 160000,
    [int]$MaxCommits = 300,
    [int]$MaxFiles = 2000,
    [ValidateSet('auto','small','medium','large','protected')]
    [string]$ContextTier = 'auto',
    [ValidateRange(1,5)]
    [int]$MaxVerificationLevel = 3,
    [string[]]$AllowedScope = @(),
    [ValidateSet('add','next','complete')]
    [string]$QueueAction = 'next',
    [string]$QueueId = '',
    [ValidateSet('low','normal','high','protected')]
    [string]$Priority = 'normal',
    [ValidateSet('pending','completed','failed','cancelled','blocked')]
    [string]$QueueStatus = 'completed',
    [bool]$RequireDiff = $true,
    [string]$LogPath = '',
    [string]$ErrorText = '',
    [string]$Fingerprint = '',
    [string]$RegressionCommand = '',
    [string[]]$Files = @(),
    [string]$Attempt = '',
    [string]$Outcome = '',
    [bool]$EvidenceChanged = $false,
    [ValidateSet('preview','install','status','uninstall')]
    [string]$SchedulerAction = 'preview',
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$DailyAt = '03:00',
    [string]$SchedulerTaskName = '',
    [switch]$ConfirmSchedulerInstall,
    [switch]$ReplaceScheduledTask,
    [switch]$ConfirmSchedulerUninstall,
    [ValidateSet('run','status','complete','release','renew')]
    [string]$DispatchAction = 'run',
    [string]$DispatchLeaseId = '',
    [ValidateSet('completed','failed','blocked')]
    [string]$DispatchResult = 'completed',
    [string]$DispatchNote = '',
    [ValidateRange(10,720)]
    [int]$DispatchLeaseMinutes = 120,
    [ValidateRange(1,10)]
    [int]$DispatchMaxAttempts = 3,
    [bool]$DispatchPrepareContext = $true,
    [bool]$DispatchUseOllama = $true,
    [ValidateRange(2,365)]
    [int]$HealthHistoryLimit = 90,
    [string]$StateConfigPath = '.ados/state-export.json',
    [string]$StatePublishConfigPath = '.ados/state-publish.json',
    [string]$ExpectedRemoteCommit = '',
    [switch]$ConfirmPublish,
    [string]$SnapshotPath = '',
    [string]$ExpectedSnapshotSha256 = '',
    [string]$SkillsRoot = '',
    [string]$ExpectedRuntimeCommit = '',
    [switch]$IncludeSchedules,
    [switch]$Json,
    [ValidateSet('preparation','implementation','decision','verified','blocked','handoff')]
    [string]$CheckpointPhase = 'implementation'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$DevCore = Join-Path $Root 'devcore.ps1'
$Memory = Join-Path $Root 'scripts\devcore-memory.ps1'
$Insights = Join-Path $Root 'scripts\ados-insights.ps1'
$Night = Join-Path $Root 'scripts\ados-night-audit.ps1'
$Index = Join-Path $Root 'scripts\ados-index.ps1'
$Quality = Join-Path $Root 'scripts\ados-quality.ps1'
$MemoryV3 = Join-Path $Root 'scripts\ados-memory-v3.ps1'
$Operations = Join-Path $Root 'scripts\ados-operations.ps1'
$Health = Join-Path $Root 'scripts\ados-health.ps1'
$Scheduler = Join-Path $Root 'scripts\ados-scheduler.ps1'
$Dispatcher = Join-Path $Root 'scripts\ados-dispatch.ps1'
$ProjectState = Join-Path $Root 'scripts\ados-state.ps1'
$StatePublisher = Join-Path $Root 'scripts\ados-state-publish.ps1'
$RuntimeStatus = Join-Path $Root 'scripts\ados-status.ps1'
$SharedKnowledge = Join-Path $Root 'scripts\ados-shared-knowledge.ps1'

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Required ADOS component is missing: $Path" }
}

function Resolve-RepoRoot {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $repo = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $repo) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($repo).TrimEnd('\','/')
    }
    finally { Pop-Location }
}

function Ensure-LocalExclude {
    param([string]$Repo)
    Push-Location $Repo
    try { $exclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
    finally { Pop-Location }
    if (-not $exclude) { throw "Unable to resolve Git exclude path for $Repo" }
    if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $Repo $exclude }
    $exclude = [IO.Path]::GetFullPath($exclude)
    $rules = @(
        '.ai/memory/',
        '.ai/analytics/',
        '.ai/context/session-context.md',
        '.ai/context/repo-map.generated.md',
        '.ai/context/import-map.generated.md',
        '.ai/context/test-plan.generated.md',
        '.ai/context/prompt-packet.generated.md',
        '.ai/context/shared-knowledge.generated.md',
        '.ai/context/similar-repairs.generated.md',
        '.ai/context/handoff.generated.md',
        '.ai/context/fix-dna.generated.json',
        '.ai/context/fix-dna.generated.md',
        '.ai/context/elastic-context.generated.json',
        '.ai/context/elastic-context.generated.md',
        '.ai/context/project-adapter.generated.json',
        '.ai/context/project-adapter.generated.md',
        '.ai/context/decision-context.generated.json',
        '.ai/context/decision-context.generated.md',
        '.ai/context/regression-context.generated.json',
        '.ai/context/regression-context.generated.md',
        '.ai/context/negative-memory.generated.json',
        '.ai/context/negative-memory.generated.md',
        '.ai/context/error-fingerprint.generated.md',
        '.ai/context/compressed-log.generated.json',
        '.ai/context/compressed-log.generated.md',
        '.ai/context/resume.generated.json',
        '.ai/context/resume.generated.md',
        '.ai/index/',
        '.ai/evidence/',
        '.ai/checkpoints/',
        '.ai/queue/',
        '.ai/test-work/',
        '.ai/local-output/'
    )
    $existing = if (Test-Path -LiteralPath $exclude) { @(Get-Content -LiteralPath $exclude) } else { @() }
    foreach ($rule in $rules) {
        if ($existing -notcontains $rule) { Add-Content -LiteralPath $exclude -Value $rule -Encoding UTF8 }
    }
}

function Invoke-Doctor {
    Require-File $DevCore
    Require-File $Memory
    Require-File $Insights
    Require-File $Night
    Require-File $Index
    Require-File $Quality
    Require-File $MemoryV3
    Require-File $Operations
    Require-File $Health
    Require-File $Scheduler
    Require-File $Dispatcher
    Require-File $ProjectState
    Require-File $StatePublisher
    Require-File $RuntimeStatus
    Require-File $SharedKnowledge
    & $DevCore doctor
    Write-Host ''
    Write-Host 'ADOS components:'
    Write-Host ('{0,-28} PASS' -f 'devcore')
    Write-Host ('{0,-28} PASS' -f 'repair memory')
    Write-Host ('{0,-28} PASS' -f 'heat map / graph / fix dna')
    Write-Host ('{0,-28} PASS' -f 'night audit')
    Write-Host ('{0,-28} PASS' -f 'incremental / symbol index')
    Write-Host ('{0,-28} PASS' -f 'quality and evidence gates')
    Write-Host ('{0,-28} PASS' -f 'v3 memory and operations')
    Write-Host ('{0,-28} PASS' -f 'project health and trends')
    Write-Host ('{0,-28} PASS' -f 'safe Night Mode scheduler')
    Write-Host ('{0,-28} PASS' -f 'autonomous dispatcher')
    Write-Host ('{0,-28} PASS' -f 'portable project state')
    Write-Host ('{0,-28} PASS' -f 'project state publication')
    Write-Host ('{0,-28} PASS' -f 'runtime and skills status')
    Write-Host ('{0,-28} PASS' -f 'reviewed cross-project knowledge')
}

function Get-ElasticBudget {
    param([string]$Repo,[int]$Fallback)
    $path = Join-Path $Repo '.ai\context\elastic-context.generated.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $Fallback }
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([int]$data.budgetBytes -gt 0) { return [int]$data.budgetBytes }
    }
    catch { }
    return $Fallback
}

function Invoke-SharedKnowledge {
    param([string]$Repo,[string]$TaskText)
    if (-not $TaskText) { return }
    Require-File $SharedKnowledge
    & $SharedKnowledge search -ProjectPath $Repo -Task $TaskText -Limit 3
}

function Add-SharedKnowledgeToPacket {
    param([string]$Repo)
    $knowledge = Join-Path $Repo '.ai\context\shared-knowledge.generated.md'
    $packet = Join-Path $Repo '.ai\context\prompt-packet.generated.md'
    if (-not (Test-Path -LiteralPath $knowledge -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packet -PathType Leaf)) { return }
    $content = [IO.File]::ReadAllText($knowledge, [Text.Encoding]::UTF8)
    if ($content.Length -gt 3200) {
        $content = $content.Substring(0,3200) + [Environment]::NewLine + '(truncated to keep context bounded)'
    }
    $addition = [Environment]::NewLine + [Environment]::NewLine +
        '## Reviewed cross-project knowledge (advisory)' + [Environment]::NewLine + $content
    [IO.File]::AppendAllText($packet,$addition,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-Analyze {
    param([string]$Repo,[string]$TaskText)
    Ensure-LocalExclude $Repo
    & $Operations adapter -ProjectPath $Repo
    & $DevCore update -ProjectPath $Repo
    & $Memory index -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Index all -ProjectPath $Repo -Task $TaskText -ContextTier $ContextTier -MaxFiles $MaxFiles
    & $Insights all -ProjectPath $Repo -Task $TaskText -MaxCommits $MaxCommits -MaxFiles $MaxFiles
    if ($TaskText) {
        & $Memory search -ProjectPath $Repo -Query $TaskText -MaxCommits $MaxCommits
        & $MemoryV3 all -ProjectPath $Repo -Task $TaskText
        Invoke-SharedKnowledge $Repo $TaskText
        $elasticBudget = Get-ElasticBudget $Repo $ContextBudgetBytes
        & $DevCore packet -ProjectPath $Repo -Task $TaskText -ContextBudgetBytes $elasticBudget
    Add-SharedKnowledgeToPacket $Repo
    }
    Write-Host "ADOS analysis completed for $Repo"
}

function Invoke-Start {
    param([string]$Repo,[string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for start.' }
    Ensure-LocalExclude $Repo
    $route = (& $DevCore route -Task $TaskText | Out-String).Trim()
    Write-Host "Route: $route"
    & $Operations checkpoint -ProjectPath $Repo -Task $TaskText -Phase 'preparation'
    & $Operations adapter -ProjectPath $Repo
    & $DevCore update -ProjectPath $Repo
    & $Memory index -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Memory search -ProjectPath $Repo -Query $TaskText -MaxCommits $MaxCommits
    & $Insights heatmap -ProjectPath $Repo -MaxCommits $MaxCommits
    & $Insights graph -ProjectPath $Repo -MaxFiles $MaxFiles
    & $Index all -ProjectPath $Repo -Task $TaskText -ContextTier $ContextTier -MaxFiles $MaxFiles
    & $MemoryV3 all -ProjectPath $Repo -Task $TaskText
    Invoke-SharedKnowledge $Repo $TaskText
    & $Insights fixdna -ProjectPath $Repo -Task $TaskText
    $elasticBudget = Get-ElasticBudget $Repo $ContextBudgetBytes
    & $DevCore packet -ProjectPath $Repo -Task $TaskText -ContextBudgetBytes $elasticBudget
    Add-SharedKnowledgeToPacket $Repo
    & $Memory handoff -ProjectPath $Repo

    $packet = Join-Path $Repo '.ai\context\prompt-packet.generated.md'
    $dna = Join-Path $Repo '.ai\context\fix-dna.generated.md'
    $similar = Join-Path $Repo '.ai\context\similar-repairs.generated.md'
    $handoff = Join-Path $Repo '.ai\context\handoff.generated.md'

    Write-Host ''
    Write-Host 'ADOS task workspace is ready:'
    Write-Host "  Route: $route"
    Write-Host "  Prompt packet: $packet"
    Write-Host "  Fix DNA: $dna"
    Write-Host "  Similar repairs: $similar"
    Write-Host "  Reviewed shared knowledge: $(Join-Path $Repo '.ai\context\shared-knowledge.generated.md')"
    Write-Host "  Handoff: $handoff"
    Write-Host "  Elastic context: $(Join-Path $Repo '.ai\context\elastic-context.generated.md')"
    Write-Host "  Checkpoint: $(Join-Path $Repo '.ai\checkpoints\current.json')"
    Write-Host ''
    if ($route -eq 'LOCAL_FIRST_THEN_CODEX_VERIFY') {
        Write-Host 'Recommended execution: bounded Ollama first pass, then Codex verification.'
    }
    elseif ($route -eq 'CODEX_REQUIRED') {
        Write-Host 'Recommended execution: Codex only for decisions and code changes; use deterministic checks first.'
    }
    else {
        Write-Host 'Recommended execution: deterministic tools plus Codex, with local read-only review after the diff exists.'
    }
}

$repo = if ($Command -in @('doctor','status','state-read','state-validate')) { $null } else { Resolve-RepoRoot $ProjectPath }

switch ($Command) {
    'doctor' { Invoke-Doctor }
    'status' { & $RuntimeStatus -ProjectPath $ProjectPath -SkillsRoot $SkillsRoot -ExpectedRuntimeCommit $ExpectedRuntimeCommit -IncludeSchedules:$IncludeSchedules -Json:$Json }
    'state-export' { & $ProjectState export -ProjectPath $repo -ConfigPath $StateConfigPath -SnapshotPath $SnapshotPath -ExpectedSnapshotSha256 $ExpectedSnapshotSha256 }
    'state-read' { & $ProjectState read -SnapshotPath $SnapshotPath }
    'state-validate' { & $ProjectState validate -SnapshotPath $SnapshotPath }
    'state-publish' {
        $publication = @{ ProjectPath = $repo; ConfigPath = $StatePublishConfigPath; ExpectedRemoteCommit = $ExpectedRemoteCommit; ConfirmPublish = $ConfirmPublish }
        if ($SnapshotPath) { $publication['SnapshotPath'] = $SnapshotPath }
        & $StatePublisher @publication
    }
    'start' { Invoke-Start $repo $Task }
    'checkpoint' {
        if (-not $Task) { throw 'Task is required for checkpoint.' }
        Ensure-LocalExclude $repo
        & $Operations checkpoint -ProjectPath $repo -Task $Task -Phase $CheckpointPhase
    }
    'analyze' { Invoke-Analyze $repo $Task }
    'night' {
        Ensure-LocalExclude $repo
        & $Insights heatmap -ProjectPath $repo -MaxCommits $MaxCommits
        & $Insights graph -ProjectPath $repo -MaxFiles $MaxFiles
        & $Operations night -ProjectPath $repo -MaxFiles $MaxFiles -HealthHistoryLimit $HealthHistoryLimit
    }
    'scheduler' {
        Ensure-LocalExclude $repo
        & $Scheduler $SchedulerAction -ProjectPath $repo -DailyAt $DailyAt -MaxFiles $MaxFiles -HealthHistoryLimit $HealthHistoryLimit -TaskName $SchedulerTaskName -ConfirmInstall:$ConfirmSchedulerInstall -ReplaceExisting:$ReplaceScheduledTask -ConfirmUninstall:$ConfirmSchedulerUninstall
    }
    'dispatch' {
        Ensure-LocalExclude $repo
        & $Dispatcher $DispatchAction -ProjectPath $repo -QueueId $QueueId -LeaseId $DispatchLeaseId -ResultStatus $DispatchResult -ResultNote $DispatchNote -LeaseMinutes $DispatchLeaseMinutes -MaxAttempts $DispatchMaxAttempts -MaxFiles $MaxFiles -PrepareContext:$DispatchPrepareContext -UseOllama:$DispatchUseOllama
    }
    'health' {
        Ensure-LocalExclude $repo
        & $Operations health -ProjectPath $repo -MaxFiles $MaxFiles -HealthHistoryLimit $HealthHistoryLimit
    }
    'handoff' {
        Ensure-LocalExclude $repo
        & $Memory handoff -ProjectPath $repo
    }
    'resume' {
        Ensure-LocalExclude $repo
        & $Operations resume -ProjectPath $repo
    }
    'verify' {
        Ensure-LocalExclude $repo
        & $Index all -ProjectPath $repo -MaxFiles $MaxFiles
        & $Quality all -ProjectPath $repo -Task $Task -AllowedScope $AllowedScope -MaxLevel $MaxVerificationLevel -RequireDiff $RequireDiff
    }
    'pr-summary' {
        Ensure-LocalExclude $repo
        & $Quality pr-summary -ProjectPath $repo -Task $Task
    }
    'queue' {
        Ensure-LocalExclude $repo
        if ($QueueAction -eq 'add') { & $Operations queue-add -ProjectPath $repo -Task $Task -Priority $Priority }
        elseif ($QueueAction -eq 'complete') { & $Operations queue-complete -ProjectPath $repo -QueueId $QueueId -QueueStatus $QueueStatus }
        else { & $Operations queue-next -ProjectPath $repo }
    }
    'benchmark' {
        Ensure-LocalExclude $repo
        & $Operations benchmark -ProjectPath $repo -Task $Task -ContextTier $ContextTier -MaxFiles $MaxFiles
    }
    'stats' {
        Ensure-LocalExclude $repo
        & $Operations usage -ProjectPath $repo
    }
    'failure' {
        Ensure-LocalExclude $repo
        if ($LogPath) { & $Quality compress -ProjectPath $repo -LogPath $LogPath }
        & $Quality fingerprint -ProjectPath $repo -Task $Task -LogPath $LogPath -ErrorText $ErrorText
    }
    'remember-regression' {
        Ensure-LocalExclude $repo
        & $MemoryV3 regression-add -ProjectPath $repo -Task $Task -Fingerprint $Fingerprint -RegressionCommand $RegressionCommand -Files $Files
    }
    'remember-negative' {
        Ensure-LocalExclude $repo
        & $MemoryV3 negative-add -ProjectPath $repo -Task $Task -Attempt $Attempt -Outcome $Outcome -Files $Files -EvidenceChanged $EvidenceChanged
    }
}
