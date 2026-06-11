---
id: 68
slug: doctor-diagnostics-correctness
title: "Doctor Diagnostics Correctness"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# Doctor Diagnostics Correctness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`nagarectl doctor` is the one command an operator runs to ask "is the platform healthy, and
if not, exactly what do I paste to fix it?" It inspects the live cluster through ordinary
command-line tools (`gcloud`, `kubectl`, `pulumi`, `gsutil`), grades roughly nineteen facets
of the system as OK / WARN / FAIL, prints a checklist with a one-line remediation under every
non-OK line, and exits non-zero if and only if at least one facet is a hard FAIL. The whole
value of the command rests on a single property: **it must tell the truth.** A check that
FAILs on a healthy cluster trains operators to ignore red lines, and a missing check hides a
real failure mode behind a green summary.

On 2026-06-10 the `nagare-01` cluster was inspected live for the first time in weeks. Every
application served HTTP 200 through the gateway, every control-plane Deployment was rolled
out, TLS issuance was healthy — and `nagarectl doctor` nonetheless printed exactly one red
line:

```text
  [FAIL]  Kourier ingress          Ingress is not serving on the reserved static IP.
          fix: kubectl get svc -n kourier-system kourier -o wide and compare against: pulumi -C infra/pulumi stack output publicIp
```

This is a **false FAIL**. The check asserts literal equality between the Kourier
LoadBalancer Service's `EXTERNAL-IP` and the Pulumi `publicIp` stack output. On a k3s cluster
using the built-in ServiceLB ("klipper") load balancer, a `LoadBalancer` Service is assigned
the **node's own IP** as its `EXTERNAL-IP` — here the node's *internal* address such as
`10.10.0.4` — while the reserved *public* static IP (such as `34.145.74.203`) fronts that node
through a Google Cloud forwarding rule. The two addresses are different by design, so literal
equality can never hold even though ingress is serving perfectly. (Background: "ServiceLB" is
k3s's bundled load-balancer controller; instead of provisioning a cloud load balancer it
binds the Service's ports on each node and advertises the node IP as the external IP. The real
public IP lives one layer up, in GCP, and routes packets to that node.)

After this change, three things are true that were not before:

1. **The Kourier-ingress check passes on the healthy cluster.** It stops demanding
   `EXTERNAL-IP == publicIp` and instead verifies what an operator actually cares about: that
   the node-IP LoadBalancer is genuinely fronted by the reserved public IP (and, as a final
   tie-breaker, that the gateway answers). Running `nagarectl doctor` on the live
   `nagare-01` cluster reports `[OK] Kourier ingress`, and the summary line shows `0 failed`.

2. **`doctor` reports whether the cluster can pull the project's private images.** A new
   check inspects the Knative `config-deployment` ConfigMap for the registry host under
   `registriesSkippingTagResolving` — the cluster capability that EP-2 (the plan at
   `docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`) makes
   declarative. If a build-mode deploy would fail because the cluster is not configured to
   resolve and pull from the project Artifact Registry, the operator sees it as a WARN with a
   pointer to EP-2's mechanism, instead of discovering it only when a Knative Revision sticks
   in `ImagePullBackOff`.

3. **`doctor` warns when the build platform and the node architecture disagree.** A new
   check compares the target platform configured in the target profile (the
   `NAGARE_TARGET_PLATFORM` field that EP-3, the plan at
   `docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md`, adds to
   `Nagare.Target`) against the k3s node's reported architecture (`amd64`). When a developer
   on an `arm64` workstation would otherwise build an image the `amd64` node cannot run, the
   operator sees a WARN with a hint to set the platform, instead of an `exec format error`
   crash loop after deploy.

The acceptance you can observe at the end: on the healthy 2026-06-10-style cluster,
`nagarectl doctor` prints `[OK] Kourier ingress`, prints the two new checks with correct
OK/WARN/FAIL grades, and the unit test suite (`cd cli/nagarectl && cabal test nagarectl-test`)
is green, including new tests that pin the corrected Kourier predicate and the two new probe
parsers.


## Scope, Non-Scope, and the Single-Writer Contract

This plan is **EP-4** of MasterPlan 13. Per that master plan's Integration Point #3, EP-4 is
the **single writer** of the `doctor` check set: only this plan edits
`cli/nagarectl/src/Nagare/Ops/Doctor.hs` and `cli/nagarectl/src/Nagare/Ops/Probe.hs` (and the
probe-gathering glue in `cli/nagarectl/src/Nagare/Ops/Status.hs`). EP-2 and EP-3 do **not**
touch those files; they provide the underlying *capability* (EP-2: the cluster's declarative
private-image-pull configuration) and the underlying *field* (EP-3: the `NAGARE_TARGET_PLATFORM`
target-profile field), and EP-4 implements the probes that read them. This keeps one owner on
the check table so two plans cannot make conflicting edits to it.

The dependency on EP-2 and EP-3 is **soft**, not hard, and this matters for ordering:

- **The Kourier fix (Milestone M1) is fully independent.** It depends on nothing from EP-2 or
  EP-3 and can land first. It is the highest-value change because it removes a standing false
  FAIL.

- **The private-image-pull check (Milestone M2)** describes a capability EP-2 establishes. At
  the time of writing, EP-2's plan (`docs/plans/66-...`) is still a skeleton, so its exact
  ConfigMap key layout is not yet finalized in that file. EP-4 therefore authors M2 against the
  **stated contract** in the master plan: the Knative `config-deployment` ConfigMap gains a
  `registriesSkippingTagResolving` entry listing the project Artifact Registry host. The
  implementer of M2 must re-read `docs/plans/66-...` when EP-2 has fleshed it out and reconcile
  the exact key/value shape and any naming, recording any divergence in this plan's Decision
  Log. If EP-2 has not landed when M2 is implemented, the check still compiles and runs: it
  simply reports WARN ("not configured") on a cluster that lacks the capability, which is the
  correct grade.

