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


## Context and Orientation

Nagare is a personal platform-as-a-service. An operator's `nagarectl` command-line tool, written in Haskell under cli/nagarectl, provisions a GCP project with Pulumi, activates a NixOS host, bootstraps a single-node Kubernetes cluster, and deploys applications. Which project it targets is the active *context*: a flat file of `export VAR=value` lines under `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, parsed in Haskell by cli/nagarectl/src/Nagare/Target.hs (the `TargetProfile` record) and in Bash by scripts/lib/target.sh. A context has `mode=cloud` or `mode=local`; local mode runs everything on loopback substitutes and has no GCP project.

MasterPlan 23 introduces a *resource inventory*: typed declarations of everything Nagare manages, composed and validated before any change. Two earlier children matter here. [EP-144](144-define-typed-resource-scopes-and-validate-composed-inventories.md) defines the pure model in cli/nagare-dsl/src/Nagare/Resource. [EP-145](145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md) is this plan's one hard dependency. It delivers the *inventory store*, the durable record of accepted declarations, reviewed plans, and execution history for one context, in cli/nagarectl/src/Nagare/Inventory/Store.hs, with the journal in Journal.hs and execution in Execute.hs. That store holds three kinds of thing. *Immutable members* are files named by the SHA-256 digest of their bytes: scope documents, review bundles, native plan files, observations. The *journal* is a sequence of immutable, numbered event files per transaction, each linked to the previous by digest; an operation's intent is appended before its first effect and its completion afterward. The *head manifest* is one small mutable file naming the accepted and converged revisions, retained resources, any unresolved transaction, and the *executor claim*: which store client is currently executing which transaction.

EP-145 deliberately specifies the store as a record of *conditional writes*: publish an immutable member only if absent, append a journal event only at an unused sequence number, and replace the head only if it is still the version that was read. It ships a filesystem implementation under `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/<context>/inventory/` and an in-memory implementation, and runs its whole transaction test suite against both. It also takes a *process lock* with `GHC.IO.Handle.Lock` so that two processes on one machine cannot execute at once. This plan adds a third implementation of the same record and changes nothing about the protocol. If implementing it seems to require a protocol change, stop and record that in the MasterPlan, because it means EP-145's contract was not sufficient.

Google Cloud Storage (GCS) supplies the same three conditional writes. Every version of an object has a *generation*, a number GCS assigns. A write may carry the precondition "only if the current generation equals N"; N = 0 means "only if no live object has this name". A failed precondition is HTTP status 412 and changes nothing. Listing a prefix is strongly consistent. The state bucket has object versioning enabled, which keeps older versions of an overwritten object; this store overwrites only the head, so versioning gives the head a history for free.

The code this plan builds on already exists. cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs creates and configures the state bucket for a context whose `NAGARE_PULUMI_BACKEND` is `gcs`: pure argument builders such as `bucketDescribeArgs` and `bucketProjectNumberArgs`, an injectable `GcloudOps` record of `capture` and `execute` so tests use a recording fake, and `bucketOwnershipVerdict`, which refuses unless the bucket's owning project number equals the target project's. That last check exists because bucket names are global, so a bucket with the expected name may belong to someone else. cli/nagarectl/src/Nagare/Ops/ContextGuard.hs holds `projectGuardVerdict`, the Haskell form of the rule that no command acts on a project other than the active context's. In Target.hs, `PulumiBackendKind`, `parsePulumiBackendKind`, `effectivePulumiBackend` (which downgrades `gcs` to local for a local-mode context), `defaultGcsPulumiBackendUrl`, the context-file renderer near the `line "NAGARE_PULUMI_BACKEND"` entries, and `nagareStateDir` are the patterns to mirror. scripts/lib/target.sh resolves the same fields for shells. The `--pulumi-backend` options of `context create` and `init` are in cli/nagarectl/app/Main.hs. Unit tests for all of this live in cli/nagarectl/test/Spec.hs. scripts/migrate-pulumi-backend.sh is the precedent for moving state between backends, and docs/user/contexts.md documents it, including the warning that a shell opened before a migration keeps exporting the old backend.

