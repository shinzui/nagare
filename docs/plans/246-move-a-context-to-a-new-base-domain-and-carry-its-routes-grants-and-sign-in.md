---
id: 246
slug: move-a-context-to-a-new-base-domain-and-carry-its-routes-grants-and-sign-in
title: "Move a context to a new base domain and carry its routes, grants and sign-in"
kind: exec-plan
created_at: 2026-11-04T17:50:22Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-04T17:50:22Z
---

# Move a context to a new base domain and carry its routes, grants and sign-in

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

An operator with a running direct context can move it to a new base domain on a Cloudflare zone, served through a
tunnel, with one reviewed, resumable, reversible command. Afterwards every site answers on its new name, everyone who
could open a site still can and nobody else can, people sign in on the new auth host, no data has changed, and the VM
accepts no inbound web connection.

The first customer is the intranet, context `intranet`, moving from `labs.topagentnetwork.net` to
`topagentnetworklabs.com` with the portal at the apex and sign-in at `auth.topagentnetworklabs.com`. Its run, date and
team notice belong to `mori://tan/tan-ng-labs/plans/14-re-home-the-intranet-onto-topagentnetworklabs-com-through-a-cloudflare-tunnel`.
This plan is complete when the move is proved on a disposable context.


## Progress

Each deliverable passes on the evidence it names. Native evidence comes only after the interpreter evidence, under
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md).

- [ ] D1, the list: `nagarectl context move --ingress cloudflare-tunnel --base-domain NEW --list` mutates nothing and
  prints every URL that changes, and writes `move-manifest.json`. The manifest holds every accepted hostname (apex, auth
  portal, admin API, `nagared` hooks, custom, default and preview) with its new name, kind and protection; every direct and
  team grant on it, read from En at a fully consistent snapshot; every Shomei OAuth client whose `redirect_uris` name the old
  base; and every account holding a passkey, marked with whether it also holds TOTP. It refuses, naming the host, a name
  outside the old base, two names that map to one, a name deeper than one label under the new base and a clash with a
  reserved platform name. Evidence: fake-adapter tests over each refusal, and a fixture holding every web kind.
- [ ] D2, the profile: an open move, and nothing else, changes `NAGARE_BASE_DOMAIN`, `NAGARE_INGRESS` and
  `NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED` together. A plain context review of any of them is still refused. The move refuses
  while the process environment sets `NAGARE_BASE_DOMAIN` to anything but the journal's value. The Pulumi projection keeps
  the old base as the retained zone's `dnsName`, so a preview with the new base shows no replace or delete of the Cloud DNS
  zone, its records, or a firewall rule. Evidence: review tests, and a new variant in
  `infra/pulumi/test/resourceProgramParity.test.ts`.
- [ ] D3, the auth plane: after the flip, the enforcer's cookie domain is `.<new>`, `SHOMEI_WEBAUTHN_RP_ID` is `<new>`,
  `SHOMEI_WEBAUTHN_ORIGINS` is exactly the new auth origin with the old one gone, and `SHOMEI_PUBLIC_BASE_URL` is that
  origin. `SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_ISSUER` and the audience are byte-identical, as are the cookie key and
  Shomei's key-encryption key. A service account's token issued before the flip still verifies after it. Evidence: a
  compiled-scope test of the auth owner across the flip, and a `cli/nagare-access` test against real Shomei.
- [ ] D4, passkeys: nobody is locked out by a passkey the browser can no longer use. In the flip, rows of
  `shomei.shomei_webauthn_credentials` are exported to a sops-encrypted file in the context's `cluster-secrets` directory
  and then deleted, in that order, and the step refuses if the pinned Shomei's columns differ from the ones it names. A
  password-and-passkey account then signs in with its password and can register a new passkey; a TOTP account is still asked
  for TOTP; rollback restores the table to the exported rows exactly. Evidence: a test against real Shomei covering all
  three.
