[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Fixture = Join-Path $RepoRoot 'tests\.work\ados-v4-smoke'
$FixtureParent = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests\.work'))
$ResolvedFixture = [IO.Path]::GetFullPath($Fixture)
if (-not $ResolvedFixture.StartsWith($FixtureParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to prepare a fixture outside tests\.work.'
}
Push-Location $RepoRoot
try { $outerExclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
finally { Pop-Location }
if (-not [IO.Path]::IsPathRooted($outerExclude)) { $outerExclude = Join-Path $RepoRoot $outerExclude }
$outerExclude = [IO.Path]::GetFullPath($outerExclude)
$outerRule = 'tests/.work/'
$outerExisting = if (Test-Path -LiteralPath $outerExclude) { @(Get-Content -LiteralPath $outerExclude) } else { @() }
if ($outerExisting -notcontains $outerRule) { Add-Content -LiteralPath $outerExclude -Value $outerRule -Encoding UTF8 }
if (Test-Path -LiteralPath $ResolvedFixture) { Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'src') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'tests') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ResolvedFixture 'docs\adr') -Force | Out-Null

$encoding = New-Object System.Text.UTF8Encoding($false)
function Write-FixtureFile([string]$Relative, [string]$Content) {
    $path = Join-Path $ResolvedFixture $Relative
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Content, $encoding)
}
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Json([string]$Relative) {
    return (Get-Content -LiteralPath (Join-Path $ResolvedFixture $Relative) -Raw | ConvertFrom-Json)
}

Write-FixtureFile 'README.md' ("# ADOS smoke fixture`r`n" + ('large optional documentation ' * 5000))
Write-FixtureFile 'src\friends.ts' "// friend request`r`nexport function sendFriendRequest(userId: string): string { return userId; }`r`n"
Write-FixtureFile 'src\friends-copy.ts' "// friend request`r`nexport function sendFriendRequest(userId: string): string { return userId; }`r`n"
Write-FixtureFile 'tests\friends.test.ts' "import { sendFriendRequest } from '../src/friends';`r`n"
Write-FixtureFile 'packages\social\package.json' '{"name":"social","type":"module","scripts":{"test":"node --test"}}'
Write-FixtureFile 'packages\social\src\friends.js' "export function normalizeFriend(value) { return value.trim(); }`r`n"
Write-FixtureFile 'packages\social\tests\friends.test.js' "import test from 'node:test';`r`nimport assert from 'node:assert/strict';`r`nimport { normalizeFriend } from '../src/friends.js';`r`ntest('normalizes a friend', () => assert.equal(normalizeFriend(' Ada '), 'Ada'));`r`n"
Write-FixtureFile 'packages\social\tsconfig.json' '{"compilerOptions":{"allowJs":true,"checkJs":false,"module":"NodeNext","moduleResolution":"NodeNext"},"include":["src/**/*.js","tests/**/*.js"]}'
Write-FixtureFile 'packages\admin\package.json' '{"name":"admin","type":"module"}'
Write-FixtureFile 'packages\admin\tests\friends.test.js' "// normalizeFriend belongs to another workspace and must not create a cross-package association.`r`n"
Write-FixtureFile 'docs\adr\ADR-0001-friend-service.md' "# ADR-0001 Friend service boundary`r`n`r`nStatus: accepted`r`n`r`nFriend requests remain in the friend service.`r`n"
Write-FixtureFile 'docs\project-brain\README.md' "# Project Brain`r`n"
Write-FixtureFile 'docs\project-brain\CURRENT_FOCUS.md' "# Current focus`r`nFriend request safety.`r`n"
Write-FixtureFile 'docs\project-brain\AGENT_ENTRYPOINTS.md' "# Agent entrypoints`r`nStart with friends service.`r`n"
Write-FixtureFile '.ados\adapter.json' '{"name":"smoke-custom","protectedBoundaries":["custom boundary"],"contextEntrypoints":["docs/project-brain/README.md","docs/project-brain/CURRENT_FOCUS.md","docs/project-brain/AGENT_ENTRYPOINTS.md"]}'
Write-FixtureFile '.ados\health.json' '{"schemaVersion":1,"historyLimit":5,"baselineWindow":3,"thresholds":{"maxConflictMarkers":0,"maxLargeSourceFiles":0,"maxTodoMarkers":0,"maxChangedFiles":10}}'

