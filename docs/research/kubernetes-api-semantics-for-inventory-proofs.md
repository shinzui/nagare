---
type: Research Document
title: Kubernetes API semantics for inventory proofs
description: First-principles, experiment-validated semantics of the Kubernetes kinds in MP-23 release line (b), the ADR 26 proof classes they imply, and a gap analysis of the Kubernetes adapter and its world model.
generated:
  by: process:claude-code
  at: "2026-10-06T22:10:00Z"
researchId: RES-4
status: complete
scope: >-
  The sixteen in-line Kubernetes kinds of MP-23 release line (b) in the recovery model's kind table, as implemented at
  9ac3a484 (plus the uncommitted F67 version-4 design on create-batch-2), against k3s v1.34.6 and Knative Serving
  1.22.0 with Kourier. Validated on a disposable local k3d cluster. No cloud or GCP action, and no Nagare
  command against a live context.
sources:
  - id: experiments
    resource: ../audits/k8s-semantics-2026-10-06/README.md
    title: Experiment scripts, outputs and verbatim results (E0–E12)
  - id: kinds
    resource: ../../cli/nagarectl/test/Nagare/Test/World/Kinds.hs
    title: Recovery model kind table (release line (b) rows)
  - id: world
    resource: ../../cli/nagarectl/test/Nagare/Test/World/Kubernetes.hs
    title: In-memory Kubernetes world model
  - id: adapter
    resource: ../../cli/nagarectl/src/Nagare/Inventory/Adapters/Kubernetes.hs
    title: Kubernetes inventory adapter (prepare, execute, recover, settle)
  - id: runtime
    resource: ../../cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs
    title: Kubernetes runtime transport, observation parser and readiness predicates
  - id: configuration
    resource: ../../cli/nagarectl/src/Nagare/Inventory/KubernetesConfiguration.hs
    title: Configuration digest and landed-unready proof
  - id: adr26
    resource: ../adr/0026-stopped-transactions-close-by-per-operation-proof.md
    title: ADR 26, stopped transactions close by per-operation proof
  - id: adr27
    resource: ../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md
    title: ADR 27, physical identity is recorded at creation
  - id: findings
    resource: ../audits/mp23-findings.md
    title: MP-23 findings register
  - id: k8s-api-concepts
    resource: https://kubernetes.io/docs/reference/using-api/api-concepts/
    title: Kubernetes API concepts (resource versions, conflicts)
  - id: k8s-ssa
    resource: https://kubernetes.io/docs/reference/using-api/server-side-apply/
    title: Kubernetes server-side apply
  - id: k8s-deployment-status
    resource: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#deployment-status
    title: Deployment status, progress deadline
  - id: k8s-sts-forced-rollback
    resource: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#forced-rollback
    title: StatefulSet forced rollback
  - id: k8s-finalizers
    resource: https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
    title: Kubernetes finalizers
  - id: k8s-skew
    resource: https://kubernetes.io/releases/version-skew-policy/#kubectl
    title: kubectl version skew policy
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: "2026-10-06T22:10:00Z"
    document_timestamp: "2026-10-06T22:10:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: Anthropic
    model: claude-opus-5-5
    effort: high
    context: >-
      Author self-review against the cited source at 9ac3a484 and the recorded experiment outputs; independent review
      is pending.
---

# Kubernetes API semantics for inventory proofs

Evidence checked: 2026-10-06. Every claim is marked **[E*n*]** when an experiment on a real API server validated it
(see [the experiment record](../audits/k8s-semantics-2026-10-06/README.md)), **[src]** when it comes from Nagare's
source at `9ac3a484`, and **[docs]** when it rests only on upstream documentation.

## Why

MP-23's adapter proofs and its recovery world model were both written from beliefs about Kubernetes. The world model
([`World/Kubernetes.hs`](../../cli/nagarectl/test/Nagare/Test/World/Kubernetes.hs)) encodes the same beliefs as the
adapter, so fault injection finds only defects that contradict the adapter's *code*, never its *assumptions*. F63, F66,
F67, F68 and F69 all follow from basic API semantics. This record states those semantics once, validated against a
real server. It derives the ADR 26 classes from them and checks the code against the result.

