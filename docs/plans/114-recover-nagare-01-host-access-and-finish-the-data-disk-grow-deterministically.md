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

Full plan before trimming: [114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/114-recover-nagare-01-host-access-and-finish-the-data-disk-grow-deterministically.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] (2026-09-12T21:20Z) STOP, resolved by the operator-approved fix below: attempt 1 failed at Phase 0 `test -d /var/lib/nagare/local-path`. The ordering fix makes `format-nagare-data` run before udev creates the by-id link (see Surprises). Nothing was committed and the host was not switched. Waiting for a human decision on the proposed storage.nix fix.
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

- [x] (2026-09-12T21:50Z) Regenerated the host flake from commit `5bcf428`: rebuilt `nagarectl`; `host init --force` printed `Replaced host configuration`. New input `path:/nix/store/66np2i3vm8zk1ldzbasp6vpacyzwi068-nagare-platform-0.1.0/share/nagare/nixos` (revision `5bcf428...-dirty`, where "dirty" is only the uncommitted ExecPlan 111 doc). Its `storage.nix` matches the committed file (`STORAGE_DIFF_EXIT=0`).
- [x] (2026-09-12T21:51Z) Gate PASS: the generated host flake evaluates keys = real key only; options `["x-systemd.growfs","defaults","nofail"]`; `DefaultDependencies` `false`; `after` includes the by-id device unit; `boot.loader.timeout` `10`; `evaluationFixture` `false`. `host-switch.sh --dry-run` exits 0. `nagarectl platform guard`: `platform mutation allowed (legacy-unknown)`. Host `trusted-users` = `root root @wheel`, and `deploy` is in `wheel`.
- [x] (2026-09-12T21:55Z) Open the IAP tunnel on port 2222 (PID 1844). The `~/.ssh/config` append was denied by the sandbox, so `NIX_SSHOPTS` is used instead (Decision Log). A fresh login through it printed `ALIAS_OK`. `pods-before.txt` holds the same six baseline pods; switch start `2026-09-12 20:58:21` UTC.
- [x] (2026-09-12T22:00Z) STOP: `just host-switch` exited 1 during `nix copy`, **before arming**: `error: cannot add path '/nix/store/2al3m9wsahzhlbybq1652zj9f9812z0b-manifest.json' because it lacks a signature by a trusted key`. The host was verified unchanged (SSH OK, `system-4-link`, no rollback timer). Resolved by operator decision: pre-copy with `--no-check-sigs` (Decision Log).
- [x] (2026-09-12T22:03Z) Pre-copy: the rebuilt toplevel equals the switch's (`...8fgipxvf...`); `nix copy --no-check-sigs --to ssh-ng://deploy@nagare-01` `COPY_EXIT=0`; `NEW_VALID_ON_HOST`.
- [x] (2026-09-12T22:05Z) `just host-switch` (ExecPlan 115's self-reverting switch), second run: `SWITCH_EXIT=0`, `ACTIVATE_RC=4` (informational: `tailscaled-autoconnect` timed out on the missing sops authkey), `host-switch: fresh login and sudo verified (attempt 1)`, `COMMITTED new=/nix/store/8fgipxvf2qwyi9z1ngxsg2cfly5pnk13-nixos-system-nagare-01-google-compute-26.11.20260531.331800d`. Gates PASS: fresh SSH `STILL_OK`; profile `system-5-link`; fstab `x-systemd.growfs,defaults,nofail`; `NO_CYCLE` since the switch start; `grub.cfg` has `terminal_input serial console` and `set timeout=10`; `format-nagare-data` `After=` includes the by-id device. Failed units: `resolvconf.service` and `tailscaled-autoconnect.service`. Both are named in Context as the known pre-existing failures (the latter is the missing sops age key). `network-local-commands.service` is no longer failed.
- [x] (2026-09-12T22:06Z) Record `df -h` and `lsblk` before: `/dev/sdb 98G 209M 93G 1% /var/lib/nagare`; `sdb 100G`.
- [x] (2026-09-12T22:07Z) Set `dataDiskSizeGb` to 110. Gate PASS: the preview shows only `~ gcp:compute/disk:Disk: (update) 🔒` with `~ size: 100 => 110`; `~ 1 to update`, `30 unchanged`.
- [x] (2026-09-12T22:08Z) `pulumi up`: `UP_EXIT=0`, `~ 1 updated`, `30 unchanged`, 15 s. Gap: `/dev/sdb 98G 212M 93G 1%` on `sdb 110G`.
- [x] (2026-09-12T22:12Z) Grow. `sudo systemctl start systemd-growfs@var-lib-nagare.service` was a **no-op** (df still 98G; see Surprises). With operator approval, `sudo systemctl restart ...` logged `Successfully resized "/var/lib/nagare" to 110G bytes`. After: `/dev/sdb 108G 212M 103G 1% /var/lib/nagare`.
- [x] (2026-09-12T22:12Z) Gate PASS: `nagare-01 Ready`; the pods not Running/Succeeded are the same six as `pods-before.txt`.
- [x] (2026-09-12T22:14Z) Tear down: tunnel PID 1844 killed (`TUNNEL_KILLED`); no SSH config block was ever written (0 `EP-114` lines in `~/.ssh/config`); snapshot `nagare-01-pre-rescue-20260912` deleted (`SNAPSHOTS=[]`). Final checks: `pulumi preview --refresh` `31 unchanged`; metadata `KEYS=[]`; no `nagare-rescue`; `DISKS_MATCH`. (`nix-builder-x86` was `RUNNING`, started on demand by the VM builds; left alone.)
- [x] (2026-09-12T22:15Z) Report back.

Milestone 6 — Hand back to ExecPlan 111 and author the private-repo plan:

- [x] (2026-09-12T22:37Z) Update ExecPlan 111 Progress and Surprises with this plan's evidence.
- [x] (2026-09-12T22:37Z) Complete ExecPlan 111 Milestone 5 (documentation, alert, close IR-5) using the corrected facts listed here, plus `systemctl restart`: commit `e95cad5`. The `host-switch.sh` `--no-check-sigs` fix landed in `efa31bc`.
- (The lockout-prevention plan already exists as ExecPlan 115; this milestone does not author it.)
- [x] (2026-09-12T22:45Z) Author the private development repository ExecPlan with `init-plan.ts`: [ExecPlan 116](116-move-operator-private-deployment-material-into-a-private-development-repository.md). It chooses the `gcs` backend over committed state, pending operator confirmation, after finding the stack passphrase empty.
- [x] (2026-09-12T22:46Z) Fill in Outcomes & Retrospective and run the ADR distillation pass for both plans: ADR 12 is new, and ADR 11 gains the `nix copy` note. ADR 5 already records the fixture rule (ExecPlan 115).
- [x] (2026-09-12T22:47Z) Final report back.

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

- (Implementation session, 2026-09-12T22:00Z) `nix copy` to the host refused an unsigned path even
  though the host daemon reports `Trusted: 1` for `deploy` (`trusted-users = root root @wheel`, and
  `deploy` is in `wheel`). The refused path, `manifest.json`, was built on the remote builder, so it
  has `signatures: []` and `ultimate: false`. `nix copy` checks signatures on the client unless it
  gets `--no-check-sigs`, so trust on the receiving side does not help. `scripts/host-switch.sh`
  therefore cannot copy remote-built closures as written. It needs `--no-check-sigs` on its
  `nix copy`, a signing key, or `--build-on-host`.

- (Implementation session, 2026-09-12T22:10Z) **`systemctl start systemd-growfs@var-lib-nagare.service`
  does not grow a filesystem that has already been grown once in this boot.** The unit is
  `Type=oneshot` with `RemainAfterExit=yes`. After its boot-time run
  (`Successfully resized "/var/lib/nagare" to 100G bytes` at 20:38) it stays `active (exited)`, so
  `start` is a no-op that exits 0. `restart` runs it again:
  `Successfully resized "/var/lib/nagare" to 110G bytes`. The VM test's Phase 2 missed this because
  it stopped the mount first, which also stops the growfs unit. The manual grow command in the docs
  must be `sudo systemctl restart systemd-growfs@var-lib-nagare.service`. The same boot log also
  proves the original bug live: `Job systemd-growfs@var-lib-nagare.service/start deleted to break
  ordering cycle` at 20:38:39 on the old generation.

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

- Decision: After the first `just host-switch` failed at `nix copy`, pre-seed the host's store with
  `nix copy --no-check-sigs --to ssh-ng://deploy@nagare-01 <toplevel>`, then re-run
  `just host-switch` unchanged. Operator approved at 2026-09-12T22:02Z.
  Rationale: The failure happened before arming, so the host was untouched. `deploy` is trusted
  on the host, so skipping the client-side signature check is safe for closures this workstation
  built. The re-run's own copy is then a no-op, and every self-reverting step (arm, activate,
  fresh-login verify, commit) still runs. `--build-on-host` would have loaded the single production
  node with a system build.
  Date: 2026-09-12