Relevant decisions. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps mutable context state out of release payload workspaces. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires the project assertion and the bucket-ownership check on every cloud-mutating path; object writes to the state bucket are such a path. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) puts Pulumi state in a versioned, uniform-access, public-access-prevented bucket owned by the target project and keeps state out of git. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) and its 2026-09-16 amendment define the inventory architecture and the rule that the store's correctness rests on conditional writes only. Mori was searched and no cross-repository ADR applies.

Two integration points with sibling plans. [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md) brings the state bucket itself into the inventory and notes that the very first transaction of a new context must run on the local store, because the bucket does not exist yet; the migration command delivered here is how that first history moves. [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md) must not remove the last legacy application-deploy path, and [EP-150](150-integrate-resource-inventories-into-upgrades-and-release-verification.md) cannot close, until this plan is complete.


## Plan of Work

### M1 (prototype) — Prove the bucket provides the three conditional writes

This milestone is a labelled prototype. Its purpose is to replace assumptions about `gcloud storage` with recorded facts before the store is built on them, and to choose the transport. At its end there is a small module of pure argument builders, a read-back classifier with unit tests, a probe script, and a dated entry in Surprises & Discoveries.

Create cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs. Define `ObjectOps`, a record of three injectable effects in the style of `GcloudOps`: get an object with its generation, put an object under a condition, and list the names under a prefix. Define the outcome types so that "unknown" is never confused with "absent" (see Interfaces). Write the `gcloud` implementation: a put writes the bytes to a private temporary file and runs `gcloud storage cp <file> gs://… --if-generation-match=<N> --print-created-message`; a get runs `gcloud storage objects describe … --format=value(generation)` and `gcloud storage cat`, re-describing afterward and retrying when the generation moved between the two; a list runs `gcloud storage ls`. Keep each argument builder pure and test it in cli/nagarectl/test/Spec.hs beside the PulumiBackend builders.

Write the classifier that every put goes through. On tool success, return the new generation. On any failure, read the object back. If it now holds exactly the bytes we sent, our write landed and the failure was only in the reply. If it holds other bytes, or for a head replacement its generation is not the one we expected, the precondition failed. If a successful listing shows the name absent, or the head is unchanged at the expected generation, nothing happened and the caller may retry. If the read-back itself fails, the outcome is unknown and the caller must stop. Absence is established only by a successful listing that lacks the name; a failed `describe` proves nothing. Unit-test all four branches against a fake.

Add scripts/probe-inventory-object-store.sh. It sources scripts/lib/target.sh, calls `_require_target_project`, takes `--url gs://bucket/prefix` and `--expected-project`, refuses a local-mode context, asserts bucket ownership with `_require_bucket_in_target_project`, and then under a unique child prefix performs: create-if-absent on a new name (expect success), the same again (expect failure and an unchanged object), replace with the matching generation (expect success), replace with a stale generation (expect failure), a listing, and a get. It prints each command's exit status, the first line of its error output, and wall-clock time, and it never deletes anything. Running it writes objects to a real bucket, so rehearse it with `--dry-run` first and then ask the operator once for that bounded run, naming the context, bucket, and prefix. A disposable cloud context is preferred. While there, list the context's Pulumi prefix and confirm every Pulumi object lives under `.pulumi/`, so that an `inventory/` sibling cannot collide with it.

Decide the transport from the evidence. Keep `gcloud storage` if a failed precondition leaves the object unchanged and the median time for one conditional put including read-back on failure is at most three seconds. Otherwise implement the put and get effects against the GCS JSON API with http-client-tls, which nagarectl already depends on, using a token from `gcloud auth print-access-token` refreshed on a 401 response; find the library's API through Mori first. Either way the rest of the plan sees only `ObjectOps`. Record the measurements and the decision.

### M2 — The object-backed store, proven by the shared conformance suite

At the end of this milestone `Nagare.Inventory.Store.Object` implements EP-145's `InventoryStore` over `ObjectOps`, and EP-145's transaction suite passes against it using an in-memory bucket. No cloud access is involved.

Write the in-memory `ObjectOps` fake in the test tree: a map from name to generation and bytes behind an `IORef`, a monotonically increasing generation counter, strict precondition checks, and injectable faults: fail before writing, fail after writing (the ambiguous case), fail a read, and fail a listing. It must let two store clients share one bucket.

