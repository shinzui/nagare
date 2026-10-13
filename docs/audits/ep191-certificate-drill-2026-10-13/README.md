# EP-191 M4: certificate failure, diagnose, renew and resume, 2026-10-13

The native confirmation of [EP-191](../../plans/191-diagnose-certificate-issuance-failures-and-renew-one-owned-host.md),
run once by [`drill.sh`](drill.sh) on a disposable local context (`site-access`, Colima profile
`nagare-mp23`, k3d, reset first) from an empty environment. The effect interpreters proved the
behaviour first; this run confirms it
([ADR 25](../../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

| what | value |
| --- | --- |
| candidate `nagarectl` | 0.6.2 at `5b13b0f005e5d67fc0d15768c575aa42701df793`, nix package `/nix/store/5134mlqa4iq9yrapj8zvd8dl94anvq44-nagarectl-0.6.2` |
| context | bootstrapped and the protected static site deployed by `scripts/site-access-drill.sh` ([`site-access-drill.log`](site-access-drill.log)); auth images `mp27-df54e94e` |
| failing host | preview `ep191`, a fresh hostname `ep191.protected-static-site.preview.127-0-0-1.sslip.io`, an enforcer DomainMapping in `nagare-system` |
| forced failure | with cert-manager's automatic approval off, the preview's CertificateRequest got the status an ACME failure leaves (`Ready=False` reason `Failed`, the IR-28 finalize 404 message), the method of [M1](../ep191-renew-mechanism-2026-10-13/README.md) |

## Timeline

| time (UTC) | step |
| --- | --- |
| 16:39:17 | team `engineering` granted on the production host under review, so the access comparison is not empty |
| 16:39:49 | preview apply running; its CertificateRequest forced to `Failed`; `failedIssuanceAttempts: 1`; approval restored; access lists and DomainMapping specs recorded (`*-before.*`) |
| 16:44:23 | the apply stopped after the five-minute certificate wait. It printed the diagnosis, then the stop line ([`preview-apply.log`](preview-apply.log)): `nagarectl: ep191…: certificate failed after 1 failed attempt: Failed to finalize Order: 404 urn:ietf:params:acme:error:malformed: Certificate not found (EP-191 M4 forced failure); cert-manager retries at 2026-10-13T17:39:49Z; run nagarectl domains tls ep191…`, then `ambiguous tx-fa88… at op-2016…` |
| 16:44:2x | `domains tls` reported `failed` with the chain and the next retry ([`tls-failed.txt`](tls-failed.txt), [`tls-failed.json`](tls-failed.json)); renew of the Ready production host was refused ([`renew-ready-refused.txt`](renew-ready-refused.txt)) |
| 16:44:26 | `domains tls ep191… --renew --yes` printed the diagnosis and wrote one patch ([`renew.txt`](renew.txt)) |
| 16:44:30 | verdict `ready` ([`tls-ready.txt`](tls-ready.txt)); a second renew was refused ([`renew-again-refused.txt`](renew-again-refused.txt)) |
| 16:44:30 | `inventory resume tx-fa88… --yes` printed `converged` ([`resume-1.log`](resume-1.log)) |
| 16:44:38 | `access list` for both hosts and the `.spec` of both DomainMappings were byte-identical before the failure and after the resume (`*-before.*`, `*-after.*`) |
| 16:44:40 | the anonymous preview answered 302 over HTTPS verified by the local CA |

[`timeline.log`](timeline.log) is the drill's own log; [`inventory-status.json`](inventory-status.json)
is the inventory after the resume. No secret appears in these files: the En API key was read into
the drill's process and never written.

## Defect found and fixed before this run

An earlier pass on `28c5254d` showed the diagnosis only in the journal. An ambiguous stop prints
`ambiguous TX at OP` and, by design, never prints journal detail. `5b13b0f0` also prints the bounded
diagnosis on stderr. That pass's diagnose, renew and resume steps behaved as above.
