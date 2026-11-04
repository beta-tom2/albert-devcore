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

function Reset-PublishFixture {
    param([string]$Mode = 'normal')
    $script:mode = $Mode
    $script:remoteHead = $script:sourceSha
    $script:apiCalls = New-Object System.Collections.ArrayList
    $script:uploadedContent = $null
    $script:treeRequest = $null
    $script:commitRequest = $null
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
    if ($Method -eq 'POST' -and $Endpoint -eq "$base/git/blobs") {
        $script:uploadedContent = $Body.content
        return [pscustomobject]@{ sha = $script:blobSha }
    }
    if ($Method -eq 'POST' -and $Endpoint -eq "$base/git/trees") {
        $script:treeRequest = $Body
        return [pscustomobject]@{ sha = $script:newTreeSha }
    }
    if ($Method -eq 'POST' -and $Endpoint -eq "$base/git/commits") {
        $script:commitRequest = $Body
        if ($script:mode -eq 'race-before-update') { $script:remoteHead = $script:concurrentSha }
        return [pscustomobject]@{ sha = $script:candidateSha; tree = [pscustomobject]@{ sha = $script:newTreeSha }; parents = @([pscustomobject]@{ sha = $script:sourceSha }) }
    }
    if ($Method -eq 'PATCH' -and $Endpoint -eq "$base/git/refs/heads/review-state") {
        if ($Body.force -ne $false -or $Body.sha -cne $script:candidateSha) { throw 'Fixture rejected a forced or unexpected ref update.' }
        if ($script:mode -eq 'race-during-update') {
            $script:remoteHead = $script:concurrentSha
            Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic fast-forward rejection during a concurrent update.'
        }
        if ($script:remoteHead -cne $script:sourceSha) { throw 'Fixture rejected a non-fast-forward update.' }
        $script:remoteHead = $script:candidateSha
        return [pscustomobject]@{ ref = 'refs/heads/review-state'; object = [pscustomobject]@{ type = 'commit'; sha = $script:candidateSha } }
    }
    if ($Method -eq 'GET' -and $Endpoint -eq "$base/git/commits/$script:candidateSha") {
        if ($script:mode -eq 'readback-unavailable') { Stop-StatePublish 'API_UNAVAILABLE' 'Synthetic read-back service failure.' }
        return [pscustomobject]@{ sha = $script:candidateSha; tree = [pscustomobject]@{ sha = $script:newTreeSha } }
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
    $script:sourceSha = Invoke-PublishFixtureGit @('rev-parse','HEAD')
    $script:sourceTreeSha = Invoke-PublishFixtureGit @('rev-parse','HEAD^{tree}')
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
    $beforeFiles = @(& git -C $testRoot status --porcelain --untracked-files=all) -join "`n"
    $indexHash = (Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash
    $preview = Invoke-AdosStatePublish -ProjectPath $testRoot -ExpectedRemoteCommit $script:sourceSha
    Assert-PublishTest ($preview.status -eq 'PREVIEW' -and -not $preview.remoteVerified -and -not (Test-Path -LiteralPath $receiptPath)) 'preview writes no receipt and does not claim publication'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'preview makes only read-only API requests'
    Assert-PublishTest ((Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash -eq $indexHash) 'preview leaves the Git index bytes untouched'
    Assert-PublishTest (((@(& git -C $testRoot status --porcelain --untracked-files=all) -join "`n") -eq $beforeFiles)) 'preview leaves working-tree contents and file inventory unchanged'

    Reset-PublishFixture
    $indexHash = (Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash
    $result = Invoke-AdosStatePublish -ProjectPath $testRoot -ExpectedRemoteCommit $script:sourceSha -ConfirmPublish
    Assert-PublishTest ($result.status -eq 'PUBLISHED_VERIFIED' -and $result.remoteVerified -and $script:remoteHead -eq $script:candidateSha) 'publication succeeds only after exact remote read-back'
    Assert-PublishTest ($script:treeRequest.base_tree -eq $script:sourceTreeSha -and @($script:treeRequest.tree).Count -eq 1 -and $script:treeRequest.tree[0].path -eq 'state/project-state.json') 'new tree preserves the remote base and changes only the configured snapshot path'
    Assert-PublishTest (@($script:commitRequest.parents).Count -eq 1 -and $script:commitRequest.parents[0] -eq $script:sourceSha) 'new commit has only the exact expected remote parent'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -eq 'PATCH' -and $_.body.force -eq $false }).Count -eq 1) 'ref update requests fast-forward only without force'
    Assert-PublishTest ((Get-FileHash -LiteralPath (Join-Path $testRoot '.git/index') -Algorithm SHA256).Hash -eq $indexHash -and (Invoke-PublishFixtureGit @('rev-parse','HEAD')) -eq $script:sourceSha) 'publication leaves the local index and HEAD untouched'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PublishTest ($receipt.remoteVerified -and $receipt.publishedCommit -eq $script:candidateSha) 'verified publication is recorded in the local receipt'

    Reset-PublishFixture
    $script:remoteHead = $script:concurrentSha
    $null = Assert-PublishFailure 'CONFLICT' 'stale expected remote head fails before writing'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'stale expected head creates no remote objects'
    Reset-PublishFixture 'race-before-update'
    $receipt = Assert-PublishFailure 'CONFLICT' 'concurrent update after object creation prevents ref update'
    Assert-PublishTest (@($script:apiCalls | Where-Object { $_.method -eq 'PATCH' }).Count -eq 0 -and $receipt.candidateCommit -eq $script:candidateSha) 'unpublished candidate is recorded without replacing the concurrent head'
    Reset-PublishFixture 'race-during-update'
    $receipt = Assert-PublishFailure 'REF_UPDATE_UNCONFIRMED' 'failure during ref update is not reported as successful publication'
    Assert-PublishTest ($script:remoteHead -eq $script:concurrentSha -and $receipt.refUpdateAttempted) 'fast-forward rejection preserves another writer and records the uncertain attempt'
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
