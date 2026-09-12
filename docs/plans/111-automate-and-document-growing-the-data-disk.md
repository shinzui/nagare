---
id: 111
slug: automate-and-document-growing-the-data-disk
title: "Automate and document growing the data disk"
kind: exec-plan
created_at: 2026-09-12T13:02:02Z
intention: "intention_01m2av9m0ge8sbwjy4arw5svf9"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T13:02:02Z
---

# Automate and document growing the data disk

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare runs on one Compute Engine virtual machine with two disks. The **boot disk** holds
the operating system and the k3s cluster state. The **data disk** is a separate Google
Persistent Disk mounted at `/var/lib/nagare`, and it holds everything an operator cannot
afford to lose: every application's persistent volume, the VictoriaMetrics, VictoriaLogs and
VictoriaTraces stores, managed Postgres and SQLite data, and local backups.

Today, if that disk fills up, an operator is stuck. An alert fires telling them to "grow the
disk", but nothing in this repository can actually grow it. Increasing the configured disk
size makes the *block device* bigger while the *filesystem* written on it stays exactly the
size it was, so the new space is invisible. There is no command in the repository that
resizes the filesystem, and the documentation devotes a single sentence to the topic
(`docs/user/resizing-the-vm.md:173-174`) naming no commands at all. The one moment an
operator most needs a reliable answer — a full disk on a running cluster — is the moment
they discover they have to improvise on a live box.

After this change, an operator who needs more space edits one number, applies it, and the
filesystem grows itself. Concretely, this is what becomes true and how it is seen:

Set a larger size and apply it:

```bash
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 110 --stack "$(nagarectl context current)"
just infra-up
```

