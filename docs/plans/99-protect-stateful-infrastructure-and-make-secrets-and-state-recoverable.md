---
id: 99
slug: protect-stateful-infrastructure-and-make-secrets-and-state-recoverable
title: "Protect stateful infrastructure and make secrets and state recoverable"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
---

# Protect stateful infrastructure and make secrets and state recoverable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Nagare is a personal PaaS running on a single GCP VM (`nagare-01`). Its stateful spine —
the persistent data disk mounted at `/var/lib/nagare`, the GCS backup bucket, the VM
itself, the sops-encrypted secrets in Git, and the Pulumi state ledger — is what makes
the platform recoverable after a disaster. A prior platform review found that this spine
is currently one mistake away from being unrecoverable:

- Nothing stops `pulumi destroy` (or a careless refactor) from deleting the data disk,
  the backup bucket, or the VM. A single wrong command erases every byte of app data.
- The VM's service account holds `roles/storage.objectAdmin` on the backup bucket, so a
  compromised VM can silently delete its own backups; the bucket has no versioning, so
  deleted backups are gone instantly.
- The operational host secrets file now belongs to the selected context at
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/secrets.yaml`. A legacy
  installation may still be sourced from the checked-in
  `nixos/hosts/nagare-01/secrets/nagare-01.yaml` compatibility fixture. In either case
  it is encrypted only to the host's age key, whose private half exists only on the VM
  at `/var/lib/sops-nix/age-key.txt`. If the VM dies before that key is copied to a
  vault, the active secret is unrecoverable and the operator cannot edit it locally.
- The VM's service account holds project-wide `roles/dns.admin` (it only needs the one
  zone), and the instance carries a contradictory `enable-oslogin: TRUE` metadata entry
  that NixOS force-disables.
- Pulumi state defaults to a `file://` backend on the operator's laptop; losing the
  laptop means losing the resource ledger.

After this plan, `pulumi destroy` and accidental deletions are refused for the disk,
bucket, and VM until the operator deliberately unprotects them; the backup bucket keeps
30 days of noncurrent object versions so a malicious or accidental wipe is reversible;
the data disk gets a free-standing daily snapshot schedule (keep 7) as a whole-disk
restore point; every sops-encrypted file is decryptable with an offline recovery key
held in the operator's vault (and host secrets become editable from the workstation);
DNS rights are scoped to the one zone; and the active cloud context's Pulumi state lives
in a versioned GCS bucket instead of only on the laptop. You can see it working: a
deliberate `pulumi destroy --preview-only`-style check refuses the protected resources,
`gcloud` describes show `deletionProtection: true` and versioning enabled, `sops -d`
succeeds with the recovery key on every encrypted file, and
the workspace-resolved `pulumi whoami -v` reports a `gs://` backend.


## Progress

Use this checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

**Status summary (reconciled 2026-08-26): the Pulumi infrastructure changes are
written, committed, and typecheck. The versioned-distribution work in MasterPlan 20
made released workspaces and context-owned host/secret configuration authoritative;
the remaining commands and recovery targets below now follow that model. Every live
GCP step is still blocked on operator action — this workstation has no cloud target
context and its gcloud credentials need an interactive re-login.**

- [x] M1a: Add `protect: true` to the data disk and backup bucket, `deletionProtection`
  (config-driven, default true) to the VM, bucket versioning + 30-day noncurrent
  lifecycle + `publicAccessPrevention: "enforced"` on both buckets, and the daily
  snapshot ResourcePolicy + attachment. (2026-08-05, commit `cfc2ce5`; `tsc --noEmit`
  clean)
- [x] M1b: Replace project-wide `roles/dns.admin` with a zone-scoped
  DNS-zone IAM member plus project-level `roles/dns.reader`. (2026-08-05 — note the
  class is `gcp.dns.DnsManagedZoneIamMember`, not the `gcp.dns.ManagedZoneIamMember`
  this plan named; see Surprises & Discoveries)
- [x] M1c: Drop the `enable-oslogin` metadata entry (fix the comment to describe the
  real auth model), and thread boot-disk size and type through config
  (`bootDiskSizeGb`, `bootDiskType` default `pd-balanced`). (2026-08-05)
- [ ] M1 (BLOCKED — needs a live GCP session): run `pulumi preview --diff`, confirm the
  acceptance gate (update/create only, plus the single expected delete of
  `nagare-iam-dns`), pin `bootDiskType` to the live boot disk's actual type if it is
  not already `pd-balanced`, then `nagare infra-up` and run the post-apply `gcloud`
  describe checks and the `kubectl get clusterissuer letsencrypt-dns` verification.
  **Do not apply without the preview.**
- [x] M2a (partial — the half that needs no key material): delete the dead
  `nixos/secrets/` creation rule and correct the root `.sops.yaml` header comment,
  which wrongly claimed one private key lives in both key locations. (2026-08-05,
  commit `4148e68`; verified by a `sops -e`/`sops -d` round-trip of a scratch file
  under `cluster/secrets/`)
- [ ] M2a (BLOCKED — needs operator key handling): generate the offline recovery age
  key, store the private half in the password manager, and add its public half to the
  source-checkout cluster-secret policy and the operator-owned policy governing the
  active context's host/cluster secrets. Add the workstation key to the host rule.
  Deliberately not started: adding an unstored recovery recipient would create a key
  path nobody can use.
- [ ] M2b (BLOCKED — needs the recovery key, active cloud context, and running VM):
  inventory and re-key every encrypted Secret in the context-owned cluster-secret
  directory plus the actual host file returned by `nagarectl host path`. If the live
  installation has not yet migrated to a generated host flake, decrypt and re-key the
  legacy checked-in file over IAP first, then install that ciphertext into the new
  context host flake with `nagarectl host init --sops-file`.
- [ ] M2c (BLOCKED — depends on M2a/M2b): rewrite the age-key section of
  `docs/runbooks/disaster-recovery.md` to name all three keys. Not written yet because
  it would document a three-key model that does not exist until the re-key lands.
- [ ] M3 (BLOCKED — no cloud context exists on this machine): migrate the active cloud
  context's Pulumi state to GCS. There is nothing to migrate here: the only context is
  the in-repo local-mode profile, and its `default` stack holds **0 resources**.
- [x] Re-audit the live-environment blocker before yielding EP-3: the Nagare context
  directory is still absent, the active gcloud configuration still names
  `tan-nb-exp`/`us-west1-a`, and explicit read-only instance, disk, and bucket queries
  still fail because gcloud requires interactive reauthentication. (2026-08-24)
- [x] Packaging reconciliation: make encrypted cluster secrets context-owned and
  excluded from released payloads/workspaces; update this plan to use the packaged
  `nagare` launcher, workspace-resolved Pulumi/migration paths, and the generated host
  flake as the operational recovery target. The asset and clone-free package checks
  pass with the new secret boundary. (2026-08-26)
