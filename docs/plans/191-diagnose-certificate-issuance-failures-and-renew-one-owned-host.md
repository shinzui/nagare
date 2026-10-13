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
  when cert-manager will retry. It classifies the result as `ready`, `issuing`, `failed`,
  `rate-limited` or `incomplete`.
- `nagarectl domains tls HOST --renew --yes` triggers one re-issuance of exactly that host's
  cert-manager Certificate. It refuses anything this context does not own, and it refuses unless
  the verdict is `failed`.
- A deploy that times out on a certificate prints the same one-line diagnosis and names the
  command, and `docs/user/cluster-bootstrap.md` documents the recovery: diagnose, renew, then
  `inventory resume TX --yes`.


## Progress

- [ ] M1: Prove the renew mechanism against real cert-manager v1.20.2 on a disposable local k3d
  context. A forced failure leaves the Certificate with `failedIssuanceAttempts` ≥ 1, a
  `lastFailureTime` and `Issuing=False`. The M3 JSON patch then sets `Issuing=True`, cert-manager
  deletes the failed CertificateRequest, creates a new one before the backoff expires, and the
  Certificate turns Ready. Pass: a transcript under `docs/audits/ep191-renew-mechanism-<date>/` with
  the exact `kubectl` arguments, the Certificate status before and after, both CertificateRequests'
  names and revisions, and the `ownerReferences` of one real DomainMapping's Knative and cert-manager
  Certificates.
- [ ] M2: `domains tls HOST [--json]` reads and classifies the chain. Pass: `Nagare.Test.Domains`
  cases over JSON fixtures for ready, pending DNS-01 challenge, failed finalization (the IR-28 404),
  rate limited (`urn:ietf:params:acme:error:rateLimited`), a missing link, and a ready certificate
  whose renewal failed. Each asserts the verdict, the human lines and the JSON, and that the decoy
  Secret data and key text appear in neither. `src/Nagare/Domain/Tls.hs` and its tests are gone.
- [ ] M3: `--renew --yes` triggers one re-issuance through the M1 patch. Pass: recording-kubectl
  tests show exactly one status patch for an owned `failed` host, printed after the full diagnosis.
  They show zero patches for a host owned by another context, a host with no Nagare DomainMapping, a
  namespace-wildcard certificate, and the `ready`, `issuing`, `rate-limited` and `incomplete`
  verdicts, and zero patches when the context guard refuses. The command is registered as `bounded`
  in `scripts/audit-managed-commands.py`.
- [ ] M4: The deploy's certificate timeout includes the M2 one-line diagnosis and the renew
  command. `docs/user/cluster-bootstrap.md` has a "Certificate did not issue" section, and
  `docs/user/reference.md` lists the command. IR-28 is marked `completed`. Pass: `just gate-fast`
  is green, then `just land`. The M1 local context is re-run end to end once with the packaged
  `nagarectl`: forced failure during a deploy, diagnose, renew, Ready, `inventory resume` converges,
  and `nagarectl access list` plus the DomainMapping `.spec` are identical before the failure and
  after the resume.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Renew by setting the cert-manager Certificate's `Issuing` condition to
  `True`, reason `ManuallyTriggered`, the state `cmctl renew` writes. Do not ship `cmctl`. The
  write is a JSON patch on the status subresource, built from the object just read: a `test` of
  `/metadata/resourceVersion`, then `replace` of the existing `Issuing` entry at its index (or `add`
  at `/status/conditions/-` when there is none). The condition carries `observedGeneration` =
  `metadata.generation` and `lastTransitionTime` = now. A merge patch would replace the whole
  `conditions` list, and appending a second `Issuing` entry is invalid because the CRD declares
  `conditions` a list map keyed by `type` (`cert-manager-v1.20.2.yaml`, around line 4674). The
  `test` makes a concurrent cert-manager write fail the patch instead of being overwritten. M1
  proves it on the pinned version before any code depends on it.
- Decision (2026-10-13): One trigger per invocation, allowed only for the verdict `failed`. A manual
  trigger bypasses cert-manager's failure backoff by design. Backoff is respected by never looping
  and by showing `failedIssuanceAttempts` and the next retry time first. The IR's "no unbounded
  retries" is met because Nagare never retries on its own.
- Decision (2026-10-13): A rate-limited failure is its own verdict, `rate-limited`, and renew
  refuses it. Re-triggering during an ACME rate limit spends more of the limit and cannot succeed
  before the retry time the CA gave. This is how AC-3's "respects issuer backoff" applies to the
  case where renewing would hurt.
