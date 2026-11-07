# Video workflow ideas: selective adoption decision (2026-11-08)

Scope: six user-provided clips (game studio, dashboard, AI gateway, skill discovery,
model routing, design/motion). This is the implementation boundary for shared DevCore.
It is **not** a claim that all devices/skills/runtimes have been audited.

## Rechecked decisions

| Idea | Existing evidence in DevCore | Action |
| --- | --- | --- |
| 49-agent Claude Game Studios | ADOS/Skill Router/Project Brain already cover orchestration and handoffs | **Adopt only lean domain lenses**, see `GAME_DEVELOPMENT_LITE.md`. No full framework install. |
| Modern dashboard styling | Design Director and project-specific tokens/mockups already exist | Reuse individual patterns only when they improve real workflows; no global redesign. |
| OmniRoute / automatic token optimization | Context packets, API ledger, MANUAL_ONLY routing already exist | **Defer**. First measure cost per *verified completed task*, not per initial request. |
| Vercel `find-skills` | Approved catalog and discovery route exist | Keep discovery; **deny third-party install until audit**. |
| Automatic cheap-model escalation | External API not automatically routed; explicit approval boundary exists | Keep MANUAL_ONLY. Benchmark quality, repeat work and data exposure before proposing AUTO. |
| Impeccable / Taste / motion | Registered as approved or conditional, but most external artifacts have no pinned local lock | Verify real installations and usage; pilot visual gate, not bulk install. |

## Practical rollout without new dependencies

1. Embed **Rule #1** (two risk-scaled preflight passes, final diff/evidence gate) in
   DevCore's root and new-project/global policy templates. This changes repository
   guidance, **not** an already installed global file on the user's offline laptop.
2. Use the lean game profile for RIFTGRID I7/I8. Preserve gameplay architecture,
   current branch and tested deterministic behavior.
3. Trial the visual quality protocol on **one** interface. Do not treat optional
   detector output as a substitute for rendering, device testing or visual review.
4. Extend current local skill telemetry only if objective metrics can be recorded
   without extra services. Existing JSONL results and absent fields must keep working.
5. When the Windows device is reachable, perform a **read-only installation audit**:
   identify actual reviewed DevCore runtime SHA; run its `ados.ps1 status`,
   compare owned skill hashes to lock and approved registry; enumerate external
   skill directories in the relevant host(s), inspect each `SKILL.md` plus scripts/
   hooks/versions and separately verify actual invocation. A catalog entry is not
   installation evidence. No mass reinstall or silent update.
6. Revisit external model routing only after several representative **verified**
   tasks have measured success, elapsed time, rework, token charges and privacy risk.
   Preserve manual consent and sensitive-data controls.

## Stop / rollback boundaries

- No automatic external provider calls, new paid infrastructure, agent spawning,
  global skill installers, rewriting of local work or merges to main.
- If a project cannot be launched/tested on the required device, leave that
  implementation branch unmerged and report the missing evidence.
- A GitHub branch or updated template does not update an offline laptop or a
  deployed/mobile installation. Local installation is a separate verified step.
