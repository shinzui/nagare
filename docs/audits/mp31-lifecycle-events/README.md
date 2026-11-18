# MasterPlan 31: the lifecycle worker on a disposable local context

EP-235 M3's native confirmation, 2026-11-17/18, on local context `ep235` (Colima `nagare-c4-amd64`,
k3s v1.34.6, x86_64 release images built from the candidate). Packaged `nagarectl` 0.21.0 at
`25bca345`; worker image `nagare-admin-api@sha256:37dc2212…0460d` (the admin API image, which carries
`nagare-events`). The record is [`local-drill-2026-11-18.tsv`](local-drill-2026-11-18.tsv): one
observation per line, no keys. It was produced by `scripts/lifecycle-events-drill.sh` after
`scripts/site-access-drill.sh` with `NAGARE_DRILL_LIFECYCLE=1 NAGARE_DRILL_BOOTSTRAP_ONLY=1`; steps
9–11 ran resumed (`NAGARE_DRILL_FROM`), and step 9's two lines were read from the proxy and receiver
logs because the resume had truncated the receiver's log (fixed in the drill since).

The receiver is the documented example (`cluster/examples/lifecycle-webhook-receiver`) behind a fault
proxy on the workstation, reached at the VM's host address and allowed by review.

| Behaviour | Observed |
| --- | --- |
| Site release to receiver | 28 s, one `app.deployed`; a no-op redeploy announced nothing |
| Unattended scheduled PostgreSQL backup | `database.backup.completed` 169 s after the wait began (15-minute schedule), no ingestion command |
| Its ingestion | `database.backup.accepted` 28 s later, naming the completion's event ID |
| Release while the worker is stopped | none while stopped; delivered once 35 s after it started |
| Receiver answering 500 | 2 attempts refused; the release converged meanwhile; delivered 6 s after recovery |
| Acknowledgement lost after processing | redelivered with the same IDs; the receiver deduplicated it |
| Worker restarted with a queued delivery | delivered after the restart, processed once |
| Delivery records | 9 deliveries, all acknowledged, 9 distinct events |
| Reviewed replay of release d1 | arrived under the original event ID; the site revision did not change |
| Worker access | reads only its named signing Secrets; cannot list Secrets; inventory mounted read-only; its object-store user lists backups and cannot write them |
| Loops | 10 source, 1 receipt and 29 delivery cycles, none failing; final platform replan 0 operations |

Found and fixed on the way, each with an offline test: the local MinIO grant Job is ordered after the
object store's bucket Job (242c06ed); ClusterRole updates in place, with recorded API traces
(4e1c436f); the example receiver builds as a cabal script, links the threaded runtime and
line-buffers its log. A new database's or subscription's signing Secret is readable after the
platform's next plan and apply (DOC-45).

Not covered here, deferred by the operator on 2026-11-17: cloud credential denials (F154) and a
release transition with queued deliveries (F155).

Cleanup: the `ep235` cluster and the drill roots under
`~/.local/state/nagare/releases/x86-work/ep235-drill*` are disposable; delete them with
`k3d cluster delete nagare-local` on that daemon and `rm -rf` of the roots.