Then, on the host, the extra space is already usable — automatically after the next boot, or
immediately with one documented command. `df -h /var/lib/nagare` reports the new size:

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb        108G   12G   91G  12% /var/lib/nagare
```

That is the whole user-visible outcome: **the number an operator sets is the space they
get**, with no hand-run filesystem surgery on a live box. Alongside it, this plan replaces
guesswork with recorded evidence — an automated test that proves the online grow actually
works, a recorded Pulumi plan proving that increasing the size updates the disk in place
instead of destroying and recreating it, and a recorded plan proving that *decreasing* it
fails safely rather than eating the data. The documentation then states only what that
evidence supports.

This plan implements improvement request IR-5,
[`docs/improvement-requests/data-disk-grow-procedure.md`](../improvement-requests/data-disk-grow-procedure.md).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — the data disk grows itself:

- [ ] Add `autoResize = true` to the `/var/lib/nagare` entry in `nixos/hosts/nagare-01/storage.nix`, with a comment explaining what NixOS does with it.
- [ ] Add a `data-disk-auto-grow` evaluation check to `nixos/flake.nix` asserting the mount carries `x-systemd.growfs`, and that the boot disk's existing auto-grow is still in place.
- [ ] Run the check and record its output.
- [ ] Move IR-5 from `accepted` to `in-progress` (its `targetPlan` already names this plan), then revalidate the improvement-request bundle.
- [ ] Commit.

Milestone 2 — prove the online grow without touching GCP:

- [ ] Add a `data-disk-online-grow` NixOS virtual-machine test to `nixos/flake.nix` that imports the real `storage.nix`, puts a deliberately undersized ext4 filesystem on an oversized disk, and proves the filesystem reaches the device size.
- [ ] Prove the reboot path (grow happens by itself on the next boot).
- [ ] Prove the no-reboot path (`systemctl start systemd-growfs@var-lib-nagare.service` grows it on a running machine).
- [ ] Record the test transcript in Surprises & Discoveries or here.
- [ ] Commit.

Milestone 3 — prove what the cloud plan actually does:

- [ ] Record the current `nagare:dataDiskSizeGb` and `nagare:bootDiskSizeGb` values before touching anything.
- [ ] Preview an *increase* of `dataDiskSizeGb` and record the verbatim plan; confirm it is an in-place update and not a replacement.
- [ ] Preview a *decrease* of `dataDiskSizeGb` and record verbatim what Pulumi says; confirm it fails closed and never silently destroys the disk.
- [ ] Preview an *increase* of `bootDiskSizeGb` and record whether it updates in place or forces instance replacement.
- [ ] Restore both config values to what they were, and verify a preview is clean.
- [ ] Commit the recorded evidence into this plan.

Milestone 4 — prove it end to end on the live host:

- [ ] Confirm the operator explicitly consents to a permanent disk-size increase (a grow cannot be undone).
- [ ] Roll the new host configuration out with `just host-switch`.
- [ ] Capture `df -h /var/lib/nagare` before the grow.
- [ ] Apply the size increase with `just infra-up`.
- [ ] Capture `df -h /var/lib/nagare` after the apply but before any grow command, to show the gap this plan closes.
- [ ] Grow the filesystem on the running host and capture `df -h` again.
- [ ] Confirm the cluster is healthy afterwards.
- [ ] Commit the recorded evidence into this plan.

Milestone 5 — make the documentation and the alert tell the truth:

- [ ] Write the "Growing the data disk" section in `docs/user/resizing-the-vm.md`, replacing the one-sentence bullet.
- [ ] State plainly that shrinking is impossible and what happens if it is attempted.
- [ ] Fix the hard-coded `tan-nb-exp` instruction at `docs/user/resizing-the-vm.md:95`, which contradicts the context model.
- [ ] Fill in the `nagare:dataDiskSizeGb` notes in `docs/user/reference.md` and `docs/user/provisioning-with-pulumi.md`, and correct the boot-disk claim to match Milestone 3's evidence.
- [ ] Point `docs/user/persistent-storage.md` at the new procedure.
- [ ] Give the `DiskUsageHigh` alert in `cluster/observability/vmrules/nagare-alerts.yaml` a remediation pointer and a stated first response.
- [ ] Run `just docs-validate` and fix whatever it reports.
- [ ] Close IR-5 as `completed` with `completedAt` and a `resolution`, log it, and revalidate.
- [ ] Fill in Outcomes & Retrospective and run the ADR distillation pass.
- [ ] Commit.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Automate the grow with the standard NixOS `fileSystems.<mount>.autoResize`
  option rather than writing a bespoke `resize2fs` systemd service.
  Rationale: IR-5 offers automation or documentation as alternatives and prefers automation.
  Evaluating the pinned host configuration with `autoResize = true` added showed it produces
  exactly the wanted behavior with no failing assertions and no custom code — NixOS
  translates it into the `x-systemd.growfs` mount option, and systemd grows the ext4
  filesystem online right after mounting. The evidence is quoted in Context and Orientation.
  A hand-rolled unit would duplicate a standard mechanism, and the standard one additionally
  gives operators a supported manual command for the current boot
  (`systemctl start systemd-growfs@var-lib-nagare.service`) instead of raw `resize2fs`.
  Date: 2026-09-12

- Decision: Do the automation *and* the documentation, not one or the other.
  Rationale: IR-5 presents documentation as the fallback if automation is rejected, but the
  two are not substitutes here. Automation only takes effect once the host has been rebuilt
  and remounted, so an operator growing a disk on a running box still needs a written
  command for the current boot. The alert also needs somewhere to point regardless.
  Date: 2026-09-12

- Decision: Prove the online grow with a NixOS virtual-machine test rather than only an
  evaluation-level assertion.
  Rationale: An evaluation check proves the option is *set*; it cannot prove the filesystem
  actually grows. IR-5 explicitly requires "evidence from a live or local run that the
  filesystem reflects the new size afterwards". A virtual-machine test gives that evidence
  reproducibly, on every run, without touching a real cluster or spending money.
  Date: 2026-09-12

- Decision: Record what the Pulumi plan does rather than asserting it from the provider's
  reputation.
  Rationale: IR-5 states that a size decrease forces disk replacement and that `protect: true`
  turns that into a failed plan. The `@pulumi/gcp` provider source is not in the local Mori
  corpus, so that behavior is currently an unverified claim. This plan verifies it against a
  real stack and writes down the verbatim output. The existing documentation already asserts
  unverified behavior; adding a second unverified assertion would repeat the mistake IR-5
  raises.
  Date: 2026-09-12

- Decision: Run the live end-to-end proof against the real cluster with a small increase
  (for example 100 GiB to 110 GiB) rather than a scratch context.
  Rationale: IR-5's acceptance is about the operator's actual box, and a scratch context
  would not exercise the running k3s workloads that hold the mount open. The cost is roughly
  a dollar a month on `pd-balanced`. The increase is permanent, because shrinking is exactly
  the operation this plan proves to be impossible — so Milestone 4 begins with explicit
  operator consent, and an operator who prefers not to spend that may substitute a scratch
  context and record that substitution here.
  Date: 2026-09-12

- Decision: Make this a standalone ExecPlan rather than a child of MasterPlan 19.
  Rationale: MasterPlan 19
  (`docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md`)
  decomposes a July 2026 five-track review and is still in progress against that scope. IR-5
  comes from a separate September 2026 pre-flight review of the `v0.1.0` release. The work is
  narrow — one NixOS option, two checks, one rehearsal, and documentation — and does not need
  a MasterPlan's coordination machinery.
  Date: 2026-09-12

- Decision: Treat the boot disk's behavior as a documentation-accuracy task, not an
  implementation task.
  Rationale: IR-5 asks for the boot disk to get "the same treatment". Evaluating the pinned
  configuration shows the boot disk *already* auto-grows: its root filesystem has
  `autoResize = true`, carries `x-systemd.growfs`, and `boot.growPartition` is true with a
  `growpart.service` present. What is genuinely missing is evidence about the *cloud* side —
  whether raising `bootDiskSizeGb` updates the instance in place or replaces it — so
  Milestone 3 records that, and Milestone 5 corrects the documentation to match.
  Date: 2026-09-12

- Decision: Move IR-5 to `accepted` with a `targetPlan` when the plan was created, rather than
  straight to `in-progress`.
  Rationale: The profile's enum distinguishes a request that has been agreed and planned from
  one whose implementation has started, and no milestone of this plan has been executed yet.
  `accepted` is the truthful state, and it matches how the sibling request IR-4 was recorded
  against ExecPlan 110. Milestone 1 moves it to `in-progress` when work actually begins.
  Date: 2026-09-12

- Decision: Correct two factual claims in IR-5 rather than implementing them as written.
  Rationale: IR-5 says twice that the disk-pressure alert "links to this section as
  remediation" and that its "remediation text points the operator at the procedure". It does
  not. `cluster/observability/vmrules/nagare-alerts.yaml:26` reads only "Free space or grow
  the disk." and contains no link anywhere in the file. The gap is therefore slightly worse
  than IR-5 describes — there is neither a link nor a procedure — and the requested change
  becomes *adding* a remediation pointer rather than repointing an existing one.
  Date: 2026-09-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it in full before editing
anything.

### The shape of a Nagare installation

Nagare is a single-node personal platform-as-a-service. It runs on exactly one Google Compute
Engine virtual machine, named `nagare-01` by default. "Single-node" means there is no second
machine to move work onto: scaling is vertical (a bigger machine), and a failure of the one
box is an outage by design.

The machine's software is defined with **NixOS**, a Linux distribution whose entire system
configuration is written as code in the `.nix` language and built reproducibly. You do not
log in and install packages; you edit `.nix` files and rebuild. The cloud resources around the
machine — the disks, the network, the static IP address — are defined with **Pulumi**, an
infrastructure-as-code tool whose programs here are written in TypeScript under
`infra/pulumi/`.

Two terms recur below:

A **block device** is the raw storage the cloud gives you, such as a 100-gigabyte disk. A
**filesystem** is the structure written onto that device that lets it hold files (here,
`ext4`, the standard Linux filesystem). These are independent: making the device bigger does
not make the filesystem on it bigger. That independence is the entire subject of this plan.

A **systemd unit** is a named background job or resource managed by `systemd`, the Linux
service manager. Units ending in `.service` are jobs; units ending in `.mount` represent a
mounted filesystem. You will see unit names like `var-lib-nagare.mount`, which is systemd's
escaped spelling of the mount at `/var/lib/nagare`.

### Which target this plan acts on

This repository can target different Google Cloud projects. The target is a named **context**
— a file of `export VAR=value` lines under `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/`
— selected with `nagarectl --context NAME`, the `NAGARE_CONTEXT` environment variable, or
`nagarectl context use NAME`. Every cloud command in this plan acts on the **active context's**
project and nothing else. The guardrail that enforces this lives in `scripts/lib/target.sh`
and is fail-closed: scripts call `_require_target_project`, which refuses to run unless
gcloud's active project matches the context's project. Do not edit a tracked file to change
targets; select a different context. Print the active one with:

```bash
nagarectl context current
```

A context may also be a **local** context (`mode=local`), which points every primitive at
loopback substitutes — a k3d cluster in Docker, a local registry, MinIO instead of Google
Cloud Storage. **Local mode has no data disk at all**, so Milestones 3 and 4 of this plan do
not apply to it, and nothing in this plan should make `just local-smoke` behave differently.

### The data disk as it exists today

`infra/pulumi/src/components/NagarePerimeter.ts:69-73` creates the disk:

```typescript
const dataDisk = new gcp.compute.Disk(`${name}-data`, {
    zone: args.zone,
    type: "pd-balanced",
    size: args.dataDiskSizeGb,
}, { parent: this, protect: true });
```

`protect: true` is a Pulumi *state* option, not a cloud API call: it makes Pulumi refuse any
plan that would delete this resource. Because replacing a resource means deleting and
recreating it, protection also blocks replacement. It is deliberately reversible with
`pulumi state unprotect '<urn>'`, but the next `pulumi up` re-asserts it because it is
declared in code.

The size comes from configuration at `infra/pulumi/index.ts:20`:

```typescript
const dataDiskSizeGbCfg = cfg.getNumber("dataDiskSizeGb") ?? 100;
```

`infra/pulumi/src/components/NagareInstance.ts:64-68` attaches the disk to the virtual machine
with the stable device name `nagare-data`, which is why the host can always find it at
`/dev/disk/by-id/google-nagare-data`.

On the host, `nixos/hosts/nagare-01/storage.nix` does three things. A oneshot service
`format-nagare-data` (lines 17-40) writes an `ext4` filesystem onto the disk if and only if
the disk has none yet, so a brand-new blank disk becomes mountable on first boot without
ever touching an existing filesystem. Lines 42-48 declare the mount:

```nix
  fileSystems."/var/lib/nagare" = {
    device = dataDiskDevice;
    fsType = "ext4";
    options = [ "defaults" "nofail" ];
  };
