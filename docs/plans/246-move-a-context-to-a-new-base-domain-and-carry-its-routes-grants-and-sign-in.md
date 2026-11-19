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

- [x] D1 (`nagarectl context move list --base-domain NEW [--out DIR]`; `Nagare.Context.BaseMove`, `Nagare.Access.ShomeiMove`, `Nagare.Test.ContextBaseMove`: every web kind and each refusal by name; grants from the ledger, refused when En differs): the list: `nagarectl context move --ingress cloudflare-tunnel --base-domain NEW --list` mutates nothing and
  prints every URL that changes, and writes `move-manifest.json`. The manifest holds every accepted hostname (apex, auth
  portal, admin API, `nagared` hooks, custom, default and preview) with its new name, kind and protection; every direct and
  team grant on it, read from En at a fully consistent snapshot; every Shomei OAuth client whose `redirect_uris` name the old
  base; and every account holding a passkey, marked with whether it also holds TOTP. It refuses, naming the host, a name
  outside the old base, two names that map to one, a name deeper than one label under the new base and a clash with a
  reserved platform name. Evidence: fake-adapter tests over each refusal, and a fixture holding every web kind.
- [x] D2 (`Nagare.Context.BaseFlip`: the flip writes the four values together and undoing it restores them, a shell naming another base is refused, `Nagare.Test.ContextBaseMove`; `perimeterDomainRecords.test.ts` and the `foundation-managed-image-retained` parity variant keep the zone, its records and every rule across the base change; the seed projects the retained name from the flip, `Nagare.Test.Init`), the profile: an open move, and nothing else, changes `NAGARE_BASE_DOMAIN`, `NAGARE_INGRESS` and
  `NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED` together. A plain context review of any of them is still refused. The move refuses
  while the process environment sets `NAGARE_BASE_DOMAIN` to anything but the journal's value. The Pulumi projection keeps
  the old base as the retained zone's `dnsName`, so a preview with the new base shows no replace or delete of the Cloud DNS
  zone, its records, or a firewall rule. Evidence: review tests, and a new variant in
  `infra/pulumi/test/resourceProgramParity.test.ts`.
