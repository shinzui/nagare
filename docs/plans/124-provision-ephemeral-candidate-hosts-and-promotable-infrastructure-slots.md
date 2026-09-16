---
id: 124
slug: provision-ephemeral-candidate-hosts-and-promotable-infrastructure-slots
title: "Provision ephemeral candidate hosts and promotable infrastructure slots"
kind: exec-plan
created_at: 2026-09-13T22:09:03Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:37Z
      mode: "update"
      note: "Refresh candidate provisioning against current guarded plan and identity boundaries"
---

# Provision ephemeral candidate hosts and promotable infrastructure slots

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare can temporarily provision a second, isolated machine beside the live machine without
adding a load balancer or changing wildcard DNS. The candidate boots the target NixOS image,
has its own boot and data disks and identity, is reachable by the operator through IAP, and
cannot receive public HTTP traffic. When no replacement is active, only the promoted machine
and its disks remain, preserving the one-machine steady-state cost model.

An operator sees this through `nagarectl platform replacement prepare <transaction-id>` and
`status`: preparation creates the inactive slot, reports its exact GCP resource identities,
and leaves the current reserved IP on the old slot. A Pulumi preview proves that adopting
the slot model does not replace the existing VM or disk.

Since this plan was drafted, Nagare 0.3.0 made reviewed Pulumi plans and apply receipts the guarded
infrastructure boundary, added explicit staged-host identity, and added context-safe kubeconfig
fetching. Candidate preparation must extend those mechanisms with replacement bindings; it must not
introduce a second direct `pulumi up`, ambient-host, or ambient-kubeconfig path.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Refactor the singleton Pulumi component into active and optional inactive host slots
      while preserving existing resource URNs and physical names.
- [ ] Add candidate-only network tags, IAP access, independent protected storage, and
      least-privilege candidate identity.
- [ ] Add candidate host-flake staging and explicit active/candidate Pulumi outputs.
- [ ] Implement idempotent prepare/reconcile operations behind the replacement transaction.
- [ ] Add mock-provider, preview, migration, and disposable-project verification.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `NagareNetwork` currently opens ports 80 and 443 to every VM on the subnet;
  creating a candidate with an ephemeral external address would therefore expose it even
  though DNS still names the old machine.
  Evidence: `infra/pulumi/src/components/NagareNetwork.ts` declares `fw-web` without target
  tags, and `NagareInstance.ts` always creates an access configuration.
- Observation: The current VM service account can push images and administer backup objects.
  Reusing it on a rehearsal candidate would let candidate workloads overwrite backups or
  publish images.
  Evidence: `NagarePerimeter.ts` grants Artifact Registry writer and backup-bucket
  `roles/storage.objectAdmin` to `nagare-node`.
- Observation: The current k3s datastore lives on the boot disk while application persistent
  volumes live on the attached data disk.
  Evidence: the NixOS k3s module uses `/var/lib/rancher`, and the local-path provisioner is
  rooted at `/var/lib/nagare/local-path`.
- Observation: the current tree now has reusable guarded infrastructure and target-identity
  primitives that were absent at plan creation.
  Evidence: `Nagare.Infra.Plan` owns private retained plan bundles,
  `Nagare.Platform.PulumiReceipt` owns apply/recovery evidence, `Nagare.Host.Config` reads the staged
  host name used by an upgrade, and `Nagare.Cluster.Kubeconfig` fetches and normalizes an explicitly
  selected context kubeconfig.


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent infrastructure as one active slot and at most one inactive candidate
  slot within the existing Pulumi stack.
  Rationale: Slots make promotion and the next replacement explicit while retaining one
  steady-state VM; a second stack would duplicate shared DNS, registry, buckets, and state.
  Date: 2026-09-13
- Decision: Give the candidate a fresh boot disk and an independent data disk; never attach
  the live data disk to it.
  Rationale: The candidate must be safe to destroy, and the old host must remain a complete
  rollback target until finalization.
  Date: 2026-09-13
- Decision: Give the candidate an ephemeral egress address but gate public web ingress by an
  `nagare-active` network tag; allow IAP SSH to both slot tags.
  Rationale: A fresh host needs outbound access during preparation, but no request should
  reach candidate ports 80/443 before the deadline-bound promotion.
  Date: 2026-09-13
