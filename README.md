# Albert DevCore and ADOS

Free local development infrastructure for ATLAS, NAVIRA, and future projects.

## Principles

- no paid AI APIs;
- Codex is used for architecture, critical code, and final verification;
- Ollama is limited to bounded read-only tasks;
- deterministic tools run before model work;
- context is assembled incrementally instead of rereading the repository;
- existing AGENTS.md and repository-specific rules remain authoritative;
- generated memory and analytics remain local by default;
- Windows PowerShell 5.1 compatibility is required.

## DevCore commands

```powershell
.\devcore.ps1 doctor
.\devcore.ps1 adopt -ProjectPath "C:\path\to\repo"
.\devcore.ps1 register -ProjectPath "C:\path\to\repo"
.\devcore.ps1 projects
.\devcore.ps1 registry-repair
.\devcore.ps1 update -ProjectPath "C:\path\to\repo"
.\devcore.ps1 route -Task "Review README wording"
.\devcore.ps1 packet -ProjectPath "C:\path\to\repo" -Task "Fix a friends bug"
.\devcore.ps1 local -ProjectPath "C:\path\to\repo" -Task "Review documentation" -Files @("README.md")
.\devcore.ps1 review -ProjectPath "C:\path\to\repo"
```

## ADOS commands

ADOS orchestrates DevCore, incremental indexes, project memory, verification evidence, local queues, audits, and handoffs. It prepares work and verifies evidence; it does not silently edit product code or call a paid model API.

```powershell
.\ados.ps1 doctor

.\ados.ps1 start `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the error when adding a found user as a friend"

.\ados.ps1 analyze `
  -ProjectPath "C:\path\to\repo" `
  -Task "Prepare the next safe project stage"

.\ados.ps1 night `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 scheduler `
  -ProjectPath "C:\path\to\repo" `
  -SchedulerAction preview `
  -DailyAt "03:00"

.\ados.ps1 dispatch `
  -ProjectPath "C:\path\to\repo" `
  -DispatchAction run

.\ados.ps1 health `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 handoff `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 resume `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 verify `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the friends flow" `
  -AllowedScope @("src\friends", "tests\friends") `
  -MaxVerificationLevel 3

.\ados.ps1 pr-summary `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 queue `
  -ProjectPath "C:\path\to\repo" `
  -QueueAction add `
  -Task "Prepare the next read-only audit" `
  -Priority normal

.\ados.ps1 benchmark `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the friends flow"

.\ados.ps1 stats `
  -ProjectPath "C:\path\to\repo"

.\ados.ps1 failure `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the friends flow" `
  -LogPath ".\test-output.log"

.\ados.ps1 remember-regression `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the friends flow" `
  -RegressionCommand "npm test -- friends" `
  -Files @("src\friends.ts", "tests\friends.test.ts")

.\ados.ps1 remember-negative `
  -ProjectPath "C:\path\to\repo" `
  -Task "Fix the friends flow" `
  -Attempt "Change RLS" `
  -Outcome "Not the root cause" `
  -Files @("src\friends.ts")