U11–U14 come from EP-182's machine-readable traces (`cli/nagarectl/test/fixtures/kubernetes-semantics/traces.json`, recorded by `record-traces.sh`), checked by the fake API server's conformance test.

Environment: k3s `v1.34.6-k3s1` (the local-mode pin), Knative Serving 1.22.0 and Kourier 1.22.0 from the vendored
manifests, kubectl client 1.37.0 [E0].

## 1. Universal API rules

| # | Rule | Evidence |
| --- | --- | --- |
| U1 | A UID is assigned at create and never reused. Delete and recreate always yields a new UID, and `generation` restarts at 1 where it exists. | [E3 i–j] |
| U2 | `resourceVersion` moves on **every** persisted write: spec, metadata (annotation, label), and any status-subresource write. A no-op server-side apply writes nothing and does not move it. rv equality therefore means "nothing at all was written", which is strictly stronger than "Nagare's write did not land". | [E1] |
| U3 | One request is one atomic write: a server-side apply that changes spec and annotations produces one new rv. Nagare's `nagare.dev/spec-digest` stamp therefore lands in the same write as the spec it describes. | [E3 b], [docs k8s-api-concepts] |
| U4 | Every 4xx refusal left the object unchanged. Observed: 409 AlreadyExists (create over existing); 409 Conflict (stale rv on PUT or SSA; UID or rv delete precondition; SSA `uid mismatch` on an absent object); 422 Invalid (SSA with a wrong UID while present, "metadata.uid: field is immutable"; a failed JSON-patch `test`; immutable fields such as a Job template or an unbound PVC spec); 404 (delete of an absent object). Same codes for a core kind and a CRD behind Knative's webhooks. Only transport failures, timeouts and 5xx can hide a committed write. | [E3, E1, E8], 5xx part [docs k8s-api-concepts] |
| U5 | A server-side apply that carries **only** `metadata.resourceVersion` creates an absent object (201). With `metadata.uid` it is refused (409). The UID, not the rv, is what makes an apply conditional on existence. Nagare always sends both. | [E3 i–k], [src runtime `addPreconditions`] |
| U6 | DELETE is two-phase when finalizers are present. The response is 200 with the object carrying `deletionTimestamp`. The object then stays, with the **same UID and a new rv**, until its finalizers clear. `Orphan` propagation adds the `orphan` finalizer: a ConfigMap is gone in about 90 ms, but a Knative Service never completes (Knative's webhook blocks the ownerReference removal; this is F20). `kubernetes.io/pvc-protection` holds a PVC while a pod mounts it, and Namespace holds `kubernetes`. Background deletion of a StatefulSet returned with no finalizer and the object gone in 94 ms, with pods removed afterwards. A PVC held this way stays mounted and readable by its running pod, but the scheduler refuses any new pod that names it ("persistentvolumeclaim … is being deleted"). Once that pod is deleted, the PVC goes within seconds, before its controller's replacement pod can schedule. Its volume is then deleted under local-path's `Delete` reclaim policy, or kept `Released` if the policy was patched to `Retain` first; a recreated PVC naming that volume (after clearing its `claimRef`) mounts the original data. | [E7, E12, E16] |
| U7 | The API server stores resource quantities in canonical form, for core kinds and also through Knative's webhook: `1024Mi`→`1Gi`, `2048Mi`→`2Gi`, `1000M`→`1G`, `1000m`→`1`, `1.5`→`1500m`, PVC `1024Mi`→`1Gi`. The rule: the suffix family is kept (binary, decimal SI, or exponent: `1500e0` stays `1500e0`), the value is rounded **up** to milli (`0.1m` and `100u` both store as `1m`), and the largest suffix of the family that leaves an integer mantissa is used. A binary value that is not a whole number falls back to decimal SI (`1.1Ki`→`1126400m`). A PVC accepts a fractional byte count with a warning, not a refusal. | [E11, E15] |
| U8 | `metadata.generation` exists only where the kind's strategy sets it, and moves on spec changes only. Exception: a **Deployment** also moves it on a metadata **annotation** change (a label does not move it). A StatefulSet's does not move on annotations. | [E1] |
| U9 | `kubectl wait --for=condition=…` (client 1.37) refuses a condition whose object reports `observedGeneration < generation`. `kubectl rollout status` uses the full rollout rule for Deployment and StatefulSet. kubectl 1.37 against a 1.32 server never satisfied `wait` on CRDs. That pairing is outside the ±1 skew policy, and the same command works against 1.34. | [E4, E5, E0], [docs k8s-skew] |
| U10 | Server-side apply tracks a writer per field in `managedFields`. Status writes go to separate status-subresource entries. `kubectl create --field-manager=nagare-inventory` records the manager as *Update*, and a later apply under the same name is a **different** manager. So an apply **without** `--force-conflicts` that changes a create-time field is refused (409, "Apply failed … conflicts with \"nagare-inventory\""), and a forced apply that leaves a value unchanged only shares ownership. A foreign write that changes a managed field takes it into its own entry (for example `kubectl-edit/Update`), and a no-force apply then conflicts. That holds even when the foreign write restores Nagare's earlier value. A write that changes nothing was not tested. `metadata.resourceVersion: "0"` is ignored by apply: it creates when absent and applies when present, so apply has no create-if-absent. | [E13] |
| U11 | A DELETE that a finalizer holds also moves `metadata.generation` (where the kind has one) along with setting `deletionTimestamp`, and controllers stop reconciling an object being deleted. A Knative Service held by an `Orphan` delete therefore shows `observedGeneration` behind `generation` while it is Terminating. | [traces E7] |
| U12 | Who owns a server-set field depends on what set it. A mutating admission plugin's change (a PVC's default StorageClass) is owned by the request's manager for Apply and Update alike. Defaulting (a Namespace's `kubernetes.io/metadata.name` label) is owned only by an Update-style create, whose ownership is the diff from an empty object. So a repeated identical apply of a PVC that omits its StorageClass moves resourceVersion once, as the applier releases that field, and `kubectl create` of a Namespace leaves a `kubectl-create` entry. | [traces E1, E12] |
| U13 | A DomainMapping carries Knative's `domainmappings.serving.knative.dev` finalizer from creation, as a non-status field of the `controller` manager; its DELETE completes once the controller finalizes, normally at once. `kubernetes.io/pvc-protection` is removed asynchronously, so even an unused PVC is briefly Terminating after DELETE. | [traces E1, E14] |
| U14 | kubectl's `wait` timeout names the bare plural (`services/e4`), and an apply with several conflicts lists their paths on lines after the first, while one with a single conflict keeps it on the first line. | [traces E4, E13] |

