---
id: 138
slug: keep-bootstrap-tls-issuance-within-intended-names
title: "Keep bootstrap TLS issuance within intended names"
kind: exec-plan
created_at: 2026-09-14T04:16:15Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:15Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T16:26:57Z
      mode: "implement"
      note: "Started EP-5 TLS issuer and namespace policy implementation"
---

# Keep bootstrap TLS issuance within intended names

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On a freshly bootstrapped cluster, Knative's internal and cluster-local certificates use its
self-signed issuer, while the public ACME issuer receives only DNS names for explicitly labeled app
namespaces. Enabling TLS no longer creates rejected orders for internal names or public wildcard
certificates for Kubernetes system namespaces. A diagnostic fails before stamping success if an
ACME-backed certificate contains a non-public name. This plan implements IR-22 and IR-23 and
integrates with independent ExecPlan 132's webhook readiness work.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T16:40:54Z) Verify Knative/net-certmanager compatibility and pin explicit
  internal issuer references.
- [x] (2026-09-14T16:40:54Z) Define the app-namespace label contract and scope wildcard issuance
  to that selector across bootstrap and workload creation paths.
- [x] (2026-09-14T16:40:54Z) Add the focused certificate-policy command, doctor probe/remediation,
  parsed manifest gate, and pure inventory coverage.
- [ ] Run the disposable k3d certificate-controller verification; Docker is currently stopped.
- [ ] Reconcile bootstrap ordering, update docs/ADR, complete both IRs, and run gates.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: net-certmanager v1.14.0 is both the repository's pinned version and the latest tag in
  the authoritative `knative-extensions/net-certmanager` repository.
  Evidence: Mori has no registered Knative project, so the fallback upstream tag inspection resolved
  `knative-v1.14.0` to commit `dcff3644e7037215a084af52905fb0e9e78bab52`. That source parses
  `issuerRef`, `clusterLocalIssuerRef`, and `systemInternalIssuerRef` separately and selects them by
  Knative certificate type. The pin does not need to move.

- Observation: the ambient shell lacks `k3d` and its configured Colima Docker socket is absent, but
  the project development shell provides k3d v5.9.0.
  Evidence: `docker info` could not connect to `~/.colima/docker.sock`; `k3d` was absent from the
  ambient `PATH`, while `nix develop -c k3d version` succeeded. The controller-level disposable
  verification therefore remains a distinct environment-dependent step.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the opt-in label `nagare.dev/app-namespace=true` and make Nagare's namespace-creating
  paths own it.
  Rationale: An allow-list remains safe as new system namespaces appear; a name-based exclusion
  list would silently issue public certificates for every unrecognized namespace.
  Date: 2026-09-14.

- Decision: Set both `systemInternalIssuerRef` and `clusterLocalIssuerRef` explicitly to
  `knative-selfsigned-issuer`; keep only public external-domain issuance on `letsencrypt-dns`.
  Rationale: Relying on version-dependent fallback behavior already routed an internal short name
  to production ACME. Explicit role-specific issuers preserve the intended trust boundaries.
  Date: 2026-09-14.

- Decision: Treat any ACME-issued DNS name without a dot, `.svc`, or `.svc.cluster.local` name as a
  bootstrap failure and diagnostic error.
  Rationale: Such names are never valid public ACME identifiers and are direct evidence that the
  issuer boundary regressed.
  Date: 2026-09-14.

- Decision: Amend ADR 10 if the label and public-name boundary survive implementation.
  Rationale: Public certificate eligibility and Certificate Transparency exposure are durable
  platform policy, not merely manifest syntax.
  Date: 2026-09-14.

- Decision: Keep net-certmanager v1.14.0 and encode all three issuer roles explicitly.
  Rationale: the pinned/latest controller source supports the exact keys and type dispatch required
  by this plan. A version change would add unrelated compatibility risk without changing behavior.
  Date: 2026-09-14.

- Decision: Reconcile application namespaces by applying a Namespace object containing only
  Nagare's opt-in label, and reject fixed Kubernetes, control-plane, and observability namespaces.
  Rationale: `kubectl apply` creates a missing namespace or merges the one Nagare-owned label onto an
  existing namespace without deleting unrelated labels. A deny-list at this API boundary prevents
  accidental public wildcard issuance even when a caller selects a platform namespace.
  Date: 2026-09-14.

- Decision: Expose the focused check as `nagarectl cluster certificate-policy` and also include its
  probe in server status and doctor.
  Rationale: bootstrap needs a fail-closed command that checks only this policy before stamping,
  while day-two diagnostics should show the same parsed evidence and remediation with the rest of
  the platform inventory.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

