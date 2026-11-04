# Reviewed upgrades and restores for the three core skills

`scripts/manage-albert-dev-skills.ps1` updates only these repository-owned skills:

- `albert-skill-router`
- `albert-design-director`
- `albert-architecture-review`

The existing installer remains the entry point for installing absent or identical
packages. The manager adds an explicit replacement lifecycle for reviewed updates
and local adaptations. It does not update third-party skills, edit a vendor lock,
install cloud adapters, fetch a repository, or enable a background updater.

## Review a plan

Choose **exactly one** target: `-Global` for the current user's `.agents/skills`,
or `-ProjectPath C:\projects\example` for that project's `.agents/skills`.
`plan` is the default action and makes no writes.

```powershell
$plan = .\scripts\manage-albert-dev-skills.ps1 -Global -Json | ConvertFrom-Json
$plan | ConvertTo-Json -Depth 14
```

The plan includes the complete installed and desired manifests, not skill text.
The installed digest covers the selected directory names, absence/presence, all
files and their SHA-256 hashes, file lengths, and empty directories. Thus an added
local note, a missing reference, or a package that did not exist is significant.
The source digest binds the selection, installer bytes, registry, lock, optional
shared contract, package manifest, and manager bytes. Git commit and dirty state
are separate observations: a version label does not establish artifact identity.

Source files must match the repository lock and registry. Linked paths, unsafe
relative paths, unlocked source files/directories, and excessive package sizes
are rejected. Inspection is limited to 2,048 entries and 64 MiB across the selected
packages, with at most 16 MiB per file. These limits keep an accidental large
directory from becoming an unbounded backup operation.

Use `-Skill albert-skill-router` to select one core package. The default selects
all three. An unrelated package cannot be added to this managed replacement set.

## Apply the reviewed upgrade

Pass the two exact digests you inspected, plus explicit confirmation:

```powershell
$receipt = .\scripts\manage-albert-dev-skills.ps1 -Action upgrade -Global `
    -ExpectedInstalledDigest $plan.installedDigest `
    -ExpectedSourceDigest $plan.sourceDigest `
    -ConfirmChange -Json | ConvertFrom-Json
$receipt
```

Do not turn these examples into an unattended “plan then immediately approve”
loop. Review the selected target, file changes and source first. A mismatch means
the plan is no longer the one being applied; inspect a fresh plan before retrying.
Repeating the old expected values after an update refuses the operation. A fresh
plan whose complete directory set already matches returns `ALREADY_CURRENT`
without writing a backup or receipt.

Backups default to the user's `.agents/backups`. `-BackupRoot` can select another
local directory outside the skills directory and source runtime. Each operation
creates a new backup directory containing:

- `previous/`: complete earlier selected directories, including custom files;
- `backup.json`: target identity, selection, full prior manifest and its digest;
- `receipt.json`: operation state, before/after digests, source hashes, actual
  source Git observations, and recovery locations.

The manager acquires a target-specific writer lock, verifies the full backup,
and stages the new packages through the existing installer using a frozen copy
of its verified source bytes. It then rechecks source and target digests, renames
the old directories aside, promotes staged directories, and verifies the result.
Staging and rename operations stay on the target volume; the durable backup may
be on another local volume.

Only the selected skill directories are replaced. Other skill packages and
`.agents/.skill-lock.json` are not modified. Receipts are local records and may
contain user paths; do not publish them as public package documentation.

## Restore a specific backup

Restore requires the same target and complete selection recorded in that backup.
It verifies the backup's files against its manifest, then binds both the backup
and the current installation to the reviewed digests:

```powershell
$backup = $receipt.backupPath
$restorePlan = .\scripts\manage-albert-dev-skills.ps1 -Global `
    -BackupPath $backup -Json | ConvertFrom-Json
$restorePlan | ConvertTo-Json -Depth 14

$restoreReceipt = .\scripts\manage-albert-dev-skills.ps1 -Action restore -Global `
    -BackupPath $backup `
    -ExpectedInstalledDigest $restorePlan.installedDigest `
    -ExpectedSourceDigest $restorePlan.sourceDigest `
    -ConfirmChange -Json | ConvertFrom-Json
```

New edits after planning block the restore. If those edits are reviewed and a new
restore plan is confirmed, the manager first saves the current directories in a
new backup before restoring the older bytes. Restoring a package that was absent
before the original update restores its absence. Restore copies the saved files;
it does not reinterpret an old local adaptation as an approved upstream artifact.

## Failure and verification boundaries

A caught replacement failure attempts to restore the displaced directories.
Failed replacement directories are preserved in the reported recovery workspace,
including any edits observed there. A concurrent directory occupying a restore
target is not silently overwritten; the receipt reports `RECOVERY_REQUIRED`.
Inspect the named backup and workspace before taking further recovery action.

The writer lock coordinates this manager's invocations. Close agents/editors that
are modifying these packages while replacing them; it is not a distributed lock
or a lock on arbitrary editors. A power loss or killed process can leave the
writer lock and transaction workspace. Do not remove a live writer's lock. For an
interrupted transaction, first confirm the process has stopped and inspect its
backup, receipt and displaced files. Automatic crash recovery is not implemented.

Backups preserve file bytes, names, presence and empty directories. They do not
promise identical timestamps, ACLs, alternate streams, or filesystem attributes.
They are ordinary local files, not signed or encrypted archives; keep them under
the user's normal access controls and include them in an independent backup when
needed. No claim of durable off-device backup or cloud freshness follows from a
successful local update.

Run the fixture suite under Windows PowerShell 5.1 before using a changed manager:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\devcore-skills-update.ps1
```

The suite covers read-only planning, exact update/restore, missing package state,
local-edit conflicts, source/backup tampering, partial failure rollback, linked
paths, and preservation of unrelated packages. It uses temporary directories and
does not update the user's global installation. A successful package update still
does not prove that every host has rediscovered or invoked the skills; use a new
host session and the behavior-contract checks for that separate claim.
