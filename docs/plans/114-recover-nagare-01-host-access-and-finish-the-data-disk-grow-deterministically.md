---
id: 114
slug: recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically
title: "Recover nagare-01 host access and finish the data-disk grow deterministically"
kind: exec-plan
created_at: 2026-09-12T18:24:12Z
intention: "intention_01m2av9m0ge8sbwjy4arw5svf9"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T18:24:12Z
  revisions:
    - model: "claude-opus-5"
      harness: "claude-code"
      at: 2026-09-12T18:38:39Z
      mode: "update"
      note: "Validation: startup script inert -> Path B; fix rescue OS Login, boot device-name drift, snapshot, --refresh gates"
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T20:23:39Z
      mode: "implement"
      note: "Implementation session: preflight through recovery milestones"
---

# Recover nagare-01 host access and finish the data-disk grow deterministically

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-09-12 an earlier session implementing
[ExecPlan 111](111-automate-and-document-growing-the-data-disk.md) (grow the data disk) locked the
operator out of SSH on the live Nagare host `nagare-01`. It then made the situation murkier
with several improvised recovery attempts. The host is running and its data is intact, but
nobody can log in. The instance also carries temporary metadata that will change the machine
again on its next boot.

After this plan is carried out, five things are true, and each can be checked with a command:
the operator can SSH to `nagare-01` as `deploy`; no temporary recovery metadata remains and
`pulumi preview` reports zero changes; the host runs a configuration generated from the
operator's own context (with the real SSH key), not the repository's evaluation fixture; the
data disk at `/var/lib/nagare` has been grown from 100 GiB to 110 GiB and `df -h` shows the new
space; and the fix that makes the automatic grow actually work is proven by a passing
virtual-machine test and committed. ExecPlan 111's documentation milestone then resumes with
correct facts. A separate ExecPlan is authored for moving operator-private material out of this
open-source repository.

This plan is written to be **deterministic**. Every milestone ends with a gate: a command whose
output decides pass or fail. **When a gate fails, stop.** Do not improvise a workaround. Record
the output in Surprises & Discoveries, report it (see "Reporting back" below), and wait. The
lockout this plan repairs was caused by exactly that kind of improvisation, so the rule is not
optional.


## Progress

Prerequisite — lockout prevention ([ExecPlan 115](115-prevent-host-lockouts-with-guarded-self-reverting-host-switches.md)):

- [x] (2026-09-12T20:40Z) ExecPlan 115 Milestone 1 (agent guardrails hook) is committed (`8eececa`) and live-checked **before Milestone 1 here**. The deny path was verified. Under `defaultMode: "auto"` the "ask" path shows no prompt (ExecPlan 115 Surprises).
- [x] (2026-09-12T20:40Z) ExecPlan 115 Milestones 2–4 (fixture refuses activation, self-reverting switch, break-glass boot menu) are committed (`744e837`, `f6a3ce7`) **before Milestone 5 here**. `host-switch-auto-rollback` passes.

Milestone 0 — Read-only preflight:

- [x] (2026-09-12T18:36Z, validation pass) Confirm the active context resolves to `tan-nb-exp` in cloud mode. Printed `tan-nb-exp cloud`. Re-run the check in every new shell anyway.
- [x] (2026-09-12T20:22Z) Stop only the stray local IAP tunnel(s) left by the previous session, by PID. PID 41469 was `gcloud ... start-iap-tunnel nagare-01 22 --local-host-port=localhost:2223`; it was killed, and nothing listens on 2222 or 2223 now.
- [x] (2026-09-12T20:22Z) Implementation-session re-check: the target resolves to `tan-nb-exp cloud`; the instance is `RUNNING` with keys `enable-oslogin;ssh-keys;startup-script`; the fresh serial capture (460 lines, one `SeaBIOS` boot) has no `NAGARE-RECOVERY`, `/home/deploy`, `authorized_keys.d`, `deploy:`, or `ssh-ed25519` lines. This agrees with the validation pass, so Path B stands.
- [x] (2026-09-12T18:36Z, validation pass) Record the instance status and its current metadata keys: `RUNNING`; `enable-oslogin`, `ssh-keys`, `startup-script`. Also recorded: the boot disk's device name, the project-wide metadata, and the firewall rules (see Surprises).
- [x] (2026-09-12T18:36Z, validation pass) Capture the serial-console log and extract every `NAGARE-RECOVERY` line: **none**. The startup script never ran, so Milestone 2 is Path B (see Surprises and Decision Log).
- [x] (2026-09-12T20:25Z) Report back: sent PASS to `nagare-62`.

Milestone 1 — Stabilize (remove temporary metadata):

- [x] (2026-09-12T20:27Z) Remove the `startup-script`, `ssh-keys`, and `enable-oslogin` metadata keys. `remove-metadata` printed `Updated [...instances/nagare-01]` and the standard global-DNS warning.
- [x] (2026-09-12T20:27Z) Gate PASS: `describe` lists none of them (`KEYS_AFTER=[]`).
- [x] (2026-09-12T20:30Z) Gate PASS: `pulumi preview --refresh --diff` exits 0 with `Resources: 31 unchanged`. The `~` lines are output-only refresh diffs (etags, `updated` timestamps, `currentStatus TERMINATED => RUNNING`, `attachedDisks` shown as secret). No create, update, delete, or replace is planned. Full output: `/tmp/ep114/preview-m1.txt`.
- [x] (2026-09-12T20:31Z) Report back.

Milestone 2 — Restore SSH access:

