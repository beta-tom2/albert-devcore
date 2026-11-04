[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('doctor','adopt','update','route','local','review','packet','register','projects','registry-repair')]
    [string]$Command,
    [string]$ProjectPath = '.',
    [string]$Task = '',
    [string[]]$Files = @(),
    [string]$Model = 'qwen2.5-coder:7b',
    [int]$ContextBudgetBytes = 160000
)

$ErrorActionPreference = 'Stop'
$DevCoreRoot = $PSScriptRoot
$RegistryBase = $env:USERPROFILE
if (-not $RegistryBase) { $RegistryBase = $HOME }
if (-not $RegistryBase) { $RegistryBase = $DevCoreRoot }
$RegistryPath = Join-Path $RegistryBase '.albert-devcore\projects.json'

function Ensure-Directory {
    param([string]$Path)
    if ($Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
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
            $key = ([string]$Node.path).Trim().ToLowerInvariant()
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
    Write-NormalizedRegistry -Entries $state.entries -CreateBackup
    Write-Host "Registry repaired: $(@($state.entries).Count) valid project(s)."
}

function Resolve-RepositoryRoot {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path
    Push-Location $resolved
    try {
        $root = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if (-not $root) { throw "Not a Git repository: $resolved" }
        return [IO.Path]::GetFullPath($root).TrimEnd('\','/')
    } finally { Pop-Location }
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
    $registryStatus = if (Test-Path $RegistryPath) { 'PASS' } else { 'EMPTY' }
    Write-Host ('{0,-18} {1}' -f 'registry',$registryStatus)
    if (Test-CommandAvailable 'ollama') { Write-Host "`nLocal models:"; & ollama list }
    if ($failed) { throw 'Required DevCore tools are missing.' }
}

function Add-IgnoreRules {
    param([string]$Root)
    Push-Location $Root
    try { $ignore = (& git rev-parse --git-path info/exclude 2>$null | Out-String).Trim() }
    finally { Pop-Location }
    if (-not $ignore) { throw "Unable to resolve Git exclude path for $Root" }
    if (-not [IO.Path]::IsPathRooted($ignore)) { $ignore = Join-Path $Root $ignore }
    $ignore = [IO.Path]::GetFullPath($ignore)
    Ensure-Directory (Split-Path -Parent $ignore)
    $required = @(
        '.ai/context/session-context.md',
        '.ai/context/repo-map.generated.md',
        '.ai/context/import-map.generated.md',
        '.ai/context/test-plan.generated.md',
        '.ai/context/prompt-packet.generated.md',
        '.ai/local-output/',
        '.ai/cache/',
        '*.local-ai.log'
    )
    $existing = if (Test-Path -LiteralPath $ignore) { @(Get-Content -LiteralPath $ignore) } else { @() }
    foreach ($line in $required) {
        if ($existing -notcontains $line) { Add-Content -LiteralPath $ignore -Value $line -Encoding UTF8 }
    }
}

function Copy-IfMissing {
    param([string]$Source,[string]$Destination)
    if (-not (Test-Path $Destination)) {
        Ensure-Directory (Split-Path -Parent $Destination)
        Copy-Item $Source $Destination
        Write-Host "Added: $Destination"
    } else { Write-Host "Preserved existing: $Destination" }
}

function Get-ChangedFiles {
    param([string]$Root)
    Push-Location $Root
    try {
        $items = @()
        $items += (& git -c core.safecrlf=false diff --name-only)
        $items += (& git -c core.safecrlf=false diff --cached --name-only)
        $items += (& git ls-files --others --exclude-standard)
        return @($items | Where-Object { $_ } | Sort-Object -Unique)
    } finally { Pop-Location }
}

function Get-SourceFiles {
    param([string]$Root,[int]$Limit=300)
    $extensions = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.rs','.go','.java','.kt','.kts')
    $excluded = '(?i)[\\/](node_modules|dist|build|coverage|\.git|\.ai|\.next|\.expo|ios|android|vendor)[\\/]'
    return @(Get-ChildItem $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch $excluded -and $_.Length -lt 300000 } |
        Sort-Object FullName | Select-Object -First $Limit)
}

function New-ImportMap {
    param([string]$Root)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Generated import map')
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
    if (Test-Path $packagePath) {
        try {
            $package = Get-Content $packagePath -Raw | ConvertFrom-Json
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
    Push-Location $root
    try {
        Ensure-Directory (Join-Path $root '.ai\context')
        Add-IgnoreRules $root
        $branch = (& git branch --show-current | Out-String).Trim()
        $head = (& git rev-parse HEAD | Out-String).Trim()
        $status = (& git status --short | Out-String).TrimEnd()
        $diff = (& git -c core.safecrlf=false diff --stat | Out-String).TrimEnd()
        $recent = (& git log -n 12 --pretty=format:'%h %ad %s' --date=short | Out-String).TrimEnd()
        $changed = Get-ChangedFiles $root
        $exclude = @('.git','node_modules','dist','build','.next','.expo','coverage','.ai','ios','android')
        $dirs = Get-ChildItem $root -Directory -Force | Where-Object { $exclude -notcontains $_.Name } | Sort-Object Name
        $files = Get-ChildItem $root -File -Force | Where-Object { $_.Length -lt 200000 } | Sort-Object Name
        $map = New-Object Collections.Generic.List[string]
        $map.Add('# Generated repository map'); $map.Add('')
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
        $readOrder = @('AGENTS.md') + @(Get-ContextEntrypoints $root) + @(
            '.ai/context/current-state.md',
            '.ai/context/decisions.md',
            '.ai/context/repo-map.generated.md',
            '.ai/context/import-map.generated.md',
            '.ai/context/test-plan.generated.md',
            'changed files and focused tests',
            'README.md when task-relevant and within the optional-base budget'
        )
        $readLines = New-Object Collections.Generic.List[string]
        for ($i = 0; $i -lt $readOrder.Count; $i++) { $readLines.Add("$($i + 1). $($readOrder[$i])") }
        $ctx = "# Session context`r`n`r`nGenerated: $(Get-Date -Format o)`r`nBranch: $branch`r`nCommit: $head`r`n`r`n## Working tree`r`n$(if ($status) {$status} else {'clean'})`r`n`r`n## Diff summary`r`n$(if ($diff) {$diff} else {'none'})`r`n`r`n## Recent commits`r`n$recent`r`n`r`n## Read order`r`n$($readLines -join "`r`n")`r`n"
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
    param([string]$Root)

    $entrypoints = @()
    foreach ($path in @('.ai\context\project-adapter.generated.json','.ados\adapter.json')) {
        $full = Join-Path $Root $path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        try {
            $data = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json
            $propertyNames = @($data.PSObject.Properties | ForEach-Object { $_.Name })
            if ($propertyNames -contains 'contextEntrypoints') { $entrypoints += @($data.contextEntrypoints) }
        }
        catch { }
    }
    $projectBrain = @(
        'docs/project-brain/README.md',
        'docs/project-brain/CURRENT_FOCUS.md',
        'docs/project-brain/AGENT_ENTRYPOINTS.md'
    )
    if (Test-Path -LiteralPath (Join-Path $Root $projectBrain[0]) -PathType Leaf) { $entrypoints += $projectBrain }
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
    Push-Location $Root
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
    Invoke-Update $root
    $route = Invoke-Route $TaskText
    $terms = Get-TaskTerms $TaskText
    $candidateFiles = New-Object Collections.Generic.List[string]
    foreach ($match in (Find-TaskFiles $root $terms)) {
        if ($candidateFiles -notcontains $match) { $candidateFiles.Add($match) }
    }
    Push-Location $root
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
            if (Test-Path $full -PathType Leaf) {
                $size = (Get-Item $full).Length
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
        $lines.Add('# Generated prompt packet'); $lines.Add('')
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
    param([string]$Path)
    $root = Resolve-RepositoryRoot $Path
    $state = Read-RegistryState
    Write-RegistryWarnings $state
    $name = Split-Path $root -Leaf
    $entries = @($state.entries | Where-Object { $_.path -ne $root })
    $entries += [pscustomobject]@{ name=$name; path=$root; registered=(Get-Date -Format o) }
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
    $template = Join-Path $DevCoreRoot 'template'
    Copy-IfMissing (Join-Path $template 'AGENTS.md') (Join-Path $root 'AGENTS.md')
    Copy-IfMissing (Join-Path $template '.ai\context\current-state.md') (Join-Path $root '.ai\context\current-state.md')
    Copy-IfMissing (Join-Path $template '.ai\context\decisions.md') (Join-Path $root '.ai\context\decisions.md')
    Copy-IfMissing (Join-Path $template '.ai\context\ADR-TEMPLATE.md') (Join-Path $root '.ai\context\ADR-TEMPLATE.md')
    Copy-IfMissing (Join-Path $template '.ai\LOCAL_MODEL_POLICY.md') (Join-Path $root '.ai\LOCAL_MODEL_POLICY.md')
    Copy-IfMissing (Join-Path $template 'scripts\ai-local-task.ps1') (Join-Path $root 'scripts\ai-local-task.ps1')
    Add-IgnoreRules $root
    Invoke-Register $root
    Invoke-Update $root
}

function Invoke-Local {
    param([string]$Path,[string]$TaskText,[string[]]$SelectedFiles,[string]$LocalModel)
    if (-not $TaskText) { throw 'Task is required for local.' }
    $root = Resolve-RepositoryRoot $Path
    $runner = Join-Path $root 'scripts\ai-local-task.ps1'
    if (-not (Test-Path $runner)) { throw 'Local runner is missing.' }
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
