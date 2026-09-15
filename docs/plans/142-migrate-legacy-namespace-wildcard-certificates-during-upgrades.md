---
id: 142
slug: migrate-legacy-namespace-wildcard-certificates-during-upgrades
title: "Migrate legacy namespace wildcard certificates during upgrades"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp35nje7j9kqpd7qgbmwpb"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T16:31:36Z
      mode: "implement"
      note: "Implemented the pure migration model and began upgrade orchestration"
---

# Migrate legacy namespace wildcard certificates during upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A TLS-enabled cluster created by Nagare 0.2.2 can upgrade to the narrowed 0.3.x certificate policy
without a manual ConfigMap patch or an unsafe blanket deletion. Upgrade planning records the
selector change plus the exact obsolete certificate chains and generated TLS Secrets in a private,
context-bound Kubernetes review bundle. Apply installs the narrowed selector before the certificate
policy gate, preserves valid wildcards in opted-in application namespaces, and removes only legacy
artifacts whose live identity still matches the reviewed evidence. The defect is recorded in
[BUG-3](../bug-reports/upgrade-does-not-migrate-certificate-selector.md).

The observable proof starts from a 0.2.2 fixture whose `namespace-wildcard-cert-selector` is `{}` and
whose system namespaces contain legacy public wildcard certificates. A 0.3.x dry run shows the
selector diff and exact cleanup inventory. Apply leaves the opted-in `personal` wildcard intact,
removes the reviewed system-namespace Certificate objects and matching generated Secrets, passes
`nagarectl cluster certificate-policy`, and produces no further changes on resume or reapply.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-15T16:31:36Z) Milestone 1: model legacy selector and certificate/Secret inventory
  as a pure, reviewable, transaction-bound Kubernetes migration bundle. Ten focused tests prove
  deterministic preserve/remove classification, disabled/target-selector no-ops, ambiguous Secret
  refusal, exact UID/content/reference drift refusal, idempotent absence, and transaction bindings.
- [x] (2026-09-15T16:57:42Z) Milestone 2: upgrade planning now publishes a private, canonical,
  context/transaction/payload-bound Kubernetes bundle after the cluster guard; apply verifies it,
  narrows the selector with server-side apply before bootstrap, waits for controller convergence,
  and deletes only unchanged reviewed Secrets. The installed clone-free check proves tamper
  refusal, exact legacy preserve/remove inventory, mutation order, and fixed-point reapply.
- [ ] Milestone 3: prove 0.2.2-to-current convergence, document recovery, amend durable TLS upgrade
  policy, and pass focused plus full validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `mori registry search net-certmanager` and
  `mori registry show knative-extensions/net-certmanager --full` do not resolve the archived
  upstream project in the current local registry, even though ADR 10 records the intended
  `mori://knative-extensions/net-certmanager` project URI. The repository-owned exact source pin
  remains available in `nix/net-certmanager-controller.nix`, and the official upstream source was
  consulted for the object contract.
  Evidence: Mori printed `No projects matching 'net-certmanager'` and `Project ... not found in
  local registry`; the Nix expression pins commit `dcff3644e7037215a084af52905fb0e9e78bab52`.

- Observation: the plan's root-level `cabal test` examples do not work because the repository root
  has no `cabal.project`; Nagare's established package commands run from `cli/nagarectl` while the
  Nix development shell is discovered from the repository root.
  Evidence: Cabal returned `There is no <pkgname>.cabal package file or cabal.project file`; the
  same focused test from `cli/nagarectl` passed all 10 cases.


## Decision Log

Record every decision made while working on the plan.

- Decision: Create a dedicated `kubernetes-plan/` bundle inside each upgrade transaction rather
  than enabling `config-network-tls.yaml` unconditionally in `cluster-bootstrap`.
  Rationale: Fresh clusters are deliberately HTTP-first until DNS and ACME prerequisites are ready.
  Only a cluster already observed with `external-domain-tls: Enabled` should retain TLS while its
  selector is migrated. A transaction-bound bundle makes that conditional decision reviewable and
  binds it to the same context, payload, and immutable workspace as the rest of the upgrade.
  Date: 2026-09-15.

