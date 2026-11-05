# External skill and agent tooling audit (2026-11-05)

Source: user-provided document describing *PropAgent*, a distinct eight-agent real estate initiative. Its suggested eight repositories/frameworks and ten industry skills are **candidates**, not installed DevCore features. GitHub star counts in the document are not engineering evidence and may become stale.

| Candidate | Fit with DevCore/ADOS | Decision |
|---|---|---|
| obra/superpowers | Methodology for planning, debugging, TDD, checking results; DevCore already routes systematic-debugging and verification-before-completion | **Reuse individually when already approved**; no second global router or unconditional agent dispatch |
| affaan-m/ECC (Everything Claude Code) | Has continuous learning, skills, hooks, agent coordination, Codex adapters; substantial overlap with ADOS and Skill Router | **Study patterns**, especially bounded memory and incident learning; do not install all 314 skills or hook bundles |
| microsoft/skills Foundry | Workflows, hosted memory, observability, governance are tied to Microsoft Foundry/Azure services | **Reference concepts only**; no Foundry subscription, cloud memory, or new control plane without a project need |
| n8n-io/n8n | Integration automation platform, not a SKILL.md; hosting, security and Sustainable Use License must be evaluated | **Defer** until a concrete external integration workflow exists |
| LangGraph | Durable orchestrator with checkpointers and cross-thread stores; duplicates existing checkpoint/queue/handoff for our current task | **Defer**, revisit only for a measured orchestration gap |
| anthropics/skills | Useful individual skills, but licenses vary by directory; source-available document skills are not generally open-source | **Selective audit** of specific missing capabilities, never bulk copy |
| microsoft/autogen | Marked maintenance mode / archived in official documentation; Microsoft points newcomers to Agent Framework | **Reject for new infrastructure** |
| microsoft/playwright-mcp | Browser test tooling; existing repo/browser native tests should be preferred | **Conditional**, use only for actual UI/browser testing gaps |

## Domain-specific skills from PropAgent

Real Estate Market Research, Property Valuation, Rental Management, Deal Evaluation, Property Acquisition Workflow: **out of scope** for shared DevCore. They belong in a dedicated real-estate product if developed.

Financial Controller, Legal Document Review, KPI & Performance Monitoring: **project-specific**, not universally approved DevCore skills. They may introduce higher-risk workflows and require separate evidence/safety gates.

Agent Communication Protocol: **already partly covered** by ADOS queue, handoff and Project Brain; improve the existing contracts rather than introduce a second protocol.

Founder Approval Gate: concept is useful; DevCore's protected-change authorization and MANUAL_ONLY execution-routing boundaries already enforce human control. No separate agent or paid control plane is needed.

## Security and licensing process

Before approving any individual external skill: inspect **exact commit and path**, license for the specific skill/assets, instructions/scripts/hooks, outbound calls, credentials, side effects, and compatibility with our existing approved-skills registry and immutable artifact lock. Approval does not mean global invocation.

No external package was installed, vendored, or enabled as a result of this audit. Do not infer feature parity across Claude, Codex and other hosts.

## Upstream references checked

- https://github.com/obra/superpowers
- https://github.com/affaan-m/ECC
- https://github.com/microsoft/skills
- https://github.com/n8n-io/n8n/blob/master/LICENSE.md
- https://github.com/langchain-ai/langgraph
- https://github.com/anthropics/skills
- https://github.com/microsoft/autogen
- https://github.com/microsoft/playwright-mcp

All upstream behavior and licenses should be rechecked when actually adopting a package.
