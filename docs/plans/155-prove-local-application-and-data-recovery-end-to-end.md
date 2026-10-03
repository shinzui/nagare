---
id: 155
slug: prove-local-application-and-data-recovery-end-to-end
title: "Prove local application and data recovery end to end"
kind: exec-plan
created_at: 2026-09-26T20:29:54Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T20:29:54Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T22:23:39Z
      mode: "update"
      note: "Cascade EP-148 decomposition: assign remaining feature, cutover, and proof ownership without weakening release acceptance"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:29:12Z
      mode: "implement"
      note: "Start local health fixture and repair observed k3d registry provider binding"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:10Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T05:44:42Z
      mode: "implement"
      note: "Accept installed full native local platform-bootstrap candidate gate and repair stale recording-fixture membership"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T18:53:10Z
      mode: "update"
      note: "Record critical intranet upgrade readiness and backup recovery acceptance with a one-hour recovery-point objective"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T04:25:08Z
      mode: "implement"
      note: "F34 diagnosis and gated recovery: DomainMapping Orphan collection leaves KIngress that breaks Kourier"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T14:20:42Z
      mode: "update"
      note: "Adopt the agreed scenario assertion record and finalize procedure"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T16:03:44Z
      mode: "implement"
      note: "B5: scenario fixture, native stateless companion collection, native reviewed PostgreSQL rename with cp3 proof"
---

# Prove local application and data recovery end to end

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current as work proceeds. It is a child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) (MP-23), which owns the supported release contract, the remaining-work phase IDs (A1–C5) and the pending operator decisions (D1–D5); this plan must agree with it. The plan was consolidated on 2026-10-02. Its earlier text, including every dated checkpoint and failed attempt, is preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md); nothing in the snapshot overrides this file.


## Purpose / Big Picture

After this plan, one reproducible, disposable local run proves that an installed Nagare release candidate works end to end on a workstation. Using only public `nagarectl` commands, it bootstraps the platform on a local k3d cluster, deploys two independently owned applications with data, changes one without disturbing the other, survives interruption at every stage without repeating completed effects, backs up and restores every supported data store into isolated targets, recovers content while the source is unavailable, renames one retained PostgreSQL database without losing rows, collects only exactly eligible leftovers, and restores its private history into a fresh state root. The run writes redacted evidence that the release gate ([EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md)) accepts for the final candidate.

To see it working: the local runner's `verify` phase writes `target.json`, `fixture.json`, `local-health.json` and `inventory-evidence.json` into a new evidence directory, and `scripts/assemble-inventory-release-index.py` accepts that directory for the candidate revision. Cloud-only behavior (GCS shared history, writer takeover, the Compute Engine host, Google CDN) belongs to [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) and is never claimed from this local run. Completing this plan does not make Nagare production-ready; MP-23's data-protection and production gates are separate.


## Progress

Evidence counts toward final acceptance only where its recorded inputs (operator revision, payload, fixture definition and target) match the final candidate; everything recorded before that candidate exists is checkpoint evidence that shows the path works and which defects were fixed. "Implementer" marks evidence recorded by the implementing session; "independent" marks evidence from the independent reviewer in [the 2026-10-02 verification](../audits/mp23-independent-verification-2026-10-02.md).