- Decision (2026-10-13): Ownership is proved by walking down from the DomainMapping, never by name.
  The DomainMapping for HOST must carry this context's `nagare.dev/context-id` annotation, which the
  inventory stamps on every object it applies (`stampNative` in
  `src/Nagare/Inventory/Adapters/Kubernetes.hs`). The Knative Certificate must have an
  ownerReference to that DomainMapping's uid. The cert-manager Certificate must have an
  ownerReference to that Knative Certificate's uid and use the same Secret name (the same predicate
  as `buildChain` in `src/Nagare/Cluster/CertificateMigration.hs`). Namespace-wildcard certificates
  are diagnosed but never renewed by this command.
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
`nagare-system` for a protected site) maps HOST to a Service. Its `metadata.name` is HOST. With TLS
on, Knative creates a Knative Certificate (`certificates.networking.internal.knative.dev`) owned by
the DomainMapping, and net-certmanager creates a cert-manager Certificate
(`certificates.cert-manager.io`) owned by that one. In cloud contexts cert-manager issues through
the `letsencrypt-dns` ClusterIssuer using DNS-01; local contexts use the `nagare-local-ca` CA
ClusterIssuer (`docs/user/local-development.md`). Each attempt is a CertificateRequest owned by the
Certificate; for ACME it owns an Order (`orders.acme.cert-manager.io`), which owns Challenges.
Versions are pinned: cert-manager v1.20.2 (`cluster/bootstrap/vendor/cert-manager-v1.20.2.yaml`)
and net-certmanager v1.14.0.

cert-manager v1.20.2 behavior this plan relies on (read from upstream source at tag v1.20.2):

- The issuing controller records a failure only when the CertificateRequest is `Failed`, `Denied`
  or `InvalidRequest`. It then sets `status.lastFailureTime`, increments
  `status.failedIssuanceAttempts`, and sets `Issuing=False` with the request's reason. A request
  whose issuer is not Ready stays `Pending` and records no failure.
- The trigger controller does nothing while `Issuing=True`. Otherwise it waits
  `1h × 2^(failedIssuanceAttempts−1)`, capped at 32h, from `lastFailureTime` before setting
  `Issuing=True` itself.
- When `Issuing=True`, the request manager deletes a failed CertificateRequest for the next
  revision if its `status.failureTime` is before the `Issuing` condition's `lastTransitionTime`,
  then creates a new request. That is why the renew patch must stamp `lastTransitionTime` with the
  current time. Deleting the request also removes its Order and Challenges, so the failed attempt's
  evidence disappears once renew runs.

What exists, under `cli/nagarectl/`:

- `src/Nagare/Ops/Domains.hs` backs `nagarectl domains list|check [--json]`
  (`app/Nagare/Cli/Commands/Domains.hs`, parsed in `app/Nagare/Cli/Parser/Operations.hs` around
  lines 140–161). It lists both Certificate kinds with kubectl through a `ToolRunner` seam
  (`queryDomainRowsWith`, `type ToolRunner = String -> [String] -> IO (Observation ByteString)`). It
  reads only the `Ready` condition into `CertificateEvidence` and guesses failure by looking for
  words like "fail" in the message (`looksFailed`). JSON is `domainReportValue`
  (`schemaVersion` 1). It calls plain `kubectl` with the current kubeconfig context and has no
  cluster guard.
- `app/Nagare/Cli/Runtime/Cluster.hs` exports `guardKubernetesContext :: ActiveTarget -> IO (Either
  Text Text)`, the cluster guard used by platform apply and upgrade. It steps aside in local mode.
  The CLI derives this context's id as
  `Resource.mkContextId (contextNameText (active ^. #contextName))`
  (`app/Nagare/Cli/Inventory/Adapters.hs`, around line 150).
- `src/Nagare/Domain/Tls.hs` is a richer older checker that no production code calls. It is listed
  in `nagarectl.cabal` (around line 121) and tested as `domainTlsTests` in
  `test/Nagare/Test/Domains.hs`, registered in `test/Nagare/Test/Suite.hs` (around line 296).
- `src/Nagare/Cluster/CertificateMigration.hs` parses Certificates into `CertificateResource`
  (uid, owner uids, issuer, secretName, wildcard flag) with `parseCertificate`. It does not parse
  `status`. Its `buildChain` also requires the generated Secret, so it cannot be called as is: this
  plan reuses `parseCertificate` and the ownership predicate inside `buildChain`, and parses status
  separately.