- [x] D3 (compiled-scope test `InventoryAuthSpec`: on a new base only the enforcer's cookie domain and Shomei's relying party change, every Secret byte-identical, the settings name only new origins; `PasskeyMoveSpec` against real Shomei: an access token issued before the flip verifies under the new base's auth plane), the auth plane: after the flip, the enforcer's cookie domain is `.<new>`, `SHOMEI_WEBAUTHN_RP_ID` is `<new>`,
  `SHOMEI_WEBAUTHN_ORIGINS` is exactly the new auth origin with the old one gone, and `SHOMEI_PUBLIC_BASE_URL` is that
  origin. `SHOMEI_ISSUER`, `NAGARE_ACCESS_SHOMEI_ISSUER` and the audience are byte-identical, as are the cookie key and
  Shomei's key-encryption key. A service account's token issued before the flip still verifies after it. Evidence: a
  compiled-scope test of the auth owner across the flip, and a `cli/nagare-access` test against real Shomei.
- [x] D4 (`cluster/bootstrap/shomei/move/*.sql` run by `remove-passkeys` and by `PasskeyMoveSpec` against real Shomei: removal after export of exactly the exported rows, password sign-in and passkey registration begin for a former holder, TOTP still asked, exact restore; the column refusal in `Nagare.Cli.Move.Passkeys`), passkeys: nobody is locked out by a passkey the browser can no longer use. In the flip, rows of
  `shomei.shomei_webauthn_credentials` are exported to a sops-encrypted file in the context's `cluster-secrets` directory
  and then deleted, in that order, and the step refuses if the pinned Shomei's columns differ from the ones it names. A
  password-and-passkey account then signs in with its password and can register a new passkey; a TOTP account is still asked
  for TOTP; rollback restores the table to the exported rows exactly. Evidence: a test against real Shomei covering all
  three.
- [x] D5 (`Nagare.Context.MoveRoutes` carries a granted route through a redeploy, `Nagare.Test.ContextMoveChecks`; `Nagare.Context.MoveSites` waits for each new route then plans each grant on the new name once, `InventoryAccessSpec`; admission takes redeploys only during `carry-sites`, `Nagare.Test.ContextMoveStore`; `verify-sites` checks listed and unlisted subjects and the edge; `status` names what is left), routes and grants: for each host in the manifest, the new route is accepted, then its grants are accepted, then
  `nagarectl access check` passes for every subject the manifest lists and fails for one it does not. Only retirement (D7)
  revokes an old grant or removes an old route. A grant that fails to declare leaves the old route and grant in place, and
  `context move status` names what is left, including any site not yet redeployed. Team memberships are not rewritten,
  because they do not name a host. This uses EP-243 D11's carrier with this plan's host map. Evidence: fake-adapter tests
  stopping at each host and kind.
- [x] D6 (`Nagare.Test.ContextBaseMoveRun`: stopped after every step's effect, resume reaches the end state and rollback the old base with its passkeys, and a rollback stopping after any inverse resumes; the outage is only between the flip and `verify-sites`), the order and its exits: the move runs the sequence in Plan of Work and refuses to advance otherwise. An
  interpreter test stops it after every step, then proves resume reaches the end state and rollback reaches a context
  serving on the old base with its old grants and passkeys. Evidence: the stuck-state invariant test from
  [Before a native run](../runbooks/before-a-native-run.md) covering this transaction.
- [x] D7 (`context move retire`, `Nagare.Context.MoveRetire`: revoke, retire the grant scopes, drop the old routes, then the Cloud DNS set; `zoneRetirement` refuses under a live delegation, `InventoryAccessSpec`), retirement: `context move retire` is a separate, separately approved step. It revokes the old grants, retires the
  old routes, then retires the old Cloud DNS zone and deletes the passkey export. It refuses to retire the zone while the
  parent domain still publishes an NS delegation for the old base. Evidence: fake-adapter tests, including that refusal.
- [x] D8 ([audit](../audits/ep246-base-move-rehearsal-2026-11-19.md): every step on `ep246d`, sign-in outages of about 19 and 17
  minutes, the upgrade to master `b462828a`, the teardown with the zone left empty), the rehearsal: the Rehearsal section below passes in full on a disposable context, and the length of the
  sign-in outage is recorded, because the team's notice states it. Evidence: an audit file under `docs/audits/`.
- [x] D9 ([`docs/user/moving-to-a-new-base-domain.md`](../user/moving-to-a-new-base-domain.md), [`docs/runbooks/context-move.md`](../runbooks/context-move.md), the tunnel guides' links, ADR 20, ADR 29 and ADR 34 amended 2026-11-16), docs and decisions: `docs/user/cloudflare-tunnel.md` no longer says moving a context is not built, and describes
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

- 2026-11-16, D8 rehearsal on `ep246d`. A fresh cloud context could not bootstrap: the posture read EP-243 added opened the
  remote inventory store before its bucket existed. Fixed in `4d38b541` before any cloud change.
- 2026-11-16, same run. A reviewed deploy updates the auth portal's settings maps but does not restart Shomei or the enforcer,
  which read them only at startup, so the first portal on `ep246d` refused a new passkey (`webauthn_verification_failed`, Shomei
  still on its default origin) until `access portal sync`. After the flip the same holds for the portal's new host, so
  `carry-sites` now waits for a sync (`portalSyncPending`, from the maps digest the sync records) and the guides say so.
- 2026-11-16, same run. Nagare never sets `SHOMEI_TOTP_ENCRYPTION_KEY`, so Shomei answers `totp_disabled` and no Nagare account
  can hold TOTP. The guide no longer promises TOTP survives the move; the rehearsal has no TOTP account.

## Decision Log

- Decision: The move's steps are EP-243's engine with this list: `check-preconditions`, `create-zone`, `enable-dnssec`,
  `start-connector`, `flip-base`, `remove-passkeys`, `carry-sites`, `verify-sites`, then EP-243's `close-firewall`, `close-kourier` and
  `commit-move`. The flip writes the profile and stops for the shell to reload, because the environment wins over the context file, and
  the next run reviews the platform; undoing it does the same in reverse. The DNS-01 issuer goes at the flip (the posture's
  `originIssuer`), since Cloud DNS is not authoritative for the new base. Rolling back `create-zone` and `start-connector` keeps their
  scopes accepted, as EP-243 does. `remove-passkeys` removes exactly the rows it exported, so a passkey registered on the new domain after
  the export stays.
  Rationale: one engine for both moves; a profile change the running shell does not see would plan for the wrong base.
  Date: 2026-11-16

- Decision: While a base move is open, or the context still keeps its old base, a redeploy carries every accepted protected route an
  accepted grant still names, unchanged, beside the new routes; `carry-sites` admits the operator's own reviews so the sites can be
  redeployed. The move declares grants on new names itself and never rewrites a deploy's bytes.
  Rationale: a grant binds to its exact accepted route, so a redeploy that dropped it would orphan the grant; carrying the accepted
  members keeps rollback mechanical and leaves retirement as the only step that removes anything on the old names.
  Date: 2026-11-16

- Decision: The commands are EP-243's as built: `context move list --base-domain NEW [--out DIR]` is the read-only list, and
  `context move start --base-domain NEW` opens this plan's step list; `apply --yes`, `status` and `rollback --yes` are shared, and reviews
  are saved under the context's state directory as for EP-243. The manifest takes each host's grants from the ledger's accepted tuples and
  reads En fully consistently only to refuse when the two differ, because the carrier re-declares what the ledger accepted and an En-only
  grant could not be carried. EP-243 D11's carrier is built here (EP-243 Decision Log, 2026-11-16).
  Rationale: one command shape for both moves; a grant the move cannot carry must stop it before it opens, not after the flip.
  Date: 2026-11-16

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

- Decision: The rehearsal's passkey account uses a software authenticator (a P-256 key held by the drill) through Shomei's own
  registration and sign-in API over a port-forward, not a browser, and has no TOTP account.
  Rationale: Nagare does not enable TOTP (above), and a browser sign-in needs a test-labelled host, which neither base has. The
  software authenticator drives the same ceremonies, so the old passkey's sign-in after rollback is still proved.
  Date: 2026-11-16

- Decision: A carried route is the accepted route with Knative's per-route TLS opt-out
  (`networking.knative.dev/disable-external-domain-tls`), and a DomainMapping is updated in place. Carrying lasts while a base
  move is open, while the profile keeps its old base, and while an accepted tunnel config serves a base other than the profile's
  (a rolled-back move keeps its zone). `context move retire` retires the other base's names in both cases: after a commit the old
  names, after a rollback the new ones. Each run is one phase: revoke their grants, retire the grant scopes, retire the routes
  with retirement decisions, collect them; then after a commit the Cloud DNS phases follow, and after a rollback the zone and
  connector stay for a later move. The whole path, rollback redeploys and every retire phase, runs in the model before native.
  Rationale: the rehearsal's rollback (D8) left each carried new-base route waiting for a certificate the old issuer cannot
  solve, and after the move closed every redeploy refused `retirement-required`; the retire route phase planned no retirement
  decisions, so it would refuse the same way. A carried route is never served, so it needs no origin certificate, and only
  retirement removes routes (above). Rejected: relaxing the verify's readiness (hides real certificate failures), and dropping
  routes at rollback (against the carrier's rule). Reviewed removal of the zone and connector does not exist for any context;
  it is a finding for the deferral ledger.
  Date: 2026-11-19

- Decision: A redeploy carries only routes on the other base: during a move the base the profile is not on, after a commit the
  retained old base, after a rollback the kept zone's base; a carried route is deletable, and a later move keeps routes already on
  its target base. Default hosts take their shape from the posture, not from whether a zone is accepted. The admin API keeps an old
  route only while a grant names it, so retire's last route phase is a platform review that drops and retains it. A commit's
  retirement drops ordering edges to the retired cloud members, and a stamp that only lost edges is verified, not reissued.
  Rationale: the rehearsal's second move and commit (D8, 2026-11-19): carrying every dropped route kept a wrong route and blocked
  the second move; the zone rule gave the old base flat names after the rollback; the admin API's members exist only in the
  platform pipeline; the commit had never run, and its retirement left the stamp's and the catalog's edges dangling.
  Date: 2026-11-19

## Outcomes & Retrospective

A direct context moves to a new base on a Cloudflare zone with one reviewed, resumable command, and rolls back from after the
firewall and `kourier` close: rehearsed natively on `ep246d`, moved, rolled back, moved again, committed, upgraded and torn down, with
grants matching on every name, the seeded rows unchanged and a sign-in outage of about 17–19 minutes for the team's notice. The
rehearsal found the defects behind 30 fix commits one at a time, because the move's model test tracked journal flags without running
the planner, the route carrier and the Kubernetes model together; the rollback path now runs through them in
`InventoryBaseMoveRoutesSpec`, while certificate issuance is still not modelled. What remains is the intranet's own move, in
`mori://tan/tan-ng-labs/plans/14-re-home-the-intranet-onto-topagentnetworklabs-com-through-a-cloudflare-tunnel`, on a release that
holds this work, and F158–F161 in the findings ledger. Nothing moves to an ADR beyond the amendments D9 made.


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
