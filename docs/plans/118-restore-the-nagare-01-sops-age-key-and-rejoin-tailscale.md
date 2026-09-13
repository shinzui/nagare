---
id: 118
slug: restore-the-nagare-01-sops-age-key-and-rejoin-tailscale
title: "Restore the nagare-01 sops age key and rejoin Tailscale"
kind: exec-plan
created_at: 2026-09-13T00:08:38Z
intention: "intention_01m2av9m0ge8sbwjy4arw5svf9"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-13T00:08:38Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-13T00:24:58Z
      mode: "implement"
      note: "Milestones 0-3 executed; nagare-01 rejoined Tailscale"
---

# Restore the nagare-01 sops age key and rejoin Tailscale

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The `nagare-01` host has not been on the operator's Tailscale network since at least 2026-06-11.
Its sops age private key was never placed at `/var/lib/sops-nix/age-key.txt`, so sops-nix cannot
decrypt the host secrets, `/run/secrets/tailscale/authkey` never exists, and
`tailscaled-autoconnect.service` fails on every boot and every switch. Every switch therefore
reports a non-zero activation code, and all access goes through the slower IAP tunnel.

After this plan, the host decrypts its secrets at activation and is online in the tailnet. You can
see it working when three things hold:

- `tailscale status` on the workstation lists `nagare-01` as online.
- `ssh deploy@nagare-01` works over Tailscale.
- `just host-switch` commits with no failed `tailscaled-autoconnect.service`.


## Progress

- [x] (2026-09-13T00:05Z) Local, read-only: the workstation file
  `~/.config/nagare/nagare-01-age-key.txt` derives to the host recipient
  `age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99`, and it decrypts
  `hosts/tan-nb-exp/secrets.yaml` in the private operator repository. The file holds one
  `tailscale.authkey` value (44 characters, `tskey-auth-` prefix), last modified 2026-06-02.
- [x] (2026-09-13T00:07Z) VM `nagare-01` is `RUNNING`.
- [x] (2026-09-13T00:18Z) Milestone 1: operator signed in to the Tailscale console in Chrome; agent generated a non-reusable, non-ephemeral, untagged, 1-day auth key (`nagare01rejoin`) and stored it with `sops set --value-stdin`. Verified length 62, prefix `tskey-auth-`, `lastmodified 2026-09-13T00:17:37Z`, recipient `age1rc26869…`; `nagare-ops@e197bc4` pushed.
- [x] (2026-09-13T00:19Z) Milestone 0 (after operator turned off auto mode): age key ABSENT, `/run/secrets` absent, `tailscaled` active, `tailscaled-autoconnect` failed, `resolvconf` failed, Tailscale "Logged out", generation `8fgipxvf…`.
- [x] (2026-09-13T00:20Z) Milestone 2: installed `/var/lib/sops-nix/age-key.txt` as `400 root:root`, 189 bytes, sha256 `a6b4d7ae…cc7f` equal to the workstation file.
- [x] (2026-09-13T00:22Z) Milestone 3: `just host-switch` over an IAP tunnel with `NIX_SSHOPTS="-F <scratch ssh_config>"` (rehearsed login and sudo first). `ACTIVATE_RC=4` (resolvconf only), `fresh login and sudo verified (attempt 1)`, `COMMITTED new=/nix/store/ljf91688avdvicz2frwpdi03sy288xjh-nixos-system-nagare-01-google-compute-26.11.20260531.331800d`. Gates: `/run/secrets/tailscale/authkey` `400 root`; `tailscaled` active; `tailscaled-autoconnect` inactive (not failed); only `resolvconf.service` failed; `tailscale status` on host: `100.80.88.126 nagare-01 nadeem@ linux`.
- [x] (2026-09-13T00:30Z) Workstation-side gate: after the operator logged in to Tailscale on the Mac, `tailscale status` lists `100.80.88.126 nagare-01`, and `ssh deploy@nagare-01` over Tailscale printed `SSH over Tailscale OK: nagare-01`.
- [x] Milestone 4: outcomes recorded; operator memory updated. `docs/user/secrets.md` already describes placing the host age key, so no doc change was needed.


## Surprises & Discoveries

- `~/.ssh/config` is a read-only home-manager symlink, so the EP-114 technique of adding a temporary
  `Host nagare-01` block is unavailable. `scripts/host-switch.sh` and
  `nixos/lib/nagare-safe-switch-client.sh` pass `NIX_SSHOPTS` to every ssh, which made
  `-F <scratch config>` sufficient.
- The encrypted auth key was last modified on 2026-06-02, 103 days before this plan. Tailscale auth
  keys expire after at most 90 days, so the stored key is almost certainly expired. Placing the age
  key alone would leave `tailscaled-autoconnect` failing with an authentication error instead of a
  missing file. Evidence: `sops` metadata `lastmodified: "2026-06-02T18:21:04Z"`.


## Decision Log

