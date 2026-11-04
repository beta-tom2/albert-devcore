[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','adopt','update','route','local','review','packet','register','projects','registry-repair')]
    [string]$Command,
    [string]$ProjectPath = '.',
    [string]$Task = '',
    [string[]]$Files = @(),
    [string]$Model = 'qwen2.5-coder:7b',
    [int]$ContextBudgetBytes = 160000,
    [string]$RegistryBasePath = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = $PSScriptRoot
$RegistryBase = $RegistryBasePath
if ($RegistryBase) { $RegistryBase = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RegistryBase) }
if (-not $RegistryBase) { $RegistryBase = $env:USERPROFILE }
if (-not $RegistryBase) { $RegistryBase = $HOME }
if (-not $RegistryBase) { $RegistryBase = $DevCoreRoot }
$RegistryPath = Join-Path $RegistryBase '.albert-devcore\projects.json'
if ($DryRun -and $Command -notin @('adopt','update','register','registry-repair')) {
    throw "DryRun is supported for adopt, update, register and registry-repair, not $Command."
}

function Invoke-DevCoreGit {
    param([string]$Root,[string[]]$Arguments,[int[]]$AllowedExitCodes = @(0))
    $null = Get-Command git -ErrorAction Stop
    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell can turn native stderr into a terminating error.
        # Inspect the native exit code instead; optional locks would make status
        # refresh the index even during a read-only preflight.
        $ErrorActionPreference = 'Continue'
        $gitOptions = @('--no-optional-locks')
        # check-ignore already accepts literal paths and rejects pathspec magic.
        if ($Arguments[0] -ne 'check-ignore') { $gitOptions += '--literal-pathspecs' }
        $output = (& git @gitOptions -C $Root @Arguments 2>$null | Out-String).TrimEnd()
        $gitExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($AllowedExitCodes -notcontains $gitExitCode) {
        throw "Git read failed (exit $gitExitCode) in ${Root}: $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ output=$output; exitCode=$gitExitCode }
}

function Assert-DevCoreTargetPath {
    param([string]$Path,[ValidateSet('File','Directory')][string]$Kind = 'File')
    $target = [IO.Path]::GetFullPath($Path)
    $current = $target
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a linked DevCore write path: $current"
            }
            $needsDirectory = ($current -ne $target) -or ($Kind -eq 'Directory')
            if ($needsDirectory -and -not $item.PSIsContainer) { throw "Directory required at DevCore write path: $current" }
            if (-not $needsDirectory -and $item.PSIsContainer) { throw "File required at DevCore write path: $current" }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-DevCoreGitPath {
    param([string]$Root,[string]$Relative)
    $path = (Invoke-DevCoreGit $Root @('rev-parse','--git-path',$Relative)).output.Trim()
    if (-not $path) { throw "Unable to resolve Git path '$Relative' for $Root" }
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    return [IO.Path]::GetFullPath($path)
}

function Assert-PrimaryCheckout {
    param([string]$Root)
    $gitDirectory = (Invoke-DevCoreGit $Root @('rev-parse','--git-dir')).output.Trim()
    $commonDirectory = (Invoke-DevCoreGit $Root @('rev-parse','--git-common-dir')).output.Trim()
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $Root $gitDirectory }
    if (-not [IO.Path]::IsPathRooted($commonDirectory)) { $commonDirectory = Join-Path $Root $commonDirectory }
    if ([IO.Path]::GetFullPath($gitDirectory).TrimEnd('\','/') -ne [IO.Path]::GetFullPath($commonDirectory).TrimEnd('\','/')) {
        throw 'Linked worktree adoption/registration is not supported. Use the primary checkout; do not register a temporary worktree as a new project.'
    }
}

function Test-TrackedDevCorePath {
    param([string]$Root,[string]$Relative)
    $tracked = Invoke-DevCoreGit $Root @('ls-files','--error-unmatch','--',$Relative) @(0,1)
    if ($tracked.exitCode -eq 0) { return $true }
    # A staged deletion is absent from ls-files, but must not be recreated.
    $deleted = Invoke-DevCoreGit $Root @('diff','--cached','--name-only','--diff-filter=D','--',$Relative)
    return -not [string]::IsNullOrWhiteSpace($deleted.output)
}

function Assert-GeneratedContextTargets {
    param([string]$Root,[switch]$IncludePacket)
    $outputs = @(
        @{ path='.ai/context/repo-map.generated.md'; header='# Generated repository map'; parts=@('## Top-level directories','## Top-level files','## Changed files') },
        @{ path='.ai/context/import-map.generated.md'; header='# Generated import map'; parts=@('Lightweight lexical map. Verify source before acting.') },
        @{ path='.ai/context/test-plan.generated.md'; header='# Generated focused test plan'; parts=@('- git diff --check - Patch integrity check.') },
        @{ path='.ai/context/session-context.md'; header='# Session context'; parts=@('## Working tree','## Diff summary','## Recent commits','## Read order') }
    )
    if ($IncludePacket) { $outputs += @{ path='.ai/context/prompt-packet.generated.md'; header='# Generated prompt packet'; parts=@('## Selected files','## Execution rules') } }
    foreach ($output in $outputs) {
        $path = Join-Path $Root $output.path
        Assert-DevCoreTargetPath $path
        if (Test-TrackedDevCorePath $Root $output.path) { throw "Refusing to overwrite tracked DevCore output: $($output.path). Preserve or relocate the project file before refreshing context." }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $ignored = Invoke-DevCoreGit $Root @('check-ignore','--quiet','--',$output.path) @(0,1)
        $text = [IO.File]::ReadAllText($path)
        $firstLine = ($text -split '\r?\n', 2)[0]
        $hasTimestamp = $text -match '(?m)^Generated: \d{4}-\d{2}-\d{2}T[^\r\n]+\r?$'
        $recognized = ($firstLine -eq $output.header) -and $hasTimestamp
        # Existing ignored caches predate the explicit marker. Their exact
        # heading, timestamp and known scaffold provide the legacy provenance.
        if (-not $text.Contains('<!-- albert-devcore:generated:v1 -->')) {
            foreach ($part in $output.parts) { if (-not $text.Contains($part)) { $recognized = $false } }
        }
        if ($ignored.exitCode -ne 0 -or -not $recognized) {
            throw "Refusing to overwrite unmanaged DevCore output: $($output.path). Only ignored, recognized generated caches may be refreshed."
        }
    }
    Assert-DevCoreTargetPath (Get-DevCoreGitPath $Root 'info/exclude')
}

function Get-RepositoryRevision {
    param([string]$Root)
    $resolvedHead = Invoke-DevCoreGit $Root @('rev-parse','--verify','--quiet','HEAD') @(0,1)
    $branch = (Invoke-DevCoreGit $Root @('branch','--show-current')).output.Trim()
    if (-not $branch) { $branch = '(detached HEAD)' }
    if ($resolvedHead.exitCode -eq 0) { return [pscustomobject]@{ head=$resolvedHead.output.Trim(); branch=$branch; hasCommit=$true } }
    $symbolicHead = Invoke-DevCoreGit $Root @('symbolic-ref','--quiet','HEAD') @(0,1)
    if ($symbolicHead.exitCode -ne 0) { throw "Unable to resolve HEAD in $Root" }
    return [pscustomobject]@{ head='(no commits yet)'; branch=$branch; hasCommit=$false }
}

function Ensure-Directory {
    param([string]$Path)
    if ($Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null }
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    Ensure-Directory (Split-Path -Parent $Path)
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Read-RegistryState {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $seenPaths = @{}
    $state = [pscustomobject]@{ needsRepair=$false; invalidCount=0 }

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        return [pscustomobject]@{ exists=$false; entries=$entries.ToArray(); needsRepair=$false; warnings=$warnings.ToArray() }
    }

    $content = Get-Content -LiteralPath $RegistryPath -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        $warnings.Add('Registry is empty; no valid project entries were loaded.')
        return [pscustomobject]@{ exists=$true; entries=$entries.ToArray(); needsRepair=$true; warnings=$warnings.ToArray() }
    }

    try { $root = $content | ConvertFrom-Json }
    catch {
        $warnings.Add("Registry JSON is invalid: $($_.Exception.Message)")
        return [pscustomobject]@{ exists=$true; entries=$entries.ToArray(); needsRepair=$true; warnings=$warnings.ToArray() }
    }

    $trimmed = $content.Trim()
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) { $state.needsRepair = $true }

    function Add-RegistryNode([object]$Node,[bool]$IsRoot=$false) {
        if ($null -eq $Node) {
            $state.needsRepair = $true
            $state.invalidCount++
            $warnings.Add('Ignoring null registry element.')
            return
        }
        if ($Node -is [System.Array]) {
            if (-not $IsRoot) { $state.needsRepair = $true }
            foreach ($child in $Node) { Add-RegistryNode $child $false }
            return
        }

        $properties = @($Node.PSObject.Properties.Name)
        $hasRequiredProperties = ($properties -contains 'name') -and ($properties -contains 'path') -and ($properties -contains 'registered')
        $hasRequiredValues = $hasRequiredProperties -and
            -not [string]::IsNullOrWhiteSpace([string]$Node.name) -and
            -not [string]::IsNullOrWhiteSpace([string]$Node.path) -and
            -not [string]::IsNullOrWhiteSpace([string]$Node.registered)

        if ($hasRequiredValues) {
            if ($properties.Count -ne 3) { $state.needsRepair = $true }
            $key = ([string]$Node.path).Trim().TrimEnd('\','/').Replace('/','\').ToLowerInvariant()
            if ($seenPaths.ContainsKey($key)) {
                $state.needsRepair = $true
                $warnings.Add("Ignoring duplicate registry path: $($Node.path)")
                return
            }
            $seenPaths[$key] = $true
            $entries.Add([pscustomobject][ordered]@{
                name=[string]$Node.name
                path=[string]$Node.path
                registered=[string]$Node.registered
            })
            return
        }

        if ($properties -contains 'value') {
            $state.needsRepair = $true
            Add-RegistryNode $Node.value $false
            return
        }

        $state.needsRepair = $true
        $state.invalidCount++
        $warnings.Add("Ignoring invalid registry element with properties: $($properties -join ', ')")
    }

    Add-RegistryNode $root $true
    return [pscustomobject]@{
        exists=$true
        entries=$entries.ToArray()
        needsRepair=[bool]$state.needsRepair
        warnings=$warnings.ToArray()
    }
}