- [x] Installed local platform bootstrap on `nagare-mp23-cp3` (2026-09-30, implementer, candidate `705716b7`, payload `nagare-0.4.0-705716b7bdb7`): a fresh 217-operation platform review converged all 19 scopes, and an unchanged replan had 213 verification-only operations and zero barriers ([evidence](../audits/mp23-archive/mp23-native-bootstrap-results-2026-09-30/local-platform-candidate-705716b7.json)). Later installed CLIs passed the same cp3 gate independently against this accepted payload (`a027d1f6`, `76628094`, `ec2e1cd4`, `e6255e6f`, `c4d219e4`, `3905012e`, `caa37d19`, `c352cfec`, `762657ed`, `b805d64a`; for example [b805d64a](../audits/mp23-independent-results-2026-10-02/local-gate-b805d64a.json)). Those are CLI gates on an old payload, not fresh candidate-payload bootstrap.
- [x] First production path (2026-09-27, implementer only, installed `e97d65e1` on an earlier six-CPU Colima fixture, private `/tmp` evidence not checked in): platform, then applications A and B each with a separately owned retained PostgreSQL, then a read-only replan of both with seven VerifyResource operations, zero writes and zero barriers; both Knative Services kept their UID and Ready revision.
- [x] Local Redis, ClickHouse and volume isolated restores through MinIO (2026-10-02, independent, installed `ec2e1cd4` on cp3): automatic signed producers ran, the producer Jobs were removed before ingestion, isolated restores returned the original content while sources kept later changes, and accepted-only freshness reported healthy at 515 s ([evidence](../audits/mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)). Local PostgreSQL through MinIO is not part of this record.
- [x] Local release-history pruning and preview cleanup (2026-10-02, independent, cp3, frozen source executables rather than an immutable release binding): the F28 fix updates exactly one history ConfigMap and preserves adjacent members and 29 unselected scopes ([evidence](../audits/mp23-independent-results-2026-10-02/release-cleanup-native-f28-fixed.json)); the F29 bounded preview-route correction and the following preview cleanup collect two stateless members and retain the durable PVC and its contents ([correction](../audits/mp23-independent-results-2026-10-02/preview-domainmapping-correction-f29.json), [cleanup](../audits/mp23-independent-results-2026-10-02/preview-cleanup-native-b805d64a.json)).
- [x] (F34 recovery, before C2) Kourier on cp3 accepts gateway updates again and preview cleanup no longer orphans DomainMapping descendants; see "F34 recovery" in Plan of Work for the gates. Diagnosis (2026-10-02, read-only): the orphaned KIngress and KCertificate of collected preview DomainMapping `7c6ab388…` put host `mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` into two HTTPS filter chains. Done (2026-10-02): step 1 source fix `beca6886` (gate: three authority regressions, 1,132 tests, six public cleanup variants, style gate). Step 2: two preconditioned Background DELETEs at 04:38:09Z; gate met within 20 s (no listener `error_state`, `mp23-correction-proof` Ready, prior routes Ready). Step 3: F30 resume converged; identities, known row and the zero-operation replan check out. Independent F34 verification and a native reviewed DomainMapping collection on the candidate remain (C2).
- [x] (MP-23 B5) The full local scenario fixture is checked in (2026-10-03, `6ed92e61`). `fixtures/inventory-release/local/scenario.json` keeps the runner's health contract and defines the C2 run: applications A and B (typed Applications under `apps/`, each with frozen source and a Dockerfile), the collision variant, the site preview, channels, broker topic, scheduled and one-off Jobs, seed content and a later change for all four stores, the rename, the companion collection, the four interruption stages, and a step map for every scenario check the gate requires. The runner now copies it as `fixture.json`. `scripts/test-local-scenario-fixture.py` holds it to the gate's sensitivity rule and local check names; with `--check-configs` all three Applications pass `nagarectl app check`. During C2, record each assertion with `scripts/scenario-assertions.py record --mode local` as it passes, and run `finalize` after verify to produce the gate-ready `local-health.json`.
- [x] (MP-23 B5) A bounded retained PostgreSQL rename (IR-24 case 3) creates the new incarnation, migrates, verifies known rows and an unchanged auth signing-key identity, and retires the old one through public commands. Source `29f8a852`, `040040dd`, `bc2fd90e`; `InventoryPostgresRenameSpec` covers convergence, a lost transfer acknowledgement and a replaced source. Native cp3 run (2026-10-03, implementer, development binary): `db rename postgres mp23-b5-rename-src mp23-b5-renamed` reviewed 72 stages and converged in 70 s. The three known rows read back on the new Pod. All nine old incarnations stayed retained with unchanged UIDs, the old StatefulSet fenced at zero replicas and the old backup schedule suspended. `nagare-system/nagare-shomei-keys` kept its UID, resourceVersion and data digest, and every other StatefulSet and PVC kept its UID ([evidence](../audits/mp23-implementer-results-2026-10-03/cp3-postgresql-rename-bc2fd90e.json)). The run also exposed two review-reader defects, fixed in `bc2fd90e` (see Surprises). Final-candidate proof remains C2.
- [ ] (MP-23 B5) Companion collection bindings collect only exactly eligible database and broker companions, broker topics and schedules while protected neighbors survive, each with a focused local proof. Database companions done (2026-10-03, implementer, `dc53beb3`, development binary on cp3): reviewed collection now admits StatefulSets (Background propagation), ServiceAccounts, Roles and RoleBindings. A retired standalone PostgreSQL lost exactly its six stateless companions in three dependency-ordered reviews (backup CronJob; StatefulSet and RoleBinding; Service, Role and ServiceAccount). Its PVC and both Secrets stayed retained with unchanged UIDs, a PVC collection was refused at planning, and the neighbors' UIDs were unchanged ([evidence](../audits/mp23-implementer-results-2026-10-03/cp3-companion-collection-dc53beb3.json)). The backup CronJob is the database's schedule; application schedules already collect through `task delete`. Broker companions and topics have no eligible member under the current policy (see Decision Log, 2026-10-03).
- [x] (MP-23 C1) The final candidate passes the installed local platform bootstrap gate on cp3: a verification-only unchanged replan with zero provider mutations and all accepted scope digests unchanged. Passed 2026-10-03 (implementer) for frozen candidate `db808a74`, installed with `nix build .#nagarectl` (`/nix/store/pl52mxv9…-nagarectl-0.4.0`). The public platform bootstrap plan took 39 s and produced 213 `VerifyResource` operations; apply took 55 s. No provider mutation occurred, all 36 accepted scope digests are unchanged, the head is idle at generation 10019, and 71 pods are Ready or Succeeded ([proof](../audits/mp23-implementer-results-2026-10-03/c1-local-gate-db808a74.json)). As before, this is a CLI gate on the retained accepted payload `705716b7`, not a fresh-payload bootstrap; that is C2.
- [ ] (MP-23 C2) In one run on a fresh local context bootstrapped with the final candidate's own payload: platform plus applications A and B with protected routing and auth, PostgreSQL, a broker topic, scheduled and one-off Jobs, a preview, Runtime/Preview/Secret channels and image publication converge; an app-only update preserves the other owner's and the platform's revisions; and an unchanged replan performs zero writes.
- [ ] (MP-23 C2) In that same run: interruption at each stage resumes without duplicate effects; a wrong-incarnation destination is refused; PostgreSQL, Redis, ClickHouse and a volume restore into isolated targets with checked content through MinIO; content is recovered with the source cluster unavailable; the private history export restores into an isolated state root with identical accepted identities; the PostgreSQL rename and companion collection pass.
- [ ] (MP-23 C2) The run's evidence directory is accepted by `scripts/assemble-inventory-release-index.py` for the final candidate revision, with private exports and credentials kept out of it.


