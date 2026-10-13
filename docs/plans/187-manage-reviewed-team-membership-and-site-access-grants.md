---
id: 187
slug: manage-reviewed-team-membership-and-site-access-grants
title: "Manage reviewed team membership and site access grants"
kind: exec-plan
created_at: 2026-10-12T14:58:44Z
intention: "intention_01m4r9rcpfem1997x5e75zc0zb"
master_plan: "docs/masterplans/27-protect-every-nagare-site-with-explicit-user-and-team-access.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T14:58:44Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T15:08:55Z
      mode: "other"
      note: "Ground user-selected site and team access scope in source research and MasterPlan decomposition"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-12T15:28:33Z
      mode: "update"
      note: "Validate APIs, upgrade latest En/Shomei prerequisite, and limit performance checks to concrete risks"
---

# Manage reviewed team membership and site access grants

This ExecPlan is a living document. Keep milestone evidence, discoveries, decisions, and outcomes current; record durable architecture in ADRs during implementation. This session plans the work only.


## Purpose / Big Picture

An operator can grant a named team access to selected protected sites, add or remove users from that team, and review exactly what changes. A member reaches the sites granted to their team and no others. Individual grants continue to work. Revoking a direct grant does not remove an independent team grant, and removing one team membership does not remove access granted through a different team.


## Progress

- [x] M1 (2026-10-12): `cluster/bootstrap/en/configmap.yaml` declares `group { relation member: user }` and `app { relation viewer: user, group#member }`; the pinned En parser and compiler accept it (`nagare-access-test`, `team access` group), and the en Deployment's Pod template carries the schema digest (`nagare.dev/en-schema-digest`) so a reviewed schema change rolls the server. `TeamKey` (`[a-z][a-z0-9_-]{0,62}`, `Nagare.Resource.Access`), `TeamMemberTuple` and `TeamAccessTuple` addresses with claims `team-member`/`team-access` that round-trip through the wire; `compileTeamMemberScope` and `compileTeamAccessScope` mint `access-member-*` and `access-team-*` scopes bound to the auth en Service (and, for a team grant, the exact protected route), and a team grant needs accepted membership history for its key. Exact filters pin the subject kind and relation (`subjectRelation none` for users, `exact member` for the userset); the runtime refuses a team write unless `GET /v1/schema` serves the reviewed declarations. Direct-user claims, scopes, filters and summaries are unchanged. The exact tuples nagarectl writes, driven through the real En and the gateway, admit a team's member to the team's host only, deny the member elsewhere and a stranger everywhere, and deny on the next check once the membership is gone. Measured cost at En `c3ee100a` (flat teams, counting tuple store): a member's check is 3 operations and `teams + 1` rows at 10, 100 and 1000 members; a stranger's check is 5 operations for one attached team and 23 for ten, reading every member once (`members × teams + teams` rows). Evidence: `nagarectl-test -p '/reviewed access/'`, `nagare-access-test -p '/team access/'`.
- [ ] M2: Public team/grant commands plan and apply guarded changes and list direct versus team relationships accurately.
- [ ] M3: Status, interrupted-write recovery, revocation, and lifecycle exits pass adversarial interpreter tests and a representative producer/consumer interaction.


## Surprises & Discoveries

Validation (2026-10-12): `runAccessList` currently expands `access` and flattens recursive nodes. The new stored-grant listing must use En's Relay relationship query instead. The selected current evaluator still has a denied-team path that can read large memberships; a targeted tuple-read check is warranted, not a general load suite.


## Decision Log

Decision (2026-10-12): A team is a named En group with flat user membership. Its members satisfy a site's viewer relation only when that exact site grants `group:<team>#member`. No Shomei-role synchronization, nesting, wildcard user, or global login grant is introduced.

Decision (2026-10-12): Preserve existing direct-user AccessTuple representation and introduce distinct typed forms for membership and team site grants. Do not reinterpret a subject string as an arbitrary En relationship.

Decision (2026-10-12): The schema change makes the packaged auth manifests differ from every earlier payload's. As with the MinIO manifest (EP-172, F41), this release pins its own and refuses the source payload's, so the transition fixture compiles the auth plane from this tree on both sides and the workspace row names the refusal; the real upgrade re-plans the auth scope from the target payload in its platform stage, where the ConfigMap update and the schema-digest annotation roll En. The next release's EP-172 rehearsal carries that proof; no fixture evidence is edited by hand.

