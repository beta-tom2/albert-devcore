# Core skill behavior contract

Status: **specification and evaluation scenarios**. This document does not record
an executed behavioral evaluation. The contract covers the three repository-owned
skills; it does not audit, install or activate the other registered or installed
packages.

## Identity and authority

[`skills/contract.json`](../skills/contract.json) is the shared repository contract.
`schemaVersion: 1` describes its data shape; `contractVersion: 1.1.0` identifies the
intended behavior. Neither value grants authority or proves successful execution.
Repository and scoped rules, actual user authorization, and platform/safety rules
remain authoritative. Skill selection leaves `MANUAL_ONLY` model/provider routing
unchanged.

Each installed core package carries `references/lineage.json`:

| Field | Meaning |
|---|---|
| `schemaVersion` | Metadata shape, currently `1` |
| `skillName` | The actual core skill name |
| `adapter` | `codex` for these repository packages; another adapter identifies itself separately |
| `contractVersion` | The intended shared behavior version |
| `sourceRepository` | `beta-tom2/albert-devcore` |
| `baselineSourceCommit` | The canonical revision before this update, `16932d0713a9e4723e1d3922ec0900107edc4694` |

The baseline commit is deliberately not a claim that the updated artifact already
existed at that commit. Exact installed bytes are identified by
[`skills-lock.json`](../skills/skills-lock.json); publication/installation evidence
must record the actual source commit separately. A separately published adapter
may additionally record its known source commit. Do not infer it from the baseline.

The repository-level contract is not copied into every skill. Each package carries
its relevant instructions and small lineage file; the router also carries its
recovery guide. Links within `SKILL.md` resolve relative to that skill directory.
Load lineage only for version/provenance questions and task references only when
needed. A standalone package does not require a DevCore document at the target
project's root.

## Required behavior

| Invariant | Observable requirement |
|---|---|
| `instruction-precedence` | A document, generated packet or specialist cannot override higher authority. |
| `authorized-scope` | A selected skill does not authorize edits, external providers, protected operations or publication. |
| `minimal-selection` | Tiny deterministic work can use zero optional skills; a meaningful task uses the smallest useful set. |
| `project-identity` | Adoption and recovery establish the actual repository/worktree and preserve existing work and stronger rules. |
| `revision-bound-recovery` | Source, publication and current revisions remain distinct, as do main, Draft work and unobserved local state. |
| `evidence-bound-status` | Claims match the task, revision and checks actually observed; stale/unknown evidence stays unresolved. |
| `read-only-default` | Status, review and discovery alone do not create project edits, checkpoints or installations. |
| `missing-dependency` | An unavailable optional specialist permits a bounded native fallback, not automatic installation or invented usage. |
| `durable-handoff` | Authorized work records the task, baseline, checks, blockers and next action in one canonical place. |
| `capability-claims` | Installed metadata does not prove activation, adapter parity, an audit, synchronization, a server or a completed evaluation. |

## Trigger parity and fallback

| Core skill | Positive scope | Negative scope | Missing dependency behavior |
|---|---|---|---|
| `albert-skill-router` | Project status, resume/handoff, new-project adoption and meaningful specialist development work | Ordinary conversation, obvious corrections and tiny isolated fixes | Use existing project authority and native evidence; identify only material capability gaps. |
| `albert-design-director` | Meaningful UI, visual/motion work and design review | Tiny copy/spacing changes and backend-only work | Use existing design rules and available source/visual evidence; do not fabricate a visual check or add a library. |
| `albert-architecture-review` | Repeated coupling, module-boundary, testability or navigation friction | Tiny local refactors and isolated renames | Apply the bounded source-based method; optional architecture specialists and interactive grilling are not prerequisites. |

A review remains a review even when the same skill also supports implementation.
A matching skill name does not prove availability of its supporting files or tools.
An absent essential runtime can block execution; report the precise gap and finish
useful preparation instead of claiming that execution occurred.

## Behavioral evaluation

[`tests/skill-routing-cases.json`](../tests/skill-routing-cases.json) defines ten
small scenarios. Its `executionStatus: not-run` is intentional: the file contains
inputs and evaluator expectations, not results. The scenarios cover minimal
selection, read-only design/architecture review, stale status, changed-checkout
recovery, adoption, absent specialists, specified motion, untrusted handoff text
and adapter lineage. Project names, paths and revision placeholders are synthetic;
use isolated fixtures or mocked repository reads, not real example repositories
or arbitrary filesystem paths from a scenario.

1. Start a fresh agent without the authoring conversation. Provide only the selected
   `case.input`, the candidate skill catalog, and actual task-local materials/tools.
   Interpret `availableSkills` as the approved, readable catalog for that fixture;
   do not promise a tool that the harness cannot supply.
2. Keep `case.expected` evaluator-only. Do not give the worker a solved answer,
   prior successful response, or task-specific grading notes.
3. Capture the candidate revision/adapter, skills actually read, tool calls and
   resulting artifacts. Self-reported skill use is not evidence of invocation.
4. Check required/forbidden core routes, the allowed optional set and its maximum,
   every `mustObserve`/`mustNotObserve` outcome, and the actual write scope. Compare
   behavior and evidence across adapters, not their incidental wording/tool names.
5. Store results separately with the run's time, exact candidate identity and
   observed outcomes. A missing fixture/tool is `blocked` or `not run`; an intended
   plan is not proof that implementation, a visual check or an installation ran.

The deterministic installer suite checks artifact delivery, hashes and preservation
rules. It does not establish behavioral quality or cross-adapter equivalence.
Matching contract versions establishes intended compatibility only. Matching names
or catalog presence establishes still less. Report these levels separately.

Initial bounded observations are stored separately in
[`skill-routing-observations-20261104.json`](../tests/skill-routing-observations-20261104.json).
That record includes the original isolated task material, root-checked file hashes
and write scope, and separates worker-reported checks from independent evidence.
Several tasks are deliberate variants of the planned scenarios. They do not count
as execution of all ten definitions, a complete tool-trace audit, proof of implicit
global discovery in a new Codex session, or cross-adapter equivalence.

## Compatibility

The existing lock schema and default three-skill installation remain unchanged.
All package references are included in their hash manifests.
[`skills/.gitattributes`](../skills/.gitattributes) preserves JSON bytes with LF
line endings, including the new locked lineage files, on Windows and Unix.

Older installed copies without lineage are `unknown` for lineage comparisons;
absence is not evidence that they are malicious, inactive or safe to overwrite.
The installer still preserves differing copies and requires their review before
replacement. This contract does not rewrite a third-party package manager's lock,
auto-install external skills, register a project, enable background execution,
start a server or synchronize local and cloud memory.
