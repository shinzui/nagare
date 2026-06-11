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


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it fully before editing.

`nagare` is a small personal platform-as-a-service that targets exactly one Google Cloud
Platform (GCP) project at a time. Operators interact with it through `nagarectl` (a Haskell
command-line tool) and a handful of bash scripts under `scripts/`. Which GCP project is
targeted is read from a *target profile* — a git-ignored file `nagare.target.env` at the
repository root, a sequence of `export VAR=value` lines. The tracked
`nagare.target.env.example` documents the schema and ships the historic `tan-nb-exp` values
as a worked example; with no profile present, built-in defaults reproduce that historic
setup. The precedence rule, used everywhere, is: **a value already set in the environment >
the profile file > the built-in default.**

There are three independent surfaces this plan touches. They do not interact, so the three
milestones are independent.

### Surface 1 — the config loader and its GHC package environment

`nagarectl`'s deploy-class commands take a *config-as-program*: an app ships a Haskell file
(by convention `nagare/Config.hs`) whose `main` prints a JSON description of the deployment.
For example, `cluster/examples/prebuilt-image-app/nagare/Config.hs` is a real such file: it
imports `Nagare.Dsl.Build`, `Nagare.Dsl.Config`, `Nagare.Dsl.Presets`, and
`Nagare.Dsl.Types` (all from the local `nagare-dsl` library) and calls `emitDeployment`.

To turn that file into JSON, the loader function
`runConfig :: FilePath -> IO (Either LoadError ByteString)` in
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs` (around line 966) runs the config with `runghc`:

```haskell
result <-
  try @IOException $
    readProcessWithExitCode "runghc" ["-XGHC2024", "-i" <> configDir, path] ""
```

`runghc` is GHC's "run a Haskell script" front-end. By itself it sees only GHC's *boot*
packages (base, containers, …) — it does **not** see `nagare-dsl`. For the `import
Nagare.Dsl.*` lines to resolve, `runghc` must be told where the `nagare-dsl` package
database lives. The standard mechanism is a *GHC package-environment file*: a file named
`.ghc.environment.<arch>-<os>-<ghcversion>` listing `package-db` and `package-id` lines.
`runghc`/`ghc` discover it two ways:

- via the `GHC_ENVIRONMENT` environment variable, if set to an absolute path to such a file; or
- by searching the current directory and its parents for a file matching
  `.ghc.environment.*` for the running compiler's arch/os/version.

`cabal` materializes this file automatically because both
`cli/nagarectl/cabal.project` and `cli/nagare-dsl/cabal.project` set
`write-ghc-environment-files: always`. On this workstation the file is
`cli/nagarectl/.ghc.environment.aarch64-darwin-9.12.3` (and an identical one under
`cli/nagare-dsl/`). It is git-ignored (`cli/nagarectl/.gitignore` lists `.ghc.environment.*`)
and is produced the first time `cabal build` runs in that directory.

The problem: when an operator runs `nagarectl deploy` from inside an app directory like
`cluster/examples/prebuilt-image-app/nagare`, neither the current directory nor its parents
contain a `.ghc.environment.*` file, and `GHC_ENVIRONMENT` is unset, so `runghc` cannot find
`nagare-dsl` and the config fails to compile.

`nagarectl` already has a partial fix: each command handler calls
`provisionGhcEnv :: Maybe FilePath -> IO ()` (in `cli/nagarectl/app/Main.hs`, around line
2627) **before** invoking the loader. Today that helper is:

```haskell
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Nothing -> pure ()
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
```

It honors the `--ghc-env FILE` flag (parsed by `ghcEnvOpt`, around line 670, wired into
`deployOptsParser`, `siteDeployOptsParser`, `siteCommonOptsParser`, `storeCommonOptsParser`,
and the task/db parsers) and the `NAGARE_GHC_ENVIRONMENT` environment variable, exporting
whichever is set as an absolute `GHC_ENVIRONMENT`. When **neither** is set it does nothing —
which is exactly the audit failure. A near-identical `provisionGhcEnv` exists in the daemon
entry point `cli/nagarectl/nagared/Main.hs` (around line 136) and must get the same treatment.

The call sites that depend on `provisionGhcEnv` (all in `cli/nagarectl/app/Main.hs`) are at
lines 1729 (`runDeploy`), 1870, 2000, 2014, 2064, 2083, 2096, 2137/2158 (`enrichFromConfig`),
2239, 2317, 2337, and 2373 — i.e. deploy, site deploy/common, db create, and the task and
store/storage commands. Fixing the single helper fixes all of them; no call site changes.

### Surface 2 — `scripts/iap-ssh.sh` and the SSH user

`scripts/iap-ssh.sh` is the IAP-tunneled SSH/SCP wrapper every script and runbook uses to
reach the VM. (IAP = Google's Identity-Aware Proxy; the project's firewall permits inbound
only on port 22, tunneled through IAP, so direct SSH is impossible and this wrapper opens a
`gcloud compute start-iap-tunnel` and routes OpenSSH through it.) It already sources the
shared target library:

```bash
source "$(dirname "$0")/lib/target.sh"
_require_target_project
```

`scripts/lib/target.sh` loads `nagare.target.env` (if present), sets `TARGET_PROJECT` /
`TARGET_REGION` / `TARGET_ZONE` with the historic fallbacks, and exposes
`_require_target_project`, the fail-closed guard that refuses to run unless gcloud's active
project equals `TARGET_PROJECT`.

The defect is the SSH login default. `iap-ssh.sh` currently computes it from the operator's
gcloud identity using GCP's OS-Login derivation:

```bash
resolve_oslogin_user() {
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null \
              | head -n1)"
  ...
  echo "${account}" | tr '@.' '__' | tr '[:upper:]' '[:lower:]'
}

