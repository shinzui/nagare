---
id: 191
slug: diagnose-certificate-issuance-failures-and-renew-one-owned-host
title: "Diagnose certificate issuance failures and renew one owned host"
kind: exec-plan
created_at: 2026-10-13T13:24:48Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:24:48Z
---

# Diagnose certificate issuance failures and renew one owned host

This ExecPlan implements [IR-28](../improvement-requests/diagnose-certificate-issuance-and-scoped-recovery.md).


## Purpose / Big Picture

When a site's certificate fails to issue, the deploy stops with
`Kubernetes DomainMapping certificate did not prove readiness; reobserve before retry`, and
`nagarectl domains check` says the certificate is pending or failed with the Certificate's Ready
message. In the v0.6.2 incident behind IR-28, DNS-01 validation succeeded but ACME finalization
returned 404 `urn:ietf:params:acme:error:malformed` ("Certificate not found"). cert-manager then
backs off for an hour or more. The operator had to walk the cluster objects by hand and run
`cmctl renew` against one Certificate.

After this change:

- `nagarectl domains tls HOST [--json]` shows the issuance chain for one hostname: the DomainMapping,
  Knative Certificate, cert-manager Certificate, latest CertificateRequest, ACME Order and any
  Challenges. For each it gives the phase, a bounded upstream error, the failed attempt count and
  when cert-manager will retry. It classifies the result as `ready`, `issuing`, `waiting-retry` or
  `failed`.
- `nagarectl domains tls HOST --renew --yes` triggers one re-issuance of exactly that host's
  cert-manager Certificate. It refuses anything this context does not own, and it refuses while
  issuance is already in progress or the certificate is Ready.
- A deploy that times out on a certificate prints the same one-line diagnosis and names the
  command, and `docs/user/cluster-bootstrap.md` documents the recovery: diagnose, renew, then
  `inventory resume TX --yes`.


## Progress

- [ ] M1: Prove the renew mechanism against real cert-manager v1.20.2. Patching the Certificate's
  status subresource with condition `Issuing=True` (what `cmctl renew` does) creates a new
  CertificateRequest even while `lastFailureTime` backoff is active. Pass: a recorded transcript on a
  disposable local k3d context with a self-signed issuer and a forced failure. It shows the
  condition patch, the new CertificateRequest's revision, the result, and the exact `kubectl`
  arguments used.
- [ ] M2: `domains tls HOST [--json]` reads and classifies the chain. Pass: `Nagare.Test.Domains`
  cases over JSON fixtures for ready, pending DNS-01 challenge, failed finalization (the IR-28 404),
  rate limited (`urn:ietf:params:acme:error:rateLimited`) and waiting-retry. Each asserts the human
  lines and the JSON, and that no fixture's Secret data or private key text appears in either.
- [ ] M3: `--renew --yes` triggers one re-issuance through the M1 mechanism. Pass: recording-kubectl
  tests show exactly one status patch for an owned failed host. They show zero patches for a host
  owned by another context, a host with no Nagare DomainMapping, a namespace-wildcard certificate,
  a Ready certificate and one already Issuing. The command is registered as `bounded` in
  `scripts/audit-managed-commands.py`.
- [ ] M4: The deploy's certificate timeout includes the M2 one-line diagnosis and the renew
  command. `docs/user/cluster-bootstrap.md` has a "Certificate did not issue" section, and
  `docs/user/reference.md` lists the command. IR-28 is marked `completed`. Pass: `just gate-fast`
  is green, then `just land`. The M1 local context is re-run end to end once with the packaged
  `nagarectl`: forced failure, diagnose, renew, Ready, `inventory resume` converges, with routes and
  access grants unchanged.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Renew by patching the cert-manager Certificate's status with
  `Issuing=True`, reason `ManuallyTriggered`, using `kubectl patch --subresource=status`. Do not
  ship `cmctl`. This is the mechanism cert-manager documents for `cmctl renew`, and it needs no new
  tool in the operator package. M1 proves it on the pinned version before any code depends on it.
- Decision (2026-10-13): One trigger per invocation, refused while `Issuing=True` or `Ready=True`.
  A manual trigger bypasses cert-manager's failure backoff by design. Backoff is respected by never
  looping and by showing `failedIssuanceAttempts` and the next retry time first. The IR's "no
  unbounded retries" is met because Nagare never retries on its own.