## Surprises & Discoveries

Condensed in-force findings; dated detail is in [the snapshot](../audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md).

On the macOS workstation, AirPlay intercepts host port 5000, so host tools cannot reach the fixed k3d registry directly, although Docker and the k3d node can. Publication uses a loopback SSH forward into Colima with `skopeo`, which preserves the reviewed manifest digest; `docker load`/`docker push` rewrites the digest and was rejected. The registry health probe observes the registry from inside its container.

The pinned upstream MinIO server and client images are no longer pullable (Quay 401, Docker Hub refusals, legacy download host 410). `scripts/publish-local-minio-images.sh` builds local images from the upstream GitHub release binaries after checking their published SHA-256 digests; the local-object-store compiler accepts both overrides only together and only as exact `k3d-registry.localhost:5000/nagare-{minio,mc}@sha256:...` references.

The default four-GiB Colima VM cannot hold the full platform plus applications; a six-CPU, 12-GiB profile can. That profile is `nagare-mp23-cp3`. The installed kubeconfig uses `local` as context and cluster alias while k3d's physical cluster is `k3d-nagare-local`; the local runner checks the API server and CA against k3d's kubeconfig and records both names.

F30 (controller status churn strands an admitted Service correction) was first observed on cp3, not in the cloud ([evidence](../audits/mp23-independent-results-2026-10-02/application-status-race-f30.json)). The independent correction under source fixes `95b58a24`/`52432400` landed on the original Service UID and was then interrupted at the operator's instruction; its transaction `tx-b4da295e…` remains active at head generation 9314/sequence 9210 on the cp3 `local` store ([handoff](../audits/mp23-independent-results-2026-10-02/application-status-race-f30-handoff.json)). The Service UID in that handoff matches the local F30 record.

The release gate requires exact check names in `local-health.json`; a producer that emits different names is refused at assembly even if the behavior passed (MP-23 A5 addresses the analogous clone-free mismatch). The gate also rejects any fixture key matching its sensitivity pattern, including a key spelled like the `secret-read-refusal` check, so the scenario fixture lists assertions as objects with `name` values.

2026-10-03 (B5 rename): Two readers assumed every Kubernetes review member is a base mutation. Both migration bundles and the native run exposed it. `kubernetesSpecsFromReview` refused the saved rename review before admission: nothing was admitted and every UID was unchanged. Review publication stored no observation bytes for migration stages, so after convergence `inventory status` failed context-wide. cp3 was recovered with the public `inventory store materialize-native`, which only adds digest-addressed bytes (head generation unchanged at 9563). Both readers now take the destination object from the bundle (`bc2fd90e`). The end-to-end test had bypassed the CLI's spec reconstruction and observation loading; it now exercises both.

2026-10-03 (B5 rename): A migrated-away incarnation keeps the live ResourceId, so reviewed collection cannot select it (`active-incarnation`). Rather than leave a backup CronJob firing against a fenced database, the rename fences writers. Their fenced state is observed as the retained incarnation, not as drift. Stored history orders dependencies canonically, so the command's old-name equality check compares dependencies as sets.

2026-10-03: `scripts/check-haskell-architecture.py` already failed at the handoff commit for `Target.hs`, `AppDeploySpec.hs`, `InventoryApplicationSpec.hs` and `InventoryKubernetesSpec.hs`. B5 kept its own files within their allowances by moving the collection request, the migration planner and the fence predicates into separate modules. The pre-existing overages are not addressed here.


## Decision Log

Condensed decisions still in force; the full entries are in [the snapshot](../audits/mp23-archive/plan-history/ep155-before-consolidation-2026-10-02.md).

2026-10-03 (B5 companion scope): "Exactly eligible" means eligible under the lifecycle policy already in force (EP-149, ADR 22): `DeleteWhenUnreferenced`, `Stateless`, a supported kind, and no retained or accepted consumer. A database's stateless companions qualify. Its PVC, credential and signing-key Secrets are `Retain`/`Durable` and stay retained. Broker topics are `Retain`/`Durable` and ordered after the broker StatefulSet, so a retired broker has no collectable member while its topics are retained. Releasing durable data or deleting topics would be a new operation with a new typed release policy, which EP-155 treats as a scope proposal for the MasterPlan and not a missing binding. It is recorded there and not implemented. Collection stays one review per dependency layer, because a candidate counts every retained declaration, including one selected in the same review, as a consumer.