SSH_USER="${SSH_USER:-$(resolve_oslogin_user)}"
```

That yields, e.g., `nadeem_topagentnetwork_com`, which is **not** a login the VM accepts: the
working account is the dedicated NixOS `deploy` user. So every invocation without an explicit
`SSH_USER` fails with `Permission denied (publickey)`. The fix is to read the SSH user from
the target profile, defaulting to `deploy`, with the same env > profile > default precedence
used everywhere.

### Surface 3 — workstation→cluster kube connection

The cluster runs k3s (a lightweight Kubernetes) on the single VM `nagare-01`. The k3s API
server listens on `127.0.0.1:6443` on the VM, and k3s writes a *kubeconfig* (the file telling
`kubectl` how to authenticate) at `/etc/rancher/k3s/k3s.yaml` with mode `0644`. That file
names the server as `https://127.0.0.1:6443`; the k3s serving certificate's subject-alternative
names include `127.0.0.1`, so TLS validates only when the client reaches the API through an
address that presents as `127.0.0.1`.

Because the firewall exposes only port 22 (over IAP), reaching the API from a workstation is a
multi-step process, documented across several master plans
(`docs/masterplans/7-persistent-storage-for-nagare.md` lines 329–330,
`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md` lines 138–140,
`docs/plans/35-…` lines 112–121) but never automated:

1. Open an IAP tunnel to `nagare-01:22` on a local port.
2. Over the SSH session through that tunnel, add a local port-forward
   `-L 16443:127.0.0.1:6443` so workstation `127.0.0.1:16443` reaches the VM's k3s API.
3. Fetch `/etc/rancher/k3s/k3s.yaml` from the VM.
4. Rewrite its `server:` from `https://127.0.0.1:6443` to `https://127.0.0.1:16443` (the cert
   still validates because the SAN list includes `127.0.0.1`).
5. Point `KUBECONFIG` at the rewritten copy.

`scripts/iap-ssh.sh` already implements steps that this can reuse: its `recv-file` subcommand
streams a root-readable remote file to a local path (so step 3 is `iap-ssh.sh recv-file
nagare-01 /etc/rancher/k3s/k3s.yaml <local>` — note `recv-file` uses `sudo cat`, which the VM
allows for the `deploy` user, and is needed because `k3s.yaml` may not be group-readable), and
its tunneling helpers know how to wait for an IAP tunnel to come up.

### Integration with EP-3 (docs/plans/67), the first writer of the profile schema

