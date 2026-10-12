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

Full plan before trimming: [74-worker-health-and-liveness-probes.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/74-worker-health-and-liveness-probes.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
- [x] M4 (2026-06-18) — `docs/user/workers.md` field table gained a `liveness` row plus a
      "Liveness probes for hung workers" subsection with an `execProbe` snippet; the
      `cluster/examples/queue-worker` example now refreshes a `/tmp/heartbeat` file and declares an
      exec liveness probe checking it (README updated). Verified end-to-end:
      `nagarectl worker deploy --dry-run -f cluster/examples/queue-worker/nagare/Config.hs` renders
      a `livenessProbe.exec.command`, and `cabal build all` (the `examples-compile` gate) is clean.

## Surprises & Discoveries

- 2026-06-18 — **`ProbeTiming`'s field labels collide with the app `HealthCheck`'s.** Both define
  `initialDelay`/`period`/`timeout`/`failureThreshold`/`asStartup`. With `DuplicateRecordFields`
  enabled (library + test common stanza) this is *allowed*, but a bare record **update** like
  `defaultProbeTiming {period = 0}` in a module that also imports `Nagare.Dsl.Types` (so
  `HealthCheck`'s `period` is in scope) is `-Wambiguous-fields`. Resolved by constructing full
  `ProbeTiming { ... }` literals in the tests (record *construction* is constructor-directed and
  unambiguous) and by using `t ^. #field` generic-lens accessors in the encoder/renderer. No
  behavioral impact; just a constructor/accessor style constraint for callers.

- 2026-06-18 — **The test-suite target is `nagare-dsl-test`, not `nagare-dsl`** (shared with EP-1):
  the plan's Concrete Steps say `cabal test nagare-dsl`, which errors `Cabal-7043` (resolves to the
  library). Use `cabal test nagare-dsl-test`.

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

**Outcome (2026-06-18 — EP-3 complete).** All four milestones landed and the full `nagare-dsl`
suite is green (`cabal test nagare-dsl-test`, 319 tests). A `Worker` now carries an optional
`liveness :: Maybe WorkerProbe` (exec / TCP / HTTP), validated by smart constructors, round-tripped
through JSON, and rendered into the `apps/v1` Deployment as a `livenessProbe` (plus a `startupProbe`
when `asStartup`). The headline behavior is demonstrated offline:
`nagarectl worker deploy --dry-run` on the queue-worker example prints a `livenessProbe.exec.command`.

**The backward-compatibility guarantee held exactly.** Because the field is `Maybe WorkerProbe`
defaulting to `Nothing`, added last, decoded with `.:?`, and rendered as `[]` when absent: the
existing `worker-minimal`/`worker-rich` goldens did **not** regenerate, and an explicit test asserts
a no-probe worker emits no `livenessProbe`. This is what protects EP-1's `Application` embedding —
the aggregate's worker round-trip and runghc load tests passed untouched (the only visible change is
embedded workers now emit `"liveness":null`, which decodes back to `Nothing`).

**EP-1 integration realized for free.** As predicted, EP-1 embeds `Worker` as-is, so the new field
flowed through the aggregate's encoder/decoder (which reuse `workerJSON`/`toWorker`) with **zero**
changes to EP-1's code — only EP-1's fixtures saw the new `"liveness":null` byte, and they still
round-trip. EP-2 will render aggregated workers via the same `renderWorker` this plan extended, so an
aggregated worker emits its probe with no extra wiring.

**Design choices that held.** The dedicated `WorkerProbe` sum (not reusing the HTTP-only app
`HealthCheck`) made exec the natural primary case and kept each branch carrying exactly Kubernetes'
required fields; the shared `ProbeTiming` avoided duplicating the range validation.

**Minor notes.** `mkTcpProbe :: Port -> ProbeTiming -> WorkerProbe` (non-`Either`, per the pinned
signature) does not re-validate its timing at construction; the loader's `toWorkerProbe` re-runs
`mkProbeTiming` for TCP too, so a tampered JSON is still caught. Building a `ProbeTiming` with a
non-default field in a test/config needs a full record literal (or qualified update) under
`DuplicateRecordFields`, since `period`/`asStartup` collide with the app `HealthCheck`'s fields.