```

`start` saves a pre-change checkpoint, detects the project adapter, refreshes local memory, builds symbol-aware elastic context, and creates the prompt packet and handoff. `verify` refreshes deterministic indexes, runs Scope Guard, the bounded Verification Ladder, and Evidence Gate, then writes a bounded PR evidence summary. When a current test-to-symbol map finds at most 12 JavaScript or TypeScript tests under a recognized package runner, level 3 runs those package-local tests; otherwise it safely falls back to the existing full-suite behavior. `pr-summary` regenerates that summary without rerunning checks and marks it `NOT_READY` if the repository changed after Evidence Gate. A task is reported as `VERIFIED` only when required evidence was actually observed.

## ADOS modules

### Portable project memory

Use the [project-state contract](docs/ADOS_PROJECT_STATE.md) to export a bounded,
revision-addressed checkpoint for another session. Configure explicit document
sources in `.ados/state-export.json`, then run:

```powershell
.\ados.ps1 state-export -ProjectPath "C:\path\to\repo"
.\ados.ps1 state-validate -SnapshotPath "C:\path\to\repo\.ai\local-output\project-state.json"
.\ados.ps1 state-read -SnapshotPath "C:\path\to\repo\.ai\local-output\project-state.json"
```

The default output stays local. Export does not push data or start an external
service. Publish a reviewed snapshot in its own project's authorized repository;
keep private project data out of public DevCore. Accepted main, observed drafts,
checkpoint verification and release readiness remain separate claims.

Queue completion now requires current evidence for the claimed task. Renew a
still-valid lease using `dispatch -DispatchAction renew -QueueId ...
-DispatchLeaseId ...`; expiry never grants the old worker permission to continue
writing shared files. Skill installation uses the policy and hash-locked local
artifacts; it no longer performs unpinned package-manager downloads.

### Available modules

- Dispatcher: selects Codex, deterministic-first, or local-first execution.
- Change Detector: reads current Git state before broad repository context.
- Context Engine: generates maps, focused checks, and task packets.
- Repair Memory: indexes commit subjects and changed paths locally.
- Heat Map: ranks frequently and recently changed areas.
- Knowledge Graph: creates a lightweight import relationship graph.
- Fix DNA: records task terms, route, domains, and changed files.
- Night Audit: reports conflict markers, large files, TODOs, and repository status without editing code.
- Handoff: creates a resumable continuation packet.
- Incremental Hash Index: hashes source files and reuses imports and symbols when content did not change.
- Symbol Index: maps functions, classes, types, and other language-level declarations to files and lines.
- Compiler Reference Resolver: optionally uses a project-local TypeScript language service with strict time and result limits; it never installs dependencies.
- Test-to-Symbol Map: associates tests with source files using relative imports, unique symbols, matching stems, and monorepo package boundaries.
- Elastic Context: chooses a risk-based budget, prioritizes repository entrypoints, and removes duplicate file content by SHA-256.
- Error Fingerprinting: normalizes failures into stable local signatures and recurrence counts.
- Regression Memory: links bugs, related files, and approved deterministic regression commands.
- ADR and Negative Memory: retrieves accepted decisions and rejected approaches relevant to the current task.
- Log Compressor: keeps the first root failure, useful stack frames, and repeat counts instead of full noisy logs.
- Scope Guard: compares post-checkpoint changes with explicit allowed scope and protected paths.
- Verification Ladder: stops at the requested level and records each observed check.
- Evidence Gate: refuses a verified status when diff, checks, scope evidence, or secret scanning is missing.
- PR Evidence Summary: creates a copy-ready local Markdown report and rejects stale Evidence Gate artifacts using a repository-state fingerprint.
- Project Adapters: detects ATLAS, NAVIRA, BPMN Studio, and generic web/mobile boundaries, supplies repository entrypoints, and never rewrites project settings.
- Checkpoint and Resume: records task, branch, HEAD, baseline changes, and continuation phase.
- Queue Engine: maintains a local priority queue; queue inspection never executes a task by itself.
- Night Mode: refreshes indexes, decisions, audits, queue status, and usage summaries without model calls or product-code changes.
- Night Mode Scheduler: previews, installs, inspects, or removes one project-scoped Windows task; install and uninstall require explicit confirmation and use the current interactive user with Limited privileges.
- Autonomous Dispatcher: leases one queued task, applies the central route policy, optionally runs bounded read-only Ollama, prepares Codex context, and requires the exact lease for completion or release.
- Project Health and Trends: compares deterministic metrics with optional project-owned `.ados/health.json` thresholds and keeps a bounded local trend history.
- Usage Analytics: records local stage duration and byte-selection estimates, not claimed billing data.
- A/B Benchmark: compares fixed lexical selection with elastic symbol-aware selection using deterministic proxy metrics.

Architecture details are in `docs/ADOS_ARCHITECTURE.md`.

### Autonomous queued work

Add work to the local queue, then let a Codex or ChatGPT Scheduled Task call the dispatcher:

```powershell
.\ados.ps1 queue -ProjectPath "C:\path\to\repo" -QueueAction add -Task "Review README wording" -Priority low
.\ados.ps1 dispatch -ProjectPath "C:\path\to\repo" -DispatchAction run
```

The dispatcher claims at most one task with a time-bounded lease and writes `.ai/queue/dispatch.generated.json` plus a concise agent handoff. A second run returns `BUSY` until the lease is completed, released, or expires. Documentation and other low-risk work may receive an automatic read-only Ollama first pass; all edits and every protected domain remain Codex-owned. Completion and release require the exact queue ID and lease ID. The dispatcher never merges, deploys, or changes production.

The recommended background agent prompt and lifecycle are documented in `docs/ADOS_AUTONOMOUS_DISPATCHER.md`. For local-project Scheduled Tasks, keep the computer on, ChatGPT desktop running, and the repository available at its configured path.

### Optional Windows schedule

Start with a non-mutating preview. It writes a local plan under `.ai/analytics/` and does not touch Windows Task Scheduler:

```powershell
.\ados.ps1 scheduler `
  -ProjectPath "C:\path\to\repo" `
  -SchedulerAction preview `
  -DailyAt "03:00"
```