The parent MasterPlan (`docs/masterplans/13-…`, Integration Point #2) designates the
target-profile schema — the Haskell record `Nagare.Target.TargetProfile`, the
`nagare.target.env(.example)` file, and `scripts/lib/target.sh` — as a shared artifact with
**two** writers. EP-3 (`docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md`)
is the *first* writer: it adds a target-**architecture** field (the MasterPlan names it
`NAGARE_TARGET_PLATFORM` in the env file, default `linux/amd64`, mirrored as a
`targetPlatform`-style field on the Haskell record). EP-6 (this plan) is the *second* writer:
it **appends** `NAGARE_SSH_USER` (default `deploy`) to the same env-file schema and to
`scripts/lib/target.sh`, following EP-3's example-file ordering and the same precedence rule.

At the time of writing, `docs/plans/67` is still a skeleton (its body sections are
placeholders), so the exact env-var name and example-file position EP-3 lands cannot be quoted
verbatim. This plan therefore states a coordination rule rather than a fixed insertion point:
**append `NAGARE_SSH_USER` after EP-3's architecture line if EP-3 has already landed; if EP-6
lands first, add `NAGARE_SSH_USER` and leave a comment block reserving the architecture
slot's documented name (`NAGARE_TARGET_PLATFORM`) so EP-3 slots in cleanly.** Either ordering
is safe because the two variables are independent. The Concrete Steps below give both forms.
Per the Decision Log, EP-6 adds `NAGARE_SSH_USER` to the **shell side only**; it does not
touch the Haskell `TargetProfile` record, so there is no record-shape conflict with EP-3 to
resolve.


## Plan of Work

The work is three independent milestones. They share no files except the
`nagare.target.env.example` / `scripts/lib/target.sh` schema (M2), so they may be implemented
in any order. The recommended order is M1, M2, M3 — M1 is the highest-value fix and entirely
self-contained in `nagarectl`.

### Milestone M1 — `nagarectl` auto-resolves the loader's GHC environment

Scope: make every deploy-class `nagarectl` command work from an app directory with no
`--ghc-env`. At the end, running `nagarectl deploy --dry-run` from
`cluster/examples/prebuilt-image-app/nagare` renders a Knative Service without any
`--ghc-env` flag or `NAGARE_GHC_ENVIRONMENT` export.

The single edit is to `provisionGhcEnv` in `cli/nagarectl/app/Main.hs` (around line 2627) and
its twin in `cli/nagarectl/nagared/Main.hs` (around line 136). Today the helper exports
`GHC_ENVIRONMENT` only when `--ghc-env` or `NAGARE_GHC_ENVIRONMENT` is set. Add a third,
final fallback: when neither is set, **discover the project's `.ghc.environment.*` file and
export it**. The discovery is a new pure-ish IO helper, `resolveProjectGhcEnv :: IO (Maybe FilePath)`,
that tries the following in order and returns the first hit (all paths absolute):

1. **The checked-out `nagarectl` package directory.** Locate the repository root, then look
   for `cli/nagarectl/.ghc.environment.<arch>-<os>-<ghcver>` and
   `cli/nagare-dsl/.ghc.environment.<arch>-<os>-<ghcver>`. The `<arch>-<os>-<ghcver>` triple
   is the running compiler's; rather than reconstruct it, glob for `.ghc.environment.*` in
   those two directories and take the first match (there is normally exactly one). Locating
   the repo root: `nagarectl` knows its own package layout, but the most robust approach that
   does not depend on the operator's cwd is to walk up from the *config file's directory*
   (the `path` the command was given, e.g. the `-f`/`--file` value, whose default is
   `nagare/Config.hs`) and from the current working directory, looking for a directory that
   contains `cli/nagarectl/cabal.project`; that directory is the repo root. Because
   `provisionGhcEnv` does not currently receive the config path, pass it in: change the
   signature to `provisionGhcEnv :: Maybe FilePath -> Maybe FilePath -> IO ()` where the
   second argument is the config file path (each call site already has it — e.g. `runDeploy`
   has `dopts ^. #file`), or, simpler and with no call-site churn, have `resolveProjectGhcEnv`
   walk up only from the current working directory and from the directory of the
   `nagarectl` executable (`System.Environment.getExecutablePath`). Choose the
   getExecutablePath approach if it reliably lands inside the source tree in the dev shell;
   otherwise pass the config path. Record the choice in the Decision Log during
   implementation.

2. **Ask cabal, as a last resort.** If no file is found on disk, run
   `cabal exec --project-dir <repo>/cli/nagarectl -- sh -c 'printf %s "$GHC_ENVIRONMENT"'`
   and capture stdout; if it names a readable file, use it. This regenerates the env file on
   demand for a fresh checkout that has never built. Guard it so a missing `cabal` or a
   non-zero exit degrades gracefully to "no env found" (the loader will then produce its
   existing, clear compile error rather than a crash).

If `resolveProjectGhcEnv` returns `Just file`, export it as absolute `GHC_ENVIRONMENT`
(reusing the existing `makeAbsolute`/`setEnv` lines). If it returns `Nothing`, do nothing —
preserving today's behavior exactly (the loader then fails with the same `CompileError` it
does now, which is the correct signal that the project has never been built).

