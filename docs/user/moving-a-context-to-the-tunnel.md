---
type: Guide
title: "Moving an existing context onto the Cloudflare Tunnel"
description: "Move a direct-ingress Nagare context onto one Cloudflare Tunnel, one reviewed step at a time, and roll it back while it is still open."
docId: DOC-43
tags: [cloudflare, tunnel, ingress, domains, move]
generated:
  by: human:nadeem
  at: 2026-11-16T00:00:00Z
---

# Moving an existing context onto the Cloudflare Tunnel

> 🔴 **Built and proven on the interpreter, not yet on a native run.** Use it on a disposable context first. A new context
> should start in tunnel mode instead: see [Serving a new context through a Cloudflare Tunnel](cloudflare-tunnel.md).

`nagarectl context move` takes a context that serves directly from its VM and ends with the same end state a new tunnel
context has: no inbound web port, `fw-iap-ssh` as the network's only firewall rule, `kourier` as a `ClusterIP` Service,
and every request arriving through `cloudflared`. It never has a moment where neither path serves. Until the firewall
step, direct ingress still works; between the record switch and the firewall step, both do.

Read [What you accept](cloudflare-tunnel.md#what-you-accept) first. It applies here too.

## Before you begin

- **The domain must be added to the same Cloudflare account,** with the three values in your shell:

  ```bash
  export CF_ACCOUNT_ID=...
  export CF_ZONE_ID=...
  export CF_API_TOKEN=...
  ```

  The token needs Cloudflare Tunnel Edit, DNS Edit, Zone Settings Edit and Cache Rules Edit on that zone.
- **No DS record at your registrar.** Cloud DNS's keys would fail validation once Cloudflare answers. Remove it, and wait for its TTL.
- **No certificate renewing in the next 14 days.** DNS-01 renewal needs Cloud DNS, and Cloud DNS stops answering when the
  name servers move. `start` refuses otherwise; wait for the renewal and start then.
- **No deploys while the move is open.** Admission takes only the move's own reviews. Plan the move for a quiet time.
- `dig`, `curl` and `gcloud` on `PATH`, and access to the cluster as for any review.

## What changes for your URLs

The free edge certificate covers the base and one label below it, so default names flatten:

| Before | After |
|---|---|
| `<name>.<namespace>.<base>` | `<name>-<namespace>.<base>` |

`context move start` lists every URL that changes. It refuses to start while any of these exist, because the move cannot
re-declare them yet:

- **a protected site on its default name.** Its enforcer route and its grants are on the old name. Give it a custom domain
  one label below the base, deploy that, and start again.
- **a custom domain two labels below the base.** It needs Cloudflare's Advanced Certificate Manager, or a one-label name.

Public default names move with Knative's domain template; tell your users the new names.

## Run the move

```bash
nagarectl context move start
nagarectl context move apply --yes
```

`apply` runs steps until one needs you, then says what to do and stops. Run the same command again when you have done it.
A step that changes the context plans a review and saves it under
`${XDG_STATE_HOME:-~/.local/state}/nagare/<context>/moves/`; read it in the output, then run `apply --yes` again to apply
it. The step completes when its next plan changes nothing.

| Step | What happens | What you do |
|---|---|---|
| `check-preconditions` | Checks the zone is your base domain, no DS at the parent, no certificate renewing soon | Fix what it names |
| `mirror-zone` | Reviews DNS-only A records in Cloudflare pointing at the VM, TTL 300 | Read and apply |
| `await-name-servers` | Waits until Cloudflare reports the zone active | Set the two name servers it prints at your registrar |
| `enable-dnssec` | Waits until Cloudflare reports DNSSEC active | Turn DNSSEC on in Cloudflare, publish the DS record it prints |
| `confirm-direct` | Checks public DNS sends the base to the VM and the VM answers | Nothing |
| `start-connector` | Reviews the connector | Run `nagarectl tunnel token` first if it asks |
| `carry-hostnames` | Reviews the flattened domain template | Read and apply |
| `switch-records` | Checks the connectors, then reviews the same records as proxied CNAMEs to the tunnel | Read and apply |
| `verify-tunnel` | Checks the base and a wildcard name answer through the edge | Nothing |
| `await-old-ttl` | Waits until the old delegation, a Cloud DNS answer and a mirror answer have all expired | Wait; it prints the time |
| `close-firewall` | Reviews the three web rules disabled in place | Read and apply |
| `close-kourier` | Reviews `kourier` as `ClusterIP` | Read and apply |
| `commit-move` | Reviews deleting the three rules, then writes `NAGARE_INGRESS=cloudflare-tunnel` and `NAGARE_RETAINED_DNS_NAME` | Read and apply each; commit the context file if it lives in your operator repository |

The `await-old-ttl` wait is usually two days: the parent zone's NS records for `.com` live 172800 seconds.

`nagarectl context move status` shows the step in progress and what is left.

## Roll back

Until `commit-move` completes, the move can be undone, newest step first:

```bash
nagarectl context move rollback --yes
```

Rollback reopens the firewall and `kourier` before it moves the records back, and it checks the VM answers before the
switch. It then waits until edge answers cached before the switch back have expired, restores the nested names, waits for
you to remove the DS record at the registrar, and waits for you to point the name servers back at Cloud DNS. The step that
waits names the Cloud DNS servers.

Rollback keeps the Cloudflare zone's records and the connector: the connector keeps running with no record pointing at it,
and the zone stops answering once the name servers are back at Cloud DNS. A later move finds them in place and goes on
from there.

You can roll back a move that is waiting at any step, including one stopped by a refused review. After `commit-move` the
move cannot be rolled back: the web rules are gone. Going back to direct ingress after that is a new context.

## After the move

The Cloud DNS zone stays, with its records and the solver's grants, so nothing breaks if a resolver still holds the old
delegation. When you are sure every resolver asks Cloudflare, retire it:

```bash
nagarectl context move retire-dns --yes
```

It refuses until the parent and three public resolvers name only Cloudflare's servers, then reviews, one run at a time,
the policy revision, the retirement and the deletion of the two records and the zone, and clears
`NAGARE_RETAINED_DNS_NAME`. The two IAM grants are retired but not deleted; remove the project's `roles/dns.reader`
binding for the node's service account yourself if you want it gone.

When something stops the move, see the [move runbook](../runbooks/context-move.md).
