---
id: 95
slug: a-one-shot-job-workload-kind-in-nagare-dsl
title: "A one-shot job workload kind in nagare-dsl"
kind: exec-plan
created_at: 2026-07-14T19:28:25Z
intention: "intention_01kxh323kyegvvmkqscf59nahr"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
---

# A one-shot job workload kind in nagare-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`nagare-dsl` will gain a sixth workload kind, `Job`, for a single bounded execution.
A `Config.hs` can describe an image/build, command, runtime environment, resources,
deadline, retry count, cleanup TTL, and sized ephemeral scratch directory without
pretending the run is a scheduled `Task` or a continuously reconciled `Worker`.
Rendering produces a deterministic `batch/v1` Job plus its restricted ServiceAccount
and default-deny NetworkPolicy.

The result is visible at two levels. The Haskell config round-trips through the current
config-as-program loader and renders byte-for-byte golden YAML. On the live k3s cluster,
the rendered workload completes with `/scratch` writable, its root filesystem read-only,
no Kubernetes API token, and no egress unless a separate allow policy is applied. A
namespace quota admits at most two deadline-bounded Pods at once and reports excess work
as Job `FailedCreate` events that a caller can treat as backpressure.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-14 13:05 PDT) Added the public `Job` model, shared command type,
  smart validation, preset, and deterministic naming while preserving Worker re-exports.
- [x] (2026-07-14 13:05 PDT) Added Job JSON emission/loading, a Config.hs fixture,
  and round-trip/kind-discrimination validation; the full DSL suite passed 372 tests.
- [x] (2026-07-14 13:15 PDT) Added deterministic ServiceAccount, default-deny
  NetworkPolicy, and hardened Job renderers with four goldens; 381 tests passed
  on two consecutive runs and all pre-existing Task/Worker goldens remained unchanged.
- [x] (2026-07-14 13:43 PDT) Added the terminating-Pod ResourceQuota,
  idempotent bootstrap/status recipes, and a compiled agent-run example with
  quota, immutable-input, network, scratch, and cleanup guidance.
- [x] (2026-07-14 14:05 PDT) Passed all 381 DSL tests, the focused Nix DSL/example/shell
  checks, server-side dry-run, and live hardening, TTL cleanup, steady-state deny/narrow
  allow, and three-Job quota acceptance on local k3s. The aggregate flake check remains
  blocked by the unrelated credentialed `nagare-access` dependency described below.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The Kikan conformance file still does not exist, and its embedded draft
  predates three fields required by this ExecPlan: `parallelism: 1`, `completions: 1`,
  and the Pod-template `activeDeadlineSeconds` used by the Terminating quota.
  Evidence: `test -f .../nagare-prereqs/agent-run.job.yaml` exited 1; the embedded
  specimen contains only the Job-level deadline and omits parallelism/completions.

- Discovery: Moving Task's environment/resource rendering and key comparison into
  `Nagare.Dsl.Batch.Render` did not perturb its golden bytes.
  Evidence: both existing Task golden tests and all Worker golden tests passed as part
  of two consecutive 381-test runs after the extraction.

- Discovery: The plan's `nix fmt` command is unavailable on this aarch64-darwin
  checkout because the flake exports no formatter for that system.
  Evidence: `nix fmt` exited 1 with `does not provide attribute
  'formatter.aarch64-darwin'`; `flake.nix` also documents why the pinned Fourmolu is
  intentionally not used as a whole-tree formatting check.

- Discovery: Even `kubectl apply --dry-run=client` attempted to download the active
  GKE context's OpenAPI schema and could not refresh its non-interactive gcloud token.
  Evidence: validation failed while fetching `/openapi/v2` from `35.247.110.193` with
  `Reauthentication failed`; server-side and live acceptance therefore require renewed
  credentials or a usable local context.

- Discovery: The existing `k3d-nagare-local` context supplied a healthy k3s
  `v1.34.6+k3s1` acceptance target after starting its stopped Colima runtime. The
  checked-in Job golden passed server-side dry-run there without writing to the unrelated
  active GKE cluster. The original `sennari` context and stopped Colima state were restored
  after cleanup.

