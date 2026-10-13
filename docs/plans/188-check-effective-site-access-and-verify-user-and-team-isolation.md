---
id: 188
slug: check-effective-site-access-and-verify-user-and-team-isolation
title: "Check effective site access and verify user and team isolation"
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

# Check effective site access and verify user and team isolation

This is a living ExecPlan for operator diagnostics and integration acceptance. The creation session writes the plan only; implementation and native verification remain unfinished.


## Purpose / Big Picture

An operator can ask whether a particular Shomei user currently has access to a protected hostname, including access derived from teams. The result comes from the same En permission used by the HTTP enforcer. A reproducible verification scenario demonstrates that signing in, joining an unrelated team, or receiving a grant for a different site never grants this site.


## Progress

- [x] M1 (2026-10-12): `nagarectl access check --host HOST --user EMAIL|USER_ID [--json] [--en-api-key KEY]` resolves the user through the existing Shomei resolver, requires an accepted protected route for the normalized host (`acceptedProtectedHost`), and sends one `POST /v1/check` at a fully consistent snapshot with an empty caveat context for `user:<id>`, permission `access`, object `app:<host>` through the same private port-forward and `NAGARE_EN_API_KEY` the reviewed writes use (`withContextEn`, now shared). `Nagare.Access.Check` reports `allowed`, `denied`, `conditional` with En's obligations, or `unavailable` with a bounded diagnostic (HTTP status plus En's problem code and detail only; transport failures, bare bodies and malformed answers never become a decision or echo a body). JSON carries host, subject, permission, decision, `checkedAt` and `grantGeneration` when present; plain output states the gateway TTL caveat. Denied exits zero; unavailable and invalid input exit nonzero. Nothing is written and no list is consulted. Evidence: `nagarectl-test -p '/Nagare.Access.Check/'` (byte-exact request against the pinned en-servant wire, every decoded answer, the transport call, diagnostics without secrets, JSON and plain renderings); `nagarectl access check --help` and the `--user` refusal run through the built executable; `scripts/audit-managed-commands.py` registers `AccessCheck` as a read route.
- [x] M2 (2026-10-12): `cli/nagare-access/test/SiteAccessIntegrationSpec.hs` drives the real En API (pinned `c3ee100a`, the bootstrap schema, a live tuple set read at the start of every request) and the gateway over the exact `backends.json` nagarectl composes for a protected StaticSite `a` and a protected ServerSite `b` (`nagarectl-test`, "two protected sites of two kinds compose one backend map"), with the exact tuples the reviewed commands write. Alice (engineering, granted a) reaches a only, Bob (finance, granted b) reaches b only, Carol reaches nothing, and the upstream is reached exactly twice; an unrouted host has no backend (502). Carol's direct grant admits a only and its revocation removes it; Alice's independent direct grant survives the loss of her membership and its revocation denies. With a 30 s TTL on an injected clock a revoked last path is still served at 29 s after the check started and denied at 30 s; with a zero TTL every request is the next fully consistent check. An En outage is 503 with no upstream call, is not cached, and service returns on the next request; a conditional answer is 403; a raw `X-Forwarded-User` header on an anonymous API request is 401 and never reaches the origin. Evidence: `nagare-access-test -p '/MasterPlan 27/'` (team access and site access integration), `nagarectl-test -p '/two protected sites of two kinds/'`.
- [x] M3 (2026-10-13): `scripts/site-access-drill.sh` ran once on a disposable local context from the gated candidate (`f6dd3ea0`, packaged nagarectl; auth images from this tree's pins, En `c3ee100a`, Shomei `0eedad13`): the served En schema is the bootstrap text with groups (hash `fnv1a64:40b7b82bdaeea49e`; the `en` Deployment carries its SHA-256), `cluster/examples/protected-static-site` was published and deployed with a preview, both routes are enforcer DomainMappings in `nagare-system` over a cluster-local origin, and `nagare-harness route-check --team engineering --other-team finance` proved the wrong-CA refusal, anonymous 302 and API 401, ungranted 403 with `access check` denied, team grant 200 with check allowed, a `finance` member refused, and removal denied by the check at once and by the session within the wait. A direct grant through the real login reached production and not the preview; a raw identity header admitted nobody; the origin's cluster-local hostname is 404 through the ingress; after a revoke the check said denied while the cached session still got 200, and the session was refused after 26 s; a second release rolled back to the first under review with its protection intact. Record: `docs/audits/mp27-site-access-drill-2026-10-13/`. Docs: `docs/user/access.md` (`access check`), `docs/user/static-hosting.md`, `docs/user/local-development.md`, the example README, the capability record, and ADR 29.


## Surprises & Discoveries

Validation (2026-10-12): Current En already supplies `checkedAt`, optional `grantGeneration`, and conditional obligations. Reuse those response types; do not invent a diagnostic API. No general load-testing milestone is required.


## Decision Log

Decision (2026-10-12): Effective access is an En check at a fully consistent snapshot, distinct from listing stored relationships. Report unavailable or conditional explicitly; never interpret an error as permission or a complete grant list.

Decision (2026-10-12): Host access does not promise read/edit distinctions inside an application. Keep path/action options in the MasterPlan's research record, outside this child's acceptance.

Decision (2026-10-12): The enforcer sees hostnames, never site kinds. Kind coverage (StaticSite, ServerSite, Deployment, Application, default hosts, aliases, previews, rollbacks) is proved where kinds exist, in nagarectl's composition of the backend map and enforcer routes (EP-186's protected-site cases and the two-kind map case); the enforcer scenario runs once over those composed bytes rather than once per kind. The resume, status and retirement loader paths are EP-187 M3's lost-write and retirement cases, whose asserted result is the exact tuple's presence, which is the access state the enforcer reads.


