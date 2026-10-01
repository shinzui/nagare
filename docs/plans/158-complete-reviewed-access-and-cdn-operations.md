---
id: 158
slug: complete-reviewed-access-and-cdn-operations
title: "Complete reviewed access and CDN operations"
kind: exec-plan
created_at: 2026-09-26T22:14:13Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-26T22:14:13Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T03:11:58Z
      mode: "update"
      note: "Pull M1 forward as MP-23 safe-use prerequisite; align with 2026-09-28 reduction"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T13:58:23Z
      mode: "implement"
      note: "Implement independent reviewed tuple scope, private guarded HTTP transport and saved public grant/revoke routes"
---

# Complete reviewed access and CDN operations

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture


Operators can grant and revoke access, synchronize the protected-app portal, and purge or disable CDN routing through reviewed operations. Each command changes only its selected grant, hostname, or authorized contribution; unrelated apps and platform scope revisions remain intact.


## Progress

**Installed repair and exact recovery handoff (2026-10-01).** Installed `f18c318d` passes the local platform gate (213 verification-only operations, zero provider effects, 19 unchanged content digests and 35 Ready/Succeeded Pods) and the access fixture; all 1,011 CLI tests pass. The guarded Application A correction updates only its Service visibility and preserves original Service/database/PVC identities and neighboring revisions. Apply stops in 42.838 seconds at original DomainMapping readiness verification; shared generation 542/sequence 515 keeps the original transaction without a claim or fence. The backend ingress now has only cluster-local hosts, but the rejected central ingress remains stale. Kourier v1.22 requeues conflicts after deletion, not this update. [The exact one-annotation requeue](../audits/mp23-native-bootstrap-results-2026-10-01/f15-ingress-requeue-review.json) needs an operator exception to the saved review; approval is pending and no requeue effect has run. Resume the original transaction after original-UID Ready proof, then continue the bounded sequence. No unchanged rebuild/bootstrap repetition; native access and parent step 4 remain open.


**Read-only route verification handoff (2026-10-01).** Installed `ee4a3f11` passes its access fixture and native local platform gate: 213 verification-only operations preserve all 19 scope content digests and 35 Ready/Succeeded Pods, with zero provider mutations. Its cloud correction plan refuses before admission in 27.432 seconds because an unchanged DomainMapping must already be Ready at preparation, even though its reviewed backend dependency needs correction first. Shared generation 517 remains idle and exact. The additional adapter repair allows preparing only exact owned, unchanged unready DomainMapping verification; execution still requires that original physical UID to become Ready. Verification and recovery refuse a replacement UID even with matching owner/spec stamps. The regression fails before and passes after with zero provider mutations; all 1,011 CLI tests pass in 49.95 seconds and structural style passes. Install/local-gate this final narrow repair before retrying the correction; native access and parent step 4 remain open.

**Native protected-route defect and bounded repair (2026-10-01).** Parent step 2 admits the protected Application A on installed `71288437`, preserving the original platform payload. Its Service and database are Ready, but its central DomainMapping reports `DomainConflict`: the backend retains a public default route with the same hostname. The adapter also classifies this unready DomainMapping as present/verified, so the converged vector is insufficient. [The diagnostic](../audits/mp23-native-bootstrap-results-2026-10-01/f15-protected-route-diagnostic.json) records exact UIDs and results. The existing ADR 15 contract already requires protected backends to be cluster-internal behind the enforcer. The focused source repair makes typed protected backend Service bytes cluster-local, preserves that policy after a reviewed restart, and requires actual DomainMapping Ready status in observation, health and native mutation waits. The named application compiler and conflicting DomainMapping regressions both fail before and pass after the repair. Full CLI and installed/native correction remain pending; do not proceed to grant/revoke or mark M1 natively accepted yet. Preserve all unaffected proof and stop after parent step 4 for the operator's usable/deferred review.

**Scheduling baseline (2026-09-30; M1 accepted below on 2026-10-01).** MasterPlan 23's safe-use gate (its Progress section) requires M1 before real low-risk workloads run on an inventory-backed cloud context: access grant and revoke currently refuse on every admitted context, so nobody can be admitted to an application. Start M1 now; hard dependencies EP-146/147/149/151 are Complete. M2 CDN work stays in MasterPlan order 5. The 2026-09-28 scope reduction does not defer any access operation; align with the revised MP-23 support boundary and ADR 22 amendment as the sibling plans did. Every candidate passes the installed local k3d platform bootstrap before a cloud rehearsal.


