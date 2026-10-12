---
id: 70
slug: cli-and-operator-harness-ergonomics
title: "CLI and Operator-Harness Ergonomics"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# CLI and Operator-Harness Ergonomics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [70-cli-and-operator-harness-ergonomics.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/70-cli-and-operator-harness-ergonomics.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

On 2026-06-10 the `nagare-01` cluster was audited live for the first time, and three
papercuts made every step slower and more error-prone than it should have been. This plan
removes all three so the next operator never hits them.

After this change, three concrete things work that did not before:

1. **`nagarectl deploy` (and `db create`, `site deploy`, `task run`) work from inside an
   example app directory with no `--ghc-env` flag.** Today, the config loader inside
   `nagarectl` shells out to `runghc` to compile-and-run an app's `nagare/Config.hs`, and
   `runghc` can only find the `nagare-dsl` Haskell package if a *GHC package-environment
   file* is discoverable. A "GHC package-environment file" is a plain-text file named
   `.ghc.environment.<arch>-<os>-<ghcversion>` (for example
   `.ghc.environment.aarch64-darwin-9.12.3`) that `cabal` writes next to a project; it lists
   the exact package databases and package-ids a `ghc`/`runghc` invocation should see, so
   that `import Nagare.Dsl.Types` resolves. When you run `nagarectl` from an arbitrary app
   directory, no such file is on the search path, so the loader fails. During the audit the
   operator worked around this by hand-capturing the file:
   `( cd cli/nagarectl && cabal exec -- sh -c 'cat "$GHC_ENVIRONMENT"' ) > /tmp/nagare-ghc-env`
   and then passing `--ghc-env /tmp/nagare-ghc-env` to every command. After this plan,
   `nagarectl` locates that file itself. The `--ghc-env` flag and the
   `NAGARE_GHC_ENVIRONMENT` environment variable remain as explicit overrides.

2. **`scripts/iap-ssh.sh ssh nagare-01 -- echo ok` works with no `SSH_USER` set.** Today the
   script defaults its SSH login name to the *OS Login* name derived from your gcloud
   identity (e.g. `nadeem_topagentnetwork_com`), which always fails here with
   `Permission denied (publickey)` because the working login is the dedicated NixOS `deploy`
   user, not an OS-Login account. After this plan the script reads the login name from the
   target profile, defaulting to `deploy`.

3. **`just live-test` stands up a working workstation→cluster kube connection in one
   command and prints the `KUBECONFIG` to use.** Today, connecting `kubectl` to the cluster's
   k3s API server is a five-step manual dance (open an IAP tunnel to port 22, layer an
   `ssh -L` forward of the k3s API port over it, fetch and rewrite the cluster's kubeconfig,
   export `KUBECONFIG`). After this plan, one command does all of it and tells you exactly
   which `KUBECONFIG` to export, after which `kubectl get nodes` succeeds.

You can see all three working with: a `nagarectl deploy` run from
`cluster/examples/prebuilt-image-app/nagare` that renders a Knative Service with no
`--ghc-env`; `scripts/iap-ssh.sh ssh nagare-01 -- echo ok` printing `ok` with no `SSH_USER`
exported; and `just live-test` printing a `KUBECONFIG=…` line that, once exported, makes
`kubectl get nodes` list the `nagare-01` node as `Ready`.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Status: **Complete** — M1–M3 done; 268 tests pass; all three behaviors verified live.

