[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$adoptionTestRepo = Split-Path -Parent $PSScriptRoot
$adoptionTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('devcore-adoption-' + [guid]::NewGuid().ToString('N'))
$adoptionTestAdopt = Join-Path $adoptionTestRepo 'scripts/adopt-albert-project.ps1'
$adoptionTestDevCore = Join-Path $adoptionTestRepo 'devcore.ps1'
$adoptionTestChecks = 0

function Assert-AdoptionTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:adoptionTestChecks++
    Write-Host "PASS: $Message"
}

function Expect-AdoptionTestFailure([scriptblock]$Body, [string]$Pattern, [string]$Message) {
    $failure = $null
    try { & $Body *> $null }
    catch { $failure = $_ }
    if ($null -ne $failure -and $failure.Exception.Message -notmatch $Pattern) {
        throw "Unexpected failure for $Message`: $($failure.Exception.Message)"
    }
    Assert-AdoptionTest ($null -ne $failure) $Message
}

function Write-AdoptionTestText([string]$Path, [string]$Text) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-AdoptionTestGit([string]$Project, [string[]]$Arguments, [switch]$AllowFailure) {
    # Native stderr is not a PowerShell failure on its own (Git uses it for
    # progress too). Judge the captured native exit code, including on PS 5.1.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git --no-optional-locks -C $Project @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "Fixture Git failed ($code): $($Arguments -join ' '): $($output -join ' ')"
    }
    return [pscustomobject]@{ exitCode=$code; text=(($output | Out-String).TrimEnd()) }
}

function New-AdoptionTestProject([string]$Name, [switch]$SeedCommit) {
    $path = Join-Path $adoptionTestRoot ($Name + '/project with spaces')
    $null = [IO.Directory]::CreateDirectory($path)
    $null = Invoke-AdoptionTestGit $path @('init', '-q', '-b', 'main')
    $null = Invoke-AdoptionTestGit $path @('config', 'user.name', 'DevCore Adoption Fixture')
    $null = Invoke-AdoptionTestGit $path @('config', 'user.email', 'devcore-adoption@example.invalid')
    $null = Invoke-AdoptionTestGit $path @('config', 'core.autocrlf', 'false')
    $null = Invoke-AdoptionTestGit $path @('config', 'core.safecrlf', 'false')
    $null = Invoke-AdoptionTestGit $path @('config', 'commit.gpgSign', 'false')
    if ($SeedCommit) {
        Write-AdoptionTestText (Join-Path $path 'README.md') "# Adoption fixture`n"
        $null = Invoke-AdoptionTestGit $path @('add', 'README.md')
        $null = Invoke-AdoptionTestGit $path @('commit', '-q', '-m', 'Seed adoption fixture')
    }
    return $path
}

function Invoke-AdoptionTestBootstrap([string]$Project, [string]$RegistryBase, [switch]$DryRun) {
    & $adoptionTestAdopt -ProjectPath $Project -RegistryBasePath $RegistryBase -DryRun:$DryRun *> $null
}

function Get-AdoptionTestTree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '[absent]' }
    $base = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    return (@(Get-ChildItem -LiteralPath $base -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
        if ($_.PSIsContainer) { $relative + '|DIRECTORY' }
        else { $relative + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n")
}

function Get-AdoptionTestFileState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '[absent]' }
    $file = Get-Item -LiteralPath $Path
    return ($file.Length.ToString() + '|' + $file.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)
}

function Get-AdoptionTestOriginalFiles([string]$Project) {
    $files = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Project -Force -Recurse -File)) {
        $relative = $file.FullName.Substring($Project.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -notlike '.git/*') {
            $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    return $files
}

function Assert-AdoptionTestOriginalFiles([string]$Project, [hashtable]$Before, [string]$Message) {
    $unchanged = $true
    foreach ($relative in $Before.Keys) {
        $path = Join-Path $Project $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Before[$relative]) {
            $unchanged = $false
        }
    }
    Assert-AdoptionTest $unchanged $Message
}