Push-Location $ResolvedFixture
try {
    & git init -q
    & git config user.name 'ADOS Smoke Test'
    & git config user.email 'ados-smoke@example.invalid'
    & git add .
    & git commit -q -m 'test: seed fixture'
}
finally { Pop-Location }

$Index = Join-Path $RepoRoot 'scripts\ados-index.ps1'
$Quality = Join-Path $RepoRoot 'scripts\ados-quality.ps1'
$Memory = Join-Path $RepoRoot 'scripts\ados-memory-v3.ps1'
$Operations = Join-Path $RepoRoot 'scripts\ados-operations.ps1'
$Ados = Join-Path $RepoRoot 'ados.ps1'
$Scheduler = Join-Path $RepoRoot 'scripts\ados-scheduler.ps1'
$Dispatcher = Join-Path $RepoRoot 'scripts\ados-dispatch.ps1'

& $Index all -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -MaxFiles 100
$first = Read-Json '.ai\index\hash-index.generated.json'
Assert-True ($first.stats.updated -ge 4) 'first index pass must analyze fixture files'
Assert-True ((Read-Json '.ai\index\symbol-index.generated.json').symbolCount -ge 1) 'symbol index must find sendFriendRequest'
$testMap = Read-Json '.ai\index\test-symbol-map.generated.json'
$compilerReferences = Read-Json '.ai\index\compiler-references.generated.json'
Assert-True (@('PASS','PARTIAL','SKIP') -contains $compilerReferences.status) 'compiler resolver must remain optional and bounded'
Assert-True ($compilerReferences.status -eq 'SKIP') 'fixture without project-local TypeScript must use the lexical fallback'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'src\friends.ts' -and $_.testFile -eq 'tests\friends.test.ts' }).Count -eq 1) 'test map must connect a relative import to its source'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'packages\social\src\friends.js' -and $_.testFile -eq 'packages\social\tests\friends.test.js' }).Count -eq 1) 'test map must preserve monorepo package associations'
Assert-True (@($testMap.associations | Where-Object { $_.sourceFile -eq 'packages\social\src\friends.js' -and $_.testFile -eq 'packages\admin\tests\friends.test.js' }).Count -eq 0) 'test map must reject ambiguous cross-package symbol matches'
Assert-True ((Read-Json '.ai\context\elastic-context.generated.json').selectedFiles.Count -ge 1) 'elastic context must select files'
$initialElastic = Read-Json '.ai\context\elastic-context.generated.json'
Assert-True (@($initialElastic.associatedTestFiles) -contains 'tests\friends.test.ts') 'elastic context must select the focused test associated with a relevant source'
Assert-True (@($initialElastic.selectedFiles.path) -contains 'docs\project-brain\README.md') 'elastic context must prioritize repository entrypoints'
Assert-True (@($initialElastic.selectedFiles.path) -notcontains 'README.md') 'oversized optional README must not consume elastic context budget'
Assert-True (@($initialElastic.skippedBaseFiles.path) -contains 'README.md') 'elastic context must report the skipped oversized README'
$selectedFriendCopies = @($initialElastic.selectedFiles.path | Where-Object { $_ -match '^src\\friends(?:-copy)?\.ts$' })
$skippedFriendCopies = @($initialElastic.skippedDuplicateFiles.path | Where-Object { $_ -match '^src\\friends(?:-copy)?\.ts$' })
Assert-True ($selectedFriendCopies.Count -eq 1) 'elastic context must select only one copy of identical source content'
Assert-True ($skippedFriendCopies.Count -eq 1) 'elastic context must report the skipped duplicate source file'
Assert-True ([long]$initialElastic.duplicateBytesAvoided -gt 0) 'elastic context must report duplicate bytes avoided'

