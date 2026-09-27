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
---

# Complete reviewed access and CDN operations

This ExecPlan owns unfinished work transferred from EP-148. Keep its living sections current.


## Purpose / Big Picture


Operators can grant and revoke access, synchronize the protected-app portal, and purge or disable CDN routing through reviewed operations. Each command changes only its selected grant, hostname, or authorized contribution; unrelated apps and platform scope revisions remain intact.


## Progress


- [ ] M1: Reviewed access grant/revoke and portal synchronization work through public commands, preserve other contributions, and recover a lost acknowledgement without duplicate or foreign effects.
- [ ] M2: Reviewed CDN purge, disable, and exact owned retirement work for their supported providers, with bounded targets, replay handling, and selected-only evidence.

Inherited: auth-owner backend/portal contributions, central routes, Google per-host DNS review with a disposable-zone probe, and Cloudflare host/zone ownership and offline transport tests. Access operations and CDN purge/disable currently refuse after inventory initialization; they are the new work.


## Surprises & Discoveries





## Decision Log


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