- Decision (2026-10-13): Ownership is proved by walking down from the DomainMapping, never by name.
  The DomainMapping for HOST must carry this context's `nagare.dev/context-id` annotation. The
  Knative Certificate must have an ownerReference to that DomainMapping's uid. The cert-manager
  Certificate must have an ownerReference to that Knative Certificate's uid and use the same Secret
  (the `buildChain` rule in `src/Nagare/Cluster/CertificateMigration.hs`). Namespace-wildcard
  certificates are diagnosed but never renewed by this command.
- Decision (2026-10-13): The renew is a bounded operator command, not an inventory transaction.
  It changes no desired state and no Nagare-owned resource. It writes one status condition on an
  object net-certmanager owns. Route class `bounded`.
- Decision (2026-10-13): Delete the unused `src/Nagare/Domain/Tls.hs` and its tests. Production
  code does not import it (only `test/Nagare/Test/Domains.hs` and `Suite.hs` do). The live surface
  is `src/Nagare/Ops/Domains.hs`, which this plan extends.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

How TLS works for a Nagare hostname: a Knative DomainMapping (in the app namespace, or in
`nagare-system` for a protected site) maps HOST to a Service. With TLS on, net-certmanager creates a
Knative Certificate (`certificates.networking.internal.knative.dev`) owned by the DomainMapping, and
a cert-manager Certificate (`certificates.cert-manager.io`) owned by that one. cert-manager issues
through the `letsencrypt-dns` ClusterIssuer using DNS-01. Each attempt is a CertificateRequest,
which for ACME has an Order (`orders.acme.cert-manager.io`), which has Challenges. A failed attempt
sets `status.lastFailureTime` and `status.failedIssuanceAttempts` on the Certificate, and
cert-manager waits before retrying, starting at one hour and doubling. Versions are pinned:
cert-manager v1.20.2 (`cluster/bootstrap/vendor/cert-manager-v1.20.2.yaml`) and net-certmanager
v1.14.0.

What exists, under `cli/nagarectl/`:

- `src/Nagare/Ops/Domains.hs` backs `nagarectl domains list|check [--json]`
  (`app/Nagare/Cli/Commands/Domains.hs`, parsed in `app/Nagare/Cli/Parser/Operations.hs` around
  lines 140–161). It lists both Certificate kinds with kubectl through a `ToolRunner` seam
  (`queryDomainRowsWith`). It reads only the `Ready` condition into `CertificateEvidence` and
  guesses failure by looking for words like "fail" in the message (`looksFailed`). JSON is
  `domainReportValue` (`schemaVersion` 1).
- `src/Nagare/Domain/Tls.hs` is a richer older checker that no production code calls.
- `src/Nagare/Cluster/CertificateMigration.hs` parses Certificates with uid, ownerReferences,
  issuer and secretName (`parseCertificate`). `buildChain` links a Knative Certificate to the one
  cert-manager Certificate it owns. Reuse those parsers.
- `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` (around lines 336–351) waits for
  DomainMapping readiness, then for `status.url` to turn `https://` when the mapping was HTTP
  downgraded. On timeout it returns
  `AdapterEffectAmbiguous "Kubernetes … did not prove readiness; reobserve before retry"`. The run
  then prints `stopped <tx> at <op>: …`, and the operator resumes with `inventory resume TX --yes`.
- Nagare-managed objects carry the `nagare.dev/context-id` and `nagare.dev/resource-id`
  annotations (`KubernetesRuntime.hs`, around lines 423–436).
- Tests: `test/Nagare/Test/Domains.hs` (`domainsTests`, which already has ACME failure-detail
  cases) uses a recording kubectl. Fixtures are inline JSON with only a Ready condition.
- New commands need a constructor in `app/Nagare/Cli/Options.hs`, a route in `Dispatch.hs`, a
  parser, and a route class in `scripts/audit-managed-commands.py` (`DomainsCommand` currently
  lists `DomainsList DomainsCheck` as `read`), mirrored in
  `docs/architecture/managed-resource-coverage.md`.
- Docs: `docs/user/cluster-bootstrap.md` has "DNS and TLS model" and "Verify" (raw `kubectl get
  certificate,certificaterequest,order -A`). There is no failed-issuance procedure.

ADRs: [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) makes domain routing
and TLS ownership explicit, and the ownership walk follows it.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): M2 and M3
are proved with fixtures and a recording kubectl. M1 is the one real-API experiment, done once to
validate cert-manager's semantics, and M4's local run confirms. No cloud run is part of acceptance.


## Plan of Work

### M1: Validate the renew mechanism

On a disposable local context (`mode=local`, k3d; see `docs/user/local-development.md`), apply
cert-manager v1.20.2 from the vendored manifest. Create a Certificate whose issuer fails, for
example an ACME issuer pointed at an unreachable directory, or a CA issuer whose Secret is
missing. Wait for `failedIssuanceAttempts` ≥ 1 and a `lastFailureTime`. Fix the issuer. Patch:

```bash
kubectl patch certificate NAME -n NS --subresource=status --type=merge \
  -p '{"status":{"conditions":[{"type":"Issuing","status":"True","reason":"ManuallyTriggered","message":"Certificate re-issuance manually triggered","lastTransitionTime":"<now>"}]}}'
```

A merge patch replaces the whole `conditions` list. If cert-manager rejects that, or drops Ready,
switch to a JSON patch that appends the condition, and record the exact form. Record that a new
CertificateRequest appears before the backoff would have expired, and that the Certificate turns
Ready. Save the transcript under `docs/audits/ep191-renew-mechanism-<date>/`. If the patch does not
trigger issuance on v1.20.2, stop and record it in the Decision Log before M3.

### M2: Diagnose

Add a module, `src/Nagare/Ops/CertificateChain.hs`, with a pure `classifyChain` from parsed objects
to a `ChainReport`. The report holds the host, the DomainMapping, each link's name/uid/phase,
bounded upstream detail (problem type and detail from Order `status.reason` and Challenge
`status.reason`, one line, at most 240 characters), `failedIssuanceAttempts`, `lastFailureTime`,
the computed next retry, and a verdict. Reading is one `kubectl get … -o json` per kind in the
DomainMapping's namespace, through the existing `ToolRunner`. Never read Secrets. The command is
`domains tls HOST [--json]`. The JSON carries `schemaVersion` 1 and the same fields. Make
`looksFailed` in `Ops/Domains.hs` use the verdict when the chain is available. Delete
`src/Nagare/Domain/Tls.hs` and its tests.

Add fixtures under `test/fixtures/certificate-chain/`, one directory per case, with redacted real
shapes. Include a decoy `tls.key` value in a Secret fixture so the redaction assertion means
something.

### M3: Renew

Add `--renew` (requires `--yes`). Run the ownership walk from the Decision Log, require the
verdict `failed` or `waiting-retry`, then issue the M1 patch once. Print the Certificate, the
patch, and "run `nagarectl domains tls HOST` to follow issuance; then
`nagarectl inventory resume TX --yes` if a deploy stopped on this certificate". Guard the
kubectl context with the existing context guard, as `domains check` does. Register it in
`scripts/audit-managed-commands.py` as `bounded` and in
`docs/architecture/managed-resource-coverage.md`.

### M4: Wire into the deploy and document

In `KubernetesRuntime.hs`, when the DomainMapping certificate wait fails, read the chain once and
append its one-line verdict and `nagarectl domains tls HOST` to the ambiguous message. A read
failure keeps today's message. Write the docs section, run the M4 local confirmation, and update
the IR record (`status: completed`, `completedAt`, `targetPlan`, `resolution`) and `log.md`.


## Concrete Steps

From `cli/nagarectl`:

```bash
cabal test nagarectl-test --test-options="-p '/Domains/ || /CertificateChain/'"
```

From the repository root:

```bash
python3 scripts/audit-managed-commands.py
just haskell-style-check && just gate-fast
just land
```


## Validation and Acceptance

| Case | `domains tls HOST` verdict | `--renew --yes` |
| --- | --- | --- |
| Ready certificate | `ready` | refused, nothing to renew |
| DNS-01 challenge pending | `issuing`, names the pending Challenge | refused, issuance in progress |
| Finalize 404 malformed (IR-28) | `failed`, shows the Order error and next retry | one status patch |
| Rate limited | `waiting-retry`, shows the problem type and retry time | one status patch |
| Host in another context, or no Nagare DomainMapping | refused, ownership | no patch |
| Namespace wildcard certificate | diagnosed | refused, wildcard |

Across all cases, no Secret data and no key text appear in the output, and the accepted routes,
access grants and inventory are unchanged.


## Idempotence and Recovery

`domains tls` is read-only. A renew is refused while issuance is in progress, so repeating it
cannot stack requests. If a renewed issuance fails again, cert-manager records the failure and
backs off as usual, and the operator sees it in `domains tls`. Nothing needs rolling back; the
patch only adds a status condition that cert-manager itself clears.


## Interfaces and Dependencies

New module `Nagare.Ops.CertificateChain` (`ChainReport`, `ChainVerdict`, `classifyChain`). New CLI
surface `nagarectl domains tls HOST [--json] [--renew --yes]`. cert-manager v1.20.2 status API;
`kubectl patch --subresource=status` (kubectl 1.24 or later). No new packaged tools.