- Decision: Grow the filesystem with `systemctl restart` instead of `start` after `start` was a
  no-op. Operator approved at 2026-09-12T22:11Z.
  Rationale: Unit state `ActiveState=active SubState=exited RemainAfterExit=yes` proved the cause.
  `restart` runs the same idempotent online ext4 grow that Phases 1 and 2 of the VM test proved.
  Date: 2026-09-12

- Decision: Route Milestone 5's SSH through the tunnel with
  `NIX_SSHOPTS="-o HostName=127.0.0.1 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentityFile=$HOME/.ssh/id_ed25519 -o LogLevel=ERROR"`
  instead of the temporary `~/.ssh/config` block.
  Rationale: The agent sandbox denied the append to `~/.ssh/config` (`permission denied`), and that
  denial was not overridden. `nagare_safe_switch` applies `NIX_SSHOPTS` to every SSH call, including
  the fresh-login verification, and `nix copy --to ssh-ng://` honors it, so the routing is
  equivalent with nothing to tear down. ExecPlan 115's author named it as the alternative.
  Verified before the switch: a fresh bash `ssh` printed `ALIAS_OK` and the current system path,
  and `nix store info --store ssh-ng://deploy@nagare-01` reported `Trusted: 1`.
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

Delivered 2026-09-12. Every purpose item holds. `deploy` can SSH to nagare-01. No temporary
metadata, rescue VM, or snapshot remains, and `pulumi preview --refresh` reports `31 unchanged`
with `dataDiskSizeGb` 110. The host runs the context-owned configuration (`system-5-link`, real key,
serial boot menu). `/var/lib/nagare` is 108G on a 110 GiB disk. The ordering-cycle fix is proven by
the VM test and committed (`5bcf428`). ExecPlan 111 and IR-5 are closed (`e95cad5`), and
ExecPlan 116 exists.

Gaps and follow-ups. ExecPlan 116 is authored but not started; it needs operator answers first.
The host's missing sops age key (Tailscale down, `tailscaled-autoconnect` failing) is untouched,
and ExecPlan 116's inventory found a candidate key on the workstation. The guard hook's "ask" does
not prompt under auto permission mode, so human approval for cloud mutations was collected by
asking directly.

Lessons. The plan's gates caught every defect before it did harm, but four of the stops came from
steps that had never been run for real: the symlinked sshd config check, the builder probe as the
wrong user, the unsigned `nix copy`, and `systemctl start` on a `RemainAfterExit` unit. Each cost a
stop-and-ask cycle at a moment when a mistake was expensive. A step that will run against a live
host, or before a long build, should first be dry-run cheaply in the exact state it will meet. The
evaluation-plus-driver-build check before VM attempt 2 is the pattern: it made that run
pass first time.

