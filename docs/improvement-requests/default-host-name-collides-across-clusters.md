---
type: Improvement Request
title: Give each cloud cluster a distinct default host name so tailnet names do not collide
description: host init defaults the NixOS and Tailscale host name to the instance name, which is nagare-01 in every project, so a second cluster on the same tailnet is renamed and ssh deploy@nagare-01 becomes ambiguous.
timestamp: "2026-09-13T23:54:44Z"
generated:
  by: process:claude-code
  at: "2026-09-13T23:54:44Z"
requestId: IR-14
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: derive the default host name from the context

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout on `v0.2.1`
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-09-13.


## Why

The operator already runs the `tan-nb-exp` cluster, whose host joined their tailnet as `nagare-01`.
Bringing up a second cloud cluster (`labs`, project `tan-ng-labs`) on the same tailnet with the
defaults would have produced a second node also named `nagare-01`. Tailscale resolves that by
renaming the newcomer (for example `nagare-01-1`), so the documented access path
`ssh deploy@nagare-01` (`docs/user/accessing-the-host.md`, "Path 1: Tailscale SSH") silently reaches
whichever cluster kept the name — and `kubectl` over the tailnet has the same ambiguity. Picking the
wrong host is exactly the cross-cluster mistake the multi-cluster guide warns about. The operator
avoided it only by noticing in advance and passing `--host-name labs-nagare`.


## What is missing

`nagarectl host init` sets `name = fromMaybe defaultInstance (options ^. #hostName)` where
`defaultInstance = profile ^. #instanceName` (`cli/nagarectl/app/Main.hs:2746-2750` at `v0.2.1`;
flag help at `Main.hs:1676`: "NixOS hostname (defaults to the context instance name)"). The module
turns that into `networking.hostName` (`nixos/modules/nagare-host.nix:111`), and Tailscale registers
the node under the OS host name (`nixos/hosts/nagare-01/tailscale.nix` passes no `--hostname`).

The instance name is effectively fixed per project: `docs/guides/running-multiple-clusters.md:66`
lists "VM name `nagare-01`" among the project-scoped names, and one project per cloud cluster is the
only supported topology. So every cloud cluster defaults to the same tailnet name, and neither
`host init` nor the multi-cluster guide mentions it.


## Requested change

- Default the host name from the context rather than the instance, for example `<context>-nagare`
  (the instance name can stay `nagare-01`). Existing host flakes are unaffected because they already
  record their host name.
- Until then, or additionally: when another context's generated host flake under
  `~/.config/nagare/hosts/` already uses the resolved host name, have `host init` warn or refuse
  without an explicit `--host-name`.
- Document the collision and the `--host-name` flag in `docs/guides/running-multiple-clusters.md`
  and in `docs/user/accessing-the-host.md`, which currently hardcodes `nagare-01`.


## Required verification

- A `HostSpec` test: two contexts with the same instance name render different default host names.
- A test for the warning or refusal when a sibling context's host flake already uses the name.


## Acceptance

Two cloud clusters onboarded with defaults on one workstation get distinct host names, and the
access documentation tells an operator which name reaches which cluster.


## Non-goals

Renaming the GCE instance or any other project-scoped resource.