- Discovery: k3s's embedded kube-router controller enforces the default-deny policy after
  reconciliation, but it is not a fail-closed startup barrier for a newly allocated Pod IP.
  Evidence: an immediate BusyBox TCP probe reached `1.1.1.1:80` even though its policy had
  existed for minutes; iptables contained the policy chain but no rule for that short-lived
  Pod IP. Repeating the probe after a 15-second in-Pod delay produced `egress=blocked`.
  A separate additive policy restricted to `1.1.1.1/32` TCP/80 then produced
  `egress=target-allowed` and `egress=non-target-blocked` for `1.0.0.1:80`.

- Discovery: The aggregate `nix flake check` is blocked by an unrelated credentialed
  dependency in the `nagare-access` check. Its sandboxed Cabal build exited 128 while
  cloning from GitHub with `could not read Username`; Nix cancelled the other checks.
  The Job-relevant DSL, example, and shell checks were therefore also run individually.


## Decision Log

Record every decision made while working on the plan.

- Decision: Associate implementation work and commits with Intention
  `intention_01kxh323kyegvvmkqscf59nahr`, replacing the intention originally recorded
  when this plan was drafted.
  Rationale: The user explicitly selected this Intention ID for the implementation
  session, and the ExecPlan workflow requires the active intention to be reflected in
  frontmatter and commit trailers.
  Date: 2026-07-14

- Decision: Treat `cli/nagare-dsl/test/golden/job-agent-run.job.yaml` as the
  provider-side conformance source until Kikan creates its standalone fixture, and
  include every explicit field required by this ExecPlan even where the older embedded
  Kikan draft relied on Kubernetes defaults.
  Rationale: The current plan explicitly requires one completion, one-way parallelism,
  and matching Job/Pod deadlines; omitting them would weaken determinism and make the
  ResourceQuota fail to select the Pod. The Context section already designates the
  Nagare golden as authoritative while Kikan's fixture is absent.
  Date: 2026-07-14

- Decision: Share a context-parameterized deterministic key comparator rather than one
  global rank table between Task and Job renderers.
  Rationale: YAML key names such as `env`, `envFrom`, and `securityContext` need different
  relative positions in the established Task contract and the hardened Job contract.
  Sharing the comparison algorithm and batch value helpers preserves existing Task bytes
  while keeping both renderers deterministic.
  Date: 2026-07-14

- Decision: Add a first-class `Job`; do not extend `Task` with a missing schedule or use
  `kubectl create job --from=cronjob` as the public model.
  Rationale: A programmatic run has no scheduling policy or history limits. Making those
  fields nullable would weaken both workload types and keep one-shot runs second-class.
  Date: 2026-07-14

- Decision: Fix `restartPolicy` to `Never` and hardening defaults in the renderer rather
  than expose them as optional user choices.
  Rationale: This kind is the locked-down one-shot substrate. A caller may choose retry
  count and deadline, but cannot turn it into an indefinitely restarting or privileged
  general Pod.
  Date: 2026-07-14

- Decision: Reuse `Worker`'s validated `Command` through a common module and factor shared
  batch-render helpers out of `Task.Render` without changing existing Task bytes.
  Rationale: Copying argv validation and YAML ordering would create two subtly different
  APIs. Existing Task and Worker goldens protect the compatibility-preserving refactor.
  Date: 2026-07-14

- Decision: Render conservative request/limit defaults when `jobResources` is `Nothing`
  and reject a `Just Resources` value unless all four request/limit fields are present.
  Rationale: The public input remains consistent with other workload records while every
  Job emitted by this hardened kind has schedulable requests and explicit limits.
  Date: 2026-07-14

- Decision: Enforce the two-Pod bound with a `ResourceQuota` scoped to Kubernetes
  `Terminating` Pods.
  Rationale: `Terminating` selects Pods whose own `spec.activeDeadlineSeconds` is set;
  ResourceQuota cannot select labels. The Job controller copies the Pod template but does
  not copy the Job-level deadline into that template, so the renderer must put the same
  validated deadline at both Job and Pod level. Exceeding quota rejects Pod creation; the
  Job remains and reports `FailedCreate`, so the future scheduler must observe Job
  events/status and retry rather than assume a third Pending Pod exists.
  Date: 2026-07-14

- Decision: Use the existing k3s network-policy controller and prove it with a live probe.
  Rationale: `nixos/hosts/nagare-01/k3s.nix` does not set
  `--disable-network-policy`; k3s therefore runs its embedded kube-router policy
  controller. Installing another controller would add conflict without adding isolation.
  Date: 2026-07-14

