[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $PSScriptRoot
$DevCoreEntry = Join-Path $DevCoreRoot 'devcore.ps1'
$SkillsInstaller = Join-Path $PSScriptRoot 'install-albert-dev-skills.ps1'

if (-not (Test-Path -LiteralPath $DevCoreEntry)) {
    throw "DevCore entrypoint not found: $DevCoreEntry"
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
Push-Location $resolvedProject
try {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if (-not $repoRoot) { throw "Not a Git repository: $resolvedProject" }
    $repoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\','/')

    $statusBefore = (& git status --short | Out-String).TrimEnd()
    if ($statusBefore) {
        Write-Warning 'Project has pre-existing working-tree changes. Adoption will preserve existing files and add only missing Albert files.'
    }

    # Verify source hashes and preserve divergent project copies before adoption writes.
    & $SkillsInstaller -ProjectPath $repoRoot -DryRun

    Write-Host '[1/5] Checking and normalizing DevCore registry'
    & $DevCoreEntry registry-repair
    if ($LASTEXITCODE -ne 0) { throw "DevCore registry repair failed with exit code $LASTEXITCODE" }

    Write-Host "[2/5] DevCore adopt: $repoRoot"
    & $DevCoreEntry adopt -ProjectPath $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "DevCore adopt failed with exit code $LASTEXITCODE" }

    Write-Host '[3/5] Installing Albert project router skills'
    & $SkillsInstaller -ProjectPath $repoRoot

    Write-Host '[4/5] Preparing local telemetry and API-gateway scratch locations'
    $analytics = Join-Path $repoRoot '.ai\analytics'
    $externalApi = Join-Path $repoRoot '.ai\external-api'
    New-Item -ItemType Directory -Force -Path $analytics | Out-Null
    New-Item -ItemType Directory -Force -Path $externalApi | Out-Null

    Push-Location $repoRoot
    try {
        $exclude = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim()
        if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $repoRoot $exclude }
        $exclude = [IO.Path]::GetFullPath($exclude)
        $rules = @('.ai/analytics/','.ai/external-api/')
        $existing = if (Test-Path -LiteralPath $exclude) { @(Get-Content -LiteralPath $exclude) } else { @() }
        foreach ($rule in $rules) {
            if ($existing -notcontains $rule) { Add-Content -LiteralPath $exclude -Value $rule -Encoding UTF8 }
        }
    }
    finally { Pop-Location }

    Write-Host '[5/5] Refreshing generated DevCore context'
    & $DevCoreEntry update -ProjectPath $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "DevCore update failed with exit code $LASTEXITCODE" }

    $head = (& git -C $repoRoot rev-parse HEAD | Out-String).Trim()
    $branch = (& git -C $repoRoot branch --show-current | Out-String).Trim()
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