## Outcomes & Retrospective

The deliverables and their evidence are the Progress checklist above; the decisions are in the Decision Log and in [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md).


## Context and Orientation

Whole-child prerequisites are `docs/plans/186-protect-nagare-sites-with-explicit-user-and-team-grants.md` and `docs/plans/187-manage-reviewed-team-membership-and-site-access-grants.md`, both Complete. Their contracts are a private origin and enforcer route per protected hostname, permission `access` on `app:<host>`, direct user grants, and team membership/site grants. Team membership is `group:<team>#member@user:<id>`; a site grant points its viewer relation at `group:<team>#member`. Multiple independent grant paths can exist.

`cli/nagarectl/app/Nagare/Cli/Parser/Access.hs` defines public commands, `Commands/Access.hs` executes them, `cli/nagarectl/src/Nagare/Access/ShomeiUser.hs` resolves identity, and `Inventory/AccessRuntime.hs` provides private context En transport. This child should factor a reusable read transport if needed rather than copy mutation authorization logic. `cli/nagare-access/src/Nagare/Access/En.hs` builds the enforcement query; `App.hs` proxies only Allowed, while `DecisionCache.hs` may serve a prior answer until its TTL. A fully consistent operator check bypasses that gateway cache, so an immediate denied check can coexist briefly with an HTTP 200 after a revoke. Explain that expected interval explicitly.

Dependency APIs are `mori://shinzui/en/packages/en-client` and `mori://shinzui/en/packages/en-servant`. Lookup sources through Mori before choosing check wire types or consistency. Prerequisite EP-186 M0 upgrades En to `c3ee100a0b2cc63a50a9473ef590de7086dca4d0` and Shomei to `0eedad1328a910b457f86bc79bc42024aca33a20`; use those APIs and matching service images. Shomei subject mapping is exact verified TypeID text, following `mori://shinzui/shomei/packages/shomei-core`. Email is an input lookup aid, not an En principal.

[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md) preserves portal session handling and header stripping. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) owns aliases and hostname collision checks. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), Decision section, requires owned saved reviews; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires interpreter checks and a gated committed candidate before native confirmation. Source image parity and upstream database ownership remain governed by ADR 1 and ADR 2. The 2026-10-12 amendment to ADR 22 records the selected contracts; add implementation evidence there.


## Plan of Work

### M1: Effective-access diagnostic

Add `nagarectl access check --host HOST --user EMAIL_OR_ID [--json]`. Normalize/validate the host using the same route contract as grant. Resolve user identity through the existing Shomei resolver. Require a context-owned protected route and accepted En binding; reject a public or foreign host with a useful diagnostic. Send a FullyConsistent En check for `user:<id>`, permission `access`, object `app:<host>`, using private service credentials. The user's login token is not an En API key.

Expose one typed result: Allowed, Denied, Conditional with the API's caveat obligations, or Unavailable with a bounded non-secret diagnostic. JSON contains host, resolved subject, permission, decision, and required `checkedAt` consistency token; optional `grantGeneration` may be reported when present. Neither field is a timestamp, and neither creates a gateway invalidation feed by itself. Issue one En check for one user/host; do not expand or list teams to infer the decision. Plain output explains the current result and gateway cache caveat. Exit zero for a successful Allowed/Denied/Conditional query and nonzero for invalid input or unavailable service; denied is a valid answer, not a transport failure. No tuples, route config, or inventory history are written. Do not derive the answer from `access list`, which reports stored relationships and may not capture every effective path.