- `src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` (around lines 336–351, `waitForCertificate`)
  waits for DomainMapping readiness, then for `status.url` to turn `https://` when the mapping was
  HTTP downgraded. On timeout it returns
  `AdapterEffectAmbiguous "Kubernetes DomainMapping certificate did not prove readiness; reobserve before retry"`.
  The run then prints `stopped <tx> at <op>: …`, and the operator resumes with
  `inventory resume TX --yes`. The adapter runs kubectl through `invoke config`, which carries the
  runtime's own cluster binding. The file is 1176 lines against a size allowance of 1180 in
  `scripts/haskell-size-allowances.json`, and allowances may only go down.
- Tests: `test/Nagare/Test/Domains.hs` (`domainsTests`, which already has ACME failure-detail
  cases) uses a recording kubectl. Fixtures are inline JSON with only a Ready condition.
- New commands need a constructor in `app/Nagare/Cli/Options.hs`, a route in `Dispatch.hs`, a
  parser, and a route class in `scripts/audit-managed-commands.py` (`DomainsCommand` currently
  lists `DomainsList DomainsCheck` as `read`), mirrored in
  `docs/architecture/managed-resource-coverage.md` (the `DomainsCommand` row counts 2
  constructors).
- Docs: `docs/user/cluster-bootstrap.md` has "DNS and TLS model" and "Verify" (raw `kubectl get
  certificate,certificaterequest,order -A`). There is no failed-issuance procedure.

ADRs: [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) makes domain routing
and TLS ownership explicit, and the ownership walk follows it.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): M2 and M3
are proved with fixtures and a recording kubectl. M1 is the one real-API experiment, done once to
validate cert-manager's semantics, and M4's local run confirms. No cloud run is part of acceptance.


## Plan of Work

### M1: Validate the renew mechanism

On a disposable local context (`mode=local`, k3d; see `docs/user/local-development.md`), which
already runs cert-manager v1.20.2 and the `nagare-local-ca` issuer. A missing CA Secret or an
unreachable ACME directory leaves the request `Pending`, not failed, so force the failure by denial:

1. Turn off cert-manager's automatic approval in this disposable cluster by adding
   `--controllers=*,-certificaterequests-approver` to the `cert-manager` Deployment's args.
2. Create a Certificate on `nagare-local-ca`. When its CertificateRequest appears, mark it
   `Denied` by status patch (condition `Denied=True`, reason `EP191ForcedFailure`, a message). Wait until the
   Certificate shows `failedIssuanceAttempts: 1`, a `lastFailureTime` and `Issuing=False`.
3. Restore automatic approval.
4. Read the Certificate and apply the renew patch with its `resourceVersion` and the index `I` of
   the `Issuing` entry:

```bash
kubectl patch certificates.cert-manager.io NAME -n NS --subresource=status --type=json -p '[
  {"op":"test","path":"/metadata/resourceVersion","value":"RV"},
  {"op":"replace","path":"/status/conditions/I","value":{"type":"Issuing","status":"True","reason":"ManuallyTriggered","message":"Certificate re-issuance manually triggered","observedGeneration":GEN,"lastTransitionTime":"NOW"}}
]'
```

Record that the denied CertificateRequest is deleted, a new one appears well inside the one-hour
backoff, and the Certificate turns Ready. Also record a stale `RV` failing the `test`. Save the
`ownerReferences` of one deployed app's DomainMapping, Knative Certificate and cert-manager
Certificate in the same directory; M2 fixtures are built from these shapes. If the patch does not
trigger issuance on v1.20.2, stop and record it in the Decision Log before M3.

### M2: Diagnose

Add a module, `src/Nagare/Ops/CertificateChain.hs`, with a pure `classifyChain` from parsed objects
to a `ChainReport`. The report holds the host, the DomainMapping, each link's name/uid/phase,
bounded upstream detail (problem type and detail from Order `status.reason`, Challenge
`status.reason`, and the CertificateRequest `Ready` message; one line, at most 240 characters),
`failedIssuanceAttempts`, `lastFailureTime`, the computed next retry, and a verdict:

- `incomplete`: a link below the DomainMapping is missing (name the missing kind).
- `issuing`: the Certificate has `Issuing=True`; name the pending Order or Challenge state.
- `rate-limited`: not `issuing`, and the latest failed Order's problem type is
  `urn:ietf:params:acme:error:rateLimited`.
