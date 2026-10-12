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

Full plan before trimming: [121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/121-give-operator-pulumi-stack-config-a-context-owned-home-so-guarded-platform-upgrades-are-safe-ship-0-2-1-and-upgrade-tan-nb-exp.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] (2026-09-13 22:55Z) `nix flake check` passed (28 checks) on the Milestone 2-3b change;
  committed `bf35b90`.
- [x] Milestone 4: release Nagare 0.2.1. (2026-09-13 23:03Z) candidate `3644275`; source-only,
  `nix flake check`, release gate, and clone-free rehearsal passed locally; native Release rehearsal
  (run 34785194885) and CI passed; artifacts assembled with every checksum OK; signed `v0.2.1`
  verified and pushed; publish workflow (run 34786727467) succeeded; all 7 attachments pass their
  checksums and are byte-identical to the rehearsal; `nix run github:shinzui/nagare/v0.2.1#nagarectl
  -- version --json` reports 0.2.1 at `3644275`; the v0.2.0 release description leads with the
  known-issue note.
- [x] (2026-09-13 22:05Z) Milestone 5 rehearsal, read-only: dry-run plan
  `20260913T21593728645-0.2.1-fed38583` succeeded with guarded Pulumi evidence and only the platform
  ConfigMap in the Kubernetes diff; the staged host toplevel equals the running system; host-switch
  and cluster-bootstrap dry runs reviewed; the issuer renders with no diff in a clean environment.
- [x] (2026-09-13 23:05Z) Milestone 5 re-plan with the published CLI inside `nagarectl context env`:
  transaction `20260913T23042832920-0.2.1-fed38583` planned; guarded preview confined with no
  replacement; one Kubernetes object (the platform ConfigMap); staged toplevel identical to the
  running system; instance id `3250226760661474799`.
- [x] (2026-09-13 23:45Z) Milestone 5: operator approved the bounded sequence; started
  `nix-builder-x86`; applied transaction `20260913T23042832920-0.2.1-fed38583` (all eight phases
  succeeded, apply-rc=0); verified; stopped the builder; committed the pins in `nagare-ops`
  (`10b97ba`).
- [x] (2026-09-13 23:50Z) ADR distillation (ADR 13 and 14 amendments, ADR 18) and Outcomes &
  Retrospective.

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

- Observation (Milestone 4): the first local release-gate run failed because this plan file was
  edited while the gates ran, and publication requires a clean worktree. The edit was set aside and
  the gates rerun clean. Later, another session added untracked MasterPlan 21 and ExecPlans
  122-127 files; the tag precondition was narrowed to tracked files, which cannot affect a tag.

- Observation (Milestone 5 rehearsal): a shell loaded by direnv before the context gained
  `NAGARE_ACME_EMAIL` still exports `NAGARE_ACME_EMAIL=` (empty), and the environment beats the
  context file, so the issuer render refused. In an environment with `NAGARE_*`, `CLOUDSDK_*`, and
  `PULUMI_*` removed, it renders with no diff. The apply must run in that clean environment.

  ```text
  nagare: no ACME contact is configured for context 'tan-nb-exp'.
  == issuer diff (clean env)
  issuer diff rc=0
  ```

- Observation (Milestone 5 rehearsal): the staged host flake builds the exact running system, so
  `host-apply` re-activates the current generation.

  ```text
  staged toplevel: /nix/store/zyrpc5ganyhl8abwf4w1m8m64jnnywia-nixos-system-nagare-01-google-compute-26.11.20260911.eaad089
  running system:  /nix/store/zyrpc5ganyhl8abwf4w1m8m64jnnywia-nixos-system-nagare-01-google-compute-26.11.20260911.eaad089
  ```

  The pinned cert-manager (v1.20.2), Knative Serving and Kourier (1.22.0), and net-certmanager
  (1.14.0) match the live cluster. `kubectl diff` shows no change except Knative's
  runtime-rewritten webhook rules and `config-certmanager`, which the recipe re-patches.

