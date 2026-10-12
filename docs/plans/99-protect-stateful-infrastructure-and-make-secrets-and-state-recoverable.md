---
id: 99
slug: protect-stateful-infrastructure-and-make-secrets-and-state-recoverable
title: "Protect stateful infrastructure and make secrets and state recoverable"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T13:31:15Z
      mode: "update"
      note: "Reconcile deferred validation against tan-ng-labs and later plan evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-16T17:57:59Z
      mode: "implement"
      note: "Verify labs secret inventory and workstation access; correct recovery procedure and record vault blocker"
---

# Protect stateful infrastructure and make secrets and state recoverable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/99-protect-stateful-infrastructure-and-make-secrets-and-state-recoverable.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
  installation's ciphertext must be recovered from its private operator repository.
  The original host file had only a host recipient. The active `labs` context now
  has host and workstation recipients, but no independently vaulted recovery
  recipient has been verified. Losing both identities would still lose the secrets.
  The public checkout's `example.yaml` is an evaluation fixture with a discarded
  private key, not an operational secret or a recovery source (ADR 13).
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

**Status summary (completed 2026-09-16): infrastructure protections and remote state
have live acceptance evidence. The selected labs context now has a separate,
operator-vaulted recovery identity on every operational ciphertext document, proven
independent decryption with unchanged values, and a committed guarded host activation.
The temporary recovery private key has been removed. Other clusters require explicit
enrollment; public examples remain excluded. Both private recovery repositories
have been published and their remote commit heads verified.**

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
- [x] M1 live GCP acceptance (reconciled 2026-09-15): the fresh `tan-ng-labs` rollout
  reviewed and applied the released Pulumi program, and a new read-only audit reported
  `31 unchanged`. The instance is RUNNING with `deletionProtection: true`, no metadata
  block, and a `pd-balanced` data disk attached to daily snapshot policy
  `nagare-data-snapshots-63547e1`; the backup bucket has versioning, enforced public-access
  prevention, uniform access, and the 30-day noncurrent lifecycle; the zone grants only
  `roles/dns.admin` to the node identity while the project grants it `roles/dns.reader`;
  ClusterIssuer `letsencrypt-dns` is Ready for project `tan-ng-labs`.
- [x] M2a (partial — the half that needs no key material): delete the dead
  `nixos/secrets/` creation rule and correct the root `.sops.yaml` header comment,
  which wrongly claimed one private key lives in both key locations. (2026-08-05,
  commit `4148e68`; verified by a `sops -e`/`sops -d` round-trip of a scratch file
  under `cluster/secrets/`)
- [x] M2a generation and custody (2026-09-16): generated a distinct recovery identity
  at the operator's request, with staging-directory mode 0700 and key-file mode 0600.
  The operator confirmed saving the complete file in their password manager.
  Custody evidence is that confirmation; no automated vault readback is claimed.
- [x] M2a policies (2026-09-16): added the recovery recipient to the applicable
  private labs rules in both operator repositories, retaining all original consumer
  and workstation recipients. No public policy or other context was changed.
- [x] M2b ciphertext (2026-09-16): re-keyed the versioned and operational XDG host
  file plus both documents in the context-owned nix-cache file. Recovery-only and
  workstation-only decryption reproduce the original plaintext for every file;
  host-only decryption also passes for the host file. Empty-identity decryption
  fails. The versioned and operational host copies match byte for byte.
- [x] M2b live acceptance (2026-09-16 18:13 UTC): the 0.4.0 packaged guarded
  host switch reported ACTIVATE_RC=0, verified fresh SSH login and sudo, and
  COMMITTED. Sops-nix reports success; the Tailscale auth secret is rendered mode
  0400 root:root. k3s and Tailscale are active, boot and active systems match, and
  the rollback timer is inactive. Removed the temporary recovery private file
  and empty staging directory after final isolated decryption checks.
- [x] M2c (2026-09-16): updated the runbook's key section and both private README
  inventories. Distilled explicit recovery enrollment, private policy ownership,
  independent decryption, and manual custody evidence into ADR 13.

- [x] M2 preflight (2026-09-16): selected context is `labs`; both the generated
  host `secrets.yaml` and context-owned `nix-cache.yaml` decrypt with the explicitly
  selected workstation key, with plaintext discarded. The host has host plus
  workstation recipients; nix-cache has only the workstation recipient. The
  1Password CLI reports no configured accounts, so recovery-key custody/access
  still needs operator input. No key or ciphertext was changed.
