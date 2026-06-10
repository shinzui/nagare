---
id: 39
slug: nagarectl-doctor-health-checks-with-remediation-hints
title: "nagarectl doctor health checks with remediation hints"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# nagarectl doctor health checks with remediation hints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`nagarectl server status` (built by the sibling plan
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`) tells an operator
*what* the platform's state is — a one-screen aligned table of `OK`/`WARN`/`UNKNOWN`/`FAIL` lines.
What it does not tell a newcomer is *what a red line means* or *what to type to fix it*. When the VM
line reads `FAIL TERMINATED`, the operator still has to know that the fix is
`gcloud compute instances start nagare-01 --zone=us-west1-a`; when a control-plane line reads `FAIL`,
they still have to know which `kubectl rollout status` to run and which `cluster/bootstrap/<component>/README.md`
to read. That knowledge lives in operators' heads and in scattered runbooks. This plan moves it into
the tool with a single command:

```text
nagarectl doctor
```

After this plan, `nagarectl doctor` re-runs EP-38's probes and renders them as an *ordered checklist*
of `OK` / `WARN` / `FAIL` lines where **every non-OK line carries a plain-language explanation of what
is wrong and the exact command to run to fix it.** A probe whose data source is unreachable
(`StatusUnknown` from EP-38) renders as a `WARN` line with a "could not check; <reason>" hint rather
than a hard `FAIL`. Crucially, `doctor` exits with a **non-zero process exit code when any check
FAILs**, so it is scriptable: an operator can put `nagarectl doctor` in a pre-deploy guard or a cron
health alert and branch on its exit status.

`doctor` is read-only and advisory: it *prints* remediation commands but **never executes them**. The
operator stays in control of every mutation. It is the diagnostic counterpart to `server status`'s
inventory — same probes, re-graded into an actionable triage list.

You can see it working without deploying anything. Power the VM off and run the command:

```text
$ gcloud compute instances stop nagare-01 --zone=us-west1-a
$ nagarectl doctor
nagare doctor — 9 checks

  [FAIL]  vm-power            The VM nagare-01 is powered off.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  [WARN]  k3s-node            could not check; the VM is TERMINATED, so the k3s API is unreachable.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a, then re-run
  ...