- **The architecture-mismatch check (Milestone M3)** reads the `NAGARE_TARGET_PLATFORM` field
  EP-3 adds to `Nagare.Target.TargetProfile`. At the time of writing, EP-3's plan
  (`docs/plans/67-...`) is also a skeleton and `Nagare.Target` does **not** yet have that
  field. The implementer of M3 must re-read `docs/plans/67-...` to confirm the final field name
  (the master plan's Integration Point #2 proposes the environment variable `NAGARE_TARGET_PLATFORM`
  and a profile accessor; the likely Haskell accessor is `tpTargetPlatform :: TargetProfile -> Text`
  defaulting to `"linux/amd64"`). M3 must not add that field itself — that is EP-3's job. If
  EP-3 has not landed, M3 is blocked only on the one-line accessor; the plan below specifies a
  fallback so M3 can be authored and even partially landed (the pure parser and grader) ahead of
  EP-3, with the wiring completed once the field exists. Record the confirmed field name in the
  Decision Log.

**Out of scope.** This plan does not change the ServiceLB/forwarding-rule infrastructure, does
not add new Pulumi outputs unless M1 needs the node's external IP (see M1 design below), and
does not alter the exit-code contract (`doctor` still exits 1 on any FAIL, 0 otherwise — WARN
and UNKNOWN never affect the exit code).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Choose and document the corrected Kourier predicate (reachability-first; see Plan of Work).
- [ ] M1: Add the pure helper(s) in `Nagare.Ops.Probe` that the new predicate needs (e.g. `gradeKourier` / a node-external-IP parser), exported for unit test.
- [ ] M1: Rewrite `probeKourierIp` in `Nagare.Ops.Status` to gather the extra evidence and call the new grader.
- [ ] M1: Update the remediation `why`/`command` for `"Kourier ingress"` in `Nagare.Ops.Doctor` so the hint matches the new predicate.
- [ ] M1: Replace/extend the Kourier unit tests in `test/Spec.hs` so a node-internal-IP LB fronted by the static IP grades OK; keep a genuine-mismatch FAIL case.
- [ ] M1: `cabal test nagarectl-test` green; `nagarectl doctor` on the live cluster shows `[OK] Kourier ingress`.
- [ ] M2: Re-read `docs/plans/66-...`; confirm the `config-deployment` key shape; record in Decision Log.
- [ ] M2: Add pure parser `parsePrivateImagePull` (config-deployment ConfigMap → registry hosts) in `Nagare.Ops.Probe`, exported.
- [ ] M2: Add `probePrivateImagePull tp` in `Nagare.Ops.Status`; wire it into `gatherInventory` in report order.
- [ ] M2: Catalogue the `"private image pull"` remediation in `Nagare.Ops.Doctor`.
- [ ] M2: Unit tests for the parser and the remediation hint; suite green.
- [ ] M3: Re-read `docs/plans/67-...`; confirm the `NAGARE_TARGET_PLATFORM` field name and accessor; record in Decision Log.
- [ ] M3: Add pure parser `parseNodeArch` (node JSON → architecture) and pure grader `gradeArch` (platform vs node arch) in `Nagare.Ops.Probe`, exported.
- [ ] M3: Add `probeArch tp` in `Nagare.Ops.Status`; wire it into `gatherInventory`.
- [ ] M3: Catalogue the `"build platform"` remediation in `Nagare.Ops.Doctor`.
- [ ] M3: Unit tests for `parseNodeArch` and `gradeArch`; suite green.
- [ ] Final: `nagarectl doctor` end-to-end on the live cluster shows Kourier OK and the two new checks with correct grades; full suite green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (2026-06-10, recorded from the live audit) The Kourier false-FAIL is caused by k3s
  ServiceLB assigning the **node IP** (e.g. `10.10.0.4`) as the Service `EXTERNAL-IP`, while
  the reserved public IP (e.g. `34.145.74.203`) fronts the node via a GCP forwarding rule.
  Evidence: apps return HTTP 200 through the gateway (ingress serves) yet
  `kubectl get svc -n kourier-system kourier -o wide` shows `EXTERNAL-IP 10.10.0.4`, which never
  equals `pulumi -C infra/pulumi stack output publicIp` (`34.145.74.203`). The existing check at
  `Nagare.Ops.Status.probeKourierIp` requires literal `EXTERNAL-IP == publicIp`, so it FAILs.

(Add further discoveries here as M1–M3 are implemented.)


## Decision Log

Record every decision made while working on the plan.

- Decision (2026-06-11): The corrected Kourier predicate is **reachability-first with a
  fronting cross-check fallback**, not literal IP equality. See the Plan of Work for the full
  predicate and the rationale for choosing it over a pure equality/forwarding-rule comparison.
  Rationale: it directly verifies the property an operator cares about (the gateway answers on
  the reserved public IP) and degrades gracefully when any single piece of evidence is
  unavailable, instead of FAILing on a healthy cluster.
  Date: 2026-06-11

- Decision (2026-06-11): EP-4 is authored against the **stated contracts** of EP-2 and EP-3
  because their plan files are still skeletons. M2 reads the Knative `config-deployment`
  `registriesSkippingTagResolving` entry per the master plan's Integration Point #4; M3 reads the
  `NAGARE_TARGET_PLATFORM` profile field per Integration Point #2. The M2/M3 implementer must
  re-read `docs/plans/66-...`/`docs/plans/67-...` and reconcile exact key/field names, recording
  any divergence here.
  Rationale: soft dependency — EP-4 must not be hard-blocked, and the checks have a meaningful
  "not yet configured" grade even before EP-2/EP-3 land.
  Date: 2026-06-11


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about the repository. Read it fully before editing.

### Where the doctor lives

`nagarectl` is a Haskell command-line tool under `cli/nagarectl/`. The "doctor" feature is
spread across three modules plus the command wiring:

- `cli/nagarectl/src/Nagare/Ops/Probe.hs` — the **typed probe model and the pure parsers**.
  The model is two small data types:

  ```haskell
  data ProbeStatus = StatusOk | StatusWarn | StatusUnknown | StatusFail
    deriving stock (Eq, Show)

  data Probe = Probe
    { probeName   :: !Text   -- left-column label, e.g. "Kourier ingress"
    , probeStatus :: !ProbeStatus
    , probeDetail :: !Text   -- right-column human description, e.g. "EXTERNAL-IP 34.x = publicIp"
    }
    deriving stock (Eq, Show)
  ```

  This module also holds the IO-free helpers: `captureTool :: String -> [String] -> IO (Maybe ByteString)`
  (run an external tool, returning `Nothing` if the binary is missing or it exits non-zero),
  `runMaybe :: Text -> Text -> Maybe a -> (a -> Probe) -> IO Probe` (lift "no data" into a
  `StatusUnknown` probe, otherwise grade with the continuation), and a family of **pure parsers**
  that turn JSON or text from those tools into typed values — `parseNodeReady`,
  `parseDeploymentReady`, `parseKourierIp`, `parseConfigDomain`, `parseClusterIssuerReady`,
  `parseNewestBackupAge`, `parseDfUsage`. The parsers are deliberately separated from IO so they
  are unit-tested without a live cluster. There are small shared JSON walkers in this file —
  `lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value` (walk a chain of object keys),
  `textAt :: [Text] -> Aeson.Value -> Maybe Text` (the string at a path), and `conditionTrue`
  (whether a `.status.conditions[]` entry of a given type has `status == "True"`). Reuse these
  walkers in any new parser rather than re-deriving JSON traversal.

  The one parser this plan changes the *use* of is:

  ```haskell
  -- | The Kourier LoadBalancer Service's EXTERNAL-IP, from
  -- .status.loadBalancer.ingress[0].ip. Nothing before the IP is assigned.
  parseKourierIp :: ByteString -> Maybe Text
  parseKourierIp bs = do
    v <- decodeStrict bs
    Aeson.Array ingress <- lookupPath ["status", "loadBalancer", "ingress"] v
    first <- ingress V.!? 0
    textAt ["ip"] first
  ```

  Keep `parseKourierIp` (it still extracts the LoadBalancer EXTERNAL-IP); M1 adds new pure
  helpers alongside it rather than mutating it, so the existing test for it stays valid.

- `cli/nagarectl/src/Nagare/Ops/Status.hs` — the **IO probes** that call the parsers and
  assemble the inventory. `gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]`
  runs every probe in report order and returns the list. It reads three Pulumi stack outputs
  once up front:

  ```haskell
  gatherInventory tp o = do
    publicIp   <- stackOutput (ioPulumiDir o) "publicIp"
    baseDomain <- stackOutput (ioPulumiDir o) "baseDomain"
    bucket     <- maybe (tpBackupBucket tp) id <$> stackOutput (ioPulumiDir o) "backupBucket"
    core <- sequence [ probeVm o, probeNode, …, probeKourierIp publicIp, … ]
    disk <- probeDisk o
    pure (core <> disk)
  ```

  The Kourier probe today is:

  ```haskell
  -- | The Kourier EXTERNAL-IP must equal the Pulumi publicIp.
  probeKourierIp :: Maybe Text -> IO Probe
  probeKourierIp publicIp = do
    m <- captureTool "kubectl" ["get", "svc", "kourier", "-n", "kourier-system", "-o", "json"]
    runMaybe "Kourier ingress" "no kubeconfig / not reachable" (m >>= parseKourierIp) $ \ip ->
      case publicIp of
        Just want
          | want == ip -> Probe "Kourier ingress" StatusOk   ("EXTERNAL-IP " <> ip <> " = publicIp")
          | otherwise  -> Probe "Kourier ingress" StatusFail  ("EXTERNAL-IP " <> ip <> " != publicIp " <> want)
        Nothing        -> Probe "Kourier ingress" StatusWarn  ("EXTERNAL-IP " <> ip <> " (publicIp unknown)")
  ```

  This `want == ip` equality is the bug. M1 rewrites this function.

- `cli/nagarectl/src/Nagare/Ops/Doctor.hs` — the **remediation knowledge base and renderer**.
  It is entirely pure. `gradeChecks :: TargetProfile -> [Probe] -> [Check]` pairs each probe with
  a remediation hint; `remediationFor` keys off `probeName` and `probeStatus`; `formatDoctor`
  renders the checklist; `doctorExitOk :: [Check] -> Bool` returns `False` iff any check is a
  hard `StatusFail`. The knowledge base matches on the probe's display name. The two functions to
  edit/extend are `why` (the plain-language reason) and `command` (the fix to paste). The current
  Kourier entries are:

  ```haskell
  why tp name detail
    | …
    | name == "Kourier ingress" = "Ingress is not serving on the reserved static IP."
    | …

  command tp name
    | …
    | name == "Kourier ingress" =
        "kubectl get svc -n kourier-system kourier -o wide and compare against: "
          <> "pulumi -C infra/pulumi stack output publicIp"
    | …
  ```

  Note: `remediationFor` returns `Nothing` for an OK probe, a `"could not check; …"` hint for
  `StatusUnknown`, and the catalogued `why`/`command` for any other non-OK probe. So once M1
  makes the Kourier probe grade OK on a healthy cluster, the `why`/`command` Kourier entries are
  only reached on a genuine WARN/FAIL — but they must still be *accurate* for those cases, so M1
  updates them too.

- `cli/nagarectl/src/Nagare/Ops/Pulumi.hs` — `stackOutput :: FilePath -> Text -> IO (Maybe Text)`
  wraps `pulumi -C <dir> stack output <name>` and returns `Nothing` if Pulumi is missing or the
  call fails (so a dependent probe degrades to `StatusUnknown`). The stack outputs available are
  defined in `infra/pulumi/index.ts`; the relevant ones are `publicIp`, `baseDomain`,
  `backupBucket`, and `artifactRegistry`. There is **no** existing output for the node's external
  IP — M1's design avoids needing one (see below).

- `cli/nagarectl/app/Main.hs` — the command wiring. `runDoctor` (around line 1500) calls
  `resolveTargetProfile`, builds `InventoryOpts`, runs `gatherInventory`, grades with
  `gradeChecks`, prints `formatDoctor`, and exits 1 unless `doctorExitOk`. **You do not need to
  change `Main.hs`** for M1; for M2/M3 you only change it if a new probe needs a value not
  already threaded through `gatherInventory` (the design below avoids that — the new probes read
  `TargetProfile`, which `gatherInventory` already receives).

### The target profile

`cli/nagarectl/src/Nagare/Target.hs` defines `TargetProfile`, the fully-resolved GCP target
record (project, region, zone, registry host/id, bucket names, base domain, instance name),
resolved once from the environment by `resolveTargetProfile :: IO TargetProfile` with the EP-60
fallback defaults (which reproduce `tan-nb-exp` / `us-west1` / `us-west1-a` when nothing is set).
`registryPrefix :: TargetProfile -> Text` builds `"<host>/<project>/<repo-id>"`. EP-3 adds a
`NAGARE_TARGET_PLATFORM` field to this record (default `linux/amd64`); M3 reads it.

