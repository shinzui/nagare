---
id: 121
slug: give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp
title: "Give operator Pulumi stack config a context-owned home so guarded platform upgrades are safe, ship 0.2.1, and upgrade tan-nb-exp"
kind: exec-plan
created_at: 2026-09-13T21:27:21Z
intention: "intention_01m2eak8xyehvbfkkgyzn0pasr"
provenance:
  created_by:
    model: "claude-opus-5"
    harness: "claude-code"
    at: 2026-09-13T21:27:21Z
  revisions:
    - model: "claude-opus-5"
      harness: "claude-code"
      at: 2026-09-13T21:30:50Z
      mode: "implement"
      note: "Implementing milestones 1-3 (stack link, guarded upgrade phases, host identity)"
---

# Give operator Pulumi stack config a context-owned home so guarded platform upgrades are safe, ship 0.2.1, and upgrade tan-nb-exp

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator who installs Nagare from a release tag should be able to move a cloud context to a new
release with `nagarectl platform upgrade`, and every Pulumi step that upgrade takes should see the
context's real Pulumi stack configuration and be stopped by the same project and VM-replacement
guards that protect `just infra-up`. Today neither is true. In Nagare 0.2.0 the upgrade previews
and applies Pulumi inside a freshly copied payload workspace that contains no stack configuration
at all, and it applies with `pulumi up --yes --skip-preview`, so nothing inspects the plan it
executes. For the `tan-nb-exp` installation, whose stack configuration carries the boot image link
and a non-default boot disk type, that combination could replace the production VM.

After this plan, the stack configuration file `Pulumi.<context>.yaml` lives at one context-owned
path, `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi/Pulumi.<context>.yaml`, next to the context,
host flake, and cluster secrets that already live under that directory. Every workspace Nagare runs
Pulumi in links to that file, so a new release keeps the operator's configuration. The upgrade's
Pulumi phases run the project guard and the VM-replacement guard and refuse a replacing plan. Host
release identities in generated host flakes are read correctly, so `nagarectl platform status`
reports the host's real version instead of `legacy / unknown`. These fixes ship as Nagare 0.2.1,
and the plan finishes by upgrading the live `tan-nb-exp` context to 0.2.1 through the guarded
transaction.

To see it working: with the `tan-nb-exp` context active and the release CLI installed from
`github:shinzui/nagare/v0.2.1`, `nagarectl context guard` prints a confined verdict (0.2.0 refuses
with "Pulumi stack 'tan-nb-exp' declares no gcp:project"), `nagarectl infra guard` reports that no
GCE instance replacement is planned, `nagarectl platform status` shows `Host: 0.1.0` before the
upgrade, and after the upgrade every identity reads `0.2.1` with compatibility `exact`.


## Progress

- [x] (2026-09-13 21:27Z) Audit the live `tan-nb-exp` state read-only and record the evidence below.
- [x] (2026-09-13 21:27Z) Record the ACME contact and live VM shape in the private context
  (`shinzui/nagare-ops` commit `f8a2878`).
- [x] (2026-09-13 21:45Z) Milestone 1: proved Pulumi's behavior with a symlinked stack configuration
  file (see Surprises & Discoveries).
- [x] (2026-09-13 22:40Z) Milestone 2: `Nagare.Platform.StackConfig` links workspaces and source
  checkouts to the context-owned stack config; workspaces install locked Node dependencies; unit
  tests and the clone-free Nix check cover link, adoption, conflict, and dangling refusals. Live:
  the canonical link for `tan-nb-exp` points into `nagare-ops`, `context guard` is confined, and
  `infra guard` finds no replacement.
- [x] (2026-09-13 22:40Z) Milestone 3: the upgrade's Pulumi phases run the project and
  protected-resource guards and apply without `--skip-preview`; `parseHostIdentity` strips
  indentation. Live: `platform status` shows `Host: 0.1.0`.
- [x] (2026-09-13 22:40Z) Milestone 3b: `context create --force` merges; the classifier protects the
  instance, DNS zone, and buckets; docs, ADR 13 and 14 amendments, and ADR 18 written.
- [ ] Run `nix flake check` on the Milestone 2-3b change and commit it.
- [ ] Milestone 4: release Nagare 0.2.1.
- [ ] Milestone 5: rehearse, then upgrade `tan-nb-exp` to 0.2.1 under one bounded approval.
- [ ] ADR distillation and Outcomes & Retrospective.