1 failed, 3 warnings, 5 ok.
$ echo $?
1
```

The VM-power line names the problem in one sentence and gives the exact `gcloud` start command; the
checks that depend on the VM degrade to `WARN` ("could not check; …") rather than crashing; and the
process exits `1` because at least one check FAILed. Start the VM, wait for k3s, re-run, and the report
walks back to "0 failed" with exit `0`.


## Progress

- [ ] M1: pure `Remediation`/`Check` model + `remediationFor` knowledge base + `formatDoctor` renderer +
  `doctorExitOk`, all in `cli/nagarectl/src/Nagare/Ops/Doctor.hs`, with a `testGroup "Nagare.Ops.Doctor"` in
  `cli/nagarectl/test/Spec.hs` covering each failure mode.
- [ ] M2: `doctor` top-level command wired into `cli/nagarectl/app/Main.hs` — `DoctorOpts` record +
  parser, `Doctor` constructor, `command "doctor"` registered, `runDoctor` handler calling EP-38's
  `gatherInventory` and exiting non-zero on any FAIL.
- [ ] M3: `nagarectl-test` green + `nagarectl doctor --help` transcript captured below; live cluster run
  deferred (no cluster mutated during implementation).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: `doctor` prints remediation commands but **never auto-executes** any fix. The output is
  advisory text the operator runs themselves.
  Rationale: The remediation commands mutate infrastructure (start a VM, patch a ConfigMap, push images,
  run a backup). Auto-running them would make a diagnostic command an outward-facing actor, hide which
  mutation happened, and risk acting on a misdiagnosis. Keeping `doctor` read-only matches the
  least-surprise contract of `server status` and keeps `remediationFor`/`formatDoctor` pure and
  trivially testable.
  Date: 2026-06-09

- Decision: The process exit code is non-zero **iff at least one check is `FAIL`**. `WARN`/`UNKNOWN`/`OK`
  do not affect the exit code. Concretely `doctorExitOk checks = not (any isFail checks)`; `runDoctor`
  calls `exitWith (ExitFailure 1)` when `doctorExitOk` is `False`.
  Rationale: A scriptable health gate needs a crisp, stable signal. `FAIL` means "a thing that should be
  up is down" (actionable, blocking); `WARN`/`UNKNOWN` mean "degraded or could-not-check" (worth a human
  glance but not a hard stop). Tying exit `1` strictly to `FAIL` lets `nagarectl doctor && deploy`
  behave sensibly without flapping on transient unknowns.
  Date: 2026-06-09

- Decision: `doctor` **reuses EP-38's probes** (`gatherInventory` returning `[Probe]`) rather than
  re-implementing any health check. EP-39 adds only the pure mapping from a `Probe` to a `Remediation`
  and the checklist renderer.
  Rationale: One source of truth for "is X healthy". `server status` and `doctor` must never disagree
  about whether the VM is up or a deployment is rolled out. EP-38 owns probing; EP-39 owns triage
  presentation. This is Integration Point IP1 with EP-38
  (`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`).
  Date: 2026-06-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan lives entirely in the `cli/nagarectl` package and adds one pure module plus one CLI command.
You need to understand five things: how the CLI is structured, what EP-38 hands you, how the tool shells
out, what the remediation knowledge base is, and where the test suite goes. Each is grounded in a real
file below.

**The CLI structure.** `cli/nagarectl/app/Main.hs` (~1462 lines) is the entry point; it uses
`optparse-applicative`. A sum type `Command` (around line 232) enumerates everything the tool does
(`Deploy`, `App …`, `Deployments …`, the `site`/`env`/`secret` groups, etc.). `opts :: ParserInfo
Command` (around line 540) builds a top-level `subparser` (around line 549) with one `command "…"` per
top-level verb — `deploy`, `site`, `env`, `secret`, `app`, `deployments`. `main` (around line 776) is
`execParser opts >>= \case …`, matching each `Command` constructor to a `runX` handler. To add `doctor`
you will: define a `DoctorOpts` record and `doctorOptsParser :: Parser DoctorOpts`, add a
`Doctor DoctorOpts` constructor to `Command`, register `command "doctor" doctorCmd` in the top-level
subparser, add a `runDoctor :: DoctorOpts -> IO ()` handler, and add the dispatch arm. `doctor` is a
**single top-level command, not a group** (unlike `app`/`site`). The shared subparser block is
Integration Point IP3: EP-38 adds `command "server" …` and EP-40/EP-41 add `domains`/`cleanup` to the
same block — **append your `command "doctor"` in EP-38's style and do not remove sibling commands**;
expect a small merge here.

**What EP-38 gives you.** The sibling plan
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md` builds the probe layer under
`cli/nagarectl/src/Nagare/Ops/` (modules such as `Nagare.Ops.Probe`, `Nagare.Ops.Pulumi`,
`Nagare.Ops.Status`). Its conceptual shape — **read the real, committed names from EP-38's source
before you implement; do not assume names EP-38 does not define** — is:

```haskell
data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
  deriving stock (Eq, Show)

data Probe = Probe
  { probeName   :: !Text   -- e.g. "vm-power", "k3s-node", "knative-serving"
  , probeStatus :: !ProbeStatus
  , probeDetail :: !Text   -- the live detail line, e.g. "TERMINATED" or "5/5 ready"
  } deriving stock (Show)

gatherInventory :: InventoryOpts -> IO [Probe]
```

EP-39 calls `gatherInventory` once, then maps each `Probe` to a remediation hint. **The mapping key is
the probe's name** (`probeName`) — or, if EP-38 publishes a stable machine-key field distinct from the
human label, that key (coordinate per IP1; prefer a stable key over a display string so renaming a label
never silently drops a remediation). EP-39 must not depend on `probeDetail`'s exact wording for matching;
it may *quote* it in the hint.

**How it shells out.** `doctor` itself runs no subprocess for its own logic — `gatherInventory` (EP-38)
does all the probing. The only reason this section matters is that the *remediation strings* `doctor`
prints are real commands the operator will run, and they must match how the rest of the tool shells out
via the `cradle` library (`import Cradle`; `run_ $ cmd "kubectl" & addArgs [...]`). Concretely: cluster
commands use `kubectl`; GCP commands target `tan-nb-exp` / `us-west1` / `us-west1-a` only (per
`CLAUDE.md`); SSH to the host goes through `scripts/iap-ssh.sh` (per
`docs/runbooks/cluster-access.md`). So the *text* of every remediation must be a command an operator
could paste verbatim in this repo's environment.