### The tests

`cli/nagarectl/test/Spec.hs` holds the unit suite, run with `cd cli/nagarectl && cabal test
nagarectl-test`. Two test groups matter here:

- `testGroup "Nagare.Ops" opsTests` (~line 548) tests the **pure parsers and the inventory
  renderer**. It already has Kourier fixtures and tests:

  ```haskell
  , testCase "parseKourierIp: ingress present" $
      parseKourierIp kourierJson @?= Just "34.83.0.1"
  , testCase "parseKourierIp: no ingress yet" $
      parseKourierIp kourierPendingJson @?= Nothing
  ```

  with `kourierJson = "{\"status\":{\"loadBalancer\":{\"ingress\":[{\"ip\":\"34.83.0.1\"}]}}}"`
  and `kourierPendingJson = "{\"status\":{\"loadBalancer\":{}}}"`. M1 adds new fixtures (a
  node-internal LB IP, node JSON carrying both internal and external addresses) and tests for the
  new pure grader, without removing the two `parseKourierIp` tests.

- `testGroup "Nagare.Ops.Doctor" doctorTests` (~line 766) tests the **pure remediation knowledge
  base**. It uses a fixed `tnbProfile :: TargetProfile` fixture (line ~332, the `tan-nb-exp`
  values) and helpers `cmdOf p = maybe "" remCommand (remediationFor tnbProfile p)` and
  `whyOf p = maybe "" remWhy (remediationFor tnbProfile p)`. The current Kourier test is:

  ```haskell
  , testCase "remediationFor: Kourier ingress FAIL -> compare publicIp" $
      cmdOf (Probe "Kourier ingress" StatusFail "EXTERNAL-IP 1.2.3.4 != publicIp 5.6.7.8")
        `containsT` "stack output publicIp"
  ```

  M1 updates this test to assert against the *new* remediation text (see M1 below). M2 and M3 add
  analogous `remediationFor`/parser tests for the two new checks.

When M3 needs the `NAGARE_TARGET_PLATFORM` field in the test fixture, extend the `tnbProfile`
record literal at line ~332 to set the new field (e.g. `tpTargetPlatform = "linux/amd64"`); the
field's existence comes from EP-3.


## Plan of Work

The work is three independent milestones. M1 (Kourier fix) is self-contained and lands first.
M2 and M3 each add one new probe end-to-end (pure parser in `Probe.hs`, IO probe in `Status.hs`
wired into `gatherInventory`, remediation entry in `Doctor.hs`, tests in `Spec.hs`) and each is
authored against a sibling plan's stated contract. The shape every new check follows is the same
as the existing nineteen: a `Probe { probeName, probeStatus, probeDetail }` produced by an IO
probe that calls `captureTool` and a pure grader, plus a catalogued `why`/`command` in
`Doctor.hs`. Because `remediationFor` falls back to a generic hint for any uncatalogued name, a
new check is never broken — but it must be catalogued to give a useful fix line.


### Milestone M1 — Fix the Kourier-ingress check (independent; land first)

**Scope.** Replace the literal `EXTERNAL-IP == publicIp` predicate in `probeKourierIp` with one
that is true on a healthy k3s ServiceLB cluster fronted by the reserved static IP, and update the
remediation text to match. At the end, `nagarectl doctor` on the live `nagare-01` cluster reports
`[OK] Kourier ingress` and `0 failed`, and the unit suite has a test that grades a
node-internal-IP LB (fronted by the static IP) as OK and a genuinely broken ingress as FAIL.

**The corrected predicate (chosen design).** Three designs were considered:

1. *Literal equality* (the current, broken behavior): require `EXTERNAL-IP == publicIp`. Wrong on
   ServiceLB — rejected.

