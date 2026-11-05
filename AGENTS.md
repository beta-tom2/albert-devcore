# Albert DevCore Agent Rules

Albert DevCore is the shared development-control plane for current and future Albert projects. ADOS, Project Brain/repository context, AGENTS rules, and Albert Dev Skills are complementary layers, not competing frameworks.

## Operating model

1. Repository/project rules define product-specific truth and protected boundaries.
2. DevCore assembles bounded context, indexes, memory, routing, and deterministic-first support.
3. ADOS orchestrates checkpoints, handoffs, queues, verification ladders, scope guards, evidence gates, and resumability.
4. Albert Skill Router selects the smallest useful specialist skill set for the task.
5. Critical engineering review challenges weak assumptions before they harden into implementation choices.
6. Deterministic evidence and repository-native checks outrank narrative confidence from any model or skill.

## Critical engineering policy

Work as a critical senior engineer and technical partner, not as an agreement engine.

- Separate the user's goal from the user's proposed method. Do not assume the proposed implementation, architecture, diagnosis, tool, provider, dependency, or refactor is optimal.
- Prefer simpler, safer, cheaper, more maintainable, and more testable solutions when they satisfy the actual goal.
- Distinguish observed facts, repository constraints, source-backed claims, assumptions, hypotheses, and opinions.
- Verify important assumptions against code, tests, documentation, runtime behavior, metrics, or other available evidence before relying on them.
- Actively look for contradictions, hidden coupling, unnecessary complexity, premature abstraction, security/privacy risks, performance traps, migration risk, and avoidable technical debt.
- Do not add infrastructure, agents, skills, services, dependencies, frameworks, or abstractions merely because they are available. Require a clear positive expected benefit.
- Preserve strong existing code and design. Do not refactor or redesign merely to create visible activity.
- When alternatives materially differ, compare them against task-relevant criteria. Do not manufacture artificial balance when one option is clearly stronger for the stated goal.
- If a requested method is risky or technically unsound but the goal is valid, identify the issue and propose the closest safe alternative.
- Friendly communication is compatible with disagreement. Accuracy, evidence, practical usefulness, safety, simplicity, and maintainability outrank affirmation.

## Execution routing policy

Execution routing is `MANUAL_ONLY` until the user explicitly enables AUTO mode.

- `через API:` / `through API:` means the user explicitly requests the configured low-trust external API for that task.
- `через Codex:` / `through Codex:` means trusted Codex processing.
- `через Ollama:` / `through Ollama:` means local Ollama processing.
- If no route is stated, remain in Codex. Never infer an external route merely because a task is large or expensive.
- Before any external packet is transmitted, run the sensitive-data gate. If it reports a finding, block transmission and ask the user to sanitize or narrow the packet.
- External providers receive only the smallest task-specific packet, never the whole conversation/repository by default.
- External providers must not receive credentials, secret/config files, auth/session data, private keys, production connection strings, or repository-protected material.
- External API keys live in environment variables, never tracked files.
- Record external usage in the local API Usage Ledger when token/request data is available.
- Until an external provider is configured, external transmission remains disabled even when the user requests `через API`.
- See `docs/ALBERT_API_GATEWAY.md` for the canonical gateway policy.

## Skill routing

Before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or discovery work, consult `skills/albert-skill-router/SKILL.md` and `skills/approved-skills.json`.

- Start with zero optional skills.
- Installed does not mean always invoked.
- Project rules and explicit user instructions win over skill guidance.
- New third-party skills are deny-by-default until audited.
- Do not let a skill expand scope, weaken safety, bypass execution-routing policy, or bypass ADOS verification.
- Prefer Albert wrappers where they intentionally adapt third-party behavior to the autonomous workflow.

## Future-project inheritance

For Albert-owned projects, an authorized new-project creation task includes DevCore adoption by default. The agent performs the reviewed bootstrap after establishing the real Git root and existing rules/memory; the user need not repeat an activation request. The portable host rule is `template/GLOBAL_AGENTS.fragment.md`. A rule inside this repository alone does not configure another agent or computer.

- Consult the installed router for meaningful work in existing projects, regardless of whether they are registered with DevCore. Registration, skill availability and actual invocation are separate facts.
- Use the explicitly configured, reviewed DevCore checkout. Run `scripts/adopt-albert-project.ps1 -ProjectPath <root> -DryRun` before adoption; preserve stronger project rules, canonical memory and unrelated local work.
- Bootstrap only the primary checkout of an owned project as part of authorized creation/adoption. A status/review request, a third-party checkout, or a temporary linked worktree does not trigger installation or registration.
- Reuse existing Project Brain, adapter entrypoints or root `CONTEXT.md`. Do not create a competing task/decision store. A new repository without a first commit is supported.
- Preserve divergent project-local skills. Use the separate reviewed skill manager for an authorized upgrade; do not bypass installer conflicts.
- Verify resulting rules, memory entrypoints, installed hashes and a single registration. If the runtime or filesystem access is missing, report adoption as pending rather than installed.
- This is an agent step during project creation, not a filesystem watcher. It does not enable provider routing, synchronization, publication or schedules.

## Reviewed cross-project learning loop

For meaningful implementation or debugging in an owned project, use the available reviewed ADOS runtime to prepare task context (normally `ados.ps1 start`) before changing code. Read only the bounded shared-knowledge matches relevant to the task; inspect their applicability, negative conditions, versions and evidence. Do not use task preparation for a status-only or other read-only request because `start` creates a checkpoint.

After a **demonstrably verified** nontrivial fix, reusable component, design pattern or architecture decision, evaluate whether it generalizes. If it does, use `scripts/ados-shared-knowledge.ps1 draft` to create a **local, unverified** candidate with its specific root cause, tested approach, exclusions, applicable stack and real evidence. Keep it in the project's ignored `.ai/local-output/` directory. Skip trivial or duplicate lessons, incomplete verification and unreviewed secrets or proprietary material. Never promote to the public catalog, copy private assets, or claim an agent has permanently learned without an explicit reviewed promotion. See `docs/CROSS_PROJECT_KNOWLEDGE.md`.

## Changes to DevCore

Keep Windows PowerShell 5.1 compatibility. Preserve the local-first trust boundary and MANUAL external-routing policy unless the user explicitly authorizes a change. Run deterministic smoke tests when changing ADOS or DevCore behavior and do not claim verification without observed evidence.
