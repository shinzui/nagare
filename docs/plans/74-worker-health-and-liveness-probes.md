---
id: 74
slug: worker-health-and-liveness-probes
title: "Worker health and liveness probes"
kind: exec-plan
created_at: 2026-06-19T00:36:47Z
intention: "intention_01kvemvx2reyn9qa49qks2dpcj"
master_plan: "docs/masterplans/14-multi-workload-applications-for-nagare.md"
---

# Worker health and liveness probes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change a developer can attach an **optional liveness/health probe** to a
`Worker` and have it rendered into the worker's `apps/v1` Deployment as a Kubernetes
`livenessProbe` (and, when requested, a `startupProbe`). The probe supports **exec** (run a
command) and **TCP** (open a port) checks — not only HTTP — because a Nagare worker is
**headless**: it renders to a plain Deployment with no Service and no HTTP port (see
`docs/user/workers.md` and `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`), so an
HTTP-only probe would be useless for the common case.

The user-visible behavior: a worker that is a NOTIFY/timer loop — like kizashi's `worker`,
`escalation-worker`, and `agent-worker` reactors (`/Users/shinzui/Keikaku/bokuno/kizashi`,
described in the parent MasterPlan
`docs/masterplans/14-multi-workload-applications-for-nagare.md`) — can **hang without
crashing**. Kubernetes only restarts a container when its process *exits*; a hung loop that
never exits is never recovered. By declaring, e.g., an exec probe that runs a healthcheck
script (`["/app/healthcheck", "--max-lag", "60"]`) every 30 seconds, the developer makes a
hung worker observable: after `failureThreshold` consecutive failures, the kubelet kills
and restarts the container. You can see it working entirely offline with `nagarectl worker
deploy --dry-run`, which prints the rendered Deployment YAML now containing a
`livenessProbe:` block under the container. A worker that declares **no** probe renders
exactly as it does today — byte-identical output, no probe block.


## Progress

- [x] M1 (2026-06-18) — `WorkerProbe` sum (`ExecProbe`/`TcpProbe`/`HttpProbe`) + `ProbeTiming`,
      optional `liveness :: Maybe WorkerProbe` field on `Worker` (default `Nothing`), and the smart
      constructors `mkProbeTiming`/`defaultProbeTiming`/`mkExecProbe`/`mkTcpProbe`/`mkHttpProbe`/
      `execProbe`/`probeTiming` (`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`). `webWorker` and
      `Load.toWorker` set `liveness = Nothing`.
- [x] M1 (2026-06-18) — `WorkerSpec` `WorkerProbe` group covers the timing-range and exec-argv
      validation, `execProbe` default timing, the http-path rule, and the `Nothing` default; full
      suite green (311 tests, no regression to existing worker/application round-trips or goldens).
- [x] M2 (2026-06-18) — JSON encode (`workerJSON` + `workerProbeJSON` in
      `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, a `"kind"`-tagged object with flat timing) and
      decode (`JsonWorker.jwLiveness` + `JsonWorkerProbe` + `toWorkerProbe` in
      `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, re-running the smart constructors) round-trip. The
      `liveness` key is decoded with `.:?`, so old worker JSON with no key decodes to `Nothing`
      (backward compatible).
- [x] M2 (2026-06-18) — round-trip tests in `WorkerSpec` cover exec, TCP, HTTP, and (via the
      existing `minimal`/`rich` fixtures) no-probe workers; full suite green (314 tests). EP-1's
      Application round-trip and the runghc load tests are unaffected (embedded workers now emit
      `"liveness":null`, which decodes back to `Nothing`).
- [x] M3 (2026-06-18) — renderer emits `livenessProbe` (and `startupProbe` when `asStartup`) into
      the worker container via a new `probesField`/`checkPair`/`timingPairs` in
      `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` (exec/tcpSocket/httpGet; no readinessProbe).
      The `keyCompare` rank table gained the container-level probe keys (`livenessProbe` 6,
      `startupProbe` 7, `volumeMounts` bumped to 8) and the probe-internal keys. New golden
      `cli/nagare-dsl/test/golden/worker-exec-probe.deployment.yaml`.