- `failed`: not `issuing`, `Ready` is not `True`, and `lastFailureTime` is set.
- `ready`: `Ready=True`. A failed renewal of a still-valid certificate stays `ready` but still
  shows `lastFailureTime` and the attempt count.

The next retry is `lastFailureTime + min(1h × 2^(failedIssuanceAttempts−1), 32h)`.

Reading goes through the existing `ToolRunner`. Find the DomainMapping with
`kubectl get domainmappings.serving.knative.dev -A --field-selector metadata.name=HOST -o json`,
then do one `kubectl get … -o json` per remaining kind (Knative Certificate, cert-manager
Certificate, CertificateRequest, Order, Challenge) in its namespace. Never read Secrets. The command
is `domains tls HOST [--json]`. The JSON carries `schemaVersion` 1 and the same fields. Make
`looksFailed` in `Ops/Domains.hs` use the verdict when the chain is available. Delete
`src/Nagare/Domain/Tls.hs`, its `nagarectl.cabal` entry, `domainTlsTests` and its `Suite.hs`
group.

Add fixtures under `test/fixtures/certificate-chain/`, one directory per case, from the M1 shapes
and redacted real ACME errors. Include a decoy `tls.key` value in a Secret fixture so the redaction
assertion means something.

### M3: Renew

Add `--renew` (requires `--yes`). Run `guardKubernetesContext` first and stop if it refuses. Run the
ownership walk from the Decision Log against this context's id, require the verdict `failed`, print
the full diagnosis (the renew deletes the failed request and its Order), then apply the M1 patch
once. A failed `test` is reported as "Certificate changed while renewing; run `domains tls HOST`
again" and is not retried. Print the Certificate, the patch, and "run `nagarectl domains tls HOST`
to follow issuance; then `nagarectl inventory resume TX --yes` if a deploy stopped on this
certificate". Register it in `scripts/audit-managed-commands.py` as `bounded` and in
`docs/architecture/managed-resource-coverage.md` (row count 3).

### M4: Wire into the deploy and document

In `KubernetesRuntime.hs`, when `waitForCertificate` times out, read the chain once for the
DomainMapping's namespace and name, and append its one-line verdict and `nagarectl domains tls HOST`
to the ambiguous message. The read must go through the adapter's own `invoke config` (wrapped as a
`ToolRunner`), never `systemToolRunner`, so it reads the cluster the deploy is bound to. A read
failure keeps today's message. Keep the addition to a call into `Nagare.Ops.CertificateChain`; the
file has four lines of size allowance left, so move code out of it if the call does not fit.

Write the docs section, run the M4 local confirmation (the M1 denial method, triggered during a
deploy of a fresh hostname), and update the IR record (`status: completed`, `completedAt`,
`targetPlan`, `resolution`) and `docs/improvement-requests/log.md`.


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
| Ready, renewal failed | `ready`, shows last failure and attempts | refused, still valid |
| DNS-01 challenge pending | `issuing`, names the pending Challenge | refused, issuance in progress |
| Finalize 404 malformed (IR-28) | `failed`, shows the Order error and next retry | one status patch |
| Rate limited | `rate-limited`, shows the problem type and the CA's retry time | refused, rate limited |
| Knative or cert-manager Certificate missing | `incomplete`, names the missing link | refused |
| Host in another context, or no Nagare DomainMapping | refused, ownership | no patch |
| Namespace wildcard certificate | diagnosed | refused, wildcard |
| Cluster guard refuses | — | refused, no patch |

Across all cases, no Secret data and no key text appear in the output, and the accepted routes,
access grants and inventory are unchanged.


## Idempotence and Recovery

`domains tls` is read-only. A renew is allowed only for `failed`, and its patch moves the
Certificate to `Issuing=True`, so repeating it is refused and cannot stack requests. A concurrent
change makes the patch's `test` fail and nothing is written. If a renewed issuance fails again,
cert-manager records the failure and backs off as usual, and the operator sees it in `domains tls`.
Nothing needs rolling back; cert-manager resets the condition itself. The failed request and its
Order are deleted by cert-manager when the renew takes effect, so the printed diagnosis is the only
record of that attempt.


## Interfaces and Dependencies

New module `Nagare.Ops.CertificateChain` (`ChainReport`, `ChainVerdict`, `classifyChain`). New CLI
surface `nagarectl domains tls HOST [--json] [--renew --yes]`. cert-manager v1.20.2 status API;
`kubectl patch --subresource=status --type=json` (kubectl 1.24 or later). No new packaged tools.
