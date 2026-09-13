---
id: 125
slug: rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster
title: "Rehearse target platform releases in a side-effect-fenced candidate cluster"
kind: exec-plan
created_at: 2026-09-13T22:09:04Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:04Z
---

# Rehearse target platform releases in a side-effect-fenced candidate cluster

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator can boot the candidate's target NixOS, k3s, and Nagare platform release while
the old machine still serves production, then run deterministic health and compatibility
checks against that candidate. Rehearsal uses an explicit candidate kubeconfig and a
side-effect fence: no public route, no scheduled jobs, no application workers, read-only
cloud credentials, and no production certificate issuance. Nagare refuses cutover if it
cannot attest that the fence held throughout the rehearsal.

`nagarectl platform replacement rehearse <transaction-id> --json` produces a signed-by-digest
evidence bundle containing host activation, cluster component versions, readiness, policy
audit, state restore checks, application probe results, durations, and log locations. A
failed rehearsal leaves the live host untouched and can be repeated after fixing the target
release or configuration.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add candidate-targeted host activation and kubeconfig plumbing with no ambient-target
      fallback.
- [ ] Add a declarative rehearsal overlay that suspends side-effecting workloads and uses
      local TLS.
- [ ] Add fence attestation and fail-closed validation before any application probe runs.
- [ ] Add platform, restored-state, and opt-in application probes plus evidence capture.
- [ ] Add offline/fake-target tests and a live candidate rehearsal test.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: Context selection does not currently select a kubeconfig; multi-cluster
  guidance pairs the context with ambient `KUBECONFIG` manually.
  Evidence: `docs/guides/running-multiple-clusters.md` documents this pairing and
  `scripts/live-test.sh` retrieves and rewrites a k3s kubeconfig over IAP.
- Observation: Applying production objects unchanged is not a safe rehearsal because Nagare
  manages CronJobs, backup uploads, minimum-scale services, workers, and migration hooks.
  Evidence: task and database modules render CronJobs, and deployed Knative Services may set
  minimum scale above zero.
- Observation: Production certificate bootstrap requires DNS mutation from the node service
  account.
  Evidence: `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` uses DNS-01 and the
  active node account has zone administration permissions.


## Decision Log

Record every decision made while working on the plan.

- Decision: Candidate selection is a typed target passed to every host and Kubernetes
  operation; ambient `KUBECONFIG`, default instance names, and active context outputs are
  forbidden in replacement code.
  Rationale: The most dangerous rehearsal failure is accidentally applying target resources
  to production.
  Date: 2026-09-13
- Decision: Rehearsal transforms the rendered production objects into a fail-closed overlay:
  CronJobs suspended, workers and StatefulSets without seeded state at zero, and Knative
  user services at zero except one explicitly invoked probe revision.
  Rationale: A fresh cluster still needs realistic manifests, but merely hiding its address
  does not prevent outbound email, queues, webhooks, migrations, or backup writes.
  Date: 2026-09-13
- Decision: Use a local rehearsal issuer and copied/nonrenewing test certificate material,
  not the production ACME issuer.
  Rationale: Platform TLS wiring can be tested without mutating production DNS or consuming
  certificate authority capacity. ExecPlan 127 arms production credentials before downtime
  and reruns the affected checks.
  Date: 2026-09-13
- Decision: Application execution is opt-in and must declare allowed destinations and probe
  commands; an undeclared workload is inspected but not started.
  Rationale: Nagare cannot infer whether arbitrary application startup has external side
  effects.
  Date: 2026-09-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Nagare builds its host configuration from `nixos/hosts/nagare-01/` and switches it with
`scripts/host-switch.sh`, whose access guard reverts a bad activation. Cluster bootstrap
assets live under `cluster/bootstrap/`, and `just cluster-bootstrap` installs k3s platform
components such as Knative, Kourier, cert-manager, authentication services, and Nagare
controllers. `Nagare.Ops.Doctor`, `Nagare.Ops.Status`, and `Nagare.Ops.Probe` contain current
readiness logic. `scripts/live-test.sh` shows how to fetch `/etc/rancher/k3s/k3s.yaml` over
IAP and tunnel to the API server.

Applications, tasks, databases, brokers, and retained volumes are rendered by modules under
`cli/nagarectl/src/Nagare/`. Rehearsal must not edit those canonical renderers to make all
deployments permanently inert. Instead, add a typed post-render transformation and audit
under a new `Nagare.Platform.Rehearsal` module. The transformation labels every object with
the transaction ID and role, suspends or scales workloads, replaces production issuer
references, and installs namespace network policies before selected pods can start.

