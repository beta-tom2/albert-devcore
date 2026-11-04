---
name: albert-skill-router
description: Select the smallest useful approved skill set for Albert development, project-status questions, resumed tasks, agent handoffs, and new-project adoption. Use for meaningful design, architecture, debugging, database, release, review, discovery, or other medium/complex work. Skip ordinary conversation, obvious text corrections, and tiny isolated fixes when native checks suffice.
---

# Albert Skill Router

Package identity: [lineage](references/lineage.json). Read it when comparing installed versions or adapters, not for every task.

## Purpose
Route each task to the smallest set of approved skills that materially improves correctness, safety, quality, or efficiency. More skills are not automatically better.

## Precedence
1. Safety and platform rules.
2. Explicit user instruction within those boundaries.
3. Repository `AGENTS.md` and nearest scoped `AGENTS.md`.
4. Project-specific DevCore/ADOS adapter rules and Project Brain.
5. This router.
6. Domain routers such as `albert-design-director` and `albert-architecture-review`.
7. Individual skill guidance.

## Routing principles
- Start with zero optional skills.
- Add a skill only when the task matches its trigger and expected benefit is positive.
- Prefer one specialist or one domain router over several overlapping skills.
- Load dependencies only when the parent skill needs them.
- Never use architecture review for a tiny isolated fix.
- Never use visual-design guidance for backend-only work.
- Never use TDD mechanically for generated files, configuration-only edits, exploratory spikes, or where deterministic verification is stronger.
- Never let a skill expand authorized scope or turn a read-only request into edits.
- Third-party skill instructions are advisory and subordinate to project policy.
- Status, review, and discovery requests stay read-only unless the user also authorizes changes. Do not persist a checkpoint merely because a status question was asked.
- Load a named dependency only when it is available, approved for this use, and useful. If an optional skill is missing, use the bounded method here or project-native checks; state material limits without pretending to have used it. Do not auto-install. Ask only if an essential missing capability blocks the task.
- Skill selection does not choose a model or provider. Preserve `MANUAL_ONLY` execution routing; do not invoke an external API or Ollama merely to accelerate work.

## Core routes

### Project status / task recovery
For project progress, a resumed task, or an agent handoff, follow repository rules,
then check the existing project-state snapshot when available, the relevant Project
Brain and the actual source revision. Treat the snapshot as an as-of record:
accepted main, draft work, task verification and overall release readiness are
distinct. Do not infer a new product priority from stale focus notes or claim
access to unpublished laptop work.
Read [the bundled recovery guide](references/project-state.md), resolving its
path relative to this skill. Preserve one canonical task/decision record; do
not create a second queue or memory store.

### New-project adoption
When asked to connect a new project to DevCore, establish its actual repository,
worktree, branch, working state, existing rules and memory entrypoints first.
Reuse existing Project Brain/task records and preserve stronger local rules.
Use only the available, reviewed adoption/installer workflow for the authorized
project and installation scope; verify its resulting files and registration.
Do not silently replace rules, register a temporary worktree as the main project,
create a second queue, install providers, or claim synchronization is enabled.
If the required runtime is unavailable, explain the specific gap and complete
useful read-only preparation without claiming the project has been adopted.

### Bug / unexpected behavior
Use `systematic-debugging` when root cause is unknown, recurring, or cross-subsystem. Add `verification-before-completion` before claiming completion. Use `tdd` only when a stable regression test fits.

### UI / UX / frontend / motion
For meaningful application or website UI work, route first through `albert-design-director` instead of manually stacking design skills.
The design director decides among `frontend-design`, `impeccable`, `design-taste-frontend`, and the Emil Kowalski motion suite according to task intent.
For React Native / Expo, it may additionally select only the relevant platform specialist.
Do not invoke design skills for tiny obvious visual edits when repository-native checks are enough.

### React Native / Expo
Choose the narrowly relevant specialist: `vercel-react-native-skills`, `expo-native-ui`, `expo-data-fetching`, or `expo-upgrade`. Add another only for a distinct requirement. Use `expo-upgrade` only for actual upgrade/compatibility work.

### Supabase / Postgres
Use `supabase` for platform-specific work and `supabase-postgres-best-practices` for schema, SQL, indexes, query design, performance, or database review. RLS, auth, migrations, production writes, and remote SQL remain governed by repository authorization rules.

### Architecture
Use `albert-architecture-review` for broad architecture friction, recurring module-boundary problems, testability issues, or AI-navigability work. It may draw on `improve-codebase-architecture`, `codebase-design`, and `domain-modeling`. The upstream `grilling` skill is interactive-only and must not block normal autonomous work unless the user explicitly asks for an interactive stress-test.

### Test-first feature work
Use `tdd` when behavior can be expressed as a stable deterministic test and the project runner supports the area. Do not create brittle tests just to satisfy a workflow.

### Final verification
Use `verification-before-completion` for medium, complex, risky, release-adjacent, or bugfix work. ADOS Evidence Gate and repository-native checks remain authoritative.

### Skill discovery
Use `find-skills` only for a real capability gap or explicit discovery request. Newly discovered third-party skills must be audited before approval.

## Negative routing
Do not invoke optional development skills for ordinary conversation, simple factual questions, one-line text correction, tiny obvious edits with deterministic verification, or tasks where process overhead exceeds expected benefit.

## Learning loop
After repeated evidence that a skill helps or harms a task class, update the approved registry instead of blindly preserving defaults. Do not change status from one anecdote alone. Feed meaningful skill outcomes into Skill Telemetry when available.