- [ ] Final: update MasterPlan 19's registry/progress for EP-99 and write the Outcomes
  & Retrospective entry here. (MasterPlan registry updated 2026-08-05 to In Progress;
  the retrospective waits for the blocked steps.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Planning research (2026-07-15): the root `.sops.yaml` comment (lines 3–7) claims the
  same private key lives at `~/.config/sops/age/keys.txt` and at
  `/var/lib/sops-nix/age-key.txt` on the host. That is wrong: the host file
  `nixos/hosts/nagare-01/secrets/nagare-01.yaml` is encrypted to recipient
  `age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99` (per its sops
  metadata and `nixos/.sops.yaml:2`), while `cluster/secrets/` uses
  `age1pqfv2y3u3y66y5zsr3qd7pnxstatvnlnx39nttzksg8kynn4a5tsq9vcsf` (root
  `.sops.yaml:14`). Two different keys, two different homes. M2 fixes the comment
  along with the recipients.
- Planning research (2026-07-15): the cert-manager ClusterIssuer template
  `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` sets no `hostedZoneName`,
  so cert-manager's Cloud DNS solver must *list* the project's managed zones to find
  the right one before it writes TXT records. Zone-scoped `roles/dns.admin` alone does
  not grant `dns.managedZones.list` at project level; project-level `roles/dns.reader`
  is required alongside it (see M1b).

**The live-environment blocker (2026-08-05).** Three independent facts stop every
live step of this plan on this workstation. All are operator-fixable; none is a
problem with the code.

1. *gcloud credentials are expired and need an interactive login.* Any project-touching
   call fails:

   ```text
   ERROR: (gcloud.compute.instances.describe) There was a problem refreshing your
   current auth tokens: Reauthentication failed. cannot prompt during non-interactive
   execution.
   ```

   Fix: run `gcloud auth login` (and `gcloud auth application-default login` for the
   Pulumi GCP provider) in an interactive shell.

2. *There is no cloud target context here.* `~/.config/nagare/contexts` does not exist
   and there is no in-repo `nagare.target.env`; the only profile is
   `nagare.local.env` (`NAGARE_MODE=local`). So the active context resolves to
   `default` in **local mode**, which is why `scripts/migrate-pulumi-backend.sh` would
   refuse it outright ("only cloud contexts use a GCS Pulumi backend").

3. *The local Pulumi stack is empty.* The `default` stack in
   `file:///Users/shinzui/.local/state/nagare/default/state` reports
   `RESOURCE COUNT 0`, its checkpoint contains zero resources, and
   `infra/pulumi/Pulumi.default.yaml` carries only an encryption salt — no
   `gcp:project`, no `imageBucket`. `pulumi preview` therefore cannot even run
   (`gcpCfg.require("project")` fails), and if it did, every resource would be a
   *create*, so this plan's acceptance gate — "update-in-place only, no replaces" —
   has nothing to assert against. The real `tan-nb-exp` state is not on this machine.

   ```text
   $ pulumi stack ls
   NAME     LAST UPDATE  RESOURCE COUNT
   default  1 month ago  0
   $ pulumi whoami -v
   Backend URL: file:///Users/shinzui/.local/state/nagare/default/state
   ```

   Unblocking M1/M3 means selecting the cloud context that owns the live stack (create
   it under `~/.config/nagare/contexts/<name>.env` with `NAGARE_MODE=cloud` and
   `CLOUDSDK_CORE_PROJECT=tan-nb-exp`, or restore the machine's original context), then
   re-running the preview gate.

**`gcp.dns.ManagedZoneIamMember` does not exist (2026-08-05).** The plan's snippet
names a class the provider does not export. In `@pulumi/gcp` v8 the class is
`DnsManagedZoneIamMember`:

```text
NagarePerimeter.ts: Property 'ManagedZoneIamMember' does not exist on type
'typeof import("@pulumi/gcp/dns/index")'. Did you mean 'DnsManagedZoneIamMember'?
```

Its argument shape (`project`, `managedZone`, `role`, `member`) is exactly as the plan
described. With the rename, `npm run build` (`tsc --noEmit`) is clean.

**This sops build does not search `~/.config/sops/age/keys.txt` (2026-08-05).** Every
`sops -d` / `sops updatekeys` command in this plan fails as written, even though the
workstation key *is* a valid recipient:

```text
age1pqfv2y3u3y66y5zsr3qd7pnxstatvnlnx39nttzksg8kynn4a5tsq9vcsf: FAILED
  - | age: no identity matched any of the recipients. Did not find keys in
    | locations 'SOPS_AGE_SSH_PRIVATE_KEY_FILE', 'SOPS_AGE_SSH_PRIVATE_KEY_CMD',
    | 'SOPS_AGE_KEY', 'SOPS_AGE_KEY_FILE', and 'SOPS_AGE_KEY_CMD'.
```

Naming the file explicitly works, and confirms the key is correct:

```text
$ SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d cluster/secrets/notes-db-url.yaml
cluster-ok
$ age-keygen -y ~/.config/sops/age/keys.txt
age1pqfv2y3u3y66y5zsr3qd7pnxstatvnlnx39nttzksg8kynn4a5tsq9vcsf
```

Prefix `SOPS_AGE_KEY_FILE=…` to every sops command in M2. This is now recorded in the
root `.sops.yaml` header so the next person does not lose time to it.

**The host secret is confirmed workstation-undecryptable**, exactly as the plan
predicted: `sops -d nixos/hosts/nagare-01/secrets/nagare-01.yaml` fails with the
workstation key even when it is named explicitly, because `age1rc26869…` is its only
recipient. That is the recovery gap this plan exists to close, and closing it requires
the VM.

**The live-environment blocker persisted on 2026-08-24.** The workstation still has
no `~/.config/nagare/contexts` directory. Although gcloud's active configuration names
project `tan-nb-exp`, zone `us-west1-a`, and region `us-west1`, explicit read-only
`instances describe`, `disks describe`, and `storage buckets list` commands all fail
with the same `Reauthentication failed. cannot prompt during non-interactive
execution` error recorded on 2026-08-05. No live apply, state migration, or host-secret
re-key was attempted. Because the MasterPlan has no hard dependencies, implementation
can proceed with EP-4 while these operator-only steps remain visible here.

**MasterPlan 20 changed the operational filesystem boundary on 2026-08-25.**
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
makes released assets immutable and context workspaces content-addressed, while
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)
makes `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/secrets.yaml` the
operational host secret. The old checked-in host file is only a compatibility fixture.
Following the original M2 literally would therefore recover the fixture but could miss
the real host. The packaged secret resolver added on 2026-08-26 similarly keeps
encrypted cluster credentials outside payloads at
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/`.

(Add further implementation discoveries here as they occur.)


## Decision Log

Record every decision made while working on the plan.

- Decision: make the VM's `deletionProtection` config-driven
  (`vmDeletionProtection`, default `true`) rather than hardcoded.
  Rationale: GCP refuses to delete a protected instance, and the platform's *intended*
  rebuild path (`docs/runbooks/disaster-recovery.md`, "Replace the VM onto the fixed
  image") replaces the VM by changing `nagareImageSelfLink`, which forces a Pulumi
  replacement. A config toggle (`pulumi config set vmDeletionProtection false`, apply,
  rebuild, re-enable) keeps the deliberate path a two-command procedure instead of a
  code edit, while the default stays fail-closed.
  Date: 2026-07-15
- Decision: 30 days for expiring noncurrent backup-object versions.
  Rationale: the backup CronJobs keep the last 7 dumps per prefix and prune older ones
  daily, so with versioning on, pruned/overwritten objects become noncurrent. 30 days
  gives a full month to notice a malicious or accidental wipe (the threat is the node
  SA's own `objectAdmin`), which comfortably exceeds the weekly-or-so cadence of a
  personal operator. Cost is bounded: noncurrent storage is roughly one extra
  generation of the backup set for a month; at us-west1 regional Standard pricing
  (~$0.023/GB-month) even 20 GB of retained noncurrent dumps is under $0.50/month.
  Date: 2026-07-15
- Decision: default boot-disk type `pd-balanced` in code, but pin the *live* stack's
  `bootDiskType` config to its current actual type (expected `pd-standard`) unless the
  operator performs a VM replacement during M1.
  Rationale: GCE cannot convert a boot disk's type in place — changing
  `bootDisk.initializeParams.type` forces Pulumi to *replace* the instance, and this
  plan's hard rule is that M1's apply shows update-in-place only. Pinning keeps the live
  stack diff-free while every fresh stack (and the next deliberate rebuild, when the pin
  is removed) gets `pd-balanced`. The runbook's rebuild path re-bootstraps the cluster
  anyway, so the type upgrade rides along at zero extra cost then.
  Date: 2026-07-15
- Decision: keep zone-scoped `roles/dns.admin` + project-level `roles/dns.reader`
  rather than adding `hostedZoneName` to the ClusterIssuer template.
  Rationale: `dns.reader` is read-only and satisfies the solver's zone-listing lookup
  without touching cluster manifests (which would add a template variable and a
  re-bootstrap step to this plan's scope). Tightening further by setting
  `hostedZoneName` and dropping `dns.reader` is left as an optional follow-up noted in
  M1b.
  Date: 2026-07-15
- Decision: M3 migrates the active cloud context to the GCS Pulumi backend and updates
  documentation to *recommend* GCS for cloud contexts, but does **not** flip the coded
  default from `local` to `gcs`.
  Rationale: EP-93 (`docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md`)
  is Complete and shipped the whole machinery — context fields
  `NAGARE_PULUMI_BACKEND`/`NAGARE_PULUMI_BACKEND_URL`, idempotent bucket bootstrap, and
  `scripts/migrate-pulumi-backend.sh` — but its Decision Log explicitly records "GCS
  Pulumi state is opt-in per cloud context, not the default" and its one intentional
  gap is the live GCS validation. Flipping the coded default would silently retarget
  every existing context's state, contradict EP-93's recorded decision, and require
  edits to `scripts/lib/target.sh`, which is owned by EP-97
  (`docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md`). Doing
  the live migration here closes EP-93's gap and makes the operator's real state
  recoverable, which is this plan's actual goal.
  Date: 2026-07-15
- Decision: two-key sops remediation — one *new* offline recovery key added to every
  creation rule, plus the existing workstation project key added to the host-secrets
  rule.
  Rationale: the offline key (private half only in the vault, never on any machine
  long-term) is the disaster-recovery root of trust; the workstation key on the host
  rule fixes the day-to-day problem that the operator cannot `sops` edit host secrets
  locally. Reusing the workstation key alone as "the recovery key" would leave both
  halves of the trust on machines that can be lost together.
  Date: 2026-07-15

- Decision: land M1's code without applying it, and split M2 so that only the two
  provably-safe, key-material-free corrections (delete the dead `nixos/secrets/` rule,
  fix the wrong root `.sops.yaml` comment) are done now.
  Rationale: the code is complete and typechecks, and holding it back would leave the
  work invisible and unreviewable; but this plan's own acceptance gate is "preview
  shows update-in-place only", and no preview is possible here (see the
  live-environment blocker in Surprises & Discoveries), so applying would be
  unverifiable. On the sops side, adding a recovery recipient whose private half is not
  yet in the operator's vault would produce a recipient nobody can use, and generating
  that key here would put its private half on a machine — the exact failure mode M2
  exists to prevent. Every commit therefore leaves the repository self-consistent.
  Date: 2026-08-05
- Decision: M1's code landed as one commit rather than the three the plan suggested.
  Rationale: the protection, bucket-hardening, snapshot, IAM-scoping and instance
  changes interleave within the same regions of the same three files; splitting them
  would have meant partial staging of adjacent hunks for no reviewability gain. The
  commit body enumerates each concern separately.
  Date: 2026-08-05
- Decision: use `gcp.dns.DnsManagedZoneIamMember` (the class the provider actually
  exports) in place of the plan's `gcp.dns.ManagedZoneIamMember`.
  Rationale: the latter does not exist in `@pulumi/gcp` v8; the former has the
  identical argument shape, so nothing else in the plan changes.
  Date: 2026-08-05

- Decision: perform all remaining live work through the selected packaged release and
  recover context-owned configuration rather than treating this checkout as the
  operator state root.
  Rationale: ADRs 4–7 separate immutable release assets, mutable workspaces, context
  intent, generated host flakes, and encrypted credentials. Direct checkout paths can
  still validate contributor changes, but they no longer identify the live context's
  Pulumi program or secrets. Cluster secrets default to the context-owned XDG path and
  host secrets come from `nagarectl host path`; both must be included in M2 acceptance.
  Date: 2026-08-26

(Record further decisions as work proceeds.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The infrastructure implementation remains complete but unapplied. Packaging
reconciliation on 2026-08-26 closed a newly discovered distribution gap: released
payloads/workspaces no longer carry cluster secrets, and recovery work now targets the
generated host flake and context-owned encrypted Secret directory. The packaged asset
and clone-free checks prove that boundary. Live GCP apply,
offline-key creation/re-keying, state migration, and final retrospective remain open.


## Context and Orientation

The remaining operator work uses the pinned `nagare` package, not a mutable checkout.
`nagarectl platform root --json` reports the immutable payload and writable context
workspace; `nagare infra-preview`, `nagare infra-up`, and `nagare host-switch` run the
release's recipes in that workspace. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md), and
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
are the durable contracts. Checkout-relative paths below describe the source files
that implemented M1; workspace-resolved paths are authoritative for live validation.

Nagare provisions its GCP perimeter with a TypeScript Pulumi program under
`infra/pulumi/`. The entrypoint `infra/pulumi/index.ts` reads Pulumi config (project,
region, zone, `dataDiskSizeGb`, `backupBucket`, `imageBucket`, `nagareImageSelfLink`,
…) and instantiates one component, `NagarePerimeter`
(`infra/pulumi/src/components/NagarePerimeter.ts`), which declares: the network, a
static IP, the persistent **data disk** (line 56, `gcp.compute.Disk`, `pd-balanced`,
mounted on the VM at `/var/lib/nagare` — all app data lives there), the node **service
account** `nagare-node` (line 64) with two project-wide IAM grants (lines 76–85:
`roles/dns.admin` and `roles/artifactregistry.writer`), the **backup bucket** (line 89,
`gcp.storage.Bucket`, uniform bucket-level access, `forceDestroy: false`) with an
`objectAdmin` grant to the node SA (lines 98–102), the **image staging bucket** (lines
107–112), the Cloud DNS **managed zone** + wildcard record (lines 117–130), the
Artifact Registry repo (lines 134–138), and — once an image self-link exists — the VM
via `NagareInstance` (lines 141–152).

`infra/pulumi/src/components/NagareInstance.ts` declares the `gcp.compute.Instance`
(line 24): `allowStoppingForUpdate: true` (line 34), a boot disk with hardcoded
`size: 100` and **no explicit type** (line 40 — the provider default is the slow
`pd-standard`), the attached data disk (lines 41–45), and a metadata entry
`"enable-oslogin": "TRUE"` (line 60). That metadata entry is dead weight and misleading:
`nixos/hosts/nagare-01/security.nix:27` sets
`security.googleOsLogin.enable = lib.mkForce false`, and SSH access really works as the
`deploy` user's declarative `authorized_keys` over the IAP tunnel
(`scripts/iap-ssh.sh`).

Secrets use **sops** with **age** keys. sops stores ciphertext plus age recipients
(public keys) that can unwrap the file's data key. Released payloads exclude operator
credentials. The active cloud context therefore has two operator-owned stores to
inventory in addition to any legacy checkout ciphertext:

- `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` contains
  encrypted Kubernetes Secret manifests. `NAGARE_CLUSTER_SECRETS_DIR` may name an
  explicit alternative. `scripts/lib/cluster-secrets.sh` resolves the context path and
  permits tracked `cluster/secrets/` only as a source-checkout compatibility fallback.
- `nagarectl host path --context <context>` returns a generated host flake whose
  `secrets.yaml` is the operational sops-nix input. Its policy is operator-owned and
  may live beside that flake or in a private configuration repository. The checked-in
  `nixos/hosts/nagare-01/secrets/nagare-01.yaml` and `nixos/.sops.yaml` are legacy /
  evaluation compatibility inputs, not an operational fallback after host generation.

The root `.sops.yaml` still governs tracked checkout examples with the workstation
recipient `age1pqfv2y3…`; the existing host recipient is `age1rc26869…`, whose private
half is on the VM at `/var/lib/sops-nix/age-key.txt`. Before re-keying, inventory both
Git (`git grep -l 'ENC\[AES256_GCM'`) and the two context-owned directories. Acceptance
covers the union, not merely the files committed in this repository.

Pulumi **state** (the ledger of which cloud resources Pulumi owns) lives, per target
context, in a local `file://` backend under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state` by default. EP-93
(`docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md`, Complete) added an
opt-in GCS backend: a context sets `NAGARE_PULUMI_BACKEND=gcs` (URL defaulting to
`gs://<project>-nagare-pulumi-state/nagare/<context>`), and
the selected workspace's `scripts/migrate-pulumi-backend.sh` performs the supported `pulumi stack export` /
`stack import` migration, bootstraps the versioned state bucket, verifies stack outputs
match, and only then flips the context file (rollback supported). EP-93 deliberately
deferred the *live* GCS run; M3 performs it. This plan references EP-93 for all backend
mechanics rather than restating them.

Live applies run through the selected release: `nagare infra-preview` and
`nagare infra-up` prepare the content-addressed workspace and run its recipes with the
backend/stack environment exported by `scripts/lib/target.sh`. Direct Pulumi inspection
uses `$(nagarectl platform root --json | jq -r .workspaceRoot)/infra/pulumi`.

Ownership boundaries with sibling plans (do not cross them):

- `scripts/lib/target.sh` and justfile guardrail logic are owned by EP-97
  (`docs/plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md`). This
  plan must not edit guardrail logic. M3 needs no such edit — the migration script
  already updates the context file itself.
- `docs/runbooks/disaster-recovery.md` is also edited by EP-103
  (`docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`). This
  plan edits **only** the age-key section ("The one thing that is NOT in Git or the
  bucket", currently lines 25–31); EP-103 owns the rest of the runbook.

Commit conventions: Conventional Commits, staged with explicit paths (never
`git add -A`), each commit carrying the trailers:

```text
MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md
ExecPlan: docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md
```


## Plan of Work

### Milestone 1 — Pulumi: deletion protection, bucket hardening, snapshots, scoped IAM, instance fixes

Scope: all edits are in `infra/pulumi/index.ts`,
`infra/pulumi/src/components/NagarePerimeter.ts`, and
`infra/pulumi/src/components/NagareInstance.ts`. At the end, the data disk and backup
bucket are Pulumi-protected, the VM has GCP deletion protection, both buckets enforce
public-access prevention, the backup bucket versions objects and expires noncurrent
versions after 30 days, the data disk has a daily keep-7 snapshot schedule, DNS rights
are zone-scoped, the OS Login metadata contradiction is gone, and the boot disk is
config-driven. Acceptance: `pulumi preview --diff` shows **only** `update` and `create`
steps (never `replace` or `delete-replace` — the single allowed `delete` is the old
project-wide `dns.admin` IAM member), and post-apply `gcloud` describes confirm each
property.

**Protection (finding 1).** In `NagarePerimeter.ts`, change the data disk's resource
options (line 56's declaration currently ends `{ parent: this }` at line 60) to
`{ parent: this, protect: true }`, and likewise the backup bucket (declaration at lines
89–94). `protect: true` is a *Pulumi state* option: any plan that would delete the
resource fails with "resource … is protected". It causes no cloud API change, so
preview shows no diff for it (the option is recorded on the next state write). In
`NagareInstance.ts`, add a `deletionProtection: pulumi.Input<boolean>` field to
`NagareInstanceArgs` and set `deletionProtection: args.deletionProtection` on the
instance (near line 34's `allowStoppingForUpdate`). This is a *GCP-level* flag — the
API refuses instance deletion while it is set — and the provider updates it in place.
Thread it from `index.ts` as `const vmDeletionProtectionCfg =
cfg.getBoolean("vmDeletionProtection") ?? true;`, through a new
`vmDeletionProtection: boolean` field on `NagarePerimeterArgs`, into the
`NagareInstance` construction (lines 141–152). Document the deliberate unprotect
procedure (see Idempotence and Recovery) in a code comment next to each option: for the
disk/bucket, `pulumi state unprotect '<urn>'`; for the VM, set
`vmDeletionProtection false` in the workspace Pulumi directory and run `nagare infra-up` before
an intentional rebuild, then set it back to `true` after.

**Backup bucket hardening (finding 2).** On the backup bucket (lines 89–94) add:

```typescript
versioning: { enabled: true },
lifecycleRules: [{
    action: { type: "Delete" },
    condition: { daysSinceNoncurrentTime: 30 },
}],
publicAccessPrevention: "enforced",
```

and add `publicAccessPrevention: "enforced"` to the image bucket (lines 107–112). With
versioning on, a delete or overwrite (including by the node SA, which keeps its
`objectAdmin` grant for the backup jobs) archives the old generation as a *noncurrent
version*, restorable for 30 days. The lifecycle rule bounds cost (see Decision Log:
about one extra backup-set generation for a month, well under $1/month at this
platform's scale). All three properties are in-place bucket updates.

**Daily disk snapshots (finding 3).** Beneath the data disk in `NagarePerimeter.ts`,
add a snapshot schedule and attach it:

```typescript
// Daily whole-disk snapshot of the data disk (keep 7). This is the coarse,
// beneath-the-apps restore point; app-level backups (EP-7 / managed DBs)
// remain the primary mechanism. KEEP_AUTO_SNAPSHOTS: snapshots outlive the
// disk, which is exactly the disaster this guards against. Incremental
// snapshots of a ~100 GB pd-balanced disk cost on the order of $1-3/month.
const dataSnapshots = new gcp.compute.ResourcePolicy(`${name}-data-snapshots`, {
    region: args.region,
    snapshotSchedulePolicy: {
        schedule: { dailySchedule: { daysInCycle: 1, startTime: "08:00" } },
        retentionPolicy: { maxRetentionDays: 7, onSourceDiskDelete: "KEEP_AUTO_SNAPSHOTS" },
    },
}, { parent: this });
new gcp.compute.DiskResourcePolicyAttachment(`${name}-data-snapshot-attach`, {
    name: dataSnapshots.name,
    disk: dataDisk.name,
    zone: args.zone,
}, { parent: this });
```

`startTime` is UTC and must be on the hour ("08:00" = midnight/1am Pacific, off-peak).
Both resources are pure creates; attaching a resource policy never touches the disk
resource itself, so no replacement can occur.

**Zone-scoped DNS IAM (finding 5).** Replace the project-wide `roles/dns.admin`
member (lines 76–80) with two grants: a zone-scoped admin on the nagare zone (the
`dnsZone` declared at line 117 — move the IAM block below the zone declaration so
`dnsZone.name` is in scope) and a project-level read-only role for zone listing:

```typescript
new gcp.dns.ManagedZoneIamMember(`${name}-iam-dns-zone`, {
    project: args.gcpProject,
    managedZone: dnsZone.name,
    role: "roles/dns.admin",
    member: saMember,
}, { parent: this });
new gcp.projects.IAMMember(`${name}-iam-dns-read`, {
    project: args.gcpProject,
    role: "roles/dns.reader",
    member: saMember,
}, { parent: this });
```

Why `dns.reader` is required: the ClusterIssuer template
`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` sets no `hostedZoneName`, so
cert-manager's Cloud DNS DNS-01 solver first *lists the project's managed zones*
(`dns.managedZones.list`, a project-level permission) to find the zone matching the
domain, then writes the `_acme-challenge` TXT record (covered by the zone-scoped
`dns.admin`). The implementer must verify this live after applying (M1 validation): the
`letsencrypt-dns` ClusterIssuer stays `READY=True` and a certificate issuance/renewal
succeeds (e.g. `kubectl apply -f cluster/bootstrap/cert-manager/test-wildcard-cert.yaml`
against a TLS-enabled setup, or watch the next scheduled renewal). Optional follow-up
(not this plan): set `hostedZoneName` in the template and drop `dns.reader`. Note the
preview for this change legitimately shows one `delete` (the old
`nagare-iam-dns` project member) plus two `create`s; IAM changes propagate within a
minute or two, and a renewal that races the window simply retries.

**Instance fixes (findings 6 and 7).** In `NagareInstance.ts`, delete line 60's
`metadata: { "enable-oslogin": "TRUE" }` and replace the comment at line 59 with the
truth: SSH auth is the `deploy` user's declarative `authorized_keys`
(`nixos/hosts/nagare-01/users.nix`) reached over the IAP tunnel
(`scripts/iap-ssh.sh`); `nixos/hosts/nagare-01/security.nix:27` force-disables OS
Login, so the metadata flag was inert and misleading. Removing a metadata entry is an
in-place update. For the boot disk (line 40), add `bootDiskSizeGb: number` and
`bootDiskType: string` to `NagareInstanceArgs` and write
`bootDisk: { initializeParams: { image: args.imageSelfLink, size: args.bootDiskSizeGb,
type: args.bootDiskType } }`, threading both through `NagarePerimeterArgs` from
`index.ts`:

```typescript
const bootDiskSizeGbCfg = cfg.getNumber("bootDiskSizeGb") ?? 100;
const bootDiskTypeCfg = cfg.get("bootDiskType") ?? "pd-balanced";
```

Keep the existing boot-disk comment about the 100 GB sizing rationale. **Replacement
hazard:** `size` staying 100 produces no diff, but if the live boot disk's actual type
differs from the declared type, the provider forces an instance **replacement** (GCE
cannot convert a boot disk type in place). Before previewing, check reality:
`gcloud compute disks describe nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE"
--format='value(type)'`. If it reports `pd-standard` (expected) and no VM rebuild is
planned right now, pin the live stack in the workspace Pulumi directory with
`pulumi config set bootDiskType pd-standard` so preview stays replace-free; the pin is removed at the next deliberate
rebuild (see Idempotence and Recovery), at which point the fresh VM boots on
`pd-balanced`. If it already reports `pd-balanced`, no pin is needed.

Apply gate: run `nagare infra-preview`, plus workspace-resolved `pulumi preview --diff`
for the transcript, and require that no line
begins with `+-` (replace) or `--` (delete) except the single expected delete of
`nagare-iam-dns`. Only then run `nagare infra-up`. Suggested commits: one for
protection + buckets + snapshots (`feat(infra): protect stateful resources and harden
backup buckets`), one for the IAM scope-down (`feat(infra): scope node SA DNS rights to
the nagare zone`), one for the instance fixes (`fix(infra): drop dead OS Login metadata
and make boot disk config-driven`).

### Milestone 2 — sops: an offline recovery recipient for every secret

Scope: the checkout's cluster-secret policy/examples, the active context's
operator-owned cluster-secret directory and host flake, and the age-key section of
`docs/runbooks/disaster-recovery.md`. At the end, every encrypted file used by the
active context is decryptable by (a) its original consumer key, (b) the operator's
workstation key, and (c) a new offline recovery key whose private half lives only in
the operator's vault. Acceptance inventories both Git and XDG configuration, decrypts
their union with the workstation and recovery keys, and proves the host still renders
its generated flake's secrets with `nagare host-switch`.

First generate the recovery key with `age-keygen` (age is in the dev shell). Record the
public key (a string starting `age1`), store the private half (`AGE-SECRET-KEY-…`) in
the password manager under a clearly-named entry ("nagare sops recovery age key"), and
delete any on-disk copy after M2b's verification. **Never commit the private half; it
must not permanently live on any machine.**

Add the recovery public key to the root `.sops.yaml` rule that governs tracked
checkout cluster-secret examples. Update or create the operator-owned sops policy that
governs `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` and the
file returned by `nagarectl host path`; its host rule lists the host key, workstation
key, and recovery key. Do not make `nixos/.sops.yaml` the policy for a generated host
flake: ADR 5 deliberately places that configuration outside the release.

Re-key the encrypted files. `sops updatekeys` re-wraps the file's data key for the new
recipient set, but it needs to *decrypt* the data key first, i.e. it requires access to
some **existing** recipient's private key:

- `cluster/secrets/notes-db-url.yaml`: the workstation key is an existing recipient
  and `~/.config/sops/age/keys.txt` holds it (confirm with `age-keygen -y
  ~/.config/sops/age/keys.txt`, which must print `age1pqfv…`). Run
  `sops updatekeys -y cluster/secrets/notes-db-url.yaml` from the repo root. The diff
  touches only the sops metadata block (new `age:` recipient stanzas; MAC unchanged).
- The actual host `secrets.yaml` returned by `nagarectl host path` may still have only
  the host recipient, whose private key lives on the VM. If the generated flake does
  not exist yet, use the legacy checked-in ciphertext as the migration source. Decrypt
  over IAP SSH into a shell variable, re-encrypt under the operator-owned three-key
  policy, then pass that encrypted file to `nagarectl host init --sops-file`. Whole-file
  re-encryption changes every ciphertext byte; only the plaintext must round-trip.

Verify per Concrete Steps: decrypt each file with the workstation key; decrypt each
with the recovery key (feed it via `SOPS_AGE_KEY` from the vault copy); statically
confirm the host recipient `age1rc26…` still appears in the host file's metadata; and
(recommended, live) run `nagare host-switch` so sops-nix re-activates and Tailscale stays
up, proving the host still decrypts. Note the pre-existing wrinkle recorded in project
memory: the host has a known sops age-key/Tailscale issue that can make `host-switch`
exit non-zero for unrelated reasons — the assertion that matters is that sops-nix
renders `/run/secrets/…` (check `ssh deploy@… 'sudo ls /run/secrets'` via the tunnel).

Finally rewrite the runbook's key section, `docs/runbooks/disaster-recovery.md` lines
25–31 ("The one thing that is NOT in Git or the bucket") — and only that section, since
EP-103 owns the rest of the file — to a "The keys that are NOT in Git" section naming
all three keys: the **host key** (`age1rc26869…`; private at
`/var/lib/sops-nix/age-key.txt` on the VM; consumed by sops-nix at NixOS activation),
the **workstation/project key** (`age1pqfv2y3…`; private at
`~/.config/sops/age/keys.txt`; day-to-day `sops` editing of both secret trees), and the
**offline recovery key** (public in both `.sops.yaml` files; private *only* in the
vault; the disaster-recovery root of trust — with it alone, every secret in Git
decrypts even if both machines are lost). Suggested commits:
`feat(secrets): add offline recovery recipient to all sops rules` (policy files +
re-keyed secrets) and `docs(runbooks): document the three sops age keys` (or one
combined commit).

### Milestone 3 — Pulumi state: off the laptop, onto versioned GCS

Scope: no guardrail or resolver code changes (owned by EP-97); the mechanics all
shipped in EP-93. This milestone performs the live migration EP-93 deferred and makes
GCS the documented recommendation for cloud contexts. At the end, the active cloud
context's Pulumi state lives in the versioned, public-access-prevented bucket
`gs://<project>-nagare-pulumi-state/nagare/<context>`, a clean preview runs against it,
the local backend remains intact as a rollback source, and
`docs/user/backups-and-disaster-recovery.md` + `docs/user/contexts.md` say GCS is the
recommended backend for cloud contexts.

Resolve the selected release workspace with `nagarectl platform root --json`, then run
its `scripts/migrate-pulumi-backend.sh` with the active cloud context (it refuses
local-mode contexts, exports the stack to a timestamped rollback artifact under
`…/nagare/<context>/pulumi-migrations/`, bootstraps the bucket with versioning +
uniform access + public-access prevention, imports, verifies `baseDomain` and
`backupBucket` outputs match, and only then flips the context file to
`NAGARE_PULUMI_BACKEND=gcs`). Then verify against the workspace's `infra/pulumi`:
`pulumi whoami -v` reports the `gs://` backend and `pulumi preview` completes with `unchanged`
resources (this also re-proves M1 left no pending diff); `gcloud storage ls` shows the
`.pulumi/stacks/` objects. Rollback, if anything looks wrong, is
the same workspace script with `--rollback` (never deletes GCS objects).

Doc edits: in `docs/user/backups-and-disaster-recovery.md`, update the Pulumi-state row
(line 24) and the "three things you must keep off-machine" note (lines 90–95) to state
that GCS is the **recommended** backend for cloud contexts (local `file://` remains the
default for fresh/local contexts, per EP-93's opt-in decision) and that a migrated
context has nothing Pulumi-related to hand-copy off-machine. In `docs/user/contexts.md`,
add one sentence to the existing "Remote GCS Pulumi state" section marking it
recommended for cloud contexts. Do **not** edit `docs/runbooks/disaster-recovery.md`'s
backup-inventory block for this (EP-103 owns it). Suggested commit:
`docs(state): recommend the GCS Pulumi backend for cloud contexts` — noting the
performed migration in the body.


## Concrete Steps

Remaining live commands use the pinned operator package and may run from any directory.
Select the intended cloud context (`nagarectl context use <name>` or
`NAGARE_CONTEXT=<name>`), verify `nagarectl platform status`, and resolve:

```bash
workspace="$(nagarectl platform root --json | jq -r .workspaceRoot)"
pulumi_dir="${workspace}/infra/pulumi"
```

The workspace's `scripts/lib/target.sh` fail-closes if gcloud's project disagrees.

### M1

Edit the three TypeScript files as described in Plan of Work, then check reality and
preview:

```bash
gcloud compute disks describe nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE" --format='value(type)'
# expected: .../diskTypes/pd-standard  -> pin the live stack:
pulumi -C "${pulumi_dir}" config set bootDiskType pd-standard
pulumi -C "${pulumi_dir}" preview --diff
```

Expected preview shape (resource names abbreviated; exact URNs will differ):

```text
    ~ gcp:storage/bucket:Bucket           nagare-backups   update  [diff: +versioning,+lifecycleRules,+publicAccessPrevention]
    ~ gcp:storage/bucket:Bucket           nagare-images    update  [diff: +publicAccessPrevention]
    ~ gcp:compute/instance:Instance       nagare-01        update  [diff: +deletionProtection, -metadata.enable-oslogin]
    + gcp:compute/resourcePolicy:ResourcePolicy            nagare-data-snapshots        create
    + gcp:compute/diskResourcePolicyAttachment:...         nagare-data-snapshot-attach  create
    + gcp:dns/managedZoneIamMember:ManagedZoneIamMember    nagare-iam-dns-zone          create
    + gcp:projects/iAMMember:IAMMember                     nagare-iam-dns-read          create
    - gcp:projects/iAMMember:IAMMember                     nagare-iam-dns               delete
```

**Acceptance gate: the preview shows update-in-place and create only.** If any line is
a `replace` (`+-`), stop: the usual culprit is the boot-disk type pin (re-check the
`gcloud disks describe` value) or an accidental edit inside
`bootDisk.initializeParams.image`. Do not apply until the replace is gone. Then:

```bash
nagare infra-up
```

Post-apply checks (all should print exactly the noted values):

```bash
gcloud compute instances describe nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE" \
  --format='value(deletionProtection)'                      # True
gcloud storage buckets describe "gs://$(pulumi -C "${pulumi_dir}" stack output backupBucket)" \
  --format='value(versioning.enabled,public_access_prevention)'   # True enforced
gcloud compute disks describe "$(pulumi -C "${pulumi_dir}" stack output dataDiskName)" \
  --zone "$CLOUDSDK_COMPUTE_ZONE" --format='value(resourcePolicies)'  # ...-data-snapshots policy URL
gcloud dns managed-zones get-iam-policy "$(pulumi -C "${pulumi_dir}" stack output dnsZoneName)" \
  | grep -A2 dns.admin                                      # serviceAccount:nagare-node@... member
kubectl get clusterissuer letsencrypt-dns                   # READY True (cert-manager still authorized)
```

Prove the protection bites (read-only; do not confirm any prompt):

```bash
pulumi -C "${pulumi_dir}" destroy --preview-only 2>&1 | head -20
# expected: error lines naming the protected disk/bucket URNs:
#   error: Resource "...nagare-data..." cannot be deleted because it is protected.
```

Commit each logical change with explicit paths and the trailers, e.g.:

```bash
git add infra/pulumi/src/components/NagarePerimeter.ts infra/pulumi/index.ts
git commit -m "feat(infra): protect stateful resources and harden backup buckets" \
  -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" \
  -m "ExecPlan: docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md" \
  -m "Intention: intention_01kzakvy1qeasagg3rpbn44749"
```

### M2

Generate and stash the recovery key, then inventory Git and the selected context:

```bash
age-keygen -o /tmp/nagare-recovery.txt      # prints "Public key: age1..."
# Copy the file's contents into the password manager NOW ("nagare sops recovery age key").
context="$(nagarectl context current)"
host_root="$(nagarectl host path --context "${context}" 2>/dev/null || true)"
cluster_secret_dir="${NAGARE_CLUSTER_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/${context}}"
git grep -l 'ENC\[AES256_GCM'
find "${cluster_secret_dir}" -maxdepth 1 -type f -name '*.yaml' -print
test -n "${host_root}" && printf '%s\n' "${host_root}/secrets.yaml"
```

Update the checkout and operator-owned sops policies, then re-key every context-owned
cluster secret. The workstation key is an existing recipient for the tracked examples:

```bash
age-keygen -y ~/.config/sops/age/keys.txt   # must print age1pqfv2y3...
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys -y cluster/secrets/notes-db-url.yaml
for secret in "${cluster_secret_dir}"/*.yaml; do
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys -y "${secret}"
done
```

For the host, use `${host_root}/secrets.yaml` when it exists. If this legacy target has
not generated a host flake yet, use the checked-in compatibility ciphertext as the
migration source, re-encrypt it under the operator-owned host policy, then run
`nagarectl host init --context "${context}" --sops-file <encrypted-file>` with the
complete operator SSH-key arguments. The decrypt step requires the running VM:

```bash
if [ -n "${host_root}" ] && [ -f "${host_root}/secrets.yaml" ]; then
  source_secret="${host_root}/secrets.yaml"
else
  source_secret="nixos/hosts/nagare-01/secrets/nagare-01.yaml"
fi
TUNPID="$("${workspace}/scripts/iap-ssh.sh" tunnel "${NAGARE_INSTANCE_NAME}" 22 2222)"
PLAINTEXT=$(ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p 2222 deploy@127.0.0.1 \
  "sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt \
   nix run nixpkgs#sops -- -d /dev/stdin" < "${source_secret}")
# Re-encrypt with the operator-owned policy and write to a staging encrypted file;
# never put plaintext on disk. Replace this command's --config path with the
# operator policy that covers the context host file.
printf '%s\n' "$PLAINTEXT" | sops --config /secure/operator/.sops.yaml \
  -e --input-type yaml --output-type yaml /dev/stdin > /secure/operator/rekeyed-host-secrets.yaml
unset PLAINTEXT; kill "$TUNPID"
```

Verify every inventoried ciphertext with the workstation and recovery keys. The host
metadata must retain its consumer recipient; then activate through the packaged recipe:

```bash
recovery_key="$(grep AGE-SECRET-KEY /tmp/nagare-recovery.txt)"
for secret in "${cluster_secret_dir}"/*.yaml "${host_root}/secrets.yaml"; do
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d "${secret}" >/dev/null
  SOPS_AGE_KEY="${recovery_key}" sops -d "${secret}" >/dev/null
done
grep -q 'recipient: age1rc26869' "${host_root}/secrets.yaml"
nagare host-switch
shred -u /tmp/nagare-recovery.txt            # vault copy is now the only private copy
```

Then verify over the tunnel that `sudo ls /run/secrets` shows the rendered secrets and
edit the runbook key section. Never commit the recovery private key or a generated host
flake unless it lives in the operator's intended private configuration repository.

### M3

```bash
"${workspace}/scripts/migrate-pulumi-backend.sh"       # add --context NAME to target another
pulumi -C "${pulumi_dir}" whoami -v                    # Backend URL: gs://<project>-nagare-pulumi-state/nagare/<ctx>
pulumi -C "${pulumi_dir}" stack output backupBucket    # unchanged value
pulumi -C "${pulumi_dir}" preview                      # "unchanged: N" — no diff on the GCS backend
gcloud storage ls "gs://${CLOUDSDK_CORE_PROJECT}-nagare-pulumi-state/nagare/" # .pulumi/ objects listed
```

Expected script transcript tail:

```text
[migrate-pulumi-backend] migrated context '<ctx>' to GCS backend gs://<project>-nagare-pulumi-state/nagare/<ctx>.
[migrate-pulumi-backend] rollback artifact: .../pulumi-migrations/pre-gcs-<stamp>.json
```

Then make the doc edits (`docs/user/backups-and-disaster-recovery.md`,
`docs/user/contexts.md`) and commit. Finally update this plan's Progress/Decision
Log/Outcomes, tick EP-99 in MasterPlan 19, and commit the plan updates.


## Validation and Acceptance

The change is accepted when every behavior below is observed.

**Deletion is refused until deliberately allowed.** `pulumi destroy --preview-only`
(or any plan deleting them) errors on the protected data-disk and backup-bucket URNs
with "cannot be deleted because it is protected", and
`gcloud compute instances delete nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE"` (do NOT
actually confirm; the API refuses before any prompt matters) fails with a
`deletionProtection` error. `gcloud compute instances describe … deletionProtection`
prints `True`.

**Backups survive a wipe attempt.** `gcloud storage buckets describe` on the backup
bucket shows `versioning.enabled: True` and `public_access_prevention: enforced` (image
bucket: `enforced` too), and the bucket's lifecycle config shows the delete-after-30-
days-noncurrent rule. Functional probe: copy a scratch object into the bucket, delete
it, and confirm `gcloud storage ls --all-versions gs://<bucket>/scratch-probe` still
lists the noncurrent generation; then remove it fully.

**The disk has an automatic restore point.** `gcloud compute disks describe` on the
data disk lists the `…-data-snapshots` resource policy, and within a day
`gcloud compute snapshots list --filter="sourceDisk~nagare"` shows the first scheduled
snapshot (acceptance for the schedule itself is the attached policy; the first-snapshot
check is a next-day follow-up noted in Progress when applicable).

**Apply-safety held.** The M1 `pulumi preview --diff` transcript, captured in this plan
or the commit body, contains only `update`/`create` steps plus the single expected
`delete` of the project-wide `dns.admin` member — never a `replace`. Acceptance is
explicitly "preview shows update-in-place only".

**cert-manager still solves DNS-01 with scoped rights.**
`kubectl get clusterissuer letsencrypt-dns` reports `READY=True` after the IAM swap,
and a certificate issuance or renewal completes (no `403` / `forbidden` events on the
Challenge resources: `kubectl describe challenge -A` clean).

**Secrets are recoverable and editable.** With only the recovery key
(`SOPS_AGE_KEY=…`), `sops -d` succeeds on the union of files listed by
`git grep -l 'ENC\[AES256_GCM'`, the active context's cluster-secret directory, and
`$(nagarectl host path)/secrets.yaml`. With the workstation key, the same. The
operational host file's metadata still lists the host recipient `age1rc26869…`, and
after `nagare host-switch` sops-nix renders `/run/secrets` on the VM.

**State is off the laptop.** Workspace-resolved `pulumi whoami -v` reports the `gs://`
backend for the active cloud context, and `pulumi preview` against it reports all resources
`unchanged`, and the state bucket has versioning + public-access prevention (the
migration script's `ensure_bucket` asserts this; re-check with
`gcloud storage buckets describe`).

**Docs match reality.** The runbook's key section names the three keys with paths and
purposes; `docs/user/backups-and-disaster-recovery.md` recommends GCS state for cloud
contexts. `just --list` still works (no justfile edits were made by this plan).


## Idempotence and Recovery

Every M1 edit is declarative: re-running `pulumi preview`/`up` after a partial or
repeated apply converges with no further diff. `protect: true` takes effect on the next
state write and is reversible per-resource with
`pulumi state unprotect '<urn>'` (find URNs with `pulumi stack --show-urns`); the
documented deliberate-rebuild procedure is: unprotect the VM path via the workspace's
Pulumi directory, then run `nagare infra-up`
(in-place update), remove the `bootDiskType` pin if present
(`pulumi -C "${pulumi_dir}" config rm bootDiskType`) so the rebuilt VM gets `pd-balanced`,
perform the image-driven replacement, then set `vmDeletionProtection` back to `true`.
Disk/bucket protection should be re-asserted (it is, by the code) on the next `up`
after any manual unprotect. The snapshot policy and attachment are idempotent creates;
deleting them never touches the disk. If the M1 preview ever shows a replace, the
recovery is simply "do not apply" — fix the pin or the edit and re-preview.

M2 is safe to repeat: `sops updatekeys -y` is a no-op when recipients already match,
and the re-encrypt flow can be re-run from the same SSH decrypt at any time. Keep host
plaintext in a shell variable, never in the workspace or XDG tree, and never commit the
recovery private key. Preserve the prior ciphertext until both workstation/recovery
decryptions and `nagare host-switch` succeed. If the SSH decrypt path is unavailable,
stop M2b; do not move the host private key off the VM.

M3 inherits EP-93's safety design: the migration script exports a timestamped rollback
artifact before touching anything, verifies outputs before flipping the context file,
is a no-op when the context is already on GCS, and the workspace-resolved migration
script's `--rollback` restores the local backend without
deleting any GCS object. Leave the local backend directory in place until a GCS
`pulumi preview` has succeeded (the script says the same in its final log line).


## Interfaces and Dependencies

Infrastructure code: `@pulumi/pulumi` and `@pulumi/gcp` (already dependencies of
`infra/pulumi/package.json`; no new packages). New/changed surfaces at the end of M1:

- `infra/pulumi/index.ts`: config reads `vmDeletionProtection: boolean` (default
  `true`), `bootDiskSizeGb: number` (default `100`), `bootDiskType: string` (default
  `"pd-balanced"`), threaded into `NagarePerimeterArgs`.
- `infra/pulumi/src/components/NagarePerimeter.ts` — `NagarePerimeterArgs` gains
  `vmDeletionProtection: boolean; bootDiskSizeGb: number; bootDiskType: string;`. New
  resources `gcp.compute.ResourcePolicy` (`…-data-snapshots`),
  `gcp.compute.DiskResourcePolicyAttachment` (`…-data-snapshot-attach`),
  `gcp.dns.DnsManagedZoneIamMember` (`…-iam-dns-zone`), `gcp.projects.IAMMember`
  (`…-iam-dns-read`); removed resource `…-iam-dns` (project-wide `dns.admin`). Resource
  options `protect: true` on the data disk and backup bucket. Do not rename any of the
  nine exported stack outputs in `index.ts` (they are MasterPlan integration
  contracts).
- `infra/pulumi/src/components/NagareInstance.ts` — `NagareInstanceArgs` gains
  `deletionProtection: pulumi.Input<boolean>; bootDiskSizeGb: number;
  bootDiskType: string;`; the instance sets `deletionProtection` and the explicit boot
  disk `size`/`type`; the `metadata` block is removed.

Secrets tooling: `sops` and `age`. At the end of M2, tracked cluster-secret examples
and the operator-owned context policy include the recovery recipient; the generated
host flake's file includes host + workstation + recovery recipients. sops-nix still
reads `/var/lib/sops-nix/age-key.txt`. `scripts/lib/cluster-secrets.sh` resolves
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/`, permits
`NAGARE_CLUSTER_SECRETS_DIR`, and uses tracked `cluster/secrets/` only in a checkout.

State tooling: `pulumi`, `gcloud storage`, and the shipped EP-93 machinery — the
workspace-resolved `scripts/migrate-pulumi-backend.sh` and the context fields
`NAGARE_PULUMI_BACKEND`/`NAGARE_PULUMI_BACKEND_URL` consumed by `scripts/lib/target.sh`
and `nagarectl` (see `docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md`
for the full contract). This plan adds no interface there.

Plan dependencies: none hard. Soft boundaries — EP-97 owns `scripts/lib/target.sh` /
justfile guardrail logic (this plan touches neither); EP-103 owns
`docs/runbooks/disaster-recovery.md` except the age-key section edited by M2c (if both
plans are in flight, coordinate that file's merge by section). EP-93 is Complete and is
consumed, not modified.

Packaging dependencies: MasterPlan 20 EP-105 through EP-109 are complete. This plan
consumes the immutable payload/workspace, generated host-flake, platform-version, and
tagged-release contracts recorded in `docs/adr/0003-*.md` through
`docs/adr/0007-*.md`; it must not reintroduce checkout-relative operator state.


## Revision Notes

- 2026-07-15 — Initial authoring: rewrote the skeleton into a full ExecPlan from the
  verified platform-review findings (deletion protection, backup-bucket hardening,
  disk snapshots, sops root-of-trust recovery recipients, DNS IAM scope-down, OS Login
  metadata contradiction, boot-disk config, GCS Pulumi backend). All file/line
  references were verified against the working tree on this date; the boot-disk-type
  replacement hazard, the `updatekeys`-needs-an-existing-key constraint, and the
  EP-93 opt-in decision drove the corresponding Decision Log entries. Planning only;
  no source or config was modified.

- 2026-08-26 — Reconciled the remaining live, secret-recovery, and Pulumi-state steps
  with MasterPlan 20's packaged distribution. Host and cluster secrets now resolve
  from context-owned XDG configuration, live commands use the selected release's
  workspace, and checkout paths remain contributor/legacy compatibility only. This
  revision also records and fixes the packaged cluster-secret omission discovered by
  resuming this plan after EP-105–109.