function Write-AdoptionTestLegacyRegistry([string]$RegistryBase) {
    # A preflight failure must not opportunistically repair this other state.
    $legacy = [ordered]@{
        value=@([pscustomobject]@{ name='existing-project'; path=(Join-Path $adoptionTestRoot 'existing-project'); registered='2026-01-01T00:00:00Z' })
        Count=1
    }
    Write-AdoptionTestText (Join-Path $RegistryBase '.albert-devcore/projects.json') (ConvertTo-Json -InputObject $legacy -Depth 5)
}

try {
    # A normal new project has no first commit yet. Planning must not create a
    # registry, project context, skills, Git index refresh, or exclude entries.
    $fresh = New-AdoptionTestProject 'fresh'
    $freshCase = Split-Path -Parent $fresh
    $freshProfile = Join-Path $freshCase 'isolated profile'
    $freshBefore = Get-AdoptionTestTree $freshCase
    Invoke-AdoptionTestBootstrap $fresh $freshProfile -DryRun
    Assert-AdoptionTest ((Get-AdoptionTestTree $freshCase) -ceq $freshBefore) 'dry-run on an unborn repository writes no project, registry or Git metadata'

    Invoke-AdoptionTestBootstrap $fresh $freshProfile
    $freshHead = Invoke-AdoptionTestGit $fresh @('rev-parse', '--verify', '--quiet', 'HEAD') -AllowFailure
    Assert-AdoptionTest ($freshHead.exitCode -eq 1) 'adoption accepts an unborn HEAD without creating a commit'
    $freshContext = [IO.File]::ReadAllText((Join-Path $fresh '.ai/context/session-context.md'))
    Assert-AdoptionTest ($freshContext -match '\(no commits yet\)' -and $freshContext -notmatch '(?im)^Commit:\s*HEAD\s*$|fatal:') 'new-project context reports the absence of commits honestly'
    $ownNames = @(Get-ChildItem -LiteralPath (Join-Path $fresh '.agents/skills') -Directory | ForEach-Object { $_.Name } | Sort-Object)
    Assert-AdoptionTest (($ownNames -join '|') -eq 'albert-architecture-review|albert-design-director|albert-skill-router') 'new-project bootstrap installs exactly the three owned router packages'
    Assert-AdoptionTest ((Test-Path -LiteralPath (Join-Path $fresh '.ai/context/current-state.md')) -and (Test-Path -LiteralPath (Join-Path $fresh '.ai/context/decisions.md'))) 'a project without existing memory receives the minimal state and decision files'
    $freshRegistry = Join-Path $freshProfile '.albert-devcore/projects.json'
    $registered = @((Get-Content -LiteralPath $freshRegistry -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    Assert-AdoptionTest ($registered.Count -eq 1 -and [IO.Path]::GetFullPath([string]$registered[0].path) -eq [IO.Path]::GetFullPath($fresh)) 'registration records the actual primary repository root once'

    $registryBefore = Get-AdoptionTestFileState $freshRegistry
    $skillsBefore = Get-AdoptionTestTree (Join-Path $fresh '.agents/skills')
    $memoryBefore = Get-AdoptionTestOriginalFiles $fresh
    foreach ($generated in @('.ai/context/repo-map.generated.md', '.ai/context/import-map.generated.md', '.ai/context/test-plan.generated.md', '.ai/context/session-context.md')) { $memoryBefore.Remove($generated) }
    $exclude = (Invoke-AdoptionTestGit $fresh @('rev-parse', '--git-path', 'info/exclude')).text
    if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $fresh $exclude }
    $excludeBefore = Get-AdoptionTestFileState $exclude
    Invoke-AdoptionTestBootstrap $fresh $freshProfile
    Assert-AdoptionTest ((Get-AdoptionTestFileState $freshRegistry) -ceq $registryBefore) 'repeat adoption preserves registry bytes, registration time and file timestamp'
    Assert-AdoptionTest ((Get-AdoptionTestTree (Join-Path $fresh '.agents/skills')) -ceq $skillsBefore) 'repeat adoption preserves installed skill bytes and timestamps'
    Assert-AdoptionTest ((Get-AdoptionTestFileState $exclude) -ceq $excludeBefore) 'repeat adoption does not append duplicate ignore rules or rewrite the exclude file'
    Assert-AdoptionTestOriginalFiles $fresh $memoryBefore 'repeat adoption preserves the existing rules, policies and canonical memory'

    # Ignored caches created by the previous accepted release have no marker.
    # They remain refreshable; unrelated files with similar names do not.
    $generatedPaths = @('.ai/context/repo-map.generated.md', '.ai/context/import-map.generated.md', '.ai/context/test-plan.generated.md', '.ai/context/session-context.md')
    foreach ($relative in $generatedPaths) {
        $path = Join-Path $fresh $relative
        $text = [IO.File]::ReadAllText($path).Replace('<!-- albert-devcore:generated:v1 -->', '')
        Write-AdoptionTestText $path $text
    }
    Invoke-AdoptionTestBootstrap $fresh $freshProfile
    $marked = @($generatedPaths | Where-Object { [IO.File]::ReadAllText((Join-Path $fresh $_)).Contains('<!-- albert-devcore:generated:v1 -->') })
    Assert-AdoptionTest ($marked.Count -eq $generatedPaths.Count) 'recognized ignored caches from the previous release can be refreshed'

    # Preserve real dirty work instead of rejecting every dirty repository.
    $existing = New-AdoptionTestProject 'existing brain [1]' -SeedCommit
    $existingProfile = Join-Path (Split-Path -Parent $existing) 'isolated profile'
    Write-AdoptionTestText (Join-Path $existing 'AGENTS.md') "# Project rules`nPreserve the existing product boundaries.`n"
    Write-AdoptionTestText (Join-Path $existing 'src/main.py') "value = 'committed'`n"
    foreach ($relative in @('docs/project-brain/README.md', 'docs/project-brain/CURRENT_FOCUS.md', 'docs/project-brain/AGENT_ENTRYPOINTS.md')) {
        Write-AdoptionTestText (Join-Path $existing $relative) ("# Canonical project memory`n" + $relative + "`n")
    }
    $null = Invoke-AdoptionTestGit $existing @('add', '.')
    $null = Invoke-AdoptionTestGit $existing @('commit', '-q', '-m', 'Existing rules and canonical memory')
    Write-AdoptionTestText (Join-Path $existing 'src/main.py') "value = 'staged work'`n"
    $null = Invoke-AdoptionTestGit $existing @('add', 'src/main.py')
    Write-AdoptionTestText (Join-Path $existing 'src/main.py') "value = 'unstaged work'`n"
    Write-AdoptionTestText (Join-Path $existing 'docs/project-brain/CURRENT_FOCUS.md') "# Canonical focus`nAn unfinished local decision.`n"
    Write-AdoptionTestText (Join-Path $existing 'untracked-note.txt') "Keep this untracked note.`r`n"
    Write-AdoptionTestText (Join-Path $existing '.agents/skills/unrelated-fixture/SKILL.md') "Unrelated project skill.`n"
    $existingBefore = Get-AdoptionTestOriginalFiles $existing
    $indexBefore = (Invoke-AdoptionTestGit $existing @('ls-files', '--stage')).text
    $stagedBefore = (Invoke-AdoptionTestGit $existing @('diff', '--cached', '--binary', '--no-ext-diff')).text
    $unstagedBefore = (Invoke-AdoptionTestGit $existing @('diff', '--binary', '--no-ext-diff')).text
    $headBefore = (Invoke-AdoptionTestGit $existing @('rev-parse', 'HEAD')).text
    $existingTreeBefore = Get-AdoptionTestTree (Split-Path -Parent $existing)
    Invoke-AdoptionTestBootstrap $existing $existingProfile -DryRun
    Assert-AdoptionTest ((Get-AdoptionTestTree (Split-Path -Parent $existing)) -ceq $existingTreeBefore) 'dry-run on a dirty repository leaves the index, user files and registry untouched'
    Invoke-AdoptionTestBootstrap $existing $existingProfile
    Assert-AdoptionTestOriginalFiles $existing $existingBefore 'existing rules, Project Brain, dirty source, untracked notes and unrelated skills retain their exact bytes'
    Assert-AdoptionTest ((Invoke-AdoptionTestGit $existing @('ls-files', '--stage')).text -ceq $indexBefore -and (Invoke-AdoptionTestGit $existing @('diff', '--cached', '--binary', '--no-ext-diff')).text -ceq $stagedBefore -and (Invoke-AdoptionTestGit $existing @('diff', '--binary', '--no-ext-diff')).text -ceq $unstagedBefore) 'adoption preserves both the index and staged/unstaged changes'
    Assert-AdoptionTest ((Invoke-AdoptionTestGit $existing @('rev-parse', 'HEAD')).text -ceq $headBefore) 'adoption creates no commit or branch movement in an existing project'
    Assert-AdoptionTest (-not (Test-Path -LiteralPath (Join-Path $existing '.ai/context/current-state.md')) -and -not (Test-Path -LiteralPath (Join-Path $existing '.ai/context/decisions.md'))) 'Project Brain does not acquire a competing state or decision journal'
    $context = [IO.File]::ReadAllText((Join-Path $existing '.ai/context/session-context.md')).Replace('\', '/')
    Assert-AdoptionTest ($context.Contains('docs/project-brain/README.md') -and $context.Contains('docs/project-brain/CURRENT_FOCUS.md')) 'generated context directs the next agent to existing canonical memory'

    # Existing projects use different memory entrypoints. Explicit declarations
    # remain authoritative even when a file is missing; do not invent a second
    # memory while the declared one needs recovery.
    $memoryCases = @(
        [pscustomobject]@{ name='brain without readme'; files=@('docs/project-brain/STATE.md', 'docs/project-brain/DECISIONS.md'); adapter=$false },
        [pscustomobject]@{ name='root context'; files=@('CONTEXT.md'); adapter=$false },
        [pscustomobject]@{ name='adapter memory'; files=@('docs/project-context.md'); adapter=$true }
    )
    foreach ($memoryCase in $memoryCases) {
        $project = New-AdoptionTestProject $memoryCase.name
        $profile = Join-Path (Split-Path -Parent $project) 'isolated profile'
        foreach ($relative in $memoryCase.files) { Write-AdoptionTestText (Join-Path $project $relative) ("# Existing memory`n" + $relative) }
        if ($memoryCase.adapter) { Write-AdoptionTestText (Join-Path $project '.ados/adapter.json') '{"contextEntrypoints":["docs/project-context.md"]}' }
        $before = Get-AdoptionTestOriginalFiles $project
        Invoke-AdoptionTestBootstrap $project $profile
        Assert-AdoptionTestOriginalFiles $project $before ("$($memoryCase.name): canonical memory and its adapter are preserved")
        $context = [IO.File]::ReadAllText((Join-Path $project '.ai/context/session-context.md')).Replace('\', '/')
        $missingReferences = @($memoryCase.files | Where-Object { -not $context.Contains($_) })
        Assert-AdoptionTest ($missingReferences.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $project '.ai/context/current-state.md')) -and -not (Test-Path -LiteralPath (Join-Path $project '.ai/context/decisions.md'))) ("$($memoryCase.name): existing entrypoints are reused without a second memory")
    }
    $missingMemory = New-AdoptionTestProject 'missing adapter entrypoint'
    $missingMemoryCase = Split-Path -Parent $missingMemory
    $missingMemoryProfile = Join-Path $missingMemoryCase 'isolated profile'
    Write-AdoptionTestText (Join-Path $missingMemory '.ados/adapter.json') '{"contextEntrypoints":["docs/not-created.md"]}'
    Write-AdoptionTestLegacyRegistry $missingMemoryProfile
    $before = Get-AdoptionTestTree $missingMemoryCase
    Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $missingMemory $missingMemoryProfile } 'Declared memory entrypoint is missing' 'an explicitly declared missing memory entrypoint requires recovery before adoption'
    Assert-AdoptionTest ((Get-AdoptionTestTree $missingMemoryCase) -ceq $before -and -not (Test-Path -LiteralPath (Join-Path $missingMemory '.ai/context/current-state.md')) -and -not (Test-Path -LiteralPath (Join-Path $missingMemory '.ai/context/decisions.md'))) 'missing declared memory creates no competing journals or other side effects'

    foreach ($kind in @('parent traversal', 'absolute path')) {
        $project = New-AdoptionTestProject ('outside memory ' + $kind)
        $caseRoot = Split-Path -Parent $project
        $profile = Join-Path $caseRoot 'isolated profile'
        $outside = Join-Path $caseRoot 'outside-memory.md'
        Write-AdoptionTestText $outside "External sentinel: this is not project memory.`n"
        $entrypoint = if ($kind -eq 'parent traversal') { '../outside-memory.md' } else { [IO.Path]::GetFullPath($outside) }
        $adapter = [ordered]@{ contextEntrypoints=@($entrypoint) }
        Write-AdoptionTestText (Join-Path $project '.ados/adapter.json') (ConvertTo-Json -InputObject $adapter -Depth 4)
        Write-AdoptionTestLegacyRegistry $profile
        $before = Get-AdoptionTestTree $caseRoot
        Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $project $profile } '(entrypoint|memory|relative|outside|traversal|root)' ("$kind memory entrypoint is refused before adoption")
        Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before) ("$kind refusal preserves the external sentinel, project, Git metadata and registry")
        if ($kind -eq 'parent traversal') {
            Expect-AdoptionTestFailure { & $adoptionTestDevCore update -ProjectPath $project -RegistryBasePath $profile } '(entrypoint|memory|relative|outside|traversal|root)' 'direct update validates memory containment before generating context'
            Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before) 'direct update with invalid memory performs no writes'
        }
    }

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $project = New-AdoptionTestProject 'linked memory entrypoint'
        $caseRoot = Split-Path -Parent $project
        $profile = Join-Path $caseRoot 'isolated profile'
        $outsideDirectory = Join-Path $caseRoot 'outside-memory'
        $outside = Join-Path $outsideDirectory 'state.md'
        Write-AdoptionTestText $outside "External junction sentinel.`n"
        $junction = Join-Path $project 'linked-memory'
        $null = New-Item -ItemType Junction -Path $junction -Target $outsideDirectory
        try {
            Write-AdoptionTestText (Join-Path $project '.ados/adapter.json') '{"contextEntrypoints":["linked-memory/state.md"]}'
            Write-AdoptionTestLegacyRegistry $profile
            $before = Get-AdoptionTestTree $caseRoot
            Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $project $profile } '(linked|reparse|entrypoint|memory)' 'a memory entrypoint cannot escape through a directory junction'
            Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before -and [IO.File]::ReadAllText($outside) -ceq "External junction sentinel.`n") 'junction refusal preserves both the project and external memory sentinel'
        }
        finally { [IO.Directory]::Delete($junction) }
    }

    foreach ($kind in @('unknown untracked', 'unknown ignored', 'tracked clean', 'tracked dirty', 'staged deletion')) {
        $project = New-AdoptionTestProject $kind -SeedCommit
        $caseRoot = Split-Path -Parent $project
        $profile = Join-Path $caseRoot 'isolated profile'
        $conflict = Join-Path $project '.ai/context/repo-map.generated.md'
        Write-AdoptionTestText $conflict "# Generated repository map`n`nGenerated: 2026-01-01T00:00:00Z`n`nUser-maintained content must survive.`n"
        if ($kind -eq 'unknown ignored') {
            Add-Content -LiteralPath (Join-Path $project '.git/info/exclude') -Value '.ai/context/repo-map.generated.md' -Encoding UTF8
        }
        if ($kind -like 'tracked*' -or $kind -eq 'staged deletion') {
            $null = Invoke-AdoptionTestGit $project @('add', '-f', '.ai/context/repo-map.generated.md')
            $null = Invoke-AdoptionTestGit $project @('commit', '-q', '-m', 'User-owned tracked context')
            if ($kind -eq 'tracked dirty') { Write-AdoptionTestText $conflict "Uncommitted user context changes.`n" }
            if ($kind -eq 'staged deletion') { $null = Invoke-AdoptionTestGit $project @('rm', '-q', '.ai/context/repo-map.generated.md') }
        }
        Write-AdoptionTestLegacyRegistry $profile
        $before = Get-AdoptionTestTree $caseRoot
        Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $project $profile } '(generated|tracked|managed|overwrite|provenance)' ("$kind output is rejected before adoption")
        Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before) ("$kind refusal leaves project, index, excludes and legacy registry unchanged")
        if ($kind -eq 'unknown untracked') {
            Expect-AdoptionTestFailure { & $adoptionTestDevCore update -ProjectPath $project -RegistryBasePath $profile } '(generated|tracked|managed|overwrite|provenance)' 'direct update cannot bypass output ownership checks'
            Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before) 'direct update refusal is also free of writes'
        }
    }

    $divergent = New-AdoptionTestProject 'divergent router' -SeedCommit
    $divergentCase = Split-Path -Parent $divergent
    $divergentProfile = Join-Path $divergentCase 'isolated profile'
    Write-AdoptionTestText (Join-Path $divergent '.agents/skills/albert-skill-router/SKILL.md') "A deliberate local router adaptation.`n"
    Write-AdoptionTestText (Join-Path $divergent '.agents/skills/albert-skill-router/local-reference.md') 'Preserve this supporting file too.'
    Write-AdoptionTestLegacyRegistry $divergentProfile
    $before = Get-AdoptionTestTree $divergentCase
    Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $divergent $divergentProfile } 'Existing skill differs' 'adoption keeps divergent local skills behind the managed-upgrade boundary'
    Assert-AdoptionTest ((Get-AdoptionTestTree $divergentCase) -ceq $before) 'a divergent skill fails before project additions or registry repair'

    foreach ($kind in @('unstaged', 'staged')) {
        $project = New-AdoptionTestProject ($kind + ' owned skill deletion') -SeedCommit
        $caseRoot = Split-Path -Parent $project
        $profile = Join-Path $caseRoot 'isolated profile'
        & (Join-Path $adoptionTestRepo 'scripts/install-albert-dev-skills.ps1') -ProjectPath $project *> $null
        $null = Invoke-AdoptionTestGit $project @('add', '.agents/skills')
        $null = Invoke-AdoptionTestGit $project @('commit', '-q', '-m', 'Track owned skill fixtures')
        $relative = '.agents/skills/albert-skill-router/SKILL.md'
        if ($kind -eq 'staged') { $null = Invoke-AdoptionTestGit $project @('rm', '-q', $relative) }
        else { Remove-Item -LiteralPath (Join-Path $project $relative) }
        Write-AdoptionTestLegacyRegistry $profile
        $before = Get-AdoptionTestTree $caseRoot
        Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $project $profile } '(deleted|deletion|tracked|restore)' ("$kind deletion of an owned skill is preserved by adoption preflight")
        Assert-AdoptionTest ((Get-AdoptionTestTree $caseRoot) -ceq $before -and -not (Test-Path -LiteralPath (Join-Path $project $relative))) ("$kind skill deletion is not restored and causes no registry, index or project writes")
    }

    $primary = New-AdoptionTestProject 'linked checkout' -SeedCommit
    $linkedCase = Split-Path -Parent $primary
    $linked = Join-Path $linkedCase 'temporary worktree'
    $linkedProfile = Join-Path $linkedCase 'isolated profile'
    $null = Invoke-AdoptionTestGit $primary @('worktree', 'add', '-q', '-b', 'fixture-linked', $linked)
    Write-AdoptionTestLegacyRegistry $linkedProfile
    $before = Get-AdoptionTestTree $linkedCase
    Expect-AdoptionTestFailure { Invoke-AdoptionTestBootstrap $linked $linkedProfile } 'primary checkout' 'a temporary linked worktree is not adopted as a separate project'
    Expect-AdoptionTestFailure { & $adoptionTestDevCore register -ProjectPath $linked -RegistryBasePath $linkedProfile } 'primary checkout' 'direct registration cannot create a false linked-worktree project'
    Assert-AdoptionTest ((Get-AdoptionTestTree $linkedCase) -ceq $before) 'linked-worktree refusal preserves both checkouts and their shared Git metadata'

    Write-Host "DevCore adoption tests passed: $adoptionTestChecks checks."
}
finally {
    if (Test-Path -LiteralPath $adoptionTestRoot) { Remove-Item -LiteralPath $adoptionTestRoot -Recurse -Force }
}