- Decision: Document the kube-router convergence window as a production isolation gap
  instead of describing the base NetworkPolicy as fail-closed from process start.
  Rationale: The delayed deny and narrow allow probes prove steady-state rule enforcement,
  while the immediate successful connection proves that this manifest/controller pair
  cannot safely launch untrusted code that sends traffic before the Pod-specific rule is
  programmed. Hiding the distinction would overstate the delivered security property;
  the target CNI or a separate admission-time mechanism must close it before production.
  Date: 2026-07-14

- Decision: Make the Attic client ConfigMap an optional, typed Job input.
  Rationale: EP-3 of the parent MasterPlan owns `nagare-nix-cache-client`; mounting it at
  `/etc/nix/nix.conf` lets Nix-capable Jobs substitute without coupling every Job to the
  cache or duplicating configuration in environment variables.
  Date: 2026-07-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The repository now has a first-class, validated one-shot `Job` model with config-as-program
round-tripping and deterministic rendering of a tokenless ServiceAccount, default-deny
NetworkPolicy, and hardened `batch/v1` Job. The renderer fixes parallelism/completions at
one, emits explicit resources and sized scratch, duplicates the validated deadline at Job
and Pod level, and supports an opt-in Nix client ConfigMap without granting network access.
All 381 DSL tests passed, including the four new goldens and every pre-existing Task and
Worker golden. The focused Nix DSL, example-compilation, and shell checks also passed.

The cluster milestone installed an idempotent two-slot `Terminating` ResourceQuota and
proved its exact backpressure contract: two default Pods consumed the full pool, the third
Job had repeated `FailedCreate/exceeded quota` events and no Pod, and deleting one admitted
Job caused the third Pod to be created. A separate hardened probe logged `uid=65532`,
`root=readonly`, `scratch=writable`, and `api-token=absent`, completed successfully, and was
deleted by its TTL; its separately applied ServiceAccount and NetworkPolicy were then
removed explicitly. The checked-in Job bundle also passed Kubernetes server-side dry-run.

Steady-state network enforcement was demonstrated with a denied outbound probe and an
additive `/32` TCP/80 policy that allowed its target while continuing to deny another IP.
The immediate-start probe exposed a residual security boundary: this kube-router dataplane
programs new Pod-IP rules asynchronously, so the base manifest is not a fail-closed startup
barrier. The example documentation now says so plainly. Production use with untrusted agent
code still needs a target CNI or admission-time isolation mechanism that proves enforcement
before the workload process starts.

Two integrations remain outside this child's completion boundary. Kikan has not created
the standalone conformance fixture, so its consumer copy still needs the corrected Pod
deadline plus explicit parallelism/completions before byte comparison. EP-3 has not yet
provided `nagare-nix-cache-client`, so the live cache substitution check remains the parent
MasterPlan's soft integration acceptance. The aggregate `nix flake check` is also not green
because the unrelated `nagare-access` derivation cannot clone a credentialed GitHub
dependency in its sandbox; all checks Nix cancelled as a result were rerun individually.


## Context and Orientation

Nagare currently models five workload kinds. Request-driven apps render Knative Services;
`Nagare.Dsl.Worker` renders a Deployment; `Nagare.Dsl.Task` renders a CronJob;
databases render StatefulSets; and brokers render Redpanda resources. A Task can be run
once through later CLI machinery, but its public type still requires a cron schedule and
cron policies. There is no public type for a one-shot, parameterized run.