- [x] (2026-09-12T18:36Z, validation pass) Choose Path A or Path B from the Milestone 0 serial log: **Path B**, because the log has no `NAGARE-RECOVERY` lines (Decision Log).
- [x] (2026-09-12T20:31Z) Path B step 1: `/tmp/ep114/nagare-01-before-rescue.yaml` and `disks-before.yaml` recorded. Boot `persistent-disk-0`/`autoDelete: true`, data `nagare-data`/`autoDelete: false`, subnet `nagare-network-subnet-555da2a`, no tags. Matches the plan.
- [x] (2026-09-12T20:32Z) Path B step 1b/2: `nagare-01` stopped (`TERMINATED`); snapshot `nagare-01-pre-rescue-20260912` created, `SNAPSHOT_STATUS=READY`; boot disk detached (only `nagare-data` remains attached).
- [x] (2026-09-12T20:33Z) Path B step 3: `nagare-rescue` created (e2-small, 10.10.0.5, no external IP, `enable-oslogin=FALSE`); `nagare-01` attached as device `nagare-boot`.
- [x] (2026-09-12T20:33Z) Path B step 4: SSH as `rescue` works (the first IAP attempt got `4047 Failed to lookup instance` while the VM was new; the script's retry succeeded). `/dev/disk/by-label/nixos -> sdb1` on `google-nagare-boot`, the only `nixos` label.
- [x] (2026-09-12T20:34Z) Path B step 5 ran to `RESCUE_DONE`. Key written with correct owner and modes; "home before" had no `.ssh`, so the already-present stop does not apply; active generation `system-4-link`.
- [x] (2026-09-12T20:35Z) STOP at the step 5 gate: no `AuthorizedKeysFile` line was printed (see Surprises). Resolved by operator decision at 20:37Z: skip the check and proceed (Decision Log).
- [x] (2026-09-12T20:45Z) Path B step 6. Detach from `nagare-rescue` and the delete both succeeded, but the tool lost that command's output mid-run. A read-only re-check found the rescue VM `STOPPING` (then `RESCUE_GONE`) and disk `nagare-01` `READY` with no users, so nothing was re-run. Then reattached with `--boot --device-name=persistent-disk-0`, auto-delete on, `DISKS_MATCH`, and started the host.
- [x] (2026-09-12T20:50Z) Path B gates PASS: SSH prints `SSH_OK` / `nagare-01` / `SUDO_OK`; `DISKS_MATCH`; `pulumi preview --refresh` `EXIT=0`, `31 unchanged`, no change lines (`/tmp/ep114/preview-m2.txt`); `gcloud compute instances list` shows no `nagare-rescue`.
- [x] (2026-09-12T20:51Z) Baseline recorded (`/tmp/ep114/baseline-m2.txt`). Failed units: `network-local-commands.service` and `resolvconf.service`. Profile `system-4-link`. fstab already reads `/dev/disk/by-id/google-nagare-data /var/lib/nagare ext4 x-systemd.growfs,defaults,nofail 0 2`. Node `nagare-01 Ready`. Pods not Running/Succeeded: `nagare-system` `nagare-dbbackup-en-db-29819717-xr7bq` and `nagare-dbbackup-shomei-db-29819717-49j55` (`Init:Error`, 165m), and `personal` `nagare-dbbackup-{auditcache,auditolap,auditpg,pg-main}-29685797-*` (`Init:CreateContainerConfigError`, 93d).
- [x] (2026-09-12T20:52Z) Report back.

Milestone 3 — Generate the context-owned host configuration:

- [x] (2026-09-12T20:58Z) Build `nagarectl` and put it on `PATH` (`/tmp/ep114/nagarectl`). `nagarectl --version` is not an option (the subcommand is `version`). `context show` prints the `tan-nb-exp` cloud profile.
- [x] (2026-09-12T21:00Z) `nagarectl host init` for `tan-nb-exp` (dry run, then real): `Installed host configuration for context 'tan-nb-exp' at /Users/shinzui/.config/nagare/hosts/tan-nb-exp` (flake.nix, host.nix, secrets.yaml, flake.lock). `nagareInput` is **not** this checkout's `nixos/` but the store payload `path:/nix/store/h77hryxf93fsq4322fs3a63gy4pjcrry-nagare-platform-0.1.0/share/nagare/nixos`, built from the working tree (`Nagare source revision: 7cc21da...-dirty`). Its `hosts/nagare-01/storage.nix` is byte-identical to the working tree (with the fix), and `boot-recovery.nix` is present. See the Decision Log on Milestone 5's input gate.
- [x] (2026-09-12T21:01Z) Gate PASS: `authorizedKeys.keys` = `["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R shinzui@sungkyung"]`; no fixture key.
- [x] (2026-09-12T21:02Z) Report back (folded into the Milestone 4 message).

Milestone 4 — Prove and commit the ordering-cycle fix:

- [x] (2026-09-12T21:04Z) Add the `DefaultDependencies` assertion to the `data-disk-auto-grow` evaluation check; `EVAL_CHECK_OK`, `FORGE_CHECK_OK`.
- [x] (2026-09-12T21:04Z) Add the diagnostics, the by-id `wait_until_succeeds`, and the no-cycle assertion (after both `multi-user.target` waits) to the `data-disk-online-grow` VM test.
- [x] (2026-09-12T21:08Z) Gate: the builder is reachable. The plan's probe `nix store info --store ssh://builder@nix-gcp-builder` fails as the operator user (`Load key "/etc/nix/builder_ed25519": Permission denied`), because the key is readable only by the Nix daemon. Substituted a daemon-routed probe: `nix build .#checks.x86_64-linux.data-disk-online-grow.driver` built on `ssh://builder@nix-gcp-builder`, `DRIVER_EXIT=0` (this also lints the edited test script). See the Decision Log.
- [x] (2026-09-12T21:18Z) Run the VM test (attempt 1): `EXIT=1`, with KVM. The by-id link was present, so no fallback applies.
- [ ] **STOP (2026-09-12T21:20Z):** attempt 1 failed at Phase 0 `test -d /var/lib/nagare/local-path`. The ordering fix makes `format-nagare-data` run before udev creates the by-id link (see Surprises). Nothing was committed and the host was not switched. Waiting for a human decision on the proposed storage.nix fix.
- [x] (2026-09-12T21:25Z) Operator approved the fix. `format-nagare-data` now `wants`/`after` `dev-disk-by\x2did-google\x2dnagare\x2ddata.device`; `data-disk-auto-grow` asserts it. Pre-run checks: `EVAL_CHECK_EXIT=0`, `OTHER_CHECKS_EXIT=0` (forge, fixture, boot menu), `DRIVER_EXIT=0`.
- [x] (2026-09-12T21:40Z) Gate PASS, attempt 2: `EXIT=0` (script 69 s, KVM). Format ran before the mount (`[15.90] no filesystem ...; creating ext4`), and the log has 0 `skipped`/`Dependency failed`/`Failed to mount` lines for the data disk. The only `ordering cycle` lines are the driver echoing its own `must fail` assertions. `systemd-growfs` reported `Successfully resized "/var/lib/nagare" to 2G` in each phase. Log: `/tmp/ep114/vmtest-attempt2.log`.

  ```text
  PHASE 0 /dev/vdb        2.0G  564K  1.8G   1% /var/lib/nagare
  PHASE 1 /dev/vdb        2.0G  308K  1.9G   1% /var/lib/nagare
  PHASE 2 /dev/vdb        2.0G  280K  1.9G   1% /var/lib/nagare
  ```
- [x] (2026-09-12T21:42Z) Commit.
- [x] (2026-09-12T21:42Z) Report back.

Milestone 5 — Live grow on nagare-01:

- [ ] Gate: the generated host flake evaluates `x-systemd.growfs` and `DefaultDependencies = false`.
- [ ] Open the IAP tunnel on port 2222 and add the temporary `~/.ssh/config` block.
- [ ] `just host-switch` (ExecPlan 115's self-reverting switch); gates: output ends with `COMMITTED`, no new failed units, no ordering cycle, fstab carries `x-systemd.growfs`, `/boot/grub/grub.cfg` has `terminal_input serial` and a 10-second timeout.
- [ ] Record `df -h` and `lsblk` before.
- [ ] Set `dataDiskSizeGb` to 110; gate: preview shows exactly one change (the disk `size`).
- [ ] `pulumi up`; record `df -h` (gap) and `lsblk`.
- [ ] Run `systemd-growfs`; record `df -h` after.
- [ ] Gate: node Ready, no newly failing pods.
- [ ] Tear down the tunnel and the SSH config block; delete snapshot `nagare-01-pre-rescue-20260912` if Path B created it.
- [ ] Report back.

Milestone 6 — Hand back to ExecPlan 111 and author the private-repo plan:

- [ ] Update ExecPlan 111 Progress and Surprises with this plan's evidence.
- [ ] Complete ExecPlan 111 Milestone 5 (documentation, alert, close IR-5) using the corrected facts listed here.
- (The lockout-prevention plan already exists as ExecPlan 115; this milestone does not author it.)
- [ ] Author the private development repository ExecPlan with `init-plan.ts`.
- [ ] Fill in Outcomes & Retrospective and run the ADR distillation pass for both plans.
- [ ] Final report back.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

The discoveries that motivated this plan are recorded as facts in Context and Orientation. The
entries below come from a read-only validation pass on 2026-09-12 (about 18:30Z), made before
implementation began. It ran only `describe`/`list`/serial-output reads against `tan-nb-exp` and
`nix eval` locally.

- The recovery `startup-script` **never ran**. The serial console holds exactly one boot, from
  SeaBIOS to `Reached target Multi-User System`. The script redirects everything to `/dev/ttyS0`
  and prints `NAGARE-RECOVERY: begin` first, yet no `NAGARE-RECOVERY` line appears. The startup
  scripts unit also finished within a second of the guest agent starting. So the earlier claim
  "GCE startup scripts do run on this image" was an inference from the `Finished` line, and it
  was wrong. The same cause explains the unexplained failure of the earlier key-writing startup
  script. The host is therefore still on the fixture generation, and no rollback happened.
  Metadata startup scripts are not a usable recovery channel on this image.

  ```text
           Starting Google Compute Engine Startup Scripts...
           Starting SSH Daemon...
  [  OK  ] Started SSH Daemon.
  [  OK  ] Finished Google Compute Engine Startup Scripts.
  ```

- The boot disk is attached as `deviceName: persistent-disk-0` with `autoDelete: true`. The plan's
  original step 6 (`attach-disk --boot` without flags) would have reattached it as device
  `nagare-01` with auto-delete off. The Pulumi program leaves `bootDisk.deviceName` unset, so
  state holds the computed `persistent-disk-0`. In the Google provider, `boot_disk.device_name` is a
  create-time field. A refreshed preview would then plan an instance **replacement**, which
  deletion protection turns into an error. Either way, "clean preview" would become unreachable.

- Project-wide metadata sets `enable-oslogin = TRUE` and a project `ssh-keys` entry. A stock
  Debian rescue VM honors OS Login and **ignores** instance `ssh-keys`. The original step 3 would
  therefore never create the `rescue` user, and step 4 would fail. The rescue VM must set
  instance-level `enable-oslogin=FALSE`, which overrides the project value.

- The IAP firewall rule `nagare-network-fw-iap-ssh-4c46189` (source `35.235.240.0/20`, `tcp:22`)
  has **no target tags**, and `nagare-01` has no network tags. Any VM on `nagare-network-net-0da5cb7`
  is reachable over IAP, including the rescue VM. The `default-allow-ssh 0.0.0.0/0` rule belongs to
  the unrelated `default` network, so it does not expose `nagare-01`.

- Evaluating the in-repo configuration (the same sshd module the fixture generation runs) gives
  `services.openssh.authorizedKeysFiles = ["%h/.ssh/authorized_keys","/etc/ssh/authorized_keys.d/%u"]`,
  `StrictModes = true`, `system.stateVersion = "26.05"`, and `boot.loader.timeout = 0`. A key
  written to `/home/deploy/.ssh/authorized_keys` with strict permissions will therefore be
  accepted. With a zero GRUB timeout, choosing an older generation from the serial console is not
  practical. Together with no passwords (`users.mutableUsers = false`), no OS Login, and no working
  startup scripts, this confirms that the rescue-disk repair is the simplest reliable path.

- An additional failed unit appears on this boot, beyond the two recorded in Context:
  `Failed to start Extra networking commands.` (`network-local-commands.service`). Treat it as part
  of the baseline.

- (Implementation session, 2026-09-12T20:22Z) The fresh serial capture confirms both halves of the
  startup-script finding. Lines 288 and 291 show `Starting`/`Finished Google Compute Engine Startup
  Scripts`, and the log has no `NAGARE-RECOVERY` output. So the unit finishing is not evidence that a
  script ran, and the Context note built on that line was an inference. The rule in `CLAUDE.md`
  ("GCE startup scripts do not run on Nagare's NixOS image") matches the evidence.

- (Implementation session, 2026-09-12T20:27Z) Milestone 1's `gcloud compute instances remove-metadata`
  ran with **no approval prompt**, even though `.claude/hooks/guard_host_mutation.py` classifies it
  as a cloud mutation that should "ask". This matches ExecPlan 115's open item: under the operator's
  `defaultMode: "auto"`, the hook's "ask" decision does not surface a prompt. The later Path B
  mutations (stop, detach, create a VM, attach) would therefore also run unprompted in this session.

- (Implementation session, 2026-09-12T21:20Z) **Milestone 4 attempt 1 STOP: the working-tree
  ordering fix introduces a first-boot race.** The by-id udev link works (so the fallback is not
  needed), no `ordering cycle` is logged, and `systemd-growfs` resized the filesystem to 2G, so the
  cycle fix itself is proven. But Phase 0 failed at `test -d /var/lib/nagare/local-path`.
  `DefaultDependencies = false` moved `format-nagare-data` to right after `local-fs-pre.target`,
  **before udev created the by-id link**. Its `ConditionPathExists` was unmet, so it was skipped. The
  mount then tried the still-blank disk and failed, and the layout unit's dependency failed with it.
  A later format and mount retry succeeded, but the layout unit stayed failed. Under the old
  `After=basic.target`, the service ran late enough for the link to exist. On the live host the disk
  is already formatted, so the skipped format is harmless there. On a brand-new host, though, the
  first boot would come up without the data-disk layout. Log `/tmp/ep114/vmtest-attempt1.log`:

  ```text
  [13.767071] systemd[1]: Expecting device /dev/disk/by-id/google-nagare-data...
  [14.864429] systemd[1]: Format the Nagare data disk on first boot if it is blank skipped, unmet condition check ConditionPathExists=/dev/disk/by-id/google-nagare-data
  [16.666500] systemd[1]: Found device /dev/disk/by-id/google-nagare-data.
  [17.042730] mount[961]: mount: /var/lib/nagare: wrong fs type, bad option, bad superblock on /dev/vdb ...
  [17.174875] systemd[1]: Dependency failed for Create the /var/lib/nagare subdirectory layout (IP-3).
  [17.362968] format-nagare-data-start[963]: no filesystem on /dev/disk/by-id/google-nagare-data; creating ext4
  [21.950780] systemd[1]: Mounted /var/lib/nagare.
  [22.266848] systemd-growfs[1158]: Successfully resized "/var/lib/nagare" to 2G bytes.
  !!! RequestedAssertionFailed: command `test -d /var/lib/nagare/local-path` failed (exit code 1)
  ```

  Proposed fix (not applied, awaiting a human): also order `format-nagare-data` after its device
  (`wants`/`after` on `"${utils.escapeSystemdPath dataDiskDevice}.device"`), so it waits for udev
  without regaining `After=basic.target`. Then re-run the VM test once.

- (Implementation session, 2026-09-12T20:35Z) **Step 5 gate STOP: the rescue script's sshd check
  printed nothing.** On the mounted NixOS root, `/etc/ssh/sshd_config` is an absolute symlink to
  `/etc/static/ssh/sshd_config`, and `/etc/static` is itself an absolute symlink into `/nix/store`.
  Prefixing the first hop with `/mnt/nixos` still leaves a link pointing outside the mount. The
  fallback `grep -ri AuthorizedKeysFile /mnt/nixos/etc/ssh/` matched nothing, because `grep -r` does
  not follow symlinks. So the gate cannot confirm the path from this output. It is not evidence that
  the path is missing: the in-repo evaluation gave
  `authorizedKeysFiles = ["%h/.ssh/authorized_keys","/etc/ssh/authorized_keys.d/%u"]`. Everything
  else in the gate passed:

  ```text
  == passwd
  deploy:x:1000:100::/home/deploy:/run/current-system/sw/bin/bash
  == home before
  ls: cannot access '/mnt/nixos/home/deploy/.ssh': No such file or directory
  drwx------ 5 1000 100 4096 Jun 25 01:17 /mnt/nixos/home/deploy
  == home after
  drwx------ 6 1000 100 4096 Sep 12 20:34 /mnt/nixos/home/deploy
  drwx------ 2 1000 100 4096 Sep 12 20:34 /mnt/nixos/home/deploy/.ssh
  -rw------- 1 1000 100 99 Sep 12 20:34 authorized_keys
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R shinzui@sungkyung
  == sshd AuthorizedKeysFile
  grep: /mnt/nixos/etc/static/ssh/sshd_config: No such file or directory
  == active generation
  system-4-link
  RESCUE_DONE
  ```

  The proposed read-only completion of the check, pending human approval: mount the disk
  read-only, resolve each symlink hop under `/mnt/nixos` by hand (`/etc/ssh/sshd_config` ->
  `/etc/static` -> `/nix/store/...-etc/etc`), grep `AuthorizedKeysFile` in the resolved store file,
  and unmount.


## Decision Log

Record every decision made while working on the plan.

- Decision: Stop at every failed gate rather than improvise.
  Rationale: The lockout came from bypassing a guard (`scripts/host-switch.sh` refusing to run
  without `nagarectl`) and then chaining speculative recovery actions against a host that could
  not be observed. Gates with pre-written pass/fail criteria remove that failure mode.
  Date: 2026-09-12

- Decision: Remove all temporary metadata before any other change, and before any reboot.
  Rationale: The `startup-script` currently on the instance rolls the NixOS system profile back
  one generation and runs `switch-to-configuration switch` on every boot. Left in place, each
  reboot would silently walk the host further back in history.
  Date: 2026-09-12

- Decision: When the serial log does not prove that the rollback worked, go straight to a
  rescue-disk repair. Do not try another startup script.
  Rationale: One earlier startup script that wrote the key into `authorized_keys` did not restore
  access, for a reason nobody observed. Another blind boot-time script could fail the same way.
  Mounting the boot disk on a throwaway VM lets the implementer see and verify every file before
  booting the host again.
  Date: 2026-09-12

- Decision: Never switch the host with the in-repo `nixos/` flake. Only use the context-owned
  flake generated by `nagarectl host init`.
  Rationale: `nixos/hosts/nagare-01/configuration.nix` is an evaluation fixture whose only
  authorized key is a placeholder. Switching to it is what removed the operator's key.
  Date: 2026-09-12

- Decision: Apply the size increase with a full `pulumi up` only after a preview shows exactly one
  change.
  Rationale: The drift reconciliation earlier on 2026-09-12 left a clean baseline (a preview reported
  31 unchanged resources). If the preview shows exactly one change, a full `up` does exactly that
  and keeps the state tidy. Anything else in the preview is a stop condition, so a targeted apply
  is never needed to hide unexpected changes.
  Date: 2026-09-12

- Decision: Run host health checks with `sudo k3s kubectl` on the host, not with a workstation
  kubeconfig.
  Rationale: The workstation has no verified kubeconfig for this cluster, and the Kubernetes API
  would need an extra tunnel. The on-host client needs neither.
  Date: 2026-09-12

- Decision: Milestone 2 takes Path B (rescue disk). The Path A branch is kept in the text only as
  a record and is not run.
  Rationale: The validation pass found no `NAGARE-RECOVERY` lines in the serial log, which is the
  plan's own "missing log" rule for Path B. The deeper reason is that startup scripts do not run on
  this image, so no rollback could have happened. Alternatives checked and rejected as not simpler:
  another startup script (proven inert), serial-console login (no password exists, and users are
  immutable), the GRUB menu over serial (timeout is 0), and OS Login or guest-agent `ssh-keys`
  (both disabled on the host).
  Date: 2026-09-12

- Decision: Snapshot the boot disk before detaching it, and keep the snapshot until Milestone 5
  passes.
  Rationale: The rescue VM mounts the boot disk read-write. A snapshot of a stopped disk costs a
  few minutes and cents, and it makes every Path B mistake reversible. The disk also carries the
  k3s state that replacing the instance would destroy.
  Date: 2026-09-12

- Decision: Reattach the boot disk with `--device-name=persistent-disk-0`, restore
  `auto-delete`, and compare against the pre-rescue record before starting the host.
  Rationale: The live attachment is `persistent-disk-0`/`autoDelete: true`, and the gcloud defaults
  differ. A changed boot device name is create-time drift that Pulumi resolves by replacing the
  instance.
  Date: 2026-09-12

- Decision: The rescue VM sets `enable-oslogin=FALSE` and gets no service account.
  Rationale: Project metadata enables OS Login, which would stop the `ssh-keys` metadata from
  creating the `rescue` user. The rescue VM needs no Google API access, and leaving the service
  account off removes a way it could fail on IAM or organization policy.
  Date: 2026-09-12

- Decision: Sequence this plan with ExecPlan 115 (lockout prevention). Its Milestone 1 (agent
  guardrails hook) lands before Milestone 1 here, and its Milestones 2–4 land before Milestone 5
  here. Milestone 5's host switch is the first live use of the self-reverting switch.
  Rationale: The operator's direction on 2026-09-12 was that a lockout must never happen again.
  The recovery session is itself an agent session touching the host, so it should run under the
  guardrails. The first real switch after the incident should be the one that reverts itself if
  access is lost. The hook makes the cloud mutations in Milestones 1, 2, and 5 prompt for human
  approval, which is intended.
  Date: 2026-09-12

- Decision: Every "no changes" Pulumi gate uses `pulumi preview --refresh`.
  Rationale: A plain preview compares the program with the saved state, not with the live cloud,
  so it cannot see metadata edits or disk re-attachments made with gcloud, which are exactly what
  these gates exist to catch. A refresh inside `preview` is not saved to state.
  Date: 2026-09-12

- Decision: Fix the first-boot race found by attempt 1 by adding `wants`/`after` on the escaped
  by-id `.device` unit to `format-nagare-data`, assert that edge in `data-disk-auto-grow`, and run
  the VM test once more (attempt 2). Operator approved at 2026-09-12T21:25Z ("Apply fix, rerun
  once").
  Rationale: Waiting on the device unit restores the "link exists before the condition is checked"
  property that `After=basic.target` used to give by accident, without reintroducing the cycle.
  `Wants` keeps an absent disk non-fatal. Before attempt 2, the edit was evaluated
  (`after = ["local-fs-pre.target","dev-disk-by\\x2did-google\\x2dnagare\\x2ddata.device"]`) and
  every fast check and the driver build passed, so a slow run cannot fail on a typo.
  Date: 2026-09-12

- Decision: Before Milestone 5, regenerate the host flake from the committed tree by rebuilding
  `nagarectl` and running `nagarectl host init --force` with the Milestone 3 arguments. Then re-run
  the Milestone 3 key gate and the Milestone 5 evaluation gates. This replaces the plan's
  `nix flake update nagare`.
  Rationale: `nagareInput` is not a `path:` to this checkout but a `/nix/store` payload embedded in
  the `nagarectl` build, so `nix flake update` cannot pick up the new `storage.nix`. The payload
  generated in Milestone 3 predates the attempt-1 fix.
  Date: 2026-09-12

- Decision: Replace Milestone 4's builder probe with a daemon-routed build of the VM test's
  `.driver` attribute.
  Rationale: `nix store info --store ssh://builder@nix-gcp-builder` runs SSH as the operator user,
  and the builder key `/etc/nix/builder_ed25519` is readable only by the Nix daemon. So the probe
  fails even when remote builds work, and it cannot test what the gate is about. Building
  `.driver` is side-effect free, goes through the daemon to the same builder, and also lints the
  edited Python test script before the long run. (An earlier `&& echo BUILDER_OK` printed despite
  the failure because the pipeline's exit status was `tail`'s; that output was not relied on.)
  Date: 2026-09-12

- Decision: At the step 5 gate STOP, the operator chose "Skip check, go to step 6". The in-repo
  evaluation (`authorizedKeysFiles` includes `%h/.ssh/authorized_keys`) is accepted as the sshd
  evidence, and the SSH-as-`deploy` gate after step 6 is the real proof.
  Rationale: The empty output came from a symlink that cannot resolve under the mount, not from a
  config that lacks the path. The key file itself passed every check. The host is offline while it
  waits, and the post-start SSH gate tests the same thing end to end. If that gate fails, the
  plan's stop rule still applies. Operator decision, 2026-09-12T20:37Z.
  Date: 2026-09-12

- Decision: Before Milestone 2 Path B, ask the operator directly for approval, because the guard
  hook's "ask" did not prompt in this session. The operator chose "Run Path B, stop at gates",
  approving the whole Path B sequence as written, with every gate still binding.
  Rationale: `CLAUDE.md` requires human approval for each cloud-mutating command. The hook did not
  collect that approval for Milestone 1 (Surprises), and Path B takes the only production host
  offline. An explicit, recorded approval for the bounded sequence is the smallest faithful
  substitute. Approval messages from peer sessions are not accepted as that approval.
  Date: 2026-09-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Read this whole section before running anything. It assumes you know nothing about this
repository or what happened before.

### What Nagare is and how it is deployed

Nagare is a single-node personal platform-as-a-service. It runs on one Google Compute Engine
virtual machine named `nagare-01` in Google Cloud project `tan-nb-exp`, zone `us-west1-a`. That
machine runs **NixOS**, a Linux distribution whose whole system configuration is code (`.nix`
files) that gets built and then "switched to". Each switch creates a numbered **generation**, and
earlier generations remain on disk and can be reactivated. The cloud resources around the
machine (disks, network, IP address) are managed by **Pulumi**, an infrastructure-as-code tool.
Its TypeScript program lives in `infra/pulumi/`. The machine runs **k3s**, a small Kubernetes
distribution. "Single-node" means an outage of this one machine is an outage of everything.

The machine has two disks. The **boot disk**, a Compute Engine disk also named `nagare-01`,
holds NixOS and the k3s state. The **data disk**, `nagare-data-8183a3e`, is mounted at
`/var/lib/nagare` and holds application data. At the time of writing it is 100 GiB with 1.1 GiB
used.

### Which target every command acts on

The repository's operating rules (`CLAUDE.md`) require that every cloud command acts only on the
**active target context**. A context is a file of `export VAR=value` lines. The active one is
selected by the pointer file `~/.config/nagare/current-context`, which now contains `tan-nb-exp`
and refers to `~/.config/nagare/contexts/tan-nb-exp.env`. Sourcing `scripts/lib/target.sh`
resolves the context and exports `CLOUDSDK_CORE_PROJECT`, `CLOUDSDK_COMPUTE_ZONE`,
`NAGARE_CONTEXT`, `PULUMI_BACKEND_URL`, `PULUMI_HOME`, and related variables. Every command block
in this plan that touches the cloud starts with:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
```

If that prints `WRONG TARGET`, stop. A repository file `nagare.local.env` also exists. It is a
lower-precedence local-mode profile, and the context takes priority over it. Do not delete it in
this plan.

The context file `tan-nb-exp.env` deliberately leaves `NAGARE_ACME_EMAIL` empty, following
[ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md): Nagare refuses to invent an
ACME contact. Nothing in this plan renders the ACME issuer, so leave it empty.

### Pulumi state: where it lives and what was changed

Until 2026-09-12 the live stack's state sat inside the git working tree at
`infra/pulumi/.pulumi-state` (git-ignored), as a stack named `dev`. It was exported, its
resource identifiers (URNs) were renamed from `dev` to `tan-nb-exp`, and it was imported into the
context's backend at `file:///Users/shinzui/.local/state/nagare/tan-nb-exp/state` as stack
`tan-nb-exp`. It holds 22 resources. The original directory, together with the old
`Pulumi.dev.yaml`, was moved to
`/Users/shinzui/.local/state/nagare/tan-nb-exp/legacy-in-repo-state-20260912T174602Z`. Do not
delete that archive in this plan.

The stack configuration file is `infra/pulumi/Pulumi.tan-nb-exp.yaml`, which is git-ignored. It
now pins two values so that the code matches the running VM: `nagare:bootDiskType: pd-standard`
and `nagare:nagareImageSelfLink` set to
`https://www.googleapis.com/compute/beta/projects/tan-nb-exp/global/images/nagare-image-s04l9dg8rc01`.
Without those two values the program's defaults (`pd-balanced` and a newer image) force Pulumi
to **replace** the instance, which means destroying and recreating the VM along with the k3s state on
its boot disk. With them in place, a `pulumi up` on 2026-09-12 applied 12 additive creates,
3 in-place updates, and 2 deletes (a stale pseudo-resource and a renamed IAM grant). A
follow-up preview reported `31 unchanged`. That same apply wrote `protect: true` into state for
the data disk, removed the `enable-oslogin` metadata key, and turned on instance deletion
protection. Keys `nagare:dataDiskSizeGb` and `nagare:bootDiskSizeGb` are unset, so both default
to 100.

Recorded preview facts that ExecPlan 111's documentation must use (verbatim excerpts):

```text
# dataDiskSizeGb 100 -> 110: in-place update, no replacement
    ~ gcp:compute/disk:Disk: (update) 🔒
        [id=projects/tan-nb-exp/zones/us-west1-a/disks/nagare-data-8183a3e]
      ~ size: 100 => 110

# dataDiskSizeGb 100 -> 50, BEFORE protect was in state: planned a replacement, no error
    +-gcp:compute/disk:Disk: (replace) 🔒
      ~ size  : 100 => 50

# dataDiskSizeGb 100 -> 50, AFTER protect was written to state: fails closed, exit 1
error: unable to replace resource "urn:pulumi:tan-nb-exp::nagare::nagare:env:NagarePerimeter$gcp:compute/disk:Disk::nagare-data"
as it is currently marked for protection. To unprotect the resource, remove the `protect` flag from the resource in your Pulumi program and run `pulumi up`
error: preview failed

# bootDiskSizeGb 100 -> 110: the size lives in bootDisk.initializeParams, and the diff shows it inside
# an instance REPLACE (that preview was confounded by then-present image/type drift, but
# initializeParams is create-time-only, so a boot-disk size change forces instance replacement)
    +-gcp:compute/instance:Instance: (replace)
          ~ initializeParams: { ~ size : 100 => 110 }
```

The lesson for the documentation: `protect: true` in code only protects a resource once a
`pulumi up` has written it into state. A stack created before the flag existed is unprotected
until then.

### How the lockout happened, and the current state of the host

Host changes are meant to be applied with `just host-switch`, which runs
`scripts/host-switch.sh`. That script asks `nagarectl host path` for the **context-owned host
flake**: a directory under `~/.config/nagare/hosts/<context>/` generated by `nagarectl host init`
that carries the operator's real SSH keys ([ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)).
`nagarectl` was not on `PATH`, so the script refused to run. The previous session worked around
the refusal by running `nixos-rebuild switch --flake ./nixos#nagare-01`. That target is the
repository's **evaluation fixture**. Its `nixos/hosts/nagare-01/configuration.nix` authorizes
only `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly`. The switch removed
the operator's key (`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R shinzui@sungkyung`,
file `~/.ssh/id_ed25519.pub`), and SSH as `deploy` now fails with `Permission denied (publickey)`.

The recovery attempts left these changes, all still in place when this plan was written:

1. Instance metadata `startup-script` holds a script (the second of two). On boot it logs to the
   serial console with lines prefixed `NAGARE-RECOVERY:`, repoints
   `/nix/var/nix/profiles/system` to the second-newest generation, and runs
   `switch-to-configuration switch`. It was meant to run on every boot. The instance was stopped
   and started after it was added. **The validation pass proved that it never ran.** The only boot
   in the serial log has no `NAGARE-RECOVERY` output (see Surprises & Discoveries). The host is
   still on the fixture generation. The key is removed anyway, so that a future image that does
   run startup scripts cannot pick it up.
2. Instance metadata `ssh-keys` = `deploy:<operator key>`. It has no effect, because this
   NixOS build does not use the guest agent's key management.
3. Instance metadata `enable-oslogin=TRUE`. It has no effect, because OS Login is **disabled** in
   the NixOS configuration (`security.googleOsLogin.enable = false`, verified by evaluation). The
   operator's key was also registered to their Google OS Login profile; that is harmless.

GCE metadata startup scripts do **not** run on this image. The serial console shows
`Finished Google Compute Engine Startup Scripts`, but no output from the script, which writes to
the serial port. Do not use startup scripts for recovery.

Other facts the rescue path depends on, all verified on 2026-09-12. The boot disk is attached as
device `persistent-disk-0` with auto-delete on, and the data disk as `nagare-data` with auto-delete
off. The project-wide metadata sets `enable-oslogin=TRUE`. The IAP SSH firewall rule on
`nagare-network-net-0da5cb7` has no target tags, so it admits any VM on that network. The host's
sshd reads `%h/.ssh/authorized_keys` as well as `/etc/ssh/authorized_keys.d/%u`, with
`StrictModes` on.

Two systemd units failed during the accidental switch: `resolvconf.service` and
`tailscaled-autoconnect.service`. The current boot also shows `network-local-commands.service`
("Extra networking commands") failing. The second fails because `/run/secrets/tailscale/authkey` is
missing, and that has been true since before any of this: the host's sops age key is absent. Treat
failed units as a **baseline** to record, not something to fix here.

### SSH to the host: the tunnel mechanics

The VM has no public SSH. Connections go through Google's Identity-Aware Proxy (IAP). On macOS,
`gcloud compute ssh --tunnel-through-iap` is broken, so the repository ships
`scripts/iap-ssh.sh`. `scripts/iap-ssh.sh ssh nagare-01 -- <command>` runs a command as `deploy`,
opening and closing a tunnel itself. `scripts/iap-ssh.sh tunnel nagare-01 22 <localport>` opens a
long-lived tunnel and prints its PID. Stop a tunnel only with `kill <that PID>`. **Never use
`pkill -f start-iap-tunnel`.** The Nix remote builder `nix-gcp-builder` also reaches its machine
through an IAP tunnel, and a blanket kill breaks builds. That happened on 2026-09-12. A stray
tunnel from the previous session was listening on local port 2223 (PID 41469 at the time of
writing).

### The data-disk grow and the ordering-cycle bug

ExecPlan 111 added `autoResize = true` to the `/var/lib/nagare` mount in
`nixos/hosts/nagare-01/storage.nix` (committed as `489daf3`). NixOS turns that into the mount
option `x-systemd.growfs`. systemd then runs `systemd-growfs@var-lib-nagare.service` after
mounting, which grows the ext4 filesystem to fill its device while it stays mounted.

A NixOS virtual-machine test revealed that **as committed in `489daf3` the grow never happens**.
The same file defines `format-nagare-data.service`, a oneshot ordered before the mount. Like every
service with default dependencies, it is implicitly ordered after `basic.target`. The growfs unit
makes `local-fs.target` wait for the mount. Together these form a loop: `local-fs.target` →
growfs → mount → `format-nagare-data` → `basic.target` → `sysinit.target` → `local-fs.target`.
systemd resolves such a loop by deleting a job, and it deleted the grow. Test log evidence:

```text
systemd[1]: dbus.socket: Found ordering cycle: sysinit.target/start after local-fs.target/start after systemd-growfs@var-lib-nagare.service/start after var-lib-nagare.mount/start after format-nagare-data.service/start after basic.target/start after sockets.target/start after dbus.socket/start - after sysinit.target
systemd[1]: systemd-growfs@var-lib-nagare.service: Job systemd-growfs@var-lib-nagare.service/start failed with result 'dependency'.
```

The fix is already in the **working tree, uncommitted and untested**. In `storage.nix`,
`format-nagare-data` now sets `unitConfig.DefaultDependencies = false`,
`after = [ "local-fs-pre.target" ]`, and `conflicts = [ "shutdown.target" ]`, with a comment
explaining the cycle. Milestone 4 proves the fix and commits it. Do not switch any host to a
configuration lacking this fix.

### The virtual-machine test and its two known traps

`nixos/flake.nix` defines `checks.x86_64-linux.data-disk-online-grow`, a
`pkgs.testers.runNixOSTest` test. It boots a QEMU virtual machine from a NixOS configuration and
drives it from a Python script. In the working tree it imports the real `storage.nix`, attaches a
2 GiB scratch disk (`virtualisation.emptyDiskImages = [ 2048 ]`, which appears as `/dev/vdb`), and
runs three phases. Phase 0 checks that a blank disk gets formatted and mounted. Phase 1 writes a
1 GiB ext4 filesystem onto the 2 GiB device (bit-for-bit the state after a disk-size increase),
reboots, and asserts the filesystem is larger than 1.5 GiB. Phase 2 repeats that setup on the
running machine and asserts that `systemctl start systemd-growfs@var-lib-nagare.service` grows it.
Each phase prints `df -h` prefixed `PHASE 0` / `PHASE 1` / `PHASE 2`.

Trap one, already handled in the working tree: the QEMU test module replaces the whole
`fileSystems` option with `virtualisation.fileSystems`. Importing `storage.nix` alone therefore
drops the data-disk mount without any warning. The test copies the shipped definition across
(`virtualisation.fileSystems."/var/lib/nagare" = { inherit (dataFs) device fsType options autoResize; };`,
where `dataFs` is read from the evaluated real host configuration).

Trap two, not yet resolved: `storage.nix` expects `/dev/disk/by-id/google-nagare-data`, which
only exists on GCP. An earlier run using a udev rule `KERNEL=="vdb", SYMLINK+=...` never produced
the link. A hand-made `ln` does not work either, because systemd needs a udev-backed `.device`
unit and waits for it until timeout. The working tree now uses
`SUBSYSTEM=="block", KERNEL=="vdb", SYMLINK+="disk/by-id/google-nagare-data"`, and whether that
works is unproven. Milestone 4 runs it with diagnostics and has one pre-specified fallback.

The test needs an `x86_64-linux` builder with KVM. The workstation (aarch64-darwin) sends the
build to `ssh://builder@nix-gcp-builder` automatically. One run takes roughly 8–12 minutes.

The working tree's `nixos/flake.nix` also contains `checks.x86_64-linux.data-disk-auto-grow`, an
evaluation-only check committed in `489daf3`, and the pre-existing `forge-credentials-module`
check. All checks live inside one `checks.${system} = { ... };` set, because Nix refuses to merge
two separate `checks.${system}.<name>` attribute paths when `${system}` is dynamic.

### nagarectl

`nagarectl` is Nagare's Haskell command-line tool. It is packaged in the root `flake.nix` as
`packages.<system>.nagarectl`, and building it compiles three derivations (`nix build .#nagarectl`).
`nagarectl host init --context NAME --ssh-public-key-file PATH --sops-file PATH` generates the
context-owned host flake at `~/.config/nagare/hosts/NAME/` (`flake.nix`, `host.nix`,
`secrets.yaml`, `flake.lock`). With `--dry-run` it writes nothing and prints the configuration,
including a line `nagareInput: path:<dir>`. The generated `flake.nix` pins the platform modules
through `inputs.nagare.url = "path:<dir>"` (source: `cli/nagarectl/src/Nagare/Host/Config.hs`).
**That `<dir>` decides which `storage.nix` the host gets**, which is why Milestone 5 gates on
evaluating the generated flake. The encrypted secrets file this host has always used is the
tracked `nixos/hosts/nagare-01/secrets/nagare-01.yaml`.

### Architecture Decision Records consulted

`docs/adr/` is a plain filesystem convention (`NNNN-slug.md`, frontmatter `title`, `status`,
`date`, `authors`, `related`, heading `# ADR N — Title`), not an OKF bundle.
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) says operator
inputs such as SSH keys live in the context-owned generated flake while reusable behavior ships in
the platform modules. It is the rule the lockout violated.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) says
`nagarectl platform guard` blocks mutation when versions drift. If it blocks here, stop; do not
bypass it with `NAGARE_UPGRADE_APPLY`.
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) says every
cloud-mutating path asserts the active context's project, which is why every cloud block begins
with the target check. [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md) covers
the empty ACME email noted above.

