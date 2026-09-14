---
id: 135
slug: make-fresh-gcp-contexts-preflight-and-re-pin-cleanly
title: "Make fresh GCP contexts preflight and re-pin cleanly"
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
      at: 2026-09-14T12:33:05Z
      mode: "implement"
      note: "Started ADC and undeployed-context implementation"
---

# Make fresh GCP contexts preflight and re-pin cleanly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A freshly initialized GCP context reports `not deployed` for resources that do not exist instead of
calling them legacy, and an operator can re-pin that context to the current patch release before
creating a VM. Initialization and every later cloud guard inspect the Application Default
Credentials (ADC) that Pulumi actually uses, refuse a foreign quota project, and make any detectable
account disagreement visible. This plan implements IR-12 and IR-16 without changing adoption or
upgrade semantics for deployed clusters.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Model and test ADC discovery, principal evidence, and quota-project policy.
- [ ] Add the shared ADC observation to initialization and the context guard.
- [ ] Represent not-deployed host/cluster identities and add a guarded re-pin command.
- [ ] Update setup/upgrade docs, complete the IRs, and run all focused and repository checks.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Refuse a known ADC `quota_project_id` that differs from the selected context project;
  warn on an absent quota project or an account that cannot be determined.
  Rationale: Foreign quota attribution is deterministic and directly violates project confinement.
  Authorized-user ADC files may omit a principal name, so absence must not be misreported as a
  mismatch; the command must still show that the account is unknown.
  Date: 2026-09-14.

- Decision: Add `nagarectl platform repin --version VERSION --yes` for never-deployed contexts.
  Rationale: `adopt` means attaching identity to legacy deployed objects, while `upgrade` is a
  guarded host-and-cluster transaction. A narrow re-pin makes the pre-resource state explicit and
  can fail permanently once deployment evidence exists.
  Date: 2026-09-14.

- Decision: Use absence of the context's GCE instance as the authoritative cloud evidence that the
  single-host cluster cannot yet exist; distinguish NotFound from lookup failure.
  Rationale: An unreachable kubeconfig alone cannot prove absence. In Nagare's current architecture,
  the cluster resides on that one context-owned host, so a successful project-scoped NotFound is a
  reliable boundary.
  Date: 2026-09-14.

- Decision: Amend ADRs 6 and 9 during implementation if the proposed interfaces remain.
  Rationale: Deployment-state identity and ADC quota attribution are durable extensions of those
  existing decisions, not task-local mechanics.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

[IR-12](../improvement-requests/check-the-adc-account-and-quota-project.md) records that Nagare
checks gcloud and Pulumi stack projects but not ADC. ADC is the credential discovery convention
used by Google client libraries. An ADC JSON file may include `quota_project_id`; API clients use
that project for quota and billing even when the resource project is correct. The path is selected
by `GOOGLE_APPLICATION_CREDENTIALS`, otherwise by the gcloud configuration directory selected by
`CLOUDSDK_CONFIG`, otherwise by gcloud's normal user ADC location. Service-account credentials
usually identify `client_email`; authorized-user credentials may have an optional `account` or no
recoverable principal at all. Never print access or refresh tokens.

`cli/nagarectl/src/Nagare/Init.hs` implements `runPreflight`. It checks the active gcloud account
and that account's IAM roles before writing a context. `cli/nagarectl/src/Nagare/Ops/ContextGuard.hs`
defines `ProjectGuardInputs` and compares the declared context project with the Pulumi stack,
ambient `CLOUDSDK_CORE_PROJECT`, and configured gcloud project. `cli/nagarectl/app/Main.hs` gathers
those values. The shared ADC observer belongs in a small GCP module rather than two JSON parsers.

[IR-16](../improvement-requests/undeployed-context-reports-legacy-unknown.md) records the second
failure. `cli/nagarectl/src/Nagare/Platform/Status.hs` represents missing version identities as
legacy/unknown; `assessPlatformStatus` lets that state outrank a real patch skew. `runPlatformAdopt`
refuses every already-versioned context, and the upgrade transaction assumes a host and Kubernetes
cluster exist. A generated host flake may already exist locally even though no VM has been created,
so local file existence is not deployment evidence.

The new observation must run `gcloud compute instances describe` with explicit context project,
zone, and instance. Exit evidence meaning NotFound yields `NotDeployed`; authentication, network,
permission, or malformed-output failures yield `Unknown`, never `NotDeployed`. If the host is
confirmed absent, cluster state is also `NotDeployed`. If the host exists but cluster identity is
unreachable, it remains legacy/unknown. A real unversioned host also remains legacy/unknown.

[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) owns
release identity across context, host, and cluster. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires cloud mutations to fail closed on project disagreement. [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)
requires re-pin to keep any generated host flake consistent with its context. No cross-repository
ADR is needed.


## Plan of Work

### Milestone 1: observe ADC safely

Create `cli/nagarectl/src/Nagare/Gcp/Adc.hs` and expose it in
`cli/nagarectl/nagarectl.cabal`. Define credential path/source, credential kind, optional principal,
optional quota project, and parse/IO failures as data. Resolve environment precedence explicitly.
Parse only identity metadata; redact token-bearing fields from all `Show`, JSON, and error output.
Add fixture files for matching, differing, absent, service-account, authorized-user-without-account,
malformed, and missing cases under `cli/nagarectl/test/fixtures/adc/`.

