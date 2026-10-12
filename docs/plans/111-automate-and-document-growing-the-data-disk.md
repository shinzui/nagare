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
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T17:19:10Z
      mode: "implement"
      note: "Implementing milestones 1-5: data-disk autoResize, VM test, Pulumi previews, live rehearsal, documentation."
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T21:29:27Z
      mode: "implement"
      note: "Milestones 2-4 completed under ExecPlan 114; Milestone 5 docs, alert, IR-5 closure, ADR 12"
---

# Automate and document growing the data disk

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [111-automate-and-document-growing-the-data-disk.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/111-automate-and-document-growing-the-data-disk.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] Add `autoResize = true` to the `/var/lib/nagare` entry in `nixos/hosts/nagare-01/storage.nix`, with a comment explaining what NixOS does with it. (2026-09-12)
- [x] Add a `data-disk-auto-grow` evaluation check to `nixos/flake.nix` asserting the mount carries `x-systemd.growfs`, and that the boot disk's existing auto-grow is still in place. (2026-09-12) — required restructuring `checks.${system}` into one attribute set; see Surprises.
- [x] Run the check and record its output. (2026-09-12) — passes; proven to have teeth by temporarily commenting out `autoResize`.
- [x] Move IR-5 from `accepted` to `in-progress` (its `targetPlan` already names this plan), then revalidate the improvement-request bundle. (2026-09-12)
- [x] Commit. (2026-09-12)

Milestone 2 — prove the online grow without touching GCP:

- [x] (2026-09-12) **Paused, then resumed under [ExecPlan 114](114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md).** That plan records the ordering-cycle bug in commit `489daf3`, the Milestone 3 preview evidence, and the SSH lockout on nagare-01, and it completed Milestones 2–4.
- [x] (2026-09-12T21:40Z) Add a `data-disk-online-grow` NixOS virtual-machine test to `nixos/flake.nix` that imports the real `storage.nix`, puts a deliberately undersized ext4 filesystem on an oversized disk, and proves the filesystem reaches the device size. It needed the ordering-cycle fix and a device-ordering fix in `storage.nix` (see Surprises).
- [x] (2026-09-12T21:40Z) Prove the reboot path (grow happens by itself on the next boot): `PHASE 1 /dev/vdb 2.0G`.
- [x] (2026-09-12T21:40Z) Prove the no-reboot path. The test's `systemctl start systemd-growfs@var-lib-nagare.service` grows the filesystem only because the test stopped the mount first: `PHASE 2 /dev/vdb 2.0G`. On a live host the command must be `restart` (see Surprises).
- [x] (2026-09-12T21:40Z) Record the test transcript: ExecPlan 114 Progress, Milestone 4 (`PHASE 0/1/2` all `2.0G`, no ordering cycle).
- [x] (2026-09-12T21:42Z) Commit: `5bcf428`.

Milestone 3 — prove what the cloud plan actually does:

- [x] (2026-09-12) Record the current `nagare:dataDiskSizeGb` and `nagare:bootDiskSizeGb` values before touching anything: both unset, so both default to 100.
- [x] (2026-09-12) Preview an *increase* of `dataDiskSizeGb` and record the verbatim plan: in-place `~ size: 100 => 110`, no replacement (ExecPlan 114 Context and Orientation).
- [x] (2026-09-12) Preview a *decrease* of `dataDiskSizeGb` and record verbatim what Pulumi says. Before `protect` was in state: `+- (replace)`, no error. After a `pulumi up` wrote it: `unable to replace resource ... marked for protection`, exit 1. It fails closed only once the flag is in state.
- [x] (2026-09-12) Preview an *increase* of `bootDiskSizeGb`: `~ initializeParams: { ~ size : 100 => 110 }` inside an instance `+- (replace)`. The size is create-time-only, so the change forces instance replacement.
- [x] (2026-09-12) Restore both config values to what they were, and verify a preview is clean: `31 unchanged`.
- [x] (2026-09-12) Commit the recorded evidence into this plan: recorded in ExecPlan 114 (`ee66ee4`).

Milestone 4 — prove it end to end on the live host:

- [x] (2026-09-12) Confirm the operator explicitly consents to a permanent disk-size increase (a grow cannot be undone): consent to 100 → 110 GiB given 2026-09-12.
- [x] (2026-09-12T22:05Z) Roll the new host configuration out with `just host-switch`: `COMMITTED`, `system-5-link`, fstab `x-systemd.growfs,defaults,nofail`.
- [x] (2026-09-12T22:06Z) Capture `df -h /var/lib/nagare` before the grow: `/dev/sdb 98G 209M 93G 1%`.
- [x] (2026-09-12T22:08Z) Apply the size increase: `pulumi up`, `~ 1 updated`, `30 unchanged`.
- [x] (2026-09-12T22:08Z) Capture `df -h /var/lib/nagare` after the apply but before any grow command: `/dev/sdb 98G 212M 93G 1%` on `sdb 110G`.
- [x] (2026-09-12T22:12Z) Grow the filesystem on the running host: `systemctl restart systemd-growfs@var-lib-nagare.service` → `/dev/sdb 108G 212M 103G 1%` (`start` was a no-op).
- [x] (2026-09-12T22:12Z) Confirm the cluster is healthy afterwards: node `Ready`, no newly failing pods.
- [x] (2026-09-12T22:15Z) Commit the recorded evidence into this plan: ExecPlan 114, `ee66ee4`.

Milestone 5 — make the documentation and the alert tell the truth:

- [x] (2026-09-12T22:30Z) Write the "Growing the data disk" section in `docs/user/resizing-the-vm.md`, replacing the one-sentence bullet.
- [x] (2026-09-12T22:30Z) State plainly that shrinking is impossible and what happens if it is attempted, including when `protect` takes effect.
- [x] (2026-09-12T22:30Z) Fix the hard-coded `tan-nb-exp` instruction in `docs/user/resizing-the-vm.md` step 1; it now says to confirm the intended context with `nagarectl context current`.
- [x] (2026-09-12T22:30Z) Fill in the `nagare:dataDiskSizeGb` notes in `docs/user/reference.md` and `docs/user/provisioning-with-pulumi.md`, and correct the boot-disk claim: create-time only, and a change forces instance replacement.
- [x] (2026-09-12T22:30Z) Point `docs/user/persistent-storage.md` at the new procedure.
- [x] (2026-09-12T22:30Z) Give the `DiskUsageHigh` alert in `cluster/observability/vmrules/nagare-alerts.yaml` a remediation pointer (`runbook` annotation) and a stated first response (find the consumer with `du`).
- [x] (2026-09-12T22:31Z) Run `just docs-validate`: `docs/user` `OK: 36 concepts`, `docs/guides` `OK`, `docs/reviews` `OK`.
- [x] (2026-09-12T22:33Z) Close IR-5 as `completed` with `completedAt` and a `resolution`, log it, and revalidate. `okf validate docs/improvement-requests ...` prints only the four pre-existing `missing profile-recommended field: reviews` advisories. It exits 1, and so does the committed `HEAD` bundle, so this is not a regression.
- [x] (2026-09-12T22:36Z) Fill in Outcomes & Retrospective and run the ADR distillation pass: new [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md), plus a copy note in ADR 11.
- [x] (2026-09-12T22:37Z) Commit.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

### Nix does not merge two *dynamic* `checks.${system}.<name>` attribute paths

Plan of Work said "Nix merges the two attribute paths into one `checks.${system}` set, so no
restructuring is needed". That is true for static attribute paths but **false** when the middle
component is a dynamic attribute (`${system}`). Adding the new check beside the existing one as a
second `checks.${system}.<name>` path failed at evaluation:

```text
error: dynamic attribute 'x86_64-linux' already defined at .../nixos/flake.nix:71:7
       at /Users/shinzui/Keikaku/bokuno/nagare/nixos/flake.nix:90:7:
           90|       checks.${system}.forge-credentials-module =
```

The fix, applied in Milestone 1, is to collapse both checks into a single
`checks.${system} = { data-disk-auto-grow = ...; forge-credentials-module = ...; };` set. This is
worth knowing for anyone adding a third check to `nixos/flake.nix`: put it inside that set, not on
a new `checks.${system}.` path.

### The data-disk evaluation flipped exactly as predicted

After the edit, from `nixos/`:

```json
{"dataAutoResize":true,"dataOptions":["x-systemd.growfs","defaults","nofail"]}
```

Contrast the `false` / `["defaults","nofail"]` recorded in Context and Orientation at commit
`c87544c`.

### The check has teeth