2026-10-03 (B5 rename design): The rename keeps the database's logical identity (pinned scope key) and migrates all nine members under EP-149's contract. It copies the data volume file for file from the fenced old writer into a new PVC with a one-shot Job on the database image, and compares full manifests in both the copy and a separate verify pass, because the new StatefulSet depends on the verified destination PVC and cannot start first. Credentials keep their values, with only the in-cluster host in `DATABASE_URL` rewritten, so the copied data directory still authenticates. The signing key is copied byte for byte, so earlier receipts stay verifiable. The old incarnation is the recovery point and stays retained. Rejected: a logical dump into a running destination (impossible under the dependency order), renaming only stateless members while reusing the PVC (no data migration at all), and relaxing data-policy equality in general (only a credential renamed in the same proposal may differ).

2026-10-02 (consolidation): Rewrite this plan as a current-state document with history moved to the snapshot. No scope, dependency or acceptance change.

2026-10-02 (F34): Knative blocks orphaning a Service's children but not a DomainMapping's. Ordinary Orphan collection of a preview DomainMapping left a KIngress that, hours later, made Envoy reject every gateway update on the whole cluster. Gateway health is therefore a cluster-wide effect of collection correctness, and C2 must include a native DomainMapping collection through the controller-descendant authority.

2026-10-02: Final acceptance binds one frozen candidate. Earlier native runs on cp3 are credited as checkpoints. The C2 run uses a fresh local context carrying the final candidate's payload, because an admitted context cannot change platform version (ADR 6) and the release gate checks that the evidence payload and operator revision match the candidate.

2026-10-02 (critical intranet): Local evidence contributes to EP-159/160's data-protection proof (source-unavailable recovery, known-content restore, recorded recovery time) without inventing an unagreed recovery-time target; D1, D2 and D4 remain operator decisions.

2026-09-29: Cloud integration (EP-156) has scheduling priority over the full local scenario; both remain required for release. Run focused local regressions whenever a cloud assertion needs them.

2026-09-28: Follow the operator-approved MP-23 scope reduction: live database/PVC overwrite, new interactive maintenance (EP-161 cancelled) and scheduled keep-N pruning are deferred and must refuse new admission, while recovery of already-admitted operations stays available. Local proof covers isolated restore only.

2026-09-27: Grow one scenario from the smallest production path (platform, application with database, unchanged replay) and add each assertion to it, rather than building separate fixtures. Use verified local MinIO image overrides rather than a new object-store provider.

2026-09-26: This plan takes over the local integration obligations of EP-150 and the native migration/collection bindings of EP-148 under EP-149's lifecycle contract; both parents are superseded history, not pending gates.


## Outcomes & Retrospective

Delivered so far: the local platform bootstrap gate on cp3, a first platform/two-application/replay production path, independent local isolated restores for Redis, ClickHouse and a volume through MinIO, and independent local release-history and preview cleanup. Several local provider bindings (k3d observation shapes, registry transport, MinIO images, Namespace resolution, release-history replay stability) were repaired along the way. B5 (2026-10-03) added the checked-in scenario fixture, native stateless companion collection and the native reviewed PostgreSQL rename, each with focused tests and a bounded cp3 run. Remaining: the final-candidate runs C1 and C2; collection of durable members, broker topics and migrated-away incarnations is outside the current contract (MasterPlan scope proposal). Lesson: local k3d reproduces Kubernetes-level defects in minutes that cost hours in the cloud, so every candidate passes the cp3 gate first; but evidence spread across many candidates and old payloads still has to be rebound to one candidate.


## Context and Orientation

Nagare describes everything it manages as typed *scopes*: one owner's complete desired resource set with its own revision (the platform, each application, each standalone database or preview). The *inventory* composes all scopes and checks that they do not claim the same resource. `nagarectl` turns a change into an immutable saved *review* that binds the exact native inputs (Kubernetes objects, Helm charts, Pulumi plans); `apply` executes only a saved review, records each operation in a private *journal*, and on interruption leaves a *transaction* that `inventory resume` continues without repeating proved effects. An *incarnation* is one physical instance of a logical resource (a PVC UID, for example); a *receipt* is the signed record of a verified backup. A *candidate* is one source revision built and installed as an immutable `nagarectl` plus its platform *payload*. The architecture and its rules are in [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md); [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside payloads; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) forbids changing an admitted context's platform version, which is why final runs need a fresh context; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) governs route ownership.

A local context (`mode=local`) runs on k3d (Kubernetes in Docker) inside Colima (a macOS Linux VM), with a local registry `k3d-registry.localhost:5000` and MinIO (an S3-compatible object store) instead of GCS; see [local development](../user/local-development.md). **Local checks use only the Colima profile `nagare-mp23-cp3` and run sequentially; never start another profile or use the default one. No GKE cluster is created, selected or used anywhere in this initiative.**