A fence attestation is evidence that infrastructure, identity, and workload controls all
match the transaction: candidate lacks `nagare-active`, its reserved-IP field is absent,
its service account is the candidate reader account, its kubeconfig names the candidate
server and CA, no unsuspended CronJob exists, no unapproved workload has nonzero desired
replicas/minimum scale, and default-deny policies precede probe execution. It is not a claim
that arbitrary hostile code is sandboxed perfectly; untrusted or undeclared workloads stay
stopped.

Relevant local decisions are [ADR 0004](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md),
[ADR 0005](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md),
[ADR 0006](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md),
[ADR 0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md),
[ADR 0011](../adr/0011-host-activation-is-guarded-and-self-reverting.md), and
[ADR 0018](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md). The replacement ADR created by
ExecPlan 122 defines the new topology. Mori searches found no cross-repository ADR governing
candidate-cluster rehearsal.


## Plan of Work

### Milestone 1: Explicit candidate targeting

Introduce `CandidateTarget` and `CandidateKubeconfig` in
`cli/nagarectl/src/Nagare/Platform/Rehearsal.hs`. Extend host-switch and bootstrap wrappers to
require an explicit instance, zone, project, host-flake path, kubeconfig path, and expected
cluster identity. Retrieve the candidate kubeconfig through IAP into the transaction
directory, rewrite only its server endpoint to a transaction-owned tunnel, and verify its CA
and node identity before use. Add a process environment builder that removes ambient
`KUBECONFIG` and sets the explicit path. This milestone ends when fake-process tests prove
every `kubectl`, `helm`, or bootstrap invocation carries the candidate target.

### Milestone 2: Host and platform bootstrap under a closed fence

Switch the candidate to the target host flake using the existing self-reverting activation
guard and confirm a new IAP session before accepting it. Install target k3s and platform
components from the immutable target payload. Add a rehearsal bootstrap profile under
`cluster/rehearsal/` that uses the local issuer, omits production DNS credentials, installs
network policies first, and records exact NixOS, kernel, k3s, Kubernetes, Knative,
cert-manager, Kourier, and Nagare component versions. Host activation and cluster bootstrap
must be separately resumable. This milestone ends when a fresh candidate becomes healthy
without any public route or production DNS mutation.

### Milestone 3: Workload transformation and fence attestation

Implement pure transformations and audits in `Nagare.Platform.Rehearsal`. Suspend all
`batch/v1 CronJob` resources; set ordinary Deployment/StatefulSet replicas to zero unless
their resource ID is in the state plan's platform allowlist; force user Knative min/max
scale to zero; omit migration and pre-deploy hook Jobs; and attach transaction and role
labels. Create default-deny ingress/egress policies before applying transformed user objects.
Allow DNS and declared in-cluster database endpoints, and generate per-probe external egress
exceptions only from explicit configuration. Reject unknown workload kinds with pod
templates instead of passing them through. Query both desired resources and running pods to
produce `FenceAttestation`; any violation stops rehearsal.

### Milestone 4: Rehearsal probes and evidence

Run `nagarectl doctor` and status checks against the candidate, validate storage and database
restores supplied by ExecPlan 126, and exercise internal ingress over an IAP SSH port forward
with production Host headers. For an application opted into rehearsal, create a one-shot
probe revision with declared network destinations, run its health/compatibility command,
capture logs, and scale it back to zero. Re-run fence attestation after every probe. Write a
canonical `rehearsal-report.json` including input digests, start/end timestamps, monotonic
durations, component versions, checks, logs, and final fence state, then attach its digest to
the transaction.

### Milestone 5: Failure injection and live proof

Add fake-runner tests for wrong kubeconfig, active instance mismatch, unsuspended CronJob,
unknown pod-bearing kind, forbidden egress, failed host activation, component timeout, and
probe cleanup. On the disposable candidate from ExecPlan 124, rehearse once successfully and
once with a deliberately broken target component. Confirm production health during both,
that the broken run stays non-ready, and that retry after correction reuses the candidate
without leaving probe pods or policy exceptions.


## Concrete Steps

From the repository root, run:

    nix develop -c cabal test nagarectl-test --test-show-details=direct
    nix flake check --print-build-logs

Focused output must include candidate-target and fence tests, for example:

    PlatformRehearsal
      rejects a kubeconfig for the active cluster: OK
      suspends every CronJob before apply: OK
      rejects an unknown pod-bearing resource: OK
      invalidates a report after a fence violation: OK

Against the disposable replacement transaction:

    nagarectl platform replacement rehearse <transaction-id> --json \
      > <transaction-dir>/rehearsal-command.json
    nagarectl platform replacement status <transaction-id> --json

