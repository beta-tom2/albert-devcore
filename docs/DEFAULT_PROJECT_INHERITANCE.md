# Default DevCore inheritance

## What the default does

In a configured agent environment, an authorized request to create a new owned
project includes DevCore bootstrap. The user does not need a separate activation
prompt. Meaningful work in existing projects already uses the installed global
router, subject to the project's more specific rules.

These are distinct states: a skill may be available without having been invoked;
a project may use the router without a DevCore registry entry; a GitHub commit
does not update a laptop or another ChatGPT installation by itself.

| Situation | Default action |
| --- | --- |
| Create a new owned Git project | Resolve identity/rules/memory, run reviewed adoption dry run, apply bootstrap, verify files and registration. A first commit is not required. |
| Meaningful work in an existing project | Consult the available router and preserve project-specific adaptations. Do not re-bootstrap just to use global skills. |
| Explicitly connect an existing owned project | Run the same preflight; preserve existing rules and canonical memory. |
| Status, research or review only | Read the relevant state; do not install, register or persist a checkpoint. |
| Third-party checkout | Respect its rules; no automatic adoption from ownership assumptions. |
| Temporary linked worktree | Reuse project identity; no separate primary registration or edits to another checkout. |
| Missing runtime, access or incompatible installed package | Report the concrete pending step; continue useful work within available capabilities. |

## Host setup

Merge `template/GLOBAL_AGENTS.fragment.md` into the host's existing global
instructions, preserving unrelated instructions and a backup. Configure an
explicit reviewed runtime path; do not find a candidate by guessing directory
names. Verify its source revision before invoking it. Skills for another agent
surface require their own installation and verification.

The fragment is a policy source, not a script and not an operating-system
watcher. The default does not add a server, scheduler, queue, external provider,
publication target or background synchronization.

## Bootstrap contract

```powershell
& '<reviewed-runtime>\scripts\adopt-albert-project.ps1' -ProjectPath '<primary-repository>' -DryRun
& '<reviewed-runtime>\scripts\adopt-albert-project.ps1' -ProjectPath '<primary-repository>'
```

Preflight checks the primary checkout, existing generated-output paths and the
complete own3 installation before writes. An unrelated dirty source file does
not block setup. A conflicting generated output or customized skill remains
untouched and requires a concrete review. The low-level `devcore.ps1 adopt` also
protects its own outputs and registry path.

Existing AGENTS files remain intact. Existing Project Brain files, explicit
adapter memory entrypoints and root `CONTEXT.md` remain the memory sources.
An invalid, outside-root or missing declared entrypoint stops bootstrap before
writes so that a configuration error cannot create a competing memory store.
Only a project without detected memory receives the minimal current-state and
decisions templates. Generated maps are disposable context caches, not another
canonical memory. Their contents and timestamps do not establish current product
readiness.

The installer creates the three repository-owned routers when absent and
accepts identical packages. Older or locally adapted packages use the separate
skill-manager review and backup flow; bootstrap does not overwrite them.

## Verification

The Windows PowerShell 5.1 workflow includes the registry regression test and
the adoption suite. The latter exercises new repositories without commits,
read-only preflight, existing memory and dirty/staged source preservation,
conflicts before writes, linked worktrees and repeat adoption.

For isolated tests, `-RegistryBasePath <fixture-profile>` keeps the registry in
the fixture without changing the host's HOME or USERPROFILE. The default remains
the real user's registry. A passing script fixture proves that script behavior;
it does not prove that every agent automatically discovers the global rule.
Report actual fresh-session observations separately from deterministic tests.

When reporting adoption, identify the runtime revision, target root, preserved
memory entrypoints, installed package hashes and registry result. A missing or
unrun check stays pending. Do not infer cloud synchronization or all-project
migration from a successful local bootstrap.