$compilerFixture = Join-Path $ResolvedFixture 'node_modules\typescript'
New-Item -ItemType Directory -Path $compilerFixture -Force | Out-Null
Write-FixtureFile 'node_modules\typescript\package.json' '{"name":"typescript","version":"0.0.0-ados-fixture","main":"index.js"}'
$compilerStub = @'
const path = require('path');
const root = process.argv[process.argv.indexOf('--root') + 1];
const source = path.join(root, 'packages', 'social', 'src', 'friends.js');
const test = path.join(root, 'packages', 'social', 'tests', 'friends.test.js');
const sourceFile = { fileName: source, getLineAndCharacterOfPosition: () => ({ line: 0, character: 0 }) };
module.exports = {
  version: '0.0.0-ados-fixture',
  sys: { readFile: () => '{}', fileExists: () => true, readDirectory: () => [], directoryExists: () => true, getDirectories: () => [] },
  readConfigFile: () => ({ config: {} }), parseJsonConfigFileContent: () => ({ fileNames: [source, test], options: {} }),
  ScriptSnapshot: { fromString: value => value }, createDocumentRegistry: () => ({}), getDefaultLibFilePath: () => '',
  isFunctionDeclaration: node => node.kind === 'function', isClassDeclaration: () => false, isInterfaceDeclaration: () => false,
  isTypeAliasDeclaration: () => false, isEnumDeclaration: () => false, isVariableDeclaration: () => false,
  isMethodDeclaration: () => false, isPropertyDeclaration: () => false, isIdentifier: value => Boolean(value && value.text),
  forEachChild: (node, visit) => (node.children || []).forEach(visit),
  createLanguageService: () => ({
    getProgram: () => ({ getSourceFiles: () => [{ fileName: source, children: [{ kind: 'function', name: { text: 'normalizeFriend', getStart: () => 7 }, children: [] }] }], getSourceFile: () => sourceFile }),
    getReferencesAtPosition: () => [{ fileName: test, textSpan: { start: 10 }, isWriteAccess: false }], dispose: () => {}
  })
};
'@
Write-FixtureFile 'node_modules\typescript\index.js' $compilerStub
& $Index all -ProjectPath $ResolvedFixture -Task 'Fix normalizeFriend behavior' -MaxFiles 100
$compilerPass = Read-Json '.ai\index\compiler-references.generated.json'
$compilerMap = Read-Json '.ai\index\test-symbol-map.generated.json'
Assert-True ($compilerPass.status -eq 'PASS') 'project-local compiler resolver must run when TypeScript is available'
Assert-True (@($compilerMap.associations | Where-Object { $_.sourceFile -eq 'packages\social\src\friends.js' -and $_.testFile -eq 'packages\social\tests\friends.test.js' -and $_.confidence -eq 'compiler' }).Count -eq 1) 'compiler evidence must strengthen the package-local test association'
Remove-Item -LiteralPath (Join-Path $ResolvedFixture 'node_modules') -Recurse -Force

& $Index index -ProjectPath $ResolvedFixture -MaxFiles 100
$second = Read-Json '.ai\index\hash-index.generated.json'
Assert-True ($second.stats.updated -eq 0) 'second index pass must not reanalyze unchanged files'
Assert-True ($second.stats.reused -eq $second.stats.scanned) 'second index pass must reuse every scanned file'