- [x] M3 (2026-06-18) — the existing `worker-minimal`/`worker-rich` goldens did NOT regenerate
      (proving a no-probe worker is byte-identical), and an explicit `testCase` asserts a no-probe
      worker renders no `livenessProbe`. Behavioral tests cover exec/tcp/startup. Full suite green
      (319 tests).
- [ ] M4 — `docs/user/workers.md` field table gains a `liveness` row; the
      `cluster/examples/queue-worker` example shows a probe.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Introduce a new worker-specific `WorkerProbe` sum type
  (`ExecProbe | TcpProbe | HttpProbe`) rather than reusing the app
  `Nagare.Dsl.Types.HealthCheck`.
  Rationale: `HealthCheck` is structurally HTTP-only — its mandatory fields are `path`
  (validated to start with `/`), `scheme :: HealthScheme` (`HTTP | HTTPS`),
  `expectedStatus`, and a `checkPort` that defaults to the *container* port. A worker has
  no container port and no HTTP path, so reusing `HealthCheck` would force meaningless
  fields (`path`, `scheme`) and could not express the headline exec case at all. A sum type
  makes the exec/TCP/HTTP choice exclusive at the type level (the same maximal-safety
  discipline as `EnvVar`'s literal-XOR-secret invariant), and keeps each branch carrying
  exactly the fields Kubernetes needs for that probe kind. The shared *timing* fields
  (`initialDelay`, `period`, `timeout`, `failureThreshold`) and the `asStartup` flag are
  factored into a `ProbeTiming` record reused across branches, so we are not duplicating the
  validation that already lives in `mkHealthCheck`.
  Date: 2026-06-18

- Decision: Keep the new field **optional** (`liveness :: Maybe WorkerProbe`) with a default
  of `Nothing` ("no probe"), added to the public `Worker` record without changing any
  existing field or smart constructor.
  Rationale: EP-1 (`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`)
  embeds `Worker` values inside its `Application` aggregate; an optional field with a sane
  default flows through embedding automatically and cannot break EP-1's construction. A
  no-probe worker must remain byte-identical in rendered YAML and JSON to today's output,
  which `Nothing` guarantees.
  Date: 2026-06-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan adds an optional liveness probe to the Nagare **`Worker`** workload kind. The
reader needs the following orientation; all paths are relative to the repository root
`/Users/shinzui/Keikaku/bokuno/nagare`.

**What a `Worker` is.** A `Worker` (defined in
`cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`) is Nagare's model for a continuous background
process that is *not* request-driven — a queue consumer, a stream processor, a polling
loop. Unlike a request-driven app (which renders to a Knative Service), a `Worker` renders
to a plain Kubernetes **`apps/v1` Deployment** (see
`cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`). It has no Service, no Ingress, no HTTP
port, and no autoscaler. It is **headless** by design. The `Worker` record today has these
fields (verbatim from `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`, lines 106–118):
`name :: ServiceName`, `namespace :: Namespace`, `image :: ImageRef`, `build :: BuildSpec`,
`command :: Maybe Command`, `replicas :: Replicas`, `env :: Map EnvName ScopedEnvVar`,
`resources :: Maybe Resources`, `volumes :: [Volume]`, `databases :: [DatabaseName]`. There
is no hidden constructor for `Worker`; the safety guarantee comes from the field types,
each of which is reused from `Nagare.Dsl.Types` / `Nagare.Dsl.Build` or smart-constructed in
this module (`Replicas`/`mkReplicas`, `Command`/`mkCommand`). The `webWorker :: Text ->
Text -> Either String Worker` preset builds a runnable default from a name and an image
repository.

**The "maximal-safety smart-constructor" pattern.** Throughout the DSL
(`cli/nagare-dsl/src/Nagare/Dsl/Types.hs`), each constrained type hides its data
constructor and exposes only a validating smart constructor `mkX :: ... -> Either Text X`
plus read-only accessors. Code outside the module therefore cannot build an invalid value;
a bad value is rejected at construction with a precise `Left` message instead of being
written down to fail at the cluster. The headline example is `EnvVar` (a sum type that makes
"literal value" and "secret reference" mutually exclusive). The new `WorkerProbe` follows
this pattern: a sum type whose branches are mutually exclusive, with a `mkWorkerProbe`-style
validator for the cross-field timing constraints.

**Liveness probe vs. startup probe (Kubernetes terms).** A **`livenessProbe`** is a check
the kubelet runs *periodically* against a running container; on `failureThreshold`
consecutive failures the kubelet **restarts** the container. This is exactly the recovery a
hung worker needs. A **`startupProbe`** runs *only during startup*; until it first
succeeds, the liveness probe is suspended — this protects slow-starting workers from being
killed before they are ready. A **`readinessProbe`** gates whether a Pod receives *traffic*;
it is meaningless for a headless worker (nothing routes to it), so this plan does **not**
emit a readiness probe — only liveness and optional startup.

**Exec vs. TCP vs. HTTP probes (Kubernetes terms).** Kubernetes supports three probe
*mechanisms* in a container probe object: `exec` (run a command inside the container; exit
code `0` is healthy), `tcpSocket` (open a TCP connection to a port; success = connection
established), and `httpGet` (issue an HTTP GET; any 2xx/3xx is healthy). A headless worker
has no HTTP server, so **exec is the primary mechanism** — a worker ships a small
healthcheck binary/script that, e.g., checks a heartbeat file's mtime or queries a "last
processed" timestamp, and exits non-zero when the loop has stalled. **TCP** is offered for
workers that *do* listen on an internal port (e.g. a metrics endpoint) without speaking
HTTP. **HTTP** is offered for completeness (a worker with an internal `/healthz`), but is
not the motivating case.

**How the app `HealthCheck` is rendered today (the pattern to mirror).** The app renderer
`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` has a `probesField :: Maybe HealthCheck -> Port ->
[Pair]` (around line 417). It always emits a `readinessProbe`, and additionally a
`livenessProbe` when `asLiveness` and a `startupProbe` when `asStartup`. Each probe object
is `{ httpGet: { path, port, scheme }, initialDelaySeconds, periodSeconds, timeoutSeconds,
failureThreshold }`. The new worker `probesField` mirrors the *timing* keys and the
liveness/startup gating, but swaps `httpGet` for `exec`/`tcpSocket`/`httpGet` depending on
the `WorkerProbe` branch, and omits `readinessProbe`.

**Where workers serialize and deserialize.** A worker config's `Config.hs` calls
`emitWorker` (`cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, around line 210), which encodes via
`workerJSON` (line 222). The loader decodes it via `JsonWorker`'s `FromJSON` instance and
`toWorker` (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`, lines 756–804), which re-runs the smart
constructors as defence-in-depth. The emit→decode round-trip must be the identity.

**Where worker tests and goldens live.** `cli/nagare-dsl/test/WorkerSpec.hs` is the spec
module. Renderer goldens live in `cli/nagare-dsl/test/golden/` —
`worker-minimal.deployment.yaml`, `worker-rich.deployment.yaml`,
`worker-rich.manifests.yaml`. Tests use `Test.Tasty.Golden.goldenVsString` and a
fixed timestamp `"20260602-120000"`. The config-load fixture is
`cli/nagare-dsl/test/fixtures/worker/nagare/Config.hs`.

**The documentation gap.** `docs/user/workers.md` has a "`Worker` config fields" table
(lines 82–94) that currently has **no** `healthCheck`/`liveness` row — that absence is
exactly the gap this plan closes. The worked example is
`cluster/examples/queue-worker/nagare/Config.hs` (a `sh -c "while true; do echo working;
sleep 5; done"` loop with 2 replicas), the canonical "hang-prone loop" this plan protects.

**Integration with sibling plans (no hard dependency).** This plan is EP-3 of MasterPlan
14. It is **orthogonal** to EP-1
(`docs/plans/72-application-aggregate-typed-multi-workload-app-with-shared-image-env-and-database-bindings.md`),
which introduces the `Application` aggregate that *embeds* `Worker` values. Because the new
`liveness` field is optional with a `Nothing` default and is added without altering any
existing `Worker` field, EP-1's embedding is unaffected: once both land, the field flows
through the aggregate automatically. EP-2
(`docs/plans/73-orchestrated-release-nagarectl-app-deploy-with-ordered-rollout-and-pre-deploy-migration-hooks.md`)
renders aggregated workers via the same `renderWorker` this plan extends, so an aggregated
worker emits its probe with no extra wiring. There are **no hard dependencies**; this plan
can land in parallel with EP-1. The only contract obligation is that EP-3 is the *definer*
of the field's name (`liveness`) and shape (`Maybe WorkerProbe`); EP-1/EP-2 must not
redefine it.


## Plan of Work

The work is four independently-verifiable milestones. M1–M3 are pure `nagare-dsl` library
changes verifiable offline with `cabal test nagare-dsl`; M4 is documentation plus an example
config. Each milestone leaves the build green.

### M1 — the probe type, the optional field, and validation

Scope: introduce the `WorkerProbe` model and attach it to `Worker`, with smart
constructors that enforce all invariants. At the end of M1 the type exists, is exported, the
`Worker` record carries `liveness :: Maybe WorkerProbe` defaulting to `Nothing`, and
`WorkerSpec` proves the constructors accept valid input and reject invalid input. Nothing
renders or serializes the field yet (M2/M3).

Edits, all in `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs`:

1. Add a `ProbeTiming` record holding the four timing fields shared by every probe kind plus
   the startup flag:

   ```haskell
   -- | Probe timing, shared across every 'WorkerProbe' branch. All durations are
   -- in seconds. Construct via 'mkProbeTiming' (validates the ranges) or
   -- 'defaultProbeTiming'.
   data ProbeTiming = ProbeTiming
     { initialDelay :: !Int       -- ^ seconds before the first probe; @>= 0@.
     , period :: !Int             -- ^ seconds between probes; @>= 1@.
     , timeout :: !Int            -- ^ per-probe timeout seconds; @>= 1@.
     , failureThreshold :: !Int   -- ^ consecutive failures before restart; @>= 1@.
     , asStartup :: !Bool         -- ^ also emit a @startupProbe@ with the same check.
     }
     deriving stock (Generic, Eq, Show)
   ```

2. Add a `WorkerProbe` sum type — exec, TCP, or HTTP — each branch carrying the timing:

   ```haskell
   -- | A liveness check for a headless worker. The branch selects the Kubernetes
   -- probe mechanism: 'ExecProbe' runs a command (exit 0 = healthy) — the primary
   -- case for a worker with no HTTP server; 'TcpProbe' opens a TCP port;
   -- 'HttpProbe' issues an HTTP GET (for a worker that happens to expose an
   -- internal endpoint). The sum makes the choice exclusive at the type level.
   -- Construct via 'mkExecProbe' / 'mkTcpProbe' / 'mkHttpProbe'.
   data WorkerProbe
     = ExecProbe ![Text] !ProbeTiming        -- ^ argv; non-empty, NUL-free.
     | TcpProbe !Port !ProbeTiming           -- ^ TCP port to dial.
     | HttpProbe !Text !(Maybe Port) !HealthScheme !ProbeTiming
       -- ^ HTTP path (starts with @/@), optional port, scheme.
     deriving stock (Generic, Eq, Show)
   ```

   `Port` and `HealthScheme` are imported from `Nagare.Dsl.Types` (already a dependency of
   this module).

3. Add the smart constructors. `mkProbeTiming` validates ranges identically to
   `mkHealthCheck` (`initialDelay >= 0`; `period`, `timeout`, `failureThreshold >= 1`).
   `defaultProbeTiming` mirrors `httpHealthCheck`'s defaults (`initialDelay = 0`,
   `period = 10`, `timeout = 1`, `failureThreshold = 3`, `asStartup = False`). `mkExecProbe`
   reuses the `mkCommand` argv invariant (non-empty, NUL-free). `mkTcpProbe` takes an
   already-validated `Port`. `mkHttpProbe` validates the path starts with `/`. A
   convenience `execProbe :: [Text] -> Either Text WorkerProbe` builds an exec probe with
   `defaultProbeTiming`.

   ```haskell
   mkProbeTiming :: ProbeTiming -> Either Text ProbeTiming
   defaultProbeTiming :: ProbeTiming
   mkExecProbe :: [Text] -> ProbeTiming -> Either Text WorkerProbe
   mkTcpProbe :: Port -> ProbeTiming -> WorkerProbe
   mkHttpProbe :: Text -> Maybe Port -> HealthScheme -> ProbeTiming -> Either Text WorkerProbe
   execProbe :: [Text] -> Either Text WorkerProbe   -- exec + defaultProbeTiming
   ```

