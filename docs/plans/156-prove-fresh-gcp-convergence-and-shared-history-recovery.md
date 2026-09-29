---
id: 156
slug: prove-fresh-gcp-convergence-and-shared-history-recovery
title: "Prove fresh GCP convergence and shared history recovery"
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
      at: 2026-09-28T15:02:11Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
---

# Prove fresh GCP convergence and shared history recovery

This ExecPlan is a living document for remaining work transferred from EP-150.


## Purpose / Big Picture

**NO GKE.** This plan uses a Nagare NixOS VM in GCP Compute Engine running k3s, as declared in infra/pulumi and nixos/hosts/nagare-01/k3s.nix. Do not create, start, use, authenticate to, select, or request access to a GKE cluster. No existing GKE context is this plan’s fixture. Cloud fence/controller identity and GCS-history evidence belong here on the actual Nagare stack and do not gate EP-160 M1.


A production-shaped disposable GCP context proves reviewed cloud/host/cluster/application convergence, shared GCS ownership history, recovery, and exact cleanup while preserving standing project resources. This supplies cloud behavior that neither local Kubernetes nor recording adapters can establish.


## Progress

2026-09-28 scope update: no milestone is newly accepted by this edit. Use the revised MP-23 support boundary; historical findings retain their observations but do not reinstate deferred live overwrite, maintenance, or scheduled-pruning requirements.


- [ ] M1: An exact disposable fixture has complete reviewed creation/cleanup membership, then converges through the public installed operator using GCS inventory history.
- [ ] M2: No-op replay, interruption/host recovery, two-state-root history recovery, data preservation, and exact owned cleanup pass and produce redacted evidence.

2026-09-28 preparation: refreshed `gcloud` and application-default credentials passed read-only checks for `tan-ng-labs`. The standing VM `nagare-01`, node account, registry, `labs.topagentnetwork.net.` zone, and four Nagare buckets remain present. The previously proposed `ep150` fixture names remain absent. A fresh `ep150-preview` context was created only in `/tmp/nagare-mp23-ep156/{config,state}`. Its current bootstrap foundation review is `/tmp/nagare-mp23-ep156/bootstrap-review-isolated`, digest `160eb40b6c63b9314d6b1e53340991b6845d0aeb8ddb7d1cb6919f6b62be4ab6`: two creates, for `tan-ng-labs-ep150-pmkjjpp-state` and the `ep150-preview` Pulumi stack; no project-API or standing-resource write. Nothing in that review has been applied. It is a private development review, not yet the complete M1 creation/cleanup review.

The first attempt exposed two boundaries. The foundation compiler treated already enabled shared-project APIs as newly owned, causing `unverified-owner` refusals. It now excludes only exact already-enabled APIs lacking accepted ownership, retains accepted service declarations, verifies all required APIs before considering foundation ready, and removes dependencies on excluded service declarations. A public fake-provider test covers both a fresh project (nine foundation operations) and an already enabled shared project (two). The workstation also exports active `labs` values that overrode the selected disposable profile during planning: the discarded `/tmp/nagare-mp23-ep156/bootstrap-review` named standing buckets, domain, and VM. The isolated review was generated with `env -i`, retaining only `HOME`, `PATH`, the selected XDG roots, and the exact GCP project. The fixture runner must enforce that isolation and assert the physical names in every saved review before any apply.

A current isolated Pulumi perimeter preview then proposed 27 creates and zero updates/deletes, but the missing context field for node `serviceAccountId` left the physical account at the standing `nagare-node`. The context profile now carries `NAGARE_SERVICE_ACCOUNT_ID`, `context create` accepts `--service-account-id`, and foundation seeding writes `nagare:serviceAccountId`. The corrected private foundation review is `/tmp/nagare-mp23-ep156/bootstrap-review-service-account`, digest `1f5239bf9b955cd2733cc81d7340a98437805447f3af5f3fdbbb13a2988e26d0`. A new isolated local-backend Pulumi preview at `/tmp/nagare-mp23-ep156/current-perimeter-service-account-v3.plan`, digest `6cadc196d21d941ef403572df029c7086e7ce936498c661936c6ffa8b349978a`, still proposes 27 creates and zero updates/deletes; its node account is `nagare-ep150`. These are preparation artifacts only. A `context create --force` attempt before the state bucket exists refused its unavailable-bucket ownership probe, so the unadmitted private context file was updated directly before regenerating reviews. The runner should create the exact profile once, before its first GCS review.

