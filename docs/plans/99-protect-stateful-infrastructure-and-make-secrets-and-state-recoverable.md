---
id: 99
slug: protect-stateful-infrastructure-and-make-secrets-and-state-recoverable
title: "Protect stateful infrastructure and make secrets and state recoverable"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
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
- The host secrets file `nixos/hosts/nagare-01/secrets/nagare-01.yaml` is encrypted to
  **only** the host's age key, whose private half exists **only** on the VM at
  `/var/lib/sops-nix/age-key.txt`. If the VM dies before that key was copied to a vault,
  the secrets are unrecoverable — and even today the operator cannot `sops` edit the
  file from the workstation.
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
`pulumi -C infra/pulumi whoami -v` reports a `gs://` backend.


## Progress

Use this checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] M1a: Add `protect: true` to the data disk and backup bucket, `deletionProtection`
  (config-driven, default true) to the VM, bucket versioning + 30-day noncurrent
  lifecycle + `publicAccessPrevention: "enforced"` on both buckets, and the daily
  snapshot ResourcePolicy + attachment. `pulumi preview --diff` shows update/create
  only — no replaces.
- [ ] M1b: Replace project-wide `roles/dns.admin` with a zone-scoped
  `gcp.dns.ManagedZoneIamMember` plus project-level `roles/dns.reader`; verify the
  cert-manager DNS-01 solver still issues certificates.
- [ ] M1c: Drop the `enable-oslogin` metadata entry (fix the comment to describe the
  real auth model), and thread boot-disk size and type through config
  (`bootDiskSizeGb`, `bootDiskType` default `pd-balanced`), pinning the live stack to
  its current type if a VM replacement is not being performed now.
- [ ] M1: Apply via `just infra-up` after a clean `pulumi preview --diff`; run the
  post-apply `gcloud` describe checks; commit.
- [ ] M2a: Generate the offline recovery age key, store the private half in the vault,
  and add its public key (plus the workstation project key for host secrets) to every
  creation rule in both `.sops.yaml` files; delete the dead `nixos/secrets/` rule.
- [ ] M2b: Re-key every encrypted file (`sops updatekeys` for `cluster/secrets/`,
  decrypt-over-SSH + re-encrypt for the host file), and verify decryption with each
  key that should work.
- [ ] M2c: Rewrite the age-key section of `docs/runbooks/disaster-recovery.md` to name
  all three keys (name, path, purpose); commit.
- [ ] M3: Migrate the active cloud context's Pulumi state to the GCS backend with
  `scripts/migrate-pulumi-backend.sh`, verify with `pulumi whoami -v` / stack outputs /
  a clean preview, and update the user docs to recommend GCS for cloud contexts;
  record the backend decision in the Decision Log; commit.
- [ ] Final: update MasterPlan 19's registry/progress for EP-99 and write the Outcomes
  & Retrospective entry here.


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

(Add implementation discoveries here as they occur.)


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

(Record further decisions as work proceeds.)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

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

Secrets use **sops** with **age** keys. sops is a file encryptor that stores ciphertext
plus a metadata block listing the age *recipients* (public keys) that can decrypt; a
`.sops.yaml` policy file (sops searches upward from the file being encrypted and uses
the nearest one) maps path regexes to recipient sets via `creation_rules`. Two policy
files exist:

- Root `.sops.yaml` — rule 1 (lines 11–14) covers `cluster/secrets/*.ya?ml`
  (Kubernetes Secret manifests; only `data`/`stringData` encrypted) with recipient
  `age1pqfv2y3u3y66y5zsr3qd7pnxstatvnlnx39nttzksg8kynn4a5tsq9vcsf` (the "project" /
  workstation key; private half at `~/.config/sops/age/keys.txt`). Rule 2 (lines
  18–20) covers `nixos/secrets/*.ya?ml` — a **dead rule**: that directory does not
  exist; real host secrets live under `nixos/hosts/nagare-01/secrets/`.
- `nixos/.sops.yaml` (lines 1–7) — covers `hosts/nagare-01/secrets/*.yaml` (relative
  to `nixos/`) with the single recipient
  `age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99` (the **host** key;
  private half exists only on the VM at `/var/lib/sops-nix/age-key.txt`, where
  sops-nix reads it during NixOS activation).

Currently exactly two encrypted files exist: `cluster/secrets/notes-db-url.yaml` and
`nixos/hosts/nagare-01/secrets/nagare-01.yaml` (holds the Tailscale auth key). Confirm
the inventory before re-keying with `git grep -l 'ENC\[AES256_GCM'`.