**The remediation knowledge base.** This is the heart of the plan: a pure function `remediationFor ::
Probe -> Maybe Remediation` that, for each failure mode EP-38's probes can report, returns a
plain-language *why* plus the *exact command*. The failure modes and their grounded fixes are enumerated
in "Plan of Work / Milestone 1" below. The grounding facts: the VM is `nagare-01` in zone `us-west1-a`
and is often left `TERMINATED` to save cost (`docs/runbooks/cluster-access.md`); the control-plane
components each have a `cluster/bootstrap/<component>/README.md`
(`cluster/bootstrap/knative-serving/README.md`, `cluster/bootstrap/cert-manager/README.md`,
`cluster/bootstrap/kourier/README.md`, `cluster/bootstrap/net-certmanager/README.md`); the base domain
is sourced from `pulumi -C infra/pulumi stack output baseDomain` and is currently the placeholder
`apps.example.com` (TLS is HTTP-first/deferred while that placeholder stands); backups live under
`gs://tan-nb-exp-nagare-backups/` and are created by `scripts/backup-postgres.sh`; disaster-recovery and
power-management caveats are in `docs/runbooks/disaster-recovery.md`. A common pitfall the kubectl
remediation must call out: the workstation default `kubectl` context often points at an unrelated GKE
cluster (`tan-cluster`), not k3s — retrieve the k3s kubeconfig per `docs/runbooks/cluster-access.md`.

**The test suite.** `cli/nagarectl/test/Spec.hs` uses `tasty` + `tasty-hunit`, grouped by module
(`testGroup "Nagare.App" […]`, etc.), and tests *pure* helpers only. You will add a
`testGroup "Nagare.Ops.Doctor"` covering `remediationFor` (each failure mode maps to the expected command),
`formatDoctor` (rendering shape), and `doctorExitOk` (non-zero iff any FAIL). Run from `cli/nagarectl`:
`cabal build && cabal test`.

**The cabal file.** `cli/nagarectl/nagarectl.cabal` lists the library `exposed-modules`; you will add
`Nagare.Ops.Doctor`. The library already depends on `text`; the executable already depends on
`optparse-applicative`. No new dependency is needed.


## Plan of Work

### Milestone 1 — The pure `Nagare.Ops.Doctor` module: model, knowledge base, renderer, exit grade

**Scope:** create `cli/nagarectl/src/Nagare/Ops/Doctor.hs` with the `Remediation`/`Check` model, the
`remediationFor` knowledge base, the `formatDoctor` renderer, and the `doctorExitOk` grade — all pure —
plus a `testGroup "Nagare.Ops.Doctor"` exercising each. After this milestone the module compiles, is
exported, and is fully unit-tested, but no command uses it yet. It imports EP-38's `Probe`/`ProbeStatus`
types but no IO from EP-38.

Create `cli/nagarectl/src/Nagare/Ops/Doctor.hs` exporting:

```haskell
module Nagare.Ops.Doctor
  ( Remediation (..)
  , Check (..)
  , remediationFor   -- pure; the knowledge base
  , gradeChecks      -- pure; [Probe] -> [Check]
  , formatDoctor     -- pure; [Check] -> Text
  , doctorExitOk     -- pure; [Check] -> Bool
  ) where

import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))   -- exact module/names per EP-38, IP1
```

Define the model:

```haskell
data Remediation = Remediation
  { remWhy     :: !Text   -- plain-language explanation of what is wrong
  , remCommand :: !Text   -- the exact command (or short pointer) to run
  } deriving stock (Eq, Show)

data Check = Check
  { checkProbe :: !Probe
  , checkHint  :: !(Maybe Remediation)
  } deriving stock (Show)
```

Implement the pure functions:

- `gradeChecks :: [Probe] -> [Check]` — `map (\p -> Check p (remediationFor p)) probes`. Preserves
  EP-38's probe order so the checklist reads top-down like `server status` (VM first, then node, control
  planes, ingress, domain, TLS, disk, registry, backups).