Expected result excerpts are `"candidateFence":"passed"`, explicit candidate instance and
cluster IDs, `"publicIngress":false`, and a successful component-version matrix. During the
run, independently probe the current public domain and require uninterrupted success.

Inspect the candidate explicitly:

    KUBECONFIG=<candidate-kubeconfig> kubectl get cronjobs -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.suspend}{"\n"}{end}'
    KUBECONFIG=<candidate-kubeconfig> kubectl get pods -A \
      -l nagare.dev/replacement-role=candidate

Every candidate CronJob reports `true`; only allowlisted platform/state/probe pods are
running. Remove the probe and repeat the pod query to prove cleanup.


## Validation and Acceptance

Acceptance requires:

* Every external command is bound to the transaction's candidate instance or kubeconfig;
  tests fail if either value is omitted or equals the active identity.
* The target NixOS activation survives the host access guard and a new IAP session, and the
  candidate reports the exact target k3s and component versions.
* No candidate address receives direct public HTTP/HTTPS traffic, wildcard DNS is unchanged,
  and production continues serving throughout successful and failed rehearsals.
* All CronJobs are suspended; unapproved workers, user Services, and hooks have zero running
  pods; candidate cloud identity cannot mutate registry or backup state.
* Local TLS, Kourier routing, Knative activation, health probes, and restored database/volume
  reads work through the IAP path. Production ACME issuance is explicitly marked untested
  until the pre-cutover arming step.
* A fence violation or failed check prevents `Ready`, persists actionable evidence, and can
  be corrected and rerun without rebuilding the old host.
* Evidence is accepted only when its target payload, candidate resource IDs, state seed,
  policy digest, and drift token match the current transaction.


## Idempotence and Recovery

Host switching uses the existing self-reverting guard. Bootstrap, transformations, and
policies use declarative apply and may be rerun after identity and recipe guards pass.
Evidence is replaced only after a complete successful run; failed-attempt logs remain under
an attempt-specific directory.

If the kubeconfig or instance identity does not match, stop before mutation and discard only
the locally fetched candidate kubeconfig. If host activation fails, wait for the access guard
to revert, reconnect through IAP, and either fix the target or abandon the candidate. If a
workload escapes the fence, immediately stop candidate workload execution, revoke/delete any
temporary probe policy, mark all rehearsal evidence invalid, and inspect external effects;
do not treat cleanup alone as a passing rehearsal. The active machine is never a recovery
target of candidate bootstrap commands.


## Interfaces and Dependencies

Use existing Haskell/Aeson/process dependencies and existing command runners. Use Kubernetes
`NetworkPolicy`, workload scale/suspend fields, labels, and server-side queries rather than a
new in-cluster controller. Do not add a service mesh or load balancer. Use the immutable
target payload's bootstrap assets and exact component pins.

The owned interfaces are:

    data CandidateTarget = CandidateTarget
      { project :: Text, zone :: Text, instance :: Text
      , hostFlake :: FilePath, kubeconfig :: FilePath
      , expectedClusterId :: Text, transactionId :: Text
      }

    data RehearsalPolicy = RehearsalPolicy
      { allowedPlatformResources :: Set ResourceId
      , allowedStateResources :: Set ResourceId
      , applicationProbes :: Map AppName ProbePolicy
      }

    data ProbePolicy = ProbePolicy
      { command :: NonEmpty Text
      , allowedClusterDestinations :: Set Destination
      , allowedExternalDestinations :: Set Destination
      , timeoutSeconds :: Natural
      }

    data FenceAttestation = FenceAttestation
      { infrastructurePassed :: Bool, identityPassed :: Bool
      , workloadPassed :: Bool, violations :: [FenceViolation]
      , observedAt :: UTCTime, policyDigest :: Text
      }

    transformForRehearsal
      :: RehearsalPolicy -> [KubernetesObject]
      -> Either RehearsalError [KubernetesObject]
    attestFence :: RehearsalOps -> CandidateTarget -> RehearsalPolicy
                -> IO (Either RehearsalError FenceAttestation)
    runRehearsal :: RehearsalOps -> ReplacementTransaction
                 -> IO (Either RehearsalError RehearsalReport)

ExecPlan 124 is a hard prerequisite and supplies the target. ExecPlan 126 is a soft
coordination dependency: this plan can bootstrap platform-only first, but it cannot produce
final ready evidence until state checks pass. ExecPlan 127 consumes the report, temporarily
arms production permissions/TLS while the old host still serves, reruns the affected fence
and platform checks, and invalidates rehearsal if that arming changes any unrelated input.