- [ ] D5, routes and grants: for each host in the manifest, the new route is accepted, then its grants are accepted, then
  `nagarectl access check` passes for every subject the manifest lists and fails for one it does not. Only retirement (D7)
  revokes an old grant or removes an old route. A grant that fails to declare leaves the old route and grant in place, and
  `context move status` names what is left, including any site not yet redeployed. Team memberships are not rewritten,
  because they do not name a host. This uses EP-243 D11's carrier with this plan's host map. Evidence: fake-adapter tests
  stopping at each host and kind.
- [ ] D6, the order and its exits: the move runs the sequence in Plan of Work and refuses to advance otherwise. An
  interpreter test stops it after every step, then proves resume reaches the end state and rollback reaches a context
  serving on the old base with its old grants and passkeys. Evidence: the stuck-state invariant test from
  [Before a native run](../runbooks/before-a-native-run.md) covering this transaction.
- [ ] D7, retirement: `context move retire` is a separate, separately approved step. It revokes the old grants, retires the
  old routes, then retires the old Cloud DNS zone and deletes the passkey export. It refuses to retire the zone while the
  parent domain still publishes an NS delegation for the old base. Evidence: fake-adapter tests, including that refusal.
- [ ] D8, the rehearsal: the Rehearsal section below passes in full on a disposable context, and the length of the
  sign-in outage is recorded, because the team's notice states it. Evidence: an audit file under `docs/audits/`.
- [ ] D9, docs and decisions: `docs/user/cloudflare-tunnel.md` no longer says moving a context is not built, and describes
  the move, rollback and retirement with EP-243's D10. ADR 20 and ADR 34 are amended, since a base domain can now change, and
  ADR 29 is amended with how a grant follows a host. Evidence: the linked pages.


## Surprises & Discoveries

- 2026-11-04, while writing this plan. A password-and-passkey account with no TOTP would have been locked out by the move,
  not asked to re-register. Shomei gates on any stored passkey, `hasSecondFactor = passkeyCount > 0 || totpEnrolled`, in
  `mori://shinzui/shomei` at `shomei-core/src/Shomei/Session/Authentication/Workflow.hs` (artifact-level URI pending), and a
  browser refuses a stored passkey on another domain. Password reset does not clear that gate, the auth portal offers no TOTP
  enrolment, and there is no administrator endpoint for a user's passkeys. This produced D4.
- 2026-11-04, same reading. Shomei's issuer does not follow the domain: `cluster/bootstrap/shomei/service.yaml` sets the
  literal `nagare-shomei`, matched by `cluster/bootstrap/nagare-access/service.yaml`. There is nothing to roll, so D3 proves it
  stays the same.


## Decision Log

- Decision: One command with two step lists. `nagarectl context move --ingress cloudflare-tunnel` is EP-243's move on the
  same domain, and adding `--base-domain NEW` selects this plan's list. EP-243 owns the journal, the refusal to advance,
  firewall and `kourier` closure, rollback's reopen-first rule, Cloud DNS retention, the closed-port proof, and the
  grant carrier of its D11, which takes a host map. This plan owns the host map across a base change, the profile change, the
  auth plane and passkeys, the OAuth and webhook lists, retirement, and its own rehearsal. The head of EP-243's D3 and all of
  its D4 do not apply here: the new zone is already active, the old domain's name servers never change, and new records never
  pointed at the VM, so there is no name server wait, no DNS-only mirror, no renewal window and no old TTL to outlast. Its
  DS refusal does apply, to the new domain.
  Rationale: a second engine would duplicate the riskiest code in MasterPlan 32. The operator asked for the two plans to be
  divided, not duplicated.
  Date: 2026-11-04

- Decision: The move is one cutover with a stated sign-in outage, and old names are not kept alive or redirected. Old names
  stop answering at the flip.
  Rationale: a context has one cookie domain, one relying-party ID and one Knative base. With origin TLS on, a new name
  cannot get a certificate, because the DNS-01 solver writes to Cloud DNS; with it off, the old names lose HTTPS, and
  `checkIngressMode` forbids a tunnel beside it. A redirect would need the old names served, which is what closing the ports
  removes. The team is told the date and the URL list.
  Date: 2026-11-04

