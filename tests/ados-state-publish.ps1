[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$devcoreRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $devcoreRoot 'scripts/ados-state-publish.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ados-publish-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$script:mode = 'normal'
$script:candidateSha = 'c' * 40
$script:blobSha = 'b' * 40
$script:newTreeSha = 'd' * 40
$script:nestedTreeSha = 'e' * 40
$script:concurrentSha = 'f' * 40

function Assert-PublishTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

function Invoke-PublishFixtureGit {
    param([string[]]$Arguments)
    $result = @(& git -C $testRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $($result -join ' ')" }
    return (($result | Out-String).Trim())
}

function Get-PublishFixtureFileState {
    return (@(Get-ChildItem -LiteralPath $testRoot -Force -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName + '|DIRECTORY' }
        else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n")
}

function Reset-PublishFixture {
    param([string]$Mode = 'normal')
    $script:mode = $Mode
    $script:remoteHead = $script:sourceSha
    $script:apiCalls = New-Object System.Collections.ArrayList
    $script:uploadedContent = $null
    $script:commitRequest = $null
    $script:pendingReceiptSeen = $false
    $script:publishConfig = [ordered]@{
        schemaVersion = 1; enabled = $true; projectId = 'FIXTURE'
        repository = [ordered]@{ fullName = 'fixture/project'; visibility = 'private' }
        branch = 'review-state'; destination = 'state/project-state.json'
    }
    Write-AdosJson $configPath $script:publishConfig
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
}

# Tests replace the single API boundary in their own scope. No live gh command
# or remote write can run here; every unexpected request fails the fixture.
function Invoke-StatePublishApi {
    param([string]$Method, [string]$Endpoint, $Body = $null)
    $null = $script:apiCalls.Add([pscustomobject]@{ method = $Method; endpoint = $Endpoint; body = $Body })
    if ($script:mode -eq 'unavailable') { Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic unavailable service.' }
    $base = 'repos/fixture/project'
    if ($Method -eq 'GET' -and $Endpoint -eq $base) {
        $name = $(if ($script:mode -eq 'wrong-repository') { 'fixture/other-project' } else { 'fixture/project' })
        $visibility = $(if ($script:mode -eq 'wrong-visibility') { 'public' } else { 'private' })
        $default = $(if ($script:mode -eq 'default-branch') { 'review-state' } else { 'main' })
        return [pscustomobject]@{ full_name = $name; visibility = $visibility; private = ($visibility -eq 'private'); default_branch = $default }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/branches/review-state") {
        return [pscustomobject]@{ name = 'review-state'; protected = ($script:mode -eq 'protected'); commit = [pscustomobject]@{ sha = $script:remoteHead } }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/ref/heads/review-state") {
        return [pscustomobject]@{ ref = 'refs/heads/review-state'; object = [pscustomobject]@{ type = 'commit'; sha = $script:remoteHead } }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/commits/$script:sourceSha") {
        $sha = $(if ($script:mode -eq 'wrong-source-commit') { $script:concurrentSha } else { $script:sourceSha })
        return [pscustomobject]@{ sha = $sha; tree = [pscustomobject]@{ sha = $script:sourceTreeSha } }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/trees/$script:sourceTreeSha") {
        return [pscustomobject]@{ sha = $script:sourceTreeSha; truncated = $false; tree = @($script:sourceEntries) }
    }
    foreach ($entry in $script:sourceEntries) {
        if ($entry.type -eq 'blob' -and $Method -eq 'GET' -and $Endpoint -eq ($base + '/git/blobs/' + $entry.sha)) {
            $bytes = $script:sourceBytes[$entry.sha]
            if ($script:mode -eq 'wrong-document-bytes' -and $entry.path -eq 'README.md') { $bytes = [Text.Encoding]::UTF8.GetBytes('Different committed bytes') }
            return [pscustomobject]@{ sha = $entry.sha; encoding = 'base64'; content = [Convert]::ToBase64String($bytes) }
        }
    }
    if ($Method -eq 'POST' -and $Endpoint -eq 'graphql') {
        $script:commitRequest = $Body.variables.input
        if ($Body.query -notmatch 'createCommitOnBranch' -or $script:commitRequest.branch.repositoryNameWithOwner -cne 'fixture/project' -or $script:commitRequest.branch.branchName -cne 'review-state') {
            throw 'Fixture received an unexpected GraphQL publication.'
        }
        $pending = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:pendingReceiptSeen = $pending.status -eq 'UPDATE_PENDING' -and $pending.refUpdateAttempted -and -not $pending.remoteVerified -and $null -eq $pending.candidateCommit
        if ($script:mode -eq 'transport-before-commit') { Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic transport failure before the server committed.' }
        if ($script:mode -eq 'race-forward') { $script:remoteHead = $script:concurrentSha }
        if ($script:mode -eq 'race-rewind') { $script:remoteHead = $script:ancestorSha }
        # Model the server's exact expectedHeadOid precondition, including rewinds.
        if ($script:commitRequest.expectedHeadOid -cne $script:remoteHead -or $script:mode -eq 'graphql-error') {
            return [pscustomobject]@{ data = [pscustomobject]@{ createCommitOnBranch = $null }; errors = @([pscustomobject]@{ message = 'SYNTHETIC_PROVIDER_ERROR_MUST_NOT_BE_LOGGED' }) }
        }
        if (@($script:commitRequest.fileChanges.additions).Count -ne 1 -or $script:commitRequest.fileChanges.additions[0].path -cne 'state/project-state.json') { throw 'Fixture received unexpected file changes.' }
        $script:uploadedContent = $script:commitRequest.fileChanges.additions[0].contents
        $script:remoteHead = $script:candidateSha
        if ($script:mode -eq 'transport-after-commit') { Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic lost response after the server committed.' }
        $response = [pscustomobject]@{ data = [pscustomobject]@{ createCommitOnBranch = [pscustomobject]@{
            commit = [pscustomobject]@{ oid = $script:candidateSha; tree = [pscustomobject]@{ oid = $script:newTreeSha }; parents = [pscustomobject]@{ totalCount = 1; nodes = @([pscustomobject]@{ oid = $script:sourceSha }) } }
            ref = [pscustomobject]@{ name = 'review-state'; prefix = 'refs/heads/'; repository = [pscustomobject]@{ nameWithOwner = 'fixture/project' }; target = [pscustomobject]@{ oid = $script:candidateSha } }
        } } }
        if ($script:mode -eq 'graphql-partial-error') { $response | Add-Member -NotePropertyName errors -NotePropertyValue @([pscustomobject]@{ message = 'SYNTHETIC_PROVIDER_ERROR_MUST_NOT_BE_LOGGED' }) }
        return $response
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/commits/$script:candidateSha") {
        if ($script:mode -eq 'readback-unavailable') { Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic read-back service failure.' }
        return [pscustomobject]@{ sha = $script:candidateSha; tree = [pscustomobject]@{ sha = $script:newTreeSha }; parents = @([pscustomobject]@{ sha = $script:sourceSha }) }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/trees/$script:newTreeSha") {
        return [pscustomobject]@{ sha = $script:newTreeSha; truncated = $false; tree = @([pscustomobject]@{ path = 'state'; type = 'tree'; mode = '040000'; sha = $script:nestedTreeSha }) }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/trees/$script:nestedTreeSha") {
        return [pscustomobject]@{ sha = $script:nestedTreeSha; truncated = $false; tree = @([pscustomobject]@{ path = 'project-state.json'; type = 'blob'; mode = '100644'; sha = $script:blobSha }) }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/blobs/$script:blobSha") {
        $content = $(if ($script:mode -eq 'readback-mismatch') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}')) } else { $script:uploadedContent })
        return [pscustomobject]@{ sha = $script:blobSha; encoding = 'base64'; content = $content }
    }
    throw "Unexpected fixture API request: $Method $Endpoint"
}

function Assert-PublishFailure {
    param([string]$ExpectedStatus, [string]$Message, [string]$Expected = $script:sourceSha)
    $failed = $false
    try { $null = Invoke-AdosStatePublish -ProjectPath $testRoot -ExpectedRemoteCommit $Expected -ConfirmPublish }
    catch { $failed = $true }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PublishTest ($failed -and $receipt.status -eq $ExpectedStatus -and -not $receipt.remoteVerified) $Message
    return $receipt
}

try {
    Ensure-AdosDirectory $testRoot
    $null = Invoke-PublishFixtureGit @('init','-q','-b','main')
    $null = Invoke-PublishFixtureGit @('config','user.name','ADOS Publish Fixture')
    $null = Invoke-PublishFixtureGit @('config','user.email','ados-publish-fixture@example.invalid')
    $null = Invoke-PublishFixtureGit @('config','core.autocrlf','false')
    $null = Invoke-PublishFixtureGit @('config','core.hooksPath',(Join-Path $testRoot 'no-hooks'))
    $null = Invoke-PublishFixtureGit @('config','commit.gpgsign','false')
    $null = Invoke-PublishFixtureGit @('remote','add','origin','https://github.com/fixture/project.git')
    Write-AdosUtf8 (Join-Path $testRoot 'README.md') "# Synthetic publish fixture`nCommitted document.`n"
    Write-AdosUtf8 (Join-Path $testRoot 'AGENTS.md') "# Synthetic rules`nFixture scope only.`n"
    Write-AdosUtf8 (Join-Path $testRoot 'metadata.json') '{"purpose":"canonical fixture document"}'
    Write-AdosUtf8 (Join-Path $testRoot 'package.json') '{"name":"canonical-fixture-manifest"}'
    Write-AdosJson (Join-Path $testRoot '.ados/state-export.json') ([ordered]@{ schemaVersion = 1; projectId = 'FIXTURE'; repository = [ordered]@{ fullName = 'fixture/project'; visibility = 'private' }; sources = @('README.md','AGENTS.md','metadata.json'); includeTaskSummary = $false })
    $null = Invoke-PublishFixtureGit @('add','.')
    $null = Invoke-PublishFixtureGit @('commit','-q','-m','Create publication fixture')
    $script:ancestorSha = Invoke-PublishFixtureGit @('rev-parse','HEAD')
    Write-AdosUtf8 (Join-Path $testRoot 'README.md') "# Synthetic publish fixture`nA newer committed document.`n"
    $null = Invoke-PublishFixtureGit @('add','README.md')
    $null = Invoke-PublishFixtureGit @('commit','-q','-m','Advance the snapshot baseline')
    $script:sourceSha = Invoke-PublishFixtureGit @('rev-parse','HEAD')
    $script:sourceTreeSha = Invoke-PublishFixtureGit @('rev-parse','HEAD^{tree}')
    $script:concurrentSha = Invoke-PublishFixtureGit @('commit-tree',$script:sourceTreeSha,'-p',$script:sourceSha,'-m','Synthetic forward writer')
    $script:sourceEntries = @()
    $script:sourceBytes = @{}
    foreach ($name in @('README.md','AGENTS.md','metadata.json','package.json')) {
        $sha = Invoke-PublishFixtureGit @('rev-parse',('HEAD:' + $name))
        $script:sourceEntries += [pscustomobject]@{ path = $name; type = 'blob'; mode = '100644'; sha = $sha }
        $script:sourceBytes[$sha] = [IO.File]::ReadAllBytes((Join-Path $testRoot $name))
    }
    & (Join-Path $devcoreRoot 'scripts/ados-state.ps1') export -ProjectPath $testRoot
    $configPath = Join-Path $testRoot '.ados/state-publish.json'
    $receiptPath = Join-Path $testRoot '.ai/local-output/state-publish.receipt.json'
    Reset-PublishFixture
    $beforeFiles = Get-PublishFixtureFileState
    $indexHash = (Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash
    $preview = Invoke-AdosStatePublish -ProjectPath $testRoot -ExpectedRemoteCommit $script:sourceSha
    Assert-PublishTest ($preview.status -eq 'PREVIEW' -and -not $preview.remoteVerified -and -not (Test-Path -LiteralPath $receiptPath)) 'preview writes no receipt and does not claim publication'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'preview makes only read-only API requests'
    Assert-PublishTest ((Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash -eq $indexHash) 'preview leaves the Git index bytes untouched'
    Assert-PublishTest ((Get-PublishFixtureFileState) -ceq $beforeFiles) 'preview leaves all fixture files, directories and Git metadata unchanged'

    Reset-PublishFixture
    $indexHash = (Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash
    $result = Invoke-AdosStatePublish -ProjectPath $testRoot -ExpectedRemoteCommit $script:sourceSha -ConfirmPublish
    Assert-PublishTest ($result.status -eq 'PUBLISHED_VERIFIED' -and $result.remoteVerified -and $script:remoteHead -eq $script:candidateSha) 'publication succeeds only after exact remote read-back'
    Assert-PublishTest (@($script:commitRequest.fileChanges.Keys).Count -eq 1 -and @($script:commitRequest.fileChanges.additions).Count -eq 1 -and $script:commitRequest.fileChanges.additions[0].path -eq 'state/project-state.json') 'atomic mutation requests only the configured snapshot addition and no deletions'
    Assert-PublishTest ($script:commitRequest.expectedHeadOid -eq $script:sourceSha) 'server-side expectedHeadOid is the exact reviewed remote head'
    $mutations = @($script:apiCalls | Where-Object { $_.method -ne 'GET' })
    Assert-PublishTest ($mutations.Count -eq 1 -and $mutations[0].method -eq 'POST' -and $mutations[0].endpoint -ceq 'graphql') 'publication uses one atomic GraphQL mutation and no REST object/ref writes'
    Assert-PublishTest $script:pendingReceiptSeen 'unconfirmed receipt is durable before the atomic mutation is attempted'
    Assert-PublishTest ((Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash -eq $indexHash -and (Invoke-PublishFixtureGit @('rev-parse','HEAD')) -eq $script:sourceSha) 'publication leaves the local index and HEAD untouched'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PublishTest ($receipt.remoteVerified -and $receipt.publishedCommit -eq $script:candidateSha) 'verified publication is recorded in the local receipt'

    Reset-PublishFixture
    $script:remoteHead = $script:concurrentSha
    $null = Assert-PublishFailure 'CONFLICT' 'stale expected remote head fails before writing'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'stale expected head creates no remote objects'
    Reset-PublishFixture 'race-forward'
    $receipt = Assert-PublishFailure 'REF_UPDATE_UNCONFIRMED' 'an advancing writer between the final GET and mutation prevents a verified publication'
    Assert-PublishTest ($script:remoteHead -eq $script:concurrentSha -and $script:commitRequest.expectedHeadOid -eq $script:sourceSha -and $null -eq $script:uploadedContent) 'atomic expected-head comparison preserves the concurrent forward commit'
    Reset-PublishFixture 'race-rewind'
    $receipt = Assert-PublishFailure 'REF_UPDATE_UNCONFIRMED' 'rewinding to an actual ancestor between GET and mutation cannot pass exact expected-head comparison'
    Assert-PublishTest ($script:remoteHead -eq $script:ancestorSha -and $script:commitRequest.expectedHeadOid -eq $script:sourceSha -and $null -eq $script:uploadedContent) 'atomic mutation preserves the rewind instead of reintroducing removed history'
    foreach ($transportMode in @('transport-before-commit','transport-after-commit')) {
        Reset-PublishFixture $transportMode
        $receipt = Assert-PublishFailure 'REF_UPDATE_UNCONFIRMED' ("$transportMode records an uncertain result without an invented commit identity")
        $expectedHead = $(if ($transportMode -eq 'transport-before-commit') { $script:sourceSha } else { $script:candidateSha })
        Assert-PublishTest ($script:remoteHead -eq $expectedHead -and $receipt.refUpdateAttempted -and $null -eq $receipt.candidateCommit -and $script:pendingReceiptSeen) ("$transportMode retains the pre-attempt receipt and requires inspection")
    }
    foreach ($errorMode in @('graphql-error','graphql-partial-error')) {
        Reset-PublishFixture $errorMode
        $receipt = Assert-PublishFailure 'REF_UPDATE_UNCONFIRMED' ("$errorMode cannot be treated as a successful mutation response")
        Assert-PublishTest ($receipt.detail -notmatch 'SYNTHETIC_PROVIDER_ERROR_MUST_NOT_BE_LOGGED') 'arbitrary GraphQL error text is not copied into the receipt'
    }
    Reset-PublishFixture 'readback-mismatch'
    $receipt = Assert-PublishFailure 'READBACK_FAILED' 'read-back byte mismatch never reports verified publication'
    Assert-PublishTest ($receipt.publishedCommit -eq $script:candidateSha -and $script:remoteHead -eq $script:candidateSha) 'read-back failure honestly retains the commit that may already be published'
    Reset-PublishFixture 'readback-unavailable'
    $null = Assert-PublishFailure 'READBACK_FAILED' 'unavailable read-back is recorded as unverified publication'

    foreach ($modeName in @('wrong-repository','wrong-visibility','wrong-source-commit','wrong-document-bytes','protected','default-branch')) {
        Reset-PublishFixture $modeName
        $null = Assert-PublishFailure 'REJECTED' ("rejects $modeName before writing")
        Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) ("$modeName makes no remote writes")
    }
    Reset-PublishFixture 'unavailable'
    $null = Assert-PublishFailure 'API_UNAVAILABLE' 'unavailable service produces a failure receipt'
    Reset-PublishFixture
    $script:publishConfig.enabled = $false
    Write-AdosJson $configPath $script:publishConfig
    $null = Assert-PublishFailure 'REJECTED' 'publication is disabled without explicit project opt-in'
    Reset-PublishFixture
    $null = Invoke-PublishFixtureGit @('remote','set-url','origin','https://github.com/fixture/other-project.git')
    $null = Assert-PublishFailure 'REJECTED' 'foreign origin cannot publish this project snapshot'
    Assert-PublishTest ($script:apiCalls.Count -eq 0) 'origin mismatch is rejected before any remote request'
    $null = Invoke-PublishFixtureGit @('remote','set-url','origin','https://github.com/fixture/project.git')
    foreach ($protectedName in @('main','master')) {
        Reset-PublishFixture
        $script:publishConfig.branch = $protectedName
        Write-AdosJson $configPath $script:publishConfig
        $null = Assert-PublishFailure 'REJECTED' ("rejects explicit $protectedName destination")
    }
    Reset-PublishFixture
    $script:publishConfig.destination = 'metadata.json'
    Write-AdosJson $configPath $script:publishConfig
    $null = Assert-PublishFailure 'REJECTED' 'canonical indexed document cannot be a publication destination'
    Reset-PublishFixture
    $script:publishConfig.destination = 'package.json'
    Write-AdosJson $configPath $script:publishConfig
    $null = Assert-PublishFailure 'REJECTED' 'existing unrelated JSON document cannot be overwritten'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'unrelated destination rejection creates no remote objects'
    Write-Host "ADOS state publication tests passed: $passed assertions (mocked API only)"
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
