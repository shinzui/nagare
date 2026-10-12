---
id: 151
slug: store-inventory-history-in-the-context-state-bucket-with-conditional-writes
title: "Store inventory history in the context state bucket with conditional writes"
kind: exec-plan
created_at: 2026-09-17T04:11:08Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-17T04:11:08Z
  revisions:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:51:14Z
      mode: "implement"
      note: "Begin conditional GCS object transport and shared store backend"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T20:05:04Z
      mode: "implement"
      note: "Complete live GCS probe, conformance, and two-state-root migration recovery"
---

# Store inventory history in the context state bucket with conditional writes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this change an operator can keep a cloud context's resource-inventory history in that context's state bucket, beside its Pulumi state, instead of in a private directory on one workstation. A second machine that has the two repository clones and gcloud credentials sees the same ownership history and can plan, apply, and resume. Two machines cannot both change the context: the second is refused and told which machine holds the work, rather than diverging silently. A lost laptop no longer takes with it the only record of which resources Nagare is allowed to delete.

You can see it working in two ways. In the test suite, two store clients share one in-memory bucket and the second client's apply is refused until an explicit takeover. Against a real bucket, `nagarectl inventory store migrate --to gcs` moves an existing local history, and `nagarectl inventory store status` run from a second, empty state directory prints the same head digest as the first machine.

This is the eighth child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). That initiative makes a typed inventory the authority for what Nagare owns and may delete. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) already moved the comparable Pulumi state off the workstation so that "a new machine needs a clone of both repositories, the symlinks, and gcloud credentials". Without this plan the inventory would quietly break that promise, and after application deploys move onto the inventory, every deploy from any other machine would refuse.

## Progress