## 2. Per-kind semantics (release line (b))

"Gen" is `metadata.generation`; "og" is `status.observedGeneration`.

| Kind | Gen (moves on) | Status subresource / og | Readiness or terminal signal | Mid-rollout and stale behaviour | Steady-state churn | Delete (Nagare policy) | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Knative Service | yes (spec) | yes / yes | `og == gen ∧ Ready=True` | After a spec write, `Ready=True` **from the old generation** is kept until the controller observes (`og < gen`); it then goes `Ready=Unknown` at the new og before `True`. Bad image: `Ready=False/RevisionFailed`, traffic stays on the last ready revision. An unowned core Service with the same name gives `Ready=False/NotOwned` until removed. | none (60 s idle, 3 min Ready and RevisionFailed) | Orphan: never completes, descendants keep serving (F20) | E1, E4, E7, E10 |
| DomainMapping | yes (spec) | yes / yes | same as Knative Service | Domain claimed elsewhere (stock `autocreate-cluster-domain-claims=false`): `Ready=False/DomainAlreadyClaimed` indefinitely. Nagare's bootstrap sets the flag to `true` [src]. Stale window: same duck type, not separately validated. | not measured | Nagare refuses an Orphan DELETE [src] | E9 |
| Deployment | yes (spec **and annotations**) | yes / yes | rollout rule: `og == gen ∧ updatedReplicas == spec.replicas ∧ status.replicas == updatedReplicas ∧ availableReplicas == updatedReplicas` | Bad image or crash loop with 1 replica: `Available=True` stays (old ReplicaSet, maxUnavailable rounds to 0), Progressing `ReplicaSetUpdated`, then `False/ProgressDeadlineExceeded`. Never terminal: the controller keeps trying. | none | not collectable | E1, E5, E10 |
| StatefulSet | yes (spec only) | yes / yes; no conditions | `og == gen ∧ readyReplicas == spec.replicas ∧ updatedReplicas == spec.replicas ∧ currentRevision == updateRevision` | Under the defaults Nagare renders (OrderedReady, RollingUpdate, replicas 1): **once pod-0 is not Ready (crash loop or Pending), no later template change replaces it.** A correcting update lands (`og == gen`, new `updateRevision`), and the pod stays at the broken revision until deleted. With `Parallel` the correction rolls in 1 s. | none | Background: gone in under 100 ms | E1, E6, E6d, E6e, E6f, E12, [docs k8s-sts-forced-rollback] |
| CronJob | yes (spec) | yes / **no** | none (object only) | n/a | **every schedule tick** (lastScheduleTime, active list): about once a minute for `* * * * *` | Orphan | E1, E10 |
| Job | yes (spec) | yes / **no** | `Complete=True`; terminal `Failed=True`, preceded by `FailureTarget=True` | template immutable (422) | while running | Background | E1, E8 |
| ConfigMap, Secret | none | none | none | n/a | none | Orphan, about 90 ms | E1, E10, E12 |
| ServiceAccount, Role, RoleBinding | none | none | none | n/a | none | Orphan | E1 |
| Service (core) | none | yes / no | none | n/a | none | Orphan | E1 |
| PVC | none | yes / no | none (phase Pending→Bound with a consumer) | spec immutable except `requests` and only once Bound (422 while Pending). The provisioner writes annotations and `spec.volumeName` at bind [src]. | on bind or resize | Orphan; while mounted: Terminating indefinitely | E1, E7 |
| Namespace | none | yes / no | phase Active / Terminating | n/a | none | Terminating until contents are removed | E1, E12 |
| ResourceQuota | none | yes / no | none | n/a | **`status.used` whenever pods in the namespace change** | not collectable | E1, E10 |
| NetworkPolicy | yes (spec) | **no** subresource / no | none | n/a | none | not collectable | E0, E1 |