Pulumi **state** (the ledger of which cloud resources Pulumi owns) lives, per target
context, in a local `file://` backend under
`${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/state` by default. EP-93
(`docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md`, Complete) added an
opt-in GCS backend: a context sets `NAGARE_PULUMI_BACKEND=gcs` (URL defaulting to
`gs://<project>-nagare-pulumi-state/nagare/<context>`), and
`scripts/migrate-pulumi-backend.sh` performs the supported `pulumi stack export` /
`stack import` migration, bootstraps the versioned state bucket, verifies stack outputs
match, and only then flips the context file (rollback supported). EP-93 deliberately
deferred the *live* GCS run; M3 performs it. This plan references EP-93 for all backend
mechanics rather than restating them.

Applies run through the repo's normal flow: `just infra-preview` runs
`cd infra/pulumi && pulumi preview` (justfile lines 24–26) and `just infra-up` runs
`cd infra/pulumi && pulumi up` (lines 19–21), with the backend/stack environment already
exported by `.envrc` / `scripts/lib/target.sh` for the active context.

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
disk/bucket, `pulumi state unprotect '<urn>'`; for the VM,
`pulumi -C infra/pulumi config set vmDeletionProtection false && just infra-up` before
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
planned right now, pin the live stack — `pulumi -C infra/pulumi config set bootDiskType
pd-standard` — so preview stays replace-free; the pin is removed at the next deliberate
rebuild (see Idempotence and Recovery), at which point the fresh VM boots on
`pd-balanced`. If it already reports `pd-balanced`, no pin is needed.

Apply gate: run `just infra-preview` (add `--diff` via
`cd infra/pulumi && pulumi preview --diff` for the transcript) and require that no line
begins with `+-` (replace) or `--` (delete) except the single expected delete of
`nagare-iam-dns`. Only then run `just infra-up`. Suggested commits: one for
protection + buckets + snapshots (`feat(infra): protect stateful resources and harden
backup buckets`), one for the IAM scope-down (`feat(infra): scope node SA DNS rights to
the nagare zone`), one for the instance fixes (`fix(infra): drop dead OS Login metadata
and make boot disk config-driven`).

### Milestone 2 — sops: an offline recovery recipient for every secret

Scope: `.sops.yaml`, `nixos/.sops.yaml`, the two encrypted files, and the age-key
section of `docs/runbooks/disaster-recovery.md`. At the end, every encrypted file in
the repo is decryptable by (a) its original consumer key, (b) the operator's
workstation key, and (c) a new offline recovery key whose private half lives only in
the operator's vault; the dead `nixos/secrets/` rule is gone; and the runbook names all
three keys. Acceptance: `sops -d` succeeds on every encrypted file with the workstation
key and with the recovery key; the host still decrypts its file (its recipient stanza
is present, and optionally a `just host-switch` activation proves it live).

First generate the recovery key with `age-keygen` (age is in the dev shell). Record the
public key (a string starting `age1`), store the private half (`AGE-SECRET-KEY-…`) in
the password manager under a clearly-named entry ("nagare sops recovery age key"), and
delete any on-disk copy after M2b's verification. **Never commit the private half; it
must not permanently live on any machine.**

Edit root `.sops.yaml`: fix the header comment (lines 1–7) to stop claiming one key
lives in both places and instead point at the runbook's key table; add the recovery
public key as a second recipient in the `cluster/secrets/` rule's `age:` list (a sops
`age:` value with multiple recipients is a comma-separated string or a YAML list —
use the list form for diffability); and **delete the dead rule** (lines 16–20,
`path_regex: nixos/secrets/…`) after confirming it matches nothing
(`git ls-files 'nixos/secrets/*'` prints nothing). Edit `nixos/.sops.yaml`: add two
recipients alongside the host key — the workstation project key (`age1pqfv…`, so the
operator can edit host secrets locally) and the recovery key — naming each with a YAML
anchor comment as the file already does for `&host_nagare01`.

Re-key the encrypted files. `sops updatekeys` re-wraps the file's data key for the new
recipient set, but it needs to *decrypt* the data key first, i.e. it requires access to
some **existing** recipient's private key:

- `cluster/secrets/notes-db-url.yaml`: the workstation key is an existing recipient
  and `~/.config/sops/age/keys.txt` holds it (confirm with `age-keygen -y
  ~/.config/sops/age/keys.txt`, which must print `age1pqfv…`). Run
  `sops updatekeys -y cluster/secrets/notes-db-url.yaml` from the repo root. The diff
  touches only the sops metadata block (new `age:` recipient stanzas; MAC unchanged).
- `nixos/hosts/nagare-01/secrets/nagare-01.yaml`: the *only* existing recipient is the
  host key, which lives solely on the VM — `updatekeys` on the workstation cannot
  decrypt it. Use the re-encrypt flow: start the VM if stopped, decrypt over IAP SSH
  into a shell variable (plaintext never touches disk), then re-encrypt locally under
  the updated rule (which now lists host + workstation + recovery recipients). The
  exact commands are in Concrete Steps. If the VM lacks a `sops` binary, `nix run
  nixpkgs#sops -- -d …` on the host or `nix shell` works; the fallback is copying the
  encrypted file *to* the VM and running `updatekeys` there against the updated
  `nixos/.sops.yaml`, then copying it back. Whole-file re-encryption changes every
  ciphertext byte — that is expected; only the plaintext must round-trip identically.

Verify per Concrete Steps: decrypt each file with the workstation key; decrypt each
with the recovery key (feed it via `SOPS_AGE_KEY` from the vault copy); statically
confirm the host recipient `age1rc26…` still appears in the host file's metadata; and
(recommended, live) run `just host-switch` so sops-nix re-activates and Tailscale stays
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

Run `scripts/migrate-pulumi-backend.sh` with the active cloud context (it refuses
local-mode contexts, exports the stack to a timestamped rollback artifact under
`…/nagare/<context>/pulumi-migrations/`, bootstraps the bucket with versioning +
uniform access + public-access prevention, imports, verifies `baseDomain` and
`backupBucket` outputs match, and only then flips the context file to
`NAGARE_PULUMI_BACKEND=gcs`). Then verify: `pulumi -C infra/pulumi whoami -v` reports
the `gs://` backend; `pulumi -C infra/pulumi preview` completes with `unchanged`
resources (this also re-proves M1 left no pending diff); `gcloud storage ls` shows the
`.pulumi/stacks/` objects. Rollback, if anything looks wrong, is
`scripts/migrate-pulumi-backend.sh --rollback` (never deletes GCS objects).

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

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/nagare` inside the
dev shell (`direnv allow` or `nix develop`), with the intended cloud context active
(`nagarectl context use <name>` or `NAGARE_CONTEXT=<name>`; the guardrail in
`scripts/lib/target.sh` fail-closes if `gcloud`'s project disagrees).

### M1

Edit the three TypeScript files as described in Plan of Work, then check reality and
preview:

```bash
gcloud compute disks describe nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE" --format='value(type)'
# expected: .../diskTypes/pd-standard  -> pin the live stack:
pulumi -C infra/pulumi config set bootDiskType pd-standard
cd infra/pulumi && pulumi preview --diff; cd -
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
just infra-up
```

Post-apply checks (all should print exactly the noted values):

```bash
gcloud compute instances describe nagare-01 --zone "$CLOUDSDK_COMPUTE_ZONE" \
  --format='value(deletionProtection)'                      # True
gcloud storage buckets describe "gs://$(pulumi -C infra/pulumi stack output backupBucket)" \
  --format='value(versioning.enabled,public_access_prevention)'   # True enforced
gcloud compute disks describe "$(pulumi -C infra/pulumi stack output dataDiskName)" \
  --zone "$CLOUDSDK_COMPUTE_ZONE" --format='value(resourcePolicies)'  # ...-data-snapshots policy URL
gcloud dns managed-zones get-iam-policy "$(pulumi -C infra/pulumi stack output dnsZoneName)" \
  | grep -A2 dns.admin                                      # serviceAccount:nagare-node@... member
kubectl get clusterissuer letsencrypt-dns                   # READY True (cert-manager still authorized)
```

Prove the protection bites (read-only; do not confirm any prompt):

```bash
cd infra/pulumi && pulumi destroy --preview-only 2>&1 | head -20; cd -
# expected: error lines naming the protected disk/bucket URNs:
#   error: Resource "...nagare-data..." cannot be deleted because it is protected.
```

Commit each logical change with explicit paths and the trailers, e.g.:

```bash
git add infra/pulumi/src/components/NagarePerimeter.ts infra/pulumi/index.ts
git commit -m "feat(infra): protect stateful resources and harden backup buckets" \
  -m "MasterPlan: docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md" \
  -m "ExecPlan: docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md"