- [x] M3 live state migration (reconciled 2026-09-15 from EP-116): the active
  `tan-nb-exp` context's 32-resource stack was exported and imported into
  `gs://tan-nb-exp-nagare-pulumi-state/nagare/tan-nb-exp`; outputs matched, the bucket is
  versioned with public-access prevention and uniform access, the context flipped through
  its private-repository symlink, and `pulumi preview --refresh` reported 31 unchanged.
- [x] Re-audit the live-environment blocker before yielding EP-3: the Nagare context
  directory is still absent, the active gcloud configuration still names
  `tan-nb-exp`/`us-west1-a`, and explicit read-only instance, disk, and bucket queries
  still fail because gcloud requires interactive reauthentication. (2026-08-24)
- [x] Packaging reconciliation: make encrypted cluster secrets context-owned and
  excluded from released payloads/workspaces; update this plan to use the packaged
  `nagare` launcher, workspace-resolved Pulumi/migration paths, and the generated host
  flake as the operational recovery target. The asset and clone-free package checks
  pass with the new secret boundary. (2026-08-26)
- [x] Final documentation (2026-09-16): completed the retrospective and distilled
  recovery decisions into ADR 13.
- [x] Final publication (2026-09-16): the operator explicitly approved publishing
  both private repositories, including the cache repository's two pre-existing
  commits. Pushed and verified remote master equals local HEAD at
  `mori://shinzui/nagare-ops` (commit `f70d7625acae4b7af4047faf94eec33210c3f0ed`)
  and `mori://tan/tan-ng-labs` (commit `0a57197b833e38ff4ef4ed66e557fef6eb9a5a6d`).
  The unrelated uncommitted Pulumi config edit was preserved. EP-3 is Complete.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

**Live recovery enrollment completed (2026-09-16).** The original PATH resolved
Nagare 0.2.2, whose host-switch script derives the SSH host from the GCE instance
name. Labs uses GCE instance `nagare-01` but OS/Tailscale name `labs-nagare`. Built
the repository's 0.4.0 operator package, verified `nagarectl host name`, and used
that immutable build's guarded recipe with the existing context-owned host flake.
The switch rebuilt only the secrets manifest, service wiring, and system closure;
it did not regenerate the host flake or change its pinned platform input.

```text
host: workstation-only, recovery-only, host-only decryption PASS
nix-cache: workstation-only, recovery-only decryption PASS
Every decrypted document equals its pre-change plaintext
No-key decryption refused; recovery recipient present in all three YAML documents
ACTIVATE_RC=0
host-switch: fresh login and sudo verified (attempt 1)
COMMITTED
sops-install-secrets: Result=success ExecMainStatus=0
k3s: active; tailscaled: active
Rendered Tailscale secret: 400 root:root
Active and boot system match; rollback timer inactive
Temporary recovery identity removed
```

The original labs-host file provided by the operator was a consumer identity,
not the new recovery identity. Manual confirmation of saving the complete new
identity supplied the custody evidence. The cryptographic checks used the staged
copy with an empty environment except PATH and the single chosen key-file variable;
they did not retrieve a key through 1Password. Existing workstation and host keys
were retained. The private cluster-secret repository already had two unpublished
commits; its remote was not updated incidentally.

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

**Live infrastructure became available through labs (2026-09-15).** The clean second target at
`mori://tan/tan-ng-labs` was provisioned from Nagare v0.2.2 after this plan's Pulumi changes. Its
operator plan is `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.
Read-only GCP, Kubernetes, and Pulumi checks matched every M1 observable and showed 31 unchanged.
This removes the old infrastructure blocker without claiming the still-unperformed recovery-key
work. EP-116 independently provides the exact live local-to-GCS export/import evidence required by
M3.

(Add further implementation discoveries here as they occur.)

**The resumed secret inventory differs from the old plan (2026-09-16).**
`nagarectl context current` returns `labs`. Its generated host file is in the regular
XDG host directory, with host recipient `age174qfjlcm6dw3nwr5pcdwzgmv23a98239kmawfj5udxredhy8he0stxsa7z`
and the existing workstation recipient. The cluster-secret directory resolves to
`mori://shinzui/nagare-ops` at project-relative path `cluster-secrets/labs/`, containing
`nix-cache.yaml`; artifact-level URI coverage is pending. The matching cluster policy
is that project's `.sops.yaml`. The labs host policy and a versioned host copy exist
in `mori://tan/tan-ng-labs` at project-relative paths `.sops.yaml` and
`hosts/labs/secrets.yaml` (artifact-level URIs pending). Re-keying that repository
copy alone would miss the current regular XDG host file. Inventory both and preserve
any differences before synchronizing encrypted copies.