## 3. Derived ADR 26 decision tables

### Observables

- **R**, the API answer to Nagare's write: `2xx`, `4xx` (definitive no effect, U4) or `ambiguous` (transport, timeout, 5xx).
- **U**, the live object's UID compared with the reviewed UID: same, different, or absent.
- **S**, the live stamp: `this member at D_new` (the review's digest), `this member at D_before`, `unstamped`, or `other`.
- **T**, whether `deletionTimestamp` is set.
- **Ready(kind)**, the generation-aware predicate of §2. **Failed**, a Job's `Failed=True`.

U3 makes **S** the exact witness of Nagare's own write. The write that sets `D_new` is the same write that sets the
spec, so its presence or absence on the reviewed UID proves landed or not landed, whatever status or controller
metadata did meanwhile.

### Create (before: absent)

| Observed | Class |
| --- | --- |
| R = 4xx | NoEffect |
| absent (any R) | NoEffect. Sound because each kind's effect is confined to the object; see G10 for a Job deleted after it ran. |
| present, S = this member at `D_new`, not T | Ready → Completed. Job Failed → TerminalPartial. Otherwise → Landed. |
| present, S = this member at `D_new`, T | TargetGone (being deleted outside review) |
| present, S unstamped or other member | TargetGone (F66) |
| present, S = this member at another digest | Unknown (a copy of the stamp; ADR 27 rebind territory) |
| observation unavailable | Unknown |

### Update (before: UID u, `D_before ≠ D_new`)

| Observed | Class |
| --- | --- |
| R = 4xx | NoEffect |
| absent, or U different | TargetGone (F64, F56, F68) |
| U same, S = this member at `D_before` | **NoEffect, regardless of rv, status, generation or controller metadata** |
| U same, S = this member at `D_new`, not T | Ready → Completed; otherwise → Landed. For a StatefulSet whose pod is at an older revision and not Ready → Landed **and blocked** (§5.3). |
| U same, T | TargetGone (being deleted outside review) |
| U same, S unstamped | TargetGone (F68) |
| U same, S other | Unknown |
| repair update with `D_before == D_new` (drift repair) | desired fields match after quantity canonicalization → Landed or Completed; they do not match → NoEffect; ambiguous otherwise → Unknown |

### Retire and collect (DELETE with UID and rv preconditions)

| Observed | Class |
| --- | --- |
| R = 409 or 422 | NoEffect |
| absent, or U different | Completed (the reviewed UID no longer exists; a different UID is recorded as evidence) |
| U same, T | **Landed** (deletion accepted; name the remaining finalizers) |
| U same, not T | NoEffect |

### Adopt (JSON patch `test` on UID and rv, then add the stamp)

| Observed | Class |
| --- | --- |
| R = 4xx (422 on a failed test) | NoEffect |
| U same, unstamped | NoEffect |
| U same, S = this member at `D_new` | Completed (adoption has no readiness of its own) |
| absent, or U different | TargetGone |

### Verify

Always NoEffect (ADR 26 §6). The close path already applies this before it asks the adapter
([`Execute/Close.hs`](../../cli/nagarectl/src/Nagare/Inventory/Execute/Close.hs) line 327) [src].

**Unknown** remains only when the API cannot be observed, or after an ambiguous answer when the stamp is neither
`D_before` nor `D_new` (another writer edited the stamp).

## 4. Gap analysis

Severity order: **wrong success** (a broken state recorded as converged) > **false hope** (a reviewed fix that
cannot take effect) > **wedge** (only attested close) > **friction** (a safe refusal that needs a replan).

| ID | Gap | Evidence | Severity | Reachable in normal operation | Line (b) | Fix size | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | `deploymentAvailable` treats `Available=True ∧ og == gen` as ready. During a broken worker update the old ReplicaSet keeps `Available=True`, including after `ProgressDeadlineExceeded`. `recover` then returns `RecoveryProvedComplete`, and plans see `ObservedPresent`. | E5; runtime `deploymentAvailable` | **wrong success** | yes: any bad worker image or crash loop, then `resume` or the next plan | yes | S | **MP-23** (handed to nagare-defects) |
| G2 | F69: `knativeReady` ignores og. A stale `Ready=True` from the previous generation satisfies the observation. Also used for DomainMapping. | E4 | wrong success | narrow: an interrupt or verify within seconds of the write, or a lagging controller | yes | S | **MP-23** (in flight) |
| G3 | A StatefulSet correction never rolls once its pod is not Ready (crash loop or Pending). F59's and F63's "a corrective update of the unready StatefulSet" lands, waits 300 s, settles Landed, and close keeps a revision that never runs. `db restart` (`rollout restart`) is blocked the same way. The world model makes any new digest Ready. | E6, E6e, E6f | **false hope**, then a hidden wedge | yes: any database misconfiguration (image, resources, scheduling) | yes | M | **MP-23** (§5.3) |
| G4 | Every non-zero kubectl exit becomes `AdapterEffectAmbiguous`, including the definitive 409/422/404 refusals. The world returns `KnownNoEffect` for the same refusal, so the model never exercises the real path: 409 after a status write, then a settle that compares rv, then Unknown. | E3; runtime `mutate` fallback; world `mutate` | wedge (via G6 churn) | occasional | yes | S | **MP-23** |
| G5 | `parseObservedWithConfiguration` ignores `deletionTimestamp`, so a terminating object is Present. A retire of a mounted PVC settles Unknown instead of Landed, and its retry precondition is stale (409). Verify and convergence can accept a terminating member. | E7; runtime parser | wedge; wrong success on verify | PVC retire while mounted; finalizer-held out-of-band deletes | yes | S | **MP-23** |
| G6 | Execute-time `requireSameBefore` (v1 whole-state, rv included) refuses any update or retire of a churning kind after a status write. That is CronJob every tick and ResourceQuota on every pod change. F30's version-2 fix covers only Knative, and v4 changes only settlement. Review→apply latency above the tick interval makes such a change unappliable. | E10; adapter `execute`, `requireSameBefore` | friction (liveness) | yes: scheduled tasks with short schedules, quotas in busy namespaces | yes | S–M | **MP-23** |
| G7 | `desiredFieldsMatch` normalizes CPU only, and `mkQuantity` keeps user text verbatim. A non-canonical memory or storage value drifts forever: the update never verifies (`completionProof` digest mismatch), and the Landed proof cannot match. Built-in defaults are canonical [src]. | E11 | wedge on every deploy | user-supplied `1024Mi`, `0.5Gi`, `1000M` | yes | S | **MP-23** |
| G8 | A Knative Service whose name collides with an unowned core Service stays `Ready=False/NotOwned` indefinitely. | E1 | Landed-unready, external cause | rare | yes | S (planning check) | ledger |
| G9 | A stamp change bumps a Deployment's generation, so og lags briefly after a stamp-only adoption or repair. Harmless once readiness is generation-aware. | E1 | none | — | — | — | record only |
| G10 | A create that finds absence settles NoEffect. A Job that ran and was then deleted outside review had side effects (backup upload, copy). Nagare sets no Job TTL [src], so this needs an out-of-band delete. | src | wrong NoEffect | no | yes | S | ledger (documented limit) |
| G11 | The world model shares the adapter's beliefs; see §5.4. | §2 against `World/Kubernetes.hs` | finds no assumption defects | — | yes | M | **MP-23** |
| G12 | The dev-shell kubectl (1.37) is three minors from the server (1.34), outside the skew policy. `kubectl wait` broke at four minors (E0). | E0 | latent | on a server or client bump | no (tooling) | S | ledger |
| G13 | `scripts/probe-ep160-*` pin k3s 1.32.5. Knative 1.22 refuses below 1.34. Local mode itself pins 1.34.6. | E0; src | none for local mode | — | no | S | ledger |
| G14 | F20, reconfirmed: an Orphan DELETE of a Knative Service never completes and its descendants keep serving. | E7b | known | — | — | — | existing finding |
| G15 | `statefulSetReady` omits `currentRevision == updateRevision`. That is equivalent at replicas 1. | src; E6 | none at 1 replica | — | — | — | tighten while touching G3 |

**Bounded total for MP-23:** seven adapter items (G1–G7) plus the world-model realignment (G11), together with the
F67 decision in §5.1. G1 and G2 are already in flight. Ledger: G8, G10, G12, G13 (G9 and G15 need no work; G14 is F20).

## 5. Recommendations

### 5.1 F67: stamp proof, not configuration digest v4

Both proposals are sound for NoEffect. They differ in completeness and cost:

| Criterion | Stamp proof (S on the reviewed UID) | v4 configuration digest |
| --- | --- | --- |
| Status churn (F30, F67) | immune | immune |
| Controller metadata writes (Deployment revision annotation, PVC bind annotations and `volumeName`, operator labels) | immune: S is untouched | Unknown, because the digest moves |
| External writer edits the spec | still NoEffect or Landed, correctly: Nagare's stamp says which write is live | Unknown |
| External writer edits the stamp | trusted. A false Landed needs the private `D_new`; a false NoEffect needs a deliberate rollback of the stamp alone. That is the same trust ADR 27 already places in stamps, bound to the UID. | Unknown (conservative) |
| Deployment generation moves on the stamp change | irrelevant: S is read directly | irrelevant: generation moves only with a write |
| Where the before-state comes from | the stamp observed at prepare, in the same GET, recorded as `beforeStamp` (see the 2026-10-06 refinement below) | a recorded configuration digest |
| Drift repair (`D_before == D_new`) | cannot tell; use the canonicalized fields-match rule of §3 | covered |
| New observation at prepare | none: prepare and settle read the stamp from the observation they already make. | one extra `get --show-managed-fields` per update; shifts the model's ObserveCall ordinals (it silently made the F68 pin vacuous) |
| Mutation format | one required field, `beforeStamp` | a new version, 4 |

**Recommendation:** adopt the stamp proof for create, update and adopt settlement, with the fields-match rule for
same-digest repairs. Do not land v4. Keep `configurationDigest` only where it already serves (version-2 Knative
execution).

**Refinement (2026-10-06, adopted for EP-180).** `D_before` is the stamp **observed** at prepare, not the base
revision's declared digest (an expectation that prepare never checks) and not "any stamp other than `D_new`" (which
mislabels a drift repair as Landed). Each mutation records it as the required field `beforeStamp`, read through a
stamped variant of the existing observation, so prepare and settle make no extra request. For an update, the order is:

1. Whole-state equality first: an unchanged resourceVersion means NoEffect.
2. With `beforeStamp ≠ D_new`:
   - the same UID still stamped `beforeStamp` → NoEffect;
   - stamped `D_new` → Landed, or Completed by readiness;
   - another stamp, or none → the TargetGone and Unknown rules of §3.
3. With `beforeStamp == D_new` (drift repair):
   - desired fields matching after canonical quantity comparison → Landed or Completed;
   - otherwise → Unknown, never NoEffect.

Nagare has no deployed users (operator, 2026-10-06), so no compatibility with earlier reviews or journals is kept.

### 5.2 One conditional-write discipline for execution (G4, G6)

1. Map kubectl's `Error from server (Conflict|Invalid|AlreadyExists|NotFound|Forbidden|BadRequest)` and
   `error: Operation cannot be fulfilled` to `KnownNoEffect`, and only exit codes without such a server answer to
   ambiguous. Longer term, call the API directly and read the HTTP status.
2. Generalize version 2's execute guard to every update and retire. Require the reviewed UID, the reviewed stamp and
   unchanged desired fields, then write with the **fresh** rv. That keeps the server-side precondition on the object
   that was just checked, without failing on status churn.

   Refined 2026-10-06 with E13 (U10): a no-force apply cannot carry this guard, because it conflicts with Nagare's
   own create entry.
   - **Update:** in the one read with managed fields, require the same UID and owner, the live stamp equal to the
     recorded `beforeStamp`, and no foreign non-status managed-field entry beyond a reviewed takeover and the
     allowlisted controller paths. Together these prove that no other writer touched a spec or metadata field since
     the reviewed before-state. Then apply **with force**, carrying the UID and that read's resourceVersion.
   - **Retire:** require the same UID, owner and a matching digest, then DELETE with the UID and the fresh
     resourceVersion.
   - **On a 409 for a moved resourceVersion,** re-read and re-check, a bounded number of times. Any other refusal is
     NoEffect (G4).

