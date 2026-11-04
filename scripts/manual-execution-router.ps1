[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Task
)

$ErrorActionPreference = 'Stop'

$normalized = $Task.Trim().ToLowerInvariant()
$route = 'CODEX'
$reason = 'No explicit external/local route requested; MANUAL mode defaults to trusted Codex.'

function Test-RoutePrefix {
    param(
        [string]$Text,
        [string[]]$Prefixes
    )
    foreach ($prefix in $Prefixes) {
        if (-not $Text.StartsWith($prefix)) { continue }
        if ($Text.Length -eq $prefix.Length -or $prefix -match '[:\s]$') { return $true }
        if ($Text.Substring($prefix.Length,1) -match '[:\s]') { return $true }
    }
    return $false
}

# Windows PowerShell 5.1 reads UTF-8-without-BOM script files as the active ANSI
# code page. Keep this file ASCII-only and construct the Russian prefix at runtime
# so manual routing remains Unicode-safe regardless of repository file encoding.
$throughRu = -join @(
    [char]0x0447, # ch
    [char]0x0435, # e
    [char]0x0440, # r
    [char]0x0435, # e
    [char]0x0437  # z
)

$apiPrefixes = @(
    ($throughRu + ' api'),
    'api:',
    'api ',
    'through api',
    'via api'
)

$ollamaPrefixes = @(
    ($throughRu + ' ollama'),
    'ollama:',
    'ollama ',
    'through ollama',
    'via ollama'
)

$codexPrefixes = @(
    ($throughRu + ' codex'),
    'codex:',
    'codex ',
    'through codex',
    'via codex'
)

if (Test-RoutePrefix $normalized $apiPrefixes) {
    $route = 'EXTERNAL_API'
    $reason = 'User explicitly requested external API processing.'
}
elseif (Test-RoutePrefix $normalized $ollamaPrefixes) {
    $route = 'OLLAMA'
    $reason = 'User explicitly requested local Ollama processing.'
}
elseif (Test-RoutePrefix $normalized $codexPrefixes) {
    $route = 'CODEX'
    $reason = 'User explicitly requested trusted Codex processing.'
}

[pscustomobject]@{
    mode = 'MANUAL_ONLY'
    route = $route
    reason = $reason
    externalConfigured = $false
} | ConvertTo-Json -Depth 3