- [x] M1: New library module `Nagare.GhcEnv` (`findGhcEnvIn` + `resolveProjectGhcEnv`); `provisionGhcEnv` in both `app/Main.hs` and `nagared/Main.hs` gained the auto-discovery fallback. (Shared module removes the duplicated helper logic.)
- [x] M1: Updated `cli/nagarectl/cabal.project` comment to describe auto-discovery.
- [x] M1: Added `ghcEnvTests` (4 cases) exercising `findGhcEnvIn` over fixture temp dirs.
- [x] M1: Verified the RAW `nagarectl` binary renders the Service from `cluster/examples/prebuilt-image-app` with no `--ghc-env` and no `NAGARE_GHC_ENVIRONMENT` (it failed `Could not find module Nagare.Dsl.*` before).
- [x] M2: Appended `NAGARE_SSH_USER` (default `deploy`) to `nagare.target.env.example` (after EP-3's `NAGARE_TARGET_PLATFORM`) and `scripts/lib/target.sh` (exported).
- [x] M2: Replaced the OS-Login default in `scripts/iap-ssh.sh` with `SSH_USER="${SSH_USER:-${NAGARE_SSH_USER:-deploy}}"`; deleted `resolve_oslogin_user`; updated the header comment.
- [x] M2: Confirmed shell-only (no `tpSshUser` on the Haskell record) per the Decision Log.
- [x] M2: Verified live — `scripts/iap-ssh.sh ssh nagare-01 -- 'echo ok; whoami'` with no `SSH_USER` prints `ok` / `deploy`.
- [x] M3: Added `scripts/live-test.sh` + the thin `just live-test` recipe; `.live-test/` git-ignored.
- [x] M3: Verified live — `just live-test` prints the `KUBECONFIG` + PIDs; `kubectl get nodes` through it lists `nagare-01 Ready`.
- [x] Final: `cabal build exe:nagarectl exe:nagared && cabal test nagarectl-test` pass (268 tests); shellcheck clean (no new warnings).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M1 resolver approach chosen (per the plan's open question): `getExecutablePath` + cwd
  walk-up, no config-path threading.** `resolveProjectGhcEnv` finds the repo root by walking up
  from *both* the current directory and the executable's path until it sees
  `cli/nagarectl/cabal.project`, then globs `<root>/cli/nagarectl` and `<root>/cli/nagare-dsl`
  for `.ghc.environment.*` (plus the cwd's own ancestors, covering a run from inside
  `cli/nagarectl`). This needed **no `provisionGhcEnv` signature change** and no call-site churn
  — verified working from `cluster/examples/prebuilt-image-app` with the dist-newstyle binary,
  whose path walks up to the repo root. The `cabal exec` fallback is kept only for a checkout
  that has never built. (The plan offered threading the config path as an alternative; it proved
  unnecessary.)

- **EP-3 had already landed `NAGARE_TARGET_PLATFORM` as the last env line**, so M2 simply
  appended `NAGARE_SSH_USER` after it (Integration Point #2, second writer) — no ambiguity, no
  reserved-slot comment needed.

- **The EP-6 GHC-env fix is load-bearing for live ops.** It was independently confirmed during
  EP-2 that the raw `nagarectl` binary cannot load a `Config.hs` without this fix
  (`Could not find module Nagare.Dsl.*`), which is exactly what blocks EP-5's one-command live
  smoke. With M1 landed, a raw-binary `nagarectl deploy` now loads configs from an app dir.

## Decision Log

Record every decision made while working on the plan.

- Decision: M1 hooks the GHC-env auto-resolution into the existing `provisionGhcEnv`
  helper rather than into the loader (`Nagare.Dsl.Load.runConfig`).
  Rationale: `provisionGhcEnv` already runs in every command handler immediately before the
  loader is called (it sets the `GHC_ENVIRONMENT` environment variable, which `runConfig`'s
  child `runghc` reads), and it is the single place that already knows the `--ghc-env` /
  `NAGARE_GHC_ENVIRONMENT` precedence. Adding "if neither is set, discover the project file"
  as the final fallback keeps all env-resolution in one function and leaves the `nagare-dsl`
  library (which must stay free of `nagarectl`-specific path logic) untouched. The loader's
  `runConfig` is not modified.
  Date: 2026-06-11

- Decision: M1 resolves the GHC-env file by **locating the checked-out `nagarectl` package
  directory and reading its `.ghc.environment.<arch>-<os>-<ghcver>` file**, falling back to
  invoking `cabal` only if no such file exists.
  Rationale: `cabal.project` already sets `write-ghc-environment-files: always`, so a
  developer who has ever run `cabal build` in `cli/nagarectl` already has the file on disk;
  discovering it is instant and needs no `cabal` subprocess. Shelling out to
  `cabal exec -- runghc` on every deploy would add multi-second cabal-resolution latency to a
  command that the operator runs repeatedly, and would fail in environments where the cabal
  store is not writable. The cabal path is kept only as a last resort. See Plan of Work M1
  for the exact discovery order.
  Date: 2026-06-11

- Decision: M2 adds `NAGARE_SSH_USER` to the **shell side only**
  (`scripts/lib/target.sh` + `nagare.target.env.example`), not to the Haskell
  `Nagare.Target.TargetProfile` record.
  Rationale: the only consumer is `scripts/iap-ssh.sh`, a bash script that sources
  `scripts/lib/target.sh`. No Haskell code reads an SSH user today, and `nagarectl` never
  SSHes to the VM. Adding `tpSshUser` to the record would be dead code. If a future plan
  needs the SSH user in `nagarectl`, it can add the field then. This is recorded here so the
  integration contract with EP-3 (docs/plans/67) is unambiguous: EP-3 owns the Haskell
  record's shape; EP-6 only appends a shell variable to the same `nagare.target.env` schema.
  Date: 2026-06-11

- Decision: M3 puts the connection logic in `scripts/live-test.sh` invoked by a thin
  `just live-test` recipe, rather than inlining a long multi-line recipe in the justfile or
  building it into `nagarectl`.
  Rationale: the user's rule is "don't hide things in the control plane that belong in
  scripts, and don't hide control-plane logic in scripts." This harness is neither — it is a
  pure dev/ops *connection convenience* (open a tunnel, rewrite a kubeconfig), not
  application or cluster-state logic, so a script + justfile target is the appropriate home.
  The justfile stays a thin wrapper (matching every other recipe in it); the multi-step body
  lives in a script because justfile recipe lines run in independent shells, which makes the
  tunnel-lifecycle and trap handling this needs impractical to express inline. The harness
  reuses `scripts/iap-ssh.sh` for the tunnel.
  Date: 2026-06-11

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All three papercuts are gone, each verified live:

1. **`nagarectl` auto-resolves the loader's GHC environment.** `Nagare.GhcEnv.resolveProjectGhcEnv`
   discovers the project's `.ghc.environment.*` and `provisionGhcEnv` exports it when neither
   `--ghc-env` nor `NAGARE_GHC_ENVIRONMENT` is set; both overrides still win. The raw binary now
   renders a Service from an example app dir with no flag (it failed before). 4 new unit tests over
   `findGhcEnvIn`; 268 tests green. The logic lives in one library module shared by `app/Main.hs` and
   `nagared/Main.hs`, removing the prior duplicated helper.

2. **`iap-ssh.sh` defaults its SSH user to `deploy` from the profile.** `NAGARE_SSH_USER` (shell-side
   only, per the EP-3↔EP-6 integration contract) is mirrored in `nagare.target.env.example` and
   `scripts/lib/target.sh`; the OS-Login derivation is deleted. `iap-ssh.sh ssh nagare-01 -- whoami`
   prints `deploy` with no `SSH_USER` set, and an explicit `SSH_USER` still overrides.

3. **`just live-test` is the one-command harness.** It fetches the kubeconfig, opens the IAP port-22
   tunnel, layers the `ssh -L` API forward, rewrites the server, and prints the `KUBECONFIG` + the
   PIDs to kill. `kubectl get nodes` through it lists `nagare-01 Ready`.

Gaps: none against scope. The Haskell `TargetProfile` record was deliberately left untouched (no
`tpSshUser`) — Integration Point #2 honored. Lesson: the `getExecutablePath`+cwd walk-up made M1 a
zero-call-site-churn change, and proving each fix on the live box (rather than only in tests) caught
that the harness's background tunnels must use `nohup`+`disown` to survive the launching shell.