- [x] (2026-10-01) M1: Reviewed access grant/revoke and portal synchronization work through public commands, preserve other contributions, and recover a lost acknowledgement without duplicate or foreign effects. The bounded HTTP/Kubernetes command fixture and full CLI suite pass; installed native integration remains with EP-155/156.
- [ ] M2: Reviewed CDN purge, disable, and exact owned retirement work for their supported providers, with bounded targets, replay handling, and selected-only evidence.

Inherited: auth-owner backend/portal contributions, central routes, Google per-host DNS review with a disposable-zone probe, and Cloudflare host/zone ownership and offline transport tests. Reviewed access commands are delivered by M1 below. CDN purge/disable still refuse after inventory initialization and remain M2 work.


**M1 source acceptance (2026-10-01).** `cli/nagarectl/src/Nagare/Inventory/Access.hs`, `AccessRuntime.hs`, and `cli/nagarectl/src/Nagare/Access/Reviewed.hs` implement a typed standalone viewer-relationship scope and complete auth-owner portal synchronization. Saved grant/revoke reviews use the common apply/resume journal; a private runtime key never enters scopes, native envelopes or diagnostics. Exact accepted En Service and protected DomainMapping identities bind each tuple. Portal sync composes every accepted contribution and reviews a Shomei Deployment rollout after its configuration maps, because running process environment does not reload when a ConfigMap changes.

`scripts/test-access-reviewed-public.py` uses the registered typed seed and actual public CLI against bounded HTTP and recording Kubernetes transports. It proves grant, one write despite a lost response and original-transaction resume, unchanged replay, revoke, changed-owner and stale-tuple refusal, unsupported API/caveat/hostname/missing-key refusals, selected-context status with missing-credential observation unavailable, complete portal sync and ordered rollout, unchanged neighbors and original scope revisions, and no credential leakage. The latest source build and fixture pass; the affected full suite passes all 1,009 tests, structural Haskell style and strict user-documentation validation pass. This change is the source checkpoint, not an installed cloud candidate. EP-155/156 still own real protected-route and installed native evidence, and MP-23 safe-use acceptance remains open.


## Surprises & Discoveries





The existing pinned dependency already supports exact atomic tuple writes. Mori resolved `mori://shinzui/en/packages/en-servant`; inspection at Nagare's existing En revision `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634` confirms `tuples`, `deletes`, and `preconditions`, a complete direct-tuple query, and the OpenAPI capability fields. No dependency pin changed. Older servers may silently ignore unknown JSON fields, so reviews refuse unless their OpenAPI schema advertises atomic preconditions and deletes. A lost response is unresolved until fresh exact observation proves the requested tuple under the same owner UIDs; it never triggers a blind write retry.

The generic recovery bundle may omit unchanged scopes. Accepted access authority therefore loads and hashes immutable base-scope bytes from the review's base revisions, rather than treating the newly admitted desired scope as previously owned during resume. Status also selects the private context kubeconfig; its absence reports unavailable observation without falling back to global Kubernetes credentials.


## Decision Log

2026-09-30: Start M1 immediately as a prerequisite of the MasterPlan safe-use gate, ahead of its original order-5 slot. Rationale: an intranet nobody can be admitted to is not usable; the operator needs the cloud cluster maintainable and usable now. M2 is unchanged. Also align with the 2026-09-28 MP-23 reduction: no access or CDN operation is deferred by it.


2026-09-26: Transfer a bounded unfinished EP-148 outcome into its own plan. Preserve delivered behavior and all release gates; no feature is dropped and no prior work is reset.


## Outcomes & Retrospective





## Context and Orientation


This plan takes only unfinished work from [EP-148](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md). Its completed application compilers, image builds/publication, environment and Secret channels, task lifecycle, manual backup/pruning, PostgreSQL scratch restore, and volume snapshot/scratch restore/pruning are inherited working code. A scope is one owner's desired resource set. An immutable review fixes the intended effects and native inputs; the private journal records execution and recovery evidence. Logical resource identity survives renames; a physical identity, such as a Kubernetes UID or storage-object version, identifies one actual incarnation. Names or labels alone do not authorize mutation.

cli/nagarectl/src/Nagare/Inventory/Command.hs supplies the command service; cli/nagarectl/src/Nagare/Inventory/Plan.hs, cli/nagarectl/src/Nagare/Inventory/Execute.hs, cli/nagarectl/src/Nagare/Inventory/Journal.hs, and cli/nagarectl/src/Nagare/Inventory/Store.hs own review, execution, receipts, and history. cli/nagarectl/app/Main.hs is the shared command registration surface. Keep behavior in named modules and preserve concurrent changes to registration and tests. Public output must not contain credentials or private native bundles.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership, exact reviewed effects, and full release acceptance despite this split. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history outside immutable payloads. These plans do not relax the existing fresh-context release boundary or the accepted offline-only Cloudflare proof. A refusal protects an unfinished feature but cannot count as its completion.

