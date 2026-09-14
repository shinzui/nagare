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


## Context and Orientation

The defect reports are [IR-10](../improvement-requests/operator-package-exports-lib-links.md) and
[IR-20](../improvement-requests/fetch-a-per-context-kubeconfig.md). In
`nix/haskell-packages.nix`, `nagarectl`, `operatorNagarectl`, and `nagare` are nested
`pkgs.symlinkJoin` values. On Darwin that exposes the Haskell executable's `lib/links` link farm in
the installed profile, where it conflicts with other Haskell or Home Manager packages. The
operator tool list includes Pulumi but not `socat`; `nix/dev-shells.nix` contains `socat`, which is
why source-tree testing hides the installed-package failure. Existing installed checks live in
`nix/checks/scripts/nagare-operator-tools.sh` and `nix/checks/platform.nix`.

`scripts/iap-ssh.sh` already supports `recv-file` through a project-scoped IAP tunnel and requires
`socat`. The `nagare` launcher resolves recipes and payload scripts, but no stable recipe exposes
this helper. `scripts/live-test.sh` contains a one-off kubeconfig retrieval and localhost rewrite;
it is test support, not the operator contract. `cli/nagarectl/app/Main.hs` has no kubeconfig or
cluster command group.

Every k3s kubeconfig initially calls its cluster, user, and context `default`. The new command must
retrieve `/etc/rancher/k3s/k3s.yaml`, change those three identifiers to the selected Nagare context,
change `server` to `https://<context-host-name>:6443`, and write mode `0600`. Derive the expected
host name through the same `Nagare.Host.Config`/`TargetProfile` logic used by `host init`; the GCE
instance name is a separate identifier and must not substitute for it.

The `cluster-bootstrap`, `cluster-enable-tls`, observability, and other cluster-mutating recipes in
`justfile` currently trust ambient `KUBECONFIG`. The guard must query the active Kubernetes context
and node list and require the single Nagare server node to equal the expected host. It must fail
closed on missing kubectl, unreachable clusters, zero or multiple unexpected server nodes, or an
unresolved context. Read-only status recipes need not be guarded.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates
installed payload from context state. [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)
owns the context-derived host name. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md)
requires operator tools in the released package. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires the IAP fetch to remain project-confined. No cross-repository ADR is needed.


## Plan of Work

### Milestone 1: make the installed operator package clean and complete

Change the user-facing joins in `nix/haskell-packages.nix` so `nagarectl` and `nagare` expose only
their executables, required `share` data, and Nix support metadata. Prefer `pathsToLink` or copying
the deliberate public surface over recursively deleting an output after construction. Keep absolute
runtime store references intact. Add `pkgs.socat` to the operator tools used by `operatorNagarectl`.

Extend `nix/checks/scripts/nagare-operator-tools.sh` and the corresponding declaration in
`nix/checks/platform.nix` to assert that `nagare` and `nagarectl` have no `lib/links`, that `socat`
is on the installed PATH, and that `nagarectl version --json` works. Add a Darwin profile-install
check that combines the package with a fixture exporting a conflicting `lib/links` path and proves
installation succeeds without priority overrides. Update `docs/user/installation.md` with the fixed
behavior; mention a priority workaround only for older releases.

### Milestone 2: fetch and normalize one context's kubeconfig

Expose the packaged IAP helper through a stable launcher recipe such as `nagare iap-ssh`, retaining
all `_require_target_project` behavior. Add `KubeconfigCommand` and `KubeconfigFetchOpts` in
`cli/nagarectl/app/Main.hs`, implemented by a new
`cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs`. The command is
`nagarectl kubeconfig fetch [--context NAME] [--output FILE]`; the default output is the XDG path.

Resolve the target once, set `NAGARE_CONTEXT` for the child helper, receive the remote file into a
mode-`0600` temporary file beside the destination, normalize it with explicit `kubectl config`
operations under `KUBECONFIG=<temporary-file>`, validate the expected names and server without
printing credentials, then rename atomically. Refuse symlink destinations and unsafe parent
permissions. Do not partially overwrite a previously working file. Tests in
`cli/nagarectl/test/HostSpec.hs` use fake IAP and kubectl executables to verify argv, context
selection, normalized names, endpoint, permissions, atomic failure, and absence of secret content
from output.

### Milestone 3: guard Kubernetes mutation

Create `cli/nagarectl/src/Nagare/Ops/ClusterGuard.hs` with injectable command observations and a
pure verdict. Add `nagarectl cluster guard [--context NAME] [--json]`. Resolve the expected host
name, inspect `kubectl config current-context` and `kubectl get nodes -o json`, and print the selected
Nagare context, kube context, expected node, and observed nodes. Success requires the expected node
and no other Nagare server node; failures name the corrective `nagarectl kubeconfig fetch` command.

