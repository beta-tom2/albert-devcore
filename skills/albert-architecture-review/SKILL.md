---
name: albert-architecture-review
description: Review broad codebase architecture for recurring friction, module-boundary problems, testability issues, or AI-navigability problems. Keep reviews read-only and nonblocking; implementation needs an authorized change scope. Skip tiny local refactors and isolated renames.
---

# Albert Architecture Review

Package identity: [lineage](references/lineage.json). Read it when comparing installed versions or adapters, not for every task.

Use this bounded review method with repository evidence. The approved Matt Pocock
architecture suite is optional supporting guidance, not a runtime prerequisite.

## Authority and scope

Safety/platform rules and explicit user instructions within those boundaries
precede repository/scoped rules, Project Brain, this wrapper and optional skills.
A review is read-only unless changes are also requested. Skill routing does not
change `MANUAL_ONLY` model/provider routing or authorize protected actions.

Load a supporting skill only if it is available, approved for this use and useful.
If it is missing, continue with relevant source/tests and the method below, state
material limits, and do not claim the missing skill was used or auto-install it.

## Inputs

Prefer:
- repository `AGENTS.md` and scoped rules;
- existing project glossary / Project Brain / CONTEXT.md when present;
- ADRs and prior decisions;
- recent Git hot spots and repeated change areas;
- relevant source and tests.

## Method

1. Scope before scanning. Focus on areas with actual friction or repeated change.
2. Inspect interfaces, coupling and test seams in relevant source. Consult `codebase-design` when available and useful.
3. Consult `domain-modeling` only when available and terminology or domain boundaries need sharpening; preserve observed project invariants.
4. Surface a small set of evidenced improvements; use `improve-codebase-architecture` when available and helpful.
5. Treat the upstream `grilling` skill as optional interactive mode only. Do not block by default waiting for a questionnaire. If a decision is unresolved, state the decision tree, recommend a default, and continue with non-destructive analysis unless higher-precedence rules require user input.
6. Preserve existing ADRs and project-specific terminology.
7. Do not write architecture changes merely because an opportunity exists; implementation scope must come from the user's request.

## Output

For each meaningful candidate include:
- area / files;
- observed friction;
- why the current interface or seam is costly;
- recommended direction;
- expected leverage, locality, and testability benefit;
- migration risk;
- recommendation strength: Strong / Worth exploring / Speculative.

End with one top recommendation and a "do nothing" comparison so architecture work is justified rather than ceremonial.

## Guardrails

- No architecture astronautics.
- No speculative abstractions with only one hypothetical adapter.
- No broad refactor for a tiny bug.
- No rewriting project domain language to satisfy an external skill vocabulary.
- No protected production, auth, RLS, migration, financial, or release action without explicit authorization.
- Repository-native verification and ADOS evidence remain authoritative.
