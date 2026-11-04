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
are indexed. The exporter does not copy document bodies, raw logs or queue contents.
It does copy selected metadata, including project/task identifiers, branch names
and repository-relative source paths; review that metadata before publication.

A task summary is omitted by default. Setting `includeTaskSummary` to true copies
the checkpoint's free-text task into `checkpoint.summary`. Recognized credential
patterns and common absolute local paths block the export, but these heuristics
cannot identify every secret or confidential detail in arbitrary prose. Enable
this option only for text reviewed for the intended audience; leave it false
when that review is unavailable. The filter is an additional safeguard, not a
guarantee that an exported snapshot is safe to publish.

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

### Local checkpoint freshness

New local checkpoints include the existing ADOS evidence fingerprint, covering
the branch, HEAD and Git-visible staged, unstaged and untracked file state. This
is an additive field in the local checkpoint; the portable snapshot v1 contract
is unchanged. Ignored local runtime outputs do not become project evidence.

`ados.ps1 resume` writes an advisory packet with `status`, `reasons`,
`revalidationRequired` and `nextAction`:

| Status | Meaning and next action |
|---|---|
| `UNCHANGED` | Branch, HEAD and known fingerprint match. Re-read rules and handoff, then continue from the saved phase. |
| `HEAD_CHANGED` | The branch has advanced or otherwise moved. Review commits and working-tree changes, refresh the handoff and continue with current checks. |
| `BRANCH_CHANGED` | Review the branch and task scope before deciding where to continue. |
| `WORKTREE_CHANGED` | Branch and HEAD match, but the fingerprint differs. Review staged, unstaged and untracked changes and revalidate. |
| `BASELINE_UNKNOWN` | A legacy checkpoint has no fingerprint, or its fingerprint format is unknown. Review the current state and save a new checkpoint before relying on a baseline. |

Branch change takes precedence over HEAD change; the reasons list retains both
when applicable, and also records a missing or unknown fingerprint. A fingerprint
difference after a branch or HEAD change alone does not establish worktree drift.
`fingerprintChanged` is null when the checkpoint fingerprint is unknown.

`revalidationRequired` is true for drift or an unknown baseline. A false value
means only that no baseline drift was found. Resume does not evaluate verification
artifacts: `verificationStatus` is always `NOT_EVALUATED`. Scope Guard,
Verification Ladder and Evidence Gate still determine completion on current inputs.
Saving a fresh checkpoint also does not verify the work.

The old `safeToResume` field remains a conservative compatibility advisory: it is
true only for `UNCHANGED`. It is neither an execution permission nor a completion
gate. A changed HEAD is normal during development and does not block generating
or following a resume packet; its next action calls for review and continuation.
Resume preserves the saved checkpoint and does not modify source files.

One writer owns shared state initially. Distributed claims, autonomous execution,
and laptop startup integration are separate capabilities. File sync is not a
distributed lock and is not a backup. Keep a recoverable version history and
test restoration before relying on unattended operation.

## Validation

Run `tests/ados-state.ps1` under Windows PowerShell 5.1. It exercises source
allowlisting, malformed input, fresh/stale evidence, confidential text rejection,
optimistic replacement and recovery from a saved snapshot. Linux PowerShell is
useful additional evidence but does not replace the Windows gate.

`tests/ados-resume.ps1` uses a temporary Git repository to check unchanged and
dirty baselines, same-branch HEAD changes, branch changes, same-HEAD worktree
changes, legacy/unknown fingerprints and the separation from cached evidence.