The closest source is `cli/nagare-dsl/src/Nagare/Dsl/Task.hs`. Its `Task` record has a
validated name and namespace, image/app inheritance, command and args, scoped environment,
optional resources, optional active deadline, retry policy, and scheduling fields.
`cli/nagare-dsl/src/Nagare/Dsl/Task/Render.hs` exposes `taskJobSpecValue`, which proves
the basic Kubernetes shape: `backoffLimit`, optional `activeDeadlineSeconds`, and a Pod
template. `cli/nagare-dsl/src/Nagare/Dsl/Worker.hs` supplies the validated optional
`Command` and the `ImageRef` plus `BuildSpec` pattern. Common validated values such as
`ServiceName`, `Namespace`, `Quantity`, `Resources`, `EnvName`, `ScopedEnvVar`,
`EnvLiteral`, and `EnvSecretRef` live in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs`.

Serialization and config-as-program loading are centralized in
`cli/nagare-dsl/src/Nagare/Dsl/Config.hs` and
`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`. Public modules and test modules are enumerated
in `cli/nagare-dsl/nagare-dsl.cabal`. `cli/nagare-dsl/test/WorkerSpec.hs` is the
closest pattern for constructor tests, renderer goldens, kind discrimination, and a
`Config.hs` fixture. Existing examples under `cluster/examples/` are compiled by the
root flake check.

The live host is a single `e2-standard-2` node configured by
`nixos/hosts/nagare-01/k3s.nix`; it leaves k3s's embedded network-policy controller
enabled. `infra/pulumi/src/components/NagarePerimeter.ts` owns the machine type if the
operator later chooses vertical resizing. In this plan, “Terminating Pod” uses the
Kubernetes ResourceQuota scope name: it means a Pod whose own
`spec.activeDeadlineSeconds` is present, not a Pod already shutting down and not merely a
Pod owned by a Job whose top-level deadline is present.

The originating requirement is
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`.
It embeds the representative `agent-run.job.yaml` bytes, but the intended standalone
Kikan conformance file does not yet exist as of 2026-07-14. The Nagare golden created
here is therefore the provider-side source until Kikan copies it; once the Kikan fixture
exists, CI or review must compare the two byte-for-byte. Repository input remains the
provisional C16 coordinate `repo_<id>@<full-40-character-sha>` and is merely a runtime
environment value to this Job API.


## Plan of Work

### Milestone 1: define and round-trip the public Job model

Move `Command`, `mkCommand`, and `commandArgvList` from
`Nagare.Dsl.Worker` into a new `cli/nagare-dsl/src/Nagare/Dsl/Command.hs`. Re-export
them from `Nagare.Dsl.Worker` so existing imports and examples remain source-compatible;
add the new module to `nagare-dsl.cabal`.

Add `cli/nagare-dsl/src/Nagare/Dsl/Job.hs` with these public fields:

```haskell
data Job = Job
  { jobName :: ServiceName
  , jobNamespace :: Namespace
  , jobImage :: ImageRef
  , jobBuild :: BuildSpec
  , jobCommand :: Maybe Command
  , jobEnv :: Map EnvName ScopedEnvVar
  , jobResources :: Maybe Resources
  , jobBackoffLimit :: Int
  , jobActiveDeadlineSeconds :: Maybe Int
  , jobTtlSecondsAfterFinished :: Maybe Int
  , jobScratchSize :: Quantity
  , jobNixConfigMap :: Maybe ConfigMapName
  }
```

Define `ConfigMapName` as a hidden-constructor DNS-subdomain-safe newtype with
`mkConfigMapName` and `configMapNameText`. A DNS label implementation that delegates to
`mkServiceName` is acceptable for v1 and matches the intended
`nagare-nix-cache-client` name. Define `mkJob :: Job -> Either Text Job`; it rejects a
negative backoff, non-positive deadline or TTL, and any explicit `Resources` missing CPU
request, memory request, CPU limit, or memory limit. `jobActiveDeadlineSeconds = Nothing`
is valid for the general API, but the documentation must say such a Pod is outside the
Terminating quota and is not acceptable for agent execution. `jobScratchSize` arrives
through `mkQuantity`, and `Command` through `mkCommand`.

Add `oneShotJob :: Text -> Text -> Either String Job`, mirroring `webWorker`. It uses
namespace `personal`, `PrebuiltImage latest`, no command or environment, `Nothing`
resources (which the renderer expands to 250m/512Mi requests and 1 CPU/1Gi limits),
backoff 0, a 1800-second deadline, a 3600-second TTL, 2Gi scratch, and no cache ConfigMap.
Define `jobResourceName` so `agent-run` becomes `nagare-job-agent-run`.

Extend `Nagare.Dsl.Config` with `emitJob` and `encodeJob`, using top-level kind `Job`.
Extend `Nagare.Dsl.Load` with `loadJob` and `decodeJob`; rebuild every constrained value
with its smart constructor and return `UnexpectedKind` consistently. Add
`cli/nagare-dsl/test/JobSpec.hs`, register it in the Cabal test stanza and test main,
and add a config fixture that uses `emitJob`.

Milestone 1 is complete when constructor boundaries, JSON round-trip, incorrect-kind
decoding, and `Config.hs` loading pass while all pre-existing Worker tests remain unchanged.

### Milestone 2: render a deterministic, hardened resource bundle