The precedence after this change is: `--ghc-env` flag > `NAGARE_GHC_ENVIRONMENT` env >
auto-discovered project file > (nothing). Explicit overrides still win, so a power user
pointing at a custom env file is unaffected.

Update the comment in `cli/nagarectl/cabal.project` (lines 12–16) to say the env file is now
auto-discovered and `--ghc-env` is an override, not a requirement.

Add a unit test in `cli/nagarectl/test/` exercising `resolveProjectGhcEnv` (or whatever the
final exported name is): from a temp directory containing a synthetic
`cli/nagarectl/.ghc.environment.aarch64-darwin-9.12.3` and a `cabal.project`, assert the
resolver returns that file's absolute path; from a temp directory with neither, assert it
returns `Nothing` (with `cabal` discovery disabled or stubbed so the test is hermetic). To
make the function testable, factor the directory-walk and glob into a pure-over-`FilePath`
core (e.g. `findGhcEnvIn :: [FilePath] -> IO (Maybe FilePath)`) that the unit test can drive
against fixture directories without touching the real repo. Note: `provisionGhcEnv` lives in
the `app/Main.hs` executable, which the test suite does not import; to test it, move
`resolveProjectGhcEnv`/`findGhcEnvIn` into a library module under
`cli/nagarectl/src/Nagare/` (e.g. `Nagare.GhcEnv`) and have both `app/Main.hs` and
`nagared/Main.hs` import it. This also removes the current duplication of `provisionGhcEnv`
across the two entry points.

### Milestone M2 — `iap-ssh.sh` reads its SSH user from the target profile

Scope: make `scripts/iap-ssh.sh ssh nagare-01 -- echo ok` succeed with no `SSH_USER` set, by
defaulting the SSH user to `deploy` from the target profile instead of the OS-Login name. At
the end, the script logs in as `deploy` by default and an operator can still override with
`SSH_USER=…`.

First, extend the schema (coordinating with EP-3 per the integration note above):

- In `nagare.target.env.example`, append a documented `export NAGARE_SSH_USER=deploy` line.
  Place it after EP-3's `NAGARE_TARGET_PLATFORM` line if that has already landed; otherwise
  add it in the "Derived names" group and, if EP-3 has not yet landed, include a short
  reserved-name comment so EP-3's insertion is unambiguous. Document it as: "Linux user
  `iap-ssh.sh` logs in as. The dedicated NixOS deploy user; override only if your host uses a
  different operator account."

- In `scripts/lib/target.sh`, after the existing `TARGET_*` derivations, add:

  ```bash
  NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"
  ```

  and `export NAGARE_SSH_USER` so `iap-ssh.sh` (which sources this file) sees it. This honors
  env > profile (the profile, if present, is sourced just above and would have set it) >
  default `deploy`.

Then change `scripts/iap-ssh.sh`:

- Replace the OS-Login default line
  `SSH_USER="${SSH_USER:-$(resolve_oslogin_user)}"` (line 60) with
  `SSH_USER="${SSH_USER:-${NAGARE_SSH_USER:-deploy}}"`. This keeps an explicit `SSH_USER`
  env override winning, then the profile-provided `NAGARE_SSH_USER`, then `deploy`.

