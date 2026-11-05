[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('search','draft','validate')]
    [string]$Command,
    [string]$ProjectPath = '.',
    [string]$Task = '',
    [string[]]$Stack = @(),
    [ValidateRange(1,5)]
    [int]$Limit = 3,
    [string]$KnowledgeRoot = '',
    [string]$RecordPath = '',
    [ValidateSet('solution','anti-pattern','component','design','decision')]
    [string]$Kind = 'solution',
    [string]$Title = '',
    [string]$Problem = '',
    [string]$Resolution = '',
    [string]$Applicability = '',
    [string]$DoNotUseWhen = '',
    [string]$Evidence = ''
)

$ErrorActionPreference = 'Stop'
$encoding = New-Object System.Text.UTF8Encoding($false)
if (-not $KnowledgeRoot) {
    $KnowledgeRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'knowledge\entries'
}

function Get-KbTerms([string]$Value) {
    $terms = @([regex]::Matches($Value.ToLowerInvariant(), '[\p{L}\p{Nd}][\p{L}\p{Nd}_-]{2,}') |
        ForEach-Object { $_.Value } | Sort-Object -Unique)
    return $terms
}

function Test-KbDate([string]$Value) {
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed
    )
}

function Assert-KbSafeText([string]$Value) {
    if ($Value.Length -gt 12000) { throw 'Knowledge text exceeds the safety length limit.' }
    $sensitivePatterns = @(
        '(?i)\b(?:sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b',
        '(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b',
        '(?i)(?:[a-z]:\\users\\|/users/|/home/)[^ \r\n]+',
        '(?i)\b(?:password|api[_-]?key|secret|access[_-]?token)\s*[:=]\s*["'']?[^\s"'']{8,}'
    )
    foreach ($pattern in $sensitivePatterns) {
        if ($Value -match $pattern) {
            throw 'Potential credential, email address, or private home path in knowledge text. Review and sanitize manually.'
        }
    }
}

function Assert-KbRecord($Record, [bool]$AllowCandidate) {
    if (-not $Record -or [int]$Record.schemaVersion -ne 1) { throw 'Unsupported knowledge schema version.' }
    if (@('solution','anti-pattern','component','design','decision') -notcontains [string]$Record.kind) {
        throw 'Invalid knowledge kind.'
    }
    $status = [string]$Record.status
    if ($status -ne 'verified' -and -not ($AllowCandidate -and $status -eq 'candidate')) {
        throw 'Knowledge record is not verified.'
    }
    if ($status -eq 'verified' -and [string]$Record.id -notmatch '^DC-KB-[0-9]{4,}$') {
        throw 'Verified record requires a reviewed DC-KB identifier.'
    }
    if ($status -eq 'candidate' -and [string]$Record.id -notmatch '^DC-CAND-[a-f0-9]{12}$') {
        throw 'Candidate record has an invalid identifier.'
    }
    foreach ($field in @('title','problem','resolution','applicability','doNotUseWhen')) {
        $value = [string]$Record.$field
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 1500) {
            throw "Missing or oversized field: $field"
        }
    }
    foreach ($field in @('stacks','tags')) {
        if ($null -eq $Record.$field -or @($Record.$field).Count -gt 20) {
            throw "Missing or oversized list: $field"
        }
    }
    if ($status -eq 'verified') {
        if (-not (Test-KbDate ([string]$Record.lastVerified))) {
            throw 'Verified knowledge must have a valid lastVerified date.'
        }
        if (@($Record.evidence).Count -lt 1) { throw 'Verified knowledge requires evidence.' }
        foreach ($proof in @($Record.evidence)) {
            if ([string]$proof.status -ne 'passed' -or [string]::IsNullOrWhiteSpace([string]$proof.reference)) {
                throw 'Verified knowledge requires concrete passed evidence references.'
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.expiresOn) -and
        -not (Test-KbDate ([string]$Record.expiresOn))) {
        throw 'Invalid expiresOn date.'
    }
    Assert-KbSafeText ($Record | ConvertTo-Json -Depth 10 -Compress)
}