- Decision: Use a candidate-specific service account with Artifact Registry and backup
  object read access only; add any narrowly scoped DNS challenge permission only if the
  fenced bootstrap plan proves it necessary.
  Rationale: Rehearsal must not be able to push images, overwrite backups, or mutate unrelated
  project state.
  Date: 2026-09-13
- Decision: Implement the exact static-IP attachment topology proven by ExecPlan 122 and do
  not encode a speculative provider sequence before that proof passes.
  Rationale: Pulumi ownership and GCE attachment behavior must be demonstrated with forward
  and reverse handoff before production infrastructure depends on it.
  Date: 2026-09-13
- Decision: Bind candidate preview/apply evidence to the replacement transaction by extending the
  existing reviewed-plan and Pulumi-receipt contracts.
  Rationale: provider execution and ambiguous crash recovery need the same private, immutable,
  operator-reviewable evidence already required by ADR 18; a parallel unchecked apply path would
  weaken the platform boundary.
  Date: 2026-09-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`infra/pulumi/src/components/NagarePerimeter.ts` creates shared network, reserved regional
address, wildcard DNS, protected data disk, node service account, registry, buckets, and one
`NagareInstance`. `infra/pulumi/src/components/NagareInstance.ts` always attaches the
reserved address and live data disk to that instance. `infra/pulumi/src/components/NagareNetwork.ts`
currently applies public ingress rules to the entire VPC. `infra/pulumi/index.ts` reads a
single `instanceName` and image and exports singleton outputs. Tests use Pulumi mocks under
`infra/pulumi/test/`, and `npm run build` performs the TypeScript check.

The slot model separates shared resources from replaceable hosts. Slot A initially adopts
the current physical instance and `nagare-data` disk. Slot B is absent. During replacement,
the inactive slot is materialized with a transaction-specific candidate VM and data disk.
Promotion changes the active pointer and public-address attachment; it does not rename disks
or copy the candidate boot disk. Finalization removes the former active slot only after its
retention period. The next replacement can materialize the now-inactive slot, so no permanent
third identity is needed.

`cli/nagarectl/src/Nagare/Host/Config.hs` stages context-owned host flakes and secrets.
Candidate host material must live under the replacement transaction and must use a unique
physical hostname and cluster identity. `scripts/iap-ssh.sh`, `scripts/host-switch.sh`, and
`scripts/live-test.sh` demonstrate the existing IAP access pattern. `Nagare.Cluster.Kubeconfig`
now supplies the guarded fetch/normalize implementation, and `Nagare.Host.Config` separates the
staged target hostname from the active host. Candidate operations extend both with explicit
transaction-owned destinations rather than relying on active context defaults.

`Nagare.Infra.Plan` and `Nagare.Platform.PulumiReceipt` are the current infrastructure execution
boundary. A replacement plan bundle must additionally bind the replacement transaction ID, source
slot, candidate slot, and expected resource manifest. Candidate resume must distinguish verified
success, known failure, and ambiguous provider execution using the receipt protocol before it
changes transaction state.

