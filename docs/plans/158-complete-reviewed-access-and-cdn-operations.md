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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-02T19:14:32Z
      mode: "implement"
      note: "Implement scoped reviewed CDN disable while retaining open public and native acceptance"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T03:28:10Z
      mode: "update"
      note: "Consolidated with MP-23 into a current-state plan; prior body archived in docs/audits/mp23-archive/plan-history"
---

# Complete reviewed access and CDN operations

This ExecPlan is a living document and a child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02; the earlier dated checkpoints, native handoffs and full decision history are preserved verbatim in [the pre-consolidation snapshot](../audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.


## Purpose / Big Picture

An operator of an inventory-backed Nagare context can admit a person to a protected application, remove them again, keep the login portal in step with every protected application, and purge, disable or retire an application's CDN routing — each through a saved review that is inspected, applied and, if interrupted, resumed. Each command changes only its selected grant, hostname or authorized contribution; other applications, other users and every platform scope revision stay byte-identical. A lost provider response is recovered by observation, never by resending the write.

To see it working: `nagarectl access grant --host HOST --user SUBJECT --save-plan DIR` followed by `nagarectl inventory apply DIR --yes` makes the protected host return the application to that user and leaves a neighbor host unchanged; `nagarectl cdn disable HOST --save-plan DIR` produces a review with exactly one DNS update from the CDN address to the origin address.


## Progress

- [x] (2026-10-01) Reviewed access grant/revoke and portal synchronization work through public commands (MasterPlan safe-use prerequisite). Commit `c4524c24`; `scripts/test-access-reviewed-public.py` proves grant, one write despite a lost response, original-transaction resume, unchanged replay, revoke, stale-tuple/changed-owner/unsupported-API/missing-key refusals, ordered portal rollout, unchanged neighbors and no credential leakage; full CLI suite passed. [Source checkpoint](../audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/reviewed-access-source.json).
- [x] (2026-10-01) Native access checkpoint on installed `d871d913`: portal sync converges, protected HTTP gives document 302 and API 401, direct backend bypass gives 404, a lost-acknowledgement grant resumes with no second write and revoke writes once ([sync](../audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/f15-auth-synchronization.json), [grant/revoke](../audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/f15-application-access-progress.json)). This ran on the now-retired `f15-preview` fixture, so it is diagnostic, not final acceptance.
- [x] (2026-10-02) Reviewed `cdn disable` keeps the owned Google DNS record and points it at the platform origin (Cloudflare: record becomes DNS-only and only that host's cache contribution is withdrawn). Commit `8bcd84f0`, plus the generated-namespace and runtime-guard integration fixes the independent public test exposed, which landed in `71068ad0`; `scripts/test-cdn-disable-public.py` yields one DNS update, observes the generated namespace, keeps accepted history unchanged and refuses an unowned host; independently verified ([output](../audits/mp23-independent-results-2026-10-02/public-cdn-disable.txt)).
- [x] (2026-10-02) Reviewed Cloudflare host, exact-path and explicit whole-zone purge with durable receipts, and exact retained DNS collection for Google and Cloudflare. Commit `71068ad0`; `scripts/test-cdn-purge-public.py` (including `--ambiguous-response redirect`, `--collection --last-contributor` and `--google-dns --last-contributor`) proves no resend after an ambiguous response, changed-record refusal and lost-response collection recovery. F21 (redirect replay) Closed; collection independently verified ([proof](../audits/mp23-independent-results-2026-10-02/cdn-retained-collection-public-71068ad0.json)).
- [ ] On the final candidate's fresh cloud context, a Google CDN host record is created by reviewed application deploy, disabled, retired and collected with exact identities and neighbors preserved, and an independent reviewer records the lifecycle result (MP-23 B3, run under EP-156 in C3).
- [ ] Access grant/revoke with lost-acknowledgement recovery and portal sync re-proven natively on the final candidate (MP-23 C3; safe-use gate).
- [ ] The HTTPS and protected-browser-login disposition is recorded from operator decision D3: either proven on the candidate or stated as a release restriction (MP-23 B3).


## Surprises & Discoveries

Full history is in [the snapshot](../audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md).

The pinned En dependency already supports exact atomic tuple writes. Mori resolved `mori://shinzui/en/packages/en-servant`; at Nagare's pinned En revision `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634` it offers `tuples`, `deletes`, `preconditions` and a complete direct-tuple query. Older servers may silently ignore unknown JSON fields, so reviews refuse unless the server's OpenAPI schema advertises atomic preconditions and deletes.

The generic recovery bundle may omit unchanged scopes, so accepted access authority loads base-scope bytes from the review's base revisions during resume. Status uses the private context kubeconfig and reports observation unavailable when it is missing, never falling back to global credentials.

Native runs exposed three routing facts. Protected backend Services must be cluster-local, otherwise their public default route collides with the central DomainMapping (`DomainConflict`); an unready DomainMapping must not count as verified. Both Shomei and the enforcer read configuration only at startup, so portal sync reviews a rollout of both after the ConfigMaps. A retained bootstrap marker must select bootstrap verification only for a review that selects that marker.

The public CDN tests found missing retirement observations, missing historical collection bindings, rejection of a valid same-owner DNS/route hostname pair, generated-namespace overlap in disable, and a runtime guard that wrongly required the desired target to equal the CDN address. All are fixed in `8bcd84f0`/`71068ad0`. Last-contributor retirement now carries the unchanged Retain namespace to its surviving platform owner.

`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` maps an empty purge path list to a whole-zone purge; the reviewed host command never passes an empty list, and whole-zone purge requires `--whole-zone`.


## Decision Log

Decisions still in force, condensed. Verbatim entries are in [the snapshot](../audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md).

2026-10-02 (consolidation): rewrite this plan as a current-state document aligned with MasterPlan 23 items B3 and C3. No scope or acceptance change.

2026-10-02: `f15-preview` is retired from acceptance ([disposition](../audits/mp23-prerelease-fixture-disposition.md)). Native access evidence gathered there is kept as diagnostic history and must be re-bound to the final candidate in C3.

2026-10-02: an ambiguous provider response (including an HTTP redirect) never triggers a resend; the transaction stays unresolved until fresh observation proves completion. Whole-zone purge is a separate reviewed zone-owner operation with a displayed blast radius. Google has no purge feature and none is added.

2026-09-30: start access work ahead of its original order because the safe-use gate needs it. The 2026-09-28 scope reduction defers no access or CDN operation; all of them remain required.

2026-09-27 (restating EP-148's accepted boundary): Cloudflare acceptance is the offline private-TLS recorder proof, because no disposable Cloudflare zone exists; Google DNS needs native proof, which EP-156 supplies.

2026-09-26: this plan takes the unfinished access/CDN outcome from EP-148 without dropping features or resetting delivered work.


## Outcomes & Retrospective

All four reviewed operations — access grant/revoke, portal sync, CDN purge and disable, and exact retained DNS collection — exist and pass public-command tests against bounded or recording providers, and their source fixes are independently verified. Native access was demonstrated, but only on a retired fixture. Remaining: native Google CDN lifecycle and native access on the final candidate, and the D3 HTTPS/browser-login decision. Lesson: public-command tests with realistic composed scopes found integration defects that unit tests over single scopes missed; run them before any native attempt.


## Context and Orientation

A *scope* is one owner's complete declared resource set; the *inventory* composes all scopes and checks shared claims. A *review* is an immutable, digest-named plan of native effects saved with `--save-plan DIR`; `nagarectl inventory apply DIR --yes` admits and executes it, and `nagarectl inventory resume tx-<digest> --yes` continues an interrupted one from the private *journal*. A *physical identity* (Kubernetes UID, DNS record value and TTL, provider rule version) names one actual incarnation; names alone never authorize a write. An *access tuple* is one (protected host, user, relation) entry in the En authorization service. The *portal* is the Shomei login service; the *enforcer* is the proxy that checks tuples in front of protected backends ([ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md)).

Access: `cli/nagarectl/src/Nagare/Inventory/Access.hs` and `AccessRuntime.hs` compile and execute tuple and portal reviews; `cli/nagarectl/src/Nagare/Access/Reviewed.hs` and `Grants.hs` hold the command and tuple wire; `cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs` and `Application.hs` supply owner grants and application contributions. CDN: `cli/nagarectl/src/Nagare/Inventory/Adapters/Cdn.hs`, `CdnRuntime.hs`, `Cloudflare.hs` and `CloudflareRuntime.hs`, plus `cli/nagarectl/src/Nagare/Cdn/CdnPurge.hs`. A Google host record is created by the application's reviewed deploy and requires an accepted platform BackendService (see the Google CDN row of `docs/architecture/managed-resource-coverage.md`). Tests: `cli/nagarectl/test/AccessGrantsSpec.hs`, `AccessResolveSpec.hs`, `InventoryCdnSpec.hs` and the three public scripts named in Progress.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) requires independent ownership and exact reviewed effects. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) reserves hostname ownership and separates routing from TLS readiness. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires the active context's project on every cloud mutation. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) keeps private history and credentials out of payloads and public output.


## Plan of Work

Source work is complete. What remains is native proof on the final candidate, executed inside EP-156's bounded, operator-approved cloud sequence (MasterPlan C3) rather than as a separate cloud run. On the fresh cloud context with the platform CDN backend enabled: deploy an application whose scope declares a Google CDN host, then `cdn disable` it, retire the application scope, and collect the retained DNS record, checking at each step the exact record value and TTL, the preserved apex and neighbor records, and unchanged unrelated scope revisions. In the same sequence, grant one user to one of two protected hosts, interrupt the acknowledgement, resume, revoke, and run portal sync, checking that the second host and other users are untouched. An independent reviewer records the result in this plan and [the findings tracker](../audits/mp23-findings.md). Ask the operator for decision D3 and record it here before C5.


## Concrete Steps

Run from the repository root in the development shell. These checks use recording or bounded providers and mutate nothing.

```bash
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p access' --test-show-details=failures)
(cd cli/nagarectl && cabal test nagarectl-test --test-options='-p CDN' --test-show-details=failures)
NAGARECTL="$(cd cli/nagarectl && cabal list-bin exe:nagarectl)"
python3 scripts/test-access-reviewed-public.py "$NAGARECTL" "$(cd cli/nagarectl && cabal list-bin test:nagarectl-test)"
python3 scripts/test-cdn-disable-public.py --nagarectl "$NAGARECTL"
python3 scripts/test-cdn-purge-public.py --nagarectl "$NAGARECTL" --ambiguous-response redirect
python3 scripts/test-cdn-purge-public.py --nagarectl "$NAGARECTL" --collection --last-contributor
python3 scripts/test-cdn-purge-public.py --nagarectl "$NAGARECTL" --google-dns --last-contributor
just haskell-style-check
```

Expected: every command exits zero; the disable script ends with `Public CDN-disable contribution regression passed`. A selected test group that runs zero tests is a failure. The public command forms used natively (each with a fresh review directory, applied one at a time) are:

```bash
nagarectl access grant --host "$HOST" --user "$SUBJECT" --save-plan "$REVIEW"
nagarectl access revoke --host "$HOST" --user "$SUBJECT" --save-plan "$REVIEW"
nagarectl access portal sync --save-plan "$REVIEW"
nagarectl cdn purge "$HOST" --path /selected --purge-id "$ID" --save-plan "$REVIEW"
nagarectl cdn disable "$HOST" --save-plan "$REVIEW"
nagarectl inventory retire --scope "application:$APP" --out "$REVIEW"
nagarectl inventory collect --resource "$DNS_RESOURCE_ID" --out "$REVIEW"
nagarectl inventory apply "$REVIEW" --yes
```


## Validation and Acceptance

Access is accepted when, on the final candidate, a granted user reaches the protected host, a revoked user does not, the second host and other users are unchanged, a lost acknowledgement resumes without a second write, and no secret appears in reviews, errors or evidence. CDN is accepted when the Google record's create, disable, retire and collect each show only the reviewed target, preserve the apex, backend and neighbor records, and refuse a changed record; Cloudflare's offline recorder proof stands. Record the candidate revision, review and transaction IDs, commands, results and evidence location, and keep recording-provider proof distinct from native provider proof.


## Idempotence and Recovery

Each review directory is single-use; reuse a purge ID only with identical intent, and changed input requires a new review. An unknown provider result stays unresolved until observation proves it; resume the original transaction rather than re-planning. No blind replay, prefix-based cleanup or history reset. Cloud steps run only inside EP-156's approved sequence under the active context's guardrail. Use Mori for dependency sources and never search `/nix/store`.


## Interfaces and Dependencies

Hard prerequisites [EP-146](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [EP-147](147-compile-cluster-bootstrap-into-owned-resource-components.md), [EP-149](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md) and [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) are complete. [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) consumes the command registration and coverage rows; [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md) runs the native Google and access proof; [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) exercises protected routing locally; [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md) checks the complete release.


## Revision Notes

2026-10-02: Consolidated with MP-23; history in the snapshot.