### Reporting back

The work will run in a new Claude Code session. The coordinating session that wrote this plan is
named `nagare-62`. At the end of every milestone, and immediately at any failed gate, the
implementing session must first update this plan file, which is the authoritative record, and
then send a short message to `nagare-62` with the SendMessage tool. The message covers the
milestone, PASS or STOP, the gate output (a few lines), and what comes next. If `nagare-62` no
longer exists, the plan file alone is the report. On STOP, do not continue to the next milestone
until a human replies.


## Plan of Work

### Milestone 0 — Read-only preflight

This milestone changes nothing. It establishes the target, clears only this plan's own local
tunnel ports, and reads the serial console. Milestone 2's choice of path depends on that log.

Confirm the target with the target check from Context and Orientation. Next, list local listeners
on ports 2222 and 2223 with `lsof -nP -iTCP:2222 -iTCP:2223 -sTCP:LISTEN`. For each, confirm with
`ps -o pid,command -p <PID>` that it is a `gcloud ... start-iap-tunnel` (the listed command may
show as `python3`) whose arguments include `nagare-01`, and `kill <PID>`. Leave every other tunnel
alone. Then run
`gcloud compute instances describe nagare-01 --format='value(status)'` and
`gcloud compute instances describe nagare-01 --format='value(metadata.items[].key)'`. Finally
save the serial console to a file and extract the recovery lines.