Commenting out `autoResize = true;` and rebuilding the check fails loudly, which is the property
Validation and Acceptance asks for:

```text
error: assertion '(dataFs).autoResize' failed
       at /Users/shinzui/Keikaku/bokuno/nagare/nixos/flake.nix:78:11:
           78|           assert dataFs.autoResize;
```

The line was restored immediately afterwards. The pre-existing `forge-credentials-module` check
still builds after the restructuring.

### The shipped grow never ran: an ordering cycle deleted it

As committed in `489daf3`, `autoResize` did nothing. `format-nagare-data` (default dependencies,
so `After=basic.target`) is ordered before the mount, and growfs makes `local-fs.target` wait on
the mount. That closes a cycle, and systemd broke it by deleting the grow job. The VM test showed
it first, then the live host's own boot log:

```text
sysinit.target: Job systemd-growfs@var-lib-nagare.service/start deleted to break ordering cycle starting with sysinit.target/start
```

The fix sets `DefaultDependencies = false` with `after = [ "local-fs-pre.target" ]`. That alone
created a first-boot race: the service ran before udev made the by-id link, skipped formatting,
and a blank disk failed to mount. So it also `wants`/`after` the by-id `.device` unit. Details and
logs are in [ExecPlan 114](114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md) Surprises.

### QEMU tests replace `fileSystems` wholesale

`qemu-vm.nix` sets `fileSystems` with `mkVMOverride virtualisation.fileSystems`. Importing
`storage.nix` into a test node therefore silently drops the data-disk mount. The test mirrors the
shipped definition into `virtualisation.fileSystems`.

### `systemctl start` on the growfs unit is a no-op on a live host

`systemd-growfs@.service` is `RemainAfterExit=yes`. After its boot-time run it stays
`active (exited)`, so `start` exits 0 and does nothing. `restart` grows the filesystem. The Plan of
Work's command was wrong for exactly the case it was written for.

### `protect: true` protects only once it is in state, and the boot-disk size is create-time

A decrease previewed as a plain replacement until a `pulumi up` wrote `protect` into state. After
that it failed closed. `bootDiskSizeGb` changes `bootDisk.initializeParams`, which forces instance
replacement.

### Pulumi state migration and the SSH lockout

On 2026-09-12 the live stack's state moved from the in-repo `infra/pulumi/.pulumi-state` (stack
`dev`) to the context backend (stack `tan-nb-exp`). The first attempt at Milestone 4 switched
nagare-01 onto the in-repo evaluation fixture and removed the operator's SSH key. [ExecPlan 114](114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md) recovered
access and finished the milestones. ExecPlan 115 and ADR 11 prevent a recurrence.

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

- Decision: Record the forward-only storage-capacity rule as a new ADR 12 rather than amending ADR 5.
  Rationale: ADR 5 is about where operator inputs live. This rule is about storage semantics: grow
  only, automatic grow, the `DefaultDependencies` constraint for units ordered before a growfs
  mount, and create-time boot-disk size. It is new durable context and applies to every operator.
  The day-2 switching lesson was already recorded by ExecPlan 115 in ADR 5 and ADR 11. ADR 11 gains
  one paragraph on `nix copy --no-check-sigs`.
  Date: 2026-09-12

- Decision: Document the live grow command as `systemctl restart`, not the Plan of Work's `start`.
  Rationale: `start` was observed to be a no-op on nagare-01 (ExecPlan 114 Surprises).
  Date: 2026-09-12

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Delivered (2026-09-12). The data disk grows itself on every boot, and one documented command grows
it on a running host. Both paths are proven by a VM test and by a live 100 → 110 GiB grow on
nagare-01 (98G → 108G). The previews prove increases are in place and decreases fail closed once
`protect` is in state. The docs and the `DiskUsageHigh` alert now lead to a working procedure. IR-5
is closed, and the durable rule is [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md).

What went wrong. The option-level evaluation check passed while the feature did not work, because
an ordering cycle deleted the grow. Only the VM test exposed it, and only a second VM run exposed
the first-boot race in the first fix. The Plan of Work's manual command (`start`) was also wrong
on a live host, a case the VM test did not cover because it remounted first. The live milestone
was attempted before the VM test proved the change, and without the guarded host switch. That
caused the lockout recovered in [ExecPlan 114](114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md). The lesson: prove behavior in a VM before touching the host,
and exercise the exact operator command in the exact host state.