- `remediationFor :: Probe -> Maybe Remediation` — **the knowledge base.** Returns `Nothing` for an
  `OK` probe; for non-OK probes it switches on `probeName` (the stable key per IP1) *and* the status. A
  `StatusUnknown` probe always yields a "could not check; <reason>" hint (the reason quoted/derived from
  `probeDetail`) — it renders as `WARN`, never `FAIL`. The full mapping:

  - `vm-power` `FAIL` (detail `TERMINATED`) → why `"The VM nagare-01 is powered off."`, command
    `"gcloud compute instances start nagare-01 --zone=us-west1-a"`.
  - `k3s-node` `FAIL`/`UNKNOWN` (node `NotReady` or kubectl unreachable) → why
    `"kubectl cannot reach the k3s cluster (or your context points at the wrong cluster)."`, command
    `"point kubectl at the k3s cluster — the workstation default context often points at the unrelated GKE cluster tan-cluster; retrieve the k3s kubeconfig per docs/runbooks/cluster-access.md"`.
  - `knative-serving` / `cert-manager` / `kourier` / `net-certmanager` `FAIL` (deployment not rolled
    out) → why `"The <component> control plane is not ready."`, command
    `"kubectl rollout status deploy/<name> -n <namespace>; consult cluster/bootstrap/<component>/README.md"`
    (fill `<name>`/`<namespace>` from the probe; e.g. `deploy/controller -n knative-serving`,
    `deploy/cert-manager -n cert-manager`, `deploy/3scale-kourier-control -n kourier-system`). If EP-38
    encodes the deployment/namespace in `probeDetail`, parse it; otherwise key the README path off
    `probeName`.
  - `kourier-ingress-ip` `FAIL` (EXTERNAL-IP ≠ reserved publicIp) → why
    `"Ingress is not serving on the reserved static IP."`, command
    `"kubectl get svc -n kourier-system kourier -o wide and compare against: pulumi -C infra/pulumi stack output publicIp"`.
  - `base-domain` `FAIL` (Pulumi `baseDomain` ≠ in-cluster `config-domain` ConfigMap) → why
    `"The cluster's configured base domain disagrees with infrastructure."`, command
    `"re-render config-domain from: pulumi -C infra/pulumi stack output baseDomain (see cluster/bootstrap/knative-serving/README.md)"`.
  - `clusterissuer-tls` `FAIL`/`WARN` (`ClusterIssuer letsencrypt-dns` not `READY`) → why
    `"TLS issuance is not ready."`, command
    `"kubectl get clusterissuer letsencrypt-dns -o yaml (note: TLS is HTTP-first/deferred while the base domain is the placeholder apps.example.com)"`.
  - `disk-usage` `WARN`/`FAIL` (high usage on `/var/lib/nagare` or the boot disk) → why
    `"Disk is filling up."`, command
    `"inspect: scripts/iap-ssh.sh -- df -h; then run nagarectl cleanup once available (EP-41, docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md)"`.
  - `registry-auth` `FAIL` (Artifact Registry push auth failing) → why
    `"Image push auth is not configured."`, command
    `"gcloud auth configure-docker us-west1-docker.pkg.dev; verify the nagare-node service account holds roles/artifactregistry.writer"`.
  - `backup-freshness` `WARN`/`FAIL` (stale or absent backup object) → why
    `"No recent backup object found."`, command
    `"run scripts/backup-postgres.sh; consult docs/runbooks/disaster-recovery.md"`.
  - `host-workarounds` (post-reboot metadata route / MASQUERADE / coredns lost) → render as a **known
    WARN**: why `"Post-reboot host workarounds may have been lost."`, command
    `"re-apply per the power-management notes in docs/runbooks/disaster-recovery.md"`.
  - Any other non-OK probe → a generic hint: why = the probe detail, command = `"see docs/runbooks/"`.
    This guarantees `doctor` never prints a bare red line with no guidance even if EP-38 adds a probe
    EP-39 has not catalogued yet.

  Keep this function a single `case probeName p of …` (with status guards) so it is one obvious table to
  read and to test.