function Write-RegistryWarnings {
    param([object]$State)
    foreach ($message in @($State.warnings | ForEach-Object { $_ })) { Write-Warning $message }
}

function Backup-RegistryFile {
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return $null }
    $directory = Split-Path -Parent $RegistryPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backup = Join-Path $directory "projects.backup-$stamp.json"
    $suffix = 0
    while (Test-Path -LiteralPath $backup) {
        $suffix++
        $backup = Join-Path $directory "projects.backup-$stamp-$suffix.json"
    }
    Copy-Item -LiteralPath $RegistryPath -Destination $backup
    Write-Host "Registry backup: $backup"
    return $backup
}

function Write-NormalizedRegistry {
    param([object[]]$Entries,[switch]$CreateBackup)
    Ensure-Directory (Split-Path -Parent $RegistryPath)
    if ($CreateBackup -and (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        $null = Backup-RegistryFile
    }
    $flatEntries = @($Entries | ForEach-Object { $_ })
    $json = if ($flatEntries.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $flatEntries -Depth 4 }
    Write-Utf8NoBom $RegistryPath ($json + [Environment]::NewLine)
}

function Invoke-RegistryRepair {
    Assert-DevCoreTargetPath $RegistryPath
    $state = Read-RegistryState
    Write-RegistryWarnings $state
    if (-not $state.exists) {
        Write-Host 'Registry not found; nothing to repair.'
        return
    }
    if (-not $state.needsRepair) {
        Write-Host "Registry already normalized: $(@($state.entries).Count) project(s)."
        return
    }
    if ($DryRun) { Write-Host "[DRY RUN] Would back up and normalize registry: $RegistryPath"; return }
    Write-NormalizedRegistry -Entries $state.entries -CreateBackup
    Write-Host "Registry repaired: $(@($state.entries).Count) valid project(s)."
}

function Resolve-RepositoryRoot {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $root = (Invoke-DevCoreGit $resolved @('rev-parse','--show-toplevel')).output.Trim()
    if (-not $root) { throw "Not a Git repository: $resolved" }
    return [IO.Path]::GetFullPath($root).TrimEnd('\','/')
}

function Get-RelativePathCompat {
    param([string]$Root,[string]$FullPath)
    $rootUri = New-Object Uri(($Root.TrimEnd('\') + '\'))
    $fileUri = New-Object Uri($FullPath)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace('/','\')
}

function Test-CommandAvailable {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Doctor {
    $checks = @(
        @{ Name='git'; Required=$true },
        @{ Name='rg'; Required=$false },
        @{ Name='ollama'; Required=$false },
        @{ Name='node'; Required=$false },
        @{ Name='npm'; Required=$false }
    )
    $failed = $false
    foreach ($check in $checks) {
        $present = Test-CommandAvailable $check.Name
        if ($present) { $status = 'PASS' }
        elseif ($check.Required) { $status = 'FAIL'; $failed = $true }
        else { $status = 'OPTIONAL-MISSING' }
        Write-Host ('{0,-18} {1}' -f $check.Name,$status)
    }
    $registryStatus = if (Test-Path -LiteralPath $RegistryPath) { 'PASS' } else { 'EMPTY' }
    Write-Host ('{0,-18} {1}' -f 'registry',$registryStatus)
    if (Test-CommandAvailable 'ollama') { Write-Host "`nLocal models:"; & ollama list }
    if ($failed) { throw 'Required DevCore tools are missing.' }
}

function Add-IgnoreRules {
    param([string]$Root)
    $ignore = Get-DevCoreGitPath $Root 'info/exclude'
    Assert-DevCoreTargetPath $ignore
    $required = @(
        '.ai/context/session-context.md',
        '.ai/context/repo-map.generated.md',
        '.ai/context/import-map.generated.md',
        '.ai/context/test-plan.generated.md',
        '.ai/context/prompt-packet.generated.md',
        '.ai/local-output/',
        '.ai/cache/',
        '.ai/analytics/',
        '.ai/external-api/',
        '*.local-ai.log'
    )
    $existing = if (Test-Path -LiteralPath $ignore) { @(Get-Content -LiteralPath $ignore) } else { @() }
    $missing = @($required | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -gt 0) {
        Ensure-Directory (Split-Path -Parent $ignore)
        $oldText = if (Test-Path -LiteralPath $ignore) { [IO.File]::ReadAllText($ignore) } else { '' }
        $prefix = if ($oldText -and -not $oldText.EndsWith("`n")) { [Environment]::NewLine } else { '' }
        [IO.File]::AppendAllText($ignore, ($prefix + ($missing -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    }
}

function Copy-IfMissing {
    param([string]$Source,[string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        Ensure-Directory (Split-Path -Parent $Destination)
        Copy-Item -LiteralPath $Source -Destination $Destination
        Write-Host "Added: $Destination"
    } else { Write-Host "Preserved existing: $Destination" }
}

function Get-ChangedFiles {
    param([string]$Root)
    $items = @()
    foreach ($arguments in @(
        @('-c','core.safecrlf=false','diff','--name-only'),
        @('-c','core.safecrlf=false','diff','--cached','--name-only'),
        @('ls-files','--others','--exclude-standard')
    )) {
        $text = (Invoke-DevCoreGit $Root $arguments).output
        if ($text) { $items += @($text -split '\r?\n') }
    }
    return @($items | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-SourceFiles {
    param([string]$Root,[int]$Limit=300)
    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.rs','.go','.java','.kt','.kts')
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor)[\\/]'
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 300000 } |
        Sort-Object FullName | Select-Object -First $Limit)
}

function New-ImportMap {
    param([string]$Root)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated import map')
    $lines.Add('<!-- albert-devcore:generated:v1 -->')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add('')
    $lines.Add('Lightweight lexical map. Verify source before acting.')
    $lines.Add('')
    foreach ($file in (Get-SourceFiles $Root 300)) {
        $relative = Get-RelativePathCompat $Root $file.FullName
        $imports = New-Object Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            $value = $null
            if ($line -match '^\s*import\s+.*?from\s+["'']([^"'']+)["'']') { $value = $Matches[1] }
            elseif ($line -match '^\s*import\s+["'']([^"'']+)["'']') { $value = $Matches[1] }
            elseif ($line -match 'require\(["'']([^"'']+)["'']\)') { $value = $Matches[1] }
            elseif ($file.Extension -eq '.py' -and $line -match '^\s*from\s+([A-Za-z0-9_\.]+)\s+import') { $value = $Matches[1] }
            elseif ($file.Extension -eq '.py' -and $line -match '^\s*import\s+([A-Za-z0-9_\.]+)') { $value = $Matches[1] }
            if ($value -and $imports -notcontains $value) { $imports.Add($value) }
        }
        if ($imports.Count -gt 0) {
            $lines.Add("## $relative")
            foreach ($item in ($imports | Select-Object -First 20)) { $lines.Add("- $item") }
            $lines.Add('')
        }
    }
    Write-Utf8NoBom (Join-Path $Root '.ai\context\import-map.generated.md') ($lines -join "`r`n")
}

function Get-TestRecommendations {
    param([string]$Root,[string[]]$Changed)
    $commands = New-Object Collections.Generic.List[string]
    $reasons = New-Object Collections.Generic.List[string]
    $scripts = @{}
    $packagePath = Join-Path $Root 'package.json'
    if (Test-Path -LiteralPath $packagePath) {
        try {
            $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
            if ($package.scripts) {
                foreach ($property in $package.scripts.PSObject.Properties) { $scripts[$property.Name] = [string]$property.Value }
            }
        } catch { }
    }
    function Add-Test([string]$Cmd,[string]$Why) {
        if ($Cmd -and $commands -notcontains $Cmd) { $commands.Add($Cmd); $reasons.Add($Why) }
    }
    if ($scripts.ContainsKey('typecheck')) { Add-Test 'npm run typecheck' 'TypeScript validation.' }
    elseif ($scripts.ContainsKey('check:typecheck')) { Add-Test 'npm run check:typecheck' 'TypeScript validation.' }
    $changedText = ($Changed -join ' ')
    if ($changedText -match '\.(ts|tsx|js|jsx|mjs|cjs)($|\s)') {
        if ($scripts.ContainsKey('test:ci')) { Add-Test 'npm run test:ci' 'Source files changed.' }
        elseif ($scripts.ContainsKey('test')) { Add-Test 'npm test' 'Source files changed.' }
    }
    if ($changedText -match '(?i)(screen|component|ui|style|css|scss|tsx)') {
        if ($scripts.ContainsKey('check:ui-copy')) { Add-Test 'npm run check:ui-copy' 'UI copy may be affected.' }
        if ($scripts.ContainsKey('check:accessibility')) { Add-Test 'npm run check:accessibility' 'Accessibility may be affected.' }
    }
    if ($changedText -match '(?i)(supabase|migration|\.sql|rls)') {
        if ($scripts.ContainsKey('check:supabase-security')) { Add-Test 'npm run check:supabase-security' 'Supabase boundary changed.' }
        if ($scripts.ContainsKey('check:sql')) { Add-Test 'npm run check:sql' 'SQL changed.' }
    }
    if ($scripts.ContainsKey('check:conflicts')) { Add-Test 'npm run check:conflicts' 'Cheap deterministic check.' }
    if ($scripts.ContainsKey('check:secrets')) { Add-Test 'npm run check:secrets' 'Cheap deterministic check.' }
    Add-Test 'git diff --check' 'Patch integrity check.'
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated focused test plan')
    $lines.Add('<!-- albert-devcore:generated:v1 -->')
    $lines.Add('')
    $lines.Add("Generated: $(Get-Date -Format o)")
    $lines.Add('')
    if ($commands.Count -eq 0) { $lines.Add('- No project-specific checks detected.') }
    else { for ($i=0; $i -lt $commands.Count; $i++) { $lines.Add("- $($commands[$i]) - $($reasons[$i])") } }
    Write-Utf8NoBom (Join-Path $Root '.ai\context\test-plan.generated.md') ($lines -join "`r`n")
    return @($commands)
}

function Invoke-Update {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    Assert-GeneratedContextTargets $root
    $revision = Get-RepositoryRevision $root
    $contextEntrypoints = @(Get-ContextEntrypoints $root)
    if ($DryRun) { Write-Host "[DRY RUN] Would refresh verified generated DevCore context: $root ($($revision.head))"; return }
    Push-Location -LiteralPath $root
    try {
        Ensure-Directory (Join-Path $root '.ai\context')
        Add-IgnoreRules $root
        $branch = $revision.branch
        $head = $revision.head
        $status = (Invoke-DevCoreGit $root @('status','--short')).output
        $diff = (Invoke-DevCoreGit $root @('-c','core.safecrlf=false','diff','--stat')).output
        $recent = if ($revision.hasCommit) { (Invoke-DevCoreGit $root @('log','-n','12','--pretty=format:%h %ad %s','--date=short')).output } else { '(no commits yet)' }
        $changed = Get-ChangedFiles $root
        $exclude = @('.git','node_modules','dist','build','.next','.expo','coverage','.ai','ios','android')
        $dirs = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $exclude -notcontains $_.Name } | Sort-Object Name
        $files = Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Length -lt 200000 } | Sort-Object Name
        $map = New-Object Collections.Generic.List[string]
        $map.Add('# Generated repository map'); $map.Add('<!-- albert-devcore:generated:v1 -->'); $map.Add('')
        $map.Add("Generated: $(Get-Date -Format o)"); $map.Add("Commit: $head"); $map.Add('')
        $map.Add('## Top-level directories')
        foreach ($dir in $dirs) { $map.Add("- $($dir.Name)/") }
        $map.Add(''); $map.Add('## Top-level files')
        foreach ($file in $files) { $map.Add("- $($file.Name) ($($file.Length) bytes)") }
        $map.Add(''); $map.Add('## Changed files')
        if ($changed.Count -eq 0) { $map.Add('- none') } else { foreach ($item in $changed) { $map.Add("- $item") } }
        Write-Utf8NoBom (Join-Path $root '.ai\context\repo-map.generated.md') ($map -join "`r`n")
        New-ImportMap $root
        $null = Get-TestRecommendations $root $changed
        $fallbackMemory = @('.ai/context/current-state.md','.ai/context/decisions.md') | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf }
        $readOrder = @('AGENTS.md') + $contextEntrypoints + @($fallbackMemory) + @(
            '.ai/context/repo-map.generated.md',
            '.ai/context/import-map.generated.md',
            '.ai/context/test-plan.generated.md',
            'changed files and focused tests',
            'README.md when task-relevant and within the optional-base budget'
        )
        $readLines = New-Object Collections.Generic.List[string]
        for ($i = 0; $i -lt $readOrder.Count; $i++) { $readLines.Add("$($i + 1). $($readOrder[$i])") }
        $ctx = "# Session context`r`n<!-- albert-devcore:generated:v1 -->`r`n`r`nGenerated: $(Get-Date -Format o)`r`nBranch: $branch`r`nCommit: $head`r`n`r`n## Working tree`r`n$(if ($status) {$status} else {'clean'})`r`n`r`n## Diff summary`r`n$(if ($diff) {$diff} else {'none'})`r`n`r`n## Recent commits`r`n$recent`r`n`r`n## Read order`r`n$($readLines -join "`r`n")`r`n"
        Write-Utf8NoBom (Join-Path $root '.ai\context\session-context.md') $ctx
        Write-Host "Updated DevCore context for $root"
    } finally { Pop-Location }
}

function Invoke-Route {
    param([string]$TaskText)
    if (-not $TaskText) { throw 'Task is required for route.' }
    $critical = '(?i)auth|security|rls|sql|migration|production|release|payment|broker|trading|financial|secret|credential|deploy|architecture|dependency|native|permission|encryption|supabase'
    $manualRouter = Join-Path $PSScriptRoot 'scripts\manual-execution-router.ps1'
    if (-not (Test-Path -LiteralPath $manualRouter -PathType Leaf)) { throw 'Manual execution routing policy is missing.' }
    $policy = (& $manualRouter -Task $TaskText | Out-String) | ConvertFrom-Json
    if ($policy.mode -ne 'MANUAL_ONLY') { throw 'Unsupported execution-routing mode; do not infer external authorization.' }
    if ($TaskText -match $critical) { 'CODEX_REQUIRED' }
    elseif ($policy.route -eq 'EXTERNAL_API') { throw 'ADOS does not dispatch external API work. Use the separately configured explicit API workflow.' }
    elseif ($policy.route -eq 'OLLAMA') { 'LOCAL_FIRST_THEN_CODEX_VERIFY' }
    elseif ($policy.route -ne 'CODEX') { throw 'Unsupported manual execution route.' }
    else { 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS' }
}

function Get-TaskTerms {
    param([string]$TaskText)
    return @([regex]::Matches($TaskText.ToLowerInvariant(),'[\p{L}\p{Nd}_-]{4,}') | ForEach-Object { $_.Value } | Sort-Object -Unique | Select-Object -First 12)
}

function Get-ContextEntrypoints {
    param([string]$Root,[switch]$RequireExisting)

    $entrypoints = @()
    foreach ($path in @('.ai\context\project-adapter.generated.json','.ados\adapter.json')) {
        $full = Join-Path $Root $path
        Assert-DevCoreTargetPath $full
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        try { $data = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json }
        catch { throw "Invalid project memory adapter: $path. $($_.Exception.Message)" }
        $propertyNames = @($data.PSObject.Properties | ForEach-Object { $_.Name })
        if ($propertyNames -notcontains 'contextEntrypoints') { continue }
        foreach ($entry in @($data.contextEntrypoints)) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::IsPathRooted($entry) -or $entry -match '(^|[\\/])\.\.([\\/]|$)|:') {
                throw "Invalid memory entrypoint in ${path}: entries must be relative project file paths without traversal or drive/UNC prefixes."
            }
            $normalized = $entry.Replace('/', '\')
            $entryPath = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
            $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
            if (-not $entryPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Memory entrypoint escapes the project: $entry" }
            Assert-DevCoreTargetPath $entryPath
            if ($RequireExisting -and -not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
                throw "Declared memory entrypoint is missing: $entry. Restore or correct the project adapter before adoption; no competing memory was created."
            }
            $entrypoints += $normalized
        }
    }
    $knownMemory = @(
        'docs/project-brain/README.md',
        'docs/project-brain/CURRENT_FOCUS.md',
        'docs/project-brain/AGENT_ENTRYPOINTS.md',
        'docs/project-brain/STATE.md',
        'docs/project-brain/DECISIONS.md',
        'docs/project-brain/ROADMAP.md',
        'CONTEXT.md'
    )
    foreach ($path in $knownMemory) {
        $full = Join-Path $Root $path
        Assert-DevCoreTargetPath $full
        if (Test-Path -LiteralPath $full -PathType Leaf) { $entrypoints += $path }
    }
    return @($entrypoints | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)
}

function Get-SelectionHash {
    param([string]$Path)

    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return '' }
}

function Find-TaskFiles {
    param([string]$Root,[string[]]$Terms)

    $results = New-Object Collections.Generic.List[string]
    Push-Location -LiteralPath $Root
    try {
        if (-not $env:ADOS_DISABLE_RG -and (Test-CommandAvailable 'rg')) {
            foreach ($term in $Terms) {
                $found = & rg -l --hidden --glob '!node_modules/**' --glob '!.git/**' --glob '!.ai/**' --glob '!dist/**' --glob '!build/**' --fixed-strings $term . 2>$null
                foreach ($match in $found) {
                    $clean = ([string]$match).TrimStart('.','\','/')
                    if ($clean -and $results -notcontains $clean) { $results.Add($clean) }
                }
            }
        }
        else {
            $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.ps1','.psm1','.psd1','.rs','.go','.java','.kt','.kts','.cs','.sql','.md','.txt','.json','.yaml','.yml','.toml')
            $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor|target|bin|obj)[\\/]'
            $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 1000000 } |
                Sort-Object FullName |
                Select-Object -First 5000)
            foreach ($file in $files) {
                foreach ($term in $Terms) {
                    if (Select-String -LiteralPath $file.FullName -Pattern $term -SimpleMatch -Quiet -ErrorAction SilentlyContinue) {
                        $relative = Get-RelativePathCompat $Root $file.FullName
                        if ($relative -and $results -notcontains $relative) { $results.Add($relative) }
                        break
                    }
                }
            }
        }
    }
    finally { Pop-Location }
    return @($results)
}

function Invoke-Packet {
    param([string]$Path,[string]$TaskText,[int]$Budget)
    if (-not $TaskText) { throw 'Task is required for packet.' }
    $root = Resolve-RepositoryRoot $Path
    Assert-GeneratedContextTargets $root -IncludePacket
    Invoke-Update $root
    $route = Invoke-Route $TaskText
    $terms = Get-TaskTerms $TaskText
    $candidateFiles = New-Object Collections.Generic.List[string]
    foreach ($match in (Find-TaskFiles $root $terms)) {
        if ($candidateFiles -notcontains $match) { $candidateFiles.Add($match) }
    }
    Push-Location -LiteralPath $root
    try {
        foreach ($changed in (Get-ChangedFiles $root)) { if ($candidateFiles -notcontains $changed) { $candidateFiles.Insert(0,$changed) } }
        $entrypoints = @(Get-ContextEntrypoints $root)
        $baseFiles = @('AGENTS.md') + $entrypoints + @('.ai/context/current-state.md','.ai/context/decisions.md','.ai/context/repo-map.generated.md','.ai/context/import-map.generated.md','.ai/context/test-plan.generated.md')
        $optionalBaseFiles = @('README.md')
        $maxOptionalBaseBytes = [long]($Budget / 4)
        $skippedBaseFiles = New-Object Collections.Generic.List[string]
        $skippedDuplicateFiles = New-Object Collections.Generic.List[object]
        $selectedHashOwners = @{}
        $duplicateBytesAvoided = 0
        $selected = New-Object Collections.Generic.List[string]
        $used = 0
        foreach ($item in ($baseFiles + $optionalBaseFiles + @($candidateFiles))) {
            $full = Join-Path $root $item
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $size = (Get-Item -LiteralPath $full).Length
                if ($selected -contains $item) { continue }
                if ($optionalBaseFiles -contains $item -and $size -gt $maxOptionalBaseBytes) {
                    if ($skippedBaseFiles -notcontains $item) { $skippedBaseFiles.Add($item) }
                    continue
                }
                if ($skippedBaseFiles -contains $item) { continue }
                $hash = Get-SelectionHash $full
                if ($hash -and $selectedHashOwners.ContainsKey($hash)) {
                    if (@($skippedDuplicateFiles | Where-Object { [string]$_.path -eq $item }).Count -eq 0) {
                        $skippedDuplicateFiles.Add([pscustomobject]@{ path=$item; bytes=[long]$size; duplicateOf=[string]$selectedHashOwners[$hash] })
                        $duplicateBytesAvoided += [long]$size
                    }
                    continue
                }
                if (($used + $size) -le $Budget) {
                    $selected.Add($item)
                    $used += $size
                    if ($hash) { $selectedHashOwners[$hash] = $item }
                }
            }
        }
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add('# Generated prompt packet'); $lines.Add('<!-- albert-devcore:generated:v1 -->'); $lines.Add('')
        $lines.Add("Generated: $(Get-Date -Format o)"); $lines.Add("Route: $route"); $lines.Add("Budget bytes: $Budget"); $lines.Add("Selected bytes: $used"); $lines.Add('')
        $lines.Add('## Task'); $lines.Add($TaskText); $lines.Add(''); $lines.Add('## Selected files')
        foreach ($item in $selected) { $lines.Add("- $item") }
        $lines.Add(''); $lines.Add('## Skipped duplicate files')
        if ($skippedDuplicateFiles.Count -eq 0) { $lines.Add('- none') }
        else { foreach ($item in $skippedDuplicateFiles) { $lines.Add("- $($item.path) ($($item.bytes) bytes; duplicates $($item.duplicateOf))") } }
        $lines.Add("Duplicate bytes avoided: $duplicateBytesAvoided")
        $lines.Add(''); $lines.Add('## Skipped oversized base files')
        if ($skippedBaseFiles.Count -eq 0) { $lines.Add('- none') }
        else { foreach ($item in $skippedBaseFiles) { $lines.Add("- $item (over $maxOptionalBaseBytes byte optional-base cap)") } }
        $lines.Add(''); $lines.Add('## Execution rules')
        $lines.Add('- Read selected files first.'); $lines.Add('- Verify generated maps against source.'); $lines.Add('- Use deterministic checks before broad model reasoning.'); $lines.Add('- Do not use paid third-party AI APIs.'); $lines.Add('- Stop only for protected or genuinely ambiguous actions.')
        Write-Utf8NoBom (Join-Path $root '.ai\context\prompt-packet.generated.md') ($lines -join "`r`n")
        Write-Host "Prompt packet written for $root"
        Write-Output $route
    } finally { Pop-Location }
}

function Invoke-Register {
    param([string]$Path,[switch]$Preview)
    $root = Resolve-RepositoryRoot $Path
    Assert-PrimaryCheckout $root
    Assert-DevCoreTargetPath $RegistryPath
    $state = Read-RegistryState
    Write-RegistryWarnings $state
    $name = Split-Path $root -Leaf
    $key = $root.TrimEnd('\','/').Replace('/','\')
    $match = @($state.entries | Where-Object { ([string]$_.path).Trim().TrimEnd('\','/').Replace('/','\') -eq $key })
    if ($match.Count -gt 0 -and -not $state.needsRepair) { Write-Host "Already registered: $($match[0].name)"; return }
    if ($DryRun -or $Preview) {
        Write-Host "[DRY RUN] Would register/preserve $name in $RegistryPath$(if ($state.needsRepair) { ' (with a registry backup and normalization)' })"
        return
    }
    $entries = @($state.entries)
    if ($match.Count -eq 0) { $entries += [pscustomobject]@{ name=$name; path=$root; registered=(Get-Date -Format o) } }
    Write-NormalizedRegistry -Entries $entries -CreateBackup:$state.needsRepair
    Write-Host "Registered: $name"
}

function Invoke-Projects {
    $state = Read-RegistryState
    Write-RegistryWarnings $state
    if (-not $state.exists -or @($state.entries).Count -eq 0) { Write-Host 'No valid projects registered.'; return }
    foreach ($entry in @($state.entries | ForEach-Object { $_ })) { Write-Host ('{0,-28} {1}' -f $entry.name,$entry.path) }
}

function Invoke-Adopt {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    Assert-PrimaryCheckout $root
    Assert-GeneratedContextTargets $root
    $revision = Get-RepositoryRevision $root
    $template = Join-Path $DevCoreRoot 'template'
    $templatePaths = @('AGENTS.md','.ai/LOCAL_MODEL_POLICY.md','scripts/ai-local-task.ps1')
    $memoryEntrypoints = @(Get-ContextEntrypoints $root -RequireExisting)
    if ($memoryEntrypoints.Count -eq 0) {
        $templatePaths += @('.ai/context/current-state.md','.ai/context/decisions.md','.ai/context/ADR-TEMPLATE.md')
    }
    else { Write-Host "Preserved canonical project memory: $($memoryEntrypoints -join ', ')" }
    foreach ($relative in $templatePaths) {
        $source = Join-Path $template $relative
        $target = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Adoption template is missing: $source" }
        Assert-DevCoreTargetPath $target
        if (-not (Test-Path -LiteralPath $target) -and (Test-TrackedDevCorePath $root $relative)) {
            throw "Refusing to restore a deleted project file during adoption: $relative"
        }
    }
    # The complete project and registry preflight runs before the first write.
    Invoke-Register $root -Preview
    if ($DryRun) {
        Write-Host "[DRY RUN] Verified adoption plan for $root ($($revision.head)); no files, registry or Git excludes were changed."
        return
    }
    foreach ($relative in $templatePaths) { Copy-IfMissing (Join-Path $template $relative) (Join-Path $root $relative) }
    Add-IgnoreRules $root
    Invoke-Register $root
    Invoke-Update $root
}

function Invoke-Local {
    param([string]$Path,[string]$TaskText,[string[]]$SelectedFiles,[string]$LocalModel)
    if (-not $TaskText) { throw 'Task is required for local.' }
    $root = Resolve-RepositoryRoot $Path
    $runner = Join-Path $root 'scripts\ai-local-task.ps1'
    if (-not (Test-Path -LiteralPath $runner)) { throw 'Local runner is missing.' }
    & $runner -Task $TaskText -Files $SelectedFiles -Model $LocalModel
}

function Invoke-Review {
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    $changed = Get-ChangedFiles $root
    if (-not $changed -or $changed.Count -eq 0) { Write-Host 'No changed files to review.'; return }
    $safe = @($changed | Where-Object { $_ -notmatch '(?i)\.env|secret|credential|token|\.pem$|\.p12$|\.pfx$' } | Select-Object -First 12)
    & (Join-Path $root 'scripts\ai-local-task.ps1') -Task 'Read-only first-pass review. Report likely bugs, duplication, unclear names, TODOs, and missing tests. Do not approve protected changes.' -Files $safe -Model $Model
}

switch ($Command) {
    'doctor'   { Invoke-Doctor }
    'adopt'    { Invoke-Adopt $ProjectPath }
    'update'   { Invoke-Update $ProjectPath }
    'route'    { Invoke-Route $Task }
    'local'    { Invoke-Local $ProjectPath $Task $Files $Model }
    'review'   { Invoke-Review $ProjectPath }
    'packet'   { Invoke-Packet $ProjectPath $Task $ContextBudgetBytes }
    'register' { Invoke-Register $ProjectPath }
    'projects' { Invoke-Projects }
    'registry-repair' { Invoke-RegistryRepair }
}
