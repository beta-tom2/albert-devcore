# Visual Quality Pilot (no bulk skill installation)

Status: **proposed reproducible evaluation protocol**. A detector or design skill is not
considered installed, running or helpful until that is observed for the target environment.

## Goal and boundaries

Reduce **repeat fixes of user-visible defects**, not increase design novelty at any cost.
The already accepted product design system, platform conventions, accessibility and
performance requirements are stronger than generic AI-design heuristics.

1. Before touching UI, record current design tokens, viewport/device matrix, the specific
   defect or UX hypothesis, and one reproducible baseline screenshot or interaction trace.
2. Pass A: choose the smallest correction and confirm it does not conflict with the product.
   Pass B: challenge truncation, nested scrolling, contrast, focus/touch, interaction states,
   motion reduction, responsiveness and rollback. Use the existing `albert-design-director`
   for substantive UI work, not the whole design suite.
3. Implement one bounded change. Run existing project typecheck/tests/accessibility/browser
   or native checks. Capture **after** screenshots of the same states and viewports; inspect
   visually. Check real device input/performance where the medium requires it.
4. Record defects found, defects fixed, regressions, rework loops and whether the first
   implementation passed acceptance. Keep evidence attached to the relevant revision.
5. Reject improvements that merely conform to a detector while harming the actual product.

## Detector experiment

Candidate: [Impeccable](https://github.com/pbakaus/impeccable) design detector.
Its source-file checks target web UI patterns, not arbitrary Godot/GDScript scenes.
Before any installation or `npx` execution: audit the exact package version,
scripts, dependencies, rights and permitted network/credential exposure.

First pilot: **one** web/React UI change with an already usable test environment,
existing screenshot/browser checks and a confirmed visual baseline. Keep the
project identity, unpublished screenshots and results in its private repository.
Run the project's existing gate **first**.
Then, in an isolated reviewed environment, compare detector findings with actual
reviewer-observed defects. Do not introduce a new mandatory CI dependency until
the detector catches real issues with an acceptable false-positive rate.

For **Godot games**, use native renderer screenshots, viewport geometry smoke,
interaction smoke and actual Android testing instead. Do not claim Impeccable can inspect
Godot screenshots automatically without a verified supported integration.

## Acceptance of a pilot

- Baseline and after evidence both exist at explicit revisions and matching viewport/state.
- No new overflow, clipped input area, unusable touch target, regressions or accessibility loss.
- At least one real defect is prevented/caught, or the extra detector is **rejected**.
- Record extra setup/time and rework: the benefit must outweigh maintenance and false alarms.

Not done means **UNVERIFIED**; do not mark a UI task visually verified because a
source-only check or self-assessment passed.