- `formatDoctor :: [Check] -> Text` — the **pure renderer.** Produce a header line
  `"nagare doctor — <N> checks"`, then for each `Check`: a line `"  [<TAG>]  <name>  <detail-or-why>"`
  where `<TAG>` is `OK`/`WARN`/`FAIL` derived from `probeStatus` (`StatusUnknown` → `WARN`); and for any
  non-OK check with a hint, a following indented `"          fix: <remCommand>"` line and the `remWhy`
  text. Close with a summary line `"<f> failed, <w> warnings, <o> ok."`. Reuse a small `pad` helper for
  the name column (mirror `Nagare.Static.Release.formatReleasesTable`'s `pad`). No clock, no IO.

- `doctorExitOk :: [Check] -> Bool` — `not (any isFail checks)` where
  `isFail c = probeStatus (checkProbe c) == StatusFail`. `True` means "no FAILs → exit 0".

Add `Nagare.Ops.Doctor` to `exposed-modules` in `cli/nagarectl/nagarectl.cabal`:

```diff
   exposed-modules:
     Nagare.App
     Nagare.App.Deployments
     Nagare.Build
     Nagare.Deploy
+    Nagare.Ops.Doctor
     Nagare.Env.BuildArgs
```

Add a `testGroup "Nagare.Ops.Doctor"` in `cli/nagarectl/test/Spec.hs` (build small hand-written `Probe`
values, no cluster):

- `remediationFor` on a `vm-power`/`StatusFail` probe returns a `Remediation` whose `remCommand`
  contains `"gcloud compute instances start nagare-01 --zone=us-west1-a"`; one assertion per failure
  mode above asserting the expected command substring.
- `remediationFor` on a `StatusOk` probe returns `Nothing`.
- `remediationFor` on a `StatusUnknown` probe returns a hint whose `remWhy` starts with
  `"could not check"`.
- `formatDoctor` of a mixed `[Check]` contains `"[FAIL]"`, the `"fix:"` line, and the summary
  `"1 failed"`.
- `doctorExitOk` is `False` when any probe is `StatusFail` and `True` for an all-`OK`/`WARN` list.

**Acceptance:** `cabal test` in `cli/nagarectl` is green, including the new `Nagare.Ops.Doctor` group.

### Milestone 2 — The `doctor` command wired to `gatherInventory` with a non-zero FAIL exit

**Scope:** wire `doctor` into `cli/nagarectl/app/Main.hs` so `nagarectl doctor` runs EP-38's probes,
renders them with `formatDoctor`, and exits non-zero when any check FAILs. After this milestone the
command exists end-to-end (its probing is whatever EP-38 has landed).

In `cli/nagarectl/app/Main.hs`:

- Define the options record and parser (doctor takes no required arguments; expose the same
  inventory knobs EP-38's `server status` exposes — e.g. namespace/timeout — by reusing EP-38's
  `InventoryOpts` parser if it publishes one, else a minimal `DoctorOpts`):

  ```haskell
  data DoctorOpts = DoctorOpts
    { inventoryOpts :: InventoryOpts }   -- reuse EP-38's opts (IP1); minimal if EP-38 has none

  doctorOptsParser :: Parser DoctorOpts
  doctorOptsParser = DoctorOpts <$> inventoryOptsParser   -- or: pure (DoctorOpts ())
  ```

- Add a `Doctor DoctorOpts` constructor to the `Command` sum type (near line 232).

- Register the command in the **top-level** subparser (near line 549) — append in EP-38's style,
  IP3, do not remove sibling commands:

  ```haskell
  <> command "doctor" doctorCmd
  ```

  ```haskell
  doctorCmd = info (Doctor <$> doctorOptsParser <**> helper)
                (fullDesc <> progDesc "Health-check the platform and print remediation hints (exit 1 on any FAIL)")
  ```

- Add the handler and import the pure module plus `System.Exit`:

  ```haskell
  import Nagare.Ops.Doctor (gradeChecks, formatDoctor, doctorExitOk)
  import Nagare.Ops.Probe (gatherInventory)   -- EP-38, IP1
  import System.Exit (exitWith, ExitCode (ExitFailure))

  runDoctor :: DoctorOpts -> IO ()
  runDoctor opts = do
    probes <- gatherInventory (inventoryOpts opts)
    let checks = gradeChecks probes
    TIO.putStr (formatDoctor checks)
    if doctorExitOk checks
      then pure ()
      else exitWith (ExitFailure 1)
  ```

  Note: `gatherInventory` already degrades unreachable sources to `StatusUnknown` (EP-38), so `runDoctor`
  needs no extra error handling — `doctor` always prints the full report and only the exit code varies.
  The existing `dieT :: Text -> IO a` helper is unchanged and unused here (a clean diagnostic run is not
  an error even when checks FAIL; the FAIL signal is the exit code, not a `nagarectl:` stderr message).

- Add the `main` dispatch arm: `Doctor o -> runDoctor o`.

**Acceptance:** `nagarectl doctor --help` shows the command; against a platform with the VM off,
`nagarectl doctor` prints a checklist whose VM line is `[FAIL]` with the `gcloud … start` fix and exits
`1`; with everything healthy it prints all `[OK]` and exits `0`.

### Milestone 3 — Tests green, `--help` transcript, live run deferred

**Scope:** run the suite, capture the `--help` transcript, and record the live-run deferral.

Run `cabal build && cabal test` in `cli/nagarectl`. Capture `nagarectl doctor --help` and paste it into
Concrete Steps. Then, against a reachable cluster (VM off, then VM on), run `nagarectl doctor` twice and
paste the transcript as evidence. If no cluster is reachable, record that `remediationFor`/`formatDoctor`/
`doctorExitOk` are validated by the `Nagare.Ops.Doctor` unit tests and `--help`/argument inspection, and that
the live run is deferred (mirroring how
`docs/plans/30-nagarectl-app-lifecycle-commands.md` deferred its live lifecycle run).

**Acceptance:** `nagarectl-test` green; `--help` transcript present; deferral noted.


## Concrete Steps

Build and test from the package directory (prefix with `nix develop -c` if `cabal` is not on PATH):

```bash
cd cli/nagarectl && cabal build && cabal test
```

Inspect the new command surface:

```bash
cd cli/nagarectl && cabal run -v0 nagarectl -- doctor --help
```

Expected `--help` shape:

```text
Usage: nagarectl doctor [INVENTORY OPTIONS]
  Health-check the platform and print remediation hints (exit 1 on any FAIL)
```

End-to-end, with `gcloud`/`kubectl`/`pulumi`/`gsutil` on PATH and `kubectl` pointed at the k3s cluster
(see `docs/runbooks/cluster-access.md`). Deploy nothing — just observe `doctor` against a platform with
the VM off, then on:

```bash
gcloud compute instances stop nagare-01 --zone=us-west1-a    # VM off
nagarectl doctor ; echo "exit=$?"
gcloud compute instances start nagare-01 --zone=us-west1-a   # VM on; wait ~1-2 min for k3s
nagarectl doctor ; echo "exit=$?"
```

Expected output shape with the VM off (non-OK lines carry a why + a `fix:` command; dependent checks
degrade to `WARN`):

```text
nagare doctor — 9 checks

  [FAIL]  vm-power            The VM nagare-01 is powered off.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  [WARN]  k3s-node            could not check; the VM is TERMINATED, so the k3s API is unreachable.
          fix: point kubectl at the k3s cluster — the workstation default context often points at the unrelated GKE cluster tan-cluster; retrieve the k3s kubeconfig per docs/runbooks/cluster-access.md
  [WARN]  knative-serving     could not check; the k3s API is unreachable.
  ...
1 failed, 5 warnings, 3 ok.
exit=1
```

Expected output shape with the VM on and everything healthy:

```text
nagare doctor — 9 checks

  [OK]    vm-power            RUNNING
  [OK]    k3s-node            Ready
  [OK]    knative-serving     5/5 ready
  ...
0 failed, 0 warnings, 9 ok.
exit=0
```

The live two-run transcript will be pasted here once captured against a reachable cluster (see Progress
M3); if no cluster is reachable during implementation, the pure helpers are exercised by the
`Nagare.Ops.Doctor` test group and the live run is deferred.


## Validation and Acceptance

1. `cabal test` in `cli/nagarectl` passes, including the new `Nagare.Ops.Doctor` group: `remediationFor`
   maps each failure mode to its expected command (e.g. `vm-power`/`FAIL` →
   `gcloud compute instances start nagare-01 --zone=us-west1-a`), returns `Nothing` for `OK`, and a
   `"could not check…"` hint for `StatusUnknown`.
2. `formatDoctor` of a mixed `[Check]` renders an ordered checklist whose non-OK lines each carry a
   plain-language why and a `fix:` command, and ends with a `"<f> failed, <w> warnings, <o> ok."`
   summary; `doctorExitOk` returns `False` iff any check is `FAIL`. (Unit-tested.)
3. `nagarectl doctor --help` lists the `doctor` command with its progDesc and inventory options.
4. With the VM off, `nagarectl doctor` prints `[FAIL] vm-power` with the `gcloud … start` fix, degrades
   the VM-dependent checks to `[WARN]` ("could not check…"), and exits `1` (`echo $?` → `1`).
5. With the VM on and the platform healthy, `nagarectl doctor` prints all `[OK]` lines and exits `0`.
6. `doctor` mutates nothing: running it twice in a row produces the same report (modulo live state) and
   changes no infrastructure — it only *prints* commands.

If no cluster is reachable, items 4–6 are validated by unit tests on the pure grading + remediation
helpers (`remediationFor`, `formatDoctor`, `doctorExitOk`); the live run is deferred.


## Idempotence and Recovery

`nagarectl doctor` is **read-only**: it runs EP-38's probes (themselves read-only `describe`/`get`/`ls`
queries) and prints a report. It **never mutates** any infrastructure — every remediation is printed
text the operator chooses to run, never executed by `doctor`. Running it any number of times is safe and
produces the same report modulo live platform state. It writes no local files. The only observable
"effect" is the process exit code (`0`/`1`), which is information, not a mutation.