## Surprises & Discoveries

- Observation: every Nagare payload workspace for `tan-nb-exp`, including the 0.2.0 one, lacks
  `infra/pulumi/Pulumi.tan-nb-exp.yaml`; only `Pulumi.yaml` is present. The real stack file exists
  only in the private operator repository and is symlinked into the source checkout.
  Evidence (2026-09-13):

  ```text
  == ~/.local/state/nagare/tan-nb-exp/platform/nagare-0.2.0-961e795321b2-feb716e715b7faf2/
  .r--r--r--  107  Pulumi.yaml
  infra/pulumi/Pulumi.tan-nb-exp.yaml -> /Users/shinzui/Keikaku/bokuno/nagare-ops/pulumi/Pulumi.tan-nb-exp.yaml   (source checkout only)
  ```

- Observation: consequently the installed 0.2.0 CLI's project guard refuses for this context,
  including inside `just infra-up` run from the checkout, because `nagarectl context guard` reads
  the workspace rather than the checkout.

  ```text
  $ nagarectl context guard     # nagarectl 0.2.0 (961e795)
  nagarectl: refusing to run: Pulumi stack 'tan-nb-exp' declares no gcp:project, so the next Pulumi operation's target project is unknown.
  fix: re-project the stack config with 'nagarectl context use tan-nb-exp'.
  ```

- Observation: the stack records values that differ from the context defaults and that the context
  cannot re-derive. `nagare:nagareImageSelfLink` is written by `scripts/upload-images.sh`, and
  `nagare:bootDiskType` is `pd-standard` while the default is `pd-balanced`. A fresh seed would
  lose the first and change the second.

  ```yaml
  config:
    gcp:project: tan-nb-exp
    nagare:nagareImageSelfLink: https://www.googleapis.com/compute/beta/projects/tan-nb-exp/global/images/nagare-image-s04l9dg8rc01
    nagare:bootDiskType: pd-standard
    nagare:dataDiskSizeGb: "110"
  ```

- Observation: a read-only `pulumi preview --json` from the checkout, where the real stack file is
  visible, reports no changes, so infrastructure already matches 0.2.0.

  ```text
  {"same": 31}
  ```

- Observation: `parseHostIdentity` in `cli/nagarectl/src/Nagare/Platform/Status.hs` matches lines
  that begin with `# Nagare platform version: `, but `cli/nagarectl/src/Nagare/Host/Config.hs`
  renders the comment indented by two spaces. Every generated host therefore reports
  `legacy / unknown`, including `tan-nb-exp`, whose flake says `  # Nagare platform version: 0.1.0`.

- Observation: the live host already runs the 0.2.0 NixOS content (`nixos/` is unchanged between
  its source revision `2ffd98a` and `v0.2.0`), k3s `v1.35.8+k3s1`, kernel `6.18.51`. The cluster
  has no `nagare-platform-version` ConfigMap, and its `letsencrypt-dns` ClusterIssuer already uses
  `nadeem@gmail.com` with the Let's Encrypt production directory.


- Observation (Milestone 1, Pulumi 3.255.0, scratch project with a file backend): with
  `Pulumi.probe.yaml` a symlink to an empty file elsewhere, `pulumi stack init`, `config set`,
  `config set --secret` (which adds `encryptionsalt`), and `config rm` all wrote through the link
  and left it a symlink; `config get` read through it. A dangling link was treated as empty
  configuration with no error, so Nagare must refuse a dangling canonical link itself.

  ```text
  == 1 empty canonical file + symlink, then stack init and config set
  Created stack 'probe'
  still-symlink
  real:
  encryptionsalt: v1:oCnAzWqARw4=:...
  config:
    nagare:k: v
  == 2 read through symlink
  v
  == 4 dangling symlink
  error: configuration key 'nagare:k' not found for stack 'probe'
  still-symlink
  ```

- Observation (reported 2026-09-13 by the `tan-infrastructure` session, verified at `v0.2.0`): the
  `ContextCreate` handler in `cli/nagarectl/app/Main.hs` builds the context only from the flags
  passed (`Map.fromList (contextEnvPairs o)`), so `--force` resets every omitted field to the
  defaults in `profileFromContextMap` (`cli/nagarectl/src/Nagare/Target.hs`), for example
  `NAGARE_BASE_DOMAIN=apps.example.com` and the default VM shape. `docs/user/contexts.md` tells
  operators to run exactly such a partial `context create --force` to switch the ACME directory.
  Projected and applied, a changed base domain replaces the `gcp.dns.ManagedZone`
  (`dnsName` is create-only), which issues new name servers and breaks the parent delegation.
  `classifyPlan` only protects `gcp:compute/instance:Instance`, so that replacement passes.