- Decision: Inventory and clean only public wildcard Certificate objects that violate the target
  label/issuer policy and only their recorded cert-manager-generated Secrets; preserve every
  compliant Certificate, even if it predates the upgrade.
  Rationale: The desired state is policy convergence, not deletion by age or namespace alone. A
  valid wildcard in `personal` is user-visible serving state and must survive. Exact namespace,
  name, UID, issuer, DNS names, secret name, and Secret UID/digest bindings keep cleanup narrow.
  Date: 2026-09-15.

- Decision: If a reviewed Certificate or Secret changes identity or content before deletion, refuse
  the Kubernetes apply phase and print the exact mismatch; never broaden selection or silently skip
  a changed object.
  Rationale: A user or controller may have replaced an object after planning. Stopping preserves the
  review boundary and prevents deleting a newly repurposed Secret under a familiar name.
  Date: 2026-09-15.

- Decision: Keep the migration bundle outside the upgrade transaction JSON schema and bind it with
  its own versioned metadata and file digests.
  Rationale: The bundle is a private reviewed artifact analogous to the Pulumi plan directory. Its
  derived location and explicit transaction/context/payload bindings avoid coupling this fix to
  independent transaction-journal evolution while still detecting tampering and stale plans.
  Date: 2026-09-15.

- Decision: Recognize a generated TLS Secret only when the cert-manager Certificate UID appears in
  its owner references or when both `cert-manager.io/certificate-name` and
  `cert-manager.io/issuer-name` match the reviewed Certificate.
  Rationale: cert-manager owner references on generated Secrets are deployment-option dependent,
  while its generated annotations preserve a narrow identity binding. Requiring one of those exact
  bindings rejects an arbitrary same-named Secret without making legacy clusters depend on an
  optional controller flag.
  Date: 2026-09-15.

- Decision: Keep `metadata.json` canonical and omit an informational creation timestamp from the
  Kubernetes bundle metadata.
  Rationale: Every remaining metadata field is either checked against the current transaction,
  context, and payload or checked against a member digest. Requiring byte-for-byte canonical JSON
  therefore makes a one-file metadata edit fail closed instead of leaving an unchecked timestamp
  field that could be changed without invalidating the bundle.
  Date: 2026-09-15.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 produced `Nagare.Cluster.CertificateMigration`, a pure JSON inventory and review
  model with no Kubernetes process execution. It hashes only stable Secret identity, annotations,
  labels, type, and data, deliberately excluding mutable server bookkeeping such as
  `resourceVersion`. The first focused run passed 10 tests.

- Milestone 2 integrated that model into `KubernetesDiff` and `KubernetesApply` without changing the
  upgrade journal schema. The hermetic 0.2.2 fixture includes `personal`, `kube-system`, and
  `observability`, so the successful exact trace proves the opt-in label drives cleanup rather than
  a system-namespace deny-list. Tampered review bytes refuse before any Kubernetes cleanup, and a
  second apply of the completed transaction adds no mutation.


## Context and Orientation

Knative Serving stores networking policy in ConfigMap `knative-serving/config-network`. When
`external-domain-tls` is `Enabled`, `namespace-wildcard-cert-selector` selects namespaces that
receive public wildcard certificates. Nagare 0.2.2 used `{}`, which matches every namespace. The
current `cluster/bootstrap/knative-serving/config-network-tls.yaml` narrows that selector to
`nagare.dev/app-namespace: "true"`; bootstrap labels the `personal` application namespace and does
not label system namespaces.

`justfile` intentionally omits `config-network-tls.yaml` from `cluster-bootstrap`, because new
clusters remain HTTP-first until an operator runs `cluster-enable-tls`. The bootstrap does run
`nagarectl cluster certificate-policy` near the end. During an upgrade, `cli/nagarectl/app/Main.hs`
runs `just cluster-bootstrap` as `KubernetesApply` with `NAGARE_UPGRADE_APPLY=1`. An existing
TLS-enabled cluster therefore retains selector `{}`, reaches the stricter policy check, and fails.
Applying the selector later makes Knative remove obsolete Certificate objects, but their generated
TLS Secrets can remain without owners.