cli/nagarectl/src/Nagare/Access/Grants.hs contains runAccessGrant/runAccessRevoke and the exact access tuple wire. cli/nagarectl/src/Nagare/Access/Resolve.hs and cli/nagarectl/src/Nagare/Inventory/BackendMap.hs handle shared auth configuration; cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs and cli/nagarectl/src/Nagare/Inventory/Application.hs supply owner grants and application contributions. cli/nagarectl/src/Nagare/Inventory/Adapters/Cdn.hs, cli/nagarectl/src/Nagare/Inventory/Adapters/CdnRuntime.hs, cli/nagarectl/src/Nagare/Inventory/Adapters/Cloudflare.hs, and cli/nagarectl/src/Nagare/Inventory/Adapters/CloudflareRuntime.hs are the existing reviewed transports. cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs currently maps an empty purge path list to whole-zone purge; do not carry that accidental authority into an app-scoped command.

[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) reserves hostname ownership and separates routing from TLS readiness. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires the selected cloud project on every mutation.


## Plan of Work

**First implementation checkpoint (2026-09-27).** Use the existing command service to prove one public grant → saved review → apply → observed tuple → lost-response recovery → revoke roundtrip against the bounded HTTP fixture. Resolve the actual upstream tuple observation/write semantics through Mori before designing retries. Extend that working path to portal synchronization and M2's existing CDN cases. Do not finish an entire new access/CDN abstraction layer before this command path runs. The command proofs close this plan's stated milestones; full native local/Google evidence remains with EP-155/156 and Cloudflare retains its accepted offline proof.


M1 introduces reviewed access operation compilation in cli/nagarectl/src/Nagare/Inventory/Access.hs (new). Bind a grant to the accepted auth owner, exact protected hostname, user/subject, relation, endpoint, and observed current tuple. Preserve the existing logical access tuple semantics. Grant/revoke changes must be journaled; verify the exact tuple after a write and use observation to recover an uncertain response. Do not infer an API's concurrency or idempotency guarantees: inspect its registered source through Mori and test its actual behavior before enabling retries. Portal sync composes the complete accepted contribution set through the existing owner, retaining unrelated backend and portal entries. It must not rebuild authority from a partial live listing. Add saved review support to existing access commands, then remove their duplicate live paths once proved. Refuse unknown owners, stale inputs, foreign hostname claims, and missing private credentials before effects.

M2 adds typed CDN operational requests to the existing adapter dispatch. Purge has a stable operation ID and explicit hostname/URL targets. A host command may not silently expand an empty list to a whole-zone operation: resolve a provider-supported host purge or require explicit exact URLs, documenting the public syntax. Preserve whole-zone purge capability only as an explicitly reviewed zone-owner operation with a displayed blast radius. Use the provider's completion/request evidence; where success cannot be recovered after an ambiguous response, require an explicit recovery decision rather than automatic replay. Disable changes the selected host's routing/cache contribution while preserving the platform backend, apex, other hosts, and origin TLS policy. Retire and collect only exact accepted/retained DNS identities with current provider preconditions, respecting dependencies and shared-owner composition. Google and Cloudflare retain their existing provider responsibilities; this does not invent a new Google purge feature absent from the current CLI.

Extend cli/nagarectl/test/AccessGrantsSpec.hs, cli/nagarectl/test/AccessResolveSpec.hs, and cli/nagarectl/test/InventoryCdnSpec.hs. Carry proofs through the actual public command route using a fake HTTP endpoint and recording adapters, including changed identity and lost responses. The accepted Cloudflare offline API proof remains sufficient. Share real Google and protected-route scenarios with EP-156/EP-155; record exactly which native assertion they supply.


## Concrete Steps


Run from the repository root in the existing development environment. A newly named test group must be registered and run at least one test; zero selected tests is not passing evidence. No provider mutation is part of these initial checks.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p access' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p CDN' --test-show-details=failures)
(cd cli/nagarectl && cabal build exe:nagarectl)
bash scripts/test-application-entrypoint-guards.sh
```

The accepted M1 command fixture uses the already built source executables and no local VM or cloud mutation:

```bash
python3 scripts/test-access-reviewed-public.py \
  cli/nagarectl/dist-newstyle/build/aarch64-osx/ghc-9.12.4/nagarectl-0.4.0/x/nagarectl/build/nagarectl/nagarectl \
  cli/nagarectl/dist-newstyle/build/aarch64-osx/ghc-9.12.4/nagarectl-0.4.0/t/nagarectl-test/build/nagarectl-test/nagarectl-test