- Observation (Milestone 2): with the stack config linked, `nagarectl infra guard` still failed in
  a payload workspace. Pulumi reported the cause only in the JSON diagnostics, with empty stderr, so
  the guard printed nothing after "refusing to apply:". Payloads exclude `node_modules`, and nothing
  installed the program's dependencies.

  ```text
  "message": "error: an unhandled error occurred: It looks like the Pulumi SDK has not been installed. Have you run pulumi install?"
  ```

  After `npm ci` in the workspace (346 packages, about 3 seconds), the guard reported no replacement.

## Decision Log

- Decision: the canonical stack configuration path is
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/pulumi/Pulumi.<context>.yaml`, and workspaces link to it.
  Rationale: the file is mutable operator state (image link, stack encryption salt, recorded VM
  shape), while payload workspaces are immutable per-digest copies that a new release replaces.
  Every other operator-owned input already lives under `nagare/` in XDG config, and ADR 13 already
  wires the private repository into those paths by symlink. A symlink keeps `pulumi config set`
  and `scripts/upload-images.sh` writing to the one real file.
  Date: 2026-09-13
- Decision: linking is fail-closed. If a workspace or checkout already holds a regular stack file
  whose content differs from the canonical file, Nagare refuses and names both paths instead of
  choosing one. A pre-0.2.1 workspace file is migrated only when no canonical file exists yet.
  Rationale: silently preferring either copy can revert the image link or VM shape, which the
  VM-replacement guard would then have to catch after the fact.
  Date: 2026-09-13
- Decision: the upgrade's `pulumi-preview` and `pulumi-apply` phases run the project guard and the
  VM-replacement classifier, and `pulumi-apply` no longer passes `--skip-preview`. A replacing plan
  fails the phase unless `NAGARE_ALLOW_VM_REPLACEMENT=1` is set, matching `just infra-up`.
  Rationale: the transaction is the documented operator path and must be at least as guarded as the
  recipe it replaces.
  Date: 2026-09-13
- Decision: `tan-nb-exp` moves from legacy directly to 0.2.1 with `platform upgrade`, without first
  running `platform adopt --version 0.1.0`.
  Rationale: adoption at 0.1.0 needs the v0.1.0 CLI, whose context-version writer predates
  ExecPlan 116 and may rename over the symlinked context file. `platform upgrade` accepts a legacy
  context (`previousVersion` is recorded as absent) and advances the pin last.
  Date: 2026-09-13
- Decision: include the `context create --force` reset bug in 0.2.1. `--force` merges the flags
  onto the existing context (a flag overrides, an omitted flag keeps the stored value), the ACME
  documentation uses that merge, and the replacement guard protects a list of resource types: the
  GCE instance, the Cloud DNS managed zone, and storage buckets.
  Rationale: it is the same class of defect as the stack configuration loss (an operator-facing
  command silently rewrites recorded infrastructure identity), a documented procedure triggers it,
  and the zone's name servers and the buckets' contents are external contracts that a replacement
  destroys.
  Date: 2026-09-13
- Decision: install the Pulumi program's dependencies with `npm ci --no-audit --no-fund` from the
  release's `package-lock.json` the first time a workspace lacks `node_modules/@pulumi/pulumi`,
  inside `ensurePulumiInWorkspace`.
  Rationale: discovered during Milestone 2 (see Surprises). Every real Pulumi command from an
  installed release failed without it. The lock file pins exact versions and integrity hashes, Node
  is already a documented operator prerequisite, and a Nix-built `node_modules` in the payload is a
  larger change to the release closure better made in its own plan.
  Date: 2026-09-13
- Decision: the guarded upgrade phases are not unit-tested through `UpgradeOps`; the guard logic
  lives in `cli/nagarectl/app/Main.hs` and is shared with `nagarectl infra guard` and `context guard`,
  whose pure cores (`classifyPlan`, `projectGuardVerdict`, `previewErrors`) have fixture tests. The
  wiring is verified live in Milestone 5's dry-run plan, whose `pulumi-preview` evidence must show
  both verdicts.
  Rationale: moving process execution into the library only to test the wiring would enlarge a
  patch release; the shared implementation prevents drift between the command and the phase.
  Date: 2026-09-13
- Decision: `EntryLinksTo` carries whether the link resolves to the same real file as the canonical
  path, and such a link counts as already linked.
  Rationale: ADR 13's existing checkout symlink points directly into the private repository; it
  reads the same file and must keep working without being rewritten.
  Date: 2026-09-13
- Decision: ship as 0.2.1, a patch release.
  Rationale: the change fixes defects in 0.2.0 and adds no incompatible interface; existing
  checkout symlinks keep working once the canonical file is linked.
  Date: 2026-09-13


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a small platform: a Haskell CLI named `nagarectl` (in `cli/nagarectl`), a Pulumi program
that creates one GCE virtual machine and its network and buckets (in `infra/pulumi`), a NixOS host
configuration (in `nixos`), and Kubernetes bootstrap manifests (in `cluster`). A *target context*
is a flat shell file of `export VAR=value` lines at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` that names one GCP project, zone,
and resource names. The active context here is `tan-nb-exp`, a real installation.

