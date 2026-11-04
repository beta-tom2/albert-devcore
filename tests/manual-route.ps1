[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$devcore = Join-Path $root 'devcore.ps1'
$manual = Join-Path $root 'scripts/manual-execution-router.ps1'
$checks = 0

function Assert-Route([string]$Task, [string]$Expected) {
    $actual = (& $devcore route -Task $Task | Out-String).Trim()
    if ($actual -ne $Expected) { throw "Unexpected route for '$Task': $actual" }
    $script:checks++
}

Assert-Route 'Review README wording' 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'
Assert-Route 'Summarize documentation and changelog' 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'
Assert-Route 'Fix the refresh flow' 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'
Assert-Route 'through Codex: Review README wording' 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'
Assert-Route 'through Ollama: Review README wording' 'LOCAL_FIRST_THEN_CODEX_VERIFY'
Assert-Route 'ollama: summarize a bounded log' 'LOCAL_FIRST_THEN_CODEX_VERIFY'
Assert-Route 'through Ollama: review authentication' 'CODEX_REQUIRED'
Assert-Route 'Review Supabase RLS' 'CODEX_REQUIRED'
Assert-Route 'through Ollamax: Review README wording' 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'

$throughRu = -join @([char]0x0447,[char]0x0435,[char]0x0440,[char]0x0435,[char]0x0437)
Assert-Route ($throughRu + ' Ollama: Review README wording') 'LOCAL_FIRST_THEN_CODEX_VERIFY'
Assert-Route ($throughRu + ' Codex: Review README wording') 'CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS'

$failed = $false
try { & $devcore route -Task 'through API: Review README wording' | Out-Null }
catch { $failed = $_.Exception.Message -match 'does not dispatch external API' }
if (-not $failed) { throw 'An unsupported external API route must fail before dispatch.' }
$checks++

$policy = (& $manual -Task 'through APIology: review wording' | Out-String) | ConvertFrom-Json
if ($policy.mode -ne 'MANUAL_ONLY' -or $policy.route -ne 'CODEX') { throw 'Lookalike prefixes must not authorize another provider.' }
$checks++
Write-Host "Manual execution routing: PASS ($checks scenarios; no provider calls)"
