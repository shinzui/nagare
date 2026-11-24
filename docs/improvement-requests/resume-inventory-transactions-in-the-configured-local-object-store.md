---
type: Improvement Request
title: Resume inventory transactions in the configured local object store
description: Resume a stopped Nagare inventory transaction against the local S3-compatible store that owns its original review and journal.
timestamp: "2026-11-24T16:39:55Z"
generated:
  by: codex-cli/gpt-6.2-sol
  at: "2026-11-24T16:39:55Z"
requestId: IR-54
status: proposed
origin: mori://shinzui/kotei/okf/friction-log/concepts/FRIC-108
originPlan: mori://shinzui/kotei/plans/159-authorize-repository-admission-and-environment-delivery-operations
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-24T16:40:23Z"
    document_timestamp: "2026-11-24T16:39:55Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.2-sol
    effort: unspecified
    context: Checked the v0.28.2 release tag and current master store-selection code against the observed v0.24.5 rehearsal failure.
acceptanceCriteria:
  - id: AC-1
    statement: Inventory resume selects the configured local object store and continues the original transaction under the original review.
    verification: Stop a reviewed image publication in a disposable local MinIO context, restore access to the fixture registry, and resume the recorded transaction with the released CLI. Compare the transaction ID, review digest, and accepted publication digest before and after recovery.
  - id: AC-2
    statement: Recovery preserves the journal's retry and settlement guarantees when a publication may already have succeeded.
    verification: Interrupt publication after the registry accepted the image and before final settlement. Resume the original transaction and check that the publication converges once and the active transaction clears. Repeat resume and verify the journal and registry remain stable.
  - id: AC-3
    statement: Recovery retains the existing authority checks for local filesystem journals and first cloud foundation transactions.
    verification: Run the filesystem and cloud foundation recovery checks. On the MinIO fixture, present a transaction ID from another context and verify refusal before any journal or registry write.
---

# Resume inventory transactions in the configured local object store

During Kotei's hosted delivery rehearsal, a stopped image publication left an
active Nagare inventory transaction. After registry access returned, inventory
close found that the interrupted operation was safe to retry and directed the
operator to resume. The v0.24.5 CLI rejected the MinIO URL with
`inventory object store URL must start with gs://`. A fixture-only CLI build
that selected MinIO directly recovered the original transaction. See
[Kotei FRIC-108](mori://shinzui/kotei/okf/friction-log/concepts/FRIC-108).

The released v0.28.2 source still routes non-filesystem stores from
`foundationResumeTarget` into `foundationStageTarget`. Store selection there
calls the GCS discovery adapter. This is a source observation on v0.28.2.
The live failure was observed on v0.24.5.

Use the selected context's local object store for normal transaction recovery.
Keep the cloud foundation recovery path for its bootstrap journal and preserve
the existing review identity, context binding, and per-operation recovery proofs.