```

### M2

Generate and stash the recovery key, then edit the two policy files per Plan of Work:

```bash
age-keygen -o /tmp/nagare-recovery.txt      # prints "Public key: age1..."
# Copy the file's contents into the password manager NOW ("nagare sops recovery age key").
git ls-files 'nixos/secrets/*'              # must print nothing (dead rule confirmed)
git grep -l 'ENC\[AES256_GCM'               # inventory: expect exactly the two files below
```

Re-key the cluster secret (workstation key is an existing recipient):

```bash
age-keygen -y ~/.config/sops/age/keys.txt   # must print age1pqfv2y3...
sops updatekeys -y cluster/secrets/notes-db-url.yaml
git diff cluster/secrets/notes-db-url.yaml  # only sops-metadata recipient stanzas change
```

Re-key the host secret via decrypt-over-SSH + local re-encrypt (VM must be running;
tunnel per `scripts/iap-ssh.sh`):

```bash
TUNPID=$(scripts/iap-ssh.sh tunnel nagare-01 22 2222)
PLAINTEXT=$(ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -p 2222 deploy@127.0.0.1 \
  "sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/age-key.txt \
   nix run nixpkgs#sops -- -d /dev/stdin" < nixos/hosts/nagare-01/secrets/nagare-01.yaml)
printf '%s\n' "$PLAINTEXT" | sops --config nixos/.sops.yaml \
  -e --input-type yaml --output-type yaml /dev/stdin > nixos/hosts/nagare-01/secrets/nagare-01.yaml
unset PLAINTEXT; kill "$TUNPID"
```

(If `sops -e` refuses to match a `/dev/stdin` path against the creation rules, write
the plaintext to a file *inside* `nixos/hosts/nagare-01/secrets/` on a tmpfs-free
workflow: `sops -e nagare-01.dec.yaml > nagare-01.yaml` run from that directory, then
`shred -u nagare-01.dec.yaml`. The path just has to match
`hosts/nagare-01/secrets/.*\.yaml$` relative to `nixos/`.)

Verify all decryption paths:

```bash
sops -d cluster/secrets/notes-db-url.yaml > /dev/null && echo cluster-ok       # workstation key
sops -d nixos/hosts/nagare-01/secrets/nagare-01.yaml > /dev/null && echo host-file-ok
SOPS_AGE_KEY="$(cat /tmp/nagare-recovery.txt | grep AGE-SECRET-KEY)" \
  sops -d cluster/secrets/notes-db-url.yaml > /dev/null && echo recovery-ok-1
SOPS_AGE_KEY="$(cat /tmp/nagare-recovery.txt | grep AGE-SECRET-KEY)" \
  sops -d nixos/hosts/nagare-01/secrets/nagare-01.yaml > /dev/null && echo recovery-ok-2
grep -c 'recipient: age1rc26869' nixos/hosts/nagare-01/secrets/nagare-01.yaml   # >= 1 (host still listed)
shred -u /tmp/nagare-recovery.txt            # vault copy is now the only private copy
```

Expected output is the four `…-ok` lines and a count of at least 1. Recommended live
proof: `just host-switch`, then over the tunnel `sudo ls /run/secrets` shows the
rendered secrets (see the memory note about the pre-existing non-zero-exit wrinkle).
Then edit the runbook key section and commit (policy files, both secret files, runbook
— explicit paths, trailers as in M1).

### M3

```bash
scripts/migrate-pulumi-backend.sh                       # active context; add --context NAME to target another
pulumi -C infra/pulumi whoami -v                        # Backend URL: gs://<project>-nagare-pulumi-state/nagare/<ctx>
pulumi -C infra/pulumi stack output backupBucket        # unchanged value
cd infra/pulumi && pulumi preview; cd -                 # "unchanged: N" — no diff on the GCS backend
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
(`SOPS_AGE_KEY=…`), `sops -d` succeeds on **every** file listed by
`git grep -l 'ENC\[AES256_GCM'`. With the workstation key, the same — including the
host file, which was previously workstation-undecryptable. The host file's metadata
still lists the host recipient `age1rc26869…`, and after `just host-switch` sops-nix
renders `/run/secrets` on the VM. Root `.sops.yaml` contains no `nixos/secrets/` rule.

