[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('devcore-skills-' + [Guid]::NewGuid().ToString('N'))
$FixtureCore = Join-Path $Fixture 'devcore'
$OriginalUserProfile = $env:USERPROFILE
$Checks = 0

function Assert-SkillTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-SkillFailure([scriptblock]$Action, [string]$MessagePattern) {
    $failure = $null
    try { & $Action | Out-Null }
    catch { $failure = $_.Exception.Message }
    Assert-SkillTest ([bool]$failure) "Operation must fail: $MessagePattern"
    Assert-SkillTest ($failure -match $MessagePattern) "Wrong failure: $failure; expected $MessagePattern"
}

function Write-SkillTestText([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function New-SkillTestProject([string]$Name) {
    $path = Join-Path $Fixture $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

try {
    New-Item -ItemType Directory -Path (Join-Path $FixtureCore 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'skills') -Destination $FixtureCore -Recurse
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/install-albert-dev-skills.ps1') -Destination (Join-Path $FixtureCore 'scripts/install-albert-dev-skills.ps1')
    $Installer = Join-Path $FixtureCore 'scripts/install-albert-dev-skills.ps1'
    $RegistryPath = Join-Path $FixtureCore 'skills/approved-skills.json'
    $LockPath = Join-Path $FixtureCore 'skills/skills-lock.json'
    $RegistryText = [IO.File]::ReadAllText($RegistryPath)
    $LockText = [IO.File]::ReadAllText($LockPath)
    $registry = $RegistryText | ConvertFrom-Json
    $lock = $LockText | ConvertFrom-Json
    $managed = @($lock.skills | Where-Object { $_.state -eq 'verified-local' })
    $expectedNames = @('albert-skill-router', 'albert-architecture-review', 'albert-design-director')
    Assert-SkillTest ($managed.Count -eq 3) 'The baseline must manage exactly the three repository-owned wrappers.'
    foreach ($name in $expectedNames) { Assert-SkillTest (@($managed | Where-Object { $_.name -eq $name }).Count -eq 1) "Missing managed wrapper: $name" }
    Assert-SkillTest (@($registry.prioritySkills | Select-Object -Unique).Count -eq 15) 'Priority profile must identify fifteen distinct directions.'
    Assert-SkillTest ((@($registry.skills | Where-Object { $_.name -eq 'tdd' })[0]).source -eq 'mattpocock/skills') 'TDD lineage must remain Matt Pocock.'
    foreach ($name in @($registry.prioritySkills)) { Assert-SkillTest (@($registry.skills | Where-Object { $_.name -eq $name }).Count -eq 1) "Priority direction must exist in the registry: $name" }
    $Checks++

    $project = New-SkillTestProject 'dry-run'
    & $Installer -ProjectPath $project -DryRun
    Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $project '.agents'))) 'DryRun must create no installation directory.'
    $Checks++

    & $Installer -ProjectPath $project
    $installedRoot = Join-Path $project '.agents/skills'
    Assert-SkillTest (@(Get-ChildItem -LiteralPath $installedRoot -Directory).Count -eq 3) 'Default install must contain only the three verified wrappers.'
    foreach ($entry in $managed) {
        foreach ($file in $entry.files) {
            $target = Join-Path (Join-Path $installedRoot $entry.name) $file.path
            Assert-SkillTest ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256) "Installed content must match its lock: $($entry.name)"
        }
    }
    $firstWrite = (Get-Item -LiteralPath (Join-Path $installedRoot 'albert-skill-router/SKILL.md')).LastWriteTimeUtc
    & $Installer -ProjectPath $project
    Assert-SkillTest ((Get-Item -LiteralPath (Join-Path $installedRoot 'albert-skill-router/SKILL.md')).LastWriteTimeUtc -eq $firstWrite) 'Idempotent install must not rewrite an identical artifact.'
    $Checks++

    $single = New-SkillTestProject 'single'
    & $Installer -ProjectPath $single -Skill albert-design-director
    Assert-SkillTest (@(Get-ChildItem -LiteralPath (Join-Path $single '.agents/skills') -Directory).Count -eq 1) 'Explicit selection must install only that wrapper.'
    $Checks++

    $env:USERPROFILE = New-SkillTestProject 'profile'
    & $Installer -Global -DryRun
    Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.agents'))) 'Global DryRun must not modify the user profile.'
    & $Installer -Global -Skill albert-skill-router
    Assert-SkillTest (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.agents/skills/albert-skill-router/SKILL.md')) 'Global install must target the selected user profile.'
    $Checks++

    $blocked = New-SkillTestProject 'unresolved'
    Assert-SkillFailure { & $Installer -ProjectPath $blocked -Skill @('albert-skill-router', 'systematic-debugging') } 'no audited local artifact'
    Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $blocked '.agents'))) 'Unresolved artifacts must fail before any selected skill is written.'
    foreach ($name in @('writing-plans', 'playwright-cli', 'differential-review', 'ai-video-generation')) {
        Assert-SkillFailure { & $Installer -ProjectPath $blocked -Skill $name } 'not approved for installation'
    }
    Assert-SkillFailure { & $Installer -ProjectPath $blocked -Skill 'not-a-real-skill' } 'Unknown skill'
    $Checks++

    $changedSource = Join-Path $FixtureCore 'skills/albert-design-director/SKILL.md'
    $sourceBytes = [IO.File]::ReadAllBytes($changedSource)
    [IO.File]::AppendAllText($changedSource, "`nUnreviewed source change.`n")
    try {
        Assert-SkillFailure { & $Installer -ProjectPath $blocked } 'hash mismatch'
        Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $blocked '.agents'))) 'Source drift must be detected before copying any wrapper.'
    }
    finally { [IO.File]::WriteAllBytes($changedSource, $sourceBytes) }
    $Checks++

    $unexpectedSource = Join-Path $FixtureCore 'skills/albert-skill-router/new-helper.ps1'
    Write-SkillTestText $unexpectedSource '# unreviewed helper'
    try { Assert-SkillFailure { & $Installer -ProjectPath $blocked } 'Unreviewed file' }
    finally { Remove-Item -LiteralPath $unexpectedSource }
    $Checks++

    $conflict = New-SkillTestProject 'local-adaptation'
    $conflictFile = Join-Path $conflict '.agents/skills/albert-skill-router/SKILL.md'
    Write-SkillTestText $conflictFile '# deliberate project adaptation'
    Assert-SkillFailure { & $Installer -ProjectPath $conflict } 'Existing skill differs'
    Assert-SkillTest ([IO.File]::ReadAllText($conflictFile) -eq '# deliberate project adaptation') 'A differing local copy must remain intact.'
    Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $conflict '.agents/skills/albert-design-director'))) 'A destination conflict must stop the whole install before writes.'
    $Checks++

    $directoryConflict = New-SkillTestProject 'directory-conflict'
    New-Item -ItemType Directory -Path (Join-Path $directoryConflict '.agents/skills/albert-design-director/SKILL.md') -Force | Out-Null
    Assert-SkillFailure { & $Installer -ProjectPath $directoryConflict } 'target is not a file'
    Assert-SkillTest (-not (Test-Path -LiteralPath (Join-Path $directoryConflict '.agents/skills/albert-skill-router'))) 'A directory occupying a file path must fail before another skill is installed.'
    $Checks++

    $policyChange = $RegistryText | ConvertFrom-Json
    (@($policyChange.skills | Where-Object { $_.name -eq 'albert-skill-router' })[0]).status = 'rejected-for-now'
    Write-SkillTestText $RegistryPath ($policyChange | ConvertTo-Json -Depth 15)
    try { Assert-SkillFailure { & $Installer -ProjectPath $blocked -Skill 'albert-skill-router' } 'not approved for installation' }
    finally { Write-SkillTestText $RegistryPath $RegistryText }
    $Checks++

    $badLock = $LockText | ConvertFrom-Json
    (@($badLock.skills | Where-Object { $_.name -eq 'albert-skill-router' })[0]).path = '../outside'
    Write-SkillTestText $LockPath ($badLock | ConvertTo-Json -Depth 15)
    try { Assert-SkillFailure { & $Installer -ProjectPath $blocked } 'must stay inside its root' }
    finally { Write-SkillTestText $LockPath $LockText }
    $Checks++

    $badLock = $LockText | ConvertFrom-Json
    $badLock.skills = @($badLock.skills) + @($badLock.skills[0])
    Write-SkillTestText $LockPath ($badLock | ConvertTo-Json -Depth 15)
    try { Assert-SkillFailure { & $Installer -ProjectPath $blocked } 'duplicate locked skill' }
    finally { Write-SkillTestText $LockPath $LockText }
    $Checks++

    Write-SkillTestText $LockPath '{ broken JSON'
    try { Assert-SkillFailure { & $Installer -ProjectPath $blocked } 'Invalid skill manifest' }
    finally { Write-SkillTestText $LockPath $LockText }
    $Checks++

    Assert-SkillFailure { & $Installer } 'No installation target'
    $Checks++

    Write-Host "DevCore skills regression test: PASS ($Checks scenarios)"
}
finally {
    $env:USERPROFILE = $OriginalUserProfile
    if (Test-Path -LiteralPath $Fixture) { Remove-Item -LiteralPath $Fixture -Recurse -Force }
}
