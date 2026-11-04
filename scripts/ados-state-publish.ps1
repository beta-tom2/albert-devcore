[CmdletBinding()]
param(
    [string]$ProjectPath = '.',
    [string]$ConfigPath = '.ados/state-publish.json',
    [string]$SnapshotPath = '.ai/local-output/project-state.json',
    [string]$ExpectedRemoteCommit = '',
    [switch]$ConfirmPublish
)

$ErrorActionPreference = 'Stop'
$script:StatePublishValidator = Join-Path $PSScriptRoot 'ados-state.ps1'
. (Join-Path $PSScriptRoot 'ados-common.ps1')

function Stop-StatePublish {
    param([string]$Status, [string]$Message)
    $errorValue = New-Object System.InvalidOperationException($Message)
    $errorValue.Data['StatePublishStatus'] = $Status
    throw $errorValue
}

function ConvertFrom-StatePublishJson {
    param([string]$Text)
    $parameters = @{ InputObject = $Text.TrimStart([char]0xFEFF); ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $parameters['DateKind'] = 'String' }
    return (ConvertFrom-Json @parameters)
}

function Get-StatePublishHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Read-StatePublishSnapshot {
    param([string]$InputPath, [byte[]]$Content = $null)
    # Dot-sourcing is intentionally confined here: validator parameters must not
    # replace the publisher's ProjectPath, ConfigPath or command arguments.
    . $script:StatePublishValidator validate -SnapshotPath $InputPath 6>$null
    if ($null -eq $Content) { $Content = [IO.File]::ReadAllBytes($InputPath) }
    if ($Content.Length -gt 131072) { Stop-StatePublish 'REJECTED' 'Snapshot exceeds 128 KiB.' }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    $state = ConvertFrom-StatePublishJson ($encoding.GetString($Content))
    Assert-ProjectState $state
    return [pscustomobject]@{ state = $state; bytes = $Content; sha256 = (Get-StatePublishHash $Content) }
}

function Resolve-StatePublishLocalPath {
    param([string]$Root, [string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Root $Path }
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $full -match '(?i)[\\/]\.git(?:[\\/]|$)' -or [IO.Path]::GetExtension($full) -ine '.json') {
        Stop-StatePublish 'REJECTED' 'Local JSON paths must stay inside this repository and outside .git.'
    }
    $cursor = $full
    while ($cursor.Length -ge $Root.Length) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-StatePublish 'REJECTED' 'Symlink/reparse-point publication inputs or receipt paths are not allowed.'
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}

function Invoke-StatePublishApi {
    param([ValidateSet('GET','POST','PATCH')][string]$Method, [string]$Endpoint, $Body = $null)
    # This is the only transport boundary. There is no production mock/bypass flag.
    if ($Endpoint -cnotmatch '^repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9%._/-]+)?$') {
        Stop-StatePublish 'REJECTED' 'Unexpected GitHub API endpoint.'
    }
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh) { Stop-StatePublish 'TRANSPORT_UNAVAILABLE' 'GitHub CLI gh is required; no publication was confirmed.' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $gh.Source
    $info.Arguments = 'api --hostname github.com --method ' + $Method + ' --header "Accept: application/vnd.github+json" --header "X-GitHub-Api-Version: 2022-11-28" ' + $Endpoint
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.EnvironmentVariables['GH_PROMPT_DISABLED'] = '1'
    if ($null -ne $Body) { $info.RedirectStandardInput = $true; $info.Arguments += ' --input -' }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { Stop-StatePublish 'TRANSPORT_UNAVAILABLE' 'Could not start GitHub CLI.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if ($null -ne $Body) {
            # Payload text is ASCII: snapshot bytes are base64, and configured
            # destination paths/project IDs are restricted to ASCII below.
            $process.StandardInput.Write(($Body | ConvertTo-Json -Depth 16 -Compress))
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit(30000)) { $process.Kill(); Stop-StatePublish 'API_UNAVAILABLE' 'GitHub API timed out; publication is not confirmed.' }
        $text = $output.GetAwaiter().GetResult()
        $null = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { Stop-StatePublish 'API_UNAVAILABLE' 'GitHub API request failed; check authenticated gh access and service/network availability.' }
        return (ConvertFrom-StatePublishJson $text)
    }
    finally { $process.Dispose() }
}