4. Add the field to the `Worker` record (after `databases`, keeping existing fields
   untouched):

   ```haskell
   , liveness :: !(Maybe WorkerProbe)
   -- ^ optional liveness/health probe (EP-74). 'Nothing' (the default) emits no
   -- probe — byte-identical to a worker without one.
   ```

5. Set `liveness = Nothing` in the `webWorker` preset's record literal so the preset stays
   total.

6. Extend the module export list: `WorkerProbe (..)`, `ProbeTiming (..)`, `mkProbeTiming`,
   `defaultProbeTiming`, `mkExecProbe`, `mkTcpProbe`, `mkHttpProbe`, `execProbe`.

M1 tests (in `cli/nagare-dsl/test/WorkerSpec.hs`, a new `testGroup "WorkerProbe"` added to
`workerTests`): `mkProbeTiming` rejects `period = 0`, `failureThreshold = 0`,
`initialDelay = -1`; accepts the defaults. `mkExecProbe` rejects `[]` and a NUL argument,
accepts `["/app/healthcheck"]`. `execProbe` yields the default timing. `webWorker` preset
has `liveness = Nothing`.

Acceptance: `cabal test nagare-dsl` passes; the new constructors compile and the validation
cases hold.

### M2 — JSON encode/decode round-trip

Scope: serialize and deserialize the `liveness` field so a worker config emits it and the
loader reads it back as the identity. At the end of M2, `decodeWorker (encodeWorker w) ==
Right w` for exec-, TCP-, HTTP-, and no-probe workers.

