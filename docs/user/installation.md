---
type: Guide
title: "Installing Nagare"
description: "Install, select, upgrade, and remove released Nagare commands with Nix."
docId: DOC-18
tags: [installation, nix, releases, nagarectl]
generated:
  by: human:nadeem
  at: 2026-08-25T20:53:35Z
---

# Installing Nagare

> **Status:** ✅ Versioned Nix distribution

Nagare publishes one semantic version for the CLI and its immutable platform payload. Operators and
app developers should pin that version; a source checkout is only a contributor workspace. The
[GitHub releases page](https://github.com/shinzui/nagare/releases) identifies the latest stable
release and supplies its manifest, native Nix output identities, notes, and `SHA256SUMS`.

## Choose the package

| Need | Flake output | What it provides |
| --- | --- | --- |
| Deploy or inspect apps on an existing platform | `nagarectl` | CLI plus the typed-config GHC runtime |
| Provision or operate the platform | `nagare` | `nagarectl`, the immutable payload, and the `nagare` recipe launcher |
| Build or change Nagare itself | source checkout | `nix develop`, tests, and maintainer tools |

The examples use version 0.1.0. Replace it only after reviewing the target release notes.

```bash
export NAGARE_VERSION=0.1.0
export NAGARE_FLAKE="github:shinzui/nagare/v${NAGARE_VERSION}"
```

## Run without installing

Use this form in automation or for a first inspection:

```bash
nix run "${NAGARE_FLAKE}#nagarectl" -- version --json
nix run "${NAGARE_FLAKE}#nagarectl" -- context list
nix run "${NAGARE_FLAKE}#nagare" -- --list
nix run "${NAGARE_FLAKE}#nagare" -- --dry-run infra-preview
```

`nagarectl` is the application-facing CLI. The `nagare` launcher exposes the release's operator
recipes and automatically resolves a writable, content-addressed payload workspace. Neither command
edits the released Nix payload.

## Install persistently

Install the smaller CLI on app-developer workstations:

```bash
nix profile install "${NAGARE_FLAKE}#nagarectl"
nagarectl version --json
```

Install the full package on operator workstations:

```bash
nix profile install "${NAGARE_FLAKE}#nagare"
nagarectl version --json
nagare --list
```

To change the installed release, inspect its profile name, remove that one package, and install the
new explicit target rather than following an unpinned branch:

```bash
nix profile list
nix profile remove nagare
nix profile install "github:shinzui/nagare/v0.2.0#nagare"
```

Profile names can vary, so use the name shown by `nix profile list`. Changing the
workstation package does not upgrade a context or cluster; follow [Upgrades](upgrades.md) for the
staged per-context transaction.

## State and credentials

Released assets are immutable. Mutable operator data remains outside the package:

- contexts and generated host flakes: `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/`;
- payload workspaces and upgrade transactions: `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/`;
- GCP, Kubernetes, SSH, age, sops, and Tailscale credentials: their normal external stores.

Upgrading or removing a Nix profile therefore does not delete contexts, credentials, Pulumi state,
or cluster data. Back up those stores according to the [disaster-recovery runbook](../runbooks/disaster-recovery.md).

## Contributors

Clone the repository only when changing Nagare itself:

```bash
git clone https://github.com/shinzui/nagare.git
cd nagare
nix develop
nix flake check --print-build-logs
```

Contributor commands such as `nix run .#nagarectl` and `nix run .#nagare` intentionally select the
working tree. Do not use them as release pins in operator automation.
