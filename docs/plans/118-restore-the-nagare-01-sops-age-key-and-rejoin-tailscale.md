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

Full plan before trimming: [118-restore-the-nagare-01-sops-age-key-and-rejoin-tailscale.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/118-restore-the-nagare-01-sops-age-key-and-rejoin-tailscale.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- Follow-up done the same day (operator-approved, 2026-09-13T00:36Z): `/etc/resolv.conf` carried
  a manual `chattr +i` from the June DNS workaround (ExecPlan 3), which `networking.nix` has long
  made unnecessary. On the host: `tailscale set --accept-dns=false` (`CorpDNS: false`),
  `chattr -i /etc/resolv.conf`, and `systemctl restart resolvconf`. The file is regenerated
  (`# Generated by resolvconf`, `8.8.8.8`/`8.8.4.4`). Host and CoreDNS (`10.43.0.10`) lookups
  passed before and after, and `resolvconf.service` is active. The Tailscale DNS health warning is
  gone. The backup is `/root/resolv.conf.pre-ep118`. `nixos/hosts/nagare-01/tailscale.nix` now
  sets `--accept-dns=false` in `extraUpFlags` and `extraSetFlags`; it reaches the host with the
  next platform release and switch.
- Node key expiry for `nagare-01` was disabled by the operator in the Tailscale admin console
  (2026-09-13), so the untagged node will not drop off the tailnet on the default schedule.

Lessons:

- `NIX_SSHOPTS` is honored by both `nix copy` and the safe-switch client. A scratch `-F` SSH config
  routes `host-switch` over IAP without editing a (home-manager, read-only) `~/.ssh/config`.
- The harness's auto-mode classifier blocks host reads and secret handling; turning auto mode off
  converts those denials into approvable prompts.