function Get-StatePublishTreeEntry {
    param([string]$Repository, [string]$TreeSha, [string]$Path, [hashtable]$Cache)
    $segments = $Path.Split('/')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($TreeSha -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'Invalid remote tree identity.' }
        if (-not $Cache.ContainsKey($TreeSha)) { $Cache[$TreeSha] = Invoke-StatePublishApi GET "repos/$Repository/git/trees/$TreeSha" }
        $tree = $Cache[$TreeSha]
        if ($tree.sha -cne $TreeSha -or $tree.truncated -ne $false -or $tree.tree -isnot [array]) { Stop-StatePublish 'REJECTED' 'Remote tree is incomplete or has an unexpected identity.' }
        $matches = @($tree.tree | Where-Object { $_.path -ceq $segments[$index] })
        if ($matches.Count -eq 0) { return $null }
        if ($matches.Count -ne 1) { Stop-StatePublish 'REJECTED' 'Ambiguous remote path.' }
        $entry = $matches[0]
        if ($index -eq $segments.Count - 1) { return $entry }
        if ($entry.type -ne 'tree' -or $entry.mode -ne '040000') { Stop-StatePublish 'REJECTED' 'Remote path crosses a file, symlink or submodule.' }
        $TreeSha = [string]$entry.sha
    }
}

function Read-StatePublishBlob {
    param([string]$Repository, [string]$Sha)
    if ($Sha -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'Invalid remote blob identity.' }
    $blob = Invoke-StatePublishApi GET "repos/$Repository/git/blobs/$Sha"
    if ($blob.sha -cne $Sha -or $blob.encoding -ne 'base64') { Stop-StatePublish 'REJECTED' 'Remote blob identity or encoding does not match.' }
    return ,([Convert]::FromBase64String([string]$blob.content))
}

function Get-StatePublishRef {
    param([string]$Repository, [string]$Branch)
    $reference = Invoke-StatePublishApi GET ("repos/$Repository/git/ref/heads/" + [Uri]::EscapeDataString($Branch))
    if ($reference.ref -cne ('refs/heads/' + $Branch) -or $reference.object.type -ne 'commit' -or $reference.object.sha -cnotmatch '^[a-f0-9]{40}$') {
        Stop-StatePublish 'REJECTED' 'The exact existing destination branch could not be verified.'
    }
    return [string]$reference.object.sha
}

