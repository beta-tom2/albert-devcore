---
name: albert-design-director
description: Selects the smallest useful design-skill stack for application and website UI work across Albert projects. Use for meaningful UI/UX creation, redesign, visual polish, animation/motion, design review, or design-system work. Do not load all design skills at once.
---

# Albert Design Director

## Purpose
Coordinate approved design skills so they complement rather than override each other. This is a routing layer under `albert-skill-router`, not a replacement for repository rules, Project Brain, DevCore, ADOS, accessibility checks, or product requirements.

## Precedence
Safety and platform rules > explicit user instruction within those boundaries > repository and scoped `AGENTS.md` > Project Brain / project design system > DevCore/ADOS > this director > individual design skills.

## Core principle
Start with zero optional design skills. Select only the minimum stack with a positive expected benefit. Never load every design skill merely because UI is involved.

## Roles

### `frontend-design` — concept and visual direction
Use for a new screen/page, substantial redesign, visual identity, typography/layout direction, interaction concept, or when the UI brief is under-specified.
Do not use for tiny spacing/copy fixes or backend-only work.

### `impeccable` — quality, polish, anti-pattern and shipping pass
Use when an existing UI needs critique, audit, polish, hardening, responsive/adaptive cleanup, typography/layout correction, or removal of generic AI-design patterns.
Prefer it after the main direction already exists. Do not let it silently replace an established brand/design system.

### `design-taste-frontend` — experimental creative variance
Use only when the user explicitly wants a more distinctive, less generic, bolder, more editorial, experimental, or alternative visual direction, or when existing approaches remain visually bland after normal design work.
Because upstream v2 is experimental, do not make it the default design authority. Treat its output as proposals to validate against project design rules.

### Emil Kowalski motion suite — purposeful motion
Use `find-animation-opportunities` before adding motion to an existing surface when it is unclear where animation adds value.
Use `animate` when a specific interaction clearly needs a new animation from scratch.
Use `improve-animations` for a broad read-only motion audit and prioritized implementation plans.
Use `review-animations` after motion implementation or for a strict review of an existing animation diff.
Use `emil-design-eng` when broader design-engineering judgment is useful, especially when motion and interface details are intertwined.
Use `apple-design` only when Apple-like fluid interaction principles, web translations of Apple motion, sheets, spring/drag behavior, or iOS-inspired interaction are actually relevant.

## Routing recipes

### New application screen / website section
Default: `frontend-design` + platform specialist (`expo-native-ui` / `vercel-react-native-skills` when relevant).
Add `impeccable` only for a final polish/audit pass, not simultaneously during early ideation unless the task explicitly asks for both creation and final quality review.

### Existing UI looks generic or cheap
Default: `impeccable`.
If a deeper creative reset is requested, add `design-taste-frontend` as a proposal generator, then reconcile its ideas through project design rules and `impeccable` quality review.

### Add animation to an existing product
Default sequence: `find-animation-opportunities` -> implement only selected opportunities -> `review-animations`.
If the user already specified exactly what should animate, skip discovery and use `animate` -> `review-animations`.

### Existing animations feel wrong
Use `improve-animations` for broad audit/planning, then implement selected fixes, then `review-animations`.

### Final UI shipping pass
Use `impeccable` plus repository-native accessibility/responsive/performance checks. Use `verification-before-completion` when the overall task warrants it.

## Conflict rules
- Established project design system and explicit brand choices beat generic anti-pattern rules.
- Never let Taste override product usability, accessibility, information hierarchy, or platform conventions without a reason.
- Never add animation merely because motion skills are installed.
- Prefer transform/opacity and purposeful motion over decorative movement; respect reduced-motion settings and platform accessibility rules.
- Do not combine Impeccable motion guidance and Emil motion skills redundantly. Emil is the primary motion authority; Impeccable remains the broader quality/polish authority.
- Do not use Apple design guidance as a universal visual style.
- Do not install a new UI library merely because a skill recommends one; dependency changes remain governed by repository authorization rules.

## Automatic behavior
When working on meaningful application or website UI tasks, agents should consult this director automatically via `albert-skill-router`. Selection should remain internal unless an explicit handoff is useful.

## Learning loop
Record selected skills and outcomes through Skill Telemetry when available. If repeated evidence shows a design skill adds churn, conflicts with project systems, or improves first-pass quality, adjust routing policy rather than accumulating more skills blindly.