Put the guard immediately after the platform/context guard and before the first mutation in every
cloud cluster-mutating `justfile` recipe. Do not guard local-mode recipes with a GCP identity.
Add pure cases and fake-command integration cases to `cli/nagarectl/test/Spec.hs`, plus dry-run
ordering assertions in `nix/checks/scripts/nagare-clone-free-platform.sh`.

### Milestone 4: publish and close

Rewrite the kubeconfig sections of `docs/user/accessing-the-host.md`, `docs/user/cluster-bootstrap.md`,
`docs/user/reference.md`, and the focused part of
`docs/user/onboarding-bring-your-own-project.md`. Remove hard-coded `nagare-01` instructions from
cloud multi-context paths. Update `CHANGELOG.md`, complete IR-10 and IR-20 only after their
acceptance evidence exists, append the bundle log, and revisit ADRs 4 and 7.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`.

```bash
cabal test nagarectl-test
nix build .#checks.aarch64-darwin.nagare-operator-tools --print-build-logs
nix build .#checks.aarch64-darwin.nagare-clone-free-platform --print-build-logs
```

On a disposable test context with fake or disposable cloud resources, exercise the public shape:

```bash
nagarectl kubeconfig fetch --context labs
stat -f '%Lp %N' "$HOME/.config/nagare/kubeconfigs/labs.yaml"
KUBECONFIG="$HOME/.config/nagare/kubeconfigs/labs.yaml" nagarectl cluster guard --context labs
```

Expected evidence includes `600`, context/cluster/user name `labs`, server
`https://labs-nagare:6443`, and a successful guard naming node `labs-nagare`. A fixture with node
`nagare-01` must exit nonzero before a recipe invokes kubectl mutation. Finish with:

```bash
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
nix flake check --print-build-logs
```


## Validation and Acceptance

The Nix package is accepted when it installs next to a profile fixture exporting `lib/links`
without `--priority`, neither public output contains `lib/links`, `socat` resolves from the installed
operator environment, and `nagarectl version --json` exits zero.

Kubeconfig fetch is accepted when selecting context `labs` retrieves only from its project/instance,
writes a `0600` non-symlink file whose cluster, user, and current-context names are `labs`, and whose
server is `https://labs-nagare:6443`. Failed retrieval or normalization leaves any previous file
byte-for-byte unchanged and never prints client certificates or keys.

The cluster guard is accepted when the matching fixture exits zero and a wrong-node, unreachable,
empty, or ambiguous fixture exits nonzero with expected and observed identities. Dry-run tests must
show the guard before the first mutation in each cloud cluster recipe. A workstation with two real
Nagare kubeconfigs must be unable to bootstrap one context while `KUBECONFIG` selects the other.


## Idempotence and Recovery

Package construction and checks are pure. Re-fetching a kubeconfig converges on the current remote
credentials and replaces the destination only after validation. If IAP, SSH, or kubectl fails, fix
the named transport problem and rerun; the prior file remains available. Back up an intentionally
customized kubeconfig before fetching because a successful fetch replaces that context's generated
file. The guard is read-only and safe to repeat. Never weaken it with a generic force flag; correct
the selected context or `KUBECONFIG` instead.


## Interfaces and Dependencies

`cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs` must expose an options-independent normalization
function and an effectful fetch boundary equivalent to:

```haskell
data KubeconfigIdentity = KubeconfigIdentity
  { contextName :: Text, hostName :: Text }

fetchKubeconfig :: FetchOps -> TargetProfile -> FilePath -> IO ()
```

`cli/nagarectl/src/Nagare/Ops/ClusterGuard.hs` must keep observation separate from policy:

```haskell
data ClusterGuardInputs = ClusterGuardInputs
  { nagareContext :: Text, kubeContext :: Text, expectedNode :: Text, observedNodes :: [Text] }

clusterGuardVerdict :: ClusterGuardInputs -> Either Text ()
```

Use the existing `Nagare.Target` and host-name resolution interfaces, `scripts/iap-ssh.sh`, kubectl,
OpenSSH, `gcloud`, and `socat`; do not add a second IAP implementation. The package has no new
external service. ExecPlan 138 consumes `nagarectl cluster guard`, and ExecPlan 139 validates this
plan's public commands.


Revision note (2026-09-14): Completed all four milestones; recorded the filtered package surface,
context-owned atomic kubeconfig contract, reusable cluster guard, documentation and ADR amendments,
IR-10/IR-20 lifecycle closeout, and passing native repository gates.