The gate is informational. Record verbatim the status, the metadata keys, and every
`NAGARE-RECOVERY` line, plus any lines mentioning `/home/deploy`, `authorized_keys.d`, or
`deploy:`.

### Milestone 1 — Stabilize

Remove the three temporary metadata keys in one command. The `startup-script` key goes first in
importance: it changes the host on every boot. After this milestone no reboot can change the host
except through a normal NixOS generation. Removing `enable-oslogin` also restores what Pulumi
declares (the program sets no metadata), so the stack has no drift.

Gate 1: `describe` lists none of `startup-script`, `ssh-keys`, `enable-oslogin`. Gate 2:
`pulumi preview --refresh` ends with a resource summary containing only `unchanged` and no
`create`/`update`/`delete`/`replace` lines. If Gate 2 shows changes, stop and report them verbatim.

### Milestone 2 — Restore SSH access

**The choice is already made: Path B.** The validation pass on 2026-09-12 found no
`NAGARE-RECOVERY` lines, because startup scripts do not run on this image (Surprises &
Discoveries). The rule is kept below for the record. **Path A** would have applied only if the
Milestone 0 log contained all three of: `NAGARE-RECOVERY: switch rc=0`, `NAGARE-RECOVERY: done`,
and a following line beginning `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yz`. In every other case,
including a missing log, Path B applies. If a fresh Milestone 0 serial capture somehow contradicts
the validation pass, stop and report instead of choosing again.