A *payload* is the immutable set of platform files a release ships (`nix build
.#nagare-platform`, installed under `share/nagare`). Commands that may write copy that payload into
a *workspace* under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/platform/<payloadId>-<digest>/`.
`preparePlatformWorkspace` in `cli/nagarectl/src/Nagare/Platform/Workspace.hs` does the copy, and
`validateExisting` in the same file reuses a completed workspace by checking only its
`.nagare-workspace.json` marker, so adding a link file inside a workspace does not invalidate it.
Both the Nix payload filter (`nix/platform-package.nix`) and the workspace copier exclude every
`infra/pulumi/Pulumi.<name>.yaml` except `Pulumi.yaml`. That is why no workspace has a stack file.

A *Pulumi stack configuration file* is `Pulumi.<stack>.yaml` beside `Pulumi.yaml`. Pulumi reads the
stack's config keys from it, and `pulumi config set` writes them. Nagare names the stack after the
context. `ensurePulumiInWorkspace` in `cli/nagarectl/app/Main.hs` (around line 2760) sets
`PULUMI_HOME`, `PULUMI_BACKEND_URL`, and the passphrase file for a context and selects the stack in a
workspace's `infra/pulumi`. It is called, directly or through `ensurePulumiForContext` and
`ensurePulumiForActiveContext`, by every command that runs Pulumi (23 call sites), which makes it
the single place to link the stack file. `seedPulumiConfig` in `cli/nagarectl/src/Nagare/Init.hs`
writes the context's seed keys (`seedKeys`) with `pulumi config set`.

Two guards protect Pulumi. The *project guard*, `runContextGuard` in `cli/nagarectl/app/Main.hs`
(around line 3115), compares the stack's `gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, and
gcloud's configured project with the context, through the pure `projectGuardVerdict`. The
*VM-replacement guard*, `runInfraGuard` (around line 2847), runs `pulumi preview --json`, parses it
with `parsePreview`, and classifies it with `classifyPlan gceInstanceType` from
`cli/nagarectl/src/Nagare/Infra/Plan.hs`; `PlanReplacesInstance` refuses unless
`--allow-replacement` or `NAGARE_ALLOW_VM_REPLACEMENT=1`. The `justfile` recipe `infra-up` runs
`nagarectl context guard`, then `nagarectl infra guard`, then `cd infra/pulumi && pulumi up`.

An *upgrade transaction* is `nagarectl platform upgrade`. `runPlatformUpgrade` and `upgradeOps` in
`cli/nagarectl/app/Main.hs` (around lines 2515 and 2615) plan with the phases `nix-evaluate`,
`pulumi-preview`, and `kubernetes-diff`, then apply `pulumi-apply`, `host-apply`,
`kubernetes-apply`, `cluster-stamp`, and `context-commit`. The phase engine is in
`cli/nagarectl/src/Nagare/Platform/Upgrade.hs`. Today `pulumi-preview` runs a bare `pulumi preview`
and `pulumi-apply` runs `pulumi up --yes --skip-preview`, both in the new workspace. `host-apply`
runs `scripts/host-switch.sh` with `NAGARE_HOST_FLAKE` set to a staged copy of the host flake, and
`kubernetes-apply` runs `just cluster-bootstrap` with `NAGARE_UPGRADE_APPLY=1`.

