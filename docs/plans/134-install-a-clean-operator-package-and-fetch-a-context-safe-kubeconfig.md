---
id: 134
slug: install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig
title: "Install a clean operator package and fetch a context-safe kubeconfig"
kind: exec-plan
created_at: 2026-09-14T04:16:14Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:14Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T04:51:48Z
      mode: "implement"
      note: "Implemented and validated installed package boundary"
---

# Install a clean operator package and fetch a context-safe kubeconfig

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

An operator can install `.#nagare` beside Home Manager without a Nix profile collision, then run one
command to retrieve the selected cluster's k3s credentials. The resulting file is private, names
the Nagare context consistently, and addresses that context's host rather than a hard-coded
`nagare-01`. Before any bootstrap recipe mutates Kubernetes, a cluster guard proves that the
selected kubeconfig reports the expected context-owned node. This plan implements IR-10 and IR-20.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T04:51:29Z) Restrict the user-facing Nix joins, ship `socat`, and add installed-package checks.
- [x] (2026-09-14T05:08:33Z) Expose IAP SSH and implement an atomic, context-specific `kubeconfig fetch` command.
- [x] (2026-09-14T05:24:01Z) Implement one reusable cluster identity guard and put it before cluster-mutating recipes.
- [x] (2026-09-14T05:29:57Z) Update access and installation docs, validate both IRs, and run repository gates.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The pinned nixpkgs `symlinkJoin` implementation ignores `pathsToLink`; it uses
  `lndir` over each complete input tree. The first focused build therefore reproduced the original
  Darwin `libgmpxx.4.dylib` collision even though `pathsToLink` appeared in the derivation arguments.
  Replacing the public joins with `buildEnv`, whose pinned implementation explicitly supports
  `pathsToLink`, made both `nagare-operator-tools` and `nagare-darwin-profile-install` pass.
  Evidence: the failing profile build named the conflicting `lib/links/libgmpxx.4.dylib`; the rerun
  reported `created 3 symlinks in user environment` and exited zero.

- Observation: The host's standalone Cabal resolver cannot build this package because its compiler
  does not support the `MultilineStrings` extension required by `nagare-dsl`.
  Evidence: `cabal test nagarectl-test` failed during dependency solving with `MultilineStrings
  which is not supported`, while the pinned Nix build compiled `nagarectl` with GHC 9.12.4 and the
  focused package checks passed. Continue to use the flake's Haskell check for authoritative local
  validation.

- Observation: Flake builds sourced from a dirty Git worktree omit untracked Haskell modules.
  Evidence: the first `nagarectl-build-test` attempt could not find
  `Nagare.Cluster.Kubeconfig`; staging that new file made the same build compile the module and run
  all 490 tests.

- Observation: The final native flake gate rebuilt both ordinary and profiled Haskell outputs, then
  exercised the installed package and recipe harnesses from the dirty source revision.
  Evidence: `nix flake check --print-build-logs` passed all buildable `aarch64-darwin` outputs,
  including 496 Haskell tests, `shellcheck-scripts`, `nagare-darwin-profile-install`,
  `nagare-operator-tools`, and `nagare-clone-free-platform`; Nix reported only the expected omission
  of incompatible `x86_64-linux` checks.

## Decision Log

Record every decision made while working on the plan.

- Decision: Store fetched files below `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/kubeconfigs/` and
  name the cluster, user, and current context after the selected Nagare context.
  Rationale: Distinct names prevent merged kubeconfigs from silently selecting another k3s
  cluster. The XDG location already appears in Nagare's upgrade guidance.
  Date: 2026-09-14.

- Decision: Fetch over the existing project-confined IAP transport, but rewrite the API endpoint to
  the context-derived NixOS host name.
  Rationale: IAP works before workstation SSH naming is configured and selects the GCE instance by
  project; the host name is present in the k3s API certificate and remains the usable Tailscale
  address after retrieval.
  Date: 2026-09-14.

- Decision: Define one `nagarectl cluster guard` and make recipes call it.
  Rationale: Duplicate shell checks would drift. The Haskell command can resolve the context-owned
  host identity once, produce human and JSON evidence, and be tested without a live cluster.
  Date: 2026-09-14.

- Decision: Amend ADRs 4 and 7 only if implementation changes their durable package or workspace
  boundaries; do not create an ADR for filenames or Unix modes.
  Rationale: Those details implement existing immutable-payload and installed-tool decisions.
  Date: 2026-09-14.

- Decision: Use `pkgs.buildEnv` with explicit `pathsToLink` for all three public package layers.
  Rationale: The pinned `symlinkJoin` API cannot filter input subtrees, while `buildEnv` preserves
  wrapper post-processing and limits the profile surface to `bin`, `share`, and `nix-support`.
  Date: 2026-09-14.

- Decision: Treat the context-owned generated `host.nix` assignment as the kubeconfig endpoint
  source of truth and keep the GCE instance name only for IAP transport.
  Rationale: `host init --host-name` may deliberately override the derived default, while IAP must
  continue targeting the profile's project and instance identity. Mixing the names would produce a
  kubeconfig whose API endpoint is absent from the k3s certificate.
  Date: 2026-09-14.

- Decision: Define observed Nagare server nodes as nodes labelled control-plane, master, or etcd,
  ignore worker-only nodes, and require the server-node set to contain exactly the expected host.
  Rationale: Worker expansion must not block normal operation, while zero servers or any additional
  server identity makes the selected cluster ambiguous and must fail closed before mutation.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All four milestones are complete. The public `nagarectl` and `nagare` package layers expose only
their deliberate `bin`, `share`, and `nix-support` surfaces; the full operator environment includes
`socat`, and the Darwin fixture proves installation beside an existing `lib/links` owner without a
priority workaround. `nagare iap-ssh` is now a stable installed launcher command.

`nagarectl kubeconfig fetch` resolves the selected context once, uses its project and GCE instance
only for IAP transport, reads its context-owned host name for the API endpoint, and atomically
installs a mode-`0600` file with unambiguous cluster, user, and context names. Unsafe directory or
symlink destinations and failed retrieval, parsing, normalization, or validation leave the prior
file intact. `nagarectl cluster guard` separately inspects ambient kubectl state and accepts only
the selected kube context with exactly its expected labelled server node. The five direct cloud
mutation recipes run it before their first Kubernetes write; local recipes remain independent.

IR-10 and IR-20 are completed. ADR 7 holds the intentional release/profile surface, and ADR 4 holds
the operator-owned kubeconfig boundary. Validation passed for 37 user documents, 2 guides, all
23 improvement requests, all 496 Haskell tests, the focused installed-package and clone-free checks,
and every buildable native flake check. No live GCP credential fetch was run during this child: the
hermetic two-context and failure fixtures prove its isolated contract, while ExecPlan 139 owns the
authorized disposable-project end-to-end rehearsal.

