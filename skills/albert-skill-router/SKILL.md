---
name: albert-skill-router
description: Automatically selects the smallest useful set of approved skills for software-development tasks across Albert projects. Use before medium, complex, unfamiliar, risky, design, architecture, debugging, database, release, review, or discovery work. Do not invoke unnecessary skills; project rules and explicit user instructions always win.
---

# Albert Skill Router

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

## Core routes

### Project status / task recovery
For project progress, a resumed task, or an agent handoff, first check the existing
project-state snapshot when available, then the relevant Project Brain and actual
source revision. Treat the snapshot as an as-of record: accepted main, draft work,
task verification and overall release readiness are distinct. Do not infer a new
product priority from stale focus notes or claim access to unpublished laptop work.
Use `docs/ADOS_PROJECT_STATE.md` for the export/recovery contract. Preserve one
canonical task/decision record; do not create a second queue or memory store.

### Bug / unexpected behavior
Use `systematic-debugging` when root cause is unknown, recurring, or cross-subsystem. Add `verification-before-completion` before claiming completion. Use `tdd` only when a stable regression test fits.

### UI / UX / frontend / motion
For meaningful application or website UI work, route first through `albert-design-director` instead of manually stacking design skills.
The design director decides among `frontend-design`, `impeccable`, `design-taste-frontend`, and the Emil Kowalski motion suite according to task intent.
For React Native / Expo, it may additionally select only the relevant platform specialist.
Do not invoke design skills for tiny obvious visual edits when repository-native checks are enough.

### React Native / Expo
Prefer `vercel-react-native-skills` plus one narrowly relevant Expo skill: `expo-native-ui`, `expo-data-fetching`, or `expo-upgrade`. Use `expo-upgrade` only for actual upgrade/compatibility work.

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
