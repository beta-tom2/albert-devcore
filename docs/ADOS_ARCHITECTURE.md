# Albert Development OS (ADOS)

ADOS is the zero-paid-API development operating layer for ATLAS, NAVIRA, and future repositories.

## Goals

- reduce repeated Codex context loading;
- route deterministic work before model work;
- use Ollama only for bounded read-only assistance;
- preserve repository-specific AGENTS.md and safety rules;
- create resumable task packets and handoffs;
- learn from Git history without external databases;
- remain compatible with Windows PowerShell 5.1.

## Architecture

```text
User task
  -> ADOS Dispatcher
  -> Change Detector
  -> DevCore Context Engine
  -> Repair Memory Search
  -> Heat Map
  -> Incremental Hash and Symbol Indexes
  -> Project Adapter and ADR / Negative Memory
  -> Elastic Context
  -> Fix DNA
  -> Prompt Packet
  -> Codex or Local Read-Only Review
  -> Scope Guard
  -> Verification Ladder
  -> Evidence Gate
  -> PR Evidence Summary
  -> Project Health and Trend Baseline
  -> Autonomous Queue Dispatcher and Lease
  -> Checkpoint / Handoff
```

## Modules

### DevCore
Repository adoption, project registry, generated maps, task routing, context budgets, focused test plans, and prompt packets.

### Dispatcher
Classifies tasks into:
- CODEX_REQUIRED
- CODEX_PRIMARY_WITH_DETERMINISTIC_TOOLS
- LOCAL_FIRST_THEN_CODEX_VERIFY

### Change Detector
Uses Git status, staged and unstaged diffs, recent commits, and changed-file paths. It never scans the entire repository when the current change set is enough.

### Repair Memory
Indexes Git commit subjects and changed files into a local JSON file. Similarity is lexical and advisory. Source files and tests remain authoritative.

### Heat Map
Ranks project areas by change frequency and recency. It is a navigation hint, not a quality score.

### Knowledge Graph
Builds a lightweight graph from file imports and path relationships. It does not replace compiler or language-server dependency analysis.

### Fix DNA
Creates a compact signature for a task from terms, likely domains, changed files, route, and related historical repairs.

### Night Audit
Runs deterministic read-only checks for TODO markers, large source files, conflict markers, and repository health. It may optionally request a bounded local-model summary, but it never edits code.

### Handoff
Captures branch, commit, working tree, generated context, checks, task route, and continuation instructions.

### Incremental Hash and Symbol Indexes
Every supported source file receives a SHA-256 content hash. Unchanged records reuse prior import and symbol analysis. The symbol index stores declarations with kind, file, and line; it is deterministic and requires no embeddings or hosted database.

### Test-to-Symbol Association
When the repository already contains `node_modules/typescript` and a `tsconfig.json` or `jsconfig.json`, a bounded helper uses that exact project-local TypeScript language service to resolve declaration references. ADOS never downloads or installs the compiler, stops the process after 35 seconds, caps projects, files, symbols, and references, and records `PASS`, `PARTIAL`, `SKIP`, or `ERROR` explicitly. Compiler evidence strengthens the test map, while the lexical map remains authoritative fallback navigation when the service is absent or bounded.

The test map also links tests to source files using relative imports, package-local unique symbol references, and matching file stems. Nearest package manifests establish monorepo boundaries, so a same-named symbol in another workspace is not treated as evidence. Elastic Context boosts associated tests only for relevant source files. Before verification, ADOS refreshes the map and binds it to the current repository-state fingerprint. Level 3 may run at most 12 focused JavaScript or TypeScript tests when every package uses a recognized path-filtering runner; ambiguous, stale, oversized, or unsupported selections fall back to the full configured suite.

### Elastic Context
Task risk selects a 30 KB small, 90 KB medium, 180 KB large, or 240 KB protected budget. Repository rules and adapter-provided context entrypoints are selected before changed files, exact path terms, symbol names, and imports. Optional base documents such as a large root README cannot consume more than one quarter of the tier budget. Selected files are deduplicated using their current SHA-256 content hash, while skipped duplicates and oversized base files remain visible in the generated report. Generated maps remain navigation aids and source remains authoritative.

### Quality gates
Scope Guard compares changes against the pre-task checkpoint and allowed paths. Verification Ladder records bounded levels from patch integrity through focused tests and build checks, including whether focused selection executed or fell back. Evidence Gate returns `UNVERIFIED` unless the required diff, verification result, scope result, and secret-pattern check all pass. PR Evidence Summary aggregates those local artifacts into bounded JSON and copy-ready Markdown. It fingerprints HEAD, branch, staged and unstaged diffs, and untracked files; any post-verification change produces `NOT_READY` instead of reusing stale evidence.

### Error, regression, and decision memory
Error Fingerprinting removes unstable paths, line numbers, hashes, and large numbers before creating a local signature. Regression Memory associates tasks and fingerprints with approved deterministic commands. ADR Memory indexes repository decision documents, while Negative Memory records failed approaches that should not be repeated without changed evidence.

### Operations
Project adapters identify protected boundaries for ATLAS, NAVIRA, BPMN Studio, and generic projects. Checkpoint/Resume reports branch, commit and working-file drift before continuation. Queue Engine stores work locally. The v0.4 dispatcher leases one eligible item at a time, recovers stale leases, applies `MANUAL_ONLY` routing, prepares deterministic context, and optionally invokes bounded read-only Ollama only when the task explicitly requests that route. A scheduled Codex agent remains responsible for edits, evidence, Draft PR creation, and explicit completion of the exact lease. Night Mode performs read-only indexing and reporting without model calls. Its optional Windows Task Scheduler integration is preview-first, project-scoped, current-user only, Limited privilege, passwordless, exact-name managed, and confirmation-gated for both installation and removal. Project Health reads optional project-owned thresholds, compares them with current deterministic metrics, and stores a bounded local history with previous and rolling-baseline deltas. Invalid configuration produces `CONFIG_ERROR`; missing optional metrics are skipped instead of invented. Usage analytics and A/B benchmarks report deterministic byte and timing proxies, never claimed token billing.

## Storage

Generated local data is stored under:

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

Generated files should remain ignored by Git unless a repository explicitly decides otherwise.

## Trust model

1. Repository rules and source code are authoritative.
2. Deterministic tools are preferred over model guesses.
3. Local-model output is untrusted until verified.
4. Generated maps are navigation aids.
5. Security, authentication, permissions, migrations, production, releases, financial logic, and architectural decisions require Codex-level review and repository-specific authorization.
6. Ollama remains read-only and its output cannot satisfy Evidence Gate by itself.
7. Project adapters never override repository AGENTS.md, ADRs, or existing ATLAS/NAVIRA configuration.

## No-paid-API boundary

ADOS does not require OpenAI API, Anthropic API, NVIDIA NIM, OpenRouter, hosted vector databases, paid embeddings, or hosted caches. The supported cloud reasoning path is the user's included ChatGPT/Codex subscription. Local assistance uses Ollama on the user's machine.