Implement tests with a recording transport and real typed response decoding in `cli/nagarectl/test/AccessGrantsSpec.hs` or a new `AccessCheckSpec.hs` registered in the Cabal test suite. Check public parser wiring and JSON encoding, authenticated context transport, FullyConsistent choice, all result states, missing keys, invalid users, public hosts, and secret-free diagnostics.

### M2: Public-command and gateway equivalence

Create a reusable integration scenario under `cli/nagare-access/test`, proposed `SiteAccessIntegrationSpec.hs`, and corresponding CLI adapter tests. Use the real En evaluator and concrete schema from the auth payload, not a handwritten second schema. Drive signed-in verified subjects, representative review loading, memberships, direct grants, and group grants. Wire the actual check request and response through the gateway adapter. Use generated route/backend bytes from the site compiler rather than reconstructing a backend map by hand.

The scenario has protected sites A and B; Alice belongs to engineering, Bob belongs to finance, and Carol has no membership. Engineering is granted A; finance is granted B. Alice gets A only, Bob gets B only, Carol gets neither. Then give Carol an individual A grant, verify she gets A only, and revoke it. Give Alice an independent direct A grant, remove her engineering membership, prove A remains allowed, then revoke the direct path and prove denial. Repeat the coverage for StaticSite, ServerSite, Deployment, Application, alternate hosts, and private previews using parameterized test inputs rather than duplicated scenarios.

Inject clock changes to prove the gateway decision TTL and zero-TTL behavior without sleeping. An En fully consistent check immediately reflects accepted writes; gateway misses also reflect them; gateway hits expire within the configured TTL. An En outage on an empty or expired cache gives 503, no upstream call, and no cached failure; restore transport and prove retry. Conditional responses fail closed. Record no upstream request for an ungranted authenticated user. Malformed backend policy and absent auth routes cannot open an origin.

Run the relationship adapter through lost acknowledgements and public `inventory resume`, status, and retirement loader paths already covered by EP-187; integration tests assert their resulting access state, not just a successful provider operation. These tests must pass before native confirmation.

### M3: Native proof and operator documentation

On a disposable accepted local test context, using candidate images built from the same pinned source revisions, exercise the real Shomei login, En mutations, enforcer, and static/server public routes. Follow `docs/runbooks/before-a-native-run.md`; native runs confirm tested behavior, and a finding adds the cheapest class-level regression before retrying. Do not start a new cloud deployment merely to complete this child.

Capture a bounded transcript showing anonymous browser redirect and API 401, signed-in ungranted 403, accepted team grant producing 200 only for its members and exact host, revoked last path yielding 403 after the documented TTL, a fully consistent diagnostic observing revocation before a cached gateway entry expires, origin-bypass refusal, private preview refusal, and protected rollback. Verify active En schema and exact image references. Do not save credentials, cookies, refresh tokens, or raw secret-bearing environment dumps. Add a check that a raw client identity header cannot grant access.

Update `docs/user/access.md`, `docs/user/static-hosting.md`, `docs/capabilities/forward-auth-route-enforcement.md`. Provide a protected StaticSite and ServerSite example under `cluster/examples` with the correct access field, reviewed grant procedure, aliases/previews behavior, direct-versus-team list explanation, fully consistent check, and revocation bounds. State that public defaults remain, no login-only mode or administrator bypass exists, and site access is not application authorization. The static-hosting guide also owns the server-site workflow; extend its existing server sections.

Review the child and parent Decision Logs and promote the durable user/team resource boundary, preview behavior, supported policy subset, tuple ownership, and cache contract into a local ADR using `agents/skills/exec-plan/ADR.md`. Update the MasterPlan registry only after all child acceptance is proved.


## Concrete Steps

Commands run at Nagare root. Read the source interfaces and test labels first:

```bash
mori path mori://shinzui/en/packages/en-client
rg -n 'CheckRequestWire|CheckResponseWire|FullyConsistent' cli
cabal test nagare-access-test --project-dir=cli/nagare-access --test-show-details=direct
just test-remote HEAD '/access/ || /site/' '0/1'
just gate-fast
```

A future authorized drill, with Alice already registered and the accepted protected host A configured, uses the new command:

```bash
nagarectl access check --host a.apps.example.com --user alice@example.com --json
nagarectl access team add-member --team engineering --user alice@example.com --save-plan ./member-review
nagarectl inventory apply ./member-review --yes
nagarectl access grant --host a.apps.example.com --team engineering --save-plan ./grant-review
nagarectl inventory apply ./grant-review --yes
nagarectl access check --host a.apps.example.com --user alice@example.com --json
nagarectl access check --host b.apps.example.com --user alice@example.com --json
```

Expected decisions are denied before the grant, allowed for A after it, and denied for B throughout. Use `curl -sS -o /dev/null -w '%{http_code}\n'` with a private session-cookie input supplied by the fixture for HTTP verification; avoid putting secrets in transcripts or command lines. The fixture owns login and token cleanup. Obtain a committed candidate gate record before the native drill and record the actual fixture invocation in Progress once it exists.

The native drill is `scripts/site-access-drill.sh` (M3). It runs from an empty environment on a disposable Docker daemon, with the auth images built from this tree by `cluster/bootstrap/auth-images/build-local-image.sh` under `NAGARE_MODE=local` and `NAGARE_AUTH_PUSH=0`:

```bash
DOCKER_HOST=unix://$HOME/.colima/nagare-mp23/docker.sock \
NAGARE_DRILL_NAGARECTL=$(cabal list-bin --project-dir=cli/nagarectl nagarectl:exe:nagarectl) \
NAGARE_DRILL_HARNESS=$(cabal list-bin --project-dir=cli/nagare-harness nagare-harness) \
NAGARE_DRILL_GHC_ENV=$PWD/cli/nagarectl/.ghc.environment.aarch64-darwin-9.12.4 \
NAGARE_DRILL_IMAGE_TAG=mp27-<revision> NAGARE_DRILL_RESET=1 \
  scripts/site-access-drill.sh
```

It bootstraps a `site-access` context, verifies the served En schema and the images, publishes and deploys `cluster/examples/protected-static-site` and a preview, runs `nagare-harness route-check --team engineering --other-team finance` against the production host, then drives a direct grant through the real login: the preview refuses the production grant, a raw identity header admits nobody, the origin's cluster-local hostname has no external route, the diagnostic says denied the moment a revoke is applied while the cached session may still be served, the session is refused within the decision TTL, and a second release rolls back to the first with its protection intact. Its record is `evidence/site-access-drill.json` under the drill root.


Revision (2026-10-12): Consume the latest dependency APIs and verified diagnostic fields. Keep functional and freshness integration acceptance; performance checks remain the specific cache and tuple-read regressions owned by EP-186/187, without a general load suite.


## Validation and Acceptance

Acceptance is the M1 result-state contract plus the M2 isolation scenario and M3 real-service transcript. A team grant authorizes exactly its members on that host; signing in alone cannot produce 200 on a protected route. Diagnostics accurately distinguish Allowed, Denied, Conditional, and Unavailable, and never write relationships. List output does not disguise derived access as a direct grant. Alias, origin, preview, and rollback tests agree with the documented protection policy. Removing the last path revokes within the configured gateway TTL, while an independent path correctly preserves access.

Documentation commands must run once through the real CLI on the disposable context. All focused tests pass, required candidate gates are green, relevant examples load, and ADR citations resolve locally. Native evidence names exact candidate/image/schema revisions and contains no secrets. Per-path policies, delegated sharing, and resource/action permissions are not required acceptance for this initiative.


## Idempotence and Recovery

The check command is read-only and repeatable. Reuse original saved reviews and transaction IDs after ambiguous mutations; never issue raw En writes to simplify the drill. The fixture uses distinct disposable host/team keys, revokes only its own grants and memberships, and retires/collects owned resources through reviewed commands. Do not delete auth databases or modify migration ledgers. Interrupted drills retain a manifest of owned fixture scopes and cleanup reviews. Do not downgrade a group schema while group tuples remain.


## Interfaces and Dependencies

Both preceding children must be Complete. EP-186 owns the private route and gateway freshness contract; EP-187 owns typed stored relationships, team lifecycle, and grant listing. This child consumes both and owns the read-only effective-check API, combined tests, operator runbooks, native acceptance evidence, and final ADR distillation. It adds no Shomei claim, database table, auth service, or upstream dependency pin. If a pinned response lacks a desired diagnostic field, report only supported data and revise the proposed JSON contract explicitly rather than inventing an API.