`nagarectl platform status` (`gatherPlatformStatus` in `cli/nagarectl/app/Main.hs`) reads five
release identities: CLI, payload, context (`NAGARE_PLATFORM_VERSION`), host (comments in
`${XDG_CONFIG_HOME}/nagare/hosts/<context>/flake.nix`, parsed by `parseHostIdentity` in
`cli/nagarectl/src/Nagare/Platform/Status.hs`), and cluster (the `nagare-system/nagare-platform-version`
ConfigMap).

Relevant ADRs, summarized so this plan stands alone:
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) makes payloads
immutable and materializes per-context workspaces, excluding generated stack configurations.
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) moves host flakes to
context-owned XDG paths. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
defines the five identities and the upgrade transaction.
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) governs releases.
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires the
project assertion on every cloud-mutating path.
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) requires host changes to go
through the self-reverting `host-switch`.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
puts operator material in a private repository symlinked into XDG paths and into the checkout's
`infra/pulumi/Pulumi.<context>.yaml`, and requires tooling to write through links.
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) makes the context own the VM shape
and requires ordinary applies to refuse instance replacement. This plan amends ADR 13 with the
context-owned stack path and records the guarded-upgrade rule in a new ADR 18.

The live environment matters for Milestone 5. `nagare-01` is reachable over Tailscale as
`deploy@nagare-01`; the workstation's default kubectl context is an unrelated GKE cluster, so every
Kubernetes command must run with `KUBECONFIG=$HOME/.config/nagare/kubeconfigs/tan-nb-exp.yaml`,
which points at `https://127.0.0.1:16443` through `ssh -N -L 16443:127.0.0.1:6443 deploy@nagare-01`.
The private repository is `/Users/shinzui/Keikaku/bokuno/nagare-ops`; its context, host flake,
cluster secrets, and stack file are symlinked into XDG config and the checkout.


## Plan of Work

### Milestone 1: prove Pulumi's behavior with a symlinked stack file (prototyping)

The design depends on four Pulumi behaviors: it reads stack config through a symlink, `pulumi config
set` writes through the symlink to the real file, it accepts an empty `Pulumi.<stack>.yaml`, and it
fails clearly on a dangling symlink. Prove them in a scratch Pulumi project with a local file
backend, never against a real stack. At the end, Surprises & Discoveries holds the transcript for
each behavior. If an empty file is rejected, the linker creates `config: {}` instead. If `config
set` replaces the link instead of writing through it, stop and record a new decision, because the
whole design would need a write-back step.

### Milestone 2: context-owned stack configuration linked into every Pulumi workspace

Add a module `cli/nagarectl/src/Nagare/Platform/StackConfig.hs`, listed in `exposed-modules` of
`cli/nagarectl/nagarectl.cabal`. It owns the path rule and the link decision as a pure function plus
a thin IO wrapper, so tests cover every branch without Pulumi. `contextStackConfigPath` returns the
canonical path under `nagareConfigDir` (from `cli/nagarectl/src/Nagare/Target.hs`). `planStackLink`
takes an observation of the canonical file (absent, present with content, or a dangling link) and of
the workspace entry (absent, a link to the canonical path, a link elsewhere, or a regular file with
content), and returns one action. When the canonical file is present, an absent or already-correct
workspace entry becomes a link to the canonical path, a regular file with identical content is
replaced by the link, and a regular file with different content or a link elsewhere is refused.
When the canonical file is absent, a regular workspace file is copied to become canonical and then
replaced by a link, and an absent workspace entry creates an empty canonical file and links it. A
dangling canonical link is refused with its target named. `linkContextStackConfig` performs the
action with `createDirectoryIfMissing`, `createFileLink`, and `copyFile`.

Call `linkContextStackConfig` at the top of `ensurePulumiInWorkspace`, before `pulumi stack select`,
and die with its refusal text. When the payload root is a source checkout (`rootSource` is
`SourceRoot` in `cli/nagarectl/src/Nagare/Platform/Paths.hs`), apply the same link to the checkout's
`infra/pulumi` too, so the checkout's `just` recipes and the guards read the same file. An existing
checkout symlink that already resolves to the same real file as the canonical path counts as
correct, so ADR 13's operator symlink keeps working unchanged.