- [x] (2026-09-23) M1/M2 partial: Added generation-guarded `gcloud storage` argv builders, a read-back classifier that distinguishes landed, conflicting, retryable, and unknown writes, and a GCS transport that confirms absence only after a successful listing. An object-backed InventoryStore passes the existing conditional-store fixture over a shared fake; tests also refuse stale two-client head replacement, unknown listing, and a foreign context format binding. A poisoned immutable cache is refetched. The bounded probe's dry run passes for the `labs` context. Live provider semantics and full fault-injection conformance remain open.
- [x] (2026-09-23) M2/M3 partial: Added a persistent per-state-root client identity, a local process file lock for the object store, explicit resume takeover with an incremented claim epoch, and a claim recheck immediately before each effect. Context selection now carries the GCS URL and local downgrade; guarded opens verify the persisted project and bucket owner. A migration copies members and head, verifies the destination, conditionally tombstones the source, then rewrites the context through its symlink. The fake migration reruns after interruption and refuses old-source writes; 28 focused tests pass. Further interruption and superseded-executor tests, live provider proof, and full-suite verification remain.
- [x] (2026-09-23) M4 partial: Documented inventory selection, migration, takeover, backup boundaries, and bucket-reader access in operator guides and amendments to ADR 13 and ADR 22. The live two-state-root rehearsal remains open.
- [x] (2026-09-23) M4 partial: Added a test group gated by both real-bucket environment variables and a thin two-state-root rehearsal script. The rehearsal dry run passes for `labs`; real execution remains pending the operator's separate go-ahead.
- [x] (2026-09-23) M2/M3 partial: The object store now takes a workstation process file lock; a second client sharing the lock path is refused. Migration supports returning to a previously tombstoned local store by verifying and replacing that tombstone, and tests prove both directions and an interrupted destination-head write. The read-back suite also models a write that landed before its acknowledgement.
- [x] (2026-09-23) M3 partial: Read-only export now opens an existing history without creating a missing remote format object or client identity, takes the same workstation file lock, and refuses an uninitialized or tombstoned head.
- [x] (2026-09-23) M3 partial: Migration dry-run now checks the target bucket's owning project and any existing destination binding/head through read-only operations, so it refuses a foreign or divergent destination before saying the move is ready. Local disposable export produced a head whose SHA-256 matches `inventory store status`; the 721-test CLI suite passes.
- [x] (2026-09-23) M3 partial: Migration now installs an inactive destination head, verifies the copy, tombstones the source, and only then activates the destination. Fault fixtures interrupt before the source tombstone and after it but before destination activation; both intermediate states refuse a second writable store, and the latter resumes. The 723-test CLI suite and style check pass. Live two-root proof remains open.
- [x] (2026-09-23) M2 partial: A full reviewed transaction on the shared fake bucket now injects a journal put whose bytes land before its acknowledgement is lost. Read-back classifies the put as successful; a second client replays the completed transaction without repeating its adapter effect. The focused two-test pattern passes. Wider fault positions and live conformance remain open.
- [x] (2026-09-23) M4 rehearsal preparation: The launcher now accepts `--nagarectl` (or `NAGARECTL_BIN`) so its real run uses the current source build rather than the older installed release. A `labs` dry run with the explicit source binary passed; the real rehearsal still awaits its own authorization.
- [x] (2026-09-23) M4 isolated source preparation: The workstation's normal `labs` state root has no initialized inventory store, so an isolated `XDG_STATE_HOME` held one accepted, converged empty-scope review with zero resource operations. An isolated copy of the context config pointed its GCS inventory URL to `gs://tan-ng-labs-nagare-pulumi-state/nagare/labs/inventory/rehearsal-7ac17399a03f4a45abf9c68a49b3493f`; migration dry-run passed against this exact destination. The authorized live rehearsal later rewrote only the copied config and retained remote objects under that unique child.
- [x] (2026-09-23) M2 partial: Two clients sharing a fake bucket now exercise actual admission: while the first client's reviewed transaction holds the head claim, the second client's admission refuses with `active-transaction` before any adapter effect. The focused claim-pattern tests pass.
- [x] (2026-09-23) M4 live: The gated real-bucket conditional-store contract passed in 73.43 seconds under unique prefix `gs://tan-ng-labs-nagare-pulumi-state/nagare/labs/inventory/rehearsal-7423bc0c7e291535c6dfcc423368656b9f9438e1c2d9c30c4ab3169a9ac3ce58`. A first isolated two-root rehearsal reached remote activation but its final verification refused duplicate `head.json` entries returned by bucket listing. Name deduplication and a regression fixture fixed that transport interpretation. The same prefix was resumed; migration committed, the copied context was rewritten, and a fresh second state/cache root reported head digest `5fa2e88e3f22c83ece53f81b2eb32ad41c8dfac47fe8f0a928068d9b1f7a8417` with byte-identical exported members. The full 732-test CLI suite and Haskell structural style check pass. Neither prefix was deleted.
- [x] (2026-09-23) M1 (prototype): write the pure `gcloud storage` argument builders and the read-back classifier with a recording fake.
- [x] (2026-09-23) M1 (prototype): the operator authorized and the bounded live `labs` probe passed under a unique `inventory-probe/` child. Results, timings, and retained object are recorded below.
- [x] (2026-09-23) M1 (prototype): retain the `gcloud storage` transport with generation preconditions and read-back classification; the live probe confirmed its required semantics.
- [x] (2026-09-23) M2: implement the in-memory `ObjectOps` fake with generations and injected failures before a head write, after a journal write, on read-back, and on listing.
- [x] (2026-09-23) M2: implement the object-backed `InventoryStore` over `ObjectOps`, with the verified local blob cache.
- [x] (2026-09-23) M2: the shared store contract and reviewed transaction fixtures pass over the object backend, including two-client admission, takeover, superseded-executor refusal, and ambiguous-write recovery.
- [x] (2026-09-23) M3: add the `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL` context fields in Haskell and Bash, with the local-mode downgrade.
- [x] (2026-09-23) M3: open the store by context selection with a persisted-project, ambient-project, and bucket-project-number assertion before mutation; the shared state-bucket bootstrap now runs when either Pulumi or inventory selects GCS. The decision log records why the Pulumi-stack-specific verdict is not used for inventory-only contexts.
- [x] (2026-09-23) M3: implement `inventory store status` and `inventory store migrate` with source tombstones and resumable ordering; fake interruption fixtures and the interrupted live command-path rehearsal passed.
- [x] (2026-09-23) M4: the gated live conformance suite and isolated two-state-root rehearsal passed; evidence and retained prefixes are recorded above.
- [x] (2026-09-23) M4: update user documentation, CLAUDE.md's variable list, ADR 13, and ADR 22, including live rehearsal findings and recovery limits.
- [x] (2026-09-23) ExecPlan 151 complete: M1–M4, 732 CLI tests, the gated live GCS contract, and two-state-root migration/replay proof passed. The local source fixture and cloud objects remain available for review.