After reviewing the preview, installation still requires an explicit confirmation flag. It creates one stable project-scoped task, runs only while the current user is logged on, uses Limited privileges, stores no password, and refuses to replace an existing task by default:

```powershell
.\ados.ps1 scheduler `
  -ProjectPath "C:\path\to\repo" `
  -SchedulerAction install `
  -DailyAt "03:00" `
  -ConfirmSchedulerInstall
```

Use `-SchedulerAction status` to inspect it. Removal is exact-name only and requires `-ConfirmSchedulerUninstall`. Replacing an existing task additionally requires `-ReplaceScheduledTask`. Moving the DevCore directory after installation requires reinstalling the task because the action stores the absolute local path to `ados.ps1`.

## Generated local files

ADOS may create files under:

```text
.ai/context/
.ai/memory/
.ai/analytics/
.ai/local-output/
.ai/index/
.ai/evidence/
.ai/checkpoints/
.ai/queue/
```

The orchestrator adds them to `.git/info/exclude` so they remain local even when a project does not yet contain shared ignore rules.

## Trust boundary

DevCore and ADOS do not give local models permission to modify product code. Local-model output, generated dependency maps, historical similarity, Heat Map scores, and audit findings are advisory until verified against source code, deterministic checks, and Codex review.

Security, authentication, permissions, RLS, migrations, production, releases, financial logic, dependencies, and architecture remain protected domains.

Built-in adapters add project-specific protected boundaries. ATLAS keeps live trading, broker access, real money, and risk gates protected. NAVIRA keeps Supabase RLS, SQL migrations, authentication, notifications, and production EAS builds protected. These adapters are advisory and do not modify the projects. A future project can provide `.ados/adapter.json` using `template/.ados/adapter.example.json` as a starting point.

Projects may also copy `template/.ados/health.example.json` to `.ados/health.json` and tune known thresholds. ADOS never creates or edits that project-owned file. Without it, conservative built-in thresholds are used. Health snapshots and reports remain local under `.ai/analytics/`; identical consecutive states replace the latest snapshot instead of growing history.

## Verification

Run the deterministic integration fixture under Windows PowerShell 5.1:

```powershell
.\tests\ados-smoke.ps1
```

The test creates an isolated Git fixture under `tests/.work/`, exercises the complete v0.4 pipeline, and expects `ADOS v0.4 smoke test: PASS`.

Pull requests that touch ADOS code run the same parser and smoke checks on a standard Windows runner using Windows PowerShell 5.1. The workflow is deterministic, read-only outside its disposable fixture, and does not call a model or paid API.

`rg` remains the preferred fast search path. When it is unavailable, prompt-packet candidate discovery falls back to bounded native PowerShell scanning, so a clean Windows machine can still run ADOS without installing another tool.