```

And a second oneshot, `nagare-data-layout` (lines 57-77), creates the subdirectories
(`victoria-metrics`, `victoria-logs`, `victoria-traces`, `postgres`, `sqlite`, `backups`,
`local-path`) *after* the mount, so they land on the data disk rather than being hidden
underneath it.

Note carefully: `format-nagare-data` runs `mkfs.ext4` directly against the whole block device.
There is **no partition table** on the data disk. This matters later — growing it needs only a
filesystem grow, never a partition grow.

`storage.nix` is not per-operator configuration. It is imported by the shared module
`nixos/modules/nagare-host.nix:9-17`, which every operator's host uses, so a change here is a
change to the platform that all installations receive. Per-operator values (host name, SSH
keys, registry host) live elsewhere, in a generated flake produced by `nagarectl host init`.

### The gap, demonstrated

Evaluating the pinned host configuration shows the data disk has no auto-grow while the boot
disk has one. Run this from `nixos/` to see it for yourself:

```bash
nix eval --json --impure --expr '
  let cfg = (builtins.getFlake (toString ./.)).nixosConfigurations.nagare-01.config;
  in {
    dataAutoResize = cfg.fileSystems."/var/lib/nagare".autoResize;
    dataOptions    = cfg.fileSystems."/var/lib/nagare".options;
    rootAutoResize = cfg.fileSystems."/".autoResize;
    rootOptions    = cfg.fileSystems."/".options;
    growPartition  = cfg.boot.growPartition;
  }'