### 5.3 StatefulSet corrections (G3)

A Landed-unready close alone is not an exit. The next plan sees the spec already matches, plans nothing, and the
database never runs the reviewed template. The supported exit consistent with ADR 26 is a **reviewed stuck-pod
replacement**: a separate operation with its own proof.

- **Planned when** a member StatefulSet is observed with `og == gen`, a pod at a revision other than
  `updateRevision`, and that pod not Ready.
- **Effect:** DELETE of the pod with its UID and rv as preconditions. If the pod became Ready meanwhile, its rv moved,
  so the delete returns 409 and the class is NoEffect.
- **Classes:** 4xx → NoEffect; same pod UID → NoEffect; new pod UID → Completed; same UID with T → Landed.
- **Data safety:** the database PVC is a separate member (no `volumeClaimTemplates` [src]), and the deleted pod was
  never Ready.

The same operation can follow F59's create-unready and F63's update-unready in the same or the next review, so their
premise is salvageable with this one addition. Defaults Nagare renders today: no `podManagementPolicy` or
`updateStrategy`, so OrderedReady and RollingUpdate, with replicas 1 [src]. `Parallel` avoids the block (E6d) but the
field is immutable: ledger it for new databases, with a reviewed replacement for existing ones.

### 5.4 Derive the world model from this table (G11)