- Observation (process error, 2026-09-13): a zsh glob failure in an `&&` chain skipped
  `export KUBECONFIG`, and commands after a `;` then ran `kubectl config view` and
  `kubectl get nodes` against the workstation's default GKE context (`sennari`). Both were
  read-only and nothing was mutated, but this breached the read-isolation rule. Every later live
  command runs under `bash -euo pipefail` and first asserts the kube server
  `https://127.0.0.1:16443` and node `nagare-01`.

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
- Decision: run the Milestone 5 apply inside `eval "$(nagarectl context env)"` from the published
  CLI, started from `env -i`, rather than the operator's direnv shell or a fully empty environment.
  Rationale: the rehearsal showed that the direnv shell carries a stale empty `NAGARE_ACME_EMAIL`,
  and that an empty environment exposes gcloud's own configured project (`tan-ng`), which the
  project guard would rightly refuse. `context env` is the launcher's exact contract for the
  context.
  Date: 2026-09-13
- Decision: start `nix-builder-x86` for the apply and stop it afterwards.
  Rationale: `host-apply` runs `scripts/host-switch.sh` in its default local-build-and-copy mode,
  and the transaction offers no way to pass `--build-on-host`. The workstation store lacks the
  host closure, and the remote x86 builder was `TERMINATED`. Without the builder, `host-apply` fails
  before anything on the host is armed, which is safe but leaves a failed transaction.
  Date: 2026-09-13
- Decision: ship as 0.2.1, a patch release.
  Rationale: the change fixes defects in 0.2.0 and adds no incompatible interface; existing
  checkout symlinks keep working once the canonical file is linked.
  Date: 2026-09-13

## Outcomes & Retrospective

Every part of the purpose was delivered. Nagare 0.2.1 is published at `v0.2.1` (`3644275`) with
the context-owned stack config, guarded upgrade Pulumi phases, the wider replacement guard, the
merging `context create --force`, and correct host identity parsing. `tan-nb-exp` was upgraded from
a legacy context to 0.2.1 through the guarded transaction. The verification after the apply:

```text
CLI: 0.2.1  Payload: 0.2.1  Context: 0.2.1  Host: 0.2.1  Cluster: 0.2.1  Compatibility: exact
instance id 3250226760661474799 RUNNING          (unchanged from the baseline)
pulumi-apply: both guards passed; Resources: 31 unchanged; Duration: 8s
running system == boot profile == zyrpc5ga...-26.11.20260911.eaad089; no pending rollback timer
letsencrypt-dns True; nagare-access, hello, protected-hello Ready; controllers rolled out
nagarectl doctor: 0 failed, 4 warnings, 18 ok
```

The four doctor warnings were not introduced by the upgrade. One is the documented
external-domain TLS warning for the placeholder base domain `apps.example.com`. Three report no
recent backup object, although the scheduled `nagare-dbbackup-*` jobs completed 18 hours before the
upgrade. That mismatch between the doctor's backup probe and the jobs' output location is unexplained
and should be investigated separately; this plan did not change backups.

Remaining gaps: the guarded upgrade phases are verified live rather than by a unit test through
`UpgradeOps`, and `host-apply` cannot select `host-switch --build-on-host`, so an upgrade from an
`aarch64-darwin` workstation needs the remote builder running.

Lessons. First, a guard is only as good as the file it reads: 0.2.0's project guard, replacement
guard, and transaction all read a workspace that never had the operator's stack config, and only a
live read-only audit exposed it. Second, the operator's shell is a hazard as real as the tooling:
a stale direnv snapshot held an empty ACME contact and hid gcloud's own configured project, and a
broken `&&` chain once let `kubectl` fall through to an unrelated cluster. Running every live
command from `env -i` plus `nagarectl context env`, with the kube server and node asserted first,
removed both classes of error. Third, readiness probes must use the same identity as the real
operation: a builder SSH probe as the operator's user can never succeed against a daemon-only key.
Durable context was promoted to ADR 13 and ADR 14 amendments and to ADR 18.

