---
type: Improvement Request
title: Give the host age key a supported delivery path, since a GCE image cannot hold it before first boot
description: The docs require the private age key on the VM before first boot, but infra-up creates and boots the VM from an image that must not contain it, so every new host first boots without secrets and needs a manual copy and reboot.
timestamp: "2026-09-14T02:40:00Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-18
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: a supported host age-key placement for new cloud hosts

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-09-14.


## Why

`docs/user/secrets.md` ("One-time setup: place the host age key") and
`docs/user/onboarding-bring-your-own-project.md` step (a) both say the private key must exist at
`/var/lib/sops-nix/age-key.txt` (mode `0400`, root) **before first boot**. They also say to keep it
out of the image. For a cloud host those two requirements cannot both be met with any documented
command: `nagare infra-up` creates the instance from the image and GCE boots it immediately.
`nagarectl host init --age-key-file` records only the on-host path ("the key is never read or
copied").

On 2026-09-14 the `labs` host (`v0.2.2`) therefore booted with no key:

```text
tailscaled-autoconnect-start[890]: cat: /run/secrets/tailscale/authkey: No such file or directory
tailscaled-autoconnect-start[891]: To authenticate, visit:
tailscaled-autoconnect-start[891]:         https://login.tailscale.com/a/…
```

`/run/secrets` did not exist, the host did not join the tailnet, and the autoconnect unit sat on an
interactive login URL. Recovery took an IAP SSH session to stream the key into
`/var/lib/sops-nix/age-key.txt` (checksums compared, mode `0400 root:root`) and a reboot, after which
sops-nix decrypted and Tailscale joined as `labs-nagare`. None of that is written down.


## What is missing

- A mechanism to place the key before or at first boot, or a supported post-boot placement.
- Any mention in the host-image, onboarding or `infra-up` docs that the first boot will come up
  without secrets.
- A check: nothing tells the operator the key is absent until they go looking at the serial console.


## Requested change

Pick one, and document it in the onboarding order:

- A `nagarectl host place-age-key --context NAME --key-file PATH` command that streams the key over
  IAP SSH to the context's instance (never via argv or a temp file), verifies the checksum and mode,
  and re-runs activation or reboots; or
- Deliver the key at boot from a project-scoped source the host's service account can read (for
  example Secret Manager in the context's project), fetched by a unit ordered before sops-nix.

In either case, have `nagarectl platform status` or a host check report "age key missing" explicitly,
and have the Tailscale autoconnect unit fail with that message instead of printing a login URL.


## Required verification

- A VM test that a host booted without the key reports the missing key, and that the placement
  path makes `/run/secrets/tailscale/authkey` appear without an interactive step.


## Acceptance

Following the documented onboarding steps for a new cloud context produces a host that joins the
tailnet without any undocumented SSH session.


## Non-goals

Baking the private key into the image, or changing sops-nix itself.