The following checks printed no secret values:

```text
labs host: workstation decrypt PASS
labs nix-cache: workstation decrypt PASS
op account list --format json: []
```

ADR 13 removed the historical operator ciphertext from the public checkout. A raw
`git grep` for `ENC[AES256_GCM` now finds test strings, documentation, and the
deliberately undecryptable `nixos/hosts/nagare-01/secrets/example.yaml`. Those matches
must not become recovery-key targets. The old fixed host-recipient assertion would
also reject the valid labs host identity.

## Decision Log

Record every decision made while working on the plan.

- Decision: accept the operator's explicit confirmation of complete-file vault
  storage as manual custody evidence, verify the generated recovery identity in
  isolation, and remove the staging file after successful live activation.
  Rationale: the operator performed the password-manager handoff manually. Requiring
  CLI account setup would not improve the already authorized re-key operation;
  evidence distinguishes human custody from automated vault retrieval instead.
  Date: 2026-09-16
- Decision: enroll only the selected labs context and preserve its existing consumer
  recipients, all other contexts, and the public fixture policy.
  Rationale: the operator accepted labs as the initial coverage scope. A shared vault
  item does not confer coverage on unenrolled ciphertext. ADR 13 preserves this rule.
  Date: 2026-09-16

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

- Decision: accept the fresh labs deployment for M1 and EP-116's original-context migration for M3.
  Rationale: M1's acceptance is the behavior of released Pulumi resources, which labs exercised
  from an empty project and exposes directly through authoritative GCP/Kubernetes APIs. M3 names the
  active `tan-nb-exp` state, and EP-116 performed that exact export/import with output and refresh
  verification. Neither evidence substitutes for M2's human custody and re-key requirements.
  Date: 2026-09-15

(Record further decisions as work proceeds.)

- Decision: apply ADR 13's existing private-operator boundary to all remaining M2
  steps, discover each host recipient from the selected context, and require a
  vaulted recovery identity before changing recipients.
  Rationale: the public example has no recoverable private key, labs already has
  workstation access, and its effective host and cluster files have different
  ownership paths. No new architecture decision is introduced. The missing vault
  account/access cannot be replaced by generating an unvaulted identity.
  Date: 2026-09-16

## Outcomes & Retrospective

Completed on 2026-09-16 for the selected labs context, including private backup
publication and verification. Infrastructure acceptance
remains backed by the labs deployment's deletion protections, disk snapshot schedule,
versioned backup storage, and scoped DNS permissions. EP-116 provides the original
context's verified local-to-GCS state migration.

The operator confirmed vault storage of the separate recovery identity. Only its
public recipient and vault reference entered the private operator repositories.
Every document in the current inventory accepts that identity: one host-secret
document in versioned and operational copies, and two nix-cache documents. Independent
recovery/workstation decryption and host-only decryption where applicable returned
unchanged plaintext; an empty identity set failed. Verification used the generated
staging identity after operator-confirmed custody, not an automated vault retrieval.
The temporary private file and directory were then removed. Ciphertext rollback
copies remain at `/tmp/nagare-ep99-rekey.pB3Ebd`.

The guarded host switch completed at 18:13 UTC, verified fresh SSH and sudo, and
committed the new boot default. Sops-nix rendered the expected secret; k3s and
Tailscale remained healthy. Existing identities and secret values were preserved.
No Kubernetes Secret apply was needed for recipient-only changes. The runbook and
ADR 13 now distinguish the three roles and explicit per-context enrollment. Other
contexts, including tan-nb-exp, were not enrolled.

The main lessons are that a host-key backup is not an independent recovery identity,
every YAML document needs recovery coverage, and regular XDG host copies can drift
from Git even when cluster secrets use symlinks. The public discarded-key fixture
is excluded. The full disaster-recovery drill remains a separate MasterPlan follow-up.

The operator explicitly approved private backup publication, including the two
pre-existing cache-repository commits. Both pushes succeeded, and independent
`git ls-remote` checks matched the local commit heads: `f70d7625acae4b7af4047faf94eec33210c3f0ed`
in `mori://shinzui/nagare-ops` and `0a57197b833e38ff4ef4ed66e557fef6eb9a5a6d`
in `mori://tan/tan-ng-labs`. Their remote histories now contain the verified recovery
envelopes. The unrelated uncommitted Pulumi change was neither staged nor published.