The checked-in `fixtures/inventory-release/gcp/ep150-target.json` fixes project, region/zone, context, VM, service account, registry, three disposable buckets, base domain, parent zone, and expected physical cluster. `scripts/rehearse-gcp-inventory-release.sh` now runs bootstrap `plan` without a Kubernetes API, saves the immutable review and operator identity, and reserves `apply --yes` for that saved stage; after bootstrap it delegates candidate plan/apply/verify to the generic runner using only the selected context's generated kubeconfig. An initial read-only run produced `/tmp/nagare-mp23-ep156/runner-bootstrap-review` with only the exact state bucket and stack operations while the ambient shell still contained standing `labs` values. Its later candidate path and the complete cleanup side remain unproven.

2026-09-28 live foundation checkpoint: `/tmp/nagare-mp23-ep156/runner-bootstrap-review-v2` applied its saved two-operation review. The bucket create completed, but stack creation was ambiguous because a local preview had left an incompatible passphrase salt in the same private Pulumi config path. The bucket was observed under project number `882581411903`, `US-WEST1`, with versioning, uniform access, and public-access prevention. The stack was absent, and journal sequence 4 identified only its stack operation as ambiguous. After backing up and clearing that preview-only config, `inventory resume tx-6ed029bcd26a9ac95d5506abb5bf7bc7b2acfedb5619781d1c1cfe2fcb9f1cbc --yes` against the original local foundation store converged without repeating the bucket create. The original local history then migrated with `inventory store migrate --to gcs --yes`. A fresh process read GCS head digest `1fc411233368f3b34035640976cd2d8a34717ca964a7f0d14d358e0570871386`, generation 18, with no active transaction; the source local head has a migration tombstone. The GCS Pulumi stack has zero resources and config pins `tan-ng-labs`, `ep150.labs.topagentnetwork.net`, `nagare-ep150` VM/account, disposable buckets, and `manageProjectApis=false`. This proves the first state-bucket/stack/history migration, not M1 perimeter or M2 second-root recovery. The runner now refuses a new-stack review if a nonempty Pulumi config predates creation.

The next bootstrap plan initially proposed an unnecessary Pulumi stack update whenever source workspace paths changed. The stack's desired-state digest included the local Pulumi program and home paths, which are execution locations rather than cloud configuration. The adapter now hashes only project, stack, backend, backend bucket, and config for stack desired state, while the retained native plan still pins the executable paths. The accepted old digest required one reviewed transition: `/tmp/nagare-mp23-ep156/runner-foundation-transition-review` converged `tx-c67ec5ebbcefc826fcf8e3617d654f677983a36f8d83ecce6127b03e2f6d8387`, with no bucket, API, or perimeter operation. A fresh plan then reached the Pulumi perimeter. Pulumi's newly initialized stack export omits `deployment.resources`; the runtime now treats that exact case as empty while rejecting malformed resource shapes. A targeted first preview also creates Pulumi's implicit stack record; validation now recognizes only the exact selected stack record and still rejects a foreign stack mutation. The focused cloud tests pass.

`/tmp/nagare-mp23-ep156/runner-perimeter-root-review-v4` contained only the Pulumi component-root create. Its saved-plan apply created the implicit stack record and component root but returned ambiguous when an unselected DNS IAM child reported a changed dependency. Exact stack export then contained only those two bookkeeping resources and a provider record; no GCP child resource. `inventory resume tx-1730d0678f5e6a74d1ee17bcb233a1a0bedbd73c96ed1c63db3485eeea2699ca --yes` proved the retained operation complete and converged the original GCS transaction. The next candidate proposed nine component roots in separate saved plans against the same starting stack; applying that review could stale later plans, so it was not applied. A serialized one-registration review for `nagare-network` then created only that component record, returned the same unselected-child dependency failure, and converged on same-transaction recovery as `tx-a6e7be16a947ecd3663ea1c30e07471e159847b2f56b9ae417943db43975def5`. These two runner stages were reconciled to applied only after fresh GCS heads showed no active transaction.