```

Recorded output on 2026-09-12, at commit `c87544c`:

```json
{"dataAutoResize":false,"dataOptions":["defaults","nofail"],"growPartition":true,"rootAutoResize":true,"rootOptions":["x-systemd.growfs","x-initrd.mount"]}
```

The boot disk grows both its partition (`boot.growPartition`, set by the upstream
`google-compute-image.nix` module that `nixos/flake.nix:31` imports) and its filesystem
(`x-systemd.growfs`). The data disk does neither. This is the asymmetry IR-5 describes, and it
is why an operator who has grown a boot disk without incident will reasonably but wrongly
assume the data disk behaves the same way.

### The fix, already validated by evaluation

Evaluating the same configuration with `autoResize = true` added to the data-disk entry gives:

```json
{"failingAssertions":[],"growUnits":["growpart.service"],"mountOptions":["x-systemd.growfs","defaults","nofail"],"systemdInitrd":true}
```

No assertion fails, and NixOS adds the `x-systemd.growfs` mount option. That option is
understood by systemd's fstab generator: when the filesystem is mounted, systemd runs
`systemd-growfs@var-lib-nagare.service`, which grows the filesystem to fill the underlying
block device. For `ext4` this happens **online**, on a mounted filesystem, with no unmount and
no downtime. Because the data disk has no partition table, no `growpart` step is needed.

### The alert that has nowhere to point

`cluster/observability/vmrules/nagare-alerts.yaml:16-26` defines the alert that fires when
either filesystem passes 80% for fifteen minutes:

```yaml
        - alert: DiskUsageHigh
          expr: |
            (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|iso9660", mountpoint=~"/|/var/lib/nagare"}
               / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|iso9660", mountpoint=~"/|/var/lib/nagare"}) * 100
              > 80
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: 'Disk {{ $labels.mountpoint }} is {{ $value | printf "%.0f" }}% full'
            description: 'Filesystem {{ $labels.mountpoint }} has been above 80% for 15m. Free space or grow the disk.'
```

There is no link and no runbook reference anywhere in that file. IR-5 states that the alert
links to the resizing document; it does not. Milestone 5 adds the pointer.

One fact shapes the advice that pointer should give. The observability stores are already
capped so they cannot be the runaway consumer: `cluster/observability/victoria-logs/values.yaml`
sets `retentionPeriod: 7d` and `retentionDiskSpaceUsage: 15GiB`,
`cluster/observability/victoria-traces/values.yaml` sets `retentionPeriod: 3d` and
`retentionDiskSpaceUsage: 8GiB`, and `cluster/observability/victoria-metrics/values.yaml`
sets `retentionPeriod: "30d"`. So when this alert fires, the growth is coming from application
persistent volumes, managed database data, or local backups — which is why the remediation
should tell the operator to *identify the consumer first* rather than reflexively grow.

### What the documentation currently says

`docs/user/resizing-the-vm.md` is the runbook for making the machine bigger. Its final bullet,
lines 173-174, is the entirety of the data-disk story:

```text
- **Resizing the disks.** Growing `/var/lib/nagare` is a `dataDiskSizeGb` change
  plus an online filesystem grow — a separate operation from the machine type.
```

Two reference tables carry disk configuration keys: `docs/user/reference.md:203-204` and
`docs/user/provisioning-with-pulumi.md:81-82`. Both leave the `nagare:dataDiskSizeGb` notes
cell empty, and both assert of the boot disk that "Increasing is supported; shrinking is not"
without evidence.

Separately, `docs/user/resizing-the-vm.md:95` still instructs the reader to "Confirm you're
targeting `tan-nb-exp`". That contradicts the context model described above, under which
`tan-nb-exp` is only a default example. Because the new procedure lands in the same file and
would otherwise sit next to a contradicting instruction, Milestone 5 corrects it.

### Architecture Decision Records consulted

`docs/adr/` in this repository is a **plain filesystem convention**, not an OKF bundle:
`mori.dhall` registers `docs/capabilities`, `docs/improvement-requests`, `docs/reviews`,
`docs/use-cases`, `docs/user` and `docs/guides` as bundles, and does not register `docs/adr`.
Records are named `NNNN-slug.md`, carry frontmatter with `title`, `status`, `date`, `authors`
and `related`, and open with a heading of the form `# ADR N — Title`. If this plan creates an
ADR, follow that convention exactly; do not add OKF frontmatter or invent a Mori identity.

Three existing records are relevant, and their relevant content is summarized here so you do
not need to read them to implement this plan:

[`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md`](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
and
[`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)
together establish that reusable platform behavior ships in Nagare's packaged NixOS modules
while each operator's own inputs live in a context-owned generated flake. The practical
consequence for this plan: `nixos/hosts/nagare-01/storage.nix` is platform code, so the
`autoResize` change is delivered to every operator rather than being something each operator
must apply by hand.

[`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
establishes that an installation crosses five independently versioned artifacts — the running
`nagarectl`, its platform payload, the context's intended release, the generated host flake,
and the resources bootstrapped into Kubernetes — and that `nagarectl platform guard` blocks
mutation when those drift incompatibly. The practical consequence: in a source checkout the
change here takes effect through `just host-switch` directly, but an operator running a
released version receives it only through a platform upgrade to a release containing it.

No existing ADR covers disk capacity, filesystem growth, or storage resizing. Whether this
work warrants a new one is decided in the distillation pass at the end of Milestone 5; the
candidate durable statement is that platform storage capacity is forward-only — it grows
automatically and cannot shrink — and that this is enforced rather than merely documented.

### Where the improvement request lives and how it closes

IR-5 is `docs/improvement-requests/data-disk-grow-procedure.md`, a concept in the
profile-governed OKF bundle `docs/improvement-requests/`. Its profile is pinned in
`docs/improvement-requests/profile.dhall` to the shared
`Profiles.coordination.improvementRequests` from `okf-profiles` v0.12.0. Reading that profile
gives the exact rules this plan must satisfy when closing the request:

The `status` field accepts exactly `proposed`, `accepted`, `in-progress`, `completed`,
`rejected`, `withdrawn`, or `superseded`. A `completedAt` field in RFC 3339 UTC form becomes
**required** once `status` is `completed`. A `resolution` field is recommended once the
request reaches any terminal state. An optional `targetPlan` field holds the
repository-relative path or Mori URI of the implementing plan. The bundle is validated
strictly by `just docs-validate`, which also enforces that the bundle's `log.md` is
maintained.

IR-5's current state, set when this plan was created: `status: accepted` with
`targetPlan: docs/plans/111-automate-and-document-growing-the-data-disk.md`, and a body
`**Status:**` line naming this plan. Both the frontmatter key and the body line must move
together at each transition, because the profile validates only the frontmatter and a
divergent body line would quietly go stale.


## Plan of Work

The work is five milestones. Each one ends with something a reader can independently verify,
and the first two are entirely offline — they change no cloud resource and cost nothing.

### Milestone 1 — The data disk grows itself

The scope is a single option and a check that it stays set. At the end of this milestone the
platform's NixOS configuration declares that `/var/lib/nagare` grows to fill its device, and
an automated evaluation check fails if anyone removes that later.

Edit `nixos/hosts/nagare-01/storage.nix`, in the `fileSystems."/var/lib/nagare"` attribute set
that currently spans lines 42-48. Add `autoResize = true;` with a comment that explains the
mechanism, because a future reader will otherwise not know that a one-line option is what
grows the disk:

```nix
  fileSystems."/var/lib/nagare" = {
    device = dataDiskDevice;
    fsType = "ext4";
    # nofail so a transient disk problem never wedges the whole boot; the
    # format-nagare-data oneshot above ensures the disk is formatted first.
    options = [ "defaults" "nofail" ];
    # Absorb a `dataDiskSizeGb` increase with no operator action. NixOS turns
    # autoResize into the `x-systemd.growfs` mount option, so systemd runs
    # systemd-growfs@var-lib-nagare.service right after the mount and grows the
    # ext4 filesystem to fill the device. ext4 grows ONLINE, so this is safe on
    # a running cluster and a no-op when the filesystem already fills the disk.
    # No partition grow is needed: format-nagare-data writes the filesystem
    # directly onto the whole block device, so there is no partition table.
    # The boot disk needs growpart as well, which google-compute-image.nix
    # already provides via boot.growPartition.
    autoResize = true;
  };
```

Then add an evaluation check to `nixos/flake.nix`. That file already has exactly this pattern:
`checks.${system}.forge-credentials-module` at lines 71-83 is a chain of `assert` expressions
over the evaluated configuration that produces a trivial output file. Follow it. Add a second
attribute beside it — Nix merges the two attribute paths into one `checks.${system}` set, so no
restructuring is needed:

```nix
      checks.${system}.data-disk-auto-grow =
        let
          dataFs = compatibilitySystem.config.fileSystems."/var/lib/nagare";
          rootFs = compatibilitySystem.config.fileSystems."/";
        in
        # The data disk must grow itself when dataDiskSizeGb increases.
        assert dataFs.autoResize;
        assert builtins.elem "x-systemd.growfs" dataFs.options;
        # nofail must survive: a transient disk fault must not wedge the boot.
        assert builtins.elem "nofail" dataFs.options;
        assert dataFs.fsType == "ext4";
        # The boot disk's pre-existing auto-grow must not regress either.
        assert rootFs.autoResize;
        assert builtins.elem "x-systemd.growfs" rootFs.options;
        assert compatibilitySystem.config.boot.growPartition;
        nixpkgs.legacyPackages.${system}.runCommand "nagare-data-disk-auto-grow-check" { } ''
          touch "$out"
        '';
```

Acceptance for this milestone is behavioral in the sense that matters for a declarative
system: the evaluation that produces the host's configuration now yields a mount carrying
`x-systemd.growfs`, and it is proven by a check that fails loudly if the option is removed.
Verify by re-running the evaluation command from Context and Orientation and seeing
`dataAutoResize` flip from `false` to `true` with `x-systemd.growfs` present in `dataOptions`,
and by building the new check.

Also in this milestone, mark the improvement request as being worked on. When this plan was
written, IR-5 was already moved to `status: accepted` and given
`targetPlan: docs/plans/111-automate-and-document-growing-the-data-disk.md`, so the only change
left is `accepted` to `in-progress` in the frontmatter of
`docs/improvement-requests/data-disk-grow-procedure.md`, along with its matching body line
("**Status:** accepted; planned as …"). Refresh its `generated.at` and `timestamp` to the
current UTC time, add a bundle log entry, and revalidate.

### Milestone 2 — Prove the online grow without touching GCP

An evaluation check proves an option is set. It cannot prove a filesystem grows. This
milestone produces that proof, reproducibly and for free, with a **NixOS virtual-machine
test**: a test that boots a real Linux virtual machine from a NixOS configuration under QEMU
and drives it from a Python script.

The trick that makes this possible without a cloud disk is to invert the setup. Instead of
growing a device (which cannot be done to a running virtual machine), the test writes a
deliberately **undersized** filesystem onto an oversized device — one gibibyte of `ext4` on a
two-gibibyte disk. That is bit-for-bit the state an operator's box is in immediately after
`dataDiskSizeGb` is increased: a filesystem smaller than the block device beneath it. If the
mechanism grows it to fill the device, the mechanism works.

The test must import the **real** `nixos/hosts/nagare-01/storage.nix`, not a copy, so that it
proves the shipped module rather than a paraphrase of it. Two accommodations are needed
because a QEMU virtual machine is not a Compute Engine instance. First, the module looks for
`/dev/disk/by-id/google-nagare-data`, which does not exist under QEMU, so the test node adds a
udev rule creating that symlink for the scratch disk. Second, the scratch disk itself comes
from `virtualisation.emptyDiskImages`, which attaches empty disks to the test machine.

Add this to `nixos/flake.nix` beside the other checks. Treat the test script as a working
starting point to iterate on against the real test driver, not as transcribed gospel — what
must hold at the end is the acceptance criterion stated after it:

```nix
      checks.${system}.data-disk-online-grow =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.testers.runNixOSTest {
          name = "nagare-data-disk-online-grow";
          nodes.machine = { ... }: {
            # Import the REAL platform module under test, not a copy of it.
            imports = [ ./hosts/nagare-01/storage.nix ];
            # storage.nix looks for the GCP by-id node, which QEMU has no
            # notion of. Point it at the scratch disk below.
            services.udev.extraRules = ''
              KERNEL=="vdb", SYMLINK+="disk/by-id/google-nagare-data"
            '';
            # A 2 GiB scratch disk, attached as /dev/vdb.
            virtualisation.emptyDiskImages = [ 2048 ];
            environment.systemPackages = [ pkgs.e2fsprogs ];
          };
          testScript = ''
            GIB = 1024 ** 3

            def data_disk_bytes():
                out = machine.succeed("df --output=size -B1 /var/lib/nagare | tail -n1")
                return int(out.strip())

            # Phase 0: a blank disk is formatted and mounted by the module, and
            # the subdirectory layout lands on the data disk (not underneath it).
            machine.wait_for_unit("multi-user.target")
            machine.succeed("mountpoint /var/lib/nagare")
            machine.succeed("test -d /var/lib/nagare/local-path")
            print(machine.succeed("df -h /var/lib/nagare"))

            # Phase 1, the reboot path. Put a 1 GiB filesystem on the 2 GiB
            # device: exactly the state after `dataDiskSizeGb` is increased.
            machine.succeed("systemctl stop var-lib-nagare.mount")
            machine.succeed("mkfs.ext4 -F -L nagare-data -b 4096 /dev/vdb 262144")
            machine.shutdown()
            machine.start()
            machine.wait_for_unit("multi-user.target")
            machine.succeed("mountpoint /var/lib/nagare")
            grown = data_disk_bytes()
            print(machine.succeed("df -h /var/lib/nagare"))
            assert grown > 1.5 * GIB, f"filesystem did not grow on boot: {grown} bytes"

            # Phase 2, the no-reboot path an operator uses on a live cluster.
            machine.succeed("systemctl stop var-lib-nagare.mount")
            machine.succeed("mkfs.ext4 -F -L nagare-data -b 4096 /dev/vdb 262144")
            machine.succeed("systemctl start var-lib-nagare.mount")
            machine.succeed("systemctl start systemd-growfs@var-lib-nagare.service")
            grown = data_disk_bytes()
            print(machine.succeed("df -h /var/lib/nagare"))
            assert grown > 1.5 * GIB, f"online grow did not take effect: {grown} bytes"
          '';
        };
```

The acceptance criterion, whatever shape the script settles into, is this: starting from a
one-gibibyte `ext4` filesystem on a two-gibibyte device, `df` inside the virtual machine
reports well over one and a half gibibytes both after a reboot and after the documented
manual command on a running machine. Phase 2 matters as much as Phase 1, because it is the
command Milestone 5 will put in front of an operator whose cluster is live and who cannot
reboot.

If Phase 1 proves flaky because the udev symlink races the mount, add
`systemd.services.format-nagare-data.after = [ "dev-vdb.device" ];` to the **test node only**,
never to the platform module — the race is an artifact of the virtual machine, since on GCP
the by-id node appears early in boot as the comment at `storage.nix:21-25` records.

This test needs an `x86_64-linux` builder with hardware virtualization available. On a macOS
workstation that means the remote builder; see Concrete Steps for how to run it and how to
tell whether the builder is reachable.

### Milestone 3 — Prove what the cloud plan actually does

This milestone changes nothing in the cloud. It runs `pulumi preview`, which computes and
prints the plan without applying it, and records the verbatim output as evidence.

Three questions get answered. Does raising `dataDiskSizeGb` produce an in-place **update** to
the disk, or a **replacement** that would destroy every byte on it? Does lowering it fail
closed? And does raising `bootDiskSizeGb` update in place or force the instance to be
replaced — the question `docs/user/reference.md:204` currently answers without evidence?

The danger to respect is that a replacement plan for the data disk would be catastrophic if
applied. Two things guard against that: only `preview` is run, never `up`; and `protect: true`
on the disk means Pulumi should refuse the plan even if someone did apply it. The second is
precisely the property being tested, so do not rely on it while testing it — run previews
only.

The other thing to respect is that `pulumi config set` writes to the stack's configuration
file, which is generated per context and not tracked in git. Record the original values before
changing anything and restore them at the end, then run one more preview to confirm the stack
is back to a clean plan.

Acceptance is a recorded transcript in this plan showing, for the increase, a line describing
an update to the `nagare-data` disk with a `size` diff and no replacement anywhere in the
plan; for the decrease, whatever Pulumi actually says, with an explicit statement of whether
that constitutes failing closed; and for the boot disk, a plain statement of which behavior
was observed.

### Milestone 4 — Prove it end to end on the live host

This is the milestone IR-5 calls "evidence from a live or local run". It grows the real data
disk by a small amount and shows `df -h` before and after.

**It begins with explicit operator consent, because growing a Persistent Disk cannot be
undone.** Milestone 3 will have just proved that shrinking fails closed. A 10 GiB increase on
`pd-balanced` costs roughly a dollar a month, permanently. Do not proceed past this point
without the operator saying so, and record their answer here.

The order matters. Roll out the host configuration **first**, with `just host-switch`, so the
new mount option is in the host's `/etc/fstab`. Then take the "before" `df -h`. Then apply the
size increase. Then take a second `df -h` *before* growing anything — this one is the
important piece of evidence, because it shows the gap this plan closes: the disk is bigger and
the filesystem is not. Then grow it and take the third `df -h`.

The reason the filesystem does not grow by itself at this point is worth stating clearly,
because it will otherwise look like a bug. `x-systemd.growfs` acts when the filesystem is
mounted. `/var/lib/nagare` was mounted at boot, is held open by k3s and every workload, and a
`nixos-rebuild switch` will not unmount it. So on the boot during which the disk was grown,
the operator runs one command; from the next reboot onward it is automatic. This is exactly
why the plan delivers both automation and documentation, and it is the single most important
thing for Milestone 5's prose to explain.

Reach the host with `scripts/iap-ssh.sh`, which tunnels through Identity-Aware Proxy; the
virtual machine must be running first. Do not reach for a default GKE kubectl context.

Acceptance is three `df -h` transcripts recorded in this plan telling a coherent story —
smaller, still smaller despite the bigger disk, then bigger — followed by evidence that the
cluster is healthy: the node `Ready` and no workload newly failing.

### Milestone 5 — Make the documentation and the alert tell the truth

Now write down only what the previous milestones proved.

In `docs/user/resizing-the-vm.md`, replace the final bullet at lines 173-174 with a real
section. It needs a stable heading so the alert can point at it — use `## Growing the data
disk`, which gives the anchor `#growing-the-data-disk`. The section must cover, in prose with
the exact commands: that growing is a `dataDiskSizeGb` increase plus a filesystem grow; that
the preview must show an update and not a replacement, with the actual expected text from
Milestone 3; that the filesystem grows by itself from the next boot but needs one command on
the boot during which the disk was grown, with that command spelled out; a `df -h`
verification with the real recorded output; and, plainly, that **shrinking is impossible** —
what Pulumi does when asked, and that `protect: true` is what stops it. Also fix line 95's
instruction to confirm targeting `tan-nb-exp`, replacing it with confirming the intended
active context.

In `docs/user/reference.md` and `docs/user/provisioning-with-pulumi.md`, fill the empty notes
cell for `nagare:dataDiskSizeGb` with the behavior and a pointer to the new section, and
revise the boot-disk row so it states what Milestone 3 observed instead of an unverified
assertion.

In `docs/user/persistent-storage.md`, add a pointer to the new procedure, since that is where
a reader worried about volume capacity will look first.

In `cluster/observability/vmrules/nagare-alerts.yaml`, extend the `DiskUsageHigh` annotations
so the alert leads somewhere. Keep `summary` as it is; extend `description` and add a
`runbook` annotation naming `docs/user/resizing-the-vm.md#growing-the-data-disk`. State the
first response: find the consumer before growing. That advice is grounded — the observability
stores are capped at 15 GiB of logs, 8 GiB of traces and 30 days of metrics, so they cannot be
the runaway; the growth is application volumes, database data, or backups, and `du -sh
/var/lib/nagare/*` identifies which in seconds.

Finally close IR-5: `status: completed`, a `completedAt` timestamp in RFC 3339 UTC, and a
`resolution` naming the evidence. Add a bundle log entry and revalidate. Then write Outcomes &
Retrospective and run the ADR distillation pass described in Context and Orientation.

Acceptance is that `just docs-validate` passes, and that an operator can start from the alert
text, follow the pointer, and reach commands that work.


## Concrete Steps

All commands assume the repository root `/Users/shinzui/Keikaku/bokuno/nagare` as the working
directory unless a different one is named. Where a command depends on the active context, it
is shown using `nagarectl context current` rather than a hard-coded project.

### Before anything: confirm your target

```bash
nagarectl context current
```

Expect the name of the context you intend to act on. If this prints an unexpected name, or
fails, stop and select the right context with `nagarectl context use NAME`. Every cloud step
below acts on this context's project and no other.

### Milestone 1

Edit `nixos/hosts/nagare-01/storage.nix` and `nixos/flake.nix` as described in Plan of Work.
Then confirm the evaluation changed, from the `nixos/` directory:

```bash
cd nixos
nix eval --json --impure --expr '
  let cfg = (builtins.getFlake (toString ./.)).nixosConfigurations.nagare-01.config;
  in {
    dataAutoResize = cfg.fileSystems."/var/lib/nagare".autoResize;
    dataOptions    = cfg.fileSystems."/var/lib/nagare".options;
  }'
```

Expected, in contrast to the `false` recorded in Context and Orientation:

```json
{"dataAutoResize":true,"dataOptions":["x-systemd.growfs","defaults","nofail"]}
```

Then build the new check. Its `assert`s run during evaluation, so a broken assertion fails
here with a clear message:

```bash
cd nixos
nix build .#checks.x86_64-linux.data-disk-auto-grow --print-build-logs
```

A silent exit with no error means every assertion held. To confirm the check has teeth, briefly
revert the `autoResize` line and re-run — the build must fail with an assertion error — then
restore it.

Mark the improvement request as in progress. Edit
`docs/improvement-requests/data-disk-grow-procedure.md` frontmatter: change `status: accepted`
to `status: in-progress`, and set both `timestamp` and `generated.at` to the current UTC time
in RFC 3339 form (get it with `date -u +%Y-%m-%dT%H:%M:%SZ`). Update the body's `**Status:**`
line to match. The `targetPlan` key already names this plan and needs no change. Then:

```bash
okf log add docs/improvement-requests --kind Update \
  -m "IR-5 is in progress: docs/plans/111-automate-and-document-growing-the-data-disk.md implements the data-disk grow."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Advisory `missing profile-recommended field: reviews` lines are pre-existing across all four
requests in this bundle and are not introduced by this change; anything else must be fixed.

Commit with both trailers:

```text
feat(nixos): grow the data disk filesystem automatically

Add autoResize to the /var/lib/nagare mount so a dataDiskSizeGb increase is
absorbed with no operator action, and assert it in a flake check.

ExecPlan: docs/plans/111-automate-and-document-growing-the-data-disk.md
Intention: intention_01m2av9m0ge8sbwjy4arw5svf9
```

Stage explicitly by path — never `git add -A` in this repository, because another actor may be
committing concurrently and a blanket add would sweep unrelated work:

```bash
git add nixos/hosts/nagare-01/storage.nix nixos/flake.nix \
        docs/improvement-requests/data-disk-grow-procedure.md \
        docs/improvement-requests/log.md \
        docs/plans/111-automate-and-document-growing-the-data-disk.md
git commit
```

### Milestone 2

A NixOS virtual-machine test must be built on `x86_64-linux` with hardware virtualization.
This repository provisions an on-demand remote builder for exactly that purpose
(`scripts/setup-nix-builder.sh`), and the workstation's SSH configuration starts it on demand.
Check that Nix knows about a Linux builder before you begin:

```bash
nix show-config | grep -E '^(builders|system-features|extra-platforms)'
```

If no `x86_64-linux` builder is configured, provision one with `scripts/setup-nix-builder.sh`
(it is idempotent and stops the machine when finished, so an idle builder costs only its boot
disk). Then run the test:

```bash
cd nixos
nix build .#checks.x86_64-linux.data-disk-online-grow --print-build-logs
```

The build log is the test transcript. Look for the `df -h` output printed by each phase and
for the absence of an assertion failure. A successful run ends with the store path and no
error. Copy the three `df -h` blocks into this plan's Surprises & Discoveries or Progress.

If the run fails because the scratch disk is not yet visible when the format service runs, add
the `after = [ "dev-vdb.device" ];` line to the test node as described in Plan of Work and
re-run. If it fails because KVM is unavailable, the builder lacks nested virtualization; that
is a builder provisioning problem, not a test problem — note it here and fix the builder.

Commit with the same trailers, staging `nixos/flake.nix` and this plan.

### Milestone 3

Record the current values first, so they can be restored exactly:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config get nagare:dataDiskSizeGb --stack "$STACK"
pulumi -C infra/pulumi config get nagare:bootDiskSizeGb --stack "$STACK"
```

If either key is unset, `pulumi config get` reports that it is not found; the effective
defaults are then `100` for both, per `infra/pulumi/index.ts:20` and `infra/pulumi/index.ts:52`.
Write down what you saw before continuing.

Preview the increase:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 110 --stack "$STACK"
just infra-preview
```

Read the plan carefully. What must be true is an **update** to the `nagare-data` disk showing
a `size` diff, and no `replace` and no `delete` anywhere in the plan. Pulumi renders an update
with a leading `~` and a replacement with `+-`. Capture the relevant lines verbatim into this
plan. If you see a replacement of the data disk, **stop immediately**, restore the original
value, and record the finding — that would contradict IR-5's premise and change the shape of
the remaining work.

Preview the decrease. This one is expected to fail in some way; the point is to record
precisely how:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 50 --stack "$STACK"
just infra-preview
```

Capture the output verbatim whether it is a provider error, a replacement plan, or a
protection error. Then state in this plan whether it fails closed — meaning no path from here
reaches a destroyed disk without a deliberate, explicit unprotect.

Preview the boot-disk increase:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb <original> --stack "$STACK"
pulumi -C infra/pulumi config set nagare:bootDiskSizeGb 110 --stack "$STACK"
just infra-preview
```

Record whether this is an in-place update to the instance's boot disk or a replacement of the
instance. Note that `vmDeletionProtection` defaults to `true`
(`docs/user/reference.md:206`), so a replacement plan should also fail closed — record whether
it does.

Restore and verify clean:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config set nagare:bootDiskSizeGb <original> --stack "$STACK"
just infra-preview
```

Expect a plan with no changes to the disks or the instance. Commit this plan with the recorded
evidence.

### Milestone 4

Confirm consent and record it here before running anything in this section.

Roll out the host configuration containing the new mount option:

```bash
just host-switch
```

If `nagarectl platform guard` blocks this, the context's platform version and the payload have
drifted; resolve that through the upgrade path in `docs/user/upgrades.md` rather than by
bypassing the guard.

Open a session on the host. Start the virtual machine first if it is stopped, and connect as
the `deploy` user through the Identity-Aware Proxy tunnel:

```bash
just vm-start
scripts/iap-ssh.sh
```

Capture the "before" state on the host:

```bash
df -h /var/lib/nagare
du -sh /var/lib/nagare/* 2>/dev/null | sort -h
```

The `du` output is worth keeping: it is real evidence for the "identify the consumer first"
advice Milestone 5 gives, and it tells you whether this box's growth is application volumes,
database data, or backups.

Back on the workstation, apply the increase:

```bash
STACK="$(nagarectl context current)"
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 110 --stack "$STACK"
just infra-preview   # confirm one more time it is an update, not a replacement
just infra-up
```

On the host again, capture the gap and then close it:

```bash
df -h /var/lib/nagare
lsblk /dev/disk/by-id/google-nagare-data
sudo systemctl start systemd-growfs@var-lib-nagare.service
df -h /var/lib/nagare
```

The first `df -h` should show the **old** size while `lsblk` shows the **new** device size —
that contrast is the evidence that the gap this plan closes is real. The second `df -h` should
show the new size. Note that `systemd-growfs@.service` is a template unit shipped with systemd
and can be started directly, which is why this command works even on a host that has not yet
picked up the new mount option.

Confirm the cluster is healthy:

```bash
kubectl get nodes
kubectl get pods -A
```

Expect the node `Ready` and no workload newly failing. Record all transcripts in this plan and
commit.

### Milestone 5

Make the documentation edits described in Plan of Work. Every reader-facing document in
`docs/user/` carries OKF frontmatter with a `generated.at` timestamp; refresh it on each file
you edit. Then add one bundle log entry and validate:

```bash
okf log add docs/user --kind Update \
  -m "Document growing the data disk: the automatic online grow, the one-command path on a running host, and that shrinking is impossible."
just docs-validate
```

`just docs-validate` runs the strict profile checks for `docs/reviews`, `docs/user` and
`docs/guides`. Fix anything it reports beyond the pre-existing `reviews` advisories.

Close the improvement request. In
`docs/improvement-requests/data-disk-grow-procedure.md`, set `status: completed`, add
`completedAt` with the current RFC 3339 UTC time, add a `resolution` naming the evidence (the
virtual-machine test, the recorded previews, and the live `df -h` transcripts), and refresh
`timestamp` and `generated.at`. Update the body's `**Status:**` line to match, keeping its link
to this plan. Then:

```bash
okf log add docs/improvement-requests --kind Update \
  -m "Deliver IR-5: the data disk grows itself, the procedure is documented and tested, and the disk alert points at it."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Write the Outcomes & Retrospective section, then run the ADR distillation pass: decide whether
the forward-only storage-capacity property belongs in `docs/adr/` as a new record following the
plain `NNNN-slug.md` convention described in Context and Orientation, and record the decision
either way in the Decision Log. If you create one, allocate the next unused number by
inspecting `docs/adr/` — and note that another plan in flight may claim a number concurrently,
so re-check immediately before writing.

Commit with both trailers, staging explicitly by path.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

Running `nix build .#checks.x86_64-linux.data-disk-auto-grow` from `nixos/` succeeds, and
removing `autoResize = true` from `nixos/hosts/nagare-01/storage.nix` makes it fail with an
assertion error. This proves the property is enforced and not merely present.

Running `nix build .#checks.x86_64-linux.data-disk-online-grow` from `nixos/` succeeds. Inside
that test, a one-gibibyte `ext4` filesystem on a two-gibibyte device reaches over one and a
half gibibytes both after a reboot and after
`systemctl start systemd-growfs@var-lib-nagare.service` on a running machine. This proves the
grow actually happens, not merely that an option is set.

This plan contains a verbatim `pulumi preview` transcript showing that increasing
`nagare:dataDiskSizeGb` produces an in-place update to the `nagare-data` disk with no
replacement, and a second transcript showing exactly what happens when it is decreased, with a
written statement of whether that fails closed. It also records the observed boot-disk
behavior.

This plan contains three `df -h /var/lib/nagare` transcripts from the live host: one before
the grow, one after the disk was enlarged but before the filesystem was grown (showing the old
size against a larger `lsblk` device), and one after the grow showing the new size. `kubectl
get nodes` shows the node `Ready` afterwards.

`docs/user/resizing-the-vm.md` contains a `## Growing the data disk` section with real
commands, the real expected preview text, a real `df -h` verification, an explanation of why
one command is needed on the boot during which the disk was grown, and a plain statement that
shrinking is impossible and what happens if attempted. Its step 1 no longer instructs the
reader to confirm they are targeting `tan-nb-exp`.

`cluster/observability/vmrules/nagare-alerts.yaml` gives `DiskUsageHigh` a remediation pointer
to that section and states the recommended first response. An operator reading the alert can
reach a working procedure.

`just docs-validate` passes. `okf validate docs/improvement-requests --strict --profile
docs/improvement-requests/profile.dhall --profile-enforce --log-enforce` passes with IR-5 at
`status: completed` carrying `completedAt` and `resolution`.

Nothing in the storage documentation asserts behavior that no test or recorded run supports.
That is IR-5's acceptance criterion, and it is the one to re-read before declaring the plan
done.


## Idempotence and Recovery

Milestones 1 and 2 are pure code edits and pure evaluation. They change nothing outside the
repository, can be run any number of times, and are reverted by `git checkout` on the two
files.

The `autoResize` change is idempotent by nature. Growing a filesystem that already fills its
device is a no-op: `systemd-growfs` finds nothing to do and exits successfully. Rebooting a
host with this option set repeatedly has no cumulative effect. The option cannot shrink a
filesystem, so it cannot destroy data by acting on a disk that was somehow made smaller.

The virtual-machine test destroys and recreates filesystems, but only on scratch disks inside a
throwaway QEMU machine created fresh for each run. It cannot touch the workstation or any
cluster.

Milestone 3 runs `pulumi preview` only, which computes a plan and applies nothing. The one
piece of state it does mutate is the stack's configuration file, and that is not tracked in
git, so it must be restored by hand. Record the original values before changing them, restore
them at the end, and prove the restore with a final preview that plans no changes. If the
sequence is interrupted partway, recover by setting both keys back to their recorded originals
and previewing again. Should the original values be lost, the defaults are `100` for both, per
`infra/pulumi/index.ts:20` and `infra/pulumi/index.ts:52` — but check whether the live disk is
actually that size before assuming it.

Milestone 4 is the only step that changes anything real, and one part of it is genuinely
irreversible: **a Persistent Disk cannot be shrunk**. That is the very property Milestone 3
proves. Treat the size increase as permanent and take it only with explicit consent. Everything
else in that milestone is recoverable: `just host-switch` can be re-run, and a NixOS host keeps
its previous configuration as a bootable generation, so an unsatisfactory switch is rolled back
with `sudo nixos-rebuild switch --rollback` on the host or by selecting the previous generation
at boot. Running `systemd-growfs` is safe to repeat.

The mount carries `nofail`, which this plan preserves and the flake check asserts. That means a
transient problem with the data disk leaves the host bootable rather than wedging it, which is
the property that makes recovery possible at all. Do not remove it.

Milestone 5 is documentation and one alert annotation. The alert change is applied to the
cluster by the observability bootstrap; a bad annotation cannot break alerting evaluation,
since only the `expr` field drives firing and that is left untouched.


## Interfaces and Dependencies

`nixos/hosts/nagare-01/storage.nix` is the only platform file whose behavior changes. At the end
of Milestone 1 its `fileSystems."/var/lib/nagare"` attribute set must contain `device`, `fsType
= "ext4"`, `options` including both `"defaults"` and `"nofail"`, and `autoResize = true`. The
two oneshot services it defines, `format-nagare-data` and `nagare-data-layout`, are unchanged;
do not alter their ordering, since `nagare-data-layout` must stay ordered after the mount or
the subdirectories land on the root filesystem and are hidden by the mount — a failure already
observed once and recorded in the comment at `storage.nix:50-56`.

`fileSystems.<name>.autoResize` is a standard NixOS option from `nixpkgs`, pinned in
`nixos/flake.lock` at revision `331800de5053fcebacf6813adb5db9c9dca22a0c`. It is confirmed
present in that revision and confirmed to produce the `x-systemd.growfs` mount option with no
failing assertions. It supports `ext4`, which is what this disk uses. Nothing new needs to be
added to `nixos/flake.nix`'s inputs.

`nixos/flake.nix` gains two attributes under `checks.x86_64-linux`: `data-disk-auto-grow`,
which evaluates assertions against `compatibilitySystem.config` and produces a trivial
`runCommand` output exactly as the existing `forge-credentials-module` check does; and
`data-disk-online-grow`, a `pkgs.testers.runNixOSTest` virtual-machine test. The existing
`forge-credentials-module` check must keep working unchanged.

`pkgs.testers.runNixOSTest` and `virtualisation.emptyDiskImages` come from the same pinned
`nixpkgs`. The test requires an `x86_64-linux` builder with KVM; the repository provisions one
through `scripts/setup-nix-builder.sh`, which creates an `n2-standard-2` machine with nested
virtualization enabled, restricted to Identity-Aware Proxy ingress, and stopped while idle.

`infra/pulumi/src/components/NagarePerimeter.ts` and `infra/pulumi/index.ts` are **read only**
in this plan. No TypeScript changes are required: the size is already configurable and the disk
is already protected. If Milestone 3 reveals that an increase forces a replacement, that
conclusion changes the plan and must be recorded in the Decision Log before any code is
written.

`cluster/observability/vmrules/nagare-alerts.yaml` gains annotations on the `DiskUsageHigh`
rule only. The `expr`, `for`, and `labels` fields are unchanged, so alert firing behavior is
identical. This is a `VMRule` custom resource
(`operator.victoriametrics.com/v1beta1`) reconciled by the VictoriaMetrics operator.

`docs/improvement-requests/data-disk-grow-procedure.md` is governed by the profile pinned in
`docs/improvement-requests/profile.dhall`, which resolves to
`Profiles.coordination.improvementRequests` from `okf-profiles` v0.12.0. The fields this plan
writes are `status` (from the enum `proposed`, `accepted`, `in-progress`, `completed`,
`rejected`, `withdrawn`, `superseded`), `targetPlan` (optional; a repository-relative path or
Mori URI), `completedAt` (required once `status` is `completed`; RFC 3339 UTC), and `resolution`
(recommended at a terminal state). Do not invent field names — the profile is authoritative and
`okf validate` enforces it.

The documents edited in Milestone 5 — `docs/user/resizing-the-vm.md` (docId `DOC-30`),
`docs/user/reference.md`, `docs/user/provisioning-with-pulumi.md`, and
`docs/user/persistent-storage.md` — belong to the `docs/user` OKF bundle validated by `just
docs-validate` against `mori/user-documentation-profile.dhall`. Preserve each file's existing
`docId` and frontmatter shape; refresh `generated.at` on the files you change.

`docs/adr/` is a plain filesystem convention in this repository and is **not** an OKF bundle.
If the distillation pass creates a record, name it `NNNN-slug.md`, give it frontmatter with
`title`, `status`, `date`, `authors` and `related`, and open it with `# ADR N — Title`. Do not
run `okf id next` against it and do not add OKF frontmatter.
