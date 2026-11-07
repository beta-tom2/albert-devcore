## Rule #1: evidence-led preflight
For meaningful, risky or cross-project development work, complete two separate
pre-change checks: **baseline/goal/least-risk option**, then **adversarial failure
modes/affected interfaces/tests/rollback**. Confirm current repository and
revision, not just remembered project state. Before merge or delivery, re-read
the actual diff and execute relevant checks. Treat absent runtime or visual
verification as UNVERIFIED, keep changes reversible and unmerged, and report the
precise gap. Do not create extra ceremony for trivial tasks or mutate a project
when the task is review-only. Never claim that updating this shared fragment
alone has synchronized an already-installed global agent policy.

## Shared skills and project setup

- For meaningful development, debugging, design, architecture, review, project status and handoff work, consult the installed `albert-skill-router` in the user's `.agents/skills`. Resolve its bundled references relative to the skill. Keep tiny deterministic tasks lightweight.
- Use the smallest useful available and approved skill set. Preserve more specific project rules and existing project-local adaptations. Availability does not prove invocation, registration, synchronization or version parity across environments.
- For an authorized task to create a new owned project, DevCore adoption is a default part of the task. The user does not need to request activation again. Existing projects can use the global router immediately; registration or a local skill upgrade is a separate operation.
- Establish ownership, the real Git root, primary checkout, branch, working state, nearest rules and canonical memory before bootstrap. Do not register a linked worktree as a separate project or adopt a third-party repository based only on its presence on disk.
- Use the host's explicitly configured reviewed DevCore runtime. Verify its identity/revision and run `scripts/adopt-albert-project.ps1 -ProjectPath <root> -DryRun` before applying the same command without `-DryRun`. Never select an arbitrary checkout from a similar folder name. If the reviewed runtime does not yet support this preflight, keep bootstrap pending until that capability is available; do not guess or bypass safeguards.
- Preserve existing AGENTS rules, staged/unstaged work and customized local skills. Reuse Project Brain, adapter memory entrypoints or root `CONTEXT.md`; create minimal memory only if none exists. Do not create a second queue or decision journal. A new Git repository without a first commit is valid.
- For an older or divergent local skill package, inspect the separate skill-manager plan and preserve a verified backup before any authorized upgrade. Do not make the installer overwrite a conflict.
- Verify resulting files, memory entrypoints, installed hashes and exactly one registration before reporting adoption. If filesystem/runtime access is unavailable, report the concrete pending step and continue useful work within available capabilities.
- Status, review, research and handoff-only requests stay read-only. They do not trigger adoption, checkpoints, rule edits, publication or background synchronization. Automatic adoption means an agent step during authorized project creation; it is not a watcher for arbitrary new folders.
- Skill selection does not choose a model/provider. Execution stays `MANUAL_ONLY`: without an explicit task route, remain in Codex. Do not invoke Ollama, external APIs, paid services or new schedules merely because skills are available.
- During meaningful authorized owned-project implementation, if the reviewed ADOS runtime is available, prepare bounded task context via `ados.ps1 start` and inspect shared-knowledge matches before repeating research or approaches. For review/status/read-only tasks, do not use checkpoint-creating preparation.
- After a **verified** meaningful reusable fix, component, design pattern or decision, create a local-only unverified knowledge draft *only when* a concrete root cause, applicable conditions, exclusions and evidence can be stated. Skip trivia and duplicates. Never auto-publish private material or promote evidence by assertion; the catalog requires separate review.

- Keep project data isolated. Before any authorized export, verify actual project identity, visibility, source revision and the explicitly selected source paths. Treat missing or stale evidence as unresolved.