Key files: `scripts/rehearse-local-inventory-release.sh` checks the exact local target (profile, kubeconfig identity, API, Knative webhook, registry, MinIO) and then hands off to the generic saved-review runner `scripts/rehearse-managed-resources.sh` (protocol tested by `scripts/test-rehearse-managed-resources.sh`). `fixtures/inventory-release/local/scenario.json` is the scenario fixture the runner copies to `fixture.json`; its app configs live under `fixtures/inventory-release/local/apps/`, and `scripts/test-local-scenario-fixture.py` validates it. `scripts/publish-local-minio-images.sh` builds the MinIO images. `cli/nagarectl/test/InventoryIntegrationSpec.hs` injects loss at each operation in a synthetic multi-scope scenario; `scripts/test-inventory-scope-isolation.py` and `scripts/test-bootstrap-local-public.sh` are reusable public-command probes. Command, planning, execution and history live in `cli/nagarectl/src/Nagare/Inventory/{Command,Plan,Execute,Store}.hs`. The release gate's consumer is `scripts/assemble-inventory-release-index.py`. Open findings and their owners are in [the findings tracker](../audits/mp23-findings.md); retired fixtures are described in [the fixture disposition](../audits/mp23-prerelease-fixture-disposition.md).


## Plan of Work

**Milestone 1 — scenario fixture and missing bindings (MP-23 B5).** Extend the checked-in local fixture from a health definition to the full scenario: platform plus applications A and B, protected routing and auth, PostgreSQL with backup, a broker topic, scheduled and one-off Jobs, a preview, Runtime/Preview/Secret channels and image publication, with known rows and files seeded for every data store. Agree the evidence shape with EP-157 so the runner emits exactly the required check names. Implement the bounded retained PostgreSQL rename as real native work under EP-149's lifecycle contract: one retained database with a stable logical identity and known rows is created under its new name, migrated, verified, and the old incarnation retired, while an unrelated auth signing key keeps its identity. Enumerate the coverage catalogue's eligible database/broker companion, topic and schedule cleanup cases and implement each missing native binding; preview and release-history cleanup are already proven. A missing binding is implementation work here; a new provider or operation is a scope proposal for the MasterPlan. Prove each piece with a focused local test or a bounded cp3 run before moving on.

**F34 recovery (cp3; written 2026-10-02 before any cluster change).** Diagnosis, read-only. Envoy admin (`config_dump`) on the Kourier gateway shows the rejected `listener_8443`/`listener_9443` update listing `mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` in two filter chains: the namespace wildcard-secret group and its own per-host chain. The host belongs to KIngress `personal/mp23-cleanup-pr-review.personal.127-0-0-1.sslip.io` (UID `e11d734a-18e8-403d-af49-35afb38e0a03`). That KIngress has no owner references, a `serving.knative.dev/domainMappingUID` label equal to the tombstone's physical identity `7c6ab388-f637-4ee3-9952-46ff019670cd` for collected resource `standalone:site-preview-mp23-cleanup-pr-review/route/route` (review `faf69cf3…`), and splits to the deleted Service `mp23-cleanup-pr-review`. Its sibling KCertificate (UID `8255d8d4-7ef7-4c67-af52-a5dd9218cdf8`, also ownerless) owns cert-manager Certificate `4eafd551…`, which owns CertificateRequest `14854d53…`. Cause: `collectionDeleteRequest` in `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` deletes DomainMappings with `propagationPolicy: Orphan`, and preview cleanup uses descendant collection only for Knative Services. The stale route keeps programming the shared gateway. When the F30 Service joined the wildcard-TLS group, the generated listener became invalid and Envoy refused every later snapshot.

Steps and gates, in order; a failed gate stops the sequence:

1. Source fix (no cluster change). Collect a DomainMapping together with its exclusive controller descendants (KIngress, KCertificate and its cert-manager chain) through the reviewed controller-collection authority, and make preview cleanup use it for DomainMappings. Gate: a regression proves the authority accepts the observed DomainMapping graph and refuses a shared, foreign or independently inventoried child; the full `nagarectl` suite and `just haskell-style-check` pass.
2. Fixture repair (cp3 only). Delete exactly the orphaned KIngress `e11d734a…` and KCertificate `8255d8d4…` with UID and resourceVersion preconditions and Background propagation, so the cert-manager chain is garbage-collected. These objects are uninventoried leftovers of an already-collected parent; no product supports this disposal, and it is recorded as a one-time fixture repair, not operator procedure. Before the delete, re-check: no owner references; the label equals the tombstone physical identity; the route target Service is absent; UID and resourceVersion are unchanged. Leave the unowned TLS Secret alone. Do not touch the shared wildcard certificate, Kourier objects or history. Gate: within 60 s Envoy shows no `error_state` on 8443/9443, the active listeners carry `mp23-correction-proof.personal.127-0-0-1.sslip.io`, the previously Ready routes stay Ready, and KIngress `mp23-correction-proof` reports `Ready=True`.
3. F30 resume. Run the public `inventory resume tx-b4da295e… --yes` with the admitting binary and isolated root. Gate: the transaction completes with no active transaction; Service UID `470ff139…`, PostgreSQL `03a23352…` and PVC `15138d3a…` are unchanged; the known row `1|mp23-original-data-before-correction` reads back; an unchanged replan plans no provider effect. Any refusal stops here and is recorded.

**Milestone 2 — final-candidate local run (MP-23 C1, C2).** When the frozen candidate exists, pass C1 on cp3, then create a fresh local context there bootstrapped with the candidate's own payload and run the whole scenario through the runner's plan/apply/verify phases: convergence, app-only isolation, unchanged replay, interruption at each real stage (database readiness, migration, cluster completion, final marker) with resume and no duplicate effect, wrong-incarnation refusal, isolated restore of all three engines and a volume with content checks, source-unavailable recovery from MinIO with the source cluster inaccessible, private history export restored into an isolated state root, the rename and companion collection. Consume EP-159's receipts, EP-160's isolated restore, EP-158's access commands and EP-153's deferred-route refusals rather than re-implementing them. Before the existing cp3 cluster is replaced, the preserved F30 transaction must reach a terminal state through the supported resume path (MP-23 A4, owned by EP-153/156); do not discard it by deleting the cluster.