```

For another native system, use `cabal list-bin exe:nagarectl` and `cabal list-bin test:nagarectl-test` from `cli/nagarectl` to obtain the equivalent built paths. Expected output is the single passing reviewed-access fixture summary. [The redacted source checkpoint](../audits/mp23-native-bootstrap-results-2026-10-01/reviewed-access-source.json) records source hashes and separates this proof from native installed acceptance.

Expected result: selected tests and build exit zero; refusal fixtures prove zero unintended effects. At a milestone boundary also run the affected full suite, `bash scripts/check-haskell-style.sh`, and, when user docs change, `okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce`. Add exact public-command native fixture invocations with their saved review paths before recording acceptance.


The following saved-review forms are required new interfaces, to implement before use. In a selected disposable context with two accepted protected hosts, use explicit fixture values for HOST, ACCESS_SUBJECT, and a fresh REVIEW directory:

```bash
nagarectl access grant --host "$HOST" --user "$ACCESS_SUBJECT" --save-plan "$REVIEW"
nagarectl access revoke --host "$HOST" --user "$ACCESS_SUBJECT" --save-plan "$REVIEW"
nagarectl access portal sync --save-plan "$REVIEW"
nagarectl cdn purge "$HOST" --path /fixture --operation-id purge-fixture-1 --save-plan "$REVIEW"
nagarectl cdn disable "$HOST" --save-plan "$REVIEW"
```

Each invocation uses a distinct review directory and saves without effects. Inspect and apply one at a time with the existing `nagarectl inventory apply "$REVIEW" --yes` interface. A whole-zone purge must have a separate explicit zone-owner selector and displayed target set; it cannot be the host command's implicit default. Update these examples if CLI compatibility requires a different spelling, preserving these exact reviewed semantics.

## Validation and Acceptance


Against two protected hosts, grant one user, repeat the same accepted operation, revoke that user, and verify the second host and other users are untouched. Portal sync must retain both owners' entries while only the selected contribution changes. Verify secrets never appear in plans, errors, or evidence. A stale tuple/owner or foreign route refuses before the transport call.

For CDN, show the reviewed target set before mutation. Exact URL or host purge cannot invalidate unrelated hosts; an explicit zone purge requires the zone owner's authority. Disable/retire must preserve standing backend and neighboring DNS records. Simulate a lost acknowledgement and changed provider identity; recover only provable completion. Native Google proof belongs to EP-156, offline Cloudflare proof to this plan, and working protected routing to EP-155. Final release acceptance requires those integrated results even when this plan's targeted command proofs have passed.

Use focused tests while implementing one coherent milestone, then the affected full suite/build and documentation checks at its acceptance boundary. Repeat broad gates only after a relevant change or failure. Record the exact command, candidate revision, review/transaction IDs, fixture identity, result, and evidence location. Distinguish recording-provider tests from real provider evidence. Shared integration runs may supply the same assertion to several plans; do not wait for administrative plan closure to run them. Keep Progress checkboxes directly under Progress, without nested headings.


## Idempotence and Recovery


Use isolated test state and exact disposable resource identities. Retain the saved review, private native members, and journal after failure. Reuse an operation ID only with identical accepted intent; changed input requires a new review. Unknown provider results remain unresolved until observation proves what happened. No blind replay, broad prefix cleanup, history reset, or automatic data rollback is allowed. This plan authorizes implementation and its bounded verification, not a real release publication. Use Mori to locate dependency sources before relying on APIs, and verify authoritative releases before changing pins. Never inspect /nix/store.


## Interfaces and Dependencies


Completed [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) supply the adapters, ownership, lifecycle, and shared store. Own the access/CDN implementation and its focused tests; [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) consumes its registration and user documentation, [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) consume working commands, and [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) checks the complete release. No new work depends on EP-148 being marked Complete. Historical, uncalibrated estimate (not a current delivery forecast): 6–12 active engineering hours, low confidence, excluding integrated provider runs. Reforecast after the first reviewed grant/revoke roundtrip if the access API lacks the required observation or conditional-write capability.


## Revision Notes

2026-09-27: Apply the execution-log diagnosis to the existing outcome: drive implementation through its production command/recovery fixture, make handoffs and known ownership explicit, and prevent new requirements from entering through an open-ended audit. Existing functionality and final release acceptance remain required.
