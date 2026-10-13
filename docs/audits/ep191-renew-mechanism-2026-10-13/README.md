# EP-191 M1: the renew patch on cert-manager v1.20.2, 2026-10-13

The real-API experiment behind [EP-191](../../plans/191-diagnose-certificate-issuance-failures-and-renew-one-owned-host.md)'s
renew command, run once with [`run.sh`](run.sh) against the disposable k3d cluster that the
MasterPlan 27 site-access drill left on Colima profile `nagare-mp23` (context `site-access`,
cert-manager `quay.io/jetstack/cert-manager-controller:v1.20.2`, k3s v1.34.6, kubectl 1.37.0).

| what | result |
| --- | --- |
| forced failure | with automatic approval off, the CertificateRequest got the status an ACME failure leaves: `Approved=True`, `Ready=False` reason `Failed`, `failureTime`. cert-manager then set `failedIssuanceAttempts: 1`, `lastFailureTime` and `Issuing=False` reason `Failed` ([`certificate-failed.json`](certificate-failed.json)) |
| backoff | 30 s after approval was restored, no new request: the trigger controller waits 1 h |
| stale `resourceVersion` | the patch with `test /metadata/resourceVersion = "1"` was rejected (`The request is invalid`) and wrote nothing |
| renew patch | [`renew-patch.json`](renew-patch.json): `test` of the read `resourceVersion`, `replace` of `/status/conditions/1` (the `Issuing` entry) with `Issuing=True`, reason `ManuallyTriggered`, `observedGeneration` 1, `lastTransitionTime` now |
| after the patch | the failed request (uid `5408a77d-…`) was deleted and a new one with the same deterministic name `ep191-probe-1`, revision 1 (uid `1d043cec-…`), was approved and issued; the Certificate was `Ready=True` 1 s after the patch, with `failedIssuanceAttempts` and `lastFailureTime` cleared ([`certificate-renewed.json`](certificate-renewed.json), [`requests-renewed.jsonl`](requests-renewed.jsonl)) |
| ownership chain | [`ownership.json`](ownership.json): the DomainMapping carries `nagare.dev/context-id: site-access` and no owner; the Knative Certificate is controller-owned by the DomainMapping's uid; the cert-manager Certificate is controller-owned by the Knative Certificate's uid with the same `secretName`; its CertificateRequest is controller-owned by the cert-manager Certificate |

The full call log is [`transcript.txt`](transcript.txt).

## A denied request is not renewable

The first run forced the failure by denial (`EP191_FAILURE=denied`, kept in [`denied/`](denied/)).
The same renew patch then made things worse. cert-manager's request manager deletes a failed request
for the current revision only when its `Ready` reason is `Failed`
(`deleteCurrentFailedRequests` in `pkg/controller/certificates/requestmanager` at v1.20.2). The
issuing controller skips such a stale request only under the same condition and otherwise fails the
issuance again. So a `Denied` request counted a second failure: `failedIssuanceAttempts: 2`,
`Issuing=False`, and two hours of backoff ([`denied/certificate-renewed.json`](denied/certificate-renewed.json)). Renew therefore
requires the latest request's `Ready` reason to be `Failed`.