Path A: run `scripts/iap-ssh.sh ssh nagare-01 -- 'echo SSH_OK; hostname; sudo -n true && echo SUDO_OK'`.
Gate: the output contains `SSH_OK`, `nagare-01`, `SUDO_OK`. If Path A's gate fails, switch to
Path B. Do not attempt anything else.

Path B, the rescue-disk repair, is fully specified in Concrete Steps. In outline: stop `nagare-01`,
snapshot its boot disk, detach it, and attach it to a temporary Debian VM `nagare-rescue` on the
same subnet. The IAP firewall rule has no target tags, so it admits the rescue VM. The rescue VM
sets `enable-oslogin=FALSE` in its own metadata, because the project-wide `enable-oslogin=TRUE`
would otherwise ignore the `ssh-keys` entry that creates its `rescue` login user. Mount the NixOS root
partition, read `deploy`'s numeric uid and gid from the mounted `/etc/passwd`, and write the real
key to the mounted `/home/deploy/.ssh/authorized_keys`, owned by that uid/gid with modes 700 on
the directory and 600 on the file. Confirm that the mounted `/home/deploy` is owned by `deploy`
and not group- or world-writable, and that the mounted sshd config's `AuthorizedKeysFile`
includes `%h/.ssh/authorized_keys`. Print all of it and record it. If "home before" already
shows the real key in `authorized_keys` with correct ownership and modes, the key file is not the
problem: stop and report rather than reattach. Then unmount, detach, and delete the rescue VM.
Reattach the disk to `nagare-01` as its boot disk under its original device name
`persistent-disk-0`, turn auto-delete back on, confirm the attachments match the pre-rescue
record, and start the host. This works no
matter which NixOS generation is active, because NixOS activation does not manage
`~/.ssh/authorized_keys`. Gates: SSH as in Path A, then a `pulumi preview --refresh` with no
changes. The rescue VM is created outside Pulumi and must be gone at the end; verify with
`gcloud compute instances list`. The snapshot `nagare-01-pre-rescue-20260912` stays until
Milestone 5 passes and is deleted in Milestone 5 teardown.

On either path, once SSH works, record a baseline: `systemctl --failed --no-legend --plain`
output, `readlink /nix/var/nix/profiles/system`, and `grep nagare /etc/fstab`.

### Milestone 3 — Generate the context-owned host configuration

Build `nagarectl` from the root flake and put its `bin` directory first on `PATH` for this and
later milestones. Run `nagarectl context show` and confirm it names `tan-nb-exp`. Run
`nagarectl host init` as a dry run with `--ssh-public-key-file ~/.ssh/id_ed25519.pub` and record
the output, in particular the `nagareInput: path:` line. Then run it for real with
`--sops-file nixos/hosts/nagare-01/secrets/nagare-01.yaml`. Then run `nagarectl host path` and
`nagarectl host show`.

Gate: evaluating the generated flake's
`nixosConfigurations.nagare-01.config.users.users.deploy.openssh.authorizedKeys.keys` returns a
list that contains `AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R` and
does not contain `FixtureKeyForNagareEvaluationOnly`. If `host init` refuses, for example over
platform version or a missing input, stop and report its exact message.

### Milestone 4 — Prove and commit the ordering-cycle fix

