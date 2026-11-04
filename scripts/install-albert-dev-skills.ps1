[CmdletBinding()]
param(
    [string]$ProjectPath = '',
    [switch]$Global,
    [switch]$DryRun,
    [string[]]$Skill = @()
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = Split-Path -Parent $PSScriptRoot

function Read-SkillJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required skill manifest is missing: $Path"
    }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Invalid skill manifest: $Path. $($_.Exception.Message)" }
}

function Get-SkillContentHash([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Resolve-SkillChildPath([string]$Root, [string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:') {
        throw "Skill manifest path must stay inside its root: $Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative.Replace('\', '/')))
    if (-not $path.StartsWith(($base + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Skill manifest path escapes its root: $Relative"
    }
    return $path
}

function Assert-SkillPathIsNotLink([string]$Root, [string]$Path) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $current = [IO.Path]::GetFullPath($Path)
    while ($current -and $current.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a linked skill path: $current"
            }
        }
        if ($current -eq $base) { break }
        $current = Split-Path -Parent $current
    }
}

$registry = Read-SkillJson (Join-Path $DevCoreRoot 'skills/approved-skills.json')
$lock = Read-SkillJson (Join-Path $DevCoreRoot 'skills/skills-lock.json')
if ([int]$lock.schemaVersion -ne 1) { throw 'Unsupported skills-lock.json schemaVersion.' }
$installStatuses = @($registry.policy.installableStatuses)
if ($installStatuses.Count -eq 0) { throw 'The skill registry must define installableStatuses.' }

$registryByName = @{}
foreach ($entry in @($registry.skills)) {
    $name = [string]$entry.name
    if ($name -notmatch '^[a-z0-9][a-z0-9-]*$' -or $registryByName.ContainsKey($name)) {
        throw "Invalid or duplicate registry skill name: $name"
    }
    $registryByName[$name] = $entry
}
$lockByName = @{}
foreach ($entry in @($lock.skills)) {
    $name = [string]$entry.name
    if (-not $registryByName.ContainsKey($name) -or $lockByName.ContainsKey($name)) {
        throw "Unknown or duplicate locked skill name: $name"
    }
    $lockByName[$name] = $entry
}
foreach ($name in $registryByName.Keys) {
    if (-not $lockByName.ContainsKey($name)) { throw "Skill is missing from skills-lock.json: $name" }
}

$selected = @($Skill | Select-Object -Unique)
if ($selected.Count -eq 0) {
    $selected = @($registry.skills | Where-Object {
        $installStatuses -contains [string]$_.status -and $lockByName[[string]$_.name].state -eq 'verified-local'
    } | ForEach-Object { [string]$_.name })
}
if ($selected.Count -eq 0) { throw 'No verified local skills are available for installation.' }

# Validate every selected artifact before creating any target directory. Keep the
# checked bytes in memory so a later source edit cannot change what is installed.
$artifacts = @()
foreach ($name in $selected) {
    if (-not $registryByName.ContainsKey($name)) { throw "Unknown skill: $name" }
    $policy = $registryByName[$name]
    $entry = $lockByName[$name]
    if ($installStatuses -notcontains [string]$policy.status) { throw "Skill is not approved for installation: $name ($($policy.status))" }
    if ($entry.state -ne 'verified-local' -or $entry.kind -ne 'repository-owned') {
        throw "Skill has no audited local artifact: $name ($($entry.state)). No network installation was attempted."
    }
    $sourceRoot = Resolve-SkillChildPath $DevCoreRoot ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Skill source is missing: $name" }
    Assert-SkillPathIsNotLink $DevCoreRoot $sourceRoot
    $fileHashes = @{}
    $files = @()
    foreach ($file in @($entry.files)) {
        $relative = ([string]$file.path).Replace('\', '/')
        $expected = [string]$file.sha256
        if ($fileHashes.ContainsKey($relative) -or $expected -notmatch '^[a-f0-9]{64}$') {
            throw "Invalid or duplicate locked file for ${name}: $relative"
        }
        $source = Resolve-SkillChildPath $sourceRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Locked file is missing for ${name}: $relative" }
        Assert-SkillPathIsNotLink $sourceRoot $source
        $bytes = [IO.File]::ReadAllBytes($source)
        if ((Get-SkillContentHash $bytes) -ne $expected) { throw "Skill hash mismatch for ${name}: $relative. Review the change before updating the lock." }
        $fileHashes[$relative] = $expected
        $files += [pscustomobject]@{ path=$relative; sha256=$expected; bytes=$bytes }
    }
    if (-not $fileHashes.ContainsKey('SKILL.md')) { throw "SKILL.md is not locked for $name" }
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not $fileHashes.ContainsKey($relative)) { throw "Unreviewed file in skill ${name}: $relative" }
    }
    $skillFile = @($files | Where-Object { $_.path -eq 'SKILL.md' })[0]
    $text = [Text.Encoding]::UTF8.GetString($skillFile.bytes)
    if ($text -notmatch ('(?m)^name:\s*' + [regex]::Escape($name) + '\s*$')) {
        throw "Skill frontmatter name does not match the registry: $name"
    }
    $artifacts += [pscustomobject]@{ name=$name; files=$files; hashes=$fileHashes }
}

$targetBases = New-Object 'Collections.Generic.List[string]'
if ($Global) {
    $profileRoot = $env:USERPROFILE
    if (-not $profileRoot) { $profileRoot = $HOME }
    if (-not $profileRoot) { throw 'Cannot resolve the current user profile for -Global.' }
    $targetBases.Add([IO.Path]::GetFullPath((Join-Path $profileRoot '.agents/skills')))
}
if ($ProjectPath) {
    $project = (Resolve-Path -LiteralPath $ProjectPath).Path
    if (-not (Test-Path -LiteralPath $project -PathType Container)) { throw 'ProjectPath must be a directory.' }
    $target = [IO.Path]::GetFullPath((Join-Path $project '.agents/skills'))
    if (-not $targetBases.Contains($target)) { $targetBases.Add($target) }
}
if ($targetBases.Count -eq 0) { throw 'Choose -Global, -ProjectPath, or both. No installation target was selected.' }

# A different existing copy might be a deliberate local adaptation. Preserve it
# and require review instead of blindly replacing it with the canonical wrapper.
foreach ($targetBase in $targetBases) {
    Assert-SkillPathIsNotLink ([IO.Path]::GetPathRoot($targetBase)) $targetBase
    foreach ($artifact in $artifacts) {
        $target = Resolve-SkillChildPath $targetBase $artifact.name
        if (Test-Path -LiteralPath $target) {
            Assert-SkillPathIsNotLink $targetBase $target
            if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Skill target is not a directory: $target" }
            foreach ($file in $artifact.files) {
                $destination = Resolve-SkillChildPath $target $file.path
                if ((Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
                    throw "Locked skill target is not a file: $destination"
                }
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $target -Recurse -File -Force)) {
                Assert-SkillPathIsNotLink $target $file.FullName
                $relative = $file.FullName.Substring($target.Length).TrimStart('\', '/').Replace('\', '/')
                if (-not $artifact.hashes.ContainsKey($relative) -or (Get-SkillContentHash ([IO.File]::ReadAllBytes($file.FullName))) -ne $artifact.hashes[$relative]) {
                    throw "Existing skill differs from the reviewed artifact: $target. Review and preserve that copy before replacing it."
                }
            }
        }
    }
}

foreach ($targetBase in $targetBases) {
    foreach ($artifact in $artifacts) {
        $target = Resolve-SkillChildPath $targetBase $artifact.name
        if ($DryRun) {
            Write-Host "[DRY RUN] verified local skill $($artifact.name) -> $target"
            continue
        }
        foreach ($file in $artifact.files) {
            $destination = Resolve-SkillChildPath $target $file.path
            if (Test-Path -LiteralPath $destination -PathType Leaf) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($file.bytes, 0, $file.bytes.Length) }
            finally { $stream.Dispose() }
        }
        Write-Host "[skill] verified local copy: $($artifact.name) -> $target"
    }
}

$unresolved = @($lock.skills | Where-Object { $_.state -eq 'needs-audit' }).Count
Write-Host "Managed skill plan completed: $($artifacts.Count) skill(s), $($targetBases.Count) target(s)."
Write-Host "Unresolved external artifacts: $unresolved. Existing external installations were not changed."
Write-Host 'This command does not install skills into ChatGPT/Work or invoke an external package manager.'
