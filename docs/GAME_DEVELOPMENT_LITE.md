# Game Development Lite (DevCore / ADOS)

Status: **operating profile**, not an installed skill, agent, engine plugin or automatic orchestrator.
Applies to small owned game prototypes when the project's rules and actual source state permit it.
Reference concept: [Claude Code Game Studios](https://github.com/Donchitos/Claude-Code-Game-Studios).
Do **not** clone its 49-agent studio, hooks, agent prompts or entire skill catalog into DevCore.

## Objective

Ship a playable, testable game loop before spending effort on process, content, monetization or agents.
Treat domain roles as **review perspectives**, not independently running subagents or model invocations.
The existing `albert-skill-router`, ADOS, Project Brain and native engine tooling remain authoritative.
Do not create a second backlog, memory, review queue or skill router.

## Risk-scaled rigor

| Profile | When | Required evidence |
| --- | --- | --- |
| P0 prototype (default) | Single developer, core fun still uncertain | Current game hypothesis, one bounded playable increment, native logic checks, observed game launch and UI evidence for visible changes. |
| P1 vertical slice | Core loop survives external playtests | Coherent visual identity, phone/device QA, asset/accessibility checks, repeatable builds, regression coverage for critical loops. |
| Release candidate | Distribution, purchases or player data are in scope | Signed/build provenance, permission and privacy checks, store/platform compliance, device matrix, documented rollback. |

A project's critical combat, economy or account subsystem may require stronger evidence than the rest.
Never waive the actual launch-and-look check just because tests are green. A screenshot is **not** proof
of good controls or performance, and a passing unit test is not proof of a usable phone UI.

## Minimal workflow, using existing project records

1. **Double preflight (Rule #1):** inspect repo/revision, game hypothesis, existing scripts and UI;
   then independently challenge failure modes, hidden interactions, scope, rollback and acceptance.
   Preserve uncommitted work. For status-only requests do not create checkpoints or files.
2. **Game design lens:** specify exactly what player decision changes, what feedback is visible,
   one failing case, the smallest testable mechanic and a stop condition.
3. **Engineering lens:** keep gameplay truth deterministic and renderer independent; prefer
   existing engine/runtime, tests, data catalogs and established interfaces. Do not introduce a
   generalized AI/game engine, ECS, backend or event bus without evidence of need.
4. **Visual / interaction lens:** verify states that exist in play, including reward, failure,
   long text, compact screens, gesture cancellation and accessibility. Render and inspect
   screenshots/video after changes; test touch on an actual device when relevant.
5. **QA / playtest lens:** native automated tests plus repeatable seed/scenario, actual launch,
   and short external playtests. Record observations rather than simulated enthusiasm.
6. **Release lens:** build/export only after the earlier gates; verify output on target hardware.
   Keep incomplete or untested work on a review branch, never label it SHIPPED.

For a task, select **one or two** of these perspectives unless its scope clearly needs more.
Do not pay for multiple models or spawn agents merely to enact the headings.

## RIFTGRID P0 application

Canonical project state is `riftgrid/docs/project-brain/STATE.md`, with the actual source
revision. As observed on 2026-11-08, I0–I6 are recorded complete and I7 (mobile feel) / I8
(external game-loop evidence) remain open. This is a source snapshot, not proof of a tested
device build or proof that the user's offline laptop is synchronized.

- **I7:** prioritize portrait layout and touch geometry first, then restrained feedback/audio/
  haptics, device performance and Android debug export. Run existing `tools/verify.ps1`,
  renderer interaction smoke and real Android checks. For visual changes preserve review
  screenshots under an ignored local artifacts path; do not commit private device artifacts.
- **I8:** run 5–10 external 10–15 minute playtests. Track changed decisions due to intent,
  failure clarity, player restart choice and major difficulty problems. Keep raw metrics local
  unless authorized for publication.
- **Stop rule:** if enemy intent rarely changes placement decisions or testers do not want
  another run, improve the core interaction before P1 content, economy or monetization.

No RIFTGRID product changes are implied by this profile. Any actual implementation must
pass the project's own revision-scoped checks and its existing decisions.