Write-FixtureFile 'packages\social\src\friends.js' "// focused verification change`r`nexport function normalizeFriend(value) { return value.trim(); }`r`n"
& $Ados verify -ProjectPath $ResolvedFixture -Task 'Verify social friend normalization' -AllowedScope @('packages\social') -MaxVerificationLevel 3 -RequireDiff $true -MaxFiles 100
$focusedVerification = Read-Json '.ai\evidence\verification.generated.json'
Assert-True ($focusedVerification.focusedTests.mapCurrent) 'verification must use a test map matching the current worktree'
Assert-True ($focusedVerification.focusedTests.executed) 'verification must execute bounded focused tests for a recognized package runner'
Assert-True (@($focusedVerification.checks | Where-Object { $_.name -match '^npm focused tests:' -and $_.status -eq 'PASS' }).Count -eq 1) 'focused package test must pass'
Assert-True ((Read-Json '.ai\evidence\pr-evidence-summary.generated.json').verification.focusedTests.executed) 'PR evidence must preserve focused-test execution'
Push-Location $ResolvedFixture
try { & git restore -- packages\social\src\friends.js }
finally { Pop-Location }

Push-Location $ResolvedFixture
try { $statusBeforeStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Ados start -ProjectPath $ResolvedFixture -Task 'Prepare friend request review' -MaxFiles 100 -MaxCommits 20
Push-Location $ResolvedFixture
try { $statusAfterStart = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeStart -eq $statusAfterStart) 'ADOS start must keep generated context out of product Git status'
$packet = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\prompt-packet.generated.md') -Raw
Assert-True ($packet -match 'Reviewed cross-project knowledge') 'ADOS task packet must contain bounded shared-knowledge advice'
Assert-True (Test-Path -LiteralPath (Join-Path $ResolvedFixture '.ai\context\shared-knowledge.generated.md')) 'ADOS start must generate reviewed knowledge context'
Assert-True ($packet -match 'docs\\project-brain\\README.md') 'prompt packet must include the Project Brain entrypoint'
Assert-True ($packet -match 'README.md \(over .* optional-base cap\)') 'prompt packet must report the oversized root README instead of selecting it'
$packetSelectedBlock = (($packet -split '## Selected files',2)[1] -split '## Skipped duplicate files',2)[0]
$packetFriendCopies = @($packetSelectedBlock -split "`r?`n" | Where-Object { $_ -match 'src\\friends(?:-copy)?\.ts' })
Assert-True ($packetFriendCopies.Count -eq 1) 'prompt packet must select only one copy of identical source content'
Assert-True ($packet -match 'duplicates src\\friends(?:-copy)?\.ts') 'prompt packet must report which duplicate source file was skipped'
$sessionContext = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\session-context.md') -Raw
Assert-True ($sessionContext.IndexOf('docs\project-brain\README.md') -lt $sessionContext.IndexOf('README.md when task-relevant')) 'session context must route Project Brain before the optional root README'

$originalDisableRg = $env:ADOS_DISABLE_RG
$env:ADOS_DISABLE_RG = '1'
try {
    & $Ados analyze -ProjectPath $ResolvedFixture -Task 'Find sendFriendRequest without ripgrep' -MaxFiles 100 -MaxCommits 20
}
finally { $env:ADOS_DISABLE_RG = $originalDisableRg }
$fallbackPacket = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\context\prompt-packet.generated.md') -Raw
Assert-True ($fallbackPacket -match 'src\\friends(?:-copy)?\.ts') 'native PowerShell fallback must find task-relevant files without rg'

& $Operations adapter -ProjectPath $ResolvedFixture
$adapter = Read-Json '.ai\context\project-adapter.generated.json'
Assert-True ($adapter.protectedBoundaries -contains 'secrets') 'custom adapters must not remove global protected boundaries'
Assert-True ($adapter.protectedBoundaries -contains 'custom boundary') 'custom adapters must add their protected boundaries'
& $Operations checkpoint -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -Phase 'test'
Write-FixtureFile 'src\friends.ts' "export function sendFriendRequest(userId: string): string { return userId.trim(); }`r`n"
Push-Location $ResolvedFixture
try {
    & git add src\friends.ts
    & git commit -q -m 'test: committed change after checkpoint'
}
finally { Pop-Location }
$fakeValue = 'test-only-' + 'not-a-secret'
Write-FixtureFile 'src\secret-fixture.ts' "api_key = `"$fakeValue`"`r`n"
Push-Location $ResolvedFixture
try { & git add src\secret-fixture.ts }
finally { Pop-Location }
& $Quality scope -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -AllowedScope @('src','tests')
Assert-True ((Read-Json '.ai\evidence\scope-guard.generated.json').status -eq 'PASS') 'scope guard must accept the allowed source change'

& $Quality verify -ProjectPath $ResolvedFixture -MaxLevel 2
Assert-True ((Read-Json '.ai\evidence\verification.generated.json').status -eq 'PASS') 'verification ladder must pass the fixture'
& $Quality evidence -ProjectPath $ResolvedFixture -RequireDiff $true
$secretGate = Read-Json '.ai\evidence\evidence-gate.generated.json'
$secretRequirement = @($secretGate.requirements | Where-Object { $_.name -eq 'no secret pattern in added diff' })[0]
Assert-True (-not $secretRequirement.passed) 'evidence gate must inspect staged changes even when checkpoint commits exist'
Push-Location $ResolvedFixture
try { & git restore --staged -- src\secret-fixture.ts }
finally { Pop-Location }
Remove-Item -LiteralPath (Join-Path $ResolvedFixture 'src\secret-fixture.ts') -Force
& $Quality scope -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -AllowedScope @('src','tests')
& $Quality verify -ProjectPath $ResolvedFixture -MaxLevel 2
& $Quality evidence -ProjectPath $ResolvedFixture -RequireDiff $true
Assert-True ((Read-Json '.ai\evidence\evidence-gate.generated.json').status -eq 'VERIFIED') 'evidence gate must verify an observed in-scope diff'
$prSummary = Read-Json '.ai\evidence\pr-evidence-summary.generated.json'
Assert-True ($prSummary.status -eq 'READY') 'fresh verified evidence must produce a ready PR summary'
Assert-True ($prSummary.evidenceCurrent) 'PR summary must match the current repository state'
$prMarkdown = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\evidence\pr-evidence-summary.generated.md') -Raw
Assert-True ($prMarkdown -match 'ADOS evidence summary') 'PR summary must create copy-ready Markdown'

Write-FixtureFile 'src\friends.ts' "export function sendFriendRequest(userId: string): string { return userId.trim().toLowerCase(); }`r`n"
& $Quality pr-summary -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
$staleSummary = Read-Json '.ai\evidence\pr-evidence-summary.generated.json'
Assert-True ($staleSummary.status -eq 'NOT_READY') 'repository changes after Evidence Gate must invalidate the PR summary'
Assert-True (-not $staleSummary.evidenceCurrent) 'stale evidence must be reported explicitly'
Push-Location $ResolvedFixture
try { & git restore -- src\friends.ts }
finally { Pop-Location }
& $Quality pr-summary -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\evidence\pr-evidence-summary.generated.json').status -eq 'READY') 'restoring the verified repository state must restore summary readiness'

& $Memory regression-add -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -RegressionCommand 'git diff --check' -Files @('src\friends.ts')
& $Memory regression-search -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\context\regression-context.generated.json').matches.Count -ge 1) 'regression memory must return the stored check'
& $Memory negative-add -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -Attempt 'Change database permissions' -Outcome 'Not the root cause' -Files @('src\friends.ts')
& $Memory decisions -ProjectPath $ResolvedFixture -Task 'Friend service request boundary'
$decisions = Read-Json '.ai\context\decision-context.generated.json'
Assert-True ($decisions.decisions.Count -ge 1) 'ADR memory must return the related decision'
Assert-True ($decisions.negativeMemory.Count -ge 1) 'decision context must include related negative memory'

$logPath = Join-Path $ResolvedFixture '.ai\test-work\failure.log'
$logLines = @('Running tests','Error: friend request failed','Expected: accepted','Received: rejected','at src/friends.ts:1:10')
for ($i = 0; $i -lt 20; $i++) { $logLines += 'retry failed' }
Write-FixtureFile '.ai\test-work\failure.log' ($logLines -join "`r`n")
& $Quality compress -ProjectPath $ResolvedFixture -LogPath $logPath
& $Quality fingerprint -ProjectPath $ResolvedFixture -LogPath $logPath -Task 'Fix sendFriendRequest behavior'
Assert-True ((Read-Json '.ai\context\compressed-log.generated.json').repeatedLinesSuppressed -ge 19) 'log compressor must suppress repeated lines'
Assert-True ((Read-Json '.ai\memory\error-fingerprints.json').entries.Count -ge 1) 'fingerprint memory must store an error signature'

& $Operations queue-add -ProjectPath $ResolvedFixture -Task 'Review friend regression evidence' -Priority high
& $Operations queue-next -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\queue\next.generated.json').next.status -eq 'pending') 'queue engine must return the pending task'
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$false
$dispatch = Read-Json '.ai\queue\dispatch.generated.json'
$dispatchQueue = Read-Json '.ai\queue\tasks.json'
Assert-True ($dispatch.state -eq 'READY_FOR_CODEX') 'dispatcher must lease one task for Codex'
Assert-True ($dispatch.route -eq 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS') 'dispatcher must use the central route policy'
Assert-True (@($dispatchQueue.tasks | Where-Object { $_.id -eq $dispatch.queueId -and $_.status -eq 'claimed' }).Count -eq 1) 'dispatcher must persist the claimed state'
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$false
Assert-True ((Read-Json '.ai\queue\dispatch.generated.json').state -eq 'BUSY') 'dispatcher must not duplicate an active lease'
$legacyCompletionRejected = $false
try { & $Operations queue-complete -ProjectPath $ResolvedFixture -QueueId $dispatch.queueId -QueueStatus completed }
catch { $legacyCompletionRejected = [string]$_.Exception.Message -match 'exact lease ID' }
Assert-True $legacyCompletionRejected 'legacy queue completion must not bypass an active dispatcher lease'
$expiredQueue = Read-Json '.ai\queue\tasks.json'
foreach ($item in @($expiredQueue.tasks)) {
    if ([string]$item.id -eq $dispatch.queueId) { $item.leaseUntil = (Get-Date).AddMinutes(-1).ToString('o') }
}
Write-FixtureFile '.ai\queue\tasks.json' ($expiredQueue | ConvertTo-Json -Depth 12)
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$false
$recoveredDispatch = Read-Json '.ai\queue\dispatch.generated.json'
Assert-True ($recoveredDispatch.state -eq 'READY_FOR_CODEX') 'dispatcher must recover an expired lease'
Assert-True ($recoveredDispatch.leaseId -ne $dispatch.leaseId) 'stale-lease recovery must issue a new lease ID'
$dispatch = $recoveredDispatch
$leaseRejected = $false
try { & $Dispatcher complete -ProjectPath $ResolvedFixture -QueueId $dispatch.queueId -LeaseId 'wrong-lease' }
catch { $leaseRejected = [string]$_.Exception.Message -match 'Lease mismatch' }
Assert-True $leaseRejected 'dispatcher must reject completion with the wrong lease'
& $Dispatcher release -ProjectPath $ResolvedFixture -QueueId $dispatch.queueId -LeaseId $dispatch.leaseId -ResultNote 'smoke release'
Assert-True (@((Read-Json '.ai\queue\tasks.json').tasks | Where-Object { $_.id -eq $dispatch.queueId -and $_.status -eq 'pending' }).Count -eq 1) 'release must return the exact task to pending'
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$false
$dispatchAgain = Read-Json '.ai\queue\dispatch.generated.json'
& $Operations checkpoint -ProjectPath $ResolvedFixture -Task $dispatchAgain.task -Phase 'verification'
& $Quality all -ProjectPath $ResolvedFixture -Task $dispatchAgain.task -AllowedScope @('src','tests') -MaxLevel 1 -RequireDiff $false
& $Dispatcher complete -ProjectPath $ResolvedFixture -QueueId $dispatchAgain.queueId -LeaseId $dispatchAgain.leaseId -ResultStatus completed -ResultNote 'smoke completed'
Assert-True (@((Read-Json '.ai\queue\tasks.json').tasks | Where-Object { $_.id -eq $dispatchAgain.queueId -and $_.status -eq 'completed' }).Count -eq 1) 'completion must close only the exact leased task'
& $Operations queue-add -ProjectPath $ResolvedFixture -Task 'through Ollama: Review README wording' -Priority low
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$false
$localDispatch = Read-Json '.ai\queue\dispatch.generated.json'
Assert-True ($localDispatch.route -eq 'LOCAL_FIRST_THEN_CODEX_VERIFY') 'an explicit Ollama request may route unprotected work local-first'
Assert-True ($localDispatch.details.localModel -eq 'DISABLED') 'test mode must disable Ollama without weakening the route'
& $Operations checkpoint -ProjectPath $ResolvedFixture -Task $localDispatch.task -Phase 'verification'
& $Quality all -ProjectPath $ResolvedFixture -Task $localDispatch.task -AllowedScope @('src','tests') -MaxLevel 1 -RequireDiff $false
& $Dispatcher complete -ProjectPath $ResolvedFixture -QueueId $localDispatch.queueId -LeaseId $localDispatch.leaseId -ResultStatus completed -ResultNote 'local route tested'
& $Operations queue-add -ProjectPath $ResolvedFixture -Task 'Review README wording for Supabase RLS release' -Priority protected
& $Dispatcher run -ProjectPath $ResolvedFixture -MaxFiles 100 -PrepareContext:$false -UseOllama:$true
$protectedDispatch = Read-Json '.ai\queue\dispatch.generated.json'
Assert-True ($protectedDispatch.route -eq 'CODEX_REQUIRED') 'protected work must always route to Codex'
Assert-True ($protectedDispatch.details.localModel -eq 'SKIP') 'protected work must never invoke Ollama'
& $Dispatcher complete -ProjectPath $ResolvedFixture -QueueId $protectedDispatch.queueId -LeaseId $protectedDispatch.leaseId -ResultStatus blocked -ResultNote 'protected authorization required'
& $Operations benchmark -ProjectPath $ResolvedFixture -Task 'Fix sendFriendRequest behavior' -MaxFiles 100
$benchmark = Read-Json '.ai\analytics\ab-benchmark.generated.json'
Assert-True ($benchmark.incremental.secondUpdated -eq 0) 'benchmark second index pass must be incremental'
Assert-True ([string]$benchmark.note -match 'no model API') 'benchmark must preserve the zero-paid-API boundary'
Assert-True ([string]$benchmark.head -eq (Read-Json '.ai\index\hash-index.generated.json').head) 'benchmark must bind metrics to the current HEAD'

& $Operations resume -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\context\resume.generated.json').safeToResume) 'checkpoint must be resumable on the same branch'
& $Operations usage -ProjectPath $ResolvedFixture
Assert-True ((Read-Json '.ai\analytics\usage-summary.generated.json').eventCount -ge 1) 'usage analytics must contain local events'

& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$health = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($health.status -eq 'HEALTHY') 'project health must pass project-owned thresholds for the clean fixture'
Assert-True ($health.thresholdSource -eq '.ados/health.json') 'project health must report the project-owned threshold source'
Assert-True ($health.historyCount -eq 1) 'first project health run must create one trend snapshot'
Assert-True ((Read-Json '.ai\analytics\night-audit.generated.json').metrics.sourceFiles -ge 1) 'night audit must expose deterministic JSON metrics'
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$duplicateHealth = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($duplicateHealth.historyCount -eq 1) 'identical consecutive health states must not grow history'
Assert-True (-not $duplicateHealth.snapshotRecorded) 'identical health state must report snapshot replacement'

Write-FixtureFile 'tests\friends.test.ts' "// TODO add a regression assertion`r`nimport { sendFriendRequest } from '../src/friends';`r`n"
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
$attentionHealth = Read-Json '.ai\analytics\health.generated.json'
Assert-True ($attentionHealth.status -eq 'ATTENTION') 'project health must flag a project-owned threshold breach'
Assert-True ($attentionHealth.historyCount -eq 2) 'changed health metrics must append a trend snapshot'
$todoTrend = @($attentionHealth.trend | Where-Object { $_.metric -eq 'todoMarkers' })[0]
Assert-True ($todoTrend.change -eq 'up') 'health trend must report an increased TODO count'
Push-Location $ResolvedFixture
try { & git restore -- tests\friends.test.ts }
finally { Pop-Location }

Write-FixtureFile '.ados\health.json' '{"schemaVersion":1,"thresholds":{"maxTodoMarkers":-1}}'
& $Operations health -ProjectPath $ResolvedFixture -MaxFiles 100
Assert-True ((Read-Json '.ai\analytics\health.generated.json').status -eq 'CONFIG_ERROR') 'invalid project health thresholds must fail closed'
Push-Location $ResolvedFixture
try { & git restore -- .ados\health.json }
finally { Pop-Location }

Push-Location $ResolvedFixture
try { $statusBeforeNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
& $Operations night -ProjectPath $ResolvedFixture -MaxFiles 100
Push-Location $ResolvedFixture
try { $statusAfterNight = (& git status --porcelain=v1 | Out-String).TrimEnd() }
finally { Pop-Location }
Assert-True ($statusBeforeNight -eq $statusAfterNight) 'night mode must not change product-code Git status'
$nightSummary = Get-Content -LiteralPath (Join-Path $ResolvedFixture '.ai\analytics\night-mode.generated.md') -Raw
Assert-True ($nightSummary -match 'Project health: HEALTHY') 'night mode must include current project health'

& $Ados scheduler -ProjectPath $ResolvedFixture -SchedulerAction preview -DailyAt '03:15' -MaxFiles 100 -HealthHistoryLimit 5
$schedulerPreview = Read-Json '.ai\analytics\night-scheduler.generated.json'
Assert-True ($schedulerPreview.state -eq 'PREVIEW') 'scheduler preview must remain non-mutating'
Assert-True ([string]$schedulerPreview.task.taskName -match '^ADOS-Night-ados-v4-smoke-[a-f0-9]{10}$') 'scheduler task name must be scoped to the exact project'
Assert-True ($schedulerPreview.task.runLevel -eq 'Limited') 'scheduler must use limited privileges'
Assert-True ($schedulerPreview.task.logonType -eq 'Interactive') 'scheduler must not store background credentials'
Assert-True (-not [bool]$schedulerPreview.task.storesCredentials) 'scheduler must not store credentials'
Assert-True ([string]$schedulerPreview.task.arguments -match 'RemoteSigned') 'scheduler must not bypass the PowerShell execution policy'
$installBlocked = $false
try { & $Scheduler install -ProjectPath $ResolvedFixture -DailyAt '03:15' -MaxFiles 100 -HealthHistoryLimit 5 }
catch { $installBlocked = [string]$_.Exception.Message -match 'Installation blocked' }
Assert-True $installBlocked 'scheduler installation must require explicit confirmation before system access'
$uninstallBlocked = $false
try { & $Scheduler uninstall -ProjectPath $ResolvedFixture -DailyAt '03:15' -MaxFiles 100 -HealthHistoryLimit 5 }
catch { $uninstallBlocked = [string]$_.Exception.Message -match 'Uninstall blocked' }
Assert-True $uninstallBlocked 'scheduler uninstall must require explicit confirmation before system access'

& (Join-Path $RepoRoot 'tests\ados-shared-knowledge.ps1')
Write-Host 'ADOS v0.4 smoke test: PASS'
