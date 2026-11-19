# EP-246 D8: base-domain move rehearsal on ep246d

Context `ep246d` in `tan-nb-exp`, direct ingress, old base `ep246.topagentnetwork.net` (delegated by an NS record added by hand to
`topagentnetwork-net-zone` in project `tan-ng-prod`),
new base `topagentnetworklabs.com` (Cloudflare zone `a0bc2ff6…`). Started on packaged build `42d83176` (`nagare-0.21.0`); every
defect the run found was fixed on branch `ep246-profile-roundtrip` with a unit or interpreter test and the per-commit gate, and
mirrored into the drill's packaged build. The branch landed on master as `c0df98bb` (2026-11-19, full gate green) after a local
upgrade rehearsal from v0.23.0 read its seeded data back unchanged. Upgrade target v0.22.0 (`26d63a3d`).

## 1. Seed

- Sites: apex (protected; alice, carol, dave and team engineering), auth portal, public `hello`, protected static site with
  preview `drill` (four preview stores), server site; admin API service-account grant (`access-before.tsv`).
- Accounts: carol has a software passkey (Shomei API, "none" attestation); no TOTP account (Decision Log 2026-11-16).
- Rows: app database notes `500 c77135795ddaac089628be2e3689ef5b`; Shomei users `5 3bbfd1cfea8b491fa85b7a4cfb45027b`; passkeys 1.

## 2. List

`context move list` names all ten hosts with their grants (`evidence/list/move-manifest.json`). Request loop from
2026-11-16T20:22Z (`evidence/loop.tsv`; one gap 2026-11-18 02:04:29–02:05:40 when the operator's terminal exited, before the flip).

## 3. Move (first)

DNSSEC: enabled 2026-11-16T20:57Z, DS in `.com` 2026-11-18T18:59:49Z (about 46 h, Cloudflare's registrar). Flip 2026-11-18
22:04:49Z. Sign-in outage: old auth host first failed 22:06:17Z, new auth host last failed 22:25:08Z, about 19 minutes.

## 4. Observe

Grants on the new names matched before the move (`access-after.tsv`). Seeded rows unchanged.

## 5. Roll back once after the close, then move again

- Rollback from after `close-kourier`: the firewall reopened first; every step undone, the move closed.
- Sites redeployed from their old configs carry the new-base routes with Knative's TLS opt-out; every old name serves HTTPS with a
  verifying certificate; every old-name grant decision matches before the move (`access-rollback.tsv`); carol's original passkey
  signs in on the old base (`rp ep246.topagentnetwork.net … answered 200`).
- Moved again 2026-11-19 05:17Z. The service account's token is base-independent: a token minted just before the flip and a fresh
  one share signing key `hSt4WMXQ…`, issuer `nagare-shomei` and audience `nagare-access`; the fresh one answers 200 on
  `admin.topagentnetworklabs.com` (tokens live 5 minutes, so the pre-flip one had expired by then). Sign-in outage: old auth host
  first failed 05:35:02Z, new auth host last failed 05:51:54Z, about 17 minutes. After `verify-sites` (05:56Z) no new name failed
  until 07:00Z; one request each on the static and server sites failed during `retire`'s platform stages. Grants on the new names
  match before the move (`access-move2.tsv`). Scheduled `en-db` and `shomei-db` backups (every 15 minutes) and app-database backups succeed after the move.
- Committed 2026-11-19 07:03Z: "the move is closed and the context serves through the tunnel".

## 6. End state

From this workstation: TCP 80, 443, 6443 and 8443 closed; the network's only rule `fw-iap-ssh` from `35.235.240.0/20`; kourier
`ClusterIP`, no svclb pods; no listener on 80/443 (`evidence/endstate-post-move.txt`).

## 7. Afterwards

- `inventory rebuild-decisions`: nothing to rebuild, no reference to the old base.
- `context move retire`: revoked and retired the old names' grants, retired and collected the sites' old routes, dropped the
  admin API's old route through a platform review, then refused: "the parent zone still delegates ep246.topagentnetwork.net;
  remove its NS records there first".
- Upgrade to v0.22.0: refused at planning, "observation Kubernetes bytes differ from typed declaration" — the defect fixed in
  `14f7fc72` (a public tunnel Service's flattened claim when read from stored bytes). The upgrade proof needs a packaged build that
  holds the fix. **Open.**

## 8. Teardown

**Open**, pending the operator: the `ep246` NS record in `tan-ng-prod`, then the drill's teardown, the Tailscale key and the request
loop.

## Findings (fixed on the branch, each with a test)

Profile round trip of the retained name and actors; packaged template members from accepted bytes; dependency-only changes of
Kubernetes and cloud members are not rewritten; every dropped route carried, the portal registration not; kubeconfig edge once;
k3s ServiceLB's finalizer; the connector declared while its scope is accepted; a carried route without origin TLS, DomainMapping
updated in place with Knative's finalizer accepted; carrying only the other base's routes, also after a rollback; a later move
keeps routes already on its base; default host shape from the posture, not the zone; `site deploy --retain-resource`; a public
tunnel Service's claim from stored bytes; the commit's retirement drops ordering edges (stamp and cloud), and a stamp that only
lost edges verifies no producers; unchanged Helm releases planned from accepted contracts; the marker checked only when written;
`context move retire` for both directions with decisions, deletion policy and collection, the admin API's route through a platform
review; a retention never taken for settled; the model's collection binding and Kubernetes discovery.

## Findings after the run

- After a move's commit, `inventory status` refused ("reviewed foundation target digest differs") until the next platform review:
  the commit writes the profile, which changes the Pulumi stack's seed, without re-declaring the foundation. Fixed after the run in
  `ca952b50`: status reads the stack against the context's current seed and reports a stale one as drift.
- Deferred with the operator's approval (2026-11-19) in [the findings ledger](mp23-findings.md): F158 (no reviewed removal of a
  Cloudflare zone's tunnel, records or connector), F159 (`context move retire` plans a finished phase again in the run that
  completes it), F160 (platform reviews drop the portal sync's rollout annotations) and F161 (no manual backup for the platform
  databases).
- The admin API's old route on `ep246d` stays retained as `Retain`: it was accepted before the route was made deletable.
