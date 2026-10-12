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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T13:56:59Z
      mode: "update"
      note: "Record operator decision D3: HTTPS and browser login are a stated release restriction"
---

# Complete reviewed access and CDN operations

This ExecPlan is a living document and a child of [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md). Keep Progress, Surprises & Discoveries, Decision Log and Outcomes & Retrospective current. It was consolidated on 2026-10-02; the earlier dated checkpoints, native handoffs and full decision history are preserved verbatim in [the pre-consolidation snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md). Nothing in that snapshot overrides this file.

Full plan before trimming: [158-complete-reviewed-access-and-cdn-operations.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/158-complete-reviewed-access-and-cdn-operations.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

An operator of an inventory-backed Nagare context can admit a person to a protected application, remove them again, keep the login portal in step with every protected application, and purge, disable or retire an application's CDN routing — each through a saved review that is inspected, applied and, if interrupted, resumed. Each command changes only its selected grant, hostname or authorized contribution; other applications, other users and every platform scope revision stay byte-identical. A lost provider response is recovered by observation, never by resending the write.

To see it working: `nagarectl access grant --host HOST --user SUBJECT --save-plan DIR` followed by `nagarectl inventory apply DIR --yes` makes the protected host return the application to that user and leaves a neighbor host unchanged; `nagarectl cdn disable HOST --save-plan DIR` produces a review with exactly one DNS update from the CDN address to the origin address.

## Progress

- [x] (2026-10-01) Reviewed access grant/revoke and portal synchronization work through public commands (MasterPlan safe-use prerequisite). Commit `c4524c24`; `scripts/test-access-reviewed-public.py` proves grant, one write despite a lost response, original-transaction resume, unchanged replay, revoke, stale-tuple/changed-owner/unsupported-API/missing-key refusals, ordered portal rollout, unchanged neighbors and no credential leakage; full CLI suite passed. [Source checkpoint](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/reviewed-access-source.json).
- [x] (2026-10-01) Native access checkpoint on installed `d871d913`: portal sync converges, protected HTTP gives document 302 and API 401, direct backend bypass gives 404, a lost-acknowledgement grant resumes with no second write and revoke writes once ([sync](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/f15-auth-synchronization.json), [grant/revoke](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/mp23-native-bootstrap-results-2026-10-01/f15-application-access-progress.json)). This ran on the now-retired `f15-preview` fixture, so it is diagnostic, not final acceptance.
- [x] (2026-10-02) Reviewed `cdn disable` keeps the owned Google DNS record and points it at the platform origin (Cloudflare: record becomes DNS-only and only that host's cache contribution is withdrawn). Commit `8bcd84f0`, plus the generated-namespace and runtime-guard integration fixes the independent public test exposed, which landed in `71068ad0`; `scripts/test-cdn-disable-public.py` yields one DNS update, observes the generated namespace, keeps accepted history unchanged and refuses an unowned host; independently verified ([output](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/public-cdn-disable.txt)).
- [x] (2026-10-02) Reviewed Cloudflare host, exact-path and explicit whole-zone purge with durable receipts, and exact retained DNS collection for Google and Cloudflare. Commit `71068ad0`; `scripts/test-cdn-purge-public.py` (including `--ambiguous-response redirect`, `--collection --last-contributor` and `--google-dns --last-contributor`) proves no resend after an ambiguous response, changed-record refusal and lost-response collection recovery. F21 (redirect replay) Closed; collection independently verified ([proof](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-02/cdn-retained-collection-public-71068ad0.json)).
- [x] On the final candidate's fresh cloud context, a Google CDN host record is created by reviewed application deploy, disabled, retired and collected with exact identities and neighbors preserved, and an independent reviewer records the lifecycle result (MP-23 B3, run under EP-156 in C3). (2026-10-09: nagare-verify, `83124396` on `mp23-c3m`. Four converged transactions moved `scenario-cdn`'s record to the CDN address, back to the VM origin on `cdn disable`, kept it on retirement and collected it. Each step recorded the exact zone listing (value and TTL 300), [google-cdn](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/checks/google-cdn/result.json). Neighbor scopes kept their revisions, [independent-scope-preservation](https://github.com/shinzui/nagare/tree/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/checks/independent-scope-preservation).)
- [x] Access grant/revoke with lost-acknowledgement recovery and portal sync re-proven natively on the final candidate (MP-23 C3; safe-use gate). (2026-10-09: on `83124396`, C3 killed an access grant after its transaction began. `inventory resume` converged the same transaction, the subject was listed, and the reviewed revoke removed it, [access-grant-revoke](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/cloud/checks/access-grant-revoke/result.json). C2 showed the same locally. Grants are checked through `access list`, not a browser, because D3 keeps browser login a restriction. Portal sync converged natively on the earlier candidate `3ae20f8c` (`mp23-c3j`, [runbook execution](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/synchronize-protected-backend/result.json)). The only later access change, `b171712a`, concerns retiring a revoked grant, not portal sync.)
- [x] The HTTPS and protected-browser-login disposition is recorded (2026-10-03, operator decision D3): it is a stated restriction of this release, not an acceptance criterion. The fixture is HTTP-only and protected browser login has not been accepted; EP-157's release notes list both as unmet production targets (MP-23 B3).

## Surprises & Discoveries

Full history is in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md).

The pinned En dependency already supports exact atomic tuple writes. Mori resolved `mori://shinzui/en/packages/en-servant`; at Nagare's pinned En revision `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634` it offers `tuples`, `deletes`, `preconditions` and a complete direct-tuple query. Older servers may silently ignore unknown JSON fields, so reviews refuse unless the server's OpenAPI schema advertises atomic preconditions and deletes.

The generic recovery bundle may omit unchanged scopes, so accepted access authority loads base-scope bytes from the review's base revisions during resume. Status uses the private context kubeconfig and reports observation unavailable when it is missing, never falling back to global credentials.

Native runs exposed three routing facts. Protected backend Services must be cluster-local, otherwise their public default route collides with the central DomainMapping (`DomainConflict`); an unready DomainMapping must not count as verified. Both Shomei and the enforcer read configuration only at startup, so portal sync reviews a rollout of both after the ConfigMaps. A retained bootstrap marker must select bootstrap verification only for a review that selects that marker.

The public CDN tests found missing retirement observations, missing historical collection bindings, rejection of a valid same-owner DNS/route hostname pair, generated-namespace overlap in disable, and a runtime guard that wrongly required the desired target to equal the CDN address. All are fixed in `8bcd84f0`/`71068ad0`. Last-contributor retirement now carries the unchanged Retain namespace to its surviving platform owner.

`cli/nagarectl/src/Nagare/Cdn/Cloudflare.hs` maps an empty purge path list to a whole-zone purge; the reviewed host command never passes an empty list, and whole-zone purge requires `--whole-zone`.

## Decision Log

Decisions still in force, condensed. Verbatim entries are in [the snapshot](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-archive/plan-history/ep158-before-consolidation-2026-10-02.md).

2026-10-03 (operator, MP-23 D3): HTTPS routes and protected browser login are a stated restriction of this release and an unmet production target, not acceptance criteria.

2026-10-02 (consolidation): rewrite this plan as a current-state document aligned with MasterPlan 23 items B3 and C3. No scope or acceptance change.

2026-10-02: `f15-preview` is retired from acceptance ([disposition](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-prerelease-fixture-disposition.md)). Native access evidence gathered there is kept as diagnostic history and must be re-bound to the final candidate in C3.

2026-10-02: an ambiguous provider response (including an HTTP redirect) never triggers a resend; the transaction stays unresolved until fresh observation proves completion. Whole-zone purge is a separate reviewed zone-owner operation with a displayed blast radius. Google has no purge feature and none is added.

2026-09-30: start access work ahead of its original order because the safe-use gate needs it. The 2026-09-28 scope reduction defers no access or CDN operation; all of them remain required.

2026-09-27 (restating EP-148's accepted boundary): Cloudflare acceptance is the offline private-TLS recorder proof, because no disposable Cloudflare zone exists; Google DNS needs native proof, which EP-156 supplies.

2026-09-26: this plan takes the unfinished access/CDN outcome from EP-148 without dropping features or resetting delivered work.

## Outcomes & Retrospective

**Status (2026-10-09): Complete.** v0.4.0 (`83124396`) ships reviewed access grant, revoke and portal sync, CDN purge and disable, and exact retained DNS collection.
- **Native proof.** C3 proved the Google CDN lifecycle and a resumed, interrupted grant natively on the final candidate. Portal sync was proved on `3ae20f8c`.
- **Restrictions.** HTTPS and browser login remain a stated restriction (D3) in the release notes. F84's fix ships in 0.4.0 (`b171712a`), and its native staged-teardown proof is pending (Verifying). That fix lets a reviewed retirement retire a revoked access grant and refuse a live one.
- **Lesson.** One scripted C3 run with a check record per operation was cheaper than the separate native checkpoints this plan first collected on a fixture that was later retired.

Earlier (2026-10-03): all four reviewed operations — access grant/revoke, portal sync, CDN purge and disable, and exact retained DNS collection — exist and pass public-command tests against bounded or recording providers, and their source fixes are independently verified. Native access was demonstrated, but only on a retired fixture. Remaining: native Google CDN lifecycle and native access on the final candidate. D3 is decided: HTTPS/browser login is a stated release restriction. Lesson: public-command tests with realistic composed scopes found integration defects that unit tests over single scopes missed; run them before any native attempt.