Extend `nix/checks/scripts/nagare-clone-free-platform.sh`: after `nagarectl context use`, assert that
the workspace `infra/pulumi/Pulumi.<context>.yaml` is a symlink to
`$XDG_CONFIG_HOME/nagare/pulumi/Pulumi.<context>.yaml`, that a value written with `pulumi config
set` in the workspace lands in the canonical file, and that a refusal occurs when a conflicting
regular file is planted in a workspace. Add unit tests for `planStackLink` to
`cli/nagarectl/test/Spec.hs`. Update `docs/user/contexts.md`, `docs/user/provisioning-with-pulumi.md`,
and ADR 13 to name the canonical path, and add `pulumi/` to the private-repository wiring. Update
`nagare-ops/README.md` with the new symlink
`ln -sfn "$OPS/pulumi/Pulumi.tan-nb-exp.yaml" "$CFG/pulumi/Pulumi.tan-nb-exp.yaml"`.

Acceptance: the `nagarectl-test` suite and `nix flake check` pass, and against the live context,
with only reads, a CLI built from this commit prints a confined `context guard` verdict and an
`infra guard` verdict of no replacement.

### Milestone 3: guarded upgrade Pulumi phases and correct host identity parsing

Factor the body of `runContextGuard` into `contextProjectGuard :: ActiveTarget -> PlatformWorkspace
-> IO (Either Text Text)` and the preview-and-classify part of `runInfraGuard` into
`instanceReplacementGuard :: TargetProfile -> PlatformWorkspace -> Text -> Bool -> IO (Either Text
Text)`, both in `cli/nagarectl/app/Main.hs`, leaving the two commands as thin wrappers with
unchanged output. In `upgradeOps`, make `pulumi-preview` run `contextProjectGuard`, then
`instanceReplacementGuard` with the replacement allowance read from `NAGARE_ALLOW_VM_REPLACEMENT`,
and return the classifier's verdict text as evidence. Make `pulumi-apply` run both guards again and
then `pulumi up --yes --stack <context> --non-interactive` without `--skip-preview`.

In `cli/nagarectl/src/Nagare/Platform/Status.hs`, change `parseHostIdentity` to compare against
`T.stripStart line`. Add tests in `cli/nagarectl/test/PlatformSpec.hs` that feed the exact text
rendered by `renderHostFlake` and assert the version and revision are read, and a test that a
replacing preview fixture makes the preview phase fail. Update `docs/user/upgrades.md` to say the
Pulumi phases are guarded and how to allow a deliberate replacement, and add ADR 18 recording that
the upgrade transaction must run the same project and replacement guards as the recipes.

Acceptance: the new tests fail before the change and pass after; `nagarectl platform status` from
this build against `tan-nb-exp` shows `Host: 0.1.0` instead of `legacy / unknown`.

### Milestone 3b: merge `context create --force` and protect the DNS zone and buckets

In the `ContextCreate` handler in `cli/nagarectl/app/Main.hs`, when the context exists and `--force`
is passed, read the stored context map (the same parser `readContextProfile` uses in
`cli/nagarectl/src/Nagare/Target.hs`) and insert the flag pairs from `contextEnvPairs o` over it,
so only passed flags change. Keep `NAGARE_PLATFORM_VERSION` from the stored file when present
instead of stamping the payload version, because changing a field is not an upgrade. Print the
fields that changed. Add tests that a forced create with only `--acme-directory staging` keeps the
stored base domain, project, VM shape, and platform version.