`cli/nagarectl/src/Nagare/Cluster/CertificatePolicy.hs` already parses cert-manager Certificate
inventory and identifies public wildcards in unlabeled namespaces or on the wrong issuer.
`cli/nagarectl/src/Nagare/Ops/Status.hs` obtains all Certificates and the opted-in namespace list,
then turns violations into the `certificate-policy` probe. Extend or reuse this pure policy rather
than implementing a second definition in shell. The migration also needs ConfigMap and Secret
parsers that retain Kubernetes identity fields (`metadata.uid`, namespace, and name), Certificate
`spec.secretName`, issuer, DNS names, and `metadata.ownerReferences`, plus a stable digest of the
reviewed Secret metadata/data needed to detect replacement. Inventory both
`certificates.networking.internal.knative.dev`, which Knative owns, and
`certificates.cert-manager.io`, which materialize the issuer request, and preserve the exact
owner-reference chain from those resources to the generated Secret.

`cli/nagarectl/src/Nagare/Platform/Upgrade.hs` defines planning phases `NixEvaluate`,
`PulumiPreview`, and `KubernetesDiff`; `cli/nagarectl/app/Main.hs` currently implements
`KubernetesDiff` by diffing only the eventual platform-version marker. The transaction directory is
created under the selected context's XDG state and already contains the private `pulumi-plan/`
bundle. Add a sibling `kubernetes-plan/` directory containing versioned `metadata.json`, a redacted
`review.json`, and the desired ConfigMap manifest or patch. Validate exact members, regular files,
private permissions, metadata bindings, and SHA-256 digests before apply, following the patterns in
`Nagare.Infra.Plan` without conflating the two artifact types.

`scripts/test-cluster-certificate-policy.sh` checks the current selector and bootstrap ordering.
`cli/nagarectl/test/Spec.hs` holds pure certificate-policy tests.
`cli/nagarectl/test/PlatformSpec.hs` holds transaction tests, and
`scripts/test-cluster-certificate-policy-k3d.sh` is the disposable-controller proof. Add a
repository-owned 0.2.2 fixture so the migration can be tested without depending on a live cluster or
mutable release URL.