Pulumi plans are stack-wide snapshots even when `--target` is supplied. The planner now groups new Pulumi resources of one scope into one inventory operation and one saved native plan. The cloud stage presents the whole selected catalog, with all already accepted members retained. A focused planner test proves two sibling creates are bound to one operation. `/tmp/nagare-mp23-ep156/runner-perimeter-coherent-v1` contained one operation with 22 new resource registrations, exactly 22 creates and no update/delete in its retained Pulumi steps. Private plan inputs named only the disposable `ep150` buckets, zone/records, service account, registry, network/firewall, address, disk, snapshot schedule, and IAM members; this excludes later image-enabled VM resources. Its saved apply converged `tx-a520eebd987cd71b915233fee8e33270821af17b7dcb1ebc1d223a7cd3ec7c77` after Pulumi no-change verification. Fresh GCS head generation 48 has no active transaction and cloud scope revision 3. Read-only provider checks found the new `nagare-zone-a2c6a65` at `ep150.labs.topagentnetwork.net.`, network `nagare-network-net-a1fefd3`, versioned backup bucket, and exact service account `nagare-ep150@tan-ng-labs.iam.gserviceaccount.com`.

The new zone returned `ns-cloud-c1.googledomains.com.` through `ns-cloud-c4.googledomains.com.`. The standing parent zone `nagare-zone-89da8ae` had no existing `ep150.labs.topagentnetwork.net.` record. An exact reviewed Cloud DNS transaction added one NS record with those four values and TTL 300; its only other change was the automatic parent SOA serial increment from 1 to 2. Change 41 is done, and a fresh parent-zone read returns the exact NS values. Cleanup must remove only that NS record with its observed values and allow the corresponding SOA serial increment.

The next bootstrap plan could not evaluate the image because the isolated context had no generated host flake directory; the `nix` spawn failure was its absent working directory, not a missing Nix executable. Public `host init` then installed `/tmp/nagare-mp23-ep156/config/nagare/hosts/ep150-preview` for host/VM `nagare-ep150` using the operator's public SSH key, a new private age key, and a separately sops-encrypted `tailscale/authkey` placeholder. This is enough to evaluate the image but not a working Tailscale credential or host readiness proof. `/tmp/nagare-mp23-ep156/runner-image-build-review-v2` is a saved ArtifactExecutor image-build review, but must be regenerated after replacing the placeholder in the encrypted host input.

The isolated second operator root read the shared GCS head directly without a copied journal: generation 48, digest `da1d593da4b12d3a8e631c694cae6815c662ab7cc8fce86969e314e315f8cadc`, no active transaction. It exported the full private store to `/tmp/nagare-mp23-ep156/second-root-export` (73 manifest members), then `inventory restore --yes` accepted that export into a fresh local third root bound to the same context and project. A fresh `inventory store status --json` on the restored root returned the identical generation and digest, no active transaction, and local store kind. Repeating `restore --yes` into that occupied root refused with `StoreConditionFailed "restore requires an empty inventory store"`. This proves history portability, binding validation, and occupied-destination refusal; writer conflict/takeover and subsequent provider recovery remain open.

The operator authorized a single-use, ephemeral Tailscale auth key for this disposable host. The key is sops-encrypted in the isolated host input; its plaintext fixture file was removed, and the generated host flake was reinitialized with that encrypted secret. The fresh `/tmp/nagare-mp23-ep156/runner-image-build-review-v5` selected exactly one image `BuildJobArtifact` create for `/nix/store/fmnpm9vffi08vicp95yz1kp7p7qcqj7n-google-compute-image`, digest `70dfa6e66e729362adb39628b2c68ebe1320dbdec839a48f1a4d14e27dc633c9`. Its original transaction `tx-7043b038a3692105177f6442e7dada4deccb084f5ab4ce6b96b8fb92d9bbde0d` initially remained active after ambiguous remote-build attempts; it was never replaced by a new image review.