Edits:

1. `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`, in `workerJSON` (line 222): add a
   `"liveness" .= fmap workerProbeJSON (w ^. #liveness)` entry, and a local
   `workerProbeJSON :: WorkerProbe -> Value` helper. Use a `"kind"` discriminator
   (`"Exec"|"Tcp"|"Http"`) matching the existing tagged-union convention used by
   `buildSpecJSON` (line 165). Emit the timing fields flat alongside the kind-specific
   fields, e.g. for exec:

   ```json
   { "kind": "Exec", "command": ["/app/healthcheck"],
     "initialDelay": 0, "period": 10, "timeout": 1,
     "failureThreshold": 3, "asStartup": false }
   ```

   For `Tcp` add `"port": <int>`; for `Http` add `"path"`, `"checkPort"` (nullable int),
   `"scheme"` (`"HTTP"|"HTTPS"`). When `liveness` is `Nothing`, the value is JSON `null`
   (matching how `deploymentJSON` emits `"healthCheck" .= fmap healthCheckJSON ...`). Import
   `WorkerProbe (..)`, `ProbeTiming (..)` from `Nagare.Dsl.Worker`.

2. `cli/nagare-dsl/src/Nagare/Dsl/Load.hs`:
   - Add a `jwLiveness :: !(Maybe JsonWorkerProbe)` field to the `JsonWorker` record (after
     `jwDatabases`, line 752) and `<*> o .:? "liveness"` to its `FromJSON` instance (after
     line 771). Because it is `.:?`, an old JSON document with no `liveness` key decodes to
     `Nothing` — backward compatible.
   - Add a `JsonWorkerProbe` type with a `FromJSON` instance that dispatches on the `kind`
     discriminator and parses the timing + per-kind fields.
   - In `toWorker` (line 778), add `liveness' <- traverse toWorkerProbe (jwLiveness j)` and
     set `liveness = liveness'` in the record. `toWorkerProbe :: JsonWorkerProbe -> Either
     LoadError WorkerProbe` re-runs `mkExecProbe`/`mkTcpProbe`/`mkHttpProbe` and
     `mkProbeTiming` (and `mkPort` for the port fields), wrapping failures in
     `MarshalError "liveness"`.