Implementation steps are likewise safe to repeat: re-running `cabal build`/`cabal test` is idempotent,
and editing `Nagare.Ops.Doctor.hs`, the cabal `exposed-modules`, and the Main.hs subparser are ordinary
source edits. Recover from a bad edit with `git checkout`.


## Interfaces and Dependencies

Existing libraries (already in `cli/nagarectl/nagarectl.cabal`): `text` (the `Text` report and pure
helpers), `optparse-applicative` (the `doctor` parser), and `base`'s `System.Exit` (the non-zero exit).
No new dependency.

**Dependency on EP-38 (IP1).** This plan **hard-depends** on
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`, which publishes the probe
types and the `gatherInventory` action under `cli/nagarectl/src/Nagare/Ops/` (e.g.
`Nagare.Ops.Probe`). EP-39 imports `Probe`/`ProbeStatus` and calls `gatherInventory`; it defines and
alters **no** probes (that is EP-38's scope). Read EP-38's committed source for the exact module name,
constructor names, and whether it exposes a stable machine key per probe — match those exactly; do not
assume names EP-38 does not define.

Signatures that must exist at the end of this plan (module `Nagare.Ops.Doctor` in
`cli/nagarectl/src/Nagare/Ops/Doctor.hs`):

```haskell
data Remediation = Remediation { remWhy :: !Text, remCommand :: !Text }
  deriving stock (Eq, Show)