The named x86 builder `nix-builder-ep150` was provisioned in the same project with its own `nix-builder-ep150-net`, `nix-builder-ep150-subnet` (`10.152.0.0/24`), and `nix-builder-ep150-iap-ssh` (TCP 22 from IAP only); all four names were absent before creation. A separate mode-0600 operator key was added only to this VM's instance SSH metadata because `/etc/nix/builder_ed25519` is readable by the root Nix daemon but not the CLI user. Direct SSH and `nix store info --store ssh-ng://` then passed. The subsequent distributed build still failed to start an SSH master because the daemon does not inherit the caller's ProxyCommand configuration. A tiny x86 derivation built and copied back through an IAP loopback tunnel with an explicit SSH host key. `scripts/upload-images.sh` now creates that daemon-accessible transport for real builds, with an external pinned-tunnel mode for focused tests; the saved original transaction is being retried with a fixture-only transport shim, so its reviewed artifact path and inventory identity stay unchanged. Full image, host, k3s, and cleanup proofs remain open.

The shimmed full image run then built all intermediate system derivations and reached the GCE image derivation. Nix refused only that final derivation because it requires `kvm`, while the builder specification omitted that feature. On the exact fixture VM, `/dev/kvm` is mode `0666` and the builder user can read and write it. The builder specification now advertises `kvm` in both the legacy inspection spec and the daemon-accessible tunnel spec; the focused script test passes. The next same-identity resume built the final image on that VM, copied the output back, and passed the artifact adapter's post-build observation. GCS journal sequence 38 records "operation completion verified" for the exact build operation; sequence 39 records "transaction converged". The CLI returned success. Fresh GCS head generation 74, sequence 40 has no active transaction and has matching accepted/converged `Platform/host-image-build` revision 1 (`3f809745e315bf91719283a1552e7ee2c4d5b485533f2a1922c44a348f0afbdc`). A direct `scripts/upload-images.sh --build-only` run without the fixture shim then opened and cleaned up its own pinned tunnel and reported `nagare-build present` for the exact reviewed path and digest. This proves the image build and recovery, not GCE image publication, host readiness, k3s, or cleanup.

Validation after stack-plan grouping: the complete 925-test CLI suite, style scan, and updated public foundation/bootstrap fixture pass. The fixture now verifies one saved 24-resource Pulumi foundation plan, same-transaction lost-ack recovery without repeating its write, a grouped component+VM plan, image and host stages, and the 211-operation cluster review. The real GCS run supplies provider evidence beyond that recording fixture.

Inherited baseline: EP-150 prepared a 27-create, zero-update/delete/import Pulumi preview and unique names in tan-ng-labs. That preview is historical and never applied. The separate state bucket and parent-zone delegation were not covered by those 27 creates. Regenerate current native plans; do not replay a stale /tmp artifact.


## Surprises & Discoveries


Current implementation findings are recorded in Progress. The state bucket, stack foundation, grouped perimeter, and exact parent-zone delegation are applied; the reviewed NixOS image build is converged. GCE image publication, the VM, host/cluster readiness, and the exact cleanup review remain.


## Decision Log

2026-09-28: Align with the operator-approved MP-23 reduction and ADR 22 amendment. Keep complete evidence for supported behavior and explicit guards/recovery compatibility for deferred routes. EP-161 is Cancelled and no longer a completion dependency; earlier full-feature decomposition instructions are superseded.

2026-09-27: The operator explicitly prohibits GKE. Retain the existing GCP Compute Engine/NixOS/k3s target and own its native fence/controller/GCS evidence without making it a prerequisite for EP-160’s local shared-contract milestone.

2026-09-26: Redirect unfinished EP-148 dependencies to EP-158–161 and preserve this plan’s assigned integration, package, or release obligations. EP-148 is superseded history, not a pending completion gate.