First extend the cheap evaluation check so the fix cannot regress unnoticed. In `nixos/flake.nix`,
inside `data-disk-auto-grow`, add
`assert compatibilitySystem.config.systemd.services.format-nagare-data.unitConfig.DefaultDependencies == false;`
next to the other asserts. Build it (see Concrete Steps).

Then change the VM test so that one run either passes or explains exactly why it failed. At the
top of the test script, before Phase 0, add a diagnostics block that uses `machine.execute`
(never fails) to print `ls -l /dev/disk/by-id/`, `cat /etc/udev/rules.d/99-local.rules`, and
`udevadm info --query=symlink --name=/dev/vdb`. Then add
`machine.wait_until_succeeds("test -e /dev/disk/by-id/google-nagare-data", timeout=120)`. Right
after each `wait_for_unit("multi-user.target")`, add the no-cycle assertion
`machine.fail("journalctl -b --no-pager | grep -q 'ordering cycle'")`. That assertion is what
proves the bug is fixed.

Check that the builder is reachable, then run attempt 1. Decide from the log.

If attempt 1 passes, the gate is met. If it fails at the `wait_until_succeeds` on the by-id link,
apply the **one** fallback and run attempt 2. The fallback changes only the test node. In the
mirrored mount, replace `inherit (dataFs) device fsType options autoResize;` with
`device = "/dev/vdb"; inherit (dataFs) fsType options autoResize;`. Delete the `udev.extraRules`
block and the `wait_until_succeeds` line. At the start of the test script, before Phase 0, add
`machine.succeed("mkfs.ext4 -F -L nagare-data /dev/vdb")` followed by
`machine.succeed("systemctl start var-lib-nagare.mount")`. Keep Phase 0's `wait_for_unit` of the
mount. With this fallback `format-nagare-data` skips itself (its path condition is unmet), but its
ordering edges still exist, so the no-cycle assertion still tests the fix, and Phases 1 and 2
still test the grow. Record in the Decision Log that the fallback was used and why.

If attempt 1 fails for any other reason, or attempt 2 fails at all, stop and report.

Gate: the build exits 0 and the log contains `PHASE 0`, `PHASE 1`, `PHASE 2` `df` blocks, with
Phases 1 and 2 showing a size above 1.5G (about `2.0G`). Commit `nixos/hosts/nagare-01/storage.nix`,
`nixos/flake.nix`, and this plan file, staged by explicit path.

### Milestone 5 — Live grow on nagare-01

First confirm that the host configuration about to be applied contains the fix. If the Milestone 3
`nagareInput` directory is not this checkout's `nixos/` directory, or the evaluation below does
not show both properties, stop and report. Do not edit the generated flake's input by hand. Both
properties must hold:
`fileSystems."/var/lib/nagare".options` contains `x-systemd.growfs`, and
`systemd.services.format-nagare-data.unitConfig.DefaultDependencies` is `false`. If the input is a
`path:` to this checkout, the generated `flake.lock` may pin an older snapshot, so run
`nix flake update nagare` in the generated host directory once and re-evaluate before deciding.

`scripts/host-switch.sh` targets `deploy@nagare-01` and normally reaches it over Tailscale, which
is down on this host. So open an IAP tunnel on local port 2222 and add a clearly marked temporary
`Host nagare-01` block to `~/.ssh/config` that points at `127.0.0.1:2222`. Verify with
`ssh nagare-01 true`. Then run `just host-switch` (it requires `nagarectl` on `PATH`). By this
point ExecPlan 115 has replaced the script's raw `nixos-rebuild switch` with a self-reverting
switch. It refuses a configuration that lacks the operator's key, activates without changing the
boot default, verifies with a fresh SSH login, and prints `COMMITTED` only then. Pre-existing
failed units no longer decide the outcome; the fresh-login verification does. If it prints
`NOT COMMITTED`, stop. The host reverts by itself within the confirmation window (600 seconds).
Wait for it, confirm SSH, and report.

Gates after the switch: `systemctl --failed --no-legend --plain` lists no unit that is not in the
Milestone 2 baseline; `journalctl -b --no-pager | grep -i 'ordering cycle'` prints nothing new
since the switch (use `--since` with the switch start time); `grep nagare /etc/fstab` contains
`x-systemd.growfs`; and `ssh nagare-01 true` still works, which proves the switch kept the key.
If SSH fails after the switch, stop and report. The fixed Path B in Milestone 2 is the recovery.

Record the "before" `df -h /var/lib/nagare` and `lsblk /dev/sdb`. Set
`nagare:dataDiskSizeGb` to `110` and preview. Gate: the preview's summary is exactly
`~ 1 to update` with `1 change`, and the only changed resource is
`gcp:compute/disk:Disk` with `~ size: 100 => 110`. Anything else: stop, run
`pulumi config rm nagare:dataDiskSizeGb`, and report. On pass, run `pulumi up --yes`. Record
`df -h /var/lib/nagare`, which should still show about 98G, and `lsblk /dev/sdb`, which should
show 110G. That contrast is the documented gap. Run
`sudo systemctl start systemd-growfs@var-lib-nagare.service` and record `df -h` again, which
should show about 108G. Health gate: `sudo k3s kubectl get nodes` shows `Ready`, and the command
listing pods not in `Running`/`Succeeded` shows nothing that was not already failing before the
switch. Take a snapshot of that list before `just host-switch` and compare. Finally kill the
tunnel by its PID and remove the SSH config block.

### Milestone 6 — Hand back to ExecPlan 111 and author the private-repo plan