function Write-StatePublishReceipt {
    param([string]$Path, $Receipt)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Write-AdosJson $temporary $Receipt 12
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-AdosStatePublish {
    [CmdletBinding()]
    param(
        [string]$ProjectPath = '.', [string]$ConfigPath = '.ados/state-publish.json',
        [string]$SnapshotPath = '.ai/local-output/project-state.json',
        [string]$ExpectedRemoteCommit = '', [switch]$ConfirmPublish
    )
    $root = Resolve-AdosRepoRoot $ProjectPath
    $receiptPath = $null
    $receipt = [ordered]@{
        schemaVersion = 1; startedAt = [datetimeoffset]::UtcNow.ToString('o'); finishedAt = $null
        mode = $(if ($ConfirmPublish) { 'publish' } else { 'preview' }); status = 'PREPARING'
        repository = $null; branch = $null; destination = $null; sourceCommit = $null
        expectedRemoteCommit = $ExpectedRemoteCommit; snapshotSha256 = $null
        candidateCommit = $null; publishedCommit = $null; refUpdateAttempted = $false
        remoteVerified = $false; stage = 'local-validation'; detail = $null
    }
    try {
        if ($ConfirmPublish) {
            $candidateReceiptPath = Resolve-StatePublishLocalPath $root '.ai/local-output/state-publish.receipt.json'
            $null = & git -C $root check-ignore --quiet -- '.ai/local-output/state-publish.receipt.json'
            if ($LASTEXITCODE -ne 0) { Stop-StatePublish 'REJECTED' 'Receipt path must already be ignored and untracked; run the existing local state setup first.' }
            $receiptPath = $candidateReceiptPath
        }
        if ($ExpectedRemoteCommit -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'An exact lowercase ExpectedRemoteCommit is required.' }
        $localConfig = Resolve-StatePublishLocalPath $root $ConfigPath
        $localSnapshot = Resolve-StatePublishLocalPath $root $SnapshotPath
        if (-not (Test-Path -LiteralPath $localConfig -PathType Leaf) -or (Get-Item -LiteralPath $localConfig).Length -gt 16384) { Stop-StatePublish 'REJECTED' 'Missing or oversized explicit publication configuration.' }
        $config = ConvertFrom-StatePublishJson (Get-Content -LiteralPath $localConfig -Raw -Encoding UTF8)
        $fields = @($config.PSObject.Properties.Name)
        foreach ($name in @('schemaVersion','enabled','projectId','repository','branch','destination')) { if ($fields -notcontains $name) { Stop-StatePublish 'REJECTED' 'Publication configuration is incomplete.' } }
        if ($fields.Count -ne 6 -or $config.schemaVersion -ne 1 -or $config.enabled -isnot [bool] -or -not $config.enabled) { Stop-StatePublish 'REJECTED' 'Publication requires a schema v1 configuration with enabled=true and only documented fields.' }
        if ($config.projectId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $config.repository.fullName -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $config.repository.visibility -cnotin @('private','public')) { Stop-StatePublish 'REJECTED' 'Invalid project or repository identity.' }
        $repository = [string]$config.repository.fullName
        $branch = [string]$config.branch
        $destination = [string]$config.destination
        $receipt.repository = $repository; $receipt.branch = $branch; $receipt.destination = $destination
        if ($branch.Length -gt 240 -or $branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $branch -imatch '^(main|master)$') { Stop-StatePublish 'REJECTED' 'Destination must be an explicit non-main/non-master branch.' }
        $null = & git -C $root check-ref-format --branch $branch 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-StatePublish 'REJECTED' 'Invalid destination branch.' }
        if ($destination.Length -gt 240 -or $destination -cnotmatch '^[A-Za-z0-9._/-]+\.json$' -or $destination.StartsWith('/') -or
            @($destination.Split('/') | Where-Object { $_ -in @('','..','.') }).Count -gt 0 -or
            $destination -imatch '(^|/)(\.git|\.github|node_modules|\.env[^/]*|secrets?|credentials?)(/|\.|$)') { Stop-StatePublish 'REJECTED' 'Destination must be a bounded repository-relative JSON path.' }
        $configRelative = $localConfig.Substring($root.Length + 1).Replace('\', '/')
        if ($destination -ieq $configRelative -or $destination -ieq '.ados/state-export.json' -or $destination -ieq '.ai/local-output/state-publish.receipt.json') { Stop-StatePublish 'REJECTED' 'Destination cannot replace configuration or the local receipt.' }
        $origin = (& git -C $root remote get-url origin 2>$null | Out-String).Trim() -replace '\.git$', ''
        if ($LASTEXITCODE -ne 0 -or $origin -cnotmatch '^(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$' -or $Matches[1] -ine $repository) { Stop-StatePublish 'REJECTED' 'Configured repository must match the exact recognized GitHub origin.' }
        $validated = Read-StatePublishSnapshot $localSnapshot
        $snapshot = $validated.state
        if ($snapshot.projectId -cne $config.projectId -or $snapshot.repository.fullName -ine $repository -or $snapshot.repository.visibility -cne $config.repository.visibility) { Stop-StatePublish 'REJECTED' 'Snapshot project, repository or visibility does not match the publication configuration.' }
        foreach ($source in @($snapshot.sources)) { if ($destination -ieq $source.path) { Stop-StatePublish 'REJECTED' 'Destination cannot replace a canonical source document.' } }
        $receipt.sourceCommit = $snapshot.source.commit; $receipt.snapshotSha256 = $validated.sha256
        $encoded = [Convert]::ToBase64String($validated.bytes)
        $receipt.stage = 'remote-validation'
        $metadata = Invoke-StatePublishApi GET "repos/$repository"
        if ($metadata.full_name -ine $repository -or $metadata.visibility -cne $config.repository.visibility -or $metadata.private -isnot [bool] -or $metadata.private -ne ($config.repository.visibility -eq 'private')) { Stop-StatePublish 'REJECTED' 'Actual GitHub repository identity or visibility does not match.' }
        if (-not $metadata.default_branch -or $branch -ieq $metadata.default_branch) { Stop-StatePublish 'REJECTED' 'Publishing to the default branch is not allowed.' }
        $branchInfo = Invoke-StatePublishApi GET ("repos/$repository/branches/" + [Uri]::EscapeDataString($branch))
        if ($branchInfo.name -cne $branch -or $branchInfo.protected -isnot [bool] -or $branchInfo.protected) { Stop-StatePublish 'REJECTED' 'Destination branch is protected or its protection state is unknown.' }
        if ((Get-StatePublishRef $repository $branch) -cne $ExpectedRemoteCommit -or $branchInfo.commit.sha -cne $ExpectedRemoteCommit) { Stop-StatePublish 'CONFLICT' 'Remote branch differs from ExpectedRemoteCommit; inspect it before retrying.' }
        $sourceCommit = Invoke-StatePublishApi GET ("repos/$repository/git/commits/" + $snapshot.source.commit)
        if ($sourceCommit.sha -cne $snapshot.source.commit) { Stop-StatePublish 'REJECTED' 'Snapshot source commit does not exist under the expected identity.' }
        $cache = @{}
        foreach ($source in @($snapshot.sources)) {
            $entry = Get-StatePublishTreeEntry $repository $sourceCommit.tree.sha $source.path $cache
            if ($null -eq $entry -or $entry.type -ne 'blob' -or $entry.mode -notin @('100644','100755') -or $entry.sha -cne $source.committedBlobSha) { Stop-StatePublish 'REJECTED' 'A source path does not identify the claimed committed document blob.' }
            if ((Get-StatePublishHash (Read-StatePublishBlob $repository $entry.sha)) -cne $source.sha256) { Stop-StatePublish 'REJECTED' 'A committed document SHA-256 does not match the snapshot.' }
        }
        $parent = Invoke-StatePublishApi GET "repos/$repository/git/commits/$ExpectedRemoteCommit"
        if ($parent.sha -cne $ExpectedRemoteCommit -or $parent.tree.sha -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'Destination parent commit cannot be verified.' }
        $existing = Get-StatePublishTreeEntry $repository $parent.tree.sha $destination $cache
        if ($null -ne $existing) {
            if ($existing.type -ne 'blob' -or $existing.mode -ne '100644') { Stop-StatePublish 'REJECTED' 'Destination cannot replace a directory, executable, symlink or submodule.' }
            $old = (Read-StatePublishSnapshot $localSnapshot (Read-StatePublishBlob $repository $existing.sha)).state
            if ($old.projectId -cne $config.projectId -or $old.repository.fullName -ine $repository -or $old.repository.visibility -cne $config.repository.visibility) { Stop-StatePublish 'REJECTED' 'Existing destination is not a snapshot for this project and visibility.' }
        }
        if ((Get-StatePublishRef $repository $branch) -cne $ExpectedRemoteCommit) { Stop-StatePublish 'CONFLICT' 'Remote branch changed during validation; nothing was published.' }
        if (-not $ConfirmPublish) {
            $receipt.status = 'PREVIEW'; $receipt.detail = 'Validated plan: one snapshot file on the expected existing branch. No local or remote writes.'
        }
        else {
            $receipt.stage = 'create-objects'
            $blob = Invoke-StatePublishApi POST "repos/$repository/git/blobs" ([ordered]@{ content = $encoded; encoding = 'base64' })
            if ($blob.sha -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'Created blob has no valid identity.' }
            $tree = Invoke-StatePublishApi POST "repos/$repository/git/trees" ([ordered]@{ base_tree = $parent.tree.sha; tree = @([ordered]@{ path = $destination; mode = '100644'; type = 'blob'; sha = $blob.sha }) })
            if ($tree.sha -cnotmatch '^[a-f0-9]{40}$') { Stop-StatePublish 'REJECTED' 'Created tree has no valid identity.' }
            $commit = Invoke-StatePublishApi POST "repos/$repository/git/commits" ([ordered]@{ message = ('chore: publish project state for ' + $config.projectId); tree = $tree.sha; parents = @($ExpectedRemoteCommit) })
            if ($commit.sha -cnotmatch '^[a-f0-9]{40}$' -or $commit.tree.sha -cne $tree.sha -or @($commit.parents).Count -ne 1 -or $commit.parents[0].sha -cne $ExpectedRemoteCommit) { Stop-StatePublish 'REJECTED' 'Created commit does not have the exact expected parent and tree.' }
            $receipt.candidateCommit = $commit.sha
            if ((Get-StatePublishRef $repository $branch) -cne $ExpectedRemoteCommit) { Stop-StatePublish 'CONFLICT' 'Remote branch changed before ref update; candidate commit was not published.' }
            $receipt.stage = 'ref-update'; $receipt.status = 'UPDATE_PENDING'; $receipt.refUpdateAttempted = $true
            Write-StatePublishReceipt $receiptPath $receipt
            $updated = Invoke-StatePublishApi PATCH ("repos/$repository/git/refs/heads/" + [Uri]::EscapeDataString($branch)) ([ordered]@{ sha = $commit.sha; force = $false })
            if ($updated.ref -cne ('refs/heads/' + $branch) -or $updated.object.sha -cne $commit.sha) { Stop-StatePublish 'REF_UPDATE_UNCONFIRMED' 'Ref update response does not confirm the candidate commit.' }
            $receipt.publishedCommit = $commit.sha; $receipt.stage = 'readback'
            if ((Get-StatePublishRef $repository $branch) -cne $commit.sha) { Stop-StatePublish 'CONFLICT' 'Remote head moved after update; current publication is not verified.' }
            $published = Invoke-StatePublishApi GET ("repos/$repository/git/commits/" + $commit.sha)
            if ($published.sha -cne $commit.sha -or $published.tree.sha -cne $tree.sha) { Stop-StatePublish 'READBACK_FAILED' 'Published commit/tree identity differs from the candidate.' }
            $readback = Get-StatePublishTreeEntry $repository $published.tree.sha $destination @{}
            if ($null -eq $readback -or $readback.type -ne 'blob' -or $readback.mode -ne '100644' -or $readback.sha -cne $blob.sha -or
                [Convert]::ToBase64String((Read-StatePublishBlob $repository $readback.sha)) -cne $encoded) { Stop-StatePublish 'READBACK_FAILED' 'Published snapshot read-back does not match the exact input bytes.' }
            if ((Get-StatePublishRef $repository $branch) -cne $commit.sha) { Stop-StatePublish 'CONFLICT' 'Remote head moved during read-back; current publication is not verified.' }
            $receipt.status = 'PUBLISHED_VERIFIED'; $receipt.remoteVerified = $true; $receipt.detail = 'Exact snapshot bytes read back from the published commit and branch.'
        }
    }
    catch {
        $receipt.status = 'REJECTED'
        if ($_.Exception.Data.Contains('StatePublishStatus')) { $receipt.status = [string]$_.Exception.Data['StatePublishStatus'] }
        if ($receipt.stage -eq 'ref-update' -and $receipt.status -ne 'CONFLICT') { $receipt.status = 'REF_UPDATE_UNCONFIRMED' }
        if ($receipt.stage -eq 'readback' -and $receipt.status -ne 'CONFLICT') { $receipt.status = 'READBACK_FAILED' }
        $receipt.detail = [string]$_.Exception.Message
        throw
    }
    finally {
        $receipt.finishedAt = [datetimeoffset]::UtcNow.ToString('o')
        if ($ConfirmPublish -and $receiptPath) { Write-StatePublishReceipt $receiptPath $receipt }
    }
    return [pscustomobject]$receipt
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AdosStatePublish @PSBoundParameters | ConvertTo-Json -Depth 12
}