- Delete the now-unused `resolve_oslogin_user` function (lines 49–58) and update the header
  comment block (lines 30–35) so the `SSH_USER` documentation reads "Defaults to
  `NAGARE_SSH_USER` from the target profile, or `deploy`" instead of the OS-Login derivation.

Per the Decision Log, do **not** add an SSH-user field to the Haskell
`Nagare.Target.TargetProfile` record — no Haskell consumer exists, so it would be dead code.

### Milestone M3 — `just live-test` one-command workstation harness

Scope: a single `just live-test` that opens the tunnel, fetches and rewrites the kubeconfig,
and prints the `KUBECONFIG` to export. At the end, running `just live-test` prints a
`KUBECONFIG=/…` line and a hint, and after exporting it `kubectl get nodes` lists `nagare-01`
as `Ready`.

Create `scripts/live-test.sh` (executable, `set -euo pipefail`) that:

1. Sources `scripts/lib/target.sh` and calls `_require_target_project` (same preamble as
   `iap-ssh.sh`), so it cannot act on the wrong project. Uses `NAGARE_INSTANCE_NAME`
   (default `nagare-01`) as the instance.

2. Fetches the cluster kubeconfig with the existing wrapper:
   `scripts/iap-ssh.sh recv-file "${INSTANCE}" /etc/rancher/k3s/k3s.yaml "${KCFG}"` where
   `KCFG` is a stable per-repo path (e.g. `"${NAGARE_REPO_ROOT}/.live-test/kubeconfig.yaml"`,
   git-ignored). `recv-file` streams the root-owned file via `sudo cat` and login as the
   `deploy` user resolved in M2, so this works without group-readable perms.

3. Opens a long-lived port-forward of the k3s API over the IAP path. Two options, decide in
   implementation: (a) reuse `scripts/iap-ssh.sh tunnel "${INSTANCE}" <remote> <local>` —
   but that tunnels TCP to a *port on the VM*, and k3s listens on `127.0.0.1:6443` which IAP
   cannot target directly (IAP only forwards 22); so (b) the correct layering is an SSH
   `-L 16443:127.0.0.1:6443` forward established *through* the iap-ssh ProxyCommand tunnel.
   The cleanest reuse is to add a small mode to `iap-ssh.sh` — or invoke `ssh` with the same
   ProxyCommand `iap-ssh.sh` builds — that runs `ssh -N -L 16443:127.0.0.1:6443` over the
   port-22 IAP tunnel and backgrounds it. Implementation note: the simplest robust path is a
   dedicated helper in `live-test.sh` that calls `scripts/iap-ssh.sh tunnel "${INSTANCE}" 22
   <localport>` to get the port-22 tunnel PID and local port, then runs a backgrounded
   `ssh -N -L 16443:127.0.0.1:6443 -o ProxyCommand=… deploy@localhost` over it; OR, preferred
   for least new code, extend `iap-ssh.sh` with an `ssh-forward` subcommand
   `iap-ssh.sh ssh-forward <instance> <localport>:<vmhost>:<vmport>` that backgrounds the
   `ssh -N -L …` and prints its PID. Decide and record which; reusing `iap-ssh.sh`'s tunnel
   plumbing is the requirement, the exact subcommand surface is a detail.

4. Rewrites the kubeconfig's server: replace `https://127.0.0.1:6443` with
   `https://127.0.0.1:16443` (the forwarded local port). Use a portable in-place edit
   (`sed` with a temp file, not GNU-only `sed -i` flags, since this runs on macOS).

5. Prints, on stdout, exactly:

   ```text
   KUBECONFIG=/abs/path/.live-test/kubeconfig.yaml
   # k3s API forwarded to https://127.0.0.1:16443 (tunnel pid <PID>)
   # run: export KUBECONFIG=/abs/path/.live-test/kubeconfig.yaml && kubectl get nodes
   # when done: kill <PID>
   ```

   The forward is left running in the background (the operator kills it when done), because a
   foreground harness that tears the tunnel down on exit would make the printed `KUBECONFIG`
   useless. The PID is printed so it can be killed. Add `.live-test/` to `.gitignore`.

Add the thin recipe to `justfile`, matching the file's existing "thin wrapper" style and
header convention (each recipe names its owning plan):