**Milestone 2 execution plan (prepared 2026-10-03, read-only; nothing below has run).** Owner: session nagare-phase-b. C1 and C3 belong to nagare-f3.

*Inputs and gates.*
- Candidate CLI: `result-mp23-db808a74/bin/nagarectl`, revision `db808a74`, with its packaged payload.
- C2 starts only after nagare-f3 reports that C1 passed on this candidate. Every cp3 mutation runs under the claim protocol (`/private/tmp/nagare-mp23-cp3.1EQ78L/.cp3-claim`).
- Every command runs with `env -i` through a wrapper for the fresh root, the same way the existing `runctl-*.sh` wrappers work.
- Stop and report on any guard refusal. Name the expected progress and time budget before each phase. A phase that runs 15 minutes past its budget gets a diagnostic checkpoint.

*A fresh context needs the existing cluster retired first.* A second k3d cluster cannot coexist on cp3:
- The payload's `cluster/bootstrap/local-substrate.json` fixes the cluster name `nagare-local`, the registry `k3d-registry.localhost` and host ports 80, 443 and 5000.
- Only the `nagare-mp23-cp3` Colima profile may be used.

Memory is not the limit: the VM has about 7.7 GiB available with today's platform running.

No reviewed teardown exists for an admitted local substrate. `just local-down` refuses after admission, `context delete --save-plan` removes only the profile, and `InfraDestroy` is the cloud route. So retiring the old cluster is the deliberate, exact step this plan's Idempotence section anticipates. It runs only with the operator's explicit approval, because it is hard to reverse and the cluster is shared with nagare-f3. Phase 0 sequence:
1. Confirm that the `local` store has no active transaction (after C1).
2. Run `inventory export --out /private/tmp/nagare-mp23-cp3.1EQ78L/exports/local-pre-c2-<UTC>` (private). Save `inventory status --json` beside it.
3. Copy the registry images the fresh bootstrap needs, by digest, with `skopeo copy` through the loopback forward into an OCI layout under that root. The images are `en`, `shomei`, `nagare-access`, `nagare-minio` and `nagare-mc`, at the digests pinned in `runctl-b805d64a-independent.sh`. `skopeo` preserves manifest digests; `docker push` does not.
4. Run `k3d cluster delete nagare-local`, then `k3d registry delete k3d-registry.localhost`, with `DOCKER_HOST` set to the cp3 socket.

The old operator root, its journals and the export are kept, and the old context is never revived. Its in-cluster MinIO objects are lost with the cluster. They belong to retired checkpoint evidence, and their receipts remain in the export.

*Phase 1 (budget 30 min): fresh bootstrap with the candidate payload.*
1. Create a new root, `/private/tmp/nagare-mp23-c2-db808a74.XXXXXX`, with its own XDG config, state and cache, a new cluster-secrets directory, and the operator's sops age key.
2. Run `context create local --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups`.
3. Run `scripts/run-reviewed-bootstrap.sh` with the candidate CLI (registry and cluster review, kubeconfig review).
4. Re-push the three auth images from the OCI copy, and run `scripts/publish-local-minio-images.sh`. Export `NAGARE_AUTH_{EN,SHOMEI,ACCESS}_IMAGE` and `NAGARE_LOCAL_{MINIO,MC}_IMAGE` with their digests.
5. Plan and apply the platform bootstrap. The 2026-09-30 run took 217 operations and 496 s.
6. Run the local runner's `plan`, `apply` and `verify` phases with a compiled candidate of the platform scopes. Verify writes `no-op-review/` and `final-observation.json`.

*Phase 2 (budget 30 min): scenario resources.* Follow `fixtures/inventory-release/local/scenario.json` steps `data`, `deploy-a`, `deploy-b` and `site`, then seed every store with the fixture's rows, keys and files.

*Phase 3: the checks.* Evidence goes under `$EV/checks/<name>/`, where `$EV` is the runner's evidence directory. Evidence holds public observations only: digests, UIDs, counts and the fixture's non-secret seed values. Each check, once it passes, is recorded with:

```bash
python3 scripts/scenario-assertions.py record --evidence-dir "$EV" --mode local \
  --name NAME --summary "ONE LINE" --evidence checks/NAME/FILE ...
```