The decisive change: the world renders realistic JSON (status counters, conditions, `observedGeneration`, stamps,
`deletionTimestamp`), and the adapter's **production parser** classifies it. Today `stateOf` builds
`KubernetesPresent` or `KubernetesNotReady` itself, which makes the world agree with the adapter by construction.
Minimal changes:

1. Extend `KindRow` with the §2 columns: generation present, generation on annotations, og present, churn source,
   readiness model, finalizer behaviour.
2. `KubeObject` gains an optional generation and og, a stamp separate from the spec digest, `deletionTimestamp`,
   and a rollout state:
   - Deployment: old available plus new updated and ready counters;
   - StatefulSet: pod revision and pod readiness.
3. A write moves rv always and generation only per the table. A new adversary event, `ControllerLag`, keeps og and
   the previous status, including `Ready=True`. That reproduces F69 by construction.
4. Churn per kind: CronJob ticks, ResourceQuota on pod changes, Knative only on transitions. Remove `ChurnAlways`
   from Knative Services.
5. A refusal returns the HTTP class, and the runtime's own mapping (§5.2) translates it, so the world and the runtime
   share code, not beliefs.
6. A StatefulSet correction stays stuck until a pod replacement. Finalizer-held deletes enter Terminating.
7. A conformance test compares world traces with the recorded real traces in
   [the experiment record](../audits/k8s-semantics-2026-10-06/README.md). Re-running the scripts is the gate for
   any k3s or Knative bump.