function Get-KbScore($Record, [string[]]$Terms) {
    $score = 0
    $titleText = ([string]$Record.title).ToLowerInvariant()
    $problemText = ([string]$Record.problem).ToLowerInvariant()
    $conditionText = ([string]$Record.applicability).ToLowerInvariant()
    $tagTexts = @($Record.tags | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($term in $Terms) {
        if ($titleText.Contains($term)) { $score += 5 }
        if ($tagTexts -contains $term) { $score += 4 }
        if ($problemText.Contains($term)) { $score += 3 }
        if ($conditionText.Contains($term)) { $score += 1 }
    }
    return $score
}

function Get-KbExcerpt([string]$Value, [int]$Max = 220) {
    $plain = ($Value -replace '[\r\n\t]+', ' ').Trim()
    if ($plain.Length -gt $Max) { return $plain.Substring(0, $Max) + '...' }
    return $plain
}

function Invoke-KbSearch {
    if ([string]::IsNullOrWhiteSpace($Task)) { throw 'Task is required for knowledge search.' }
    $project = (Resolve-Path -LiteralPath $ProjectPath).Path
    $terms = @(Get-KbTerms $Task)
    $requestedStacks = @($Stack | ForEach-Object { ([string]$_).ToLowerInvariant().Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)
    $matches = @()
    if (Test-Path -LiteralPath $KnowledgeRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $KnowledgeRoot -File -Filter '*.json' | Sort-Object Name)) {
            try {
                $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                Assert-KbRecord $record $false
            }
            catch {
                Write-Warning ("Skipping invalid reviewed entry {0}: {1}" -f $file.Name,$_.Exception.Message)
                continue
            }
            if ($record.expiresOn -and [string]$record.expiresOn -lt (Get-Date -Format 'yyyy-MM-dd')) {
                continue
            }
            $recordStacks = @($record.stacks | ForEach-Object { ([string]$_).ToLowerInvariant().Trim() })
            if ($requestedStacks.Count -gt 0 -and $recordStacks.Count -gt 0 -and
                @($requestedStacks | Where-Object { $recordStacks -contains $_ }).Count -eq 0) {
                continue
            }
            $score = Get-KbScore $record $terms
            if ($score -gt 0) { $matches += [pscustomobject]@{ score=$score; entry=$record } }
        }
    }
    $chosen = @($matches | Sort-Object @{Expression='score';Descending=$true},
        @{Expression={ [string]$_.entry.id };Descending=$false} | Select-Object -First $Limit)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Cross-project knowledge (reviewed advisory context)')
    $lines.Add('')
    $lines.Add('Knowledge is not authority: check applicability, versions, source, and current tests before reuse.')
    $lines.Add('Only explicitly reviewed DevCore entries appear here; local project memory remains separate.')
    $lines.Add('')
    if ($chosen.Count -eq 0) {
        $lines.Add('No relevant, reviewed cross-project knowledge found.')
    }
    else {
        foreach ($match in $chosen) {
            $e = $match.entry
            $lines.Add(('## {0} [{1}]' -f (Get-KbExcerpt ([string]$e.title) 100),[string]$e.id))
            $lines.Add(('Type: {0}; verified: {1}; stacks: {2}' -f $e.kind,$e.lastVerified,(@($e.stacks) -join ', ')))
            $lines.Add('Problem: ' + (Get-KbExcerpt ([string]$e.problem)))
            $lines.Add('Approach: ' + (Get-KbExcerpt ([string]$e.resolution)))
            $lines.Add('Applicable: ' + (Get-KbExcerpt ([string]$e.applicability)))
            $lines.Add('Do not use when: ' + (Get-KbExcerpt ([string]$e.doNotUseWhen)))
            $lines.Add('Evidence: ' + (Get-KbExcerpt ((@($e.evidence) | ForEach-Object { [string]$_.reference }) -join ', ') 170))
            $lines.Add('')
        }
    }
    $out = Join-Path $project '.ai\context\shared-knowledge.generated.md'
    $parent = Split-Path -Parent $out
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($out,($lines -join [Environment]::NewLine),$encoding)
    Write-Host ("Shared knowledge: {0} reviewed match(es), {1}" -f $chosen.Count,$out)
}

function Invoke-KbDraft {
    foreach ($field in @('Title','Problem','Resolution','Applicability','DoNotUseWhen','Evidence')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name $field -ValueOnly))) {
            throw "$field is required for a draft."
        }
    }
    $project = (Resolve-Path -LiteralPath $ProjectPath).Path
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $encoding.GetBytes(($Title.Trim() + '|' + $Problem.Trim()).ToLowerInvariant())
        $digest = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
    }
    finally { $hash.Dispose() }
    $id = 'DC-CAND-' + $digest.Substring(0,12)
    $candidate = [ordered]@{
        schemaVersion=1; id=$id; kind=$Kind; status='candidate'
        title=$Title.Trim(); problem=$Problem.Trim(); resolution=$Resolution.Trim()
        applicability=$Applicability.Trim(); doNotUseWhen=$DoNotUseWhen.Trim()
        stacks=@($Stack); tags=@(); lastVerified=$null; expiresOn=$null
        evidence=@(@{kind='candidate-note';reference=$Evidence.Trim();status='unverified'})
    }
    Assert-KbRecord ([pscustomobject]$candidate) $true
    $directory = Join-Path $project '.ai\local-output\knowledge-candidates'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $out = Join-Path $directory ($id + '.json')
    if (Test-Path -LiteralPath $out) {
        throw 'A draft with this problem already exists. Review it rather than overwrite.'
    }
    $json = $candidate | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($out,$json,$encoding)
    Write-Host "Local unverified draft created: $out"
    Write-Host 'Nothing was promoted, committed, uploaded, or published.'
}

switch ($Command) {
    'search' { Invoke-KbSearch }
    'draft' { Invoke-KbDraft }
    'validate' {
        if (-not $RecordPath) { throw 'RecordPath is required for validation.' }
        $record = Get-Content -LiteralPath $RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-KbRecord $record $true
        Write-Host ("Knowledge record VALID ({0}); manual evidence and privacy review still required." -f $record.status)
    }
}