Extend `ProjectGuardInputs` and its renderer with ADC evidence. A known foreign quota project is a
refusal with the exact repair command `gcloud auth application-default set-quota-project <project>`.
A known principal different from gcloud's active account is a warning during preflight and guard,
not proof of resource-project mismatch. Missing or invalid ADC is a preflight/guard failure before
Pulumi. Unknown principal is an explicit warning. Unit tests must prove all verdicts and prove no
fixture token appears in output.

### Milestone 2: put the shared check on every required path

Call the shared observer in `runPreflight` before any context write and in `projectGuardInputsFor`
before Pulumi inspection. Preserve `--json` stability by adding structured ADC fields and warnings;
do not bury them in free-form text. Ensure init can validate its proposed project before a context
exists, while context guard resolves the selected context. Update fake-command tests in
`cli/nagarectl/test/Spec.hs` to prove a foreign quota project prevents the first Pulumi invocation.

Update `docs/user/gcp-prerequisites.md`, `docs/user/contexts.md`, and
`docs/user/onboarding-bring-your-own-project.md` to run ADC login and `set-quota-project` explicitly.
Explain that changing Nagare or gcloud contexts does not switch ADC.

### Milestone 3: model not-deployed and make re-pin safe

Extend `cli/nagarectl/src/Nagare/Platform/Status.hs` with a deployment observation separate from
release identity. Add a project-scoped host observer in a focused module such as
`cli/nagarectl/src/Nagare/Platform/Deployment.hs`. Render `Host: not deployed` and
`Cluster: not deployed` in human output and explicit state values in JSON. Aggregate compatibility
from identities that exist, so a context one patch behind remains `patch-skew`. Do not change the
meaning of legacy/unknown for an existing unversioned or unreachable object.

Add `PlatformRepinOpts` and `PlatformRepin` in `cli/nagarectl/app/Main.hs`. The command requires an
explicit version, the normal platform/context/ADC guards, a successful NotFound observation for the
context's instance, no observed cluster identity, and `--yes`. It atomically updates the context
release pin and, if a generated host flake exists, regenerates or updates its Nagare input to the
same release using the existing host-config writer. Refuse dirty/unrecognized generated files rather
than partially editing them. Rerun status and require context/payload agreement.

Add `PlatformSpec` matrices for absent, existing-unversioned, unreachable, and versioned objects,
plus fake-gcloud command tests proving re-pin refuses an existing instance and every lookup failure.
Document re-pin next to adoption in `docs/user/upgrades.md`.

### Milestone 4: close the requests

Update `CHANGELOG.md`, amend ADRs 6 and 9 with the verified durable rules, and complete IR-12 and
IR-16 only after focused tests pass. Add the bundle log entry and run strict OKF validation and the
repository gate.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`.

```bash
cabal test nagarectl-test
nagarectl context guard --context labs --json
nagarectl platform status --context labs --json
```

For an intentionally undeployed fixture context, expected JSON contains a matching ADC quota
project, host/cluster state `not-deployed`, and compatibility `patch-skew` when the pin is one patch
behind. Then:

```bash
nagarectl platform repin --context labs --version 0.2.2 --yes
nagarectl platform status --context labs
```

Expected human output names both resources `not deployed` and reports the context at the requested
release. A fixture `quota_project_id: production` must exit nonzero before fake Pulumi is called;
an existing fake GCE instance must make re-pin exit nonzero. Finish with:

```bash
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
nix flake check --print-build-logs
```


## Validation and Acceptance

ADC acceptance requires unit fixtures for matching, foreign, absent, and malformed quota projects,
plus known, mismatched, and unknowable principals. Init and context guard must refuse before Pulumi
when the ADC file is missing/invalid or carries a foreign quota project, print the exact repair
command, and never reveal credential tokens. `GOOGLE_APPLICATION_CREDENTIALS` and `CLOUDSDK_CONFIG`
must select the tested file in documented precedence.

Deployment-state acceptance requires a patch-behind context with a confirmed-absent instance to
render host and cluster `not deployed` and aggregate to `patch-skew`, not `legacy-unknown`. A real
unversioned host and a failed cloud lookup must remain legacy/unknown. Re-pin succeeds exactly when
the context is versioned but never deployed, keeps the context and generated host flake at one pin,
and refuses once the instance exists or any absence check is inconclusive.


## Idempotence and Recovery

ADC and status observations are read-only. Re-running re-pin at the requested version should report
an already-matching no-op after repeating the absence guard. Write context and generated-host
changes through sibling temporary files and atomic renames; if either validation fails, leave both
old files intact. Never use re-pin to repair a deployed context. If the cloud lookup is unavailable,
restore connectivity/credentials and retry rather than adding a force bypass; deployed contexts use
the existing upgrade flow.


## Interfaces and Dependencies

`Nagare.Gcp.Adc` should expose data, not credential contents:

```haskell
data AdcObservation = AdcObservation
  { source :: AdcSource, credentialKind :: Text
  , principal :: Maybe Text, quotaProject :: Maybe Text }

observeAdc :: AdcEnv -> IO (Either AdcError AdcObservation)
```

`Nagare.Platform.Deployment` should distinguish absence from uncertainty:

```haskell
data DeploymentState = NotDeployed | Deployed | DeploymentUnknown Text
observeHostDeployment :: DeploymentOps -> TargetProfile -> IO DeploymentState
```

Extend `ProjectGuardInputs` with `adc :: Either AdcError AdcObservation` and keep
`projectGuardVerdict` pure. Depend only on existing Aeson/process/filesystem libraries, `gcloud`,
and existing Nagare context/host writers. EP-3 consumes the extended guard. EP-6 validates the
public preflight and re-pin path.
