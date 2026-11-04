[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [string]$RegistryBasePath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $PSScriptRoot
$DevCoreEntry = Join-Path $DevCoreRoot 'devcore.ps1'
$SkillsInstaller = Join-Path $PSScriptRoot 'install-albert-dev-skills.ps1'
if ($RegistryBasePath) { $RegistryBasePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RegistryBasePath) }

if (-not (Test-Path -LiteralPath $DevCoreEntry)) {
    throw "DevCore entrypoint not found: $DevCoreEntry"
}

function Invoke-AdoptionGit {
    param([string]$Root,[string[]]$Arguments,[int[]]$AllowedExitCodes = @(0))
    $null = Get-Command git -ErrorAction Stop
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (& git --no-optional-locks --literal-pathspecs -C $Root @Arguments 2>$null | Out-String).TrimEnd()
        $gitExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($AllowedExitCodes -notcontains $gitExitCode) { throw "Git preflight failed (exit $gitExitCode): $($Arguments -join ' ')" }
    return [pscustomobject]@{ output=$output; exitCode=$gitExitCode }
}

function Assert-AdoptionScratchDirectory {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a linked adoption scratch path: $current" }
            if (-not $item.PSIsContainer) { throw "Adoption scratch directory is occupied by a file: $current" }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-NoDeletedOwnedSkillFiles {
    param([string]$Root)
    # The installer has already validated both manifests and all selected bytes.
    # Missing files are normally installable, except when Git records a user's
    # deletion; an adoption run must not silently resurrect those files.
    $policy = Get-Content -LiteralPath (Join-Path $DevCoreRoot 'skills/approved-skills.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lock = Get-Content -LiteralPath (Join-Path $DevCoreRoot 'skills/skills-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $approved = @($policy.skills | Where-Object { @($policy.policy.installableStatuses) -contains [string]$_.status } | ForEach-Object { [string]$_.name })
    foreach ($skill in @($lock.skills | Where-Object { $_.state -eq 'verified-local' -and $_.kind -eq 'repository-owned' -and $approved -contains [string]$_.name })) {
        foreach ($file in @($skill.files)) {
            $relative = ".agents/skills/$($skill.name)/$($file.path)".Replace('\','/')
            if (Test-Path -LiteralPath (Join-Path $Root $relative)) { continue }
            $tracked = Invoke-AdoptionGit $Root @('ls-files','--error-unmatch','--',$relative) @(0,1)
            $deleted = Invoke-AdoptionGit $Root @('diff','--cached','--name-only','--diff-filter=D','--',$relative)
            if ($tracked.exitCode -eq 0 -or -not [string]::IsNullOrWhiteSpace($deleted.output)) {
                throw "Refusing to restore a deleted tracked owned skill file during adoption: $relative. Preserve the deletion or use the separately reviewed skill manager."
            }
        }
    }
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
Push-Location -LiteralPath $resolvedProject
try {
    $repoRoot = (Invoke-AdoptionGit $resolvedProject @('rev-parse','--show-toplevel')).output.Trim()
    if (-not $repoRoot) { throw "Not a Git repository: $resolvedProject" }
    $repoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\','/')

    $statusBefore = (Invoke-AdoptionGit $repoRoot @('status','--short')).output
    if ($statusBefore) {
        Write-Warning 'Project has pre-existing working-tree changes. Adoption preserves project files and refreshes only recognized ignored DevCore caches.'
    }

    Write-Host '[1/4] Read-only adoption preflight'
    $analytics = Join-Path $repoRoot '.ai\analytics'
    $externalApi = Join-Path $repoRoot '.ai\external-api'
    Assert-AdoptionScratchDirectory $analytics
    Assert-AdoptionScratchDirectory $externalApi
    # Both preflights must succeed before a project, registry or Git exclude write.
    # Script failures terminate normally; LASTEXITCODE belongs to native programs.
    & $SkillsInstaller -ProjectPath $repoRoot -DryRun
    Assert-NoDeletedOwnedSkillFiles $repoRoot
    & $DevCoreEntry adopt -ProjectPath $repoRoot -RegistryBasePath $RegistryBasePath -DryRun
    if ($DryRun) {
        Write-Host "[DRY RUN] Albert adoption plan verified: $repoRoot"
        Write-Host '[DRY RUN] No project files, skills, registry, scratch directories or Git excludes were changed.'
        return
    }

    Write-Host "[2/4] DevCore adopt: $repoRoot"
    & $DevCoreEntry adopt -ProjectPath $repoRoot -RegistryBasePath $RegistryBasePath

    Write-Host '[3/4] Installing verified Albert project router skills'
    & $SkillsInstaller -ProjectPath $repoRoot

    Write-Host '[4/4] Preparing local scratch locations and refreshing generated context'
    [IO.Directory]::CreateDirectory($analytics) | Out-Null
    [IO.Directory]::CreateDirectory($externalApi) | Out-Null
    & $DevCoreEntry update -ProjectPath $repoRoot -RegistryBasePath $RegistryBasePath

    $resolvedHead = Invoke-AdoptionGit $repoRoot @('rev-parse','--verify','--quiet','HEAD') @(0,1)
    $head = if ($resolvedHead.exitCode -eq 0) { $resolvedHead.output.Trim() } else { '(no commits yet)' }
    $branch = (Invoke-AdoptionGit $repoRoot @('branch','--show-current')).output.Trim()
    if (-not $branch) { $branch = '(detached HEAD)' }
    Write-Host ''
    Write-Host 'Albert project adoption complete.'
    Write-Host "Repository: $repoRoot"
    Write-Host "Branch:     $branch"
    Write-Host "HEAD:       $head"
    Write-Host 'Added/preserved: AGENTS.md, Project Brain context, Albert routers, local telemetry/API scratch paths, DevCore registration/context.'
    Write-Host 'Execution routing defaults to MANUAL_ONLY; no external API transmission occurs until a provider is explicitly configured.'
    Write-Host 'Third-party development skills remain global and selectively routed; they are not copied into every repository.'
}
finally {
    Pop-Location
}