Add `cli/nagare-dsl/src/Nagare/Dsl/Job/Render.hs`. Extract only genuinely shared batch
helpers and the deterministic key comparator from `Task.Render` into an internal
`Nagare.Dsl.Batch.Render` module; keep `taskJobSpecValue`, `renderTask`, and all existing
Task bytes unchanged. The Job renderer's public interface is specified below.

Render resources in apply order: ServiceAccount, NetworkPolicy, then Job. All carry
`nagare.dev/managed-by: nagarectl` and `nagare.dev/job: <logical-name>` where the
resource supports labels. The ServiceAccount is `nagare-job-<name>` and has
`automountServiceAccountToken: false`. The NetworkPolicy selects the Job label and has
`policyTypes: [Ingress, Egress]` with empty ingress and egress lists. It is a default
deny; any future forge, DNS, cache, or sink access is granted by a separate additive
policy owned by the caller's platform feature.

The Job has `parallelism: 1`, `completions: 1`, the chosen backoff, optional active
deadline, optional finished TTL, and a Pod template with `restartPolicy: Never`, the
restricted ServiceAccount, and `automountServiceAccountToken: false`. When a deadline is
present, render its value both as Job `spec.activeDeadlineSeconds` and Pod-template
`spec.activeDeadlineSeconds`; this makes the Job controller enforce a whole-Job wall clock
and makes its Pods match the Terminating ResourceQuota. Pod security is `runAsNonRoot:
true`, `runAsUser: 65532`, and `seccompProfile.type: RuntimeDefault`.
Container security is `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, and `capabilities.drop: [ALL]`. The renderer always
emits resources; `Nothing` becomes the preset defaults, while an explicit validated
value is emitted verbatim.

Add an `emptyDir` named `scratch`, with `sizeLimit` from `jobScratchSize`, mounted
read-write at `/scratch`. Emit Runtime-scoped inline environment in sorted order and the
standard optional `envFrom` pair `nagare-env-<name>-runtime` and
`nagare-secret-<name>-runtime`. Resolve the image tag with `BuildSpec` exactly as Worker
does. When `jobNixConfigMap` is present, add label
`nagare.dev/nix-cache-client: "true"`, a read-only ConfigMap volume selecting key
`nix.conf`, and mount it with `subPath` at `/etc/nix/nix.conf`. EP-3 owns the additive
NetworkPolicy that grants only these opted-in Pods DNS and cache-service egress. The label
is absent when the field is absent, so merely being a Nagare Job never grants network.

Create goldens under `cli/nagare-dsl/test/golden/` for the representative Job, its
ServiceAccount, its NetworkPolicy, and the complete ordered bundle. The Job-only file is
`job-agent-run.job.yaml` and must reproduce the manifest embedded in the originating
Kikan plan with one correctness amendment: add `activeDeadlineSeconds: 1800` to the Pod
template spec as well as the Job spec. The embedded draft omitted the Pod field, so its
proposed Terminating quota would not select these Pods. Preserve its other fields: name
`nagare-job-agent-run`, namespace `personal`, TTL 3600, backoff 0, run user 65532, the
standard env pair, requests 250m/512Mi, limits 1/1Gi, and 2Gi scratch. Use the active
registry prefix as an input in real deployments; do not introduce a new hard-coded
`tan-nb-exp` default. When Kikan creates
`docs/architecture/evolution/conformance/nagare-prereqs/agent-run.job.yaml`, compare it
with this corrected golden using `cmp`; update Kikan's embedded specimen/fixture to include
the Pod deadline before claiming byte equality, and resolve any other difference explicitly
in both plans.

Milestone 2 is complete when all new goldens are stable across two test runs, every old
Task/Worker golden is byte-identical, and a decoded config renders the Job-only golden.

### Milestone 3: install the concurrency policy and prove behavior live

Add `cluster/bootstrap/job-runs/resourcequota.yaml` and a neighboring `README.md`.
The ResourceQuota is named `nagare-terminating-jobs`, lives in `personal`, has
`scopes: [Terminating]`, and sets `pods: "2"`. Also cap aggregate requests and limits at
values that permit exactly two default agent Jobs while retaining headroom for the
control plane and Victoria stack; start with requests 500m/1Gi and limits 2 CPU/2Gi.
Do not claim that the quota selects `nagare.dev/job`: ResourceQuota has no label selector,
so all deadline-bounded Pods in `personal` share this pool. Add idempotent
`job-runs-bootstrap` and status recipes to the root `justfile`.

Add `cluster/examples/agent-run-job/nagare/Config.hs` plus a README explaining unique
per-run names, full-SHA `REPO_REF`, the required deadline, quota backpressure, additive
egress policy, immutable images in production, scratch lifetime, and cleanup. The example
may use a harmless prebuilt probe image, but the live hardening test needs an image that
runs successfully as UID 65532 with a read-only root filesystem.

Apply the bootstrap quota and two long-running probe Jobs with distinct names. Applying a
third Job object succeeds, but its controller must fail to create a Pod and record
`FailedCreate` with `exceeded quota`; there must be only two admitted Terminating Pods.
After deleting one admitted Job, observe the controller create the third Pod. This is the
contract future Shikigami code consumes as backpressure.

Run separate probes that show `/etc` cannot be written, `/scratch` can be written, the
service-account token directory is absent, and an outbound connection fails under the
default-deny policy but succeeds after a narrowly scoped additive allow policy is applied.
Wait for successful completion and confirm the TTL controller removes the Job. Clean up
the per-Job ServiceAccount and NetworkPolicy explicitly because Job TTL cannot own
objects that were applied before it had a UID.

Milestone 3 is complete when the local suite passes and all live observations above are
recorded without weakening the host or applying a blanket egress allow.


## Concrete Steps

Run development commands from `/Users/shinzui/Keikaku/bokuno/nagare`:

```bash
nix develop
cabal test nagare-dsl --test-show-details=direct
```

The test output should include groups for Job constructor validation, JSON round-trip,
config-as-program loading, and four renderer goldens, followed by `All tests passed`.
Run the broad compatibility checks:

```bash
nix fmt
nix flake check
git diff --check
```

Render the fixture twice through the test harness and verify that the checked-in golden
does not change. If the Kikan conformance fixture now exists, resolve the project from
`mori://shinzui/kikan`, then compare the repository-local paths in the two projects.
For the currently registered checkout, run:

```bash
kikan_root="$(mori path mori://shinzui/kikan)"
cmp cli/nagare-dsl/test/golden/job-agent-run.job.yaml \
  "$kikan_root/docs/architecture/evolution/conformance/nagare-prereqs/agent-run.job.yaml"
```

Expected output is empty with exit status zero. A missing Kikan file is not a reason to
invent it in this repository; record the outstanding provider/consumer sync in the
parent MasterPlan.

Before a live write, inspect the active context:

```bash
just context-show
kubectl config current-context
just job-runs-bootstrap
kubectl -n personal describe resourcequota nagare-terminating-jobs
```

Apply the bundle golden or fixture-generated bundle, then inspect security and completion:

```bash
kubectl -n personal apply -f cli/nagare-dsl/test/golden/job-agent-run.bundle.yaml
kubectl -n personal get job,pod -l nagare.dev/job=agent-run
kubectl -n personal logs job/nagare-job-agent-run
kubectl -n personal get job nagare-job-agent-run -o jsonpath='{.status.succeeded}'
```

Expected final status is `1`, and the probe log contains explicit success for writable
scratch and absence of a service-account token. It must treat a successful write under
`/etc` or successful outbound probe under deny policy as a test failure.

For quota behavior, apply three copies with distinct Job and label names and commands
that sleep long enough to overlap. Inspect:

```bash
kubectl -n personal get pods --field-selector=status.phase=Running
kubectl -n personal describe job nagare-job-quota-probe-3
```

Exactly two probe Pods are admitted. The third Job shows a `FailedCreate` event containing
`exceeded quota: nagare-terminating-jobs`; it does not have a third Pending Pod. Delete
one admitted Job and observe the third create and run. Remove all probes and restore the
checked-in quota after any temporary test edits.


## Validation and Acceptance

Acceptance requires these behaviors:

* `oneShotJob`, explicit record construction, `encodeJob`/`decodeJob`, and `loadJob` all
  produce the same validated value. Invalid names, commands, quantities, numeric bounds,
  and incomplete explicit resources return `Left` with a precise field error.
* `renderJobManifest` is deterministic and equals
  `cli/nagare-dsl/test/golden/job-agent-run.job.yaml`. Existing Task and Worker goldens
  do not change as a side effect of helper extraction.
* The Job YAML is valid under `kubectl apply --dry-run=server` and includes every fixed
  hardening field, explicit requests and limits, 2Gi scratch, the two optional envFrom
  entries, matching Job-level and Pod-level active deadlines, and no mutable privilege
  toggle.