```text
# EP-6 (docs/plans/70-cli-and-operator-harness-ergonomics.md): stand up a
# workstation->cluster kube connection in one command — open the IAP port-22
# tunnel, layer an ssh -L forward of the k3s API (127.0.0.1:6443 -> :16443),
# fetch /etc/rancher/k3s/k3s.yaml and rewrite its server: to the forwarded
# port, and print the KUBECONFIG to export. Reuses scripts/iap-ssh.sh.
live-test:
    scripts/live-test.sh
```


## Concrete Steps

All commands assume you are in the repository root `/Users/shinzui/Keikaku/bokuno/nagare`
unless a different working directory is shown, and that you have entered the dev shell
(`nix develop`, or `direnv allow` once so direnv loads it). Cloud steps assume gcloud's active
project equals the configured target (the fail-closed guard enforces this).

### M1 steps

1. Create the library module `cli/nagarectl/src/Nagare/GhcEnv.hs` exporting
   `resolveProjectGhcEnv :: IO (Maybe FilePath)` and the testable core
   `findGhcEnvIn :: [FilePath] -> IO (Maybe FilePath)` (returns the first existing
   `.ghc.environment.*` found by globbing each directory in the list). Add `Nagare.GhcEnv` to
   the library's `exposed-modules` in `cli/nagarectl/nagarectl.cabal` (the `library` stanza,
   `hs-source-dirs: src`).

2. In `cli/nagarectl/app/Main.hs`, import `Nagare.GhcEnv` and rewrite `provisionGhcEnv`
   (around line 2627) so its final fallback calls `resolveProjectGhcEnv` and exports the
   result as absolute `GHC_ENVIRONMENT`. Apply the identical change to
   `cli/nagarectl/nagared/Main.hs` (around line 136), or have it import and call the same
   helper.

3. Update the comment block in `cli/nagarectl/cabal.project` (lines 12–16) to describe
   auto-discovery.

4. Build and run the new test:

   ```bash
   cd cli/nagarectl && cabal build exe:nagarectl && cabal test nagarectl-test
   ```

   Expected: the build succeeds and the test suite reports all passing, including the new
   `resolveProjectGhcEnv`/`findGhcEnvIn` cases.

5. Prove the end-to-end behavior with no `--ghc-env`. First ensure the env file exists
   (it is produced by the build above). Then, from the example app directory:

   ```bash
   cd cluster/examples/prebuilt-image-app/nagare
   cabal --project-dir=../../../../cli/nagarectl run exe:nagarectl -- deploy --dry-run
   ```

   (or, if a `nagarectl` is already on PATH from the dev shell, simply `nagarectl deploy
   --dry-run` from this directory). Expected: the command prints the rendered Knative Service
   YAML and the computed app URL and exits 0, with **no** `--ghc-env` flag and no
   `NAGARE_GHC_ENVIRONMENT` set. Before the fix the same command fails with a `CompileError`
   complaining it cannot find `Nagare.Dsl.*`.

### M2 steps

1. Edit `nagare.target.env.example`: append the `NAGARE_SSH_USER` line per the coordination
   rule with EP-3. If EP-3 has landed (the file already contains `NAGARE_TARGET_PLATFORM`),
   add `NAGARE_SSH_USER` immediately after it:

   ```bash
   # --- Operator access ---

   # Linux user scripts/iap-ssh.sh logs in as. The dedicated NixOS deploy user;
   # override only if your host uses a different operator account.
   export NAGARE_SSH_USER=deploy
   ```

   If EP-3 has not landed, add the same block at the end of the file.

2. Edit `scripts/lib/target.sh`: after the `TARGET_ZONE` line (line 35), add

   ```bash
   # SSH login user for scripts/iap-ssh.sh (env > profile > default 'deploy').
   NAGARE_SSH_USER="${NAGARE_SSH_USER:-deploy}"
   export NAGARE_SSH_USER
   ```

3. Edit `scripts/iap-ssh.sh`: delete `resolve_oslogin_user` (lines 49–58); replace line 60
   with `SSH_USER="${SSH_USER:-${NAGARE_SSH_USER:-deploy}}"`; update the header `SSH_USER`
   comment (lines 30–35).