data Check = Check { checkProbe :: !Probe, checkHint :: !(Maybe Remediation) }
  deriving stock (Show)

remediationFor :: Probe -> Maybe Remediation   -- pure; the knowledge base
gradeChecks    :: [Probe] -> [Check]           -- pure
formatDoctor   :: [Check] -> Text              -- pure renderer
doctorExitOk   :: [Check] -> Bool              -- pure; True iff no FAIL
```

`remediationFor` and `formatDoctor` are **pure** so they are unit-testable without a cluster; that is the
crux of how Milestone 1's tests validate the whole knowledge base offline. In `cli/nagarectl/app/Main.hs`
the command wiring adds `DoctorOpts`, `doctorOptsParser :: Parser DoctorOpts`, a `Doctor DoctorOpts`
constructor on `Command`, `command "doctor" doctorCmd` in the top-level subparser, and
`runDoctor :: DoctorOpts -> IO ()`.

**Integration.** IP1 — EP-39 consumes EP-38's `Probe`/`ProbeStatus`/`gatherInventory` from
`cli/nagarectl/src/Nagare/Ops/` (`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`);
the mapping key is `probeName` (or EP-38's stable machine key, coordinated there). IP3 — the `doctor`
top-level command is appended to the same shared subparser block in `cli/nagarectl/app/Main.hs` that
EP-38 (`server`) and EP-40/EP-41 (`domains`/`cleanup`) also edit; append in EP-38's style and keep all
sibling commands. Forward references that remain advisory text only (no code dependency): the
`disk-usage` hint points at `nagarectl cleanup`
(`docs/plans/41-nagarectl-cleanup-for-images-previews-and-releases.md`, EP-41) once it exists, and base
domain work is owned by `docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md`
(EP-40) — EP-39 only *prints* pointers to those, it does not depend on them at build time.
