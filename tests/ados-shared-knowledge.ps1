$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tool = Join-Path $RepoRoot 'scripts\ados-shared-knowledge.ps1'
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('ados-knowledge-' + [guid]::NewGuid().ToString('N'))
$Project = Join-Path $Fixture 'project'
$Library = Join-Path $Fixture 'knowledge'
$Failures = 0
$encoding = New-Object Text.UTF8Encoding($false)

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Failures++
}
function Write-JsonFile([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 9),$encoding)
}
function Make-Entry([string]$Id,[string]$Title,[string]$Stack,[string]$Expiry) {
    return [ordered]@{
        schemaVersion=1
        id=$Id
        kind='solution'
        status='verified'
        title=$Title
        problem='Authentication navigation restore race after cold start'
        resolution='Wait for a resolved authentication state before navigation'
        applicability='Same lifecycle and relevant library versions'
        doNotUseWhen='The authentication state lifecycle differs'
        stacks=@($Stack)
        tags=@('auth','navigation')
        lastVerified='2026-11-05'
        expiresOn=$Expiry
        evidence=@(@{kind='public-ci';reference='https://github.com/example/public/actions/runs/123';status='passed'})
    }
}

New-Item -ItemType Directory -Path $Project,$Library -Force | Out-Null
try {
    Write-JsonFile (Join-Path $Library '01-expo.json') (Make-Entry 'DC-KB-0001' 'Expo navigation auth restore' 'expo' $null)
    Write-JsonFile (Join-Path $Library '02-python.json') (Make-Entry 'DC-KB-0002' 'Python auth session navigation' 'python' $null)
    Write-JsonFile (Join-Path $Library '03-expired.json') (Make-Entry 'DC-KB-0003' 'Expo old navigation workaround' 'expo' '2020-01-01')
    $candidate = Make-Entry 'DC-KB-0004' 'Expo unverified navigation shortcut' 'expo' $null
    $candidate.status = 'candidate'
    Write-JsonFile (Join-Path $Library '04-candidate.json') $candidate

    $digestBefore = (Get-FileHash -LiteralPath (Join-Path $Library '01-expo.json') -Algorithm SHA256).Hash
    & $Tool search -ProjectPath $Project -KnowledgeRoot $Library -Task 'Expo navigation auth restore' -Stack expo -Limit 3
    $resultFile = Join-Path $Project '.ai\context\shared-knowledge.generated.md'
    $report = Get-Content -LiteralPath $resultFile -Raw
    Assert-True ($report -match 'DC-KB-0001') 'matching reviewed Expo solution must be retrieved'
    Assert-True ($report -notmatch 'DC-KB-0002') 'incompatible stack must not be retrieved'
    Assert-True ($report -notmatch 'DC-KB-0003') 'expired solution must not be retrieved'
    Assert-True ($report -notmatch 'DC-KB-0004') 'candidate must not be retrieved'
    & $Tool search -ProjectPath $Project -KnowledgeRoot $Library -Task 'Expo navigation auth restore' -Limit 3
    $inferred = Get-Content -LiteralPath $resultFile -Raw
    Assert-True ($inferred -notmatch 'DC-KB-0002') 'explicit technology in task must infer a safe stack filter'
    Assert-True ($report.Length -lt 3200) 'retrieved context must remain bounded'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $Library '01-expo.json') -Algorithm SHA256).Hash -eq $digestBefore) 'search must not mutate reviewed catalog'

    & $Tool search -ProjectPath $Project -KnowledgeRoot $Library -Task 'Python auth navigation' -Stack python -Limit 1
    $report = Get-Content -LiteralPath $resultFile -Raw
    Assert-True ($report -match 'DC-KB-0002') 'other stack match must be retrieved on request'
    Assert-True ($report -notmatch 'DC-KB-0001') 'limit and stack must be respected'

    Write-JsonFile (Join-Path $Library '05-duplicate.json') (Make-Entry 'DC-KB-0001' 'Conflicting navigation repair' 'expo' $null)
    & $Tool search -ProjectPath $Project -KnowledgeRoot $Library -Task 'Expo navigation auth restore' -Stack expo
    $duplicateReport = Get-Content -LiteralPath $resultFile -Raw
    Assert-True ($duplicateReport -notmatch 'DC-KB-0001') 'conflicting duplicate IDs must not be recommended'
    Remove-Item -LiteralPath (Join-Path $Library '05-duplicate.json') -Force

    & $Tool search -ProjectPath $Project -KnowledgeRoot $Library -Task 'unrelated zygomorphic engine' -Limit 3
    $report = Get-Content -LiteralPath $resultFile -Raw
    Assert-True ($report -match 'No relevant, reviewed') 'a new empty search must not reuse stale results'

    $draftArgs = @{
        ProjectPath=$Project; Title='Mobile navigation re-entry'; Problem='Navigation race after auth restore'
        Resolution='Defer the route until the initial session is resolved'
        Applicability='Projects using this router and session lifecycle'
        DoNotUseWhen='Different state management or router lifecycle'
        Evidence='Reproduction, local regression test and a human reviewer are needed'
        Stack=@('expo')
    }
    Push-Location $Project
    try { & git init -q }
    finally { Pop-Location }
    $threw = $false
    try { & $Tool draft @draftArgs } catch { $threw = $true }
    Assert-True $threw 'a draft without Git ignore protection must be blocked'
    [IO.File]::WriteAllText((Join-Path $Project '.gitignore'),'.ai/' + [Environment]::NewLine,$encoding)
    & $Tool draft @draftArgs
    $drafts = @(Get-ChildItem -LiteralPath (Join-Path $Project '.ai\local-output\knowledge-candidates') -Filter '*.json')
    Assert-True ($drafts.Count -eq 1) 'draft must create exactly one local candidate'
    $draft = Get-Content -LiteralPath $drafts[0].FullName -Raw | ConvertFrom-Json
    Assert-True ($draft.status -eq 'candidate') 'draft must remain unverified regardless of evidence text'
    Assert-True ($draft.id -match '^DC-CAND-[a-f0-9]{12}$') 'draft ID must be stable and bounded'
    & $Tool validate -RecordPath $drafts[0].FullName

    $threw = $false
    try { & $Tool draft @draftArgs } catch { $threw = $true }
    Assert-True $threw 'same draft must not be silently overwritten'

    $threw = $false
    try {
        $unsafe = $draftArgs.Clone()
        $unsafe.Resolution = 'Send sk-' + ('a' * 22) + ' to the endpoint'
        & $Tool draft @unsafe
    } catch { $threw = $true }
    Assert-True $threw 'credential-like text must be blocked from local drafts'

    $threw = $false
    try {
        $invalid = Make-Entry 'DC-KB-0005' 'Unsupported claim' 'expo' $null
        $invalid.evidence = @(@{kind='test';reference='unverified impression';status='unverified'})
        $badPath = Join-Path $Fixture 'invalid.json'
        Write-JsonFile $badPath $invalid
        & $Tool validate -RecordPath $badPath
    } catch { $threw = $true }
    Assert-True $threw 'a verified entry without passed evidence must fail validation'

    Write-Host ("Shared knowledge tests: {0} assertions PASS" -f $Failures)
}
finally {
    if (Test-Path -LiteralPath $Fixture) {
        Remove-Item -LiteralPath $Fixture -Recurse -Force
    }
}