In `cli/nagarectl/src/Nagare/Infra/Plan.hs`, replace the single `gceInstanceType` target with
`protectedResourceTypes`, containing `gcp:compute/instance:Instance`,
`gcp:dns/managedZone:ManagedZone`, and `gcp:storage/bucket:Bucket`. `classifyPlan` takes that list,
and the refusal names each replaced resource and why it matters (a zone replacement issues new name
servers; a bucket replacement deletes its objects). Extend the classifier tests in
`cli/nagarectl/test/Spec.hs` with zone and bucket replacement fixtures. Update
`docs/user/contexts.md` (the Let's Encrypt staging section) to show the merging command and to warn
that changing `NAGARE_BASE_DOMAIN` replaces the DNS zone, and update
`docs/user/provisioning-with-pulumi.md` where it describes `NAGARE_ALLOW_VM_REPLACEMENT`.

Acceptance: the new tests fail at `v0.2.0` and pass after the change, and a forced create against a
scratch context with one flag changes exactly one line of the context file.

### Milestone 4: release Nagare 0.2.1

Follow `docs/runbooks/releases.md` and the repository's `nagare-release` skill end to end: set
0.2.1 in `release.json`, the three Cabal files, and the compatibility fixture
`cli/nagarectl/test/PlatformSpec.hs`; cut `CHANGELOG.md`; write `docs/releases/v0.2.1.md` covering
the stack path migration, guarded upgrades, the host identity fix, and the 0.2.0 known issue; run
the source, local, native CI, and rehearsal gates; sign and push `v0.2.1`; and verify the published
attachments and `nix run github:shinzui/nagare/v0.2.1#nagarectl -- version --json`. Add a known-issue
note to the v0.2.0 GitHub release description that points operators at 0.2.1 instead of running
`platform upgrade` with 0.2.0.

### Milestone 5: rehearse, then upgrade `tan-nb-exp` to 0.2.1

First, without mutation: link the canonical stack file into the private repository, open the
Kubernetes port forward, run `nagarectl platform status`, `nagarectl context guard`, and
`nagarectl infra guard` from the 0.2.1 CLI, run `platform upgrade --to 0.2.1 --dry-run --json`, and
review the recorded Nix evaluation, the Pulumi verdict (must be no replacement and no changes other
than those explained), and the Kubernetes diff. Run `scripts/host-switch.sh --dry-run` against the
staged host flake and `nagare --dry-run cluster-bootstrap` to confirm the exact commands, and
confirm Tailscale SSH accepts a fresh non-interactive login (`ssh -o BatchMode=yes deploy@nagare-01
true`), because host-switch verifies access with a brand-new login.

Then ask the operator once for the bounded apply: `platform upgrade --apply --resume <id> --yes`
for that transaction. Stop on any refused guard, a Pulumi verdict other than no replacement, a
`NOT COMMITTED` host result, or a failed rollout; the transaction keeps the old context pin and is
resumable by identifier. Afterwards verify status is `exact` at 0.2.1, `nagarectl doctor` passes,
the issuer is Ready, and a Knative service still serves; then commit the updated context pin and
host flake in `nagare-ops`.


## Concrete Steps

Milestone 1, from a scratch directory (never the repository):

```bash
S=$(mktemp -d) && cd "$S" && mkdir proj real && cd proj
printf 'name: linkprobe\nruntime: yaml\n' > Pulumi.yaml
export PULUMI_BACKEND_URL="file://$S/state" PULUMI_CONFIG_PASSPHRASE=probe
mkdir -p "$S/state" && pulumi stack init probe --non-interactive
mv Pulumi.probe.yaml "$S/real/Pulumi.probe.yaml" 2>/dev/null || : > "$S/real/Pulumi.probe.yaml"
ln -s "$S/real/Pulumi.probe.yaml" Pulumi.probe.yaml
pulumi config set --stack probe k v && test -L Pulumi.probe.yaml && grep -q 'k: v' "$S/real/Pulumi.probe.yaml"
pulumi config get --stack probe k        # expect: v
```

Milestones 2 and 3. Haskell tests run inside the `cli/nagarectl` Cabal project; style and flake
checks run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/cli/nagarectl
nix develop -c cabal test nagarectl-test --test-show-details=direct
cd /Users/shinzui/Keikaku/bokuno/nagare
just haskell-style-check
nix flake check --print-build-logs
```

Milestone 2 live read-only acceptance, from the repository root with the `tan-nb-exp` context active:

```bash
mkdir -p ~/.config/nagare/pulumi
ln -sfn /Users/shinzui/Keikaku/bokuno/nagare-ops/pulumi/Pulumi.tan-nb-exp.yaml ~/.config/nagare/pulumi/Pulumi.tan-nb-exp.yaml
CLI="$(nix build --no-link --print-out-paths .#nagarectl)/bin"
"$CLI/nagarectl" context guard
"$CLI/nagarectl" infra guard
```

Expected output ends with:

```text
infra guard: no GCE instance replacement is planned
```

Milestone 5 commands are recorded here as they are rehearsed.


## Validation and Acceptance

The change is accepted when all of the following hold. The `nagarectl-test` suite includes passing
`planStackLink` cases for every branch and passing host identity and guarded-preview cases that fail
on `v0.2.0`. `nix flake check` passes, including the extended clone-free platform check that proves
a workspace links to the canonical stack file and that `pulumi config set` writes through it. The
0.2.1 release passes every gate in `docs/runbooks/releases.md`, and
`nix run github:shinzui/nagare/v0.2.1#nagarectl -- version --json` reports version `0.2.1`. Against
`tan-nb-exp`, the 0.2.1 CLI's `context guard` is confined, `infra guard` finds no replacement, and
`platform status` shows the host's recorded version. After Milestone 5, `nagarectl platform status`
reports `exact` with every identity `0.2.1`, the `nagare-platform-version` ConfigMap exists, and the
VM's instance ID is unchanged from before the upgrade (`gcloud compute instances describe nagare-01
--format='value(id)'`).


## Idempotence and Recovery

Linking is idempotent: a workspace entry that already links to the canonical path is left alone,
and a refusal changes nothing. Removing a workspace link and re-running any Pulumi command recreates
it. A mistaken canonical file is recoverable from the private repository's git history or from the
checkout's former symlink target, which this plan never deletes.

Release steps follow the release runbook's recovery rules: never move or delete a pushed tag; fix
forward with a new version.

The upgrade transaction persists every phase under
`${XDG_STATE_HOME}/nagare/tan-nb-exp/upgrades/` and advances the context pin last. A failure leaves
the old pin; resume with `nagarectl platform upgrade --apply --resume <id> --yes` after fixing the
cause. `host-apply` uses the self-reverting host switch, so a lost login reverts the host after the
confirmation window; do not run further host commands until that window passes. Before
Milestone 5's apply, record the VM instance ID, confirm the latest scheduled database backups
succeeded, and keep the 0.1.0 and 0.2.0 payload workspaces, because release selection does not
restore data.


## Interfaces and Dependencies

At the end of Milestone 2, `cli/nagarectl/src/Nagare/Platform/StackConfig.hs` exports:

```haskell
data CanonicalObservation = CanonicalAbsent | CanonicalPresent !ByteString | CanonicalDangling !FilePath
data EntryObservation = EntryAbsent | EntryLinksTo !FilePath !Bool | EntryRegular !ByteString
data StackLinkAction
  = LinkOnly
  | ReplaceWithLink
  | AdoptThenLink
  | CreateEmptyThenLink
  | AlreadyLinked
  | RefuseStackLink !Text
contextStackConfigPath :: ContextName -> IO FilePath
stackConfigEntryPath :: ContextName -> FilePath -> FilePath
planStackLink :: FilePath -> FilePath -> CanonicalObservation -> EntryObservation -> StackLinkAction
linkContextStackConfig :: ContextName -> FilePath -> IO (Either Text FilePath)
```

At the end of Milestone 3, `cli/nagarectl/app/Main.hs` defines the shared guard pieces, and
`cli/nagarectl/src/Nagare/Infra/Plan.hs` exports `protectedResourceTypes`, `previewErrors`, and
`PlanVerdict = PlanAllowed | PlanReplacesProtected [PlanStep]`:

```haskell
projectGuardInputsFor :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ProjectGuardInputs
instanceReplacementGuard :: TargetProfile -> PlatformWorkspace -> String -> Bool -> IO (Either Text Text)
ensurePulumiProgramDependencies :: FilePath -> IO ()
```

`cli/nagarectl/src/Nagare/Target.hs` exports
`mergeContextOverrides :: Maybe (Map String Text) -> [(String, Text)] -> Text -> Map String Text`.

No new library dependencies are needed: `directory` already provides `createFileLink`,
`getSymbolicLinkTarget`, `pathIsSymbolicLink`, and `canonicalizePath`. External tools are the
pinned `pulumi` 3.255.0, `just`, `kubectl`, `gcloud`, and `nix` already used by the workspace
recipes. Haskell style follows ADR 16 and must pass `just haskell-style-check`.

## Revision notes

- 2026-09-13: Recorded Milestone 1 evidence. Added Milestone 3b after the `tan-infrastructure`
  session reported, and this session verified, that `context create --force` resets omitted fields
  and that the replacement guard does not protect the DNS zone or buckets; both ship in 0.2.1.
- 2026-09-13: Implemented Milestones 2, 3, and 3b. Added the npm dependency install discovered in
  Milestone 2, recorded why the upgrade-phase wiring is verified live rather than unit-tested, and
  aligned Interfaces and Dependencies with the implemented signatures.