Decision (2026-10-12): A denied check against a flat team reads every member of each attached team once at the pinned En (a member's check does not). For the intended small teams that is a few hundred rows per miss, bounded by En's tuple-read and decision caches and the gateway's TTL; Nagare adds no second graph or throttle. The concrete upstream improvement is a point probe of `group#member` for the checked subject instead of a relation read; it is recorded here as an En issue candidate, not a Nagare dependency.


## Outcomes & Retrospective

(To be filled during implementation and at completion.)


## Context and Orientation

Hard prerequisite: `docs/plans/186-protect-nagare-sites-with-explicit-user-and-team-grants.md` must be Complete. It supplies accepted protected routes for every web workload kind, the host-scoped `app:<host>#access` contract, and fully consistent En checks on gateway cache misses. Its gateway TTL remains configurable, default 30 seconds. This child does not modify site routing.

`cluster/bootstrap/en/configmap.yaml` currently declares `object user {}` and `object app { relation viewer: user; permission access = viewer }`. The text schema describes allowed relationship shapes and derives computed permissions. A tuple is one stored relationship. A userset subject refers to everyone who holds a named relationship on another object, such as `group:engineering#member`; it is distinct from a concrete user subject.

`cli/nagarectl/src/Nagare/Access/Grants.hs` builds direct viewer tuples; `Access/Reviewed.hs` routes public mutation commands through saved plans; `Access/ShomeiUser.hs` resolves an email to an existing Shomei ID. `cli/nagarectl/src/Nagare/Inventory/Access.hs` owns compileAccessScope, exact bindings, and the adapter. `AccessRuntime.hs` encodes exact read filters, atomic preconditions, tuple writes, and recovery observations. `cli/nagare-dsl/src/Nagare/Resource/Types.hs` gives AccessTuple a canonical claim ending in viewer, and `Wire.hs` decodes that shape; `Resource/Inventory.hs` owns ResourceSpec. A reviewed tuple identity must include the object, relation, subject kind, and subject relation; a group userset must never collide with a concrete subject whose text happens to match.

Dependency source is `mori://shinzui/en/packages/en-core`, `mori://shinzui/en/packages/en-servant`, and `mori://shinzui/en/packages/en-client`. In the canonical En project, source files `en-core/src/En/Schema/Types.hs`, `en-core/src/En/Schema/Parse.hs`, and `en-servant/src/En/Servant/API.hs` were inspected at the initial pin `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634`; revalidated against the user-selected `c3ee100a0b2cc63a50a9473ef590de7086dca4d0`. They already support userset subjects, comma-separated relation subject types, and the schema API. Project-relative file references here are anchored to `mori://shinzui/en`; file-level artifact URIs are pending. EP-186 M0 supplies En `c3ee100a0b2cc63a50a9473ef590de7086dca4d0` and Shomei `0eedad1328a910b457f86bc79bc42024aca33a20`. En still has no published release/tag; these are exact upstream commits selected by the user's latest-dependency requirement.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), Decision section, requires one owner per managed relationship, exact observed state, guarded writes, and recoverable journals. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires failure-world coverage before native tests. [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md) binds any pin update to image parity, and [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) forbids Nagare-owned SQL copies. Teams are relationship facts in En's existing store, not tables in Shomei's database.


## Plan of Work

### M1: Typed team relationships and additive schema

Extend the bootstrap text schema as follows; this syntax is supported at the pinned En revision:

```text
object user {}

object group {
  relation member: user
}

object app {
  relation viewer: user, group#member
  permission access = viewer
}
```

A membership is `group:<team>#member@user:<verified-id>`. A site grant is `app:<host>#viewer@group:<team>#member`. Retain all existing direct viewer tuples. Team keys are immutable validated lowercase ASCII identifiers, proposed `[a-z][a-z0-9_-]{0,62}`; reject malformed keys rather than rewriting them. They are scoped to the context's accepted En service, not a global directory. Use a smart constructor and readonly accessor in a proposed `cli/nagare-dsl/src/Nagare/Resource/Access.hs`. A team first becomes known through an accepted membership record; no empty native group object or separate create-team table is invented. Team grants require accepted membership history for that key, even if all members have since been revoked. Retained team grant or membership history continues to identify the key; no rename operation is part of this plan.

Introduce TeamMemberTuple and TeamAccessTuple provider addresses, with canonical claims including auth-service identity, group key, object relation, user or userset subject, and subject relation `member` where present. Preserve existing AccessTuple serialization and minting for direct-user grants. Bind new logical scope keys to the complete exact relationship. Extend ResourceSpec/Wire validation and every executor/load/status/lifecycle dispatch for the new forms. Restrict these forms to flat user memberships and app viewer usersets; they must not authorize arbitrary En objects, relations, caveats, or wildcard subjects.

The schema remains owned by the platform auth component in `cli/nagarectl/src/Nagare/Inventory/Components/PackagedAuth.hs`. Publish the additive schema in a reviewed bootstrap/update and roll the En process so the active schema changes. Validate it through the pinned parser and against existing direct tuple fixtures. Prove the active schema accepts group usersets before enabling CLI mutations. Use GET `/v1/schema` (`source`, `hash`, `origin`, `loadedAt`) to validate active relation and permission semantics, not only names. It is read-only. Make the reviewed schema change roll En through a Pod-template schema digest in `Inventory/Components/Auth.hs`, wait for old serving revisions to drain, and verify the active schema before writes. Recheck the expected schema and service identity at apply/resume, not only plan creation. Keep this off the gateway request path.

Before building all command variants, use a representative interaction: compile membership and a site-team grant, serialize/load the review, write through the recording adapter into a real En in-memory interpreter, and send a verified member through the enforcer. Access to A is allowed, B is denied. This is a consumer check of the same relationship bytes, not a mock authorize-always-true test.

Before broadening team command variants, use the actual selected `En.Check` with a counting TupleStore interpreter for one site granted to a flat team: compare allowed and absent users with 10, 100, and 1000 members, then ten attached teams. Record calls/rows, including the nonmember fallback. En probes direct tuples and tries reverse membership, but a miss can recursively drain attached teams; `pageLimit` bounds each page, not total work. This focused check is the only additional performance requirement. If it shows unacceptable work for the intended small-team use, record a concrete upstream fix/dependency; do not build a second authorization graph or assume a broad load-test program is needed.


### M2: Public reviewed commands

Extend `cli/nagarectl/app/Nagare/Cli/Parser/Access.hs`, `Commands/Access.hs`, `Access/Reviewed.hs`, and the grant parameter domain with the following proposed interface. Keep current `--user` commands compatible. Exactly one of `--user` and `--team` is required for a site grant/revoke. Membership changes use the same existing Shomei email/ID resolver; a user must already exist, and ambiguities refuse before a review is saved.

```bash
nagarectl access team add-member --team engineering --user alice@example.com --save-plan ./member-review
nagarectl access team remove-member --team engineering --user alice@example.com --save-plan ./remove-member-review
nagarectl access team list-members --team engineering
nagarectl access grant --host a.apps.example.com --team engineering --save-plan ./team-site-review
nagarectl access revoke --host a.apps.example.com --team engineering --save-plan ./revoke-team-site-review
nagarectl access list --host a.apps.example.com
```

Team members may be added before any site grant. The membership depends on the accepted context En service; a team site grant depends on that service and the exact protected route, not on a particular member resource. This allows safe removal of the last member without deleting or invalidating the site's group grant. Direct or team grant planning still refuses a public or foreign host. Do not enable legacy unreviewed mutation for the new commands, even before inventory initialization: these commands require accepted auth ownership.

Keep En's read-write key private via `NAGARE_EN_API_KEY`; read operations may use the existing context transport and appropriately scoped credentials. Saved plans name team, user TypeID (with supplied email for review), host, exact relation, and desired presence, never a bearer key. `access list` reports direct grants separately from group userset grants, retaining distinct subjects rather than flattening a group into misleading direct users. Add machine-readable JSON output for list commands. Replace the existing expand/flatten listing with POST `/v1/relationships/query`: `first`/`after` Relay parameters and body `consistency`/`filter`, decoding `edges` and `pageInfo`. Site listing anchors on exact `app:<host>#viewer`; membership listing anchors on exact `group:<team>#member` and concrete user subjects. Do not expand teams or resolve every listed TypeID through Shomei. Follow the server's opaque Relay cursor, which binds continuation to the original snapshot/filter, rather than inventing body cursors or issuing unrelated fresh pages. Reuse one command-scoped connection/port-forward. Drain pages incrementally; repeated cursors, token errors, or a bounded command deadline report incomplete with nonzero exit, never an empty or complete grant list. Keep exact mutation observation separate at `first=2` and refuse non-exhausted results. Effective access is delegated to EP-188's check command.

### M3: Exact guarded mutation and recovery

Extend exact filters and expected-tuple comparison in `Inventory/AccessRuntime.hs`. A concrete user filter uses subjectRelation none; a userset uses subjectRelation exact member. Write preconditions name all fields and run atomically in En's write transaction. Reject foreign tuples, caveated grants, wildcard subjects, incomplete reads, old servers lacking required preconditions, and mismatched auth/route owners. Existing unowned facts refuse instead of silently becoming accepted.

Membership and site grants use the common journal and status/resume/close paths. Model writes before any native proof: lost acknowledgement, no effect, landed effect, failed observation, contradictory tuple state, replaced auth service, foreign relationship, concurrent precondition refusal, and cancellation. A fully verified existing effect is recovered rather than repeated. Do not claim exact native incarnation where the tuple provider cannot distinguish remove-and-readd; preserve current provider limits and refuse ambiguous recovery without adequate evidence. If the implementation requires an upstream tuple generation feature, research its pinned API, explicitly revise dependencies, and verify it before strengthening a recovery guarantee.

Revoking a team site grant removes only that userset relationship. Removing a user removes only that membership, leaving direct/other-team paths intact. Retirement follows current live-grant refusal rules and retains history; new forms must have tested reviewed revoke/retire/collect exits. Removing all members does not revoke a team-to-site grant. Deleting a site requires revoking its direct and team site grants first; membership changes remain independent of unrelated routes. Add tests in `cli/nagarectl/test/AccessGrantsSpec.hs`, `InventoryAccessSpec.hs`, and `cli/nagare-dsl/test` for canonical claims, new wire values, old wire compatibility, public loaders, Relay continuation/filter mismatch and incomplete-list behavior, zero expansion/per-member calls, review determinism, and all stopped states. Register the new relationship forms in the generated recovery-model kind table as required by ADR 25.


## Concrete Steps

Commands run at the Nagare root. Re-read registered sources before adding an API dependency:

```bash
mori registry show shinzui/en --full
mori path mori://shinzui/en/packages/en-servant
rg -n 'AccessTuple|AccessGrantSpec|accessExecutor|tupleFilter' cli
cabal test --project-dir=cli/nagare-dsl --test-show-details=direct
just test-remote HEAD '/access/' '0/1'
just gate-fast
```

For future authorized integration, apply the schema review before relationship mutations. On a disposable, accepted test context with two protected hosts, existing Alice/Bob Shomei accounts, and private En credentials already configured, the expected command sequence is:

```bash
nagarectl access team add-member --team engineering --user alice@example.com --save-plan ./member-review
nagarectl inventory apply ./member-review --yes
nagarectl access grant --host a.apps.example.com --team engineering --save-plan ./team-site-review
nagarectl inventory apply ./team-site-review --yes
nagarectl access list --host a.apps.example.com
nagarectl access team list-members --team engineering
```

Expected outputs include a reviewed member tuple for Alice and a group userset viewer tuple for engineering on A. Alice reaches A; Bob and requests to B remain denied. These interfaces are proposed implementation outputs, not commands available in today's CLI. Native execution waits for interpreter tests and the candidate gate procedure in `docs/runbooks/before-a-native-run.md`.


Revision (2026-10-12): Consume the latest-auth prerequisite, use Relay stored-tuple listing and active schema evidence, and add only a targeted denied-team tuple-read check.


## Validation and Acceptance

Prove the additive schema preserves direct grants and allows only members of an explicitly granted group. An engineering member has access to A after the group grant and no access to B. A signed-in nonmember gets 403. A different team's member remains denied. The same subject string with a different subject kind/relation never collides. Team names and user resolution errors fail before mutation. The public loader accepts new plans, status observes the exact tuple, and resume does not repeat a proven write.

Removal of engineering membership denies A after the configured gateway TTL if that was the last access path. Keeping a direct grant or another granted membership keeps A allowed and is visible as a separate relationship. Incomplete listing, an unavailable En service, or unknown schema never creates permission. Old direct-user grant identity and review loading remain compatible. A tested revoke/retire exit exists for every relationship form, including writes interrupted after their effect. No Shomei role or default signup configuration can independently grant a protected host.


## Idempotence and Recovery

Stable claims prevent duplicate ownership. A repeated accepted membership/grant is a no-op only after observing the exact owned relationship. Foreign existing tuples refuse. Changes require atomic expected-state preconditions; a 412 means known no effect and requires reread/replanning. A lost response resumes the original transaction and observes exact tuples; it is not a reason to issue another broad write. Schema rollout is additive and retains old relationships. Once group tuples exist, rolling back to the user-only schema must be refused until those tuples have been revoked through reviewed changes; no force reload, SQL edit, or blanket deletion is allowed.


## Interfaces and Dependencies

Hard dependency is the whole completed EP-186. This child owns team-key validation, team relationship ProviderAddress/Wire/ResourceSpec forms, schema extension, membership mutation, group grants, and listing of stored relationships. EP-188 consumes those types and uses En check to diagnose effective access. The dependency upgrade is owned by prerequisite EP-186 M0; this child uses that accepted API. A changed pin requires registry/tag verification, source lookup through Mori, auth-library build and service-image parity under ADR 1, and explicit migration jobs under ADR 2 when the upstream version requires them.