## Surprises & Discoveries

Recorded while drafting, 2026-09-16, with Google Cloud SDK 570.0.0 on the operator's workstation, from `gcloud storage <command> --help` only (no project was contacted): `gcloud storage cp` accepts `--if-generation-match=GENERATION`, `--if-metageneration-match`, `--no-clobber`, and `--print-created-message`; `gcloud storage rm` accepts `--if-generation-match`; `gcloud storage cat` and `gcloud storage objects describe` accept no precondition flag. Whether `--if-generation-match=0` is passed through as "must not exist", what a failed precondition prints, and how long one call takes are not yet known and are what M1 measures.

On macOS, opening a file already locked by another Haskell handle can itself raise `ResourceBusy`, before `hTryLock` runs. The object backend's workstation lock normalizes that exception to `StoreBusy`; a two-client fixture now verifies the refusal. A reverse migration also found that the old local destination is intentionally tombstoned. Migration accepts that tombstone only when it names the current source store, copies and verifies the newer history, and stages the destination before tombstoning the source.

The first migration implementation copied an active head to the destination before tombstoning the source. That ordering allowed both stores to accept writes during the handoff, despite a quiescence check and local locks. The destination now carries a tombstone pointing back to the source until the source's conditional tombstone succeeds. A crash between those writes leaves both stores inactive; rerunning migration activates the verified destination.

2026-09-23, bounded live `labs` probe against `gs://tan-ng-labs-nagare-pulumi-state/nagare/labs/inventory-probe/probe-20260923T192516Z-91590/conditional.txt`: create-if-absent (`--if-generation-match=0`) succeeded in 2.893 s; repeating it failed with exit 1 in 2.763 s; replacement at the observed generation succeeded in 2.699 s; repeating that stale generation failed with exit 1 in 2.857 s. `gcloud storage cat` returned `second`, and listing returned the one test object (twice because its two generations are visible). The probe printed `Copying file://... to gs://...` as the first stderr line for both success and failure, so that line alone does not explain the failure; the conditional outcomes and final read-back establish the semantics. The single object and its versions remain under the named prefix for review. This approval covered this one-object probe, not the wider conformance or two-state-root migration rehearsal.

The read-only bucket listing found 258 Pulumi objects under `nagare/labs/.pulumi/` and two listed versions under `nagare/labs/inventory-probe/`; no Pulumi object used the sibling `inventory/` path. This establishes the planned prefix separation for the current `labs` bucket.

The installed `nagarectl` predates these inventory store commands, and the ordinary `labs` state root has no initialized local inventory. The live two-root rehearsal therefore needs the current source binary and an isolated local fixture. The prepared fixture holds one empty scope and a reviewed, converged transaction; its copied context config points to a unique child beneath `inventory/`, leaving the ordinary context file and default inventory prefix untouched.

The live rehearsal found that `gcloud storage objects list .../**` can return the same logical object name twice after a generation replacement. Its first pass refused at final member verification, after destination activation but before rewriting the copied context file. The source had a migration tombstone and the destination held the matching active head, so no second writer was admitted. Object listings now deduplicate relative names, and migration dry-run recognizes the valid interrupted handoff by the recorded head digest. Rerunning the same migration finished safely. The conformance prefix listed four objects; the migration prefix listed seven entries for six distinct names because `head.json` appeared twice.

## Decision Log