- `collision-refusal`: run `app deploy -f apps/scenario-collision/nagare/Config.hs --save-plan DIR`. Expected: non-zero exit with a composition collision on the route host, no review directory, and an unchanged head generation. Evidence: `checks/collision-refusal/result.json` (exit, error code, before and after head).
- `adoption`: create one unowned object at an address a later review will claim (a Redis scratch PVC, as in the EP-160 drill), then plan that restore. Expected: `adoption-required` with no review saved, and `inventory status --json` reporting the object as unowned. Evidence: `refusal.json` and `status-unowned.json`. Delete the created object afterwards.
- `drift-classification`: from `inventory status --json`, the companion collection's retained orphans plus a deliberate field edit on application B's Service, repaired through a reviewed replan. Expected: distinct `retained-orphan` and configuration-drift categories, and the replan restores the reviewed bytes. Evidence: `status-drift.json` and `repair.json`.
- `convergence-noop-removal`: the runner's verify `no-op-review/review.json` (zero operations), plus preview removal through `cleanup --previews --save-plan` with DomainMapping descendants included. Evidence: `no-op-review/review.json` and `checks/convergence-noop-removal/preview-cleanup.json`.
- `independent-scope-preservation`: accepted revisions of `application:scenario-b` and every platform scope, plus application B's Service UID, before and after step `update-a`. Evidence: `before.json`, `after.json` and `diff.json`.
- `secret-read-refusal`: the encrypted value is generated at run time and passed only on stdin. There is no public `secret get`, and `secret list` prints names only. Scan every file under `$EV`, the saved review directories, the status outputs and the export summary for the value. Evidence: `scan.json` (value SHA-256, files scanned, matches = 0) and `secret-list.txt`.
- `interrupted-recovery`: the four stages in the fixture. For each, poll `inventory status --json` until the target operation's intent is recorded, kill the `inventory apply` process, then run `inventory resume TX --yes`. Expected: completion with each created object's UID unchanged, and one intent and one effect per operation. Evidence: `<stage>.json` per stage (transaction, killed operation, UIDs before and after resume, journal event counts).
- `postgresql-backup-restore`: back up `scenario-pg` through MinIO, insert the fixture's `afterBackup` row, restore under a new ID, and read the scratch database.
  - Wrong-incarnation, PostgreSQL (decided 2026-10-03): create the scratch database the next restore targets before applying. Expected: the in-Job `createdb` fails, the existing database has zero writes, and the transaction closes with `abandon-partial-database-restore`.
  - Wrong-incarnation, Redis: a foreign PVC created at the scratch address between plan and apply is refused at preflight, and the transaction ends with `abandon-refused-operation` (F35).
  - Evidence: `seed.json`, `restored.json`, `source-after.json`, `wrong-incarnation-postgresql.json` and `wrong-incarnation-redis.json`.
- `redis-backup-restore` and `clickhouse-backup-restore`: the same pattern with `db backup NAME --backup-id ID --save-plan` and `db restore NAME ID --restore-id ID --save-plan`, reading back the keys or rows. Evidence: `seed.json`, `restored.json` and `source-after.json`.
- `volume-backup-restore`: `storage snapshot scenario-a uploads` and `storage restore` with pins. The restored file is proved by the Job's `NAGARE_VOLUME_RESTORE_FILE` line for `scenario-known.txt`. Evidence: `manifest.txt` and `source-after.json`.
- `source-unavailable-recovery` (decided 2026-10-03, on the disposable C2 cluster only), recorded as "source cluster inaccessible":
  1. Escrow the signing key first with `db escrow-signing-key scenario-pg --output SCRATCH_SOPS_DIR/...`.
  2. Stop the k3d server container and copy the MinIO data out with `docker cp`.
  3. Serve it from a disposable MinIO container and run `db verify-escrowed-backup` against it.
  4. Restore the known rows into a disposable PostgreSQL container.
  5. The C2 store is never mutated while the server is stopped. Afterwards, restart the container and confirm the store is idle.

  Evidence: `escrow.json` (digest only), `verify.json`, `restored.json` and `idle-after.json`.
- `backup-freshness`: `server status` and `db backup-receipts NAME --check-freshness` show healthy rows under the hourly objective for all three databases. Evidence: `server-status.txt` and `freshness.json`.
- `retained-data`: the companion collection (fixture `companionCollection`, with the PVC collection refused), plus history `inventory export` restored with `inventory restore --from PRIVATE --yes` into an isolated state root with identical accepted identities. Evidence: `collection.json` and `history-restore.json` (head digests, scope revisions). The export itself stays private.
- `access-grant-revoke`: `access grant` and `access revoke` on `scenario-a.127-0-0-1.sslip.io` for a test subject ID. Grants are en relationship tuples, so no shomei account or browser is needed; the 2026-10-01 native grant and revoke ran the same way (archived EP-158 snapshot). Observe each with `access list`. Browser login over HTTPS remains a stated restriction (D3). Evidence: `grant.json` and `revoke.json`.
- `retained-postgresql-rename`: fixture step `rename`. Evidence: `rows.json`, `uids.json` and `unrelated-identity.json`.

*F36 native proof (EP-160 record, not a gate check).*
1. Back up a throwaway Redis, then save its restore review.
2. Delete exactly the pinned archive version with a throwaway `nagare-mc` Pod, then apply.
3. Expected: the scratch StatefulSet's container exits non-zero, apply stops, and `inventory recover TX --operation OP --decision FILE` (version 1, `abandon-partial-database-restore`) closes the transaction with the scratch objects left unaccepted.