[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) requires
Kubernetes diff evidence before apply and stamps the cluster only after convergence.
[ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md) owns public ACME identity and the
opt-in application-namespace boundary. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
requires upgrade mutation paths to carry the same guards as their recipes.
[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) requires preserving
application hostname and certificate ownership. No cross-repository ADR governs the migration. The
live origin is `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.


## Plan of Work

Milestone 1 builds the review model. Add
`cli/nagarectl/src/Nagare/Cluster/CertificateMigration.hs` and register it in
`cli/nagarectl/nagarectl.cabal`. Define parsers for the live `config-network` ConfigMap, both
Knative and cert-manager Certificate lists, opted-in namespace list, and candidate Secret objects. The planner returns no
migration when TLS is disabled or the selector already equals the target. For an enabled legacy
selector, it renders the target ConfigMap change and a sorted list of policy-violating public
wildcard certificate chains with their exact generated Secret bindings. It must reject unparseable
selectors, ambiguous secret ownership, a violation without `spec.secretName`, duplicate targets, or
an object whose issuer/annotations do not establish Nagare/cert-manager management. Add JSON schemas
for bundle metadata and redacted review, stable renderers, digest/security validation, and pure
fixtures for `{}`, the target selector, disabled TLS, compliant `personal`, violating system
namespaces, shared secret names, and changed UIDs. This milestone is accepted when pure tests show a
deterministic plan that preserves the valid application wildcard and refuses unsafe cleanup.

Milestone 2 wires planning and apply. In `upgradeOps` inside `cli/nagarectl/app/Main.hs`, make
`KubernetesDiff` gather the selected cluster's ConfigMap, namespace, Certificate, and candidate
Secret inventories after `cluster guard`, create `kubernetes-plan/` atomically with mode `0700` and
files mode `0600`, run `kubectl diff` against the desired ConfigMap object, and persist both the
human diff and exact cleanup review as phase evidence. Bind metadata to transaction ID, context,
target payload ID/digest, and the digests of every bundle member. Planning is read-only and must not
patch or delete cluster objects.

In `KubernetesApply`, verify the untouched bundle and live selected-cluster identity before any
write. If the bundle says no TLS migration, proceed to the ordinary bootstrap. Otherwise re-fetch
every reviewed object and refuse on UID/content/ownership drift; apply the desired selector first;
wait with a bounded timeout for the reviewed obsolete Certificate objects to disappear; re-fetch
each candidate Secret and delete it only when its exact reviewed identity and cert-manager-generated
metadata still match and no live Certificate refers to it. Then run `just cluster-bootstrap`, whose
existing final `certificate-policy` gate must now pass. Emit a concise applied/preserved/deleted/
manual-attention summary in phase evidence. Repeating this apply treats an already-correct selector
and already-absent exact artifacts as success. Add transaction tests that fail at each boundary and
prove no cleanup happens before bundle and cluster validation.

Milestone 3 proves the actual upgrade path. Add a 0.2.2 Kubernetes fixture under
`cli/nagarectl/test/fixtures/` or `cluster/test/fixtures/` containing selector `{}`, one valid
`personal` wildcard, several system-namespace legacy chains, and their Secrets. Extend the hermetic
platform check to prove the planned diff and exact deletion trace. Extend
Add `scripts/test-cluster-certificate-migration-k3d.sh` as a focused disposable-cluster proof that
loads the fixture, runs plan/apply twice, and observes that the valid wildcard remains Ready, all
reviewed invalid Certificates and Secrets are absent, the selector is narrowed, and policy exits
zero. Document the migration and mismatch recovery in `docs/user/upgrades.md` and
`docs/user/cluster-bootstrap.md`, update `[Unreleased]` in `CHANGELOG.md`, and amend ADR 10 with the
upgrade-convergence rule. Amend ADR 6 or 18 only if the final bundle/phase boundary adds durable
context not already stated there.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/nagare`. Reconfirm current ordering before editing:

```bash
git status --short
sed -n '145,225p' justfile
sed -n '1,140p' cluster/bootstrap/knative-serving/config-network-tls.yaml
sed -n '2960,3050p' cli/nagarectl/app/Main.hs
sed -n '1,150p' cli/nagarectl/src/Nagare/Cluster/CertificatePolicy.hs
```

After Milestone 1, format and run pure tests:

```bash
nix develop -c fourmolu -i cli/nagarectl/src/Nagare/Cluster/CertificateMigration.hs cli/nagarectl/test/Spec.hs
nix develop -c cabal test nagarectl-test --test-options='--pattern CertificateMigration'
nix develop -c ./scripts/check-haskell-style.sh
```

After wiring, run all package and focused shell checks:

```bash
nix develop -c cabal test nagarectl-test
nix develop -c bash scripts/test-cluster-certificate-policy.sh
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).cluster-certificate-policy
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nagare-clone-free-platform
```

The hermetic fixture's review and apply evidence should include:

```text
selector: {} -> matchLabels[nagare.dev/app-namespace=true]
preserve: personal/personal-wildcard
delete certificate: kube-system/kube-system-wildcard
delete secret: kube-system/kube-system-wildcard-tls
certificate policy: public ACME names are confined to labeled app namespaces
second apply: no changes
```

The focused disposable proof must create and select its own temporary cluster and refuse if the
current kubeconfig name does not match that generated name. Run it only with a working Docker
daemon, never against the active operator kubeconfig:

```bash
nix develop -c bash scripts/test-cluster-certificate-migration-k3d.sh
```

Then finish with:

```bash
just user-documentation-validate
nix flake check --print-build-logs
```

Every implementation commit must include the conventional trailer:

```text
ExecPlan: docs/plans/142-migrate-legacy-namespace-wildcard-certificates-during-upgrades.md
```