Update [ExecPlan 111](111-automate-and-document-growing-the-data-disk.md): check off its
Milestone 2 (VM test), Milestone 3 (previews, using the recorded facts in Context and Orientation
above), and Milestone 4 (live grow, using this plan's transcripts) with timestamps and pointers
to this plan. Add the ordering-cycle bug, the QEMU `fileSystems` override, the stale-`protect`
finding, the state migration, and the lockout to its Surprises & Discoveries. Then complete
ExecPlan 111's Milestone 5 as written there, with these corrections that its original text did
not know about:

- The documentation must say that raising `bootDiskSizeGb` forces instance replacement, which is
  not an in-place update.
- It must say that `protect: true` only protects once written to state by a `pulumi up`.
- The manual grow command is `sudo systemctl start systemd-growfs@var-lib-nagare.service`.
- Host changes must go through `just host-switch` with the context-owned flake.

Close IR-5 as ExecPlan 111 specifies.

Then author the private development repository plan with
`bun .claude/skills/exec-plan/init-plan.ts --title "Move operator-private deployment material into a private development repository" --model <your model> --harness claude-code --intention intention_01m2av9m0ge8sbwjy4arw5svf9`,
and write it in full under `PLANS.md`. The user's direction, recorded 2026-09-12: this repository
is only for open-source development of Nagare; a new **private GitHub repository** will hold
operator development material going forward, and that plan moves the Pulumi state there. The plan
must begin with an inventory, not a guess, of operator-private material currently in or around
this repository. Candidates to check include the `tan-nb-exp` context and its Pulumi backend and
archive, `infra/pulumi/Pulumi.*.yaml`, the tracked encrypted `nixos/hosts/nagare-01/secrets/nagare-01.yaml`,
`nagare.local.env`, and `~/.config/nagare/nagare-01-age-key.txt`. It must choose a Pulumi backend
that a git repository can hold safely; state files contain secrets, so decide between an encrypted
file backend and the supported `gcs` backend and record why. Creating the GitHub repository is an
outward-facing action, so that plan must require explicit user confirmation before
`gh repo create`. This milestone only authors the plan; it does not create the repository.

Finish with Outcomes & Retrospective and the ADR distillation pass. The candidate durable statement
is "day-2 host switches must use the context-owned flake; the in-repo `nixos/` flake is an
evaluation fixture and must never be switched onto a real host". If recorded, it should probably
amend ADR 5 rather than create a new ADR.


## Concrete Steps

Working directory for everything is `/Users/shinzui/Keikaku/bokuno/nagare` unless stated. The
target check block from Context and Orientation is abbreviated below as `TARGET_CHECK`. Always run
it literally at the start of any shell that touches the cloud.

### Milestone 0

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
lsof -nP -iTCP:2222 -iTCP:2223 -sTCP:LISTEN
# for each PID shown: ps -o pid,command -p <PID>   then, only if it is an IAP tunnel to nagare-01: kill <PID>
gcloud compute instances describe nagare-01 --format='value(status)'
gcloud compute instances describe nagare-01 --format='value(metadata.items[].key)'
mkdir -p /tmp/ep114
gcloud compute instances get-serial-port-output nagare-01 > /tmp/ep114/serial-m0.txt 2>/dev/null
grep -aE 'NAGARE-RECOVERY|/home/deploy|authorized_keys.d|^deploy:|ssh-ed25519' /tmp/ep114/serial-m0.txt
```

Expected: status `RUNNING`; keys include `startup-script`, `ssh-keys`, `enable-oslogin` (and
possibly others, which you should record). The serial output buffer is limited. If no
`NAGARE-RECOVERY` lines appear, that is the "missing log" case, and it means Path B.

### Milestone 1

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
gcloud compute instances remove-metadata nagare-01 --keys=startup-script,ssh-keys,enable-oslogin
gcloud compute instances describe nagare-01 --format='value(metadata.items[].key)'
pulumi -C infra/pulumi preview --refresh --stack "$NAGARE_CONTEXT" --diff 2>&1 | tail -8
```

`--refresh` makes the preview read the live resources first; a preview never saves that refresh
to state. Expected tail: a `Resources:` block with a single `NN unchanged` line and no `to create`,
`to update`, `to delete`, or `to replace` lines. The `warning: using pulumi-language-nodejs from $PATH`
line is normal. If `infra/pulumi/node_modules` is missing, run `npm ci` in `infra/pulumi` first.

### Milestone 2, Path A

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
scripts/iap-ssh.sh ssh nagare-01 -- 'echo SSH_OK; hostname; sudo -n true && echo SUDO_OK'
```

### Milestone 2, Path B (rescue disk)

Every command here runs after `TARGET_CHECK`. Record the output of each numbered step.

```bash
# 1. Facts needed to recreate attachments exactly.
gcloud compute instances describe nagare-01 \
  --format='yaml(disks[].source,disks[].deviceName,disks[].boot,networkInterfaces[0].subnetwork,tags.items)' \
  | tee /tmp/ep114/nagare-01-before-rescue.yaml
gcloud compute instances describe nagare-01 --format='yaml(disks[].deviceName,disks[].autoDelete,disks[].boot)' \
  | tee /tmp/ep114/disks-before.yaml
# Expect (verified 2026-09-12): boot disk source .../disks/nagare-01 with deviceName persistent-disk-0 and
# autoDelete true; data disk deviceName nagare-data with autoDelete false. If the boot deviceName differs,
# use the recorded value everywhere step 6 says persistent-disk-0.

# 2. Stop the host and snapshot the boot disk (it is about to be mounted read-write elsewhere).
gcloud compute instances stop nagare-01
gcloud compute disks snapshot nagare-01 --snapshot-names=nagare-01-pre-rescue-20260912
gcloud compute snapshots describe nagare-01-pre-rescue-20260912 --format='value(status)'   # must print READY
# Then detach ONLY the boot disk. Never touch the data disk.
gcloud compute instances detach-disk nagare-01 --disk=nagare-01

# 3. Create the rescue VM on the same subnet, with no public IP, then attach the boot disk.
#    enable-oslogin=FALSE overrides the project-wide TRUE; without it the ssh-keys entry is ignored and
#    no `rescue` user exists. The IAP firewall rule has no target tags, so no tags are needed.
SUBNET=$(gcloud compute instances describe nagare-01 --format='value(networkInterfaces[0].subnetwork)')
gcloud compute instances create nagare-rescue --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --subnet="$SUBNET" --no-address --no-service-account --no-scopes \
  --metadata="enable-oslogin=FALSE,ssh-keys=rescue:$(cat ~/.ssh/id_ed25519.pub)"
gcloud compute instances attach-disk nagare-rescue --disk=nagare-01 --device-name=nagare-boot

# 4. On the rescue VM (the SSH user is `rescue`, created by Debian's guest agent from the ssh-keys metadata).
SSH_USER=rescue scripts/iap-ssh.sh ssh nagare-rescue -- 'lsblk -o NAME,SIZE,LABEL,FSTYPE; ls -l /dev/disk/by-id/ | grep nagare-boot'
```

In step 4's output, identify the ext4 partition on the `nagare-boot` disk whose label is `nixos`
(the GCE NixOS image labels its root filesystem `nixos`). Use `/dev/disk/by-label/nixos` below.
If no `nixos` label exists, stop and report the `lsblk` output.

```bash
# 5. Mount, inspect, repair, verify — write the script locally, copy it, run it.
#    (iap-ssh.sh retries transient failures, so piping a script on stdin is unsafe: a retry gets empty stdin.)
cat > /tmp/ep114/rescue.sh <<'RESCUE'
set -euo pipefail
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R shinzui@sungkyung'
mkdir -p /mnt/nixos && mount /dev/disk/by-label/nixos /mnt/nixos
R=/mnt/nixos
echo "== passwd"; grep '^deploy:' $R/etc/passwd
UID_=$(awk -F: '$1=="deploy"{print $3}' $R/etc/passwd); GID_=$(awk -F: '$1=="deploy"{print $4}' $R/etc/passwd)
echo "== home before"; ls -lnd $R/home/deploy $R/home/deploy/.ssh 2>&1 || true; ls -ln $R/home/deploy/.ssh 2>&1 || true
chmod go-w $R/home/deploy
install -d -o "$UID_" -g "$GID_" -m 0700 $R/home/deploy/.ssh
printf '%s\n' "$KEY" > $R/home/deploy/.ssh/authorized_keys
chown "$UID_:$GID_" $R/home/deploy/.ssh/authorized_keys && chmod 0600 $R/home/deploy/.ssh/authorized_keys
echo "== home after"; ls -lnd $R/home/deploy $R/home/deploy/.ssh; ls -ln $R/home/deploy/.ssh; cat $R/home/deploy/.ssh/authorized_keys
echo "== sshd AuthorizedKeysFile"; CFG=$(readlink $R/etc/ssh/sshd_config); case "$CFG" in /*) grep -i AuthorizedKeysFile "$R$CFG" || grep -ri AuthorizedKeysFile "$R/etc/ssh/" ;; *) grep -i AuthorizedKeysFile "$R/etc/ssh/$CFG" ;; esac || true
echo "== active generation"; readlink $R/nix/var/nix/profiles/system
sync; umount $R; echo RESCUE_DONE
RESCUE
SSH_USER=rescue scripts/iap-ssh.sh scp /tmp/ep114/rescue.sh nagare-rescue:/tmp/rescue.sh
SSH_USER=rescue scripts/iap-ssh.sh ssh nagare-rescue -- 'sudo bash /tmp/rescue.sh'
```

Gate for step 5: the output ends with `RESCUE_DONE`; "home after" shows `.ssh` as `drwx------`
and `authorized_keys` as `-rw-------`, both owned by deploy's uid; `/home/deploy` has no group or
world write bit; and the `AuthorizedKeysFile` line mentions `%h/.ssh/authorized_keys` or
`.ssh/authorized_keys`. If the sshd config does not include that path, stop and report. Also stop
and report if "home before" already showed the real key in `authorized_keys` with the right owner
and modes: that would mean the key file was never the problem. Do not reattach yet.

```bash
# 6. Put everything back, restoring the ORIGINAL boot device name and auto-delete flag.
#    A different boot device name is create-time drift that Pulumi resolves by replacing the instance.
gcloud compute instances detach-disk nagare-rescue --disk=nagare-01
gcloud compute instances delete nagare-rescue --quiet
gcloud compute instances attach-disk nagare-01 --disk=nagare-01 --boot --device-name=persistent-disk-0
gcloud compute instances set-disk-auto-delete nagare-01 --disk=nagare-01 --auto-delete
gcloud compute instances describe nagare-01 --format='yaml(disks[].deviceName,disks[].autoDelete,disks[].boot)' \
  > /tmp/ep114/disks-after.yaml
diff /tmp/ep114/disks-before.yaml /tmp/ep114/disks-after.yaml && echo DISKS_MATCH   # gate: DISKS_MATCH, else STOP (host still stopped)
gcloud compute instances start nagare-01
gcloud compute instances list --format='value(name,status)'   # nagare-rescue must be gone
```

Boot takes a few minutes. Poll SSH with a bounded loop rather than guessing:

```bash
for i in $(seq 1 20); do
  scripts/iap-ssh.sh ssh nagare-01 -- 'echo SSH_OK; hostname; sudo -n true && echo SUDO_OK' && break
  sleep 30
done
```

Then gate on `pulumi preview --refresh` exactly as in Milestone 1. If the preview shows a change
to the instance's boot disk attachment, stop and report. Do not apply it.

Baseline, on either path:

```bash
scripts/iap-ssh.sh ssh nagare-01 -- 'systemctl --failed --no-legend --plain; readlink /nix/var/nix/profiles/system; grep nagare /etc/fstab; sudo k3s kubectl get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded'
```

### Milestone 3

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nix build .#nagarectl -o /tmp/ep114/nagarectl
export PATH=/tmp/ep114/nagarectl/bin:$PATH
nagarectl --version
nagarectl context show
nagarectl host init --context tan-nb-exp --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" --dry-run
nagarectl host init --context tan-nb-exp --ssh-public-key-file "$HOME/.ssh/id_ed25519.pub" \
  --sops-file nixos/hosts/nagare-01/secrets/nagare-01.yaml
HOSTDIR=$(nagarectl host path --context tan-nb-exp); echo "$HOSTDIR"
nagarectl host show --context tan-nb-exp
nix eval --json "path:$HOSTDIR#nixosConfigurations.nagare-01.config.users.users.deploy.openssh.authorizedKeys.keys"
```

Gate: the final JSON contains `AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R`
and not `FixtureKeyForNagareEvaluationOnly`. If the attribute name `nagare-01` does not exist,
read the `nixosConfigurations.` line in `$HOSTDIR/flake.nix` and use that name. If the name is
different, record it, because `scripts/host-switch.sh` uses `NAGARE_HOST_ATTR` or the instance
name.

### Milestone 4

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare/nixos
# after adding the DefaultDependencies assert:
nix build .#checks.x86_64-linux.data-disk-auto-grow --print-build-logs && echo EVAL_CHECK_OK
nix build .#checks.x86_64-linux.forge-credentials-module && echo FORGE_CHECK_OK
nix store info --store ssh://builder@nix-gcp-builder && echo BUILDER_OK
nix build .#checks.x86_64-linux.data-disk-online-grow --print-build-logs > /tmp/ep114/vmtest-attempt1.log 2>&1; echo "EXIT=$?"
grep -aE 'PHASE|ordering cycle|google-nagare-data|RequestedAssertionFailed|Traceback|error:' /tmp/ep114/vmtest-attempt1.log | tail -40
```

Run the VM build in the foreground with a generous timeout (up to 30 minutes), or in the
background and wait for its exit notification. Do not run grep pipelines on a live build and
conclude it is "stuck"; read the log file after it exits. If `BUILDER_OK` does not print, stop.
The builder is started on demand by the SSH configuration; report, and do not provision a new
one.

Commit:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
git add nixos/hosts/nagare-01/storage.nix nixos/flake.nix \
  docs/plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md
git commit -F - <<'MSG'
fix(nixos): break the data-disk growfs ordering cycle and prove the online grow

autoResize on /var/lib/nagare added systemd-growfs to local-fs.target, and
format-nagare-data's implicit After=basic.target closed a cycle that systemd
broke by dropping the grow job. Disable its default dependencies, assert that
in the evaluation check, and add a VM test that grows an undersized ext4
filesystem on reboot and on a running machine with no ordering cycle.

ExecPlan: docs/plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md
ExecPlan: docs/plans/111-automate-and-document-growing-the-data-disk.md
Intention: intention_01m2av9m0ge8sbwjy4arw5svf9
MSG
```

### Milestone 5

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
export PATH=/tmp/ep114/nagarectl/bin:$PATH
HOSTDIR=$(nagarectl host path --context tan-nb-exp)
grep 'inputs.nagare.url' "$HOSTDIR/flake.nix"
nix eval --json "path:$HOSTDIR#nixosConfigurations.nagare-01.config.fileSystems.\"/var/lib/nagare\".options"
nix eval --json "path:$HOSTDIR#nixosConfigurations.nagare-01.config.systemd.services.format-nagare-data.unitConfig.DefaultDependencies"
```

Expected: `["x-systemd.growfs","defaults","nofail"]` and `false`. If they differ and the input is
a `path:` to this checkout, run `(cd "$HOSTDIR" && nix flake update nagare)` once and re-evaluate.
If they still differ, stop.

Tunnel and SSH alias:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
scripts/iap-ssh.sh tunnel nagare-01 22 2222 | tee /tmp/ep114/tunnel.pid
cat >> ~/.ssh/config <<'SSHCFG'
# BEGIN EP-114 TEMPORARY nagare-01 IAP ALIAS (remove when done)
Host nagare-01
  HostName 127.0.0.1
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
# END EP-114 TEMPORARY nagare-01 IAP ALIAS
SSHCFG
ssh nagare-01 'echo ALIAS_OK'
```

Snapshot, switch, and post-switch gates:

```bash
ssh nagare-01 'sudo k3s kubectl get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded' | tee /tmp/ep114/pods-before.txt
SWITCH_START=$(date -u '+%Y-%m-%d %H:%M:%S')
just host-switch 2>&1 | tee /tmp/ep114/host-switch.log; echo "SWITCH_EXIT=${PIPESTATUS[0]}"
tail -3 /tmp/ep114/host-switch.log   # GATE: ends with COMMITTED (exit 0). NOT COMMITTED (exit 4): STOP, wait 600 s, check SSH, report.
ssh nagare-01 'echo STILL_OK; systemctl --failed --no-legend --plain; grep nagare /etc/fstab; sudo grep -E "terminal_input serial|timeout" /boot/grub/grub.cfg'
ssh nagare-01 "journalctl --since '$SWITCH_START' --no-pager | grep -i 'ordering cycle' || echo NO_CYCLE"
```

If `just host-switch` stops at `nagarectl platform guard` or `nagarectl context guard`, stop and
report the message. Do not set `NAGARE_UPGRADE_APPLY`.

Grow:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
source scripts/lib/target.sh
test "$CLOUDSDK_CORE_PROJECT" = tan-nb-exp && test "$NAGARE_MODE" = cloud || { echo "WRONG TARGET"; exit 1; }
ssh nagare-01 'df -h /var/lib/nagare; lsblk /dev/sdb'            # BEFORE: ~98G / 100G
pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 110 --stack "$NAGARE_CONTEXT"
pulumi -C infra/pulumi preview --stack "$NAGARE_CONTEXT" --diff 2>&1 | tee /tmp/ep114/preview-grow.txt | tail -12
# GATE: summary "~ 1 to update" / "1 change", only the Disk with "~ size: 100 => 110". Else: config rm + STOP.
pulumi -C infra/pulumi up --stack "$NAGARE_CONTEXT" --yes 2>&1 | tail -8
ssh nagare-01 'df -h /var/lib/nagare; lsblk /dev/sdb'            # GAP: ~98G filesystem on a 110G device
ssh nagare-01 'sudo systemctl start systemd-growfs@var-lib-nagare.service; df -h /var/lib/nagare'   # AFTER: ~108G
ssh nagare-01 'sudo k3s kubectl get nodes; sudo k3s kubectl get pods -A --no-headers --field-selector=status.phase!=Running,status.phase!=Succeeded' | tee /tmp/ep114/pods-after.txt
```

Teardown:

```bash
kill "$(grep -E '^[0-9]+$' /tmp/ep114/tunnel.pid | head -n1)"
python3 - <<'PY'
import pathlib, re
p = pathlib.Path.home() / ".ssh/config"
s = p.read_text()
s2 = re.sub(r"# BEGIN EP-114 TEMPORARY nagare-01 IAP ALIAS.*?# END EP-114 TEMPORARY nagare-01 IAP ALIAS\n", "", s, flags=re.S)
p.write_text(s2); print("removed" if s2 != s else "block not found")
PY
# Only after every Milestone 5 gate passed, and after TARGET_CHECK:
gcloud compute snapshots delete nagare-01-pre-rescue-20260912 --quiet
```

`scripts/iap-ssh.sh tunnel` prints two lines: the PID as a bare number, then a `# tunnel log: <path>`
comment. The `grep` picks the bare number.

### Milestone 6

Follow ExecPlan 111's Concrete Steps for its Milestone 5 (docs, `okf log add`,
`just docs-validate`, IR-5 closure) with the corrections listed in Plan of Work. Stage explicitly
by path and never use `git add -A`, because other actors may commit in this repository
concurrently. Then run `init-plan.ts` as given in Plan of Work and write that plan.


## Validation and Acceptance

The plan is complete when all of these are observably true.

`gcloud compute instances describe nagare-01 --format='value(metadata.items[].key)'` lists none
of `startup-script`, `ssh-keys`, `enable-oslogin`; `gcloud compute instances list` shows no
`nagare-rescue`; `gcloud compute snapshots list` shows no `nagare-01-pre-rescue-20260912`; and the
boot disk is still attached as `persistent-disk-0` with auto-delete on.

`scripts/iap-ssh.sh ssh nagare-01 -- 'echo SSH_OK; sudo -n true && echo SUDO_OK'` prints both
markers.

`nix eval` of the context-owned host flake's `deploy` authorized keys contains the operator key
and not the fixture key, and `grep nagare /etc/fstab` on the host contains `x-systemd.growfs`.

`nix build .#checks.x86_64-linux.data-disk-online-grow` from `nixos/` exits 0. Its log shows
`PHASE 1` and `PHASE 2` filesystems above 1.5G and no `ordering cycle`.
`nix build .#checks.x86_64-linux.data-disk-auto-grow` exits 0 and fails if
`DefaultDependencies = false` is removed from `storage.nix`.

This plan records three `df -h /var/lib/nagare` transcripts from the live host (about 98G before,
about 98G on a 110G device after `pulumi up`, about 108G after `systemd-growfs`), a node `Ready`,
and no newly failing pods compared with `pods-before.txt`.

`pulumi preview --refresh` for `tan-nb-exp` reports zero changes with `nagare:dataDiskSizeGb` = 110.

ExecPlan 111 is complete with IR-5 closed, and a new ExecPlan for the private development
repository exists.


## Idempotence and Recovery

Milestone 0 is read-only apart from killing this plan's own stray tunnels, and it can be repeated.
Milestone 1's `remove-metadata` is idempotent: removing absent keys is harmless. Milestone 2 Path B
is the only step that takes the host offline. Each numbered step is individually re-runnable: a
stopped instance stays stopped, `detach-disk` fails harmlessly if the disk is already detached, and
the rescue script only writes a fixed file. If interrupted after step 2, the boot disk exists
unattached. Resume from step 3. To abort, run the three reattach commands from step 6 (`attach-disk`
with `--boot --device-name=persistent-disk-0`, `set-disk-auto-delete --auto-delete`, and the
`diff` gate), then start. If the rescue step damaged the boot disk, create a disk from snapshot
`nagare-01-pre-rescue-20260912` and stop to report before using it. The data disk is never
detached at any point.

`nagarectl host init` without `--force` leaves an existing identical flake unchanged. The VM test
only touches throwaway QEMU disks. `just host-switch` can be re-run. A bad generation can be
rolled back on the host with `sudo nixos-rebuild switch --rollback` while SSH works; if SSH is
lost, Milestone 2 Path B is the recovery.

**Growing the data disk to 110 GiB is permanent.** A Persistent Disk cannot shrink, and the recorded
preview proves that Pulumi refuses. The operator consented to this increase on 2026-09-12.
`systemd-growfs` is safe to repeat. If `pulumi up` is interrupted, re-run the preview. It will
show either the same single update or nothing.


## Interfaces and Dependencies

Files changed by this plan: `nixos/hosts/nagare-01/storage.nix` (already edited in the working
tree: `format-nagare-data` gains `unitConfig.DefaultDependencies = false`,
`after = [ "local-fs-pre.target" ]`, `conflicts = [ "shutdown.target" ]`), `nixos/flake.nix`
(the evaluation check gains one assert; the VM test gains diagnostics, the no-cycle assertion,
and possibly the specified fallback), this plan, and ExecPlan 111 and its Milestone 5 targets. Out
of repository: `~/.config/nagare/hosts/tan-nb-exp/` (generated), temporary lines in
`~/.ssh/config` (removed at the end), and the stack config key `nagare:dataDiskSizeGb: "110"` in
`infra/pulumi/Pulumi.tan-nb-exp.yaml`.

Cloud resources touched, all in project `tan-nb-exp`, zone `us-west1-a`: instance `nagare-01`
(metadata, stop/start, boot-disk detach/attach on Path B), disk `nagare-01` (Path B only), the
temporary snapshot `nagare-01-pre-rescue-20260912` (Path B only, deleted in Milestone 5), the
temporary instance `nagare-rescue` (Path B only, deleted), and disk `nagare-data-8183a3e` (resized
through Pulumi URN
`urn:pulumi:tan-nb-exp::nagare::nagare:env:NagarePerimeter$gcp:compute/disk:Disk::nagare-data`).

Tools: `gcloud` and `pulumi` from the repository's dev shell; `nix` with the remote builder
`nix-gcp-builder`; `nagarectl` built from the root flake; `scripts/iap-ssh.sh`;
`scripts/host-switch.sh` via `just host-switch`; `okf` for Milestone 6 documentation validation.


## Revision notes

- 2026-09-12T18:40Z — Pre-implementation validation (update mode). A read-only pass (gcloud
  `describe`/`list`/serial output against `tan-nb-exp`, local `nix eval`) found that the recovery
  startup script never ran, because metadata startup scripts are inert on this image. That fixes
  Milestone 2 as Path B and corrects the Context claim that startup scripts run. It also found two
  defects that would have broken Path B. First, the project-wide `enable-oslogin=TRUE` would have
  kept the `rescue` user from being created, so the rescue VM now sets `enable-oslogin=FALSE`.
  Second, a plain `attach-disk --boot` would have changed the boot device name from
  `persistent-disk-0` and turned auto-delete off, which is create-time drift Pulumi resolves by
  replacing the instance; step 6 now restores both and diffs against a pre-rescue record. Added a
  boot-disk snapshot before the rescue, a stop condition if the key file was already correct, and
  `--refresh` on every "no changes" Pulumi gate, since a plain preview cannot see gcloud-made drift.
  Milestone 0's status/metadata/serial items are checked off with this evidence; the tunnel cleanup
  and the report-back remain for the implementer.

- 2026-09-12T18:55Z — Sequenced with ExecPlan 115 (lockout prevention), at the operator's direction
  that a lockout must never recur. Added prerequisites to Progress: ExecPlan 115 Milestone 1 before
  Milestone 1 here, and Milestones 2–4 before Milestone 5. Milestone 5's host switch now gates on
  the self-reverting switch's `COMMITTED` marker and checks the serial boot menu in
  `/boot/grub/grub.cfg`. Milestone 6 no longer needs to author a prevention plan.