2. *Fronting cross-check*: accept when the Kourier `EXTERNAL-IP` equals the **node's internal IP**
   AND the **node's external/access IP** equals the Pulumi `publicIp`. This is faithful to the
   topology (the static public IP fronts the node whose internal IP is the LB external IP), and
   the node's external IP is obtainable from `gcloud compute instances describe <instance>
   --format='value(networkInterfaces[0].accessConfigs[0].natIP)'` or from the node object's
   `.status.addresses[]` (`ExternalIP`). But it has two soft spots: the node's external IP and the
   reserved `publicIp` are only equal when the static IP is actually attached as the node's access
   config (true here, but it couples the check to one networking arrangement), and on a k3s node
   with no `ExternalIP` advertised in `.status.addresses` the kubectl route yields nothing.

3. *Reachability-first with a fronting fallback* (**chosen**): the property an operator truly
   cares about is "does the gateway answer on the reserved public IP?" So the check, in order:

   a. Reads the Kourier LoadBalancer `EXTERNAL-IP` (existing `parseKourierIp`). If absent (no
      ingress assigned yet), grade **FAIL** "no EXTERNAL-IP assigned to the Kourier
      LoadBalancer" — this is the genuinely-broken case the check must still catch.

   b. Reads the Pulumi `publicIp` (already threaded into `probeKourierIp`).

   c. **Primary signal — reachability.** Probe the gateway at the reserved public IP and confirm
      it answers HTTP. Concretely, run a `curl` against `http://<publicIp>/` with the Knative
      health convention: Kourier returns HTTP `404` for an unknown Host (no route matched) and a
      2xx/3xx for a known one — *any* HTTP status line proves the gateway is listening and the
      public IP routes to it. Grade **OK** "serving on <publicIp> (HTTP <code>; LB EXTERNAL-IP
      <ip>)" when curl gets any HTTP response. Use `captureTool "curl" ["-sS", "-o", "/dev/null",
      "-m", "5", "-w", "%{http_code}", "http://<publicIp>/"]`; a numeric body (even `404`) means
      reachable, an empty/`000` body or missing curl means not-reachable (fall through to the
      next signal rather than failing outright — curl may be absent on the operator box).

   d. **Fallback signal — fronting cross-check (no curl, or curl gave no answer).** When
      reachability could not be established (curl missing, or returned `000`), fall back to the
      topology check: treat the LB `EXTERNAL-IP` as the node's internal IP and confirm the node's
      external/access IP equals the Pulumi `publicIp`. Obtain the node's external IP from the same
      `kubectl get nodes -o json` already used by `probeNode` (parse `.items[0].status.addresses[]`
      for the `ExternalIP` entry). If that external IP equals `publicIp`, grade **OK** "LB
      EXTERNAL-IP <ip> fronted by <publicIp> (node ExternalIP)". If the node advertises an
      external IP that differs from `publicIp`, grade **FAIL** "node ExternalIP <x> != publicIp
      <want>". If neither curl nor a node ExternalIP is available, grade **WARN** "LB EXTERNAL-IP
      <ip>; could not confirm it is fronted by publicIp <want> (curl unavailable, node ExternalIP
      not advertised)" — a WARN, never a FAIL, because on a healthy ServiceLB cluster the absence
      of an advertised node ExternalIP is normal and we must not regress to a false FAIL.

   e. If `publicIp` itself is unknown (Pulumi unreachable), and curl could not be used, grade
      **WARN** "LB EXTERNAL-IP <ip> (publicIp unknown)" exactly as today's `Nothing` branch does.

   **Why design 3 over design 2.** Reachability is the ground truth — it confirms the user-visible
   behavior (apps answer through the gateway on the public IP) rather than inferring it from a
   specific GCP networking arrangement. The fronting cross-check is retained only as a fallback
   for environments without `curl`, and it is graded WARN (not FAIL) when inconclusive, so a
   healthy ServiceLB cluster can never false-FAIL again. This satisfies the master plan's
   requirement that the check "no longer false-FAILs the Kourier ingress check on a k3s node-IP
   LoadBalancer that the reserved static IP fronts."

**Edits.**

1. In `cli/nagarectl/src/Nagare/Ops/Probe.hs`, add two pure helpers, exported from the module's
   pure-parsers section so the test suite can call them:

   - `parseNodeExternalIp :: ByteString -> Maybe Text` — from `kubectl get nodes -o json`, return
     the first node's `.status.addresses[]` entry whose `type == "ExternalIP"` (`Nothing` when no
     ExternalIP is advertised — the normal ServiceLB case). Reuse `lookupPath`/`textAt` and the
     `find` import already present.

   - `gradeKourier :: KourierEvidence -> Probe` — the pure grader encoding steps (a)–(e) above,
     where `KourierEvidence` is a small record gathering the evidence the IO probe collected:

     ```haskell
     data KourierEvidence = KourierEvidence
       { keLbExternalIp   :: !(Maybe Text)  -- parseKourierIp result
       , kePublicIp       :: !(Maybe Text)  -- Pulumi publicIp
       , keHttpCode       :: !(Maybe Text)  -- curl %{http_code}, Nothing if curl absent/000
       , keNodeExternalIp :: !(Maybe Text)  -- parseNodeExternalIp result
       }
       deriving stock (Eq, Show)

     gradeKourier :: KourierEvidence -> Probe
     ```

     Making the grader pure and total over `KourierEvidence` is what lets M1's test pin every
     branch (reachable, fronted, mismatch, inconclusive, no-EXTERNAL-IP) without a cluster. Export
     `KourierEvidence(..)` and `gradeKourier`.

2. In `cli/nagarectl/src/Nagare/Ops/Status.hs`, rewrite `probeKourierIp` to gather the evidence and
   delegate to `gradeKourier`:

   ```haskell
   probeKourierIp :: Maybe Text -> IO Probe
   probeKourierIp publicIp = do
     svcJson  <- captureTool "kubectl" ["get", "svc", "kourier", "-n", "kourier-system", "-o", "json"]
     nodeJson <- captureTool "kubectl" ["get", "nodes", "-o", "json"]
     let lbIp       = svcJson  >>= parseKourierIp
         nodeExtIp  = nodeJson >>= parseNodeExternalIp
     httpCode <- case publicIp of
       Just ip -> curlHttpCode ip       -- captureTool "curl" [...]; Nothing on absent/000
       Nothing -> pure Nothing
     pure $ gradeKourier KourierEvidence
       { keLbExternalIp = lbIp, kePublicIp = publicIp
       , keHttpCode = httpCode, keNodeExternalIp = nodeExtIp }
   ```

   Add a small private `curlHttpCode :: Text -> IO (Maybe Text)` helper in `Status.hs` that runs
   `captureTool "curl" ["-sS","-o","/dev/null","-m","5","-w","%{http_code}","http://" <> ip <> "/"]`
   and returns `Nothing` when curl is missing or the code is `"000"`/empty, else `Just code`.
   `probeKourierIp` keeps its name and signature (`Maybe Text -> IO Probe`) so the
   `gatherInventory` call site is unchanged.

3. In `cli/nagarectl/src/Nagare/Ops/Doctor.hs`, update the `"Kourier ingress"` entries so the
   `why` and `command` describe the new predicate accurately (these are shown only on the genuine
   WARN/FAIL grades now):

   - `why … | name == "Kourier ingress" = "The gateway is not reachable on the reserved public IP (and could not be confirmed fronting the node)."`
   - `command … | name == "Kourier ingress" = "curl -sS -o /dev/null -w '%{http_code}\\n' http://$(pulumi -C infra/pulumi stack output publicIp)/ ; also: kubectl get svc -n kourier-system kourier -o wide; kubectl get nodes -o wide"`

4. In `cli/nagarectl/test/Spec.hs`:

   - In `opsTests`, add fixtures and tests for `parseNodeExternalIp` and `gradeKourier`. Cover at
     least: (i) `gradeKourier` with `keHttpCode = Just "404"` → OK; (ii) LB IP present, no curl,
     `keNodeExternalIp = Just publicIp` → OK (fronted); (iii) LB IP present, no curl,
     `keNodeExternalIp = Just <different>` → FAIL; (iv) LB IP present, no curl, no node ExternalIP
     → WARN (inconclusive, **not** FAIL — this is the regression guard); (v) `keLbExternalIp =
     Nothing` → FAIL (no EXTERNAL-IP). Add a `parseNodeExternalIp` fixture with a node carrying
     both an `InternalIP` and an `ExternalIP` address, and one carrying only `InternalIP` →
     `Nothing`.

   - In `doctorTests`, replace the existing `"remediationFor: Kourier ingress FAIL -> compare
     publicIp"` test so it asserts the new `command` text, e.g.
     `cmdOf (Probe "Kourier ingress" StatusFail "…") \`containsT\` "stack output publicIp"` still
     holds (the new command still mentions `stack output publicIp`), and add an assertion that it
     mentions `curl` so the new remediation is pinned.

