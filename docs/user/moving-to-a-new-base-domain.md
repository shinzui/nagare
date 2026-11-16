---
type: Guide
title: "Moving a context to a new base domain"
description: "Move a direct-ingress Nagare context to a new base domain on a Cloudflare zone, served through one tunnel, carrying its sites, grants and sign-in, and roll it back while it is open."
docId: DOC-44
tags: [cloudflare, tunnel, domains, move, access]
generated:
  by: human:nadeem
  at: 2026-11-16T00:00:00Z
---

# Moving a context to a new base domain

> 🔴 **Built and proven on the interpreter and against a real Shomei, not yet on a native run.** Rehearse it on a disposable
> context first.

`nagarectl context move start --base-domain NEW` moves a direct context from its base domain to `NEW`, a Cloudflare zone that is
already active, and ends where a new tunnel context starts: every site answers on its new name through `cloudflared`, no inbound web
port, `fw-iap-ssh` as the only firewall rule. Everyone who could open a site still can, nobody else can, and no data changes.

The old domain's name servers never change, so there is no name server wait and no two-day TTL. In exchange there is **one cutover
with a sign-in outage**: from the flip until the sites are verified, the old names stop and the new ones come up one by one. Tell your
users the date and the URL list first.

Read [What you accept](cloudflare-tunnel.md#what-you-accept) first. It applies here too.

## Before you begin

- **The new domain is a zone on the same Cloudflare account,** active, with `CF_ACCOUNT_ID`, `CF_ZONE_ID` and `CF_API_TOKEN` for it in
  your shell. The token needs Cloudflare Tunnel Edit, DNS Edit, Zone Settings Edit and Cache Rules Edit on that zone. The zone holds no
  record, tunnel or rule from anyone else.
- **No foreign DS record** at the new domain's registrar. Cloudflare's own, published with DNSSEC on, is fine.
- **No deploys while the move is open,** except the redeploys it asks for.
- **Recent backups** of `en-db`, `shomei-db` and every app database.
- `dig`, `curl`, `kubectl`, `sops` and `gcloud` on `PATH`.

## See what changes

```bash
nagarectl context move list --base-domain topagentnetworklabs.com --out ./move
```

It mutates nothing. It prints every URL that changes and writes `move-manifest.json`:

| Before | After |
|---|---|
| the apex `<old>` | `<new>` |
| `auth.<old>`, `admin.<old>`, `hooks.<old>` and any `x.<old>` | the same label under `<new>` |
| a default name `<name>.<namespace>.<old>` | `<name>-<namespace>.<new>` |
| a preview `<preview>.<site>.preview.<old>` | `<preview>-<site>-preview.<new>` |

With each protected host it lists its direct and team grants. It also lists every Shomei OAuth client with a redirect URI on the old
base, which you update at Shomei, and every account holding a passkey, which stops working (below). Change the GitHub webhooks that
post to `https://hooks.<old>` to `https://hooks.<new>`.

It refuses, naming the host, a name outside the old base, a custom domain two labels below the base (give it a one-label name first),
two names that would become one, and a name that would spell a platform host. It also refuses when a protected host's grants in En
differ from the reviewed ones: settle them with `nagarectl access grant` or `revoke` first, because the move carries only what the
ledger declares.

## Run the move

```bash
nagarectl context move start --base-domain topagentnetworklabs.com
nagarectl context move apply --yes
```

`apply` runs steps until one needs you, says what to do, and stops. Run it again when you have done that. A step that changes the
context saves a review under `${XDG_STATE_HOME:-~/.local/state}/nagare/<context>/moves/`; read it, then run `apply --yes` again to apply
it.

| Step | What happens | What you do |
|---|---|---|
| `check-preconditions` | The zone is the new base, active, with no foreign DS record | Fix what it names |
| `create-zone` | Reviews the tunnel and the proxied apex and wildcard records on the new zone | Read and apply |
| `enable-dnssec` | Waits for DNSSEC on the new zone | Turn it on in Cloudflare; publish the DS record it prints |
| `start-connector` | Reviews the connector beside direct ingress | Run `nagarectl tunnel token` first if it asks |
| `flip-base` | Writes `NAGARE_BASE_DOMAIN`, `NAGARE_INGRESS`, `NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED` and `NAGARE_RETAINED_DNS_NAME` together, then reviews the platform on the new base. **The outage starts.** | Reload your shell (`direnv reload`) when it asks, then read and apply |
| `remove-passkeys` | Exports every passkey to `move-passkeys.sops.yaml` in the context's secrets directory, then removes exactly those | Nothing; commit the export with your other secrets |
| `carry-sites` | Waits until every site answers on its new name and Shomei and the enforcer run on the portal's new host, then reviews the same grants on the new names | Redeploy each site from its updated config, the auth portal first, then the apex: `nagarectl deploy -f site.yaml`. Then run `nagarectl access portal sync --save-plan DIR` and `nagarectl inventory apply DIR --yes` when it asks |
| `verify-sites` | Every listed subject gets in on each new protected name, an unlisted one does not, every new name answers through the edge. **The outage ends.** | Take fresh `en-db` and `shomei-db` backups: one from before the move lacks the new grants |
| `close-firewall` | Reviews the three web rules disabled in place | Read and apply |
| `close-kourier` | Reviews `kourier` as `ClusterIP` | Read and apply |
| `commit-move` | Reviews deleting the three rules | Read and apply each |

`nagarectl context move status` shows the step in progress, and during `carry-sites` the sites not yet redeployed and the grants left
to declare.

**Configs carry hostnames.** Update each site's `domain` and any environment value that names the old base (a portal's public origin,
say) before you redeploy it. A redeploy keeps each old protected route beside the new one while its grants exist, so nothing loses its
binding; the old grants and routes stay until you retire them.

**Passkeys.** A browser refuses a passkey on another domain, and Shomei asks a passkey holder for one at every sign-in, so the move
removes them. Their holders sign in with their password and register a new passkey. Nagare does not enable Shomei's TOTP, so no
account has a second factor left to ask for.
Everyone signs in once on the new auth host, because browsers do not send the old cookie to the new domain.

## Roll back

```bash
nagarectl context move rollback --yes
```

Until `commit-move` completes: rollback reopens the firewall and `kourier` first, restores the passkey table to the export exactly
(passkeys registered after the flip are removed), writes the old profile back and stops for your shell to reload, then reviews the
platform on the old base. Redeploy each site from its old config, the auth portal first, and run the portal sync above again. The old grants were never touched. The new zone and the connector
stay, unused, so a later move finds them in place.

## Retire the old base

When everyone is on the new domain:

```bash
nagarectl context move retire --yes
```

Run it again after each phase. It revokes the grants on the old names, retires them, drops the old routes, and then, once the old base's
parent zone no longer delegates it, retires the old Cloud DNS zone, clears `NAGARE_RETAINED_DNS_NAME` and deletes the passkey export.
Remove the parent's NS records for the old base first, whoever owns that zone: a delegation naming a deleted zone is open to takeover.
This is the only step that cannot be undone.

When something stops the move, see the [move runbook](../runbooks/context-move.md).
