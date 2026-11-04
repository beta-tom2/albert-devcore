[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$devcoreRoot=Split-Path -Parent $PSScriptRoot
$stateScript=Join-Path $devcoreRoot 'scripts/ados-state.ps1'
. (Join-Path $devcoreRoot 'scripts/ados-common.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ados-state-' + [guid]::NewGuid().ToString('N'))
$passed=0

function Assert-StateTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

function Expect-StateFailure {
    param([scriptblock]$Action,[string]$Pattern,[string]$Message)
    $failed=$false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected failure for $Message`: $($_.Exception.Message)" }
        $failed=$true
    }
    Assert-StateTest $failed $Message
}

function Invoke-StateGit {
    param([string[]]$Arguments)
    $result=@(& git -C $testRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed: $($result -join ' ')" }
    return (($result | Out-String).Trim())
}

try {
    Ensure-AdosDirectory $testRoot
    $null=Invoke-StateGit @('init','-b','main')
    $null=Invoke-StateGit @('config','user.name','ADOS State Fixture')
    $null=Invoke-StateGit @('config','user.email','ados-state-fixture@example.invalid')
    $null=Invoke-StateGit @('config','core.autocrlf','false')
    $null=Invoke-StateGit @('remote','add','origin','https://github.com/fixture/project.git')
    Write-AdosUtf8 (Join-Path $testRoot 'README.md') "# Fixture`nPRIVATE DOCUMENT BODY MUST NOT BE COPIED`n"
    Write-AdosUtf8 (Join-Path $testRoot 'AGENTS.md') "# Fixture rules`nSynthetic test content.`n"
    $config=[ordered]@{ schemaVersion=1; projectId='FIXTURE'; repository=[ordered]@{fullName='fixture/project';visibility='private'}; sources=@('AGENTS.md','README.md'); includeTaskSummary=$false }
    $configPath=Join-Path $testRoot '.ados/state-export.json'
    Write-AdosJson $configPath $config
    $null=Invoke-StateGit @('add','AGENTS.md','README.md','.ados/state-export.json')
    $null=Invoke-StateGit @('commit','-m','Create synthetic state fixture')
    Ensure-AdosLocalExclude $testRoot
    $output=Join-Path $testRoot '.ai/local-output/project-state.json'

    & $stateScript export -ProjectPath $testRoot
    & $stateScript validate -SnapshotPath $output
    $snapshot=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    $readmeHash=($snapshot.sources | Where-Object { $_.path -eq 'README.md' }).sha256
    Assert-StateTest ($snapshot.evidence.status -eq 'MISSING' -and -not $snapshot.evidence.current) 'missing evidence is not verified'
    Assert-StateTest ($null -eq $snapshot.checkpoint -and $snapshot.sources.Count -eq 2) 'explicit sources and missing checkpoint survive export'
    $text=Get-Content -LiteralPath $output -Raw
    Assert-StateTest (-not $text.Contains('PRIVATE DOCUMENT BODY') -and -not $text.Contains($testRoot)) 'export contains neither source bodies nor absolute local paths'
    Assert-StateTest (-not $snapshot.source.worktreeDirty) 'ignored export does not dirty product worktree'

    $originalHash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot } 'replacement hash|Snapshot changed' 'replacement requires observed SHA-256'
    Assert-StateTest ((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant() -eq $originalHash) 'rejected replacement preserves original bytes'

    $head=Get-AdosHead $testRoot
    $checkpointPath=Join-Path $testRoot '.ai/checkpoints/current.json'
    $saved=[ordered]@{taskId='FIXTURE-1';task='Preserve a durable task handoff';phase='verification';branch='main';head=$head;generated=[datetimeoffset]::UtcNow.AddSeconds(-10).ToString('o')}
    Write-AdosJson $checkpointPath $saved
    $gatePath=Join-Path $testRoot '.ai/evidence/evidence-gate.generated.json'
    $fingerprint=Get-AdosEvidenceFingerprint $testRoot
    $verificationPath=Join-Path $testRoot '.ai/evidence/verification.generated.json'
    $scopePath=Join-Path $testRoot '.ai/evidence/scope-guard.generated.json'
    $verification=[ordered]@{status='PASS';head=$head;branch='main';generated=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o');evidenceFingerprint=$fingerprint;endEvidenceFingerprint=$fingerprint;repositoryUnchanged=$true}
    $scope=[ordered]@{status='PASS';task=$saved.task;head=$head;branch='main';generated=[datetimeoffset]::UtcNow.AddSeconds(-1).ToString('o');evidenceFingerprint=$fingerprint;endEvidenceFingerprint=$fingerprint;repositoryUnchanged=$true}
    Write-AdosJson $verificationPath $verification
    Write-AdosJson $scopePath $scope
    $gate=[ordered]@{status='VERIFIED';head=$head;branch='main';generated=[datetimeoffset]::UtcNow.ToString('o');evidenceFingerprint=$fingerprint;inputsCurrent=$true}
    Write-AdosJson $gatePath $gate
    & $stateScript export -ProjectPath $testRoot -ExpectedSnapshotSha256 $originalHash
    $snapshot=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    Assert-StateTest ($snapshot.evidence.current -and $null -eq $snapshot.checkpoint.summary) 'matching task evidence is current and summary stays opt-in'

    $gate.Remove('inputsCurrent')
    Write-AdosJson $gatePath $gate
    & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/legacy-gate.json'
    $legacy=Get-Content -LiteralPath (Join-Path $testRoot '.ai/local-output/legacy-gate.json') -Raw | ConvertFrom-Json
    Assert-StateTest (-not $legacy.evidence.current) 'legacy gate without input provenance is not current'
    $gate['inputsCurrent']=$true
    Write-AdosJson $gatePath $gate

    $verification.status='FAIL'
    Write-AdosJson $verificationPath $verification
    & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/failed-recheck.json'
    $failedRecheck=Get-Content -LiteralPath (Join-Path $testRoot '.ai/local-output/failed-recheck.json') -Raw | ConvertFrom-Json
    Assert-StateTest (-not $failedRecheck.evidence.current) 'a newer failed recheck cannot be hidden by a cached verified gate'
    $verification.status='PASS'
    Write-AdosJson $verificationPath $verification

    Write-AdosUtf8 (Join-Path $testRoot 'README.md') "# Fixture`nChanged product state.`n"
    $hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    & $stateScript export -ProjectPath $testRoot -ExpectedSnapshotSha256 $hash
    $snapshot=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    Assert-StateTest (-not $snapshot.evidence.current -and $snapshot.source.worktreeDirty) 'file change invalidates old verification'
    Assert-StateTest (($snapshot.sources | Where-Object { $_.path -eq 'README.md' }).sha256 -eq $readmeHash) 'document hash remains tied to exact committed bytes despite local edits'
    $null=Invoke-StateGit @('checkout','--','README.md')

    $config.includeTaskSummary=$true
    Write-AdosJson $configPath $config
    $saved.task='password=synthetic-fixture-value'
    Write-AdosJson $checkpointPath $saved
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/secrets.json' } 'credential-like' 'credential-like checkpoint summary is blocked'
    Assert-StateTest (-not (Test-Path -LiteralPath (Join-Path $testRoot '.ai/local-output/secrets.json'))) 'blocked summary produces no snapshot'
    $saved.task='Continue FIXTURE-1 from verification; next action is an independent review.'
    Write-AdosJson $checkpointPath $saved
    & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/handoff.json'
    $recovered=(& $stateScript read -SnapshotPath (Join-Path $testRoot '.ai/local-output/handoff.json') | Out-String) | ConvertFrom-Json
    Assert-StateTest ($recovered.checkpoint.taskId -eq 'FIXTURE-1' -and $recovered.checkpoint.summary.Contains('next action')) 'a separate read recovers task identity and handoff'

    $config.sources=@('../outside.md')
    Write-AdosJson $configPath $config
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/escape.json' } 'repository-relative' 'path traversal is rejected'
    $config.sources=@('.env.json')
    Write-AdosJson $configPath $config
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/env.json' } 'non-secret' 'secret document path is rejected'
    $config.sources=@('README.md','AGENTS.md')
    $config.repository.fullName='another/project'
    Write-AdosJson $configPath $config
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot -SnapshotPath '.ai/local-output/wrong-project.json' } 'must match' 'wrong repository identity is rejected'
    $config.repository.fullName='fixture/project'
    Write-AdosJson $configPath $config

    $invalid=Join-Path $testRoot '.ai/local-output/invalid.json'
    Write-AdosUtf8 $invalid '{'
    Expect-StateFailure { & $stateScript validate -SnapshotPath $invalid } 'invalid JSON' 'malformed snapshot is rejected'
    Expect-StateFailure { & $stateScript export -ProjectPath $testRoot -SnapshotPath $invalid -ExpectedSnapshotSha256 ((Get-FileHash $invalid).Hash.ToLowerInvariant()) } 'invalid JSON' 'malformed destination is preserved'
    Assert-StateTest ((Get-Content -LiteralPath $invalid -Raw) -eq '{') 'invalid destination bytes remain unchanged'

    $snapshot.source.kind='github'
    $snapshot.source.worktreeDirty=$null
    $snapshot.source.evidenceFingerprint=$null
    $snapshot.evidence.status='UNKNOWN'
    $snapshot.evidence.current=$false
    $snapshot.evidence.recordedAt=$null
    $snapshot.evidence.head=$null
    $snapshot.evidence.fingerprint=$null
    $snapshot.workstreams.accepted=[pscustomobject]@{branch='main';commit=$head}
    $snapshot.workstreams.drafts=@([pscustomobject]@{number=1;headBranch='feature';headCommit=$head;baseBranch='main';draft=$true;url='https://github.com/fixture/project/pull/1'})
    $remotePath=Join-Path $testRoot '.ai/local-output/remote.json'
    Write-AdosJson $remotePath $snapshot 12
    & $stateScript validate -SnapshotPath $remotePath
    Assert-StateTest ($snapshot.workstreams.accepted.branch -ne $snapshot.workstreams.drafts[0].headBranch) 'accepted source and observed draft remain separate'
    $snapshot.evidence.current=$true
    Write-AdosJson $remotePath $snapshot 12
    Expect-StateFailure { & $stateScript validate -SnapshotPath $remotePath } 'Current evidence' 'remote snapshot cannot invent current local verification'
    $snapshot.evidence.current=$false
    $snapshot | Add-Member -NotePropertyName rawLogs -NotePropertyValue 'unexpected'
    Write-AdosJson $remotePath $snapshot 12
    Expect-StateFailure { & $stateScript validate -SnapshotPath $remotePath } 'unsupported field' 'unknown fields cannot smuggle raw logs into export'

    Write-Host "ADOS project-state tests: $passed assertions passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