Create cli/nagarectl/src/Nagare/Inventory/Store/Object.hs. Use the same relative layout EP-145's filesystem store uses beneath `inventory/`, so that export, restore, and migration are a verified copy of members followed by a head install; do not invent a second layout. Publish-if-absent maps to a put with generation 0 under the member's digest name, and an existing member with equal bytes counts as success. Append-at-sequence maps to a put with generation 0 on the event's zero-padded sequence name. Replace-head maps to a put conditioned on the generation read with the snapshot. A `format` object, created once with generation 0, records the store format version and the ContextId; every open compares that ContextId with the local context binding and refuses a mismatch, so that a mistyped URL cannot attach one context to another's history.

Reads go through a local cache at `${XDG_CACHE_HOME:-$HOME/.cache}/nagare/<context>/inventory-blobs/`, keyed by digest, with private file modes. Immutable members are verified against their digest on every read from the cache and on every download, so the cache is never an authority and may be deleted at any time. The head and the journal listing are always read from the bucket.

Cross-machine exclusion uses EP-145's executor claim. Admission installs the claim with the head replacement that activates the transaction, so a second machine's admission fails its precondition, re-reads, finds the claim, and refuses with the claiming client's identity and start time. The store client identity is generated once per state root and kept at `<state root>/<context>/inventory-client-id`. When a claim belongs to another client, `inventory resume` refuses unless the operator passes `--take-over CLIENT_ID`, which is the operator's statement that the other executor is dead. Takeover replaces the claim and raises its epoch. Because intent is appended before every effect, an executor that was superseded loses its next append, re-reads the head, sees a claim that is not its own, and stops before causing that effect. State the remaining limit in the command's help and the documentation: if the other executor is alive and already inside an effect, takeover can let a recovery probe run beside it. The local process lock is still taken, under the state root, to serialize processes on one machine.

Add cli/nagarectl/test/InventoryObjectStoreSpec.hs and register it in the existing test lists. Run EP-145's transaction suite against this store over the fake. Add: two clients where the second admission is refused; takeover followed by the superseded client stopping before its next effect, with the recording adapter proving the effect did not run; each fault position, including a put that fails after writing being recognized as success; a `format` mismatch refusing; a poisoned cache entry being rejected and refetched; and a listing failure never being read as an empty journal.

### M3 — Context selection, guarded opening, and migration

At the end of this milestone a cloud context can opt in, and an existing local history can be moved without a window in which both stores accept writes.

Add `InventoryStoreKind` (`InventoryStoreLocal | InventoryStoreGcs`), `parseInventoryStoreKind`, `effectiveInventoryStore`, and `defaultGcsInventoryStoreUrl` to cli/nagarectl/src/Nagare/Target.hs, the two fields to `TargetProfile`, the two lines to the context-file renderer, and the parsing in both resolver paths, exactly as the Pulumi backend fields are handled. The default URL is `gs://<project>-nagare-pulumi-state/nagare/<context>/inventory`. A local-mode context is always downgraded to the local store. Mirror the fields in scripts/lib/target.sh with the same downgrade warning, add them to nagare.target.env.example, and add `--inventory-store` and `--inventory-store-url` to `context create` and `init` in cli/nagarectl/app/Main.hs. Update the canonical-variable list in CLAUDE.md's "GCP project isolation" section in the same change, since that file is the operating contract for agents.

Open the store by selection in one function. For GCS it first evaluates `projectGuardVerdict`, then asserts bucket ownership with the existing `bucketProjectNumberArgs`, `projectNumberArgs`, and `bucketOwnershipVerdict`, once per process and before the first write, failing closed when either number is unreadable. Generalize `bootstrapPulumiStateBucket` so the bucket is ensured when either the Pulumi backend or the inventory store needs it; do not write a second bootstrap.

Add `nagarectl inventory store status`, which prints the store kind and URL, the ContextId, the head digest and generation, any unresolved transaction, and the executor claim, and mutates nothing. Add `nagarectl inventory store migrate --to gcs|local [--dry-run] --yes`. It takes the process lock and refuses unless the source is quiescent: no unresolved transaction and no claim. It refuses a destination whose `format` names another ContextId. It copies immutable members and journal events with publish-if-absent, verifying digests, installs the head with generation 0, and then re-reads the entire destination through the normal open path and compares the head digest and every member. Only then does it write a tombstone into the source head, naming the destination, by an ordinary conditional head replacement; any command that opens a tombstoned store refuses, prints the destination, and reminds the operator to reload the shell. Last, it rewrites the two context fields through the existing context writer, which writes through symlinks as ADR 13 requires. The order matters. A crash after the tombstone and before the context rewrite leaves a context that still says `local` and a local store that refuses, which is safe and is finished by running the command again: it finds the tombstone, verifies the destination, and performs only the rewrite. The opposite order would leave a stale shell free to write to the old store. `--to local` is the same procedure in reverse and never deletes bucket objects.