M2 tests (extend `roundTripTests` in `WorkerSpec.hs`): an `execProbeWorker`, a
`tcpProbeWorker`, and an `httpProbeWorker` fixture each satisfy `decodeWorker (toStrict
(encodeWorker w)) == Right w`. The existing `minimalWorker`/`richWorker` round-trips still
pass (they have `liveness = Nothing`).

Acceptance: `cabal test nagare-dsl` passes; round-trip is identity for all four shapes.

### M3 — renderer emits the probe + golden test

Scope: the renderer emits `livenessProbe` (and `startupProbe` when `asStartup`) into the
worker's Deployment container. At the end of M3 a probe-bearing worker renders a probe block;
a no-probe worker is byte-identical to today.

Edits, all in `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`:

1. In `containerValue` (line 124), append `<> probesField (w ^. #liveness)` to the container
   pair list, after `resourcesPairs` and before `volumeMountsField` (so probe keys sit
   between `resources` and `volumeMounts`, matching the app renderer's container ordering).

2. Add `probesField :: Maybe WorkerProbe -> [Pair]`, mirroring the app's `probesField`
   (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`, line 417) but with no `readinessProbe`:

   ```haskell
   probesField :: Maybe WorkerProbe -> [Pair]
   probesField Nothing = []
   probesField (Just p) =
     ["livenessProbe" .= probe]
       <> (if asStartup (probeTiming p) then ["startupProbe" .= probe] else [])
     where
       probe = object (checkPair p <> timingPairs (probeTiming p))
   ```

   `checkPair` renders `["exec" .= object ["command" .= argv]]`, or
   `["tcpSocket" .= object ["port" .= portInt port]]`, or
   `["httpGet" .= object ["path" .= path, "port" .= port, "scheme" .= scheme]]`.
   `timingPairs` renders `initialDelaySeconds`/`periodSeconds`/`timeoutSeconds`/
   `failureThreshold` exactly as the app renderer does. `probeTiming :: WorkerProbe ->
   ProbeTiming` extracts the shared timing from any branch.

3. Extend the `keyCompare` rank table (line 170) with the new container-level and
   probe-internal keys so output ordering is deterministic. NOTE: the rank table is
   `ranks :: [(Text, Int)]` (integer ranks — verified in
   `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`), so a fractional rank like `5.5` is not
   possible; you must renumber. The current container ranks are `resources = 5`,
   `volumeMounts = 6`; to place the probes between them, set `("livenessProbe", 6)`,
   `("startupProbe", 7)`, and bump `("volumeMounts", 8)`. Then add probe-internal keys
   `("exec", 0)`, `("tcpSocket", 0)`,
   `("httpGet", 0)`, `("command", ...)`, `("port", ...)`, `("initialDelaySeconds", ...)`,
   `("periodSeconds", ...)`, `("timeoutSeconds", ...)`, `("failureThreshold", ...)`,
   `("scheme", ...)`, `("path", ...)`. Follow the exact pattern already used for the app
   renderer's probe keys (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs`, lines 241–259).

M3 tests (extend `renderTests` in `WorkerSpec.hs`): add an `execProbeWorker` fixture (the
`minimalWorker` plus `liveness = Just (unsafe (execProbe ["/app/healthcheck"]))`) and a new
golden `cli/nagare-dsl/test/golden/worker-exec-probe.deployment.yaml`. Add a `testCase`
asserting `renderWorkerDeployment minimalWorker "20260602-120000"` is unchanged — re-run the
existing `worker-minimal.deployment.yaml` golden; it must NOT regenerate (proves a no-probe
worker is byte-identical). Optionally add a `worker-tcp-probe.deployment.yaml` golden.

Acceptance: `cabal test nagare-dsl` passes; the exec-probe golden contains a `livenessProbe`
with an `exec.command`; the minimal golden is unchanged.

### M4 — docs + example

Scope: document the field and update the canonical example so a reader sees the headline
case. At the end of M4, `docs/user/workers.md` has a `liveness` row and the queue-worker
example declares an exec probe.

Edits:

1. `docs/user/workers.md`: add a row to the "`Worker` config fields" table (after
   `databases`, line 93):

   ```text
   | `liveness`   | Optional liveness probe — `exec` (run a command), `tcp` (open a port), or `http`. Absent = no probe. Restarts a hung worker that never crashes. |
   ```

   Add a short subsection "Liveness probes for hung workers" explaining why a headless
   NOTIFY/timer loop needs an exec probe, with a `Config.hs` snippet using `execProbe`.

2. `cluster/examples/queue-worker/nagare/Config.hs`: add `liveness = Just (unsafe (execProbe
   [...]))` to the worker (a check appropriate to the `echo working` loop — e.g. an exec
   probe that always succeeds, or `["sh", "-c", "test -f /tmp/heartbeat"]` with the loop
   touching the heartbeat). Keep it compiling under `-XGHC2024` (plain record updates, no
   `OverloadedLabels`). The `examples-compile` flake check must still pass.

Acceptance: `docs/user/workers.md` lists `liveness`; the example compiles
(`nagarectl worker deploy --dry-run -f cluster/examples/queue-worker/nagare/Config.hs`
renders a `livenessProbe`).


## Concrete Steps

Run all `cabal`/`nagarectl` commands from the repository root
`/Users/shinzui/Keikaku/bokuno/nagare`.

1. Build and run the library tests after each milestone:

   ```bash
   cabal build nagare-dsl
   cabal test nagare-dsl
   ```

   Expected tail after M3 (the renderer goldens and round-trips pass):

   ```text
   Nagare.Dsl.Worker (EP-71)
     WorkerProbe
       mkProbeTiming rejects period 0:           OK
       mkExecProbe rejects empty argv:            OK
       execProbe yields default timing:           OK
     renderer goldens
       renderWorkerDeployment exec probe:         OK
       renderWorkerDeployment minimal (unchanged): OK
     JSON round-trip and kind discrimination
       exec-probe worker round-trips:             OK
       tcp-probe worker round-trips:              OK
   All N tests passed
   ```

2. To (re)generate a new golden the first time, run with the accept flag, then inspect the
   diff before committing:

   ```bash
   cabal test nagare-dsl --test-options=--accept
   git diff -- cli/nagare-dsl/test/golden/
   ```

3. Render a probe-bearing worker offline and read the YAML (the headline demonstration):

   ```bash
   cabal run nagarectl -- worker deploy --dry-run \
     -f cluster/examples/queue-worker/nagare/Config.hs
   ```

   Expected (abridged) — the container now carries a `livenessProbe`:

   ```yaml
   spec:
     template:
       spec:
         containers:
         - name: queue-worker
           image: gcr.io/knative-samples/helloworld-go:latest
           command:
           - sh
           - -c
           - 'while true; do echo working; sleep 5; done'
           livenessProbe:
             exec:
               command:
               - /app/healthcheck
             initialDelaySeconds: 0
             periodSeconds: 10
             timeoutSeconds: 1
             failureThreshold: 3
   ```

4. Confirm a no-probe worker is unchanged (compare against today's golden):

   ```bash
   git stash   # or check out the pre-change golden
   cabal run nagarectl -- worker deploy --dry-run \
     -f cluster/examples/queue-worker/nagare/Config.hs > /tmp/after.yaml
   ```

   A no-probe worker's rendered Deployment must be byte-identical to the committed
   `cli/nagare-dsl/test/golden/worker-minimal.deployment.yaml`.


## Validation and Acceptance

Acceptance is phrased as observable behavior, verifiable entirely offline (the standard gate
for this repo, since `nagare-01` is frequently `TERMINATED`).

1. **Exec probe renders.** Given a `Worker` with `liveness = Just (unsafe (execProbe
   ["/app/healthcheck"]))`, `renderWorkerDeployment` produces a Deployment whose container
   has a `livenessProbe` with `exec.command: ["/app/healthcheck"]` and the four timing keys
   (`initialDelaySeconds: 0`, `periodSeconds: 10`, `timeoutSeconds: 1`,
   `failureThreshold: 3`). Asserted by the new golden
   `cli/nagare-dsl/test/golden/worker-exec-probe.deployment.yaml`.

2. **TCP probe renders.** Given `liveness = Just (mkTcpProbe port defaultProbeTiming)`, the
   container has `livenessProbe.tcpSocket.port: <port>`. Asserted by a golden or a `testCase`
   on the rendered bytes.

3. **Startup probe gating.** Given a probe with `asStartup = True`, the container has *both*
   a `livenessProbe` and a `startupProbe` with the same check; with `asStartup = False`,
   only `livenessProbe`. Asserted by a `testCase`.

4. **No-probe is byte-identical.** A `Worker` with `liveness = Nothing` renders no probe
   block; the `worker-minimal.deployment.yaml` golden does NOT change. This is the
   backward-compatibility guarantee that protects EP-1's embedding.

5. **Round-trip identity.** For exec-, TCP-, HTTP-, and no-probe workers,
   `decodeWorker (toStrict (encodeWorker w)) == Right w` (extends `roundTripTests`).

6. **Validation rejects bad input.** `mkProbeTiming` returns `Left` for `period = 0`,
   `failureThreshold = 0`, `initialDelay = -1`; `mkExecProbe []` and `mkExecProbe
   ["a\NULb"]` return `Left`.

Test command for all of the above:

```bash
cabal test nagare-dsl
```

Expected: `All N tests passed`, with the `WorkerProbe`, `renderer goldens`, and `JSON
round-trip` groups all `OK`.


## Idempotence and Recovery

All edits are deterministic source changes to the `nagare-dsl` library; re-running
`cabal build`/`cabal test` is safe and repeatable. Golden regeneration
(`--test-options=--accept`) is the only step that *writes* files; always inspect
`git diff -- cli/nagare-dsl/test/golden/` before committing so an accidental change to an
existing golden (which would mean a no-probe worker's bytes changed) is caught. If a golden
diff shows an unexpected change to `worker-minimal.deployment.yaml` or
`worker-rich.deployment.yaml`, the field was not added optionally/last — revert and re-check
M3's container ordering. Because the new field is `Maybe WorkerProbe` defaulting to
`Nothing` and decoded with `.:?`, the change is forward- and backward-compatible: old JSON
(no `liveness` key) decodes cleanly, and new JSON read by an old binary would simply ignore
an unknown key. No cluster state is touched until a real `worker deploy` (non-`--dry-run`) is
run, which is out of scope for this offline-verifiable plan.


## Interfaces and Dependencies

All new code lives in the existing `nagare-dsl` library; no new package dependencies. The
modules and signatures that must exist at the end of each milestone:

**After M1** — `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` exports:

```haskell
data ProbeTiming = ProbeTiming
  { initialDelay :: !Int, period :: !Int, timeout :: !Int
  , failureThreshold :: !Int, asStartup :: !Bool }

data WorkerProbe
  = ExecProbe ![Text] !ProbeTiming
  | TcpProbe !Port !ProbeTiming
  | HttpProbe !Text !(Maybe Port) !HealthScheme !ProbeTiming

mkProbeTiming     :: ProbeTiming -> Either Text ProbeTiming
defaultProbeTiming :: ProbeTiming
mkExecProbe       :: [Text] -> ProbeTiming -> Either Text WorkerProbe
mkTcpProbe        :: Port -> ProbeTiming -> WorkerProbe
mkHttpProbe       :: Text -> Maybe Port -> HealthScheme -> ProbeTiming -> Either Text WorkerProbe
execProbe         :: [Text] -> Either Text WorkerProbe
```

and the `Worker` record gains `liveness :: !(Maybe WorkerProbe)`. `Port` and `HealthScheme`
are imported from `Nagare.Dsl.Types`.

**After M2** — `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`'s `workerJSON` emits a `"liveness"`
key (a tagged object or `null`); `cli/nagare-dsl/src/Nagare/Dsl/Load.hs` has
`JsonWorkerProbe` (with `FromJSON`), `jwLiveness :: Maybe JsonWorkerProbe` on `JsonWorker`,
and `toWorkerProbe :: JsonWorkerProbe -> Either LoadError WorkerProbe` wired into `toWorker`.

**After M3** — `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` has
`probesField :: Maybe WorkerProbe -> [Pair]`, called from `containerValue`, and an extended
`keyCompare` rank table covering the probe keys.

**Reused, unchanged:** `Nagare.Dsl.Types.Port`/`mkPort`/`portInt`,
`Nagare.Dsl.Types.HealthScheme`, the timing-validation shape of
`Nagare.Dsl.Types.mkHealthCheck`, the app renderer's `probesField` (as the pattern to
mirror, in `Nagare.Dsl.Render`), and the `mkCommand` argv invariant. The test harness is
`Test.Tasty` / `Test.Tasty.Golden` / `Test.Tasty.HUnit` via
`cli/nagare-dsl/test/WorkerSpec.hs`.


## Revision Notes

- 2026-06-18 — MasterPlan validation pass. Corrected the `keyCompare` rank guidance in M3: the
  table is `[(Text, Int)]` (integer ranks, verified in source), so the placeholder fractional
  rank `5.5` is impossible; the plan now specifies concrete integer ranks
  (`livenessProbe = 6`, `startupProbe = 7`, `volumeMounts` bumped to `8`). No change to the
  type, encoders, renderer logic, or tests; this is a precision fix to an existing instruction.