Relevant decisions are [ADR 0005](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md)
for context-owned host flakes, [ADR 0009](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
for selected-project confinement, [ADR 0011](../adr/0011-host-activation-is-guarded-and-self-reverting.md)
for guarded host switching, [ADR 0012](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md)
for protected data, [ADR 0013](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
for context-owned state, and [ADR 0014](../adr/0014-the-active-context-owns-the-vm-shape.md)
for intentional VM replacement. ExecPlan 122 adds the replacement-topology ADR that this
plan must follow. Mori did not locate a registered Pulumi GCP provider corpus, so the
implementation must use the repository-locked provider behavior rather than assume an API.


## Plan of Work

### Milestone 1: Non-replacing slot migration

Refactor `NagareInstance.ts` into a reusable `NagareHostSlot` component whose inputs include
slot identity, network tags, optional public address, boot image, data disk, and service
account. In `NagarePerimeter.ts`, declare slot A with aliases and physical names that adopt
the existing `NagareInstance`, VM, data disk, snapshot policy, and attachment URNs. Add
`activeSlot`, defaulting to A, but do not create slot B yet. Update network firewall rules so
public 80/443 ingress targets only `nagare-active`; IAP SSH targets both `nagare-active` and
`nagare-candidate`. The active VM receives `nagare-active` in place. A saved pre-change stack
fixture and a real preview must show tag updates and no creates, deletes, or replacements for
the VM and data disk.

### Milestone 2: Optional candidate resources

Add typed `replacement` Pulumi configuration in `infra/pulumi/index.ts`: transaction ID,
candidate slot, target image self-link, and candidate shape. Reject partial configuration,
an active candidate slot, a source mismatch, or more than one candidate. Materialize the
inactive `NagareHostSlot` with a fresh boot disk, separately protected data disk of at least
the active size, a unique name, `nagare-candidate` tag, and ephemeral external address for
egress. It must not receive the reserved address. Create a candidate service account with
only `roles/artifactregistry.reader`, backup bucket `roles/storage.objectViewer`, logging,
and metrics permissions required by the base host. Do not grant registry writer or backup
object admin. Keep daily snapshot policy off the disposable candidate disk until promotion;
ExecPlan 126 owns explicit seed snapshots. Export active and candidate identities separately.

### Milestone 3: Candidate host identity and preparation orchestration

Extend `Nagare.Host.Config` to stage a candidate flake under
`replacement-upgrades/<id>/host/`, preserving the target release lock and secrets while
overriding physical hostname, instance name, and cluster identity. Add an explicit host
target record to the replacement schema from ExecPlan 123. Wire
`platform replacement prepare` in `Main.hs` to stage the candidate, write replacement
Pulumi config, save and review the expected create-only candidate plan through
`Nagare.Infra.Plan`, apply that exact plan, record the outcome through
`Nagare.Platform.PulumiReceipt`, and retain the actual outputs. Use existing Pulumi project/stack
guards and GCP project/zone guards for every subprocess. Fetch the candidate kubeconfig through the
explicit identity contract in `Nagare.Cluster.Kubeconfig`, storing it under the transaction without
changing the active context kubeconfig. Do not bootstrap k3s workloads here; ExecPlan 125 owns that
step.

### Milestone 4: Reconciliation and disposable-project proof

Add Pulumi mock tests for active-only, candidate-present, promoted, and finalized shapes.
Add command tests with fake Pulumi/GCP operations proving resume after each write. In a
disposable project or explicitly named test stack, run active-only migration preview and
candidate creation. Verify IAP SSH succeeds, direct TCP 80/443 to the candidate's ephemeral
address fails, the reserved address remains attached to active, and deleting candidate
configuration cannot delete active resources. Record command output as transaction evidence.


## Concrete Steps

Run Pulumi commands from the repository root as shown. Run Cabal from `cli/nagarectl/` because the
monorepo has no root `cabal.project`:

    npm --prefix infra/pulumi run build
    npm --prefix infra/pulumi test
    nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct

If `infra/pulumi` still has no test script when implementation begins, invoke its committed
test runner directly and add the stable script to `package.json`; do not silently skip mock
tests. Expected tests include `adopts current host without replacement`, `candidate has no
reserved address`, and `candidate service account cannot write backups`.

With the existing context selected, run a non-mutating migration preview:

    pulumi -C <context-infra-workspace> preview --diff

Expected summary before candidate configuration:

    Resources:
        ~ 2 to update
        0 to create
        0 to replace
        0 to delete

The exact update count may change as provider normalization evolves; the acceptance rule is
zero replacement/deletion and only the reviewed tag/alias changes.

Against a disposable test stack, run:

    nagarectl platform replacement prepare <transaction-id> --json
    gcloud compute instances describe <candidate> --project <test-project> --zone <zone>
    gcloud compute addresses describe <reserved-address> --project <test-project> \
      --region <region>
    gcloud compute ssh <candidate> --project <test-project> --zone <zone> \
      --tunnel-through-iap --command 'systemctl is-system-running --wait'

The prepare result names the candidate VM and disk. The address still reports the active VM
as its user, the candidate has only the candidate tag, IAP succeeds, and an external probe
to candidate ports 80/443 times out or is rejected.

Finally run:

    nix flake check --print-build-logs


## Validation and Acceptance

Acceptance requires:

* Adopting slots in an existing active-only stack does not replace or delete its VM, boot
  disk, protected data disk, address, DNS record, registry, buckets, or service account.
* `prepare` creates exactly one candidate VM with a fresh target boot image and independent
  protected data disk. It neither stops nor changes the running active machine.
* The wildcard DNS record and reserved address remain unchanged and attached to active.
  No load balancer, forwarding rule, backend service, or permanent proxy is created.
* Candidate public HTTP/HTTPS ingress is denied, while IAP SSH and required outbound package
  and image access work. Existing active HTTP/HTTPS ingress remains available.
* Candidate credentials cannot push Artifact Registry images or create, overwrite, or delete
  backup objects. They can pull images and read the selected restore objects.
* Repeating `prepare` reconciles and records the same resource identities. A changed target
  image invalidates later evidence and requires explicit candidate reconciliation.
* Removing a failed candidate leaves the active slot untouched. After promotion and explicit
  finalization, the former active slot can be deleted and steady state returns to one VM and
  one protected data disk.


## Idempotence and Recovery

Pulumi resources are declarative and `prepare` may be resumed after reading the transaction
and actual stack outputs. Never infer success solely from a prior CLI exit code. If candidate
creation fails, leave its config and transaction in `ReplacementFailed`; a retry previews
and reconciles only candidate resources. `replacement abandon` may remove an unpromoted
candidate only after checking the reserved address still belongs to active and the
candidate disk name matches the transaction.

The slot migration is the risky portion. Export stack state before applying it, require an
interactive or explicit approval after a zero-replacement preview, and stop if provider
aliases do not adopt every protected resource. Do not work around protection by unprotecting
the live disk. If the migration apply partially fails, rerun preview/apply with the same
declarations; the original physical resources and Pulumi state backup remain the recovery
anchors.


## Interfaces and Dependencies

Use the versions already locked in `infra/pulumi/package-lock.json`; at plan creation the
installed `@pulumi/gcp` is 8.41.1. Before changing dependency bounds, verify the registry and
upstream release tag as required by repository policy. The GCP provider types used are
`gcp.compute.Instance`, `Disk`, `Address`, `Firewall`, `ResourcePolicy`, service-account and
non-authoritative IAM member resources. Use aliases/imports supported by the locked provider
and proven by ExecPlan 122.

`NagareHostSlot` must accept and expose a contract equivalent to:

    interface NagareHostSlotArgs {
      slot: "a" | "b";
      role: "active" | "candidate";
      transactionId?: string;
      instanceName: string;
      zone: string;
      machineType: string;
      imageSelfLink: string;
      subnetId: pulumi.Input<string>;
      publicIp?: pulumi.Input<string>;
      dataDiskSizeGb: number;
      serviceAccountEmail: pulumi.Input<string>;
      deletionProtection: pulumi.Input<boolean>;
      bootDiskSizeGb: number;
      bootDiskType: string;
    }

The perimeter exports stable `activeSlot`, `activeInstanceName`, `activeDataDiskName`,
`candidateSlot`, `candidateInstanceName`, `candidateDataDiskName`, `candidateInternalIp`,
`candidateExternalIp`, `candidateServiceAccountEmail`, `publicIp`, and
`replacementTransactionId` outputs. Absent candidate outputs use JSON `null`, not display
sentinels.

The command layer owns an operation interface so tests do not invoke real infrastructure:

    data CandidateOps = CandidateOps
      { previewCandidate :: CandidateSpec -> IO PulumiPreviewEvidence
      , applyCandidate :: CandidateSpec -> IO CandidateResources
      , inspectCandidate :: CandidateResources -> IO CandidateObservedState
      , destroyCandidate :: CandidateResources -> IO ()
      }

This plan has hard prerequisites on ExecPlans 122 and 123. ExecPlan 125 consumes candidate
host and kubeconfig identities. ExecPlan 126 consumes candidate storage identities. ExecPlan
127 changes the active role and address attachment but must use this plan's outputs and the
handoff primitive selected by ExecPlan 122.


Revision note (2026-09-15): Refreshed candidate preparation against Nagare 0.3.0's reviewed Pulumi
plan, apply-receipt, staged-host, and context-safe kubeconfig boundaries; no candidate infrastructure
milestone is marked complete.
