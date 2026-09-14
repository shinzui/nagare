---
type: Improvement Request
title: Add a command that fetches a per-context kubeconfig addressed to that context's host
description: The documented kubeconfig steps hard-code nagare-01, which on a multi-cluster tailnet is another cluster, leave the context named default, and depend on iap-ssh.sh, which the launcher does not expose and whose socat the operator package does not ship.
timestamp: "2026-09-14T02:40:00Z"
generated:
  by: process:claude-code
  at: "2026-09-14T02:40:00Z"
requestId: IR-20
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: `nagarectl kubeconfig fetch`

**Authored by:** a `claude-code` session implementing the `tan-ng-labs` rollout
(`mori://tan/tan-infrastructure`, `docs/plans/2026-06-30-nagare-labs-domain-delegation.md`; the
artifact-level plan URI is pending).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed.
**Created:** 2026-09-14.


## Why

`docs/user/upgrades.md` expects a per-context file, `KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml"`,
but no command writes one. `docs/user/accessing-the-host.md` ("Getting a working `kubectl`") gives
the manual route, and on a workstation with two clusters every step of it points at the wrong one:

- The Tailscale variant is `ssh deploy@nagare-01 sudo cat /etc/rancher/k3s/k3s.yaml`. The operator's
  tailnet has `nagare-01` (the `tan-nb-exp` cluster) and `labs-nagare` (the new one; see IR-14), so
  this fetches the other cluster's admin credentials.
- Step 2 says to set `server:` to `https://nagare-01:6443`, which again addresses `tan-nb-exp`.
- The file's context, cluster and user are all named `default`, as they are in every k3s kubeconfig,
  so a merged `KUBECONFIG` silently picks one.

The IAP variant is the safe one because `iap-ssh.sh` resolves the instance in the context's project,
but it is awkward on a clone-free install. `nagare iap-ssh` is not a recipe, so the script had to be
run by path from `~/.local/state/nagare/labs/platform/nagare-0.2.2-…/scripts/iap-ssh.sh`. It then
failed with `iap-ssh: socat not found on PATH`, because `socat` comes only from
`nix/dev-shells.nix`, not the operator package. The same happened with Pulumi (IR-8).

On 2026-09-14 the working sequence was: run `iap-ssh.sh recv-file` under `nix shell nixpkgs#socat`,
check that the API certificate's SANs include `DNS:labs-nagare`, set `server: https://labs-nagare:6443`,
rename the context `default` to `labs`, and require `kubectl get nodes` to show exactly `labs-nagare`
before running `cluster-bootstrap`.


## Requested change

- Add `nagarectl kubeconfig fetch [--context NAME]` that retrieves `/etc/rancher/k3s/k3s.yaml` over
  IAP in the context's project, rewrites `server:` to the context's host name, renames the context,
  cluster and user to the context name, and writes `~/.config/nagare/kubeconfigs/<context>.yaml` with
  mode `0600`.
- Before `cluster-bootstrap` and other cluster-mutating recipes, check that the current kubectl
  context's node names match the context's host name, and refuse otherwise (a cluster analogue of
  `context guard`).
- Ship `socat` (and anything else `iap-ssh.sh` needs) in the operator package, and expose IAP SSH
  through the launcher.
- Update `accessing-the-host.md` to use the context's host name instead of `nagare-01`.


## Required verification

- A test that the fetched file names the context's host and context, and that the cluster guard
  refuses when the node name differs.
- The operator-tools check covers `socat`.


## Acceptance

On a workstation with two nagare clusters, one documented command produces a kubeconfig that can only
reach the selected context's cluster, and cluster recipes refuse when `KUBECONFIG` points elsewhere.


## Non-goals

Managing kubeconfigs for non-nagare clusters, or replacing k3s's admin credentials with scoped ones.