### 5.5 Local mode

`cluster/bootstrap/local-substrate.json` pins `rancher/k3s:v1.34.6-k3s1`, which Knative 1.22 accepts, and the
existing `nagare-local` cluster runs that image. `just local-up` and `just local-smoke` were **not** run here, so this
record makes no claim about them beyond the version pin. One caution for local rehearsals: starting Colima's default
profile also restarts every k3d cluster in it (here `nagare-local` and `kotei-dev`), and three clusters exhaust a
4 GiB VM.

### 5.6 Estimate

About 11 agent-days of implementation, plus machine time for the deep tier. That is roughly 4–5 calendar days across
three parallel sessions:

| Item | Days |
| --- | --- |
| G1 (in flight) | 0.5 |
| G2 (in flight) | 0.25 |
| §5.1 stamp proof in place of v4, with tests and mutation records | 1 |
| §5.2 refusal mapping and generalized execute guard (G4, G6) | 1.5–2 |
| G5 terminating state | 1 |
| G7 quantity canonicalization (normalize in `mkQuantity` and compare semantically) | 0.5 |
| G3 stuck-pod replacement operation | 2–3 |
| §5.4 world realignment and conformance test | 2–3 |
| One local-mode rehearsal | 0.5 |

Assumptions:

- no further ADR change: the stuck-pod operation fits ADR 26 as an ordinary reviewed operation with its own proof;
- the ledger items stay deferred;
- no native cloud run before the final candidate;
- the world realignment lands before the next deep-tier campaign, so new findings come from validated semantics
  rather than from the old beliefs.
