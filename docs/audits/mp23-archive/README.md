# MP-23 audit archive

This directory holds superseded proofs, experiments and raw results produced while implementing
[MasterPlan 23](../../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md).
They were moved here unchanged on 2026-10-02 so the active audit directory shows only current
material. Every accepted result keeps its credit; nothing here is a current instruction. Evidence
JSON files are byte-identical to their originals, so path strings inside them still name the
pre-move `docs/audits/<name>` location.

Current MP-23 material lives one level up:

- [mp23-findings.md](../mp23-findings.md) — the active findings tracker (open and verifying findings, plus the closed register).
- [mp23-findings-closed.md](mp23-findings-closed.md) — full text of closed findings.
- [plan-history/](plan-history/) — verbatim bodies of MasterPlan 23 and EP-153–160 before the 2026-10-02 consolidation.
- [mp23-evidence-ledger.md](../mp23-evidence-ledger.md) — dated checkpoint history, including text removed from plans during consolidation.
- [mp23-independent-verification-2026-10-02.md](../mp23-independent-verification-2026-10-02.md) and its results directory — the most recent independent verification.
- [mp23-prerelease-fixture-disposition.md](../mp23-prerelease-fixture-disposition.md) — the retired-fixture decision.
- `mp23-reproductions/` and `mp23-native-bootstrap-results-2026-10-02/` stay in place because scripts and test fixtures reference them by path.


## Archived documents

| File | Subject |
|---|---|
| [mp23-initial-audit.md](mp23-initial-audit.md) | First implementation audit |
| [mp23-verification.md](mp23-verification.md) | Independent verification log before 2026-10-02 (F01, F11 closure) |
| [mp23-design-reassessment.md](mp23-design-reassessment.md) | 2026-09-29 design reassessment: one serial operation driver |
| [mp23-operational-experiments.md](mp23-operational-experiments.md) | 2026-09-29 command-boundary experiments (E1–E10) |
| [mp23-rescue-proof.md](mp23-rescue-proof.md) | Production operation-driver proof |
| [mp23-selected-read-proof.md](mp23-selected-read-proof.md) | Selected observation and store-cost proof |
| [mp23-head-claims-proof.md](mp23-head-claims-proof.md) | Claim observations and selected publication |
| [mp23-active-startup-proof.md](mp23-active-startup-proof.md) | Active-command startup repair |
| [mp23-active-host-proof.md](mp23-active-host-proof.md) | Active transaction and host recovery checkpoint |
| [mp23-auth-replay-proof.md](mp23-auth-replay-proof.md) | GCS authentication failure and retained replay |
| [mp23-gcs-scale-proof.md](mp23-gcs-scale-proof.md) | Real GCS 500-event replay |
| [mp23-gogol-transport-proof.md](mp23-gogol-transport-proof.md) | Pinned Gogol transport |
| [mp23-gogol-integration-proof.md](mp23-gogol-integration-proof.md) | Gogol ObjectOps integration |
| [mp23-gogol-cli-proof.md](mp23-gogol-cli-proof.md) | Gogol command integration |
| [mp23-fresh-root-discovery-proof.md](mp23-fresh-root-discovery-proof.md) | Fresh-root GCS discovery investigation |
| [mp23-fresh-root-discovery-repair.md](mp23-fresh-root-discovery-repair.md) | Fresh-root discovery repair |
| [mp23-native-bootstrap-proof.md](mp23-native-bootstrap-proof.md) | Native bootstrap continuation, 2026-09-29 |
| [mp23-cloud-continuation-2026-09-30.md](mp23-cloud-continuation-2026-09-30.md) | Cloud continuation, 2026-09-30 |
| [mp23-manual-receipt-public-fixture.md](mp23-manual-receipt-public-fixture.md) | Manual receipt public-command fixture |
| [mp23-web-cleanup-public-fixture.md](mp23-web-cleanup-public-fixture.md) | Public web cleanup fixture |
| [mp23-effectful-restore-pilot.md](mp23-effectful-restore-pilot.md) | Effectful restore pilot (basis of the interpreter-first decision) |
| [mp23-effectful-collection-proof.md](mp23-effectful-collection-proof.md) | Local F20 collection and recovery proof |
| [mp23-reviewed-controller-collection-proof.md](mp23-reviewed-controller-collection-proof.md) | Reviewed Knative controller collection, local and native |
| [mp23-maintainability-performance.json](mp23-maintainability-performance.json) | Recorder measurements for cache/replay cost |

Each `*-results-<date>/` directory holds the raw output for the document with the matching prefix;
the `mp23-native-bootstrap-results-2026-09-29`, `-09-30` and `-10-01` directories hold installed
native run output cited from the evidence ledger.