* On k3s, the probe runs as UID 65532; write under `/etc` fails; write under `/scratch`
  succeeds; `/var/run/secrets/kubernetes.io/serviceaccount` is absent; and the Job
  reaches `Complete` before its deadline and disappears after its TTL.
* With the default-deny NetworkPolicy present, an outbound probe fails. A narrow additive
  policy allows only its named destination, proving the controller enforces policy.
* Each admitted Pod reports its own `.spec.activeDeadlineSeconds`. With two
  deadline-bounded default Jobs active, a third Job reports `FailedCreate/exceeded quota`
  and has no Pod. Releasing one slot lets it create a Pod.
* Mounting EP-3's `nagare-nix-cache-client` ConfigMap places its exact `nix.conf` at
  `/etc/nix/nix.conf` and adds `nagare.dev/nix-cache-client: "true"`; omitting the field
  creates no cache label, volume, mount, or egress grant.

The first six behaviors are required for this child plan to complete. The final
cache-mount live check is a soft integration acceptance and can be recorded in the
parent MasterPlan if EP-3 completes later.


## Idempotence and Recovery

Golden and unit tests are read-only and repeatable. The bootstrap recipe uses declarative
`kubectl apply`, so rerunning it converges the same ResourceQuota. ResourceQuota changes
take effect immediately; lowering it does not evict existing Pods, but blocks new
admissions. Inspect current usage before any reduction and restore the checked-in
manifest if a test value is wrong.

Job manifests are not generally re-runnable under the same name after completion because
important Job template fields are immutable. Use a unique run name or delete the old
Job before applying a changed template. Deleting a Job removes its Pods and ephemeral
scratch permanently. It does not remove the separately applied ServiceAccount or
NetworkPolicy; clean those by exact name after the Job is gone.

If network policy unexpectedly blocks cluster-critical traffic, delete only the
per-Job policy and diagnose the selector/controller. Never disable the host-wide k3s
policy controller as a workaround. If the quota affects an unrelated Terminating Pod,
remove or raise the quota temporarily, document that shared-pool collision, and revisit
namespace/priority-class isolation before restoring enforcement.


## Interfaces and Dependencies

No new Haskell package dependency is required. Use existing `aeson`, `yaml`, `lens`,
`text`, `containers`, Tasty, and golden-test machinery. The Kubernetes behavior is
`batch/v1` Job, `v1` ServiceAccount, `networking.k8s.io/v1` NetworkPolicy, and `v1`
ResourceQuota. The registered `codedownio/kubernetes-api` source confirms that Job
supports optional active deadline, backoff, and finished TTL, and that NetworkPolicy
empty egress plus explicit `policyTypes` isolates matching Pods.

The public Haskell interface at completion is:

```haskell
module Nagare.Dsl.Command
  ( Command, mkCommand, commandArgvList )

module Nagare.Dsl.Job
  ( ConfigMapName, mkConfigMapName, configMapNameText
  , Job(..), mkJob, oneShotJob, jobResourceName
  )

emitJob :: Job -> IO ()
encodeJob :: Job -> LBS.ByteString
loadJob :: FilePath -> IO (Either LoadError Job)
decodeJob :: ByteString -> Either LoadError Job

renderJob :: Job -> Text -> [ByteString]
renderJobServiceAccount :: Job -> ByteString
renderJobNetworkPolicy :: Job -> ByteString
renderJobManifest :: Job -> Text -> ByteString
```

The `Text` argument is the deploy-time image tag, matching `renderWorker`; `BuildSpec`
decides whether it or a prebuilt tag is used. `renderJob` returns ServiceAccount,
NetworkPolicy, then Job in apply order. EP-3's only shared interface is a ConfigMap named
`nagare-nix-cache-client` with a `nix.conf` key and the opt-in Pod label
`nagare.dev/nix-cache-client: "true"`. Kikan consumes the Job YAML contract but is not a
Nagare build dependency.


## Revision Notes

2026-07-14: Replaced every indented command and Haskell interface excerpt with an
explicitly language-tagged fenced code block, as required by the ExecPlan formatting
specification. No workload design or acceptance behavior changed.

2026-08-23: Replaced the informal cross-repository Kikan plan reference and fixed checkout
path with canonical `mori://` resolution as part of the Nagare plan-registry update. Scope,
completion state, and acceptance evidence are unchanged.