*Phase 4 (budget 20 min).*
1. Run the runner's `verify` with `--private-store-export`.
2. Run `python3 scripts/scenario-assertions.py finalize --evidence-dir "$EV" --mode local`.
3. Run `scripts/assemble-managed-resource-evidence.sh --release-manifest FILE --system aarch64-darwin --rehearsal-dir "$EV" --private-store-export PRIVATE --coverage-result FILE --output "$EV/inventory-evidence.json"`.
4. `finalize` revalidates every bound record against the plan-time health and `fixture.json`. Full `scripts/assemble-inventory-release-index.py` assembly also needs the cloud directory, both native outputs and the coverage result, so it is EP-157's C5 step and is not claimed here.

Results go in this plan and in a dated implementer results file.

## Concrete Steps

Run from the repository root inside its development shell. Focused checks first:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-option=-p --test-option='/inventory integration/' --test-show-details=failures
bash scripts/test-rehearse-managed-resources.sh
bash scripts/test-bootstrap-local-public.sh "$INSTALLED_NAGARECTL"
python3 scripts/test-inventory-release-index.py
python3 scripts/test-local-scenario-fixture.py
cabal test nagarectl-test --project-dir=cli/nagarectl --test-option=-p --test-option='/PostgreSQL rename/' --test-show-details=failures
cabal test nagarectl-test --project-dir=cli/nagarectl --test-option=-p --test-option='/companion collection/' --test-show-details=failures
```

The native run uses only `nagare-mp23-cp3`, an isolated operator root, a compiled candidate directory and a new evidence directory:

```bash
: "${NAGARE_TEST_CONTEXT:?exact disposable local context}"
: "${NAGARE_TEST_CLUSTER:?exact k3d cluster, e.g. k3d-nagare-local}"
: "${NAGARE_TEST_EVIDENCE:?new evidence directory}"
: "${NAGARE_TEST_CANDIDATE:?compiled candidate directory}"
bash scripts/rehearse-local-inventory-release.sh --phase plan --context "$NAGARE_TEST_CONTEXT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE" --candidate "$NAGARE_TEST_CANDIDATE"
bash scripts/rehearse-local-inventory-release.sh --phase apply --context "$NAGARE_TEST_CONTEXT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE" --yes
bash scripts/rehearse-local-inventory-release.sh --phase verify --context "$NAGARE_TEST_CONTEXT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE" --candidate "$NAGARE_TEST_CANDIDATE" --private-store-export "$PRIVATE_EXPORT_DIR"
```

Expected: focused checks exit zero; an unhealthy fixture stops before any review is published with a named blocker; apply refuses without the saved review and `--yes`; verify writes the four evidence files. Before each costly run, name the assertion, expected progress and time budget; an unmeasured path gets a diagnostic checkpoint after 15 minutes, and a second identical failure stops dependent work until the cause is known.


## Validation and Acceptance

The plan is accepted when, for the final candidate revision, `local-health.json` reports healthy with the candidate's operator revision and a fixture digest matching `fixture.json`, and its checks include every common name the gate requires — `collision-refusal`, `adoption`, `drift-classification`, `convergence-noop-removal`, `independent-scope-preservation`, `secret-read-refusal`, `interrupted-recovery`, `postgresql-backup-restore`, `redis-backup-restore`, `clickhouse-backup-restore`, `volume-backup-restore`, `source-unavailable-recovery`, `backup-freshness`, `retained-data`, `access-grant-revoke` — plus the local-only `retained-postgresql-rename`; and `scripts/assemble-inventory-release-index.py` accepts the directory. Behaviorally: review membership equals executed effects; app B's and the platform's revisions survive app A updates; the unchanged replan writes nothing; restored rows and files match the seeded content while sources keep later changes; foreign or wrong-incarnation inputs refuse; a failed run never prints success. Public evidence contains only digests and observations; private exports and native plans stay private. Passing inherited tests is regression evidence, not proof of a new outcome.


## Idempotence and Recovery

Work against isolated operator roots and exact named contexts. Preserve immutable reviews and journals after interruption; resume or explicitly recover the same transaction rather than regenerating a changed review or retrying effects blindly. An unknown provider result is not absence. Never clean up by namespace, prefix or broad label because a test failed; disposal of the fixed-name k3d cluster and registry is an exact, deliberate step after any active transaction there is terminal and its private history is exported. Never reset history or patch a provider to manufacture a result. This plan authorizes no release publication. Do not search or read `/nix/store`; inspect sources through the checkout and Mori.


## Interfaces and Dependencies

Hard prerequisites EP-146, EP-147, EP-149 and EP-151 are complete. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies fresh bootstrap; [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) supplies installed candidates; [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) supplies command coverage, deferred-route refusal and the F30 fix (A4); [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md) and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) supply access, receipts/freshness and isolated restore. Their working commands, not their administrative closure, are what this plan needs. EP-156 reuses this scenario's definitions; EP-157 consumes the local evidence directory, passed to `scripts/assemble-inventory-release-index.py` as `--local-dir`, which must contain `target.json`, `fixture.json`, `local-health.json` and `inventory-evidence.json`; the assembled index lands under `docs/release-evidence/<revision>/`.


## Revision Notes

2026-10-02: Consolidated with MP-23; history in the snapshot.

2026-10-03: B5 implemented: scenario fixture, companion collection, PostgreSQL rename; recorded the review-reader defects and the collection scope boundary.
