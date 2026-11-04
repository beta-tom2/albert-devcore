# Controlled project-state publication

This optional transport publishes one existing portable project-state snapshot
to an existing GitHub branch. Project Brain and repository files remain canonical.
It is not folder synchronization, a background worker, a second queue or a new
memory database. It does not merge a PR, create branches or call a model provider.

## Explicit setup and preview

Git and an authenticated GitHub CLI (`gh`) must be available. Authentication is
reused; this command does not log in, obtain tokens or change permissions.
Copy `template/.ados/state-publish.example.json` to the project's
`.ados/state-publish.json`, set the actual project/repository identity and
visibility, choose an existing review branch and a dedicated JSON destination.
Set `enabled` to `true` only after reviewing that destination and audience.
The example is disabled by default.

Create and review the snapshot using the existing state export workflow. Its
metadata can be confidential even when source document bodies are omitted.
Existing snapshot validation includes bounded heuristics, not a guarantee that
all arbitrary confidential text has been removed. A private snapshot can only be
published to its matching private project repository.

Supply the full, recently observed destination branch SHA:

```powershell
.\ados.ps1 state-publish -ProjectPath C:\projects\example `
  -ExpectedRemoteCommit '<40-character lowercase branch SHA>'
```

The default is a strictly read-only preview: it validates inputs and reads GitHub
metadata, commits, trees and blobs, then prints the plan. It writes no receipt,
temporary file, local Git state or remote object. A successful preview is not
proof that a later write will succeed; publication rechecks its own preconditions.

After reviewing the exact snapshot and plan, the same command with
`-ConfirmPublish` attempts the publication. `-StatePublishConfigPath` and `-SnapshotPath` select other JSON inputs through
`ados.ps1`. The standalone publisher accepts `-ConfigPath` instead. The default snapshot is
`.ai/local-output/project-state.json`.

## Publication contract

- Configuration, snapshot identity and a recognized `https://github.com/...`
  or `git@github.com:...` origin must match. Unknown hosts and foreign origins fail.
- GitHub's actual repository identity and public/private visibility must agree
  with configuration and snapshot. Internal/unknown visibility is unsupported.
- The destination cannot be `main`, `master`, the actual default branch or a
  branch GitHub reports as protected. Missing or unknown branch state fails.
- The exact current remote head must match `ExpectedRemoteCommit` during
  validation. The write uses `createCommitOnBranch` with that same
  `expectedHeadOid`, so GitHub also checks the head as part of the commit-and-ref
  operation. A concurrent advance or rewind does not qualify as the expected
  head. This command never creates a branch.
- The source commit must exist in this repository. Every indexed document path
  must identify its declared committed blob, and the remote blob bytes must match
  the snapshot's SHA-256. Local uncommitted document bodies are not published.
- The destination is one repository-relative JSON path. It cannot replace an
  indexed canonical source, publication/export configuration or the local receipt.
  An existing destination must already be a valid snapshot for the same project,
  repository and visibility. Unrelated JSON, symlinks and directories are rejected.
- One GraphQL mutation supplies exactly one `fileChanges.additions` entry and
  no deletions. It appends the snapshot commit to the expected branch head and
  updates that branch in the same operation. There are no separate REST blob,
  tree, commit or ref writes, and no force update. The returned and read-back
  commit must have only `ExpectedRemoteCommit` as its parent.
- The published commit, destination blob and exact input bytes are read back.
  The branch is checked around read-back. Only this completed sequence produces
  `PUBLISHED_VERIFIED` with `remoteVerified:true`.

GitHub CLI uses `--hostname github.com` and JSON on standard input. The commit
is created as the authenticated GitHub account. No shell
command interpolation, paid model API or additional service is involved. V1
accepts ASCII branch/destination names and snapshots up to 128 KiB. Document
hashes use committed bytes, preserving original line endings.

## Receipts, conflicts and recovery

Only confirmed publication attempts write
`.ai/local-output/state-publish.receipt.json`. That path must already be ignored
and untracked through the existing local ADOS setup; publication does not change
ignore rules. Symlink/reparse-point input and receipt paths are rejected.
The local index, HEAD and product files are not updated.

| Status | Meaning |
|---|---|
| `PREVIEW` | Read-only plan; no receipt and no publication. |
| `PUBLISHED_VERIFIED` | Exact bytes read back from the candidate commit while the destination branch matched it. |
| `CONFLICT` | An expected remote revision changed. Review the actual branch before retrying. |
| `REJECTED` | Configuration, identity, provenance, destination or another precondition failed. |
| `TRANSPORT_UNAVAILABLE` / `API_UNAVAILABLE` | The transport or request failed. No verified publication is claimed. |
| `REF_UPDATE_UNCONFIRMED` | The atomic operation returned errors, an incomplete response or a transport failure. Inspect the live ref and snapshot before retrying; `candidateCommit` can be null when no reliable commit identity was returned. |
| `READBACK_FAILED` | A commit may already be published, but read-back failed or differed. `remoteVerified` remains false; inspect the recorded candidate/published commit. |
| `UPDATE_PENDING` | The last durable record was written before the atomic mutation. An interrupted run requires a live check, not an assumption of success or failure. |

An error throws after recording the available result when a safe receipt path
can be established. Invalid repository/receipt paths can prevent a receipt from
being written at all. An old successful receipt is not proof of a later attempt.
The receipt describes one observed attempt, not continuous synchronization or
whole-project readiness. Source and publication commits are deliberately distinct.

GraphQL `errors` are rejected even if partial result data is also present; their
arbitrary text is not copied into receipts. An error is not treated as proof that
no side effect occurred. For an unknown commit identity, compare the live branch,
its parent and destination bytes with `expectedRemoteCommit` and `snapshotSha256`
in the receipt before deciding whether to retry. There is no automatic retry.

The command does not force a ref or roll another writer back. One writer should
own publication initially. The exact-head precondition protects this individual
write, not later history: another authorized actor can still change the branch
after it completes. The receipt remains an as-of observation, not a persistent lock.
There is no startup integration, periodic synchronization or offline upload queue.

## Validation and references

`tests/ados-state-publish.ps1` uses a temporary Git repository and replaces only
the API transport in test scope. It performs no real GitHub writes. It covers
preview, success, stale refs, concurrent advance and ancestor rewind between the
final GET and mutation, GraphQL errors/partial data, lost responses before and
after commit, unavailable service/read-back, byte mismatch,
identity/visibility/provenance failures, protected branches and canonical files.
Windows PowerShell 5.1 is the required runtime gate. A mocked pass does not prove
that credentials, GitHub permissions or a particular live repository allow a write.

Primary API contracts: [GitHub CLI api](https://cli.github.com/manual/gh_api),
[createCommitOnBranch and expectedHeadOid](https://docs.github.com/en/graphql/reference/commits#createcommitonbranchinput),
[CommittableBranch and file changes](https://docs.github.com/en/graphql/reference/git#filechanges).