2026-09-26: Carry forward completed EP-150 implementation and give this remaining outcome its own acceptance boundary. The split changes ownership and tracking, not the required functionality or proof.


## Outcomes & Retrospective


Remaining-work plan created; no new acceptance run has been performed. Inherited capabilities are credited in Progress and must not be presented as newly completed work.


## Context and Orientation


This plan replaces part of [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md); its 2026-09-25 implementation is already present. A scope is one owner's desired resource set. The inventory composes all scopes; an immutable review binds exact native inputs, and a private journal records verified operation receipts. Completion of one scope must not change another owner's revision. cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the shared command service; Plan.hs, Execute.hs, and Store.hs in that directory own review, execution, and history. Public evidence must exclude reusable credentials and private native plans.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires complete ownership and reviewed effects. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) permits this first release to start with fresh contexts while rejecting in-place platform version changes after admission. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps operator state outside immutable payloads. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable release evidence. The operator's 2026-09-28 MP-23 decision reduces the supported feature set while retaining full validation, typed ownership, and cross-tool journal/state. General live overwrite, new custom interactive mutating maintenance, and generalized scheduled pruning are explicitly deferred. Refusal does not complete a retained feature; deferred routes need tested admission guards and recovery compatibility. Earlier no-reduction instructions are superseded.

scripts/rehearse-gcp-bootstrap.sh, scripts/rehearse-managed-resources.sh, infra/pulumi/index.ts, infra/pulumi/src/components/NagarePerimeter.ts, cli/nagarectl/src/Nagare/Inventory/Cloud.hs, Host.hs, and Store/Open.hs provide existing integration surfaces. The standing tan-ng-labs project contains nagare-01, nagare-node, the nagare registry, standing state/data/cache buckets, and labs.topagentnetwork.net. The prior proposed fixture used nagare-ep150 and ep150.labs.topagentnetwork.net with separate ep150-pmkjjpp bucket names. These are discovery leads, not authorization to reuse names without checking current state. The operator selected tan-ng-labs but required standing resources preserved.


## Plan of Work

**Revised provider boundary (2026-09-28).** Run the supported receipt/isolated-restore paths and EP-153 deferred-admission guards. General scheduled-prune, live-overwrite, and new interactive-maintenance cloud matrices are removed. Keep real GCS conditional history, exact backup-object generation checks, interruption recovery, Compute Engine/NixOS/k3s, and existing supported manual pruning. Recovery of retained old records may use isolated fixtures and the shared store; it does not require creating new deferred operations. No candidate external backup tool is selected or installed by this plan.


M1 finishes the fixture under fixtures/inventory-release/gcp/ and supplies scripts/rehearse-gcp-inventory-release.sh as a thin composition of existing public commands and the generic phase protocol. Bind exact project, region/zone, VM/service-account/registry/bucket names, state backend, domain, and native cluster identity. The runner separates pre-cluster preparation from the generic Kubernetes-backed rehearsal; it must not require a reachable API before the reviewed host/cluster stage creates one. Fresh bootstrap must review the state bucket before migrating from local history to the context GCS prefix. Include the exact parent-zone NS delegation and its cleanup decision; suppress duplicate ownership of enabled project APIs using the existing manageProjectApis option. Prepare and inspect current plans for zero unintended standing-resource changes. Inherit prior authorization where it covers the exact resources, and request only any genuinely missing bounded mutation authorization after concrete creation/cleanup reviews exist.

Run the installed candidate through actual cloud foundation, guarded NixOS activation, cluster bootstrap/auth/cache, and the application/data scenario established by EP-155. Include live Google DNS/CDN host ownership against the accepted platform backend and preserve shared routing. The existing approved offline-only Cloudflare proof remains sufficient for that provider; do not ask again for a nonexistent disposable zone.