[IR-22](../improvement-requests/system-internal-cert-sent-to-acme.md) records that
`cluster/bootstrap/knative-serving/config-certmanager.yaml` sets only `issuerRef` to
`letsencrypt-dns`. On the observed cluster, Knative's `routing-serving-certs` then requested an ACME
certificate for `kn-routing` and `data-plane.knative.dev`; the first name is not public and the order
was rejected. The ConfigMap's `_example` mentions `systemInternalIssuerRef` and
`clusterLocalIssuerRef`, but those keys are not active configuration.

[IR-23](../improvement-requests/wildcard-certs-for-system-namespaces.md) records that
`cluster/bootstrap/knative-serving/config-network-tls.yaml` sets
`namespace-wildcard-cert-selector: "{}"`. That selector matches every namespace, including
`kube-system`, `cert-manager`, and `knative-serving`. Public wildcard requests consume a shared
registered-domain rate budget and expose namespace names through Certificate Transparency.

`justfile` creates fixed bootstrap namespaces, creates/updates `personal`, applies Knative and
net-certmanager, patches these ConfigMaps, and later enables TLS. Independent
[ExecPlan 132](132-make-cluster-bootstrap-wait-for-knative-webhooks.md) adds readiness gates and
bounded ConfigMap patch retries in this same sequence. Reconcile with its helper and keep the final
platform stamp after all configuration and diagnostics. EP-1 adds `nagarectl cluster guard`; consume
it before mutation when available.

Application deployment is implemented in `cli/nagarectl/src/Nagare/App/Deploy.hs`, worker deploy in
`cli/nagarectl/src/Nagare/Worker/Deploy.hs`, and other resource paths are dispatched from
`cli/nagarectl/app/Main.hs`. They currently assume a namespace exists or use `personal`; there is no
shared app-namespace reconciler. Add one owner so deploying an app, worker, database, broker, task,
or static site into a new namespace creates/labels it before namespaced resources. Do not label
observability or control-plane namespaces merely because Nagare manages resources there.

The pinned versions are Knative Serving `knative-v1.22.0` and net-certmanager `v1.14.0`, with the
skew noted in `cluster/bootstrap/net-certmanager/README.md`. Before choosing any compatibility pin
change, use Mori to locate registered dependency source and verify current release tags and
published matching guidance upstream. If the present keys behave correctly with explicit values,
prefer no version change.

[ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md) owns the context-specific public
ACME identity. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires the cluster stamp to represent completed bootstrap. No cross-repository ADR currently
governs Knative certificate selection.


## Plan of Work

### Milestone 1: make issuer roles explicit

Verify the active Knative/net-certmanager configuration schema against the registered sources or
authoritative release artifacts before editing. In
`cluster/bootstrap/knative-serving/config-certmanager.yaml`, keep `issuerRef` on the context-owned
`letsencrypt-dns` ClusterIssuer and set `systemInternalIssuerRef` and `clusterLocalIssuerRef` to the
ClusterIssuer `knative-selfsigned-issuer`. Use the exact structured YAML expected by the installed
controller. Update `cluster/bootstrap/knative-serving/README.md` with the three roles.

Add a render/config check under `nix/checks/scripts.nix` that parses the ConfigMap and asserts all
three values, rather than grepping comments. In a disposable cluster, enable external-domain TLS and
assert certificates labeled `networking.knative.dev/certificate-type=system-internal` or serving
cluster-local names reference the self-signed issuer and become Ready.

### Milestone 2: opt app namespaces into public wildcards

Replace the empty selector in `config-network-tls.yaml` with a `matchLabels` selector for
`nagare.dev/app-namespace: "true"`. Make `cluster-bootstrap` create/apply `personal` with this label.
Create a shared namespace reconciler in a module such as
`cli/nagarectl/src/Nagare/Cluster/Namespace.hs`; call it before each application workload path
creates namespaced objects. It should create a missing namespace with managed labels or add the
opt-in label to an existing requested app namespace without deleting unrelated labels. Dry-run must
render the namespace action. Never label system/observability namespaces through this helper.

Add pure manifest tests and fake-kubectl command tests covering `personal`, a new app namespace, an
existing labeled namespace, preserved labels, and a system namespace refusal. Add a bootstrap
selector check to `nix/checks/scripts.nix`.

### Milestone 3: detect leaked ACME names and prove behavior

