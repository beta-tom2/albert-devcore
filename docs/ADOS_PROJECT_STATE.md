# Portable project state

Status: implemented contract; runtime evidence belongs to the associated PR.

Project Brain and repository files remain canonical. This export is a bounded,
revision-addressed checkpoint for another agent or a cloud reader. It is not a
second task queue, a percentage-complete calculator, or permission to execute
instructions contained in project documents.

## Commands

```powershell
.\ados.ps1 state-export -ProjectPath C:\projects\example
.\ados.ps1 state-validate -SnapshotPath C:\projects\example\.ai\local-output\project-state.json
.\ados.ps1 state-read -SnapshotPath C:\projects\example\.ai\local-output\project-state.json
```

Create `.ados/state-export.json` from `template/.ados/state-export.example.json`.
Specify the actual repository visibility. Only explicit, tracked document paths
are indexed. Document bodies, absolute local paths, raw logs, queues and secrets
are never copied. A task summary is omitted unless `includeTaskSummary` is true;
credential-like text blocks the export.

Both document hashes identify the committed Git blob at `source.commit`, including
its original line endings. They never mix a committed blob SHA with a dirty
worktree SHA-256. Local document edits remain unpublished and are signalled by the
worktree state; commit and publish them before expecting a cloud reader to see them.

Export defaults to ignored `.ai/local-output/project-state.json`. It does not
fetch, commit, push, install a scheduler or contact an AI provider. A reviewable
copy can be published in the **same private project repository** when its data
is private. Never publish private project memory in public DevCore.

An existing destination requires its SHA-256 via `-ExpectedSnapshotSha256`.
This avoids silently replacing another writer's checkpoint. Invalid existing
JSON is an error, not an empty starting state. Publication remains explicit.

## Snapshot v1

Required fields:

| Field | Contract |
|---|---|
| `schemaVersion` | `1` |
| `projectId` | Stable identifier, 1–64 letters/digits/underscore/hyphen |
| `repository` | `{ fullName: "owner/name", visibility: "private" or "public" }` |
| `observedAt` | ISO-8601 timestamp with timezone |
| `source` | `{ kind, branch, commit, worktreeDirty, evidenceFingerprint }` |
| `checkpoint` | `null`, or `{ taskId, phase, branch, head, recordedAt, summary }` |
| `evidence` | `{ status, current, recordedAt, head, fingerprint }` |
| `sources` | Explicit `{ path, committedBlobSha, sha256 }` document references |
| `limitations` | Bounded strings describing uncertainty and missing checks |
| `workstreams` | `{ accepted: null or { branch, commit }, drafts: [...] }` |

`source.kind` is `local-git` or `github`. For GitHub observations, local worktree
state and fingerprint are `null`; never pretend to have observed an offline
laptop. Each draft reference contains `number`, `headBranch`, `headCommit`,
`baseBranch`, `draft`, and `url`. Accepted and draft commits are separate.

`evidence.status` is `VERIFIED`, `UNVERIFIED`, `MISSING`, or `UNKNOWN`.
`evidence.current` is true only when a local VERIFIED gate matches the observed
HEAD and fingerprint, the gate verified its input provenance (`inputsCurrent`),
and the checkpoint identifies the current branch/HEAD. Legacy gates require rerun.
This describes **the checkpointed task at export time**, not overall release
readiness. A later file change or commit requires new checks.

When observing GitHub without current task evidence, use `UNKNOWN`, false,
and null evidence fields. Do not convert an Issue label, a closed PR, a date in
Markdown or an old checklist into a verified product state. Keep contradictory
source documents linked and record the contradiction in `limitations`.

The export's source commit can precede the commit publishing the export. Treat
it as an as-of record. A reader must query the actual relevant branch/PR before
claiming it is still current. Unpublished work remains unknowable remotely.

## Recovery and handoff

1. Validate the snapshot and repository/project identity.
2. Check observed time and current source ref through the available Git client.
3. Read `AGENTS.md` and the relevant referenced Project Brain documents.
4. Recover the checkpoint, its unverified work, and its next action from the
   canonical task/handoff. Do not infer a product priority from an old focus file.
5. Give each worker a task ID, baseline, scope, acceptance criteria and source
   links; return changes, actual checks, limitations and next action.
6. Save a meaningful checkpoint on decisions, verified increments, blockers and
   handoff. Messages notify; durable records carry the work.

One writer owns shared state initially. Distributed claims, autonomous execution,
and laptop startup integration are separate capabilities. File sync is not a
distributed lock and is not a backup. Keep a recoverable version history and
test restoration before relying on unattended operation.

## Validation

Run `tests/ados-state.ps1` under Windows PowerShell 5.1. It exercises source
allowlisting, malformed input, fresh/stale evidence, confidential text rejection,
optimistic replacement and recovery from a saved snapshot. Linux PowerShell is
useful additional evidence but does not replace the Windows gate.