4. Verify with no `SSH_USER` set (first start the VM if it is stopped):

   ```bash
   unset SSH_USER
   scripts/iap-ssh.sh ssh nagare-01 -- echo ok
   ```

   Expected output ends with `ok`. Confirm it logged in as `deploy`:

   ```bash
   scripts/iap-ssh.sh ssh nagare-01 -- whoami
   ```

   Expected: `deploy`.

### M3 steps

1. Create `scripts/live-test.sh` per the Plan of Work, make it executable
   (`chmod +x scripts/live-test.sh`), and add `.live-test/` to `.gitignore`.

2. Add the `live-test` recipe to `justfile`.

3. Run it (VM started, gcloud project = target):

   ```bash
   just live-test
   ```

   Expected stdout (paths and PID will differ):

   ```text
   KUBECONFIG=/Users/shinzui/Keikaku/bokuno/nagare/.live-test/kubeconfig.yaml
   # k3s API forwarded to https://127.0.0.1:16443 (tunnel pid 54321)
   # run: export KUBECONFIG=… && kubectl get nodes
   # when done: kill 54321
   ```

4. Export and probe:

   ```bash
   export KUBECONFIG=/Users/shinzui/Keikaku/bokuno/nagare/.live-test/kubeconfig.yaml
   kubectl get nodes
   ```

   Expected: one node, `nagare-01`, `STATUS Ready`.


## Validation and Acceptance

Acceptance is the three observable behaviors from Purpose, each with a before/after contrast.

**M1.** From `cluster/examples/prebuilt-image-app/nagare`, `nagarectl deploy --dry-run` exits
0 and prints rendered Knative YAML with **no** `--ghc-env` flag and no `NAGARE_GHC_ENVIRONMENT`
in the environment. Negative control: temporarily renaming the project's
`.ghc.environment.*` files away and running with `cabal` discovery disabled should reproduce
the old `CompileError`, confirming the resolver is what makes it work. Unit acceptance:
`cd cli/nagarectl && cabal build exe:nagarectl && cabal test nagarectl-test` passes, including
the `findGhcEnvIn` fixture cases (finds a planted env file; returns `Nothing` when none
exists).

**M2.** With `SSH_USER` unset, `scripts/iap-ssh.sh ssh nagare-01 -- echo ok` prints `ok` and
`scripts/iap-ssh.sh ssh nagare-01 -- whoami` prints `deploy`. Before the change the same
unset-`SSH_USER` invocation fails with `Permission denied (publickey)`. Override still works:
`SSH_USER=someoneelse scripts/iap-ssh.sh ssh nagare-01 -- whoami` attempts `someoneelse`.
Schema check: `grep NAGARE_SSH_USER nagare.target.env.example scripts/lib/target.sh` shows the
new variable in both, defaulting to `deploy`.

**M3.** `just live-test` prints a `KUBECONFIG=…` line and a tunnel PID; after
`export KUBECONFIG=…`, `kubectl get nodes` lists `nagare-01` as `Ready`. Before this plan the
same outcome required five manual steps. Cleanup works: `kill <PID>` from the printed hint
tears the forward down and a subsequent `kubectl get nodes` then fails to connect (proving the
forward, not some pre-existing context, carried the connection).

The combined build/test gate for the whole plan:

```bash
cd cli/nagarectl && cabal build exe:nagarectl && cabal test nagarectl-test
```

must pass. Shell changes (M2, M3) are validated by the live invocations above; if `shellcheck`
is available in the dev shell, run `shellcheck scripts/iap-ssh.sh scripts/live-test.sh
scripts/lib/target.sh` and expect no new warnings.


## Idempotence and Recovery

**M1** is pure code; rebuilding is idempotent. The auto-resolver only *reads* an env file and
sets a process-local environment variable — it never writes repo files (the cabal-fallback,
if reached, writes the same `.ghc.environment.*` cabal would write anyway, in the cabal store
/ package dir, which is already git-ignored). If resolution misbehaves, set `--ghc-env` or
`NAGARE_GHC_ENVIRONMENT` to bypass it entirely, restoring the pre-plan path.