M2 exercises a safely injected acknowledgement interruption at real provider boundaries with retained reviews and receipts. Proven work is skipped; ambiguous outcomes use explicit recovery. Verify the guarded host's post-activation readiness and rollback/self-reversion contract, not only SSH exit. A second isolated operator state root reads shared history and cannot steal an active writer; explicit takeover/recovery follows the existing contract. Prove cloud registry publication with accepted Build input pins, scheduled receipt ingestion with exact GCS generation/digest checks, isolated database/new-PVC restore integrity, retained-backup preservation and truthful deferred-retention reporting, existing supported manual-prune GCS behavior, and recovery compatibility across state roots for already-admitted records, private history export/restore, app-only isolation, and final no-op behavior. Reuse EP-155 engine-specific native checks where the same candidate and transport behavior suffice; cloud-specific GCS/registry/shared-writer assertions still require this cloud run. Cleanup is a separate exact review that removes only disposable owned objects and the matching delegation, leaving standing neighbors untouched.


## Concrete Steps


Run from the repository root in its existing development environment. Commands for a new runner are explicitly marked as a required interface; implement them before running.

```bash
bash scripts/test-rehearse-managed-resources.sh
bash scripts/rehearse-managed-resources.sh --help
# Required new runner interface; plan first, apply only its reviewed fixture:
: "${NAGARE_TEST_CONTEXT:?exact disposable cloud context}"
: "${NAGARE_TEST_CLUSTER:?exact disposable cluster}"
: "${NAGARE_TEST_PROJECT:?exact authorized project}"
: "${NAGARE_TEST_EVIDENCE:?new public evidence directory}"
bash scripts/rehearse-gcp-inventory-release.sh --phase plan --context "$NAGARE_TEST_CONTEXT" --expected-project "$NAGARE_TEST_PROJECT" --expected-cluster "$NAGARE_TEST_CLUSTER" --evidence-dir "$NAGARE_TEST_EVIDENCE"
```

Expected result: relevant checks exit zero; refused negative fixtures exit nonzero before effects. Native evidence must name the exact candidate and target.


## Validation and Acceptance


The original and post-apply reviews, real receipts, final status, and before/after standing-resource identities prove convergence, no unintended writes, and isolation. The cloud phase reports actual provider proof, never a successful recording substitute. GCS history is authoritative from the second workstation; lost local files do not reconstruct ownership from labels. Restored data hashes/rows and exact retained identities match. Cleanup has evidence of selected-only deletion and cannot broadly destroy the project or current labs context. Publish redacted evidence to EP-157; keep native plans/credentials/private exports private.

Use focused checks during implementation and one relevant full acceptance gate for the coherent outcome; repeat broad checks only after a relevant change or failure. Record candidate source revision, command, fixture identity, observed result, and evidence location. Passing inherited tests is regression evidence, not proof that a newly required outcome exists. Keep Progress checkboxes directly under the Progress heading so Mina can read them. Use partial markers for actual unfinished implementation, never mark a milestone complete merely to improve a percentage.


## Idempotence and Recovery


Work against isolated test state and exact named contexts. Preserve immutable reviews and private journals after interruption; inspect/resume the same transaction rather than regenerate a changed review or blindly retry effects. An unknown provider result is not absence. Never clean a resource by broad project, namespace, or prefix merely because a test failed. No plan here authorizes publication of a real Nagare release. Do not search or read /nix/store; Nix may execute its normal builds, but source inspection uses the checkout and Mori.


## Interfaces and Dependencies


Completed EP-146/147/149/151 provide executors/store. [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md) supplies working fresh bootstrap, [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) the scenario/receipt contract, [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md) native packages, and the delivered EP-148 baseline plus [EP-158](158-complete-reviewed-access-and-cdn-operations.md), [EP-159](159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md), and [EP-160](160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md) required commands. Plan/fixture preparation can start before they close; a successful live local run and working cloud prerequisites gate cloud apply. [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) consumes this evidence. Initial estimate: 8–16 active hours excluding approvals, provider queues, and unfinished feature implementation, low confidence; reforecast after the first complete read-only cloud preview including state bucket and delegation.

## Revision Notes

2026-09-28: Align with the reduced MP-23 contract; retain complete supported cloud and shared-state evidence.