Extend Spec.hs for the parsing, downgrade, default URL, and renderer, and InventoryObjectStoreSpec.hs for migration: interrupted at each step and rerun, destination already populated with the same history, destination belonging to another context, a non-quiescent source, and a tombstoned source refusing every mutating command.

### M4 — Live evidence, documentation, and durable decisions

At the end of this milestone the store has been exercised against a real bucket from two state roots, and the documents say what is and is not guaranteed.

Make InventoryObjectStoreSpec.hs able to run the same conformance group against a real bucket when `NAGARE_TEST_INVENTORY_STORE_URL` and `NAGARE_TEST_EXPECTED_PROJECT` are both set; otherwise that group reports itself skipped. It refuses when gcloud's active project is not the expected one or the bucket is not owned by it, works under a unique child prefix, uses only recording adapters inside the test binary, and deletes nothing. Add scripts/rehearse-inventory-store.sh as a thin launcher that, for a named context and expected project, runs `inventory store migrate --to gcs`, then sets `XDG_STATE_HOME` and `XDG_CACHE_HOME` to fresh temporary directories to stand in for a second machine and runs `inventory store status` and `inventory export`, comparing head digests and exported member digests with the first machine's. It contains no store logic. Both write to a real bucket: rehearse with their dry-run forms, then ask the operator once for the bounded sequence. Removing the rehearsal prefix afterward is a separate, separately approved command that names the exact prefix.

Add a section to docs/user/contexts.md after "Remote GCS Pulumi state", covering the two fields, the default URL, migration in both directions, the reload-your-shell warning, takeover and its limit, the fact that any mutation now needs bucket access, and that readers of the bucket can read private native bundles. Update docs/user/backups-and-disaster-recovery.md to say which store kinds are covered by which recovery path. docs/user is an OKF bundle with a log; follow its profile and add the log entries its contract requires. Amend ADR 13's decision on remote state to include the inventory store and restore its new-machine consequence, and add a short amendment to ADR 22 recording that the conditional-write contract was sufficient, or what had to change if it was not. Then distill this plan.


## Concrete Steps

Run everything from the repository root inside the project's development environment. Find dependency sources through Mori before relying on an API, and never search or read /nix/store.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
bash scripts/check-haskell-style.sh
bash scripts/probe-inventory-object-store.sh --dry-run \
  --url "gs://${CLOUDSDK_CORE_PROJECT}-nagare-pulumi-state/nagare/${NAGARE_CONTEXT}/inventory-probe" \
  --expected-project "${CLOUDSDK_CORE_PROJECT}"
```

The probe script, the rehearsal launcher, the `inventory store` commands, and InventoryObjectStoreSpec.hs are new surfaces delivered by this plan. The dry run prints the commands it would run and contacts nothing. The live probe prints one line per step; the second create-if-absent must report a failure and an unchanged object:

```text
create-if-absent  new-name        exit=0  0.9s  generation=1758000000000001
create-if-absent  same-name       exit=1  0.8s  object unchanged
replace           generation ok   exit=0  0.9s
replace           generation old  exit=1  0.8s  object unchanged
```

The figures above illustrate the shape only; record the real output in Surprises & Discoveries. The gated live conformance run is:

```bash
: "${NAGARE_TEST_INVENTORY_STORE_URL:?set a gs:// prefix in a disposable context}"
: "${NAGARE_TEST_EXPECTED_PROJECT:?set that context's exact GCP project}"
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct \
  --test-options='-p InventoryObjectStore')