- Decision: Place the existing host age key rather than switching sops-nix to derive its identity
  from the host SSH key (`sops.age.sshKeyPaths`).
  Rationale: The key exists and matches the recipient every host secret is encrypted to, so no
  secret needs re-encryption to a new recipient. Changing the identity scheme is a module change
  with its own lockout and recovery surface.
  Date: 2026-09-13

- Decision: Replace the Tailscale auth key before switching, and make the operator the only person
  who sees its value: they paste it into a hidden `read` that pipes into
  `sops set --value-stdin`.
  Rationale: The stored key is probably expired (Surprises). A secret typed into a hidden prompt
  never reaches the transcript, shell history, or process listings.
  Date: 2026-09-13


## Outcomes & Retrospective

Host side complete (2026-09-13): `nagare-01` decrypts its sops secrets and is logged in to the tailnet
as `100.80.88.126`. Every future switch loses the `tailscaled-autoconnect` failure. Remaining:

- `resolvconf.service` still fails, and Tailscale reports a DNS health warning because
  `/etc/resolv.conf` cannot be modified on this image. That is pre-existing and needs a follow-up.
- The node is untagged, so its Tailscale node key expires on the tailnet's default schedule. Disable
  key expiry for `nagare-01` in the admin console, or it will drop off again.

Lessons:

- `NIX_SSHOPTS` is honored by both `nix copy` and the safe-switch client. A scratch `-F` SSH config
  routes `host-switch` over IAP without editing a (home-manager, read-only) `~/.ssh/config`.
- The harness's auto-mode classifier blocks host reads and secret handling; turning auto mode off
  converts those denials into approvable prompts.


## Context and Orientation

`nagare-01` is the single NixOS VM in Google Cloud project `tan-nb-exp`, zone `us-west1-a`. Its
NixOS configuration is built from a **context-owned host flake**. That flake lives in the private
operator repository `shinzui/nagare-ops`, cloned at `/Users/shinzui/Keikaku/bokuno/nagare-ops`, under
`hosts/tan-nb-exp/`. It is symlinked into `~/.config/nagare/hosts/tan-nb-exp`
([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)).
Its `host.nix` sets `sopsDefaultFile = ./secrets.yaml` and
`ageKeyFile = "/var/lib/sops-nix/age-key.txt"`.

**sops** encrypts YAML values so that only holders of a listed **age** private key can decrypt them.
**sops-nix** is the NixOS module that decrypts `secrets.yaml` during activation, using the private
key at `ageKeyFile`, and writes each secret under `/run/secrets/`. The Tailscale module
(`nixos/hosts/nagare-01/tailscale.nix` shape, reused by the host module) sets
`services.tailscale.authKeyFile` to `/run/secrets/tailscale/authkey`. At boot and at switch,
`tailscaled-autoconnect.service` runs `tailscale up` with that key if the node is not logged in.
A **Tailscale auth key** (`tskey-auth-…`) is a one-time or reusable token that lets a machine join
the tailnet unattended. It expires 1–90 days after creation. It is only needed to join; a joined
node keeps its identity after the key expires.

Host changes go **only** through `just host-switch` (`scripts/host-switch.sh`,
[ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md)). It builds the context's
host flake, arms an on-host rollback timer, activates, verifies a fresh SSH login and sudo, and
only then commits. Otherwise the host reverts by itself. `scripts/iap-ssh.sh` reaches the host
over an IAP tunnel as user `deploy` with `~/.ssh/id_ed25519`
(`SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '<cmd>'`).
A git flake sees only tracked files, so an edited `secrets.yaml` must stay tracked (it is) and is
best committed before the switch.

Lockout analysis: installing a file under `/var/lib/sops-nix` does not touch sshd or the `deploy`
user. Tailscale's `--ssh` flag adds Tailscale SSH alongside OpenSSH; it does not disable OpenSSH.
The switch is self-reverting. The remaining risk is a sops activation failure. That already happens
today (a missing key), and the switch still committed on 2026-09-12.


## Plan of Work

### Milestone 0 — Read-only host preflight

Over IAP, record the facts below without changing anything. Gate: the host is reachable as `deploy`
with sudo, and the file is absent (or present with the wrong recipient, which changes Milestone 2
to a replacement).

- Whether `/var/lib/sops-nix/age-key.txt` exists, with its mode and owner.
- Whether `/run/secrets` exists.
- `systemctl is-active tailscaled tailscaled-autoconnect`.
- `systemctl --failed`.
- `tailscale status`.
- The current system generation.

### Milestone 1 — New Tailscale auth key into the host secrets

The operator creates an auth key in the Tailscale admin console (Settings → Keys → Generate auth key).
It should be non-ephemeral, pre-approved if device approval is on, and expire in 1 day, since it is
used once. From the `nagare-ops` root, the operator runs the hidden-input command in Concrete Steps.
Verify it without printing the value: the length changes and the prefix is `tskey-auth-`.
Gate: `sops` decrypts with the host key, `lastmodified` is today, and only
`hosts/tan-nb-exp/secrets.yaml` changed. Commit and push `nagare-ops`.

