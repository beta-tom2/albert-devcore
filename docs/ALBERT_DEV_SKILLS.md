# ALBERT DEV SKILLS

ALBERT DEV SKILLS is the selective skill layer for Albert DevCore / ADOS.

## Goal

Make useful skills available by default across current and future development projects without forcing every skill into every task.

The system separates five concerns:

1. **Availability** — approved skills may be installed globally or per project.
2. **Routing** — `albert-skill-router` selects the smallest useful set for a task.
3. **Domain routing** — wrappers such as `albert-design-director` and `albert-architecture-review` coordinate overlapping expert skills.
4. **Project authority** — repository `AGENTS.md`, scoped rules, adapters, Project Brain, and explicit user instructions override skills.
5. **Evidence** — deterministic checks and ADOS Evidence Gate outrank narrative claims from any skill.

## Default policy

- Installed does not mean invoked.
- Optional skill count should normally stay small.
- Third-party skills are deny-by-default until audited.
- A skill may not expand authorized scope.
- A skill may not turn a read-only task into edits.
- Protected operations remain protected regardless of skill instructions.
- Skills that repeatedly add noise or reduce quality should be demoted or disabled by route, not kept from habit.

Approved status is recorded in `skills/approved-skills.json`. This is the only installation policy list; the installer no longer maintains a second hardcoded list.

Artifact identity is recorded separately in `skills/skills-lock.json`. Approval describes how a skill may be used, while an audited artifact determines whether this repository may install it. Existing external skills are not removed merely because their exact local or ChatGPT bytes have not yet been audited.

## Approved pack

### Meta / routers
- `albert-skill-router`
- `albert-design-director`
- `albert-architecture-review`
- `find-skills`

### Design direction / polish
- `frontend-design` — primary concept/direction skill for meaningful new UI or substantial redesigns.
- `impeccable` — critique, audit, polish, hardening, responsive/adaptive cleanup, anti-pattern detection.
- `design-taste-frontend` — conditional experimental creative-variance skill; never the default design authority.

### Motion / design engineering
Routed selectively through `albert-design-director`:
- `emil-design-eng`
- `animate`
- `find-animation-opportunities`
- `improve-animations`
- `review-animations`
- `apple-design` (conditional)

### UI / mobile implementation
- `expo-native-ui`
- `expo-data-fetching`
- `expo-upgrade`
- `vercel-react-native-skills`

### Backend / data
- `supabase`
- `supabase-postgres-best-practices`

### Engineering quality
- `systematic-debugging`
- `verification-before-completion`
- `tdd`

### Architecture suite
Use only under `albert-architecture-review` for broad architecture work when needed:
- `improve-codebase-architecture`
- `codebase-design`
- `domain-modeling`
- `grilling` (interactive-only unless explicitly requested)

`ai-video-generation` from `skills-101/superpowers` remains intentionally unapproved.

## Priority profile and candidate directions

The registry's `prioritySkills` list records these fifteen priorities without activating all of them for every task:

1. `verification-before-completion`
2. `systematic-debugging`
3. `expo-native-ui`
4. `expo-data-fetching`
5. `vercel-react-native-skills`
6. `supabase`
7. `supabase-postgres-best-practices`
8. `domain-modeling`
9. `codebase-design`
10. `frontend-design`
11. `impeccable`
12. `tdd` (Matt Pocock lineage)
13. `writing-plans` (reference only: integrate useful contract fields into ADOS)
14. `playwright-cli` (candidate: first reuse the project's existing browser tooling)
15. `differential-review` (candidate: a separate package audit is still required)

The first twelve directions were already represented in the user's skill set. That does not prove identical versions are installed on the laptop, in ChatGPT, and in this repository. The three new entries are recommendations, not installed artifacts or automatically approved dependencies.

`writing-plans` has useful interface, dependency, and acceptance conventions, but its upstream workflow requires additional Superpowers skills and blocking plan confirmation. Those workflow requirements are not adopted. Playwright needs a compatible runtime and its referenced guides; an existing project Playwright installation should be used before adding another tool. Trail of Bits' package uses CC-BY-SA-4.0 and includes supporting guides and an agent integration that must be reviewed together before installation.

## Design routing examples

### Tiny spacing/copy fix
No design skill if deterministic project checks are sufficient.

### New Expo screen
`albert-design-director` normally selects `frontend-design` + relevant Expo/RN specialist. `impeccable` may be used later for a final polish pass.

### Existing UI looks generic
`impeccable`; add experimental `design-taste-frontend` only when a creative reset or higher visual variance is actually wanted.

### Add purposeful motion to existing UI
`find-animation-opportunities` -> implement only selected opportunities -> `review-animations`.
If exact motion is already specified, use `animate` -> `review-animations`.

### Existing motion feels wrong
`improve-animations` -> selected implementation -> `review-animations`.

### Final UI shipping pass
`impeccable` + repository-native accessibility/responsive/performance checks + `verification-before-completion` when task risk warrants it.

## Other routing examples

### Unknown recurring bug
`systematic-debugging` + `verification-before-completion`; add `tdd` only if a durable regression test fits.

### Supabase query performance issue
`supabase-postgres-best-practices`; add `supabase` when platform semantics matter.

### Broad architecture review
`albert-architecture-review` coordinates the architecture suite. Do not trigger it for a local rename or tiny refactor.

## Reproducible local installation

The checked-in lock currently verifies the exact SHA-256 bytes of the three repository-owned routing skills. External entries are explicitly `needs-audit` or `not-installable`; upstream lineage is not a substitute for a reviewed immutable package. The installer never fetches external packages, invokes `npx`, or installs every registered skill.

The lock's `baselineRevision` identifies the audited starting commit. The local file hashes identify the bytes to install, including reviewed changes made after that baseline. This is a DevCore lock format, not the Vercel CLI's `skills-lock.json` format.

Preview first:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global -DryRun
```

Install the three verified wrappers globally:

```powershell
.\scripts\install-albert-dev-skills.ps1 -Global
```

`-Global` targets `%USERPROFILE%\.agents\skills` on Windows, with the current home directory as fallback. This makes those local wrappers available to compatible agents; it does not install or update ChatGPT/Work skills.

For a project, or a single wrapper:

```powershell
.\scripts\install-albert-dev-skills.ps1 -ProjectPath "C:\path\to\repo" -DryRun
.\scripts\install-albert-dev-skills.ps1 -ProjectPath "C:\path\to\repo"
.\scripts\install-albert-dev-skills.ps1 -ProjectPath "C:\path\to\repo" -Skill albert-skill-router
```

Choose `-Global`, `-ProjectPath`, or both explicitly. Before creating target directories, the installer checks every selected artifact against the registry and complete file manifest. Missing or changed bytes, unreviewed source files, invalid paths, linked paths, and unresolved external skills fail closed. A different existing target copy is preserved and reported for review; identical copies are left untouched. A conflicting target does not cause a partial update of the other selected skills.

For an existing customized or older installation, inspect its diff against the locked wrapper and preserve that copy before replacing it. Do not use this installer as an implicit way to overwrite local adaptations.

### Updating a local hash after review

Review the skill change first. Keep the skill file and its lock update in the same Git change. The installer deliberately does not refresh hashes itself.

From the DevCore repository root, update only the reviewed skill's existing manifest entries, for example:

```powershell
$skillName = 'albert-skill-router'
$lockPath = Join-Path $PWD 'skills/skills-lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = @($lock.skills | Where-Object { $_.name -eq $skillName -and $_.state -eq 'verified-local' })[0]
if (-not $entry) { throw 'Reviewed local skill not found in the lock.' }
foreach ($file in $entry.files) {
    $path = Join-Path (Join-Path $PWD $entry.path) $file.path
    $file.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$json = ($lock | ConvertTo-Json -Depth 15) + "`n"
[IO.File]::WriteAllText($lockPath, $json, (New-Object Text.UTF8Encoding($false)))
.\tests\devcore-skills.ps1
```

If the reviewed change adds reference files, add their explicit relative paths and SHA-256 values to the same entry. Preserve LF line endings for the locked Markdown files across Windows and other checkouts so a newline conversion is not mistaken for an audited content change.

### Before installing an external skill

Resolve an immutable source revision, read its license, audit the complete selected artifact and executable dependencies, and compare it with any existing adapter. The candidate metadata in the lock records only the entrypoint/license review; it does not approve the unreviewed references or runtime. Add a deterministic installation path only when that concrete need exists. Do not silently replace an installed short adapter with a larger upstream workflow.

Run the focused installer contract checks with `tests/devcore-skills.ps1`. They use disposable temporary profiles and projects, verify copied hashes and idempotence, and exercise failures before writes. Windows PowerShell 5.1 remains the compatibility target.

## One-command project adoption

Use the wrapper below for current and future repositories:

```powershell
.\scripts\adopt-albert-project.ps1 -ProjectPath "C:\path\to\repo"
```

The wrapper deliberately preserves existing project files and then performs the Albert adoption sequence:

1. runs DevCore `adopt` to install/preserve `AGENTS.md`, Project Brain context templates, local model policy, registration, repository maps and focused test context;
2. copies the three Albert routing skills locally under `.agents/skills/`: `albert-skill-router`, `albert-architecture-review`, and `albert-design-director`;
3. prepares local `.ai/analytics/` storage for Skill Telemetry and excludes it from Git commits;
4. refreshes generated DevCore context after all routing files are present.

Third-party skills remain global rather than being copied into every repository. This keeps project repositories small while making the Albert routing layer project-local and deterministic.

If the repository already has stricter `AGENTS.md` or context files, they are preserved rather than overwritten.

## New project adoption

For a new repository, the expected default is now one command:

```powershell
.\scripts\adopt-albert-project.ps1 -ProjectPath "C:\path\to\new-repo"
```

This removes the need to remember separate DevCore, Project Brain, Skill Router, Design Director and telemetry setup steps. Meaningful UI/UX/frontend/motion work routes through `albert-design-director`; backend-only and tiny visual work should not pay design-skill overhead.

## ChatGPT / Work

OpenAI Skills can be automatically selected once installed in supported ChatGPT environments. Personal Skills availability depends on plan/workspace, and personal skills may require separate installation across product surfaces.

Therefore the Git repository is the canonical source of truth, while ChatGPT/Work installation remains an adapter step rather than assumed implicit state.

## Review loop

Use Skill Telemetry on real tasks. Periodically evaluate:
- did the selected skill improve correctness or visual quality?
- did it reduce exploration or rework?
- did it introduce unnecessary process or design churn?
- did it conflict with project rules or an established design system?
- did it inflate context without improving output?

Update the approved registry from repeated evidence, not popularity alone.
