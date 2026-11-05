# ADOS Cross-Project Knowledge & Reuse (v1)

## Scope

Extend existing **Project Brain, Repair Memory, Negative Memory, Fix DNA, Skill Router, and Evidence Gate** rather than inventing a second project-memory system. Project-specific knowledge stays in its original repository. This new layer contains only *sanitized, reusable, reviewed* knowledge.

This is **not** automatic model training, autonomous code publication, a vector database, or a new service. The first reviewed entries are generalized from merged, publicly verifiable DevCore PR #12 and passed Windows CI; they are not assumed applicable to other projects without new tests. Initial matching is deterministic, read-only, lexical, and capped at three records per task.

## Trust and lifecycle

1. **Observe** a meaningful repeated or expensive issue while developing an owned project. Keep raw logs, errors, and source in the private project.
2. **Draft** a generalized record into that project's ignored .ai/local-output/knowledge-candidates/ using the local draft command. Its status is always candidate; a string saying "passed" never upgrades the status.
3. **Review** cause, alternatives, negative conditions, security/privacy, ownership/licensing, dependency versions, and real test/build/CI evidence. The reviewer must ensure the referenced check actually ran against the relevant revision.
4. **Promote by reviewed PR** into public knowledge/entries/ only when the entry can safely be public and reproducible validation supports it. Give it a unique DC-KB-#### identifier, status verified, verification date, and expiry where applicable. Never auto-commit, push, or transfer project-private material.
5. **Reuse before work**: ados start and ados analyze ask the shared catalog for relevant records, storing a small .ai/context/shared-knowledge.generated.md inside the project's ignored generated context, and include that summary in the generated task packet.
6. **Revalidate on adoption** in the destination project. A matching record is advice, not evidence that the new task has passed its own Evidence Gate.
7. **Maintain** by deprecating/removing outdated recipes in a reviewed PR. Expired entries are omitted automatically. Never silently replace known good project-specific instructions.

A plain old chat summary, an unverified claim from an LLM, and an unrelated repo's successful CI **do not** satisfy the promotion gate.

## Record shape

The following is a **schema illustration, not a real verified result**:

~~~json
{
  "schemaVersion": 1,
  "id": "DC-KB-0001",
  "kind": "solution",
  "status": "verified",
  "title": "Example: avoid navigation before auth restore",
  "problem": "Navigation may run before state restoration",
  "resolution": "Gate navigation on a resolved auth state",
  "applicability": "Only apps using the same auth lifecycle and router version",
  "doNotUseWhen": "Auth and navigation lifecycles differ",
  "stacks": ["expo", "react-native"],
  "tags": ["auth", "navigation"],
  "lastVerified": "2026-11-05",
  "expiresOn": null,
  "evidence": [{
    "kind": "public-ci",
    "reference": "https://github.com/EXAMPLE/REPO/actions/runs/123",
    "status": "passed"
  }]
}
~~~

The sample above is **not** an actual evidence-backed entry. Do not commit it as verified. Evidence from a private project must stay private; a generalized technique needs safe, independent evidence before publication.

## Commands

From the checked-out DevCore repository, in Windows PowerShell 5.1:

~~~powershell
.\scripts\ados-shared-knowledge.ps1 search -ProjectPath C:\Work\MyProject -Task "Auth navigation race" -Stack expo,react-native
.\scripts\ados-shared-knowledge.ps1 draft -ProjectPath C:\Work\MyProject -Title "Auth navigation race" -Problem "Race after session restore" -Resolution "Await resolved auth state" -Applicability "Same auth lifecycle" -DoNotUseWhen "Different router" -Evidence "Reproduced and covered by local tests" -Stack expo
.\scripts\ados-shared-knowledge.ps1 validate -RecordPath .\knowledge\entries\DC-KB-0001.json
~~~

Search also runs automatically during ADOS task preparation, **provided that task preparation runs through the reviewed DevCore runtime**. It is not a background watcher and does not automatically affect unrelated repositories or ChatGPT conversations.

A candidate is written **only locally** and is not searchable by other projects. The draft command requires the project Git root and checks that .ai/local-output/ is ignored; if not, it refuses to write. Once a vetted entry is merged to DevCore and the runtime is updated, it becomes available to other adopted projects. Global project adoption from PR #14 remains separate and must finish its own review/merge.

## Context budget and applicability

- At most 3 reviewed entries are retrieved by default (configurable 1–5).
- The summary is bounded, with concise problem, resolution, applicability, exclusion and evidence.
- Explicit -Stack filters out records for incompatible stated stacks. If none is passed, a small allowlist of technology tokens may be inferred from the task; generic queries still require the agent to check compatibility before reuse.
- Scoring uses task terms in title, tags, problem and applicability; it is only a navigation heuristic, not semantic proof. Conflicting duplicate reviewed IDs are suppressed rather than randomly preferred.
- No personal or sensitive source documents, full histories, or third-party provider calls are read or transmitted.
- No new dependency, paid API, scheduled service, vector store, or installation is required.

## Future increments (only after v1 demonstrates value)

1. An opt-in post-Evidence-Gate proposal step that *suggests* candidate creation, never claims an inferred fix was verified.
2. Deduplication and conflict review using real reusable cases from multiple projects.
3. An optional design/component asset manifest with checksums and explicit license/ownership. Do **not** copy assets across private repositories by default.
4. Skill Telemetry metrics on whether a reused suggestion actually reduced rework; no fabricated token-savings measurements.

## Security/limitations

The built-in text filter blocks some credential, email and private-home-path signatures, but cannot prove a record is free of proprietary information or prompt injection. Review every line of a promotion PR.

The catalog is public because DevCore is public. For anything private, use private project memory or a future **separately authorized private store**, not public DevCore.

Never treat a verified label, timestamp, evidence URL string, or cached search result as proof of actual production safety. The real target project and its current tests remain authoritative.