### Milestone 2 — Install the host age key

Stream the workstation key file over SSH into
`sudo install -D -m 0400 -o root -g root /dev/stdin /var/lib/sops-nix/age-key.txt`. The key never
appears in arguments or on screen. Gate: on the host, `age-keygen -y` of the file prints
`age1rc26869…`, and the mode is `400 root`.

### Milestone 3 — Switch and verify

Run `just host-switch` from the public checkout with the fixed `nagarectl` on PATH, in a shell
that resolved the current context. Gates:

- `host-switch` prints `COMMITTED`.
- `/run/secrets/tailscale/authkey` exists with mode 0400.
- `tailscaled-autoconnect` is not failed.
- `sudo tailscale status` on the host shows it logged in.
- `tailscale status` on the workstation lists `nagare-01`.
- `ssh deploy@nagare-01 true` succeeds over Tailscale.

If the switch commits but `tailscaled-autoconnect` did not run again, restart it once. That starts
a unit and changes no configuration.

### Milestone 4 — Close out

Record outcomes. Update `docs/user/secrets.md` if the procedure differs from its "place the host age
key" section, and update the operator memory that describes the gap.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/nagare` unless stated; bash, not zsh.

Milestone 0 (read-only):

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- '
sudo stat -c "%a %U %s" /var/lib/sops-nix/age-key.txt 2>&1
sudo ls /run/secrets 2>&1
systemctl is-active tailscaled tailscaled-autoconnect
systemctl --failed --no-legend
sudo tailscale status 2>&1 | head -3
readlink /run/current-system'
```

Milestone 1 (operator runs this in their own terminal, from the private repository root):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare-ops
IFS= read -rs -p 'Tailscale auth key: ' K; echo
printf '"%s"' "$K" | SOPS_AGE_KEY_FILE=~/.config/nagare/nagare-01-age-key.txt \
  nix shell nixpkgs#sops -c sops set --value-stdin hosts/tan-nb-exp/secrets.yaml '["tailscale"]["authkey"]'
unset K
```

Verification (prints no secret):

```bash
SOPS_AGE_KEY_FILE=~/.config/nagare/nagare-01-age-key.txt nix shell nixpkgs#sops -c \
  sops -d --extract '["tailscale"]["authkey"]' hosts/tan-nb-exp/secrets.yaml \
  | awk '{ printf "length=%d prefix=%s\n", length($0), substr($0,1,11) }'
grep lastmodified hosts/tan-nb-exp/secrets.yaml
```

Milestone 2:

```bash
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- \
  'sudo install -D -m 0400 -o root -g root /dev/stdin /var/lib/sops-nix/age-key.txt' \
  < ~/.config/nagare/nagare-01-age-key.txt
SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519 scripts/iap-ssh.sh ssh nagare-01 -- \
  'sudo stat -c "%a %U" /var/lib/sops-nix/age-key.txt; sudo nix shell nixpkgs#age -c age-keygen -y /var/lib/sops-nix/age-key.txt'
```

Expected:

```text
400 root
age1rc26869fukux3k5rqjwf0e9gs3j7p98ekp47pxrtge6m5sc9zerssk9r99
```

Milestone 3:

```bash
export PATH="$PWD/result/bin:$PATH"
just host-switch
```


## Validation and Acceptance

- On the workstation, `tailscale status | grep nagare-01` shows the node online.
- `ssh -i ~/.ssh/id_ed25519 deploy@nagare-01 true` exits 0 without IAP.
- On the host, `systemctl is-failed tailscaled-autoconnect` prints `inactive` or `active`, not
  `failed`.
- `sudo ls /run/secrets/tailscale/authkey` exists.
- The `host-switch` output contains `COMMITTED`.


## Idempotence and Recovery

Milestone 0 is read-only. Milestone 1 can be repeated with a fresh key; the previous `secrets.yaml`
is in git history (`git -C nagare-ops checkout HEAD~1 -- hosts/tan-nb-exp/secrets.yaml`).
Milestone 2 is idempotent (`install` overwrites with identical content). Remove the key with
`sudo rm /var/lib/sops-nix/age-key.txt` to return to today's state. Milestone 3 is the
self-reverting switch: if verification fails, the host reverts on its own within the confirm window
(600 s), and a plain `host-switch` exit code other than 0 is reported and stops the plan. An unused
auth key simply expires. Revoke it in the admin console if the plan is abandoned.


## Interfaces and Dependencies

- Tools: `scripts/iap-ssh.sh`, `scripts/host-switch.sh` via `just host-switch`, `sops` 3.13
  (`set --value-stdin`), `age-keygen`, and the Tailscale admin console (operator).
- Files: `hosts/tan-nb-exp/secrets.yaml` in `nagare-ops`, the workstation key
  `~/.config/nagare/nagare-01-age-key.txt`, and the host path `/var/lib/sops-nix/age-key.txt`.
- Cloud: none. Host: one file installed, one guarded switch.