```


## Validation and Acceptance

EP-145's complete transaction suite passes against the object-backed store over the in-memory bucket, unchanged. That is the primary acceptance: it shows the store is a drop-in implementation of the contract rather than a variant of it.

With two clients on one bucket, the second client's apply is refused and names the first client; after `--take-over`, the second client proceeds and the first stops before its next effect, which the recording adapter proves by showing that effect was never invoked. A put that fails after writing is treated as success; a put that fails before writing is retried; an unreadable read-back stops the transaction as unknown. A failed listing is never treated as an empty journal, and a failed get is never treated as absence. A store whose `format` names another context refuses to open. A corrupted cache file is rejected and refetched.

A local-mode context that asks for the GCS store is downgraded with a warning. A cloud context pointing at a bucket owned by another project refuses before any write. Migration interrupted at any step completes when rerun and never leaves both stores writable; after migration, a shell still exporting `NAGARE_INVENTORY_STORE=local` is refused by the tombstone with a message naming the bucket URL.

Live, the conformance group passes against a real bucket, and a second state root with an empty cache reports the same head digest and exports byte-identical members. Unit and fake-backed tests do not establish provider behavior; leave M4 incomplete if the live evidence cannot be obtained.


## Idempotence and Recovery

Every store write is conditional, so repeating any step is safe: republishing a member with equal bytes succeeds, re-appending an event with equal bytes succeeds, and a repeated head replacement either finds its own bytes or fails its precondition. The store never deletes or overwrites an immutable object. Migration is resumable by rerunning it and does not remove the source, which remains as a tombstoned, read-only fallback; reversing a migration is the same command with `--to local`. The probe, the live conformance run, and the rehearsal write only under their own unique prefixes and delete nothing; cleanup is a separate approved step naming the exact prefix. Object versioning on the bucket keeps earlier head versions should a head ever need to be inspected or restored by hand, which is a recovery action to plan and review, not something this store does on its own. If a guard or ownership check refuses, stop and report it; do not work around it.


## Interfaces and Dependencies

Hard dependency: [EP-145](145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md) must be complete, because this plan implements its `InventoryStore` record, reuses its conformance suite, its executor claim in the head manifest, its export/restore, and its digest module. It needs nothing from EP-146, EP-147, EP-148, or EP-149 and can run beside them. It does not change the head, journal, or member formats; those belong to EP-145.

```haskell
-- cli/nagarectl/src/Nagare/Inventory/Store/ObjectOps.hs
newtype ObjectName = ObjectName Text
newtype Generation = Generation Integer

data PutCondition = IfAbsent | IfGenerationMatches !Generation

data GetOutcome
  = ObjectFound !Generation !ByteString
  | ObjectAbsent          -- only after a successful listing that lacks the name
  | GetUnknown !Text

data PutOutcome
  = PutWritten !Generation
  | PutPreconditionFailed
  | PutNoEffect !Text     -- confirmed unchanged; safe to retry
  | PutUnknown !Text      -- read-back failed; stop

data ObjectOps = ObjectOps
  { getObject :: !(ObjectName -> IO GetOutcome)
  , putObject :: !(PutCondition -> ObjectName -> ByteString -> IO PutOutcome)
  , listObjects :: !(ObjectName -> IO (Either Text [ObjectName]))
  }

gcloudObjectOps :: GcloudOps -> Text -> ObjectOps -- bucket URL prefix

-- cli/nagarectl/src/Nagare/Inventory/Store/Object.hs
objectInventoryStore
  :: ObjectOps -> StoreClientId -> ContextId -> FilePath -- cache directory
  -> IO (Either StoreError InventoryStore)

-- cli/nagarectl/src/Nagare/Inventory/Store/Open.hs
openInventoryStore :: ResolvedContext -> IO (Either StoreError InventoryStore)

migrateInventoryStore
  :: MigrationDirection -> InventoryStore -> InventoryStore
  -> IO (Either StoreError MigrationResult)
```

`GcloudOps` is the existing record in Nagare.Ops.PulumiBackend; move it to a shared module if importing it from there creates a cycle. `InventoryStore`, `StoreError`, `ContextId`, and the transaction suite are EP-145's and EP-144's. Use existing dependencies only: process, temporary, directory, filepath, bytestring, text, crypton for digests through EP-145's digest module, and, only if M1's criteria require it, http-client and http-client-tls, which nagarectl already lists. No dependency version changes are prescribed; if one becomes necessary, locate the source through Mori and verify the released version against the package registry and upstream tags first.