**M2** is a default-only change: existing callers that set `SSH_USER` explicitly are
unaffected, and re-running the edits is safe (the env-file line and the `target.sh` default
are plain assignments). Recovery is trivial — revert the three edits. The deleted
`resolve_oslogin_user` is recoverable from git history if some other caller is later found to
need OS-Login (none exists today; `grep -rn resolve_oslogin_user scripts/` before deleting to
confirm it is unreferenced elsewhere).

**M3** can be run repeatedly. Each run rewrites `.live-test/kubeconfig.yaml` afresh and opens
a new tunnel; stale tunnels from prior runs are orphaned background processes — the script
should, at start, `pkill -f 'start-iap-tunnel .* 16443'`-style cleanup or simply pick a fresh
local port and tell the operator the PID, accepting that the operator kills old ones. Prefer:
print the PID and let the operator manage it (documented in the printed hint), and make the
local forward port configurable via an env var (`LIVE_TEST_PORT`, default 16443) so a second
concurrent run does not collide. If the VM is stopped, the harness fails fast at the
`recv-file`/tunnel step with the same IAP error `iap-ssh.sh` already surfaces; start the VM
and re-run.


## Interfaces and Dependencies

**M1 — Haskell.** New library module `Nagare.GhcEnv` (file
`cli/nagarectl/src/Nagare/GhcEnv.hs`), added to `exposed-modules` in
`cli/nagarectl/nagarectl.cabal`. Exports at least:

```haskell
-- | First existing ".ghc.environment.*" file across the given directories
-- (absolute path), or Nothing. Pure-over-FilePath core, used by the test.
findGhcEnvIn :: [FilePath] -> IO (Maybe FilePath)

-- | Discover the project's GHC package-environment file: search the checked-out
-- cli/nagarectl and cli/nagare-dsl package directories, then fall back to asking
-- cabal. Nothing if none is found.
resolveProjectGhcEnv :: IO (Maybe FilePath)
```

`provisionGhcEnv` in `cli/nagarectl/app/Main.hs` and `cli/nagarectl/nagared/Main.hs` gains a
final fallback that calls `resolveProjectGhcEnv` and, on `Just`, does the existing
`makeAbsolute`/`setEnv "GHC_ENVIRONMENT"` work. Uses `System.Directory`
(`doesFileExist`, `makeAbsolute`, `getCurrentDirectory`, `listDirectory`/`getDirectoryContents`),
`System.Environment` (`lookupEnv`, `setEnv`, `getExecutablePath`), and `System.Process`
(`readProcessWithExitCode`) for the cabal fallback — all already available to the package. No
new Hackage dependency. The loader `Nagare.Dsl.Load.runConfig` is **unchanged**: it continues
to read `GHC_ENVIRONMENT`/the discoverable file as before; M1 only ensures one of those is set.

**M2 — shell.** New target-profile variable `NAGARE_SSH_USER` (default `deploy`) added to
`nagare.target.env.example` and exported by `scripts/lib/target.sh`. `scripts/iap-ssh.sh`
consumes it via `SSH_USER="${SSH_USER:-${NAGARE_SSH_USER:-deploy}}"`. No Haskell interface
changes (the `Nagare.Target.TargetProfile` record is **not** extended — see Decision Log).
This is the second write to MasterPlan 13's Integration Point #2 (target-profile schema);
EP-3 (docs/plans/67) is the first writer and owns the Haskell record shape and the example
file's ordering.

**M3 — shell + justfile.** New script `scripts/live-test.sh` and new `live-test` recipe in
`justfile`. Depends on `scripts/iap-ssh.sh` (its `recv-file` and tunnel plumbing) and
`scripts/lib/target.sh` (project guard, `NAGARE_INSTANCE_NAME`, and the M2 `NAGARE_SSH_USER`).
External tools used at runtime: `gcloud` (IAP tunnel, via `iap-ssh.sh`), `ssh` (the
`-L` forward), `sed` (server rewrite), `kubectl` (operator's verification, not the script's).
Output contract: prints `KUBECONFIG=<abs path>` on its own line plus comment hints; leaves a
backgrounded `ssh -L` forward whose PID it prints. New git-ignored directory `.live-test/`.