## Validation and Acceptance

Given the checked-in 0.2.2 fixture, planning must make no writes and produce a private bundle bound
to the exact context, transaction, and target payload. Its human review must show the ConfigMap
selector change, the compliant application Certificate it will preserve, and every violating
Certificate/Secret pair it proposes to remove. Tampering with any bundle file, changing the selected
context, changing payload digest, replacing a Certificate or Secret UID, modifying a candidate
Secret, or adding another live Certificate reference to that Secret must refuse before deletion.

Applying an untouched plan must install the selector before `certificate-policy`, preserve the
valid `personal` wildcard and its Secret, remove every reviewed obsolete chain and matching stale
Secret, pass policy, stamp the target platform version, and leave the context eligible for commit.
The test must include system namespaces beyond a hard-coded deny-list so the opt-in policy, not a
name list, drives cleanup. Repeating apply and resuming after injected failures at selector patch,
controller convergence, Secret cleanup, bootstrap, and policy must converge without deleting any
additional object. A TLS-disabled cluster must show no migration and remain HTTP-first.

All Haskell tests, certificate-policy scripts, bundle security/tamper cases, installed clone-free
check, disposable-cluster proof, user-documentation validation, and native flake checks must pass.


## Idempotence and Recovery

Planning refuses to overwrite an existing Kubernetes bundle unless its bindings and digests match,
so retry either reuses identical evidence or creates a new transaction. Apply is convergent: the
target selector may already be installed, reviewed obsolete Certificates may already be gone, and
reviewed Secrets may already be absent. Each state is reported as satisfied rather than treated as
an error.

If any object differs from the reviewed UID or digest, stop and leave it untouched. The operator
must inspect the named object, abandon the stale transaction if intent changed, and create a new
upgrade plan; there is no force-delete option. If controller convergence times out, retain the old
context pin and resume the same transaction after diagnosing Knative/cert-manager. Rollback does not
restore deleted obsolete certificates, because the narrowed policy deliberately removes them; the
preserved valid application wildcard continues serving throughout. All destructive tests use a
fresh disposable cluster and verify kubeconfig identity before mutation.


## Interfaces and Dependencies

`cli/nagarectl/src/Nagare/Cluster/CertificateMigration.hs` should expose a narrow pure and IO-neutral
model. Exact names may follow repository style, but the responsibilities must be equivalent to:

```haskell
data CertificateResource = CertificateResource
  { namespace :: !Text
  , certificateName :: !Text
  , certificateUid :: !Text
  , apiGroup :: !Text
  , ownerUids :: ![Text]
  , issuerName :: !Text
  , dnsNames :: ![Text]
  }

data CertificateChain = CertificateChain
  { knativeCertificate :: !(Maybe CertificateResource)
  , certManagerCertificate :: !CertificateResource
  , secretName :: !Text
  , secretUid :: !Text
  , secretDigest :: !Text
  }

data CertificateMigrationPlan = CertificateMigrationPlan
  { schemaVersion :: !Int
  , selectorChange :: !(Maybe SelectorChange)
  , preserve :: ![CertificateChain]
  , remove :: ![CertificateChain]
  }

planCertificateMigration
  :: ConfigNetworkObservation
  -> Set Text
  -> [CertificateResource]
  -> [CertificateResource]
  -> [SecretObservation]
  -> Either Text CertificateMigrationPlan
```

Keep Kubernetes process execution in `cli/nagarectl/app/Main.hs` or a dedicated operational module;
the pure planner must not call `kubectl`. Use Aeson for JSON parsing/rendering, cryptonite's existing
SHA-256 support for file/object digests, and the repository's atomic rename/private-mode patterns.
The only external services are the selected Kubernetes API, Knative/net-certmanager controllers,
and cert-manager. Do not add a new package or network dependency; all required APIs already exist in
the repository and target payload.


Revision note (2026-09-15): Implemented and validated the pure Milestone 1 migration model, recorded
the exact Secret-management safety rule, and corrected the working-directory discovery needed to
resume validation.