- Decision: Implement the shared store as a single-writer home for one context's history, not as a distributed coordinator. There is no lease, heartbeat, or background process.
  Rationale: The operator-driven CLI has no process that could renew a lease during a ten-minute Pulumi apply, and MasterPlan 23 excludes a daemon and a distributed scheduler. Conditional writes already give the property that matters: a second writer fails instead of diverging. What they cannot give is proof that a silent executor is dead, so that one judgment stays with the operator as an explicit takeover.
  Date: 2026-09-16

- Decision: Use a real shared store rather than replicating a local store to the bucket or relying on export/restore.
  Rationale: With replication, two machines can restore the same copy, both apply, and each later believe it may retire what the other created. The state at risk is deletion authority. A head object replaced only when its generation still matches makes that impossible, and because EP-145 already specifies the store as conditional writes, the real store costs about what replication would.
  Date: 2026-09-16

- Decision: Select the store with its own context fields, `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL`, defaulting to `local`, rather than inferring it from `NAGARE_PULUMI_BACKEND`.
  Rationale: Contexts that already use the GCS Pulumi backend will run the filesystem inventory store between EP-145 and this plan, so a migration step exists regardless; an explicit field makes the move a reviewed act instead of a side effect of upgrading the CLI. It mirrors how ExecPlan 93 introduced the Pulumi backend fields, including the local-mode downgrade.
  Date: 2026-09-16

- Decision: Default the store to the existing state bucket under a sibling prefix, `gs://<project>-nagare-pulumi-state/nagare/<context>/inventory`, and accept the same trust boundary as Pulumi state. No client-side encryption is added here.
  Rationale: ADR 13 already accepts that principals who can read the state bucket can read Pulumi state, which contains plaintext inputs. Private native bundles in the inventory are the same class of data, and EP-145 keeps secret values out of reviews and evidence. An operator who wants a narrower audience sets the URL to a separate bucket.
  Date: 2026-09-16

- Decision: Classify the result of every conditional write by reading the object back, never by parsing a tool's error text; establish absence only by a successful listing that lacks the name.
  Rationale: MasterPlan 23 requires that a failed query is "unknown", never "absent". A timeout can follow a write that landed. Comparing the bytes now stored with the bytes we sent distinguishes "our write landed", "someone else holds this name", and "nothing happened" with the same code for every transport.
  Date: 2026-09-16

- Decision: Keep `gcloud storage` as the object transport for this inventory store.
  Rationale: The live `labs` probe confirmed create-if-absent and observed-generation replacement, rejected both duplicate and stale writes, and read back the final bytes. The four conditional copies took 2.699–2.893 s each. Its first error line was identical in shape for successful and rejected copies, validating the read-back classifier instead of error-text parsing. No second transport is needed for the plan's operator-driven workload.
  Date: 2026-09-23

- Decision: Choosing a remote store means the store itself needs GCS access. The property that a proven Pulumi phase is skipped without running Pulumi or calling the provider is kept; "fully offline resume" is not, for contexts that opt in.
  Rationale: This is the same trade the GCS Pulumi backend made, and the local store remains available for contexts that need offline operation.
  Date: 2026-09-16

- Decision: The inventory GCS opener applies ADR 9's bucket-project-number assertion and checks the persisted and ambient context project. It does not call the Pulumi-specific `projectGuardVerdict`, which also requires a Pulumi stack probe and would reject an inventory-only GCS context before its stack exists.
  Rationale: Every object operation addresses the explicitly selected bucket URL. The bucket's owning project number, compared with the target project's number before opening a mutating store, is the mutation-site identity proof for that URL. The CLI never derives a project from ambient gcloud configuration.
  Date: 2026-09-23

## Outcomes & Retrospective

The live `labs` probe measured four conditional copies at 2.699–2.893 seconds and selected `gcloud storage` with generation guards and read-back classification. The gated real-bucket store contract passed in 73.43 seconds, and the isolated two-root rehearsal matched head digest `5fa2e88e3f22c83ece53f81b2eb32ad41c8dfac47fe8f0a928068d9b1f7a8417` and exact exported members after an interrupted migration was resumed. This evidence uses one reviewed empty scope in an isolated state root; it does not show a full production bootstrap migrating its 205 resources. The store still needs credentials on both machines and cannot prove whether another executor is alive during an explicit takeover. The prefixes above remain for review.