Add certificate policy inspection to `nagarectl doctor` or a focused bootstrap validation module in
`cli/nagarectl/src/Nagare/Ops/Doctor.hs`. Query Certificates across namespaces as JSON, identify
those using `letsencrypt-dns`, inspect every `spec.dnsNames`, and fail for a short or cluster-local
name. Also fail when a public wildcard certificate exists in a namespace lacking the opt-in label.
Return structured evidence and a remediation that points to bootstrap configuration; do not delete
orders or certificates automatically.

Build a disposable kind/k3d verification that installs the pinned stack, applies a fake or staging
issuer where necessary, creates one labeled app namespace and several unlabeled system fixtures,
enables TLS, and proves only the app namespace receives a public wildcard. Prove internal/cluster
local certificates select self-signed. Use fake ACME resources for deterministic CI; reserve real
staging/production issuance for an explicitly authorized cloud rehearsal.

### Milestone 4: integrate bootstrap and publish policy

Reconcile `justfile` with ExecPlan 132 so cluster guard, webhook waits, patches, certificate policy
check, and platform stamp remain in that order. Update `docs/user/cluster-bootstrap.md`,
`docs/user/onboarding-bring-your-own-project.md`, and `docs/user/reference.md` with the opt-in label,
rate-limit cost, Certificate Transparency exposure, and diagnostic. Amend ADR 10, update
`CHANGELOG.md`, complete IR-22 and IR-23, append the bundle log, and run gates.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`.

```bash
cabal test nagarectl-test
nix build .#checks.aarch64-darwin.cluster-bootstrap-defaults --print-build-logs
nix build .#checks.aarch64-darwin.knative-bootstrap-readiness --print-build-logs
```

For a disposable cluster selected by an explicit `KUBECONFIG`:

```bash
NAGARE_CONTEXT=tls-test nagare cluster-bootstrap
NAGARE_CONTEXT=tls-test nagare cluster-enable-tls
kubectl get certificate -A -o json
nagarectl doctor --context tls-test
```

Expected evidence: internal and cluster-local certificate objects name
`knative-selfsigned-issuer`; only namespaces labeled `nagare.dev/app-namespace=true` have
`*.<namespace>.<baseDomain>` public certificates; doctor exits zero and no ACME Order contains a
short or cluster-local name. Finish with strict OKF validation and `nix flake check --print-build-logs`.


## Validation and Acceptance

Parsed manifest checks must prove all issuer roles and the opt-in selector. Namespace tests must
prove every Nagare app-workload creation path labels its requested namespace, preserves unrelated
labels, and never opts fixed system/observability namespaces into public issuance. Diagnostic tests
must reject an ACME certificate for `kn-routing`, `.svc`/cluster-local names, and a wildcard in an
unlabeled namespace.

On a fresh disposable cluster, one bootstrap plus TLS enable produces Ready internal certificates
on the self-signed issuer and public wildcards only for `personal` and any additional labeled app
namespace. `kubectl get certificate -A` shows none for `kube-system`, `kube-node-lease`,
`cert-manager`, `knative-serving`, `kourier-system`, or `nagare-system`. No ACME Order contains a
non-public name. Bootstrap stamps the platform only after this policy passes.


## Idempotence and Recovery

ConfigMap patches and namespace label reconciliation are convergent and preserve unrelated labels.
Rerunning bootstrap or TLS enable is safe after correcting readiness. Changing the selector does
not necessarily delete certificates already created under the old selector; document and test an
explicit review-and-delete procedure that lists exact Certificate, CertificateRequest, Order, and
Secret targets before removal. Never automate bulk deletion or switch to production ACME during
tests. If rate limits may already be affected, keep staging configured until the inventory is clean.


## Interfaces and Dependencies

The namespace owner should expose a small interface equivalent to:

```haskell
data NamespacePurpose = ApplicationNamespace
ensureNamespace :: NamespaceOps -> NamespacePurpose -> Text -> IO ()
```

The certificate policy should separate JSON parsing from Kubernetes IO:

```haskell
certificatePolicyViolations :: Set Text -> [CertificateObservation] -> [CertificateViolation]
```

Depend on the pinned Knative Serving/net-certmanager manifests, cert-manager CRDs, kubectl, existing
Aeson/process helpers, the context-owned `letsencrypt-dns` issuer, and
`knative-selfsigned-issuer`. ExecPlan 132 owns webhook readiness; EP-1 owns cluster identity guard;
EP-6 owns the final live rehearsal.


Revision note (2026-09-14): Verified the pinned controller schema, made issuer roles and wildcard
namespace eligibility explicit, reconciled the app-namespace label across workload creation paths,
and added fail-closed parsed certificate diagnostics. Disposable-controller verification and final
publication remain.