- Decision: Passkeys are exported and removed in the flip (D4), and their holders are password-only until they register a
  new one. Holders are tracked by `mori://tan/tan-ng-labs/plans/14-re-home-the-intranet-onto-topagentnetworklabs-com-through-a-cloudflare-tunnel`
  D5.
  Rationale: a passkey cannot survive the change and its row blocks sign-in. Rejected: asking each user to delete theirs first
  (a straggler is locked out with no administrator exit); `SHOMEI_MFA_REQUIRE_SECOND_FACTOR=false` (also drops TOTP for those
  who have it, and the rows still block once it returns); WebAuthn Related Origin Requests (needs the old domain served); an
  `rp_id` column in Shomei (an upstream release for a one-time event, worth raising with Shomei if a second move ever happens).
  Date: 2026-11-04

- Decision: Sites are redeployed from their own configs, with `deploy -f` and the new `NAGARE_BASE_DOMAIN`. The move never
  rewrites an accepted scope's bytes. While a move is open, the tunnel's refusal of a domain outside the zone admits exactly
  the old hosts in the manifest, and the deploy keeps each old route beside its new one.
  Rationale: configs carry hostnames in environment values too (the intranet portal's `PORTAL_PUBLIC_ORIGIN`), so a host
  rewrite of the bytes would miss them and the config would disagree with the ledger. A grant binds to an accepted route, so an
  old route must outlive its old grants to keep rollback mechanical.
  Date: 2026-11-04

- Decision: The parent's NS delegation goes before the old Cloud DNS zone, and retirement enforces it. The zone is held
  through the whole move.
  Rationale: a delegation naming a deleted Cloud DNS zone leaves the name open to takeover, and the zone is also what makes
  rollback's certificate issue possible. This reverses the order in plan 14's D6.
  Date: 2026-11-04

- Decision: The order of work is the operator's. The release holding F145, F150, F151 and EP-239 moves the intranet first. Then
  this plan and EP-243 finish and the full move is rehearsed on a disposable context. Then the team gets the date and the
  changed-URL list. Then the intranet moves, on a release holding this plan and EP-245 D1 to D3.
  Rationale: operator, 2026-11-04, through the session working on EP-240. The move needs restore proved first, and the portal's
  own calls to the admin API cross the edge, so it needs EP-245's edge.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** A context is one Nagare installation's target, a file of `export` lines. Its base domain is the name every site
hangs under. The inventory ledger is the reviewed record of what each scope owns. A grant is an En relationship letting a user
or team open one hostname. A passkey is a browser credential bound to one domain, the relying-party ID. The flip is the step
where the context starts using the new base.

**What holds the old name today.**

- The profile: `compatible` in `cli/nagarectl/src/Nagare/Context/Review.hs` leaves out `baseDomain` and `ingress`, so a review
  changing them is refused with "context authority or resource identity changed". `ContextBinding` is the context and project,
  so the ledger's identity does not change with the domain.
- Knative: `cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs` writes `config-domain`, and in tunnel mode the flat
  `domain-template`.
- Auth: `authBaseDomain` in `cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs` sets the cookie domain and relying-party ID.
  `cli/nagarectl/src/Nagare/Access/Resolve.hs` keeps the portal origin, adds origins without removing old ones, and refuses an
  auth portal outside the base (`isUnderBaseDomain`).
- Hostnames: `cli/nagarectl/src/Nagare/Deploy/Host.hs` gives the shapes, nested on direct and flat in tunnel mode.
  `cli/nagarectl/src/Nagare/Inventory/TunnelRoute.hs` holds the tunnel's refusals. `cluster/bootstrap/nagared/service.yaml` holds
  the `hooks.<base>` route.
- Grants: `cli/nagarectl/src/Nagare/Inventory/Access.hs` binds a host grant to that host's exact accepted protected route. A site
  deploy cannot drop a route under its grants, so the order is route, grants, later revoke, later retire.
- Perimeter: `infra/pulumi/src/components/NagarePerimeter.ts` derives the Cloud DNS zone's `dnsName` from `baseDomain`, so a plain
  change replaces the zone. `withTunnelPerimeter` in `cli/nagarectl/src/Nagare/Inventory/Cloud.hs` removes the zone and the
  rules from the catalog, which EP-243's retention must hold for an open move.
- The tunnel: `tunnelUpstreamInputs`, called from `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`, drops the DNS-01 issuer.
  `cli/nagarectl/src/Nagare/Inventory/Components/CloudflareZone.hs` refuses a base that is not the zone's own name.

**What does not change.** Databases, volumes and backups do not key on a hostname, and no data moves. Stored Kansoku events keep
the host they were recorded on. Existing sessions end, because browsers do not send the old cookie to the new domain, so everyone
signs in once.

**Decisions this rests on.**
[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) makes routing and TLS ownership explicit.
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) makes each hostname its own authorization object
with no bypass and never rewrites a protected route in place.
[ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md) sets the topology, requires the base
to be the zone for the free certificate, and treats both Cloudflare credentials as interception credentials.
[ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md) requires a rebuilt
node to rejoin the same tunnel. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) keeps
cloud writes on the active project.

