[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('fingerprint','compress','scope','verify','evidence','pr-summary','all')]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$Task = '',
    [string]$LogPath = '',
    [string]$ErrorText = '',
    [string[]]$AllowedScope = @(),
    [ValidateRange(1,5)]
    [int]$MaxLevel = 3,
    [bool]$RequireDiff = $true
)

$ErrorActionPreference = 'Stop'
$Common = Join-Path $PSScriptRoot 'ados-common.ps1'
. $Common

function Get-AdosErrorFingerprint {
    param([string]$Text)

    $normalized = ([string]$Text).ToLowerInvariant()
    $normalized = $normalized -replace '[a-z]:\\[^\r\n:]+', '<path>'
    $normalized = $normalized -replace '(?<![a-z0-9_])[/\\][^\s:]+', '<path>'
    $normalized = $normalized -replace '\b[0-9a-f]{40,64}\b', '<hash>'
    $normalized = $normalized -replace '\b[0-9a-f]{8}-[0-9a-f-]{27,}\b', '<guid>'
    $normalized = $normalized -replace '(?<=line\s+)\d+', '<line>'
    $normalized = $normalized -replace ':\d+(?::\d+)?', ':<line>'
    $normalized = $normalized -replace '\b\d{4,}\b', '<number>'
    $normalized = $normalized -replace '\s+', ' '
    $normalized = $normalized.Trim()

    $codes = @([regex]::Matches($normalized, '(?i)\b(?:[a-z]{1,8}\d{3,6}|\d{5}|sqlstate\s*[a-z0-9]+)\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $signal = @([regex]::Matches($normalized, '[a-z_][a-z0-9_.-]{3,}') | ForEach-Object { $_.Value } |
        Where-Object { @('error','failed','failure','exception','expected','received','stack','trace','path','line','number') -notcontains $_ } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 16 | ForEach-Object { $_.Name })
    $basis = (($codes + $signal) | Sort-Object -Unique) -join '|'
    if (-not $basis) { $basis = $normalized.Substring(0, [math]::Min(500, $normalized.Length)) }
    $hash = Get-AdosTextHash $basis
    return [pscustomobject]@{
        id = $hash.Substring(0, 20)
        basis = $basis
        codes = @($codes)
        signals = @($signal)
    }
}

function Invoke-AdosFingerprint {
    param([string]$Root, [string]$Text, [string]$SourcePath, [string]$TaskText)

    if (-not $Text -and $SourcePath) { $Text = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 }
    if (-not $Text) { throw 'ErrorText or LogPath is required for fingerprint.' }
    $fingerprint = Get-AdosErrorFingerprint $Text
    $memoryPath = Join-Path $Root '.ai\memory\error-fingerprints.json'
    $memory = Read-AdosJson $memoryPath $null
    $entries = @()
    if ($memory -and $memory.entries) { $entries = @($memory.entries) }
    $existing = @($entries | Where-Object { [string]$_.id -eq [string]$fingerprint.id })
    $firstSeen = Get-Date -Format o
    $occurrences = 1
    if ($existing.Count -gt 0) {
        $firstSeen = [string]$existing[0].firstSeen
        $occurrences = [int]$existing[0].occurrences + 1
        $entries = @($entries | Where-Object { [string]$_.id -ne [string]$fingerprint.id })
    }
    $entries += [pscustomobject]@{
        id = $fingerprint.id
        basis = $fingerprint.basis
        codes = @($fingerprint.codes)
        signals = @($fingerprint.signals)
        task = $TaskText
        firstSeen = $firstSeen
        lastSeen = (Get-Date -Format o)
        occurrences = $occurrences
        head = Get-AdosHead $Root
    }
    Write-AdosJson $memoryPath ([ordered]@{ schemaVersion=1; entries=@($entries | Sort-Object lastSeen -Descending) }) 10
    $lines = @('# ADOS error fingerprint','',"ID: $($fingerprint.id)","Occurrences: $occurrences",'', '## Codes')
    $lines += ConvertTo-AdosMarkdownList $fingerprint.codes
    $lines += @('','## Signals')
    $lines += ConvertTo-AdosMarkdownList $fingerprint.signals
    Write-AdosUtf8 (Join-Path $Root '.ai\context\error-fingerprint.generated.md') ($lines -join "`r`n")
    Write-Host "Error fingerprint: $($fingerprint.id) (occurrence $occurrences)"
    return $fingerprint
}

function Invoke-AdosLogCompressor {
    param([string]$Root, [string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A valid LogPath is required for compress.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    Write-Verbose "Log compressor loaded $($lines.Count) lines."
    $rootIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([string]$lines[$i] -match '(?i)\b(error|failed|failure|exception|fatal|panic|assert|expected|received)\b') { $rootIndex = $i; break }
    }
    if ($rootIndex -lt 0 -and $lines.Count -gt 0) { $rootIndex = 0 }
    $start = $rootIndex - 3
    if ($start -lt 0) { $start = 0 }
    $end = $rootIndex + 10
    if ($end -ge $lines.Count) { $end = $lines.Count - 1 }
    $rootBlock = @()
    if ($rootIndex -ge 0) {
        for ($blockIndex = $start; $blockIndex -le $end; $blockIndex++) { $rootBlock += [string]$lines[$blockIndex] }
    }
    $stackFrames = @($lines | Where-Object { [string]$_ -match '(?i)\bat\s+.*[:\(]\d+|\.\w+:\d+(?::\d+)?' } | Select-Object -First 8 | ForEach-Object { [string]$_ })
    $frequent = @($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Group-Object |
        Where-Object { $_.Count -gt 1 } | Sort-Object Count -Descending | Select-Object -First 8)
    Write-Verbose "Log compressor grouped repeated lines."
    $suppressed = 0
    foreach ($group in $frequent) { $suppressed += ($group.Count - 1) }
    Write-Verbose "Log compressor counted $suppressed suppressed lines."
    $timer.Stop()
    Write-Verbose 'Log compressor stopped timer.'

    $sourceName = Split-Path -Leaf $Path
    $rootLineNumber = 0
    if ($rootIndex -ge 0) { $rootLineNumber = $rootIndex + 1 }
    $payload = [ordered]@{
        schemaVersion = 1
        generated = (Get-Date -Format o)
        source = $sourceName
        sourceLines = $lines.Count
        rootLine = $rootLineNumber
        rootBlock = @($rootBlock)
        stackFrames = @($stackFrames)
        repeatedLinesSuppressed = $suppressed
    }
    Write-Verbose 'Log compressor built payload.'
    $jsonPath = Join-Path $Root '.ai\context\compressed-log.generated.json'
    $jsonText = $payload | ConvertTo-Json -Depth 8
    Write-Verbose 'Log compressor converted JSON.'
    Write-AdosUtf8 $jsonPath $jsonText
    Write-Verbose 'Log compressor wrote JSON.'
    $report = @('# ADOS compressed log','',"Source lines: $($lines.Count)","Root line: $($payload.rootLine)","Repeated lines suppressed: $suppressed",'', '## Root failure','```text')
    $report += @($rootBlock)
    $report += @('```','','## First stack frames','```text')
    if ($stackFrames.Count -gt 0) { $report += @($stackFrames) } else { $report += 'none' }
    $report += '```'
    Write-AdosUtf8 (Join-Path $Root '.ai\context\compressed-log.generated.md') ($report -join "`r`n")
    Write-Verbose 'Log compressor wrote Markdown.'
    Add-AdosUsageEvent $Root 'log-compressor' 'PASS' $timer.ElapsedMilliseconds (Get-Item -LiteralPath $Path).Length 0 @{ lines=$lines.Count; suppressed=$suppressed }
    Write-Verbose 'Log compressor recorded usage.'
    Write-Host "Compressed log written to $jsonPath ($($lines.Count) source lines)"
    return $payload
}

function Get-AdosEvidenceFiles {
    param([string]$Root)

    $files = @(Get-AdosChangedFiles $Root)
    $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
    if ($checkpoint -and $checkpoint.head -and [string]$checkpoint.head -ne (Get-AdosHead $Root)) {
        Push-Location $Root
        try {
            $committed = @(& git -c core.safecrlf=false diff --name-only ([string]$checkpoint.head + '..HEAD') 2>$null)
            $files += @($committed | ForEach-Object { ([string]$_).Replace('/', '\') })
        }
        finally { Pop-Location }
    }
    return @($files | Where-Object { $_ -and ([string]$_ -notmatch '(?i)^\.ai[\\/]') } | Sort-Object -Unique)
}

function Invoke-AdosScopeGuard {
    param([string]$Root, [string]$TaskText, [string[]]$Allowed)

    $head = Get-AdosHead $Root
    $branch = Get-AdosBranch $Root
    $inputFingerprint = Get-AdosEvidenceFingerprint $Root
    $files = @(Get-AdosEvidenceFiles $Root)
    $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
    $baseline = @()
    if ($checkpoint -and $checkpoint.baselineChangedFiles) { $baseline = @($checkpoint.baselineChangedFiles) }
    $newFiles = @($files | Where-Object { $baseline -notcontains $_ })
    $patterns = @($Allowed | Where-Object { $_ })
    if ($patterns.Count -eq 0) { $patterns = @(Get-AdosTaskTerms $TaskText) }
    $protectedPattern = '(?i)(^|[\\/])(supabase[\\/](migrations|functions)|migrations?|auth|payments?|billing|broker|trading|production|deploy|release)([\\/]|$)|\.env($|\.)'
    $outside = @()
    $protected = @()
    foreach ($file in $newFiles) {
        if ($file -match $protectedPattern) { $protected += $file }
        $matched = $false
        foreach ($pattern in $patterns) {
            if ($file -match [regex]::Escape([string]$pattern)) { $matched = $true; break }
        }
        if (-not $matched) { $outside += $file }
    }
    $status = 'PASS'
    if ($outside.Count -gt 0 -or $protected.Count -gt 0) { $status = 'REVIEW_REQUIRED' }
    if ($patterns.Count -eq 0 -and $newFiles.Count -gt 0) { $status = 'REVIEW_REQUIRED' }
    $endFingerprint = Get-AdosEvidenceFingerprint $Root
    $repositoryUnchanged = [bool]($inputFingerprint -ceq $endFingerprint)
    if (-not $repositoryUnchanged) { $status = 'REVIEW_REQUIRED' }
    $payload = [ordered]@{
        schemaVersion = 2
        generated = (Get-Date -Format o)
        head = $head
        branch = $branch
        evidenceFingerprint = $inputFingerprint
        endEvidenceFingerprint = $endFingerprint
        repositoryUnchanged = $repositoryUnchanged
        task = $TaskText
        status = $status
        allowedPatterns = @($patterns)
        baselineChangedFiles = @($baseline)
        evaluatedFiles = @($newFiles)
        outsideScope = @($outside)
        protectedFiles = @($protected)
    }
    $jsonPath = Join-Path $Root '.ai\evidence\scope-guard.generated.json'
    Write-AdosJson $jsonPath $payload 8
    $lines = @('# ADOS scope guard','',"Status: $status", "Repository unchanged during scope evaluation: $repositoryUnchanged",'', '## Allowed patterns')
    $lines += ConvertTo-AdosMarkdownList $patterns
    $lines += @('','## Outside scope')
    $lines += ConvertTo-AdosMarkdownList $outside
    $lines += @('','## Protected files')
    $lines += ConvertTo-AdosMarkdownList $protected
    Write-AdosUtf8 (Join-Path $Root '.ai\evidence\scope-guard.generated.md') ($lines -join "`r`n")
    Write-Host "Scope guard: $status ($($outside.Count) outside, $($protected.Count) protected)"
    return $payload
}

function New-AdosCheckResult {
    param([int]$Level, [string]$Name, [string]$Status, [int]$ExitCode, [string]$Summary)
    $bounded = [string]$Summary
    $maxSummaryChars = 6000
    if ($bounded.Length -gt $maxSummaryChars) {
        $omitted = $bounded.Length - $maxSummaryChars
        $bounded = $bounded.Substring(0, $maxSummaryChars) + "`r`n... $omitted characters omitted"
    }
    return [pscustomobject]@{ level=$Level; name=$Name; status=$Status; exitCode=$ExitCode; summary=$bounded }
}

function Invoke-AdosCapturedCommand {
    param([string]$Root, [string]$Executable, [string[]]$Arguments)

    Push-Location $Root
    try {
        $output = & $Executable @Arguments 2>&1 | Out-String
        $exit = $LASTEXITCODE
        if ($null -eq $exit) { $exit = 0 }
        return [pscustomobject]@{ exitCode=[int]$exit; output=$output.TrimEnd() }
    }
    finally { Pop-Location }
}

function Get-AdosPackageTestScript {
    param([string]$PackagePath)

    $packageFile = Join-Path $PackagePath 'package.json'
    if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) { return '' }
    try {
        $package = Get-Content -LiteralPath $packageFile -Raw | ConvertFrom-Json
        $scriptsProperty = @($package.PSObject.Properties | Where-Object { $_.Name -eq 'scripts' } | Select-Object -First 1)
        if ($scriptsProperty.Count -eq 0 -or -not $scriptsProperty[0].Value) { return '' }
        $testProperty = @($scriptsProperty[0].Value.PSObject.Properties | Where-Object { $_.Name -eq 'test' } | Select-Object -First 1)
        if ($testProperty.Count -eq 0) { return '' }
        return [string]$testProperty[0].Value
    }
    catch { return '' }
}

function Get-AdosFocusedTestSelection {
    param([string]$Root)

    $map = Read-AdosJson (Join-Path $Root '.ai\index\test-symbol-map.generated.json') $null
    $current = [bool]($map -and [string]$map.head -eq (Get-AdosHead $Root) -and [string]$map.evidenceFingerprint -eq (Get-AdosEvidenceFingerprint $Root))
    $changed = @(Get-AdosEvidenceFiles $Root)
    $candidates = @()
    if ($current) {
        foreach ($association in @($map.associations)) {
            $source = [string]$association.sourceFile
            $test = [string]$association.testFile
            if ($changed -notcontains $source -and $changed -notcontains $test) { continue }
            $candidates += [pscustomobject]@{
                testFile = $test
                packageRoot = $(if ($association.packageRoot) { [string]$association.packageRoot } else { '.' })
                sourceFile = $source
                confidence = [string]$association.confidence
            }
        }
    }
    $candidates = @($candidates | Sort-Object testFile, packageRoot -Unique)
    return [pscustomobject]@{
        mapCurrent = $current
        changedFiles = @($changed)
        candidates = @($candidates)
    }
}

function Invoke-AdosVerification {
    param([string]$Root, [int]$Limit)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $head = Get-AdosHead $Root
    $branch = Get-AdosBranch $Root
    $inputFingerprint = Get-AdosEvidenceFingerprint $Root
    $results = @()
    $focusedSelection = Get-AdosFocusedTestSelection $Root
    $focusedExecuted = $false
    $focusedFallback = ''
    $diffCheck = Invoke-AdosCapturedCommand $Root 'git' @('-c','core.safecrlf=false','diff','--check')
    $results += New-AdosCheckResult 1 'git diff --check' $(if ($diffCheck.exitCode -eq 0) {'PASS'} else {'FAIL'}) $diffCheck.exitCode $(if ($diffCheck.output) {$diffCheck.output} else {'clean'})
    $stagedDiffCheck = Invoke-AdosCapturedCommand $Root 'git' @('-c','core.safecrlf=false','diff','--cached','--check')
    $results += New-AdosCheckResult 1 'git diff --cached --check' $(if ($stagedDiffCheck.exitCode -eq 0) {'PASS'} else {'FAIL'}) $stagedDiffCheck.exitCode $(if ($stagedDiffCheck.output) {$stagedDiffCheck.output} else {'clean'})
    $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
    if ($checkpoint -and $checkpoint.head -and [string]$checkpoint.head -ne (Get-AdosHead $Root)) {
        $checkpointRange = ([string]$checkpoint.head + '..HEAD')
        $committedDiffCheck = Invoke-AdosCapturedCommand $Root 'git' @('-c','core.safecrlf=false','diff','--check',$checkpointRange)
        $results += New-AdosCheckResult 1 'git checkpoint diff --check' $(if ($committedDiffCheck.exitCode -eq 0) {'PASS'} else {'FAIL'}) $committedDiffCheck.exitCode $(if ($committedDiffCheck.output) {$committedDiffCheck.output} else {'clean'})
    }
    $conflicts = Invoke-AdosCapturedCommand $Root 'git' @('grep','-n','-I','-e','^<<<<<<< ','-e','^=======$','-e','^>>>>>>> ')
    $conflictStatus = if ($conflicts.exitCode -eq 1 -and -not $conflicts.output) { 'PASS' } elseif ($conflicts.output) { 'FAIL' } else { 'PASS' }
    $results += New-AdosCheckResult 1 'conflict markers' $conflictStatus $conflicts.exitCode $(if ($conflicts.output) {$conflicts.output} else {'none'})

    if ($Limit -ge 2) {
        $psFiles = @(Get-AdosEvidenceFiles $Root | Where-Object { $_ -match '(?i)\.ps(m)?1$' })
        foreach ($file in $psFiles) {
            $full = Join-Path $Root $file
            try {
                $tokens = $null
                $parseErrors = $null
                [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors) | Out-Null
                if (@($parseErrors).Count -eq 0) { $results += New-AdosCheckResult 2 "PowerShell parse: $file" 'PASS' 0 'no parser errors' }
                else { $results += New-AdosCheckResult 2 "PowerShell parse: $file" 'FAIL' 1 ((@($parseErrors | ForEach-Object { $_.Message }) -join '; ')) }
            }
            catch { $results += New-AdosCheckResult 2 "PowerShell parse: $file" 'SKIP' 0 'parser unavailable in the current language mode' }
        }
        $packagePath = Join-Path $Root 'package.json'
        if (Test-Path -LiteralPath $packagePath) {
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
                if ($package.scripts -and $package.scripts.typecheck) {
                    $check = Invoke-AdosCapturedCommand $Root 'npm' @('run','typecheck')
                    $results += New-AdosCheckResult 2 'npm run typecheck' $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
                }
            }
            catch { $results += New-AdosCheckResult 2 'package inspection' 'FAIL' 1 $_.Exception.Message }
        }
    }

    if ($Limit -ge 3) {
        $packagePath = Join-Path $Root 'package.json'
        $focusedCandidates = @($focusedSelection.candidates)
        $canRunFocused = [bool]($focusedSelection.mapCurrent -and $focusedCandidates.Count -gt 0 -and $focusedCandidates.Count -le 12)
        $focusedGroups = @()
        if ($canRunFocused) {
            $focusedGroups = @($focusedCandidates | Group-Object packageRoot)
            foreach ($group in $focusedGroups) {
                $packageRoot = [string]$group.Name
                $workingRoot = if ($packageRoot -eq '.') { $Root } else { Join-Path $Root $packageRoot }
                $testScript = Get-AdosPackageTestScript $workingRoot
                $knownRunner = [bool]($testScript -match '(?i)\b(jest|vitest|mocha|ava|tap)\b|\bnode\s+--test\b|\btsx\b.*--test')
                $supportedFiles = @($group.Group | Where-Object { [string]$_.testFile -match '(?i)\.(ts|tsx|js|jsx|mjs|cjs)$' }).Count -eq @($group.Group).Count
                if (-not $testScript -or -not $knownRunner -or -not $supportedFiles) { $canRunFocused = $false; break }
            }
        }
        if ($canRunFocused) {
            foreach ($group in $focusedGroups) {
                $packageRoot = [string]$group.Name
                $workingRoot = if ($packageRoot -eq '.') { $Root } else { Join-Path $Root $packageRoot }
                $testPaths = @($group.Group | ForEach-Object {
                    $path = [string]$_.testFile
                    if ($packageRoot -ne '.') { $path = $path.Substring($packageRoot.Length) -replace '^[\\/]+','' }
                    $path.Replace('\','/')
                } | Sort-Object -Unique)
                $arguments = @('test','--') + $testPaths
                $check = Invoke-AdosCapturedCommand $workingRoot 'npm' $arguments
                $name = "npm focused tests: $packageRoot ($($testPaths.Count) files)"
                $results += New-AdosCheckResult 3 $name $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
            }
            $focusedExecuted = $true
        }
        else {
            if (-not $focusedSelection.mapCurrent) { $focusedFallback = 'test map missing or stale' }
            elseif ($focusedCandidates.Count -eq 0) { $focusedFallback = 'no associated tests for changed files' }
            elseif ($focusedCandidates.Count -gt 12) { $focusedFallback = 'more than 12 focused tests; full suite is safer' }
            else { $focusedFallback = 'package test runner is not safely recognized for path filtering' }
        }
        if (-not $focusedExecuted -and (Test-Path -LiteralPath $packagePath)) {
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
                if ($package.scripts -and $package.scripts.test) {
                    $check = Invoke-AdosCapturedCommand $Root 'npm' @('test')
                    $results += New-AdosCheckResult 3 'npm test' $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
                }
            }
            catch { }
        }
    }
    if ($Limit -ge 4) {
        $packagePath = Join-Path $Root 'package.json'
        if (Test-Path -LiteralPath $packagePath) {
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
                if ($package.scripts -and $package.scripts.'test:integration') {
                    $check = Invoke-AdosCapturedCommand $Root 'npm' @('run','test:integration')
                    $results += New-AdosCheckResult 4 'npm run test:integration' $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
                }
                elseif ($package.scripts -and $package.scripts.'test:ci') {
                    $check = Invoke-AdosCapturedCommand $Root 'npm' @('run','test:ci')
                    $results += New-AdosCheckResult 4 'npm run test:ci' $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
                }
            }
            catch { }
        }
    }
    if ($Limit -ge 5) {
        $packagePath = Join-Path $Root 'package.json'
        if (Test-Path -LiteralPath $packagePath) {
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
                if ($package.scripts -and $package.scripts.build) {
                    $check = Invoke-AdosCapturedCommand $Root 'npm' @('run','build')
                    $results += New-AdosCheckResult 5 'npm run build' $(if ($check.exitCode -eq 0) {'PASS'} else {'FAIL'}) $check.exitCode $check.output
                }
            }
            catch { }
        }
    }

    $endFingerprint = Get-AdosEvidenceFingerprint $Root
    $repositoryUnchanged = [bool]($inputFingerprint -ceq $endFingerprint)
    $results += New-AdosCheckResult 1 'repository unchanged during verification' $(if ($repositoryUnchanged) {'PASS'} else {'FAIL'}) $(if ($repositoryUnchanged) {0} else {1}) $(if ($repositoryUnchanged) {'input fingerprint preserved'} else {'repository changed while checks were running; review the changes and rerun verification'})
    $timer.Stop()
    $failures = @($results | Where-Object { $_.status -eq 'FAIL' })
    $status = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $payload = [ordered]@{
        schemaVersion = 3
        generated = (Get-Date -Format o)
        head = $head
        branch = $branch
        evidenceFingerprint = $inputFingerprint
        endEvidenceFingerprint = $endFingerprint
        repositoryUnchanged = $repositoryUnchanged
        status = $status
        maxLevel = $Limit
        durationMs = $timer.ElapsedMilliseconds
        focusedTests = [ordered]@{
            mapCurrent = [bool]$focusedSelection.mapCurrent
            candidates = @($focusedSelection.candidates)
            executed = $focusedExecuted
            fallback = $focusedFallback
        }
        checks = @($results)
    }
    $jsonPath = Join-Path $Root '.ai\evidence\verification.generated.json'
    Write-AdosJson $jsonPath $payload 8
    $lines = @('# ADOS verification ladder','',"Status: $status","Maximum level: $Limit","Duration ms: $($timer.ElapsedMilliseconds)",'','| Level | Check | Status |','|---:|---|---|')
    foreach ($result in $results) { $lines += "| $($result.level) | $($result.name.Replace('|','/')) | $($result.status) |" }
    if ($results.Count -eq 0) { $lines += '| 1 | no checks detected | SKIP |' }
    Write-AdosUtf8 (Join-Path $Root '.ai\evidence\verification.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'verification-ladder' $status $timer.ElapsedMilliseconds 0 0 @{ maxLevel=$Limit; checks=$results.Count; failures=$failures.Count }
    Write-Host "Verification ladder: $status ($($results.Count) checks through level $Limit)"
    return $payload
}

function Test-AdosSecretDiff {
    param([string]$Root)

    Push-Location $Root
    try {
        $secretPattern = '(?i)(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[0-9A-Z]{16}\b|(?:secret|token|password|api[_-]?key)\s*[:=]\s*["''][^"'']{8,})'
        $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
        $diffText = @()
        if ($checkpoint -and $checkpoint.head -and [string]$checkpoint.head -ne (Get-AdosHead $Root)) {
            $diffText += (& git -c core.safecrlf=false diff --no-ext-diff --unified=0 ([string]$checkpoint.head + '..HEAD') 2>$null | Out-String)
        }
        $diffText += (& git -c core.safecrlf=false diff --no-ext-diff --unified=0 2>$null | Out-String)
        $diffText += (& git -c core.safecrlf=false diff --cached --no-ext-diff --unified=0 2>$null | Out-String)
        $diff = ($diffText -join "`n")
        $added = @($diff -split "`r?`n" | Where-Object { $_ -match '^\+[^+]' }) -join "`n"
        if ($added -match $secretPattern) { return $true }
        $untracked = @(& git ls-files --others --exclude-standard 2>$null)
        foreach ($relative in $untracked) {
            $candidate = Join-Path $Root ([string]$relative)
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            $item = Get-Item -LiteralPath $candidate
            if ($item.Length -gt 2097152) { continue }
            $content = Get-Content -LiteralPath $candidate -Raw -ErrorAction SilentlyContinue
            if ($content -match $secretPattern) { return $true }
        }
        return $false
    }
    finally { Pop-Location }
}

function Invoke-AdosEvidenceGate {
    param([string]$Root, [bool]$MustHaveDiff)

    $head = Get-AdosHead $Root
    $branch = Get-AdosBranch $Root
    $fingerprint = Get-AdosEvidenceFingerprint $Root
    $files = @(Get-AdosEvidenceFiles $Root)
    $verification = Read-AdosJson (Join-Path $Root '.ai\evidence\verification.generated.json') $null
    $scope = Read-AdosJson (Join-Path $Root '.ai\evidence\scope-guard.generated.json') $null
    $hasDiff = $files.Count -gt 0
    $verificationPassed = [bool]($verification -and [string]$verification.status -eq 'PASS')
    $scopePassed = [bool]($scope -and [string]$scope.status -eq 'PASS')
    $verificationCurrent = Test-AdosVerificationState $verification $head $branch $fingerprint
    $scopeCurrent = Test-AdosVerificationState $scope $head $branch $fingerprint
    $secretDetected = Test-AdosSecretDiff $Root
    $repositoryUnchanged = [bool]($fingerprint -ceq (Get-AdosEvidenceFingerprint $Root))
    $requirements = @(
        [pscustomobject]@{ name='diff present'; passed=([bool]($hasDiff -or -not $MustHaveDiff)); detail="$($files.Count) files" },
        [pscustomobject]@{ name='verification observed'; passed=$verificationPassed; detail=$(if ($verification) {[string]$verification.status} else {'missing'}) },
        [pscustomobject]@{ name='verification matches repository state'; passed=$verificationCurrent; detail=$(if ($verificationCurrent) {'current'} else {'missing or stale input fingerprint; rerun verification'}) },
        [pscustomobject]@{ name='scope guard passed'; passed=$scopePassed; detail=$(if ($scope) {[string]$scope.status} else {'missing'}) },
        [pscustomobject]@{ name='scope matches repository state'; passed=$scopeCurrent; detail=$(if ($scopeCurrent) {'current'} else {'missing or stale input fingerprint; rerun scope guard'}) },
        [pscustomobject]@{ name='repository unchanged during evidence gate'; passed=$repositoryUnchanged; detail=$(if ($repositoryUnchanged) {'stable'} else {'changed while evaluating the gate'}) },
        [pscustomobject]@{ name='no secret pattern in added diff'; passed=(-not $secretDetected); detail=$(if ($secretDetected) {'candidate detected'} else {'none'}) }
    )
    $failed = @($requirements | Where-Object { -not $_.passed })
    $status = if ($failed.Count -eq 0) { 'VERIFIED' } else { 'UNVERIFIED' }
    $payload = [ordered]@{
        schemaVersion = 3
        generated = (Get-Date -Format o)
        status = $status
        requireDiff = $MustHaveDiff
        branch = $branch
        head = $head
        evidenceFingerprint = $fingerprint
        inputsCurrent = [bool]($verificationCurrent -and $scopeCurrent -and $repositoryUnchanged)
        evidenceFiles = @($files)
        requirements = @($requirements)
    }
    $jsonPath = Join-Path $Root '.ai\evidence\evidence-gate.generated.json'
    Write-AdosJson $jsonPath $payload 8
    $lines = @('# ADOS evidence gate','',"Status: $status",'', '| Requirement | Result | Detail |','|---|---|---|')
    foreach ($item in $requirements) { $lines += "| $($item.name) | $(if ($item.passed) {'PASS'} else {'FAIL'}) | $($item.detail) |" }
    Write-AdosUtf8 (Join-Path $Root '.ai\evidence\evidence-gate.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'evidence-gate' $status 0 0 0 @{ requirements=$requirements.Count; failed=$failed.Count }
    Write-Host "Evidence gate: $status"
    return $payload
}

function ConvertTo-AdosPrTableCell {
    param($Value)
    return (([string]$Value) -replace '[\r\n]+', ' ' -replace '\|', '/').Trim()
}

function Write-AdosPrEvidenceSummary {
    param([string]$Root, [string]$TaskText)

    $gate = Read-AdosJson (Join-Path $Root '.ai\evidence\evidence-gate.generated.json') $null
    $scope = Read-AdosJson (Join-Path $Root '.ai\evidence\scope-guard.generated.json') $null
    $verification = Read-AdosJson (Join-Path $Root '.ai\evidence\verification.generated.json') $null
    $checkpoint = Read-AdosJson (Join-Path $Root '.ai\checkpoints\current.json') $null
    $benchmark = Read-AdosJson (Join-Path $Root '.ai\analytics\ab-benchmark.generated.json') $null
    $elastic = Read-AdosJson (Join-Path $Root '.ai\context\elastic-context.generated.json') $null

    if (-not $TaskText -and $checkpoint -and $checkpoint.task) { $TaskText = [string]$checkpoint.task }
    $branch = Get-AdosBranch $Root
    $head = Get-AdosHead $Root
    $currentFingerprint = Get-AdosEvidenceFingerprint $Root
    $gateFingerprint = ''
    if ($gate -and @($gate.PSObject.Properties.Name) -contains 'evidenceFingerprint') {
        $gateFingerprint = [string]$gate.evidenceFingerprint
    }
    $evidenceCurrent = Test-AdosEvidenceGateCurrent $gate $verification $scope $head $branch $currentFingerprint
    $gateHasCurrentInputs = [bool]($gate -and @($gate.PSObject.Properties.Name) -contains 'inputsCurrent' -and
        $gate.inputsCurrent -is [bool] -and $gate.inputsCurrent)
    $gateVerified = [bool]($gate -and [string]$gate.status -eq 'VERIFIED' -and $gateHasCurrentInputs)
    $status = if ($gateVerified -and $evidenceCurrent) { 'READY' } else { 'NOT_READY' }
    $reason = if (-not $gate) { 'Evidence Gate has not run.' }
        elseif (-not $gateVerified) { 'Evidence Gate is not VERIFIED with current input evidence.' }
        elseif (-not $evidenceCurrent) { 'Repository state or verification inputs changed after Evidence Gate.' }
        else { 'Evidence Gate is VERIFIED and matches the current repository state.' }

    $files = @(Get-AdosEvidenceFiles $Root)
    $scopeOutside = @()
    if ($scope -and $scope.outsideScope) { $scopeOutside = @($scope.outsideScope) }
    $scopeProtected = @()
    if ($scope -and $scope.protectedFiles) { $scopeProtected = @($scope.protectedFiles) }
    $checks = @()
    if ($verification -and $verification.checks) { $checks = @($verification.checks) }
    $passedChecks = @($checks | Where-Object { [string]$_.status -eq 'PASS' }).Count
    $failedChecks = @($checks | Where-Object { [string]$_.status -eq 'FAIL' }).Count
    $skippedChecks = @($checks | Where-Object { [string]$_.status -eq 'SKIP' }).Count
    $focusedTests = [ordered]@{ mapCurrent=$false; candidates=@(); executed=$false; fallback='' }
    if ($verification -and @($verification.PSObject.Properties.Name) -contains 'focusedTests' -and $verification.focusedTests) {
        $focusedTests = $verification.focusedTests
    }
    $requirements = @()
    if ($gate -and $gate.requirements) { $requirements = @($gate.requirements) }

    $benchmarkSummary = $null
    if ($benchmark) {
        $benchmarkSummary = [ordered]@{
            contextByteReductionPercent = $benchmark.contextByteReductionPercent
            baselineRelevanceDensity = $benchmark.A.relevanceDensity
            elasticRelevanceDensity = $benchmark.B.relevanceDensity
        }
    }
    $contextSummary = $null
    if ($elastic) {
        $contextSummary = [ordered]@{
            tier = $elastic.tier
            selectedBytes = $elastic.selectedBytes
            budgetBytes = $elastic.budgetBytes
            duplicateBytesAvoided = $(if (@($elastic.PSObject.Properties.Name) -contains 'duplicateBytesAvoided') { $elastic.duplicateBytesAvoided } else { 0 })
        }
    }

    $payload = [ordered]@{
        schemaVersion = 2
        generated = (Get-Date -Format o)
        status = $status
        reason = $reason
        task = $TaskText
        branch = $branch
        head = $head
        evidenceCurrent = $evidenceCurrent
        evidenceFingerprint = $gateFingerprint
        currentFingerprint = $currentFingerprint
        evidenceGate = $(if ($gate) { [string]$gate.status } else { 'MISSING' })
        changedFiles = @($files)
        scope = [ordered]@{
            status = $(if ($scope) { [string]$scope.status } else { 'MISSING' })
            outsideScope = @($scopeOutside)
            protectedFiles = @($scopeProtected)
        }
        verification = [ordered]@{
            status = $(if ($verification) { [string]$verification.status } else { 'MISSING' })
            maxLevel = $(if ($verification) { $verification.maxLevel } else { 0 })
            durationMs = $(if ($verification) { $verification.durationMs } else { 0 })
            passed = $passedChecks
            failed = $failedChecks
            skipped = $skippedChecks
            focusedTests = $focusedTests
            checks = @($checks)
        }
        requirements = @($requirements)
        benchmark = $benchmarkSummary
        context = $contextSummary
        safety = 'Deterministic local summary; no model or paid API was called.'
    }
    Write-AdosJson (Join-Path $Root '.ai\evidence\pr-evidence-summary.generated.json') $payload 10

    $shortHead = if ($head.Length -gt 12) { $head.Substring(0, 12) } else { $head }
    $lines = @(
        '## ADOS evidence summary','',
        "**Status:** $status", "**Evidence current:** $evidenceCurrent", "**Evidence Gate:** $($payload.evidenceGate)",
        "**Branch / HEAD:** ``$branch`` / ``$shortHead``", "**Task:** $(ConvertTo-AdosPrTableCell $TaskText)",'',
        $reason,'','### Scope','',
        "- Changed files: $($files.Count)",
        "- Scope Guard: $($payload.scope.status)",
        "- Outside allowed scope: $($scopeOutside.Count)",
        "- Protected files: $($scopeProtected.Count)",'','### Verification','',
        "- Result: $($payload.verification.status)",
        "- Maximum level: $($payload.verification.maxLevel)",
        "- Checks: $passedChecks passed, $failedChecks failed, $skippedChecks skipped",
        "- Focused tests executed: $([bool]$focusedTests.executed)",
        "- Focused candidates: $(@($focusedTests.candidates).Count)",'',
        '| Level | Check | Result |','|---:|---|---|'
    )
    foreach ($check in @($checks | Select-Object -First 50)) {
        $lines += "| $($check.level) | $(ConvertTo-AdosPrTableCell $check.name) | $(ConvertTo-AdosPrTableCell $check.status) |"
    }
    if ($checks.Count -eq 0) { $lines += '| - | No verification checks recorded | MISSING |' }
    if ($checks.Count -gt 50) { $lines += "| - | $($checks.Count - 50) additional checks omitted | INFO |" }
    $lines += @('','### Evidence Gate','', '| Requirement | Result | Detail |','|---|---|---|')
    foreach ($requirement in $requirements) {
        $result = if ([bool]$requirement.passed) { 'PASS' } else { 'FAIL' }
        $lines += "| $(ConvertTo-AdosPrTableCell $requirement.name) | $result | $(ConvertTo-AdosPrTableCell $requirement.detail) |"
    }
    if ($requirements.Count -eq 0) { $lines += '| Evidence Gate output | FAIL | missing |' }
    $lines += @('','### Changed files','')
    $listedFiles = @($files | Select-Object -First 50)
    $lines += ConvertTo-AdosMarkdownList $listedFiles
    if ($files.Count -gt 50) { $lines += "- ... $($files.Count - 50) additional files omitted" }
    if ($benchmarkSummary) {
        $lines += @('','### Context efficiency','',
            "- Context byte reduction: $($benchmarkSummary.contextByteReductionPercent)%",
            "- Relevance density: $($benchmarkSummary.baselineRelevanceDensity) -> $($benchmarkSummary.elasticRelevanceDensity)")
    }
    if ($contextSummary) {
        $lines += "- Duplicate bytes avoided: $($contextSummary.duplicateBytesAvoided)"
    }
    $lines += @('','_Generated locally from ADOS evidence artifacts. No model or paid API was called._')
    Write-AdosUtf8 (Join-Path $Root '.ai\evidence\pr-evidence-summary.generated.md') ($lines -join "`r`n")
    Add-AdosUsageEvent $Root 'pr-evidence-summary' $status 0 0 0 @{ evidenceCurrent=$evidenceCurrent; files=$files.Count; checks=$checks.Count }
    Write-Host "PR evidence summary: $status (current: $evidenceCurrent)"
    return $payload
}

$root = Resolve-AdosRepoRoot $ProjectPath
Ensure-AdosLocalExclude $root
switch ($Command) {
    'fingerprint' { $null = Invoke-AdosFingerprint $root $ErrorText $LogPath $Task }
    'compress' { $null = Invoke-AdosLogCompressor $root $LogPath }
    'scope' { $null = Invoke-AdosScopeGuard $root $Task $AllowedScope }
    'verify' { $null = Invoke-AdosVerification $root $MaxLevel }
    'evidence' {
        $null = Invoke-AdosEvidenceGate $root $RequireDiff
        $null = Write-AdosPrEvidenceSummary $root $Task
    }
    'pr-summary' { $null = Write-AdosPrEvidenceSummary $root $Task }
    'all' {
        if ($LogPath) {
            $compressed = Invoke-AdosLogCompressor $root $LogPath
            $null = Invoke-AdosFingerprint $root (($compressed.rootBlock) -join "`n") '' $Task
        }
        $null = Invoke-AdosScopeGuard $root $Task $AllowedScope
        $null = Invoke-AdosVerification $root $MaxLevel
        $null = Invoke-AdosEvidenceGate $root $RequireDiff
        $null = Write-AdosPrEvidenceSummary $root $Task
    }
}
