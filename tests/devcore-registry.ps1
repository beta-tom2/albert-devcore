[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$FixtureParent = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests\.work'))
$Fixture = [IO.Path]::GetFullPath((Join-Path $FixtureParent 'devcore-registry'))
if (-not $Fixture.StartsWith($FixtureParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to prepare a fixture outside tests\.work.'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

if (Test-Path -LiteralPath $Fixture) {
    Remove-Item -LiteralPath $Fixture -Recurse -Force
}
New-Item -ItemType Directory -Path $Fixture -Force | Out-Null

$ProfileRoot = Join-Path $Fixture 'profile'
$RegistryRoot = Join-Path $ProfileRoot '.albert-devcore'
$RegistryPath = Join-Path $RegistryRoot 'projects.json'
$Project = Join-Path $Fixture 'adopted-project'
New-Item -ItemType Directory -Path $Project -Force | Out-Null

Push-Location $Project
try {
    & git init -q
    & git config user.name 'DevCore Registry Test'
    & git config user.email 'devcore-registry@example.invalid'
    Write-Utf8NoBom (Join-Path $Project 'README.md') "# Registry fixture`r`n"
    & git add README.md
    & git commit -q -m 'test: seed registry fixture'
}
finally { Pop-Location }

$legacyRegistry = @'
[
  {
    "value": [
      {"name":"atlas-market-os","path":"C:\\Projects\\atlas-market-os","registered":"2026-08-06T00:00:00+03:00"},
      {"name":"masha-albert-health","path":"C:\\Projects\\masha-albert-health","registered":"2026-08-06T00:01:00+03:00"}
    ],
    "Count": 2
  },
  {"unexpected":"damaged"},
  {"name":"very-vel","path":"C:\\Projects\\very-vel","registered":"2026-08-13T14:33:58+03:00"}
]
'@
Write-Utf8NoBom $RegistryPath $legacyRegistry

$DevCore = Join-Path $RepoRoot 'devcore.ps1'
$Adopt = Join-Path $RepoRoot 'scripts\adopt-albert-project.ps1'
$projectsOutput = (& $DevCore projects -RegistryBasePath $ProfileRoot *>&1 | Out-String)
Assert-True ($projectsOutput -match 'atlas-market-os\s+C:\\Projects\\atlas-market-os') 'projects must flatten legacy registry entries'
Assert-True ($projectsOutput -match 'masha-albert-health\s+C:\\Projects\\masha-albert-health') 'projects must print every valid legacy entry'
Assert-True ($projectsOutput -match 'very-vel\s+C:\\Projects\\very-vel') 'projects must preserve valid flat entries'
Assert-True ($projectsOutput -notmatch 'System\.Object\[\]') 'projects must never print nested array type names'
Assert-True ($projectsOutput -match 'invalid registry element') 'projects must warn about invalid registry elements'

& $Adopt -ProjectPath $Project -RegistryBasePath $ProfileRoot

$backups = @(Get-ChildItem -LiteralPath $RegistryRoot -Filter 'projects.backup-*.json')
Assert-True ($backups.Count -eq 1) 'automatic adoption repair must create exactly one registry backup'

$registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
$entries = @($registry | ForEach-Object { $_ })
Assert-True ($entries.Count -eq 4) 'adoption must preserve three valid projects and register the adopted project'
foreach ($entry in $entries) {
    $properties = @($entry.PSObject.Properties.Name)
    Assert-True (($properties.Count -eq 3) -and ($properties -contains 'name') -and ($properties -contains 'path') -and ($properties -contains 'registered')) 'registry must contain only normalized project objects'
}

$finalOutput = (& $DevCore projects -RegistryBasePath $ProfileRoot *>&1 | Out-String)
Assert-True ($finalOutput -notmatch 'System\.Object\[\]') 'projects output must remain normalized after adoption'
$compactOutput = $finalOutput -replace '\s',''
$compactProject = $Project -replace '\s',''
Assert-True ($compactOutput.Contains($compactProject)) 'projects must print the newly adopted project path'

Write-Host 'DevCore registry regression test: PASS'