**State is off the laptop.** `pulumi -C infra/pulumi whoami -v` reports the `gs://`
backend for the active cloud context, `pulumi preview` against it reports all resources
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
documented deliberate-rebuild procedure is: unprotect the VM path via
`pulumi -C infra/pulumi config set vmDeletionProtection false && just infra-up`
(in-place update), remove the `bootDiskType` pin if present
(`pulumi -C infra/pulumi config rm bootDiskType`) so the rebuilt VM gets `pd-balanced`,
perform the image-driven replacement, then set `vmDeletionProtection` back to `true`.
Disk/bucket protection should be re-asserted (it is, by the code) on the next `up`
after any manual unprotect. The snapshot policy and attachment are idempotent creates;
deleting them never touches the disk. If the M1 preview ever shows a replace, the
recovery is simply "do not apply" — fix the pin or the edit and re-preview.

M2 is safe to repeat: `sops updatekeys -y` is a no-op when recipients already match,
and the re-encrypt flow can be re-run from the same SSH decrypt at any time (the
working tree change is only committed after verification). The risky asset is the
plaintext of `nagare-01.yaml`: keep it in a shell variable or a `shred`-ed temp file,
never in the repo or scratch dirs, and never commit the recovery private key. Rollback
before commit is `git checkout -- <file>`; after commit, the old ciphertext remains in
Git history and the host key still decrypts both old and new versions, so nothing can
be lost by re-keying — the failure mode to guard is *forgetting a recipient*, which the
per-key `sops -d` verification catches before commit. If the SSH decrypt path is
unavailable (VM down), stop M2b and record it in Progress; do not improvise by moving
the host private key off the VM.

M3 inherits EP-93's safety design: the migration script exports a timestamped rollback
artifact before touching anything, verifies outputs before flipping the context file,
is a no-op when the context is already on GCS, and
`scripts/migrate-pulumi-backend.sh --rollback` restores the local backend without
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
  `gcp.dns.ManagedZoneIamMember` (`…-iam-dns-zone`), `gcp.projects.IAMMember`
  (`…-iam-dns-read`); removed resource `…-iam-dns` (project-wide `dns.admin`). Resource
  options `protect: true` on the data disk and backup bucket. Do not rename any of the
  nine exported stack outputs in `index.ts` (they are MasterPlan integration
  contracts).
- `infra/pulumi/src/components/NagareInstance.ts` — `NagareInstanceArgs` gains
  `deletionProtection: pulumi.Input<boolean>; bootDiskSizeGb: number;
  bootDiskType: string;`; the instance sets `deletionProtection` and the explicit boot
  disk `size`/`type`; the `metadata` block is removed.

Secrets tooling: `sops` and `age` from the dev shell. Policy interfaces at the end of
M2: root `.sops.yaml` has exactly one creation rule (`cluster/secrets/`, recipients =
workstation key + recovery key, `encrypted_regex` unchanged); `nixos/.sops.yaml` has
one rule (`hosts/nagare-01/secrets/`, recipients = host key + workstation key +
recovery key). Consumers unchanged: sops-nix on the host reads
`/var/lib/sops-nix/age-key.txt`; the runbook step "Restore secrets" keeps working
byte-for-byte.

State tooling: `pulumi`, `gcloud storage`, and the shipped EP-93 machinery —
`scripts/migrate-pulumi-backend.sh` and the context fields
`NAGARE_PULUMI_BACKEND`/`NAGARE_PULUMI_BACKEND_URL` consumed by `scripts/lib/target.sh`
and `nagarectl` (see `docs/plans/93-remote-gcs-pulumi-backends-for-target-contexts.md`
for the full contract). This plan adds no interface there.

Plan dependencies: none hard. Soft boundaries — EP-97 owns `scripts/lib/target.sh` /
justfile guardrail logic (this plan touches neither); EP-103 owns
`docs/runbooks/disaster-recovery.md` except the age-key section edited by M2c (if both
plans are in flight, coordinate that file's merge by section). EP-93 is Complete and is
consumed, not modified.


## Revision Notes

- 2026-07-15 — Initial authoring: rewrote the skeleton into a full ExecPlan from the
  verified platform-review findings (deletion protection, backup-bucket hardening,
  disk snapshots, sops root-of-trust recovery recipients, DNS IAM scope-down, OS Login
  metadata contradiction, boot-disk config, GCS Pulumi backend). All file/line
  references were verified against the working tree on this date; the boot-disk-type
  replacement hazard, the `updatekeys`-needs-an-existing-key constraint, and the
  EP-93 opt-in decision drove the corresponding Decision Log entries. Planning only;
  no source or config was modified.