**The host map.** `x.<old>` becomes `x.<new>`, the apex stays the apex, `auth`, `admin` and `hooks` keep their labels, and a
nested default name `<name>.<namespace>.<old>` becomes `<name>-<namespace>.<new>`. A preview follows `previewHostName`. When the
new base is the zone itself, flattening is not a question, so EP-243 D11's prompt is skipped.


## Plan of Work

Build on the interpreter first: the manifest and its refusals (D1), the profile and retained zone (D2), the auth plane (D3),
passkeys against real Shomei (D4), the carrier with a host map (D5), then the sequence with stops at every step (D6) and
retirement (D7). EP-243's D2, D3, D5 and D11 are prerequisites and land first or together. Then rehearse (D8) and write up (D9).

The sequence. Each step stops on any refusal, and the journal records where it stopped.

1. **Preconditions, no mutation.** The ledger is idle. The manifest still matches the live context. Backups of `en-db`,
   `shomei-db` and every app database were verified inside the recovery point. The zone holds no record, tunnel or rule from
   anyone else. The new domain has no foreign DS record. The Cloudflare token works for this account and zone.
2. **Zone.** The Cloudflare zone stage creates the tunnel, proxied apex and wildcard records, edge policy and cache bypass, and
   `tunnel token` saves the token. The operator turns DNSSEC on at Cloudflare. Old names still serve, untouched.
3. **Flip; the outage starts.** The profile changes (D2), the platform stages run until a review has no operations, the connector
   starts, the auth plane rolls (D3), and passkeys are exported and removed (D4). Old names stop. The firewall, the `kourier`
   LoadBalancer and Cloud DNS stay as they were.
4. **Sites.** The auth portal first, then the apex, then the rest, each from its config, followed by its grants (D5). The admin
   API's route and grants move with the platform. OAuth redirect URIs and `nagared` webhook URLs on the list are updated here;
   they are operator steps at Shomei and GitHub.
5. **Verify; the outage ends.** `domains check`, `tunnel status` and `doctor` pass, except for the still open port that step 6
   closes. `access check` passes for every manifest subject. A real browser signs in at the new auth host and is refused on an
   ungranted site. Then take fresh `en-db` and `shomei-db` backups, because a restore from before the move lacks the new grants.
6. **Close.** EP-243's closing steps: close the firewall, then make `kourier` `ClusterIP`. `doctor` is now fully green.
7. **Retire, later and separately (D7).** After the people are confirmed on the new domain, the parent's delegation is removed by
   whoever owns it, then `context move retire` runs.

Rollback from any step before retirement: reopen the firewall and restore `kourier`, restore the profile and platform stages so the
issuer returns (Cloud DNS is still there, so the wildcard certificate can be issued), redeploy sites from their configs on the old
base, and restore the passkey table from the export. Passkeys registered after the flip are lost by that restore. Old grants were
never touched. The new zone's records are removed by retiring the Cloudflare zone scope; the zone itself stays.


## Concrete Steps

From the repository root, on a shell with the active context selected and `CF_ACCOUNT_ID`, `CF_ZONE_ID` and `CF_API_TOKEN` set:

```bash
nagarectl context move --ingress cloudflare-tunnel --base-domain "$NEW" --list --out ./move   # read-only; the changed URLs and move-manifest.json
nagarectl context move --ingress cloudflare-tunnel --base-domain "$NEW" --out ./move          # saves the reviews
nagarectl context move apply ./move --yes                                                     # runs and resumes the sequence
nagarectl context move status                                                                 # where it stopped and what is left
nagarectl context move rollback --yes
nagarectl context move retire --save-plan ./retire
```

EP-243 uses the same commands without `--base-domain`. Add no `just` recipe.


## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. Land with `just land`, and because this touches
`cli/nagarectl/app` and the planner, build `exe:nagarectl` and run the full gate before landing. `npm test` in `infra/pulumi`
covers D2.

### Rehearsal (D8)

On a disposable direct context in `tan-nb-exp`, from a packaged build of the landed revision, after
[Before a native run](../runbooks/before-a-native-run.md) and the operator's go-ahead for this bounded sequence. Its old base is a
Cloud DNS delegated name the operator gives at the go-ahead. Its new base is `topagentnetworklabs.com` with the drill's token,
`cloudflare-api-token-ep240`. The zone must be empty before and after.

1. **Seed.** A protected Deployment at the apex, the auth portal, a public service, a protected static site with a preview, a
   server site, and a Shomei service account with an admin API grant; a direct grant and a team grant; a
   password-and-passkey account using a browser virtual authenticator and a TOTP account, on a host labelled as a test; an app
   database and a platform database with seeded rows.
2. **List.** The changed-URL list names every one of these. A continuous request loop runs on the old and new names.
3. **Move.** Old names serve until the flip. After verify, the loop has no failed request on a new name.
4. **Observe.** Every assertion of D3, D4 and D5; the admin API answers the service account's existing token; the seeded rows read
   back unchanged.
5. **Roll back once from after the close.** The firewall reopens first, the old names serve over HTTPS with a certificate that
   verifies, the old grants pass `access check`, and the old passkey signs in. Then move again.
6. **End state.** EP-243 D6's checks: from a machine on neither the tailnet nor the project, TCP 80 and 443 are closed;
   `gcloud compute firewall-rules list` shows exactly `fw-iap-ssh` from `35.235.240.0/20`; `ss -ltn` on the host shows no listener
   on 80 or 443.
7. **Afterwards.** `inventory rebuild-decisions` plans with no reference to the old base; the context upgrades to a later packaged
   build and still serves; `context move retire` refuses while the parent's delegation exists, and the zone stays.
8. **Teardown** as EP-240 did it, checking the same list of leftovers. The zone holds no record, tunnel or rule afterwards, because
   the intranet needs it empty.

Stop on any refusal or guard, and report to the operator.


## Idempotence and Recovery

The move resumes from its journal, and repeating a finished step does nothing. Before the flip, nothing users can see has changed.
From the flip until retirement, rollback is the recovery and needs Pulumi state, the Cloudflare token, the passkey export and the
operator's IAP or tailnet access. No step changes application data; the only row changes are the passkey table's, and they are
exported first. Retirement is the only step that cannot be undone, which is why it is separate.


## Interfaces and Dependencies

Requires EP-243 D2, D3, D5 and D11, and EP-241 and EP-242, which are complete. A rehearsal needs EP-245 D1 to D3 so that it observes
the final edge. Consumes `NAGARE_INGRESS`, `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `CF_API_TOKEN`, `nagarectl domains check`, `nagarectl
tunnel`, `nagarectl access check` and `nagarectl inventory rebuild-decisions`.

Consumed by `mori://tan/tan-ng-labs/plans/14-re-home-the-intranet-onto-topagentnetworklabs-com-through-a-cloudflare-tunnel`, whose
D2 uses the list from D1 and whose D4 runs the sequence. It holds its own API token, scoped as MasterPlan 32 lists, and the
installation's hostnames and notices. The Shomei schema this names is from `mori://shinzui/shomei`,
`shomei-migrations/migrations/shomei/0014-shomei-webauthn-credentials.sql` (artifact-level URI pending).