**Run / acceptance.** `cd cli/nagarectl && cabal test nagarectl-test` is green. Then on a machine
with cluster access (see `docs/runbooks/cluster-access.md`), run `nagarectl doctor`; the Kourier
line reads `[OK] Kourier ingress  serving on 34.145.74.203 (HTTP 404; LB EXTERNAL-IP 10.10.0.4)`
(the exact public IP and node IP depend on the cluster), and the summary shows `0 failed`.


### Milestone M2 — Add the private-image-pull check (soft dep on EP-2)

**Scope.** Add a `doctor` check that reports whether the cluster is configured to pull private
images from the project Artifact Registry — the capability EP-2 (`docs/plans/66-...`) makes
declarative by adding the registry host to `registriesSkippingTagResolving` in the Knative
`config-deployment` ConfigMap (and `registries.yaml` on the node). At the end, `nagarectl doctor`
shows a `private image pull` line: OK when the registry host is listed, WARN ("not configured")
when it is absent, UNKNOWN when the ConfigMap is unreachable.

**Before writing M2:** re-read `docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`.
Confirm (a) the ConfigMap name and namespace (`config-deployment` in `knative-serving` per the
master plan's Integration Point #4), (b) the exact `.data` key — the master plan names
`registriesSkippingTagResolving`, a Knative `config-deployment` field whose value is a
comma-separated list of registry hostnames for which Knative skips digest resolution and pulls by
tag — and (c) the expected host value (the target profile's `tpRegistryHost`, e.g.
`us-west1-docker.pkg.dev`). Record the confirmed shape in the Decision Log.

**Knative term, defined.** `config-deployment` is a ConfigMap in the `knative-serving` namespace
that tunes how Knative Serving creates Kubernetes Deployments for Revisions. Its
`registriesSkippingTagResolving` value is a comma-separated list of registry hosts that Knative
should pull from *by tag* without first resolving the tag to a digest (digest resolution requires
registry credentials Knative may not have for a private registry). Listing the project Artifact
Registry host here is what lets a build-mode app's private image be deployed.

**Edits.**

1. In `cli/nagarectl/src/Nagare/Ops/Probe.hs`, add a pure parser, exported:

   ```haskell
   -- | The hosts listed in config-deployment's registriesSkippingTagResolving
   -- (.data."registriesSkippingTagResolving", a comma-separated string), trimmed.
   -- [] when the key is absent. Nothing on malformed JSON.
   parseSkipTagResolvingHosts :: ByteString -> Maybe [Text]
   ```

   It decodes the ConfigMap JSON, reads `.data.registriesSkippingTagResolving` as a string,
   splits on `,`, and trims each element (reuse `lookupPath`/`textAt`). Return `Just []` when the
   `.data` object exists but the key is absent, `Nothing` only on undecodable JSON.

2. In `cli/nagarectl/src/Nagare/Ops/Status.hs`, add an IO probe and wire it into
   `gatherInventory`. It receives the already-available `TargetProfile`, so no new `gatherInventory`
   plumbing is needed:

   ```haskell
   probePrivateImagePull :: TargetProfile -> IO Probe
   probePrivateImagePull tp = do
     m <- captureTool "kubectl"
            ["get", "configmap", "config-deployment", "-n", "knative-serving", "-o", "json"]
     let host = tpRegistryHost tp
     runMaybe "private image pull" "config-deployment not reachable"
       (m >>= parseSkipTagResolvingHosts) $ \hosts ->
         if host `elem` hosts
           then Probe "private image pull" StatusOk   (host <> " in registriesSkippingTagResolving")
           else Probe "private image pull" StatusWarn (host <> " not configured for private pull")
   ```

   Add `probePrivateImagePull tp` to the `sequence [...]` list in `gatherInventory`, placed
   logically near `probeRegistryAuth tp` (both concern the registry), preserving report order.

3. In `cli/nagarectl/src/Nagare/Ops/Doctor.hs`, catalogue the remediation:

   - `why … | name == "private image pull" = "The cluster is not configured to pull private images from the project Artifact Registry."`
   - `command … | name == "private image pull" = "apply the declarative private-image-pull config (config-deployment registriesSkippingTagResolving + node registries.yaml) per docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md"`

4. In `cli/nagarectl/test/Spec.hs`, add to `opsTests`: a fixture ConfigMap whose
   `registriesSkippingTagResolving` lists `us-west1-docker.pkg.dev` → `parseSkipTagResolvingHosts`
   yields that host; an empty/absent-key fixture → `Just []`; malformed JSON → `Nothing`. Add to
   `doctorTests`: `cmdOf (Probe "private image pull" StatusWarn "…")` mentions
   `docs/plans/66`.

**Run / acceptance.** `cabal test nagarectl-test` green. On the live cluster, after EP-2 has been
applied, `nagarectl doctor` shows `[OK] private image pull  us-west1-docker.pkg.dev in
registriesSkippingTagResolving`. Before EP-2 is applied (or on a cluster lacking the key), it
shows `[WARN] private image pull  us-west1-docker.pkg.dev not configured for private pull` and the
summary counts it as a warning, not a failure (so it never blocks `doctor`'s exit code).


### Milestone M3 — Add the build/node architecture-mismatch check (soft dep on EP-3)

**Scope.** Add a `doctor` check that WARNs when the configured build/target platform and the k3s
node's CPU architecture disagree (e.g. building `linux/arm64` for an `amd64` node), with a hint to
set the platform. At the end, `nagarectl doctor` shows a `build platform` line: OK when they match,
WARN when they differ, UNKNOWN when the node arch is unreadable.

**Before writing M3:** re-read `docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md`
and `cli/nagarectl/src/Nagare/Target.hs`. Confirm the final field name EP-3 added to
`TargetProfile`. The master plan's Integration Point #2 names the environment variable
`NAGARE_TARGET_PLATFORM` (default `linux/amd64`); the corresponding record accessor is expected to
be `tpTargetPlatform :: TargetProfile -> Text`. Record the confirmed accessor name in the Decision
Log. **Do not add the field yourself** — that is EP-3's responsibility; if it is missing, M3's
wiring (step 2) is blocked on that one accessor, but the pure parser and grader (step 1) can be
implemented and tested ahead of time.

**Platform vs architecture, defined.** A Docker/OCI **platform** is `os/arch` such as
`linux/amd64` or `linux/arm64`. A Kubernetes node reports just the **architecture** (`amd64`,
`arm64`) in `.status.nodeInfo.architecture` from `kubectl get nodes -o json` (equivalently
`kubectl get node <name> -o jsonpath='{.status.nodeInfo.architecture}'`). The check compares the
*arch* component of the configured platform against the node arch. The arch token in a platform
string is the part after the first `/` (and before an optional `/variant`): `linux/amd64` →
`amd64`, `linux/arm64/v8` → `arm64`.

**Edits.**

1. In `cli/nagarectl/src/Nagare/Ops/Probe.hs`, add two pure helpers, exported:

   ```haskell
   -- | The first node's architecture from kubectl get nodes -o json:
   -- .items[0].status.nodeInfo.architecture, e.g. "amd64". Nothing on malformed JSON.
   parseNodeArch :: ByteString -> Maybe Text

   -- | Grade a platform string (e.g. "linux/arm64") against a node arch (e.g.
   -- "amd64"). Compares the arch token of the platform (segment after the first
   -- '/', ignoring any '/variant') to the node arch, case-insensitively.
   -- OK when equal, WARN when different.
   gradeArch :: Text -> Text -> Probe   -- platform -> nodeArch -> Probe
   ```

   `gradeArch` extracts the arch token from the platform and produces
   `Probe "build platform" StatusOk ("linux/amd64 matches node amd64")` or
   `Probe "build platform" StatusWarn ("linux/arm64 will not run on amd64 node")`.

2. In `cli/nagarectl/src/Nagare/Ops/Status.hs`, add the IO probe and wire it in. It reads the
   platform from the `TargetProfile` (already available in `gatherInventory`) and the node arch
   from `kubectl`:

   ```haskell
   probeArch :: TargetProfile -> IO Probe
   probeArch tp = do
     m <- captureTool "kubectl" ["get", "nodes", "-o", "json"]
     runMaybe "build platform" "node arch not reachable" (m >>= parseNodeArch) $ \arch ->
       gradeArch (tpTargetPlatform tp) arch
   ```

   Add `probeArch tp` to the `sequence [...]` list in `gatherInventory` (near `probeNode`, since
   both read node JSON; do not merge the kubectl calls — keep the probes independent so one
   failing source does not take down another).

   If EP-3's field is not yet present, temporarily resolve the platform from the environment with
   the documented default inside `probeArch` (`lookupEnv "NAGARE_TARGET_PLATFORM"` defaulting to
   `"linux/amd64"`) and leave a `-- TODO(EP-3): switch to tpTargetPlatform once the field lands`
   comment, then convert to `tpTargetPlatform tp` once EP-3 has merged. Record this in the
   Decision Log if used.

3. In `cli/nagarectl/src/Nagare/Ops/Doctor.hs`, catalogue the remediation:

   - `why … | name == "build platform" = "The configured build platform does not match the cluster node architecture; images built here will not run on the node."`
   - `command … | name == "build platform" = "set NAGARE_TARGET_PLATFORM (e.g. linux/amd64) in nagare.target.env to match the node architecture; see docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md"`

4. In `cli/nagarectl/test/Spec.hs`: add to `opsTests` a node-JSON fixture with
   `.status.nodeInfo.architecture == "amd64"` → `parseNodeArch` yields `Just "amd64"`, plus a
   malformed case → `Nothing`; and `gradeArch` cases: `gradeArch "linux/amd64" "amd64"` → status
   `StatusOk`, `gradeArch "linux/arm64" "amd64"` → `StatusWarn`, `gradeArch "linux/arm64/v8"
   "arm64"` → `StatusOk`. Add to `doctorTests`: `cmdOf (Probe "build platform" StatusWarn "…")`
   mentions `NAGARE_TARGET_PLATFORM`. If the `tnbProfile` fixture must gain the new field for the
   suite to compile (because EP-3 added it to the record), set `tpTargetPlatform = "linux/amd64"`
   in that literal at line ~332.

**Run / acceptance.** `cabal test nagarectl-test` green. On the live `amd64` cluster with the
default `linux/amd64` platform, `nagarectl doctor` shows `[OK] build platform  linux/amd64 matches
node amd64`. With `NAGARE_TARGET_PLATFORM=linux/arm64` exported, it shows `[WARN] build platform
linux/arm64 will not run on amd64 node`, counted as a warning (never affecting the exit code).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless noted.

Build and test the CLI (the primary feedback loop for every milestone):

```bash
cd cli/nagarectl
cabal build nagarectl
cabal test nagarectl-test
```

A green run ends with a line like:

```text
All N tests passed (0.0Ns)
nagarectl-test: All tests passed.
```

Run the doctor against the live cluster (requires cluster access per
`docs/runbooks/cluster-access.md`; the VM must be running and kubectl must point at the k3s
cluster, not the unrelated GKE context):

```bash
# from the repo root, with .envrc allowed (direnv) so CLOUDSDK_* and PULUMI_* are set
cabal --project-dir=cli/nagarectl run nagarectl -- doctor
```

Expected on the healthy 2026-06-10-style cluster after M1 (exact IPs/codes vary):

```text
nagare doctor — 21 checks

  [OK]    VM                       RUNNING
  …
  [OK]    Kourier ingress          serving on 34.145.74.203 (HTTP 404; LB EXTERNAL-IP 10.10.0.4)
  …
  [OK]    private image pull       us-west1-docker.pkg.dev in registriesSkippingTagResolving
  [OK]    build platform           linux/amd64 matches node amd64
  …

  0 failed, 0 warnings, 21 ok.
```

(The check count rises from 19 to 21 once M2 and M3 land; before they land it is 20 after M1
adds nothing to the count — M1 modifies the existing Kourier probe rather than adding one.)

To reproduce the original bug for a before/after comparison, temporarily revert
`probeKourierIp` to the `want == ip` form and observe the `[FAIL] Kourier ingress` line; then
re-apply M1 and observe `[OK]`.


## Validation and Acceptance

The change is validated at two levels: pure unit tests (no cluster needed) and a live
end-to-end `doctor` run.

**Unit tests** (`cd cli/nagarectl && cabal test nagarectl-test`). The suite must be green and
must include, beyond the existing `parseKourierIp` tests which remain:

- `gradeKourier` graded OK on a curl-reachable gateway (`keHttpCode = Just "404"`).
- `gradeKourier` graded OK on a node-internal LB IP whose node ExternalIP equals `publicIp`
  (curl absent).
- `gradeKourier` graded FAIL when the node ExternalIP differs from `publicIp`.
- `gradeKourier` graded **WARN, not FAIL**, when neither curl nor a node ExternalIP can confirm
  fronting (the regression guard against the original false FAIL).
- `gradeKourier` graded FAIL when no LB EXTERNAL-IP is assigned.
- `parseNodeExternalIp` extracts the ExternalIP address and returns `Nothing` when only an
  InternalIP is advertised.
- `parseSkipTagResolvingHosts` extracts the host list, returns `Just []` for an absent key, and
  `Nothing` for malformed JSON; the private-image-pull remediation mentions `docs/plans/66`.
- `parseNodeArch` extracts `amd64`; `gradeArch` is OK on match (including a `/variant` platform)
  and WARN on mismatch; the build-platform remediation mentions `NAGARE_TARGET_PLATFORM`.

**Live acceptance.** Run `nagarectl doctor` against the healthy cluster. The Kourier line is
`[OK]` (the explicit acceptance from the master plan: "a `doctor` run that no longer lies"); the
`private image pull` line is `[OK]` once EP-2 is applied (or `[WARN]` before, never `[FAIL]`); the
`build platform` line is `[OK]` on the `amd64` node with the default platform (or `[WARN]` with a
mismatched `NAGARE_TARGET_PLATFORM`, never `[FAIL]`); and the summary shows `0 failed`. The exit
code is `0` (verify with `echo $?`), confirming the false FAIL is gone and the two new advisory
checks do not gate the exit code.


## Idempotence and Recovery

Every change here is to pure Haskell code and unit tests; there are no migrations, no writes to
the cluster, and no destructive operations. `doctor` itself is **read-only**: it inspects with
`gcloud`/`kubectl`/`pulumi`/`gsutil`/`curl` and prints text; it never mutates the cluster, so it is
safe to run repeatedly. The new `curl` reachability probe is a single GET against the public IP
with a 5-second timeout; it has no side effects.

If a milestone's edits leave the build broken, `git checkout -- cli/nagarectl/src/Nagare/Ops/`
restores the three modules and `git checkout -- cli/nagarectl/test/Spec.hs` restores the tests;
each milestone is independent, so M1 can ship while M2/M3 wait on EP-2/EP-3. Re-running
`cabal test nagarectl-test` after any restore returns to a known-good state. Because the probes
degrade gracefully (a missing tool or unreachable source yields `StatusUnknown`/`StatusWarn`, never
an exception — the IP4 convention enforced by `captureTool`/`runMaybe`), a partially configured
cluster never crashes the command.


## Interfaces and Dependencies

**Modules edited (EP-4 is the single writer of these per Integration Point #3):**

- `cli/nagarectl/src/Nagare/Ops/Probe.hs` — gains exported pure helpers:
  `KourierEvidence(..)`, `gradeKourier :: KourierEvidence -> Probe`,
  `parseNodeExternalIp :: ByteString -> Maybe Text`,
  `parseSkipTagResolvingHosts :: ByteString -> Maybe [Text]`,
  `parseNodeArch :: ByteString -> Maybe Text`,
  `gradeArch :: Text -> Text -> Probe`. The `Probe`/`ProbeStatus` model is unchanged.
- `cli/nagarectl/src/Nagare/Ops/Status.hs` — `probeKourierIp :: Maybe Text -> IO Probe` rewritten
  (signature unchanged) plus a private `curlHttpCode :: Text -> IO (Maybe Text)`; new
  `probePrivateImagePull :: TargetProfile -> IO Probe` and `probeArch :: TargetProfile -> IO Probe`,
  both added to the `sequence [...]` in `gatherInventory :: TargetProfile -> InventoryOpts -> IO [Probe]`.
- `cli/nagarectl/src/Nagare/Ops/Doctor.hs` — the `why` and `command` functions gain/adjust the
  `"Kourier ingress"`, `"private image pull"`, and `"build platform"` cases. No type changes.
- `cli/nagarectl/test/Spec.hs` — new fixtures and tests in `opsTests` and `doctorTests`.

**Modules read but not edited:**

- `cli/nagarectl/src/Nagare/Ops/Pulumi.hs` — `stackOutput :: FilePath -> Text -> IO (Maybe Text)`,
  used (already) to obtain `publicIp`.
- `cli/nagarectl/src/Nagare/Target.hs` — `TargetProfile`, `resolveTargetProfile`,
  `tpRegistryHost`, and (from EP-3) `tpTargetPlatform`. M3 depends on EP-3 having added
  `tpTargetPlatform`; until then M3 falls back to reading `NAGARE_TARGET_PLATFORM` from the
  environment with the `linux/amd64` default.
- `cli/nagarectl/app/Main.hs` — `runDoctor` (≈ line 1500) needs **no change**: the new probes
  read `TargetProfile`, which `gatherInventory` already receives.

**External tools the probes invoke** (all via `captureTool`, so absence degrades gracefully):
`kubectl` (Service, nodes, ConfigMap JSON), `pulumi` (the `publicIp` output, already gathered),
and `curl` (the M1 reachability GET — optional, with the node-ExternalIP fallback when absent).

**Soft dependencies (no hard blocking):**

- **EP-2** (`docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`) —
  establishes the Knative `config-deployment` `registriesSkippingTagResolving` capability M2
  reads. M2's parser/probe compile and run regardless; they simply report WARN until EP-2 is
  applied to the cluster. Coordinate the exact ConfigMap key and host value with EP-2 (re-read
  before implementing M2).
- **EP-3** (`docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md`) —
  adds the `NAGARE_TARGET_PLATFORM` profile field M3 reads (`tpTargetPlatform`). M3's pure
  parser/grader are independent; the wiring reads the field once EP-3 lands, with an
  environment-variable fallback in the interim. Re-read before implementing M3 to confirm the
  accessor name.
