# When a context move stops

[Moving an existing context onto the Cloudflare Tunnel](../user/moving-a-context-to-the-tunnel.md) describes the move. This
runbook covers what to do when `nagarectl context move apply` or `rollback` stops with a refusal instead of a wait.

The open move lives in the inventory head, so a lost shell, a closed laptop or a crashed command loses nothing: run the same
command again and it resumes at the step in progress. `nagarectl context move status` shows that step.

While the move is open the site keeps serving, by the VM until `close-firewall` and by the edge from `switch-records` on.
None of the cases below needs a hand edit of the head, the context file or Pulumi state.

## A saved review did not apply

The move discards the review and says so. Usually something changed between planning and applying, and running the same
command again plans afresh. If `nagarectl inventory status` shows an active transaction, the apply stopped part way:

```bash
nagarectl inventory status
nagarectl inventory resume
```

`resume` is admitted because the transaction carries the move's identity. Then run the move command again.

## `check-preconditions` refuses

- **The zone is not the base domain:** `CF_ZONE_ID` names another zone. Export the base domain's zone ID.
- **The parent publishes a DS record:** remove it at the registrar, wait for its TTL (`dig DS <base>` shows it), run again.
- **A certificate renews within 14 days, or has no renewal time:** wait until cert-manager has renewed it
  (`kubectl get certificates.cert-manager.io -A`), then run again. The move has not opened anything yet.

## `switch-records` refuses because the connectors are not ready

`nagarectl tunnel status` lists them. Two connectors from the VM's address are expected. A connector from any other address
holds a copy of the tunnel token: rotate it with `nagarectl tunnel rotate --yes`, apply the platform review it asks for
(`context move apply --yes` plans it), and evict the stranger with `nagarectl tunnel evict ID --yes`.

## `verify-tunnel` refuses

The records already point at the tunnel, and the VM still serves anything a resolver has cached. Check
`nagarectl tunnel status` and `nagarectl domains check`. If the edge does not answer and the cause is not obvious, roll back:

```bash
nagarectl context move rollback --yes
```

`switch-records`' inverse checks the VM answers, then points the records back at it.

## `close-firewall` refuses

A cached answer may still send a visitor to the VM. The refusal names the time when the last one expires; run again after it.

## Rollback waits at `mirror-zone`

The name servers still point at Cloudflare at the parent, or a public resolver still answers with them. The wait prints the
Cloud DNS name servers to set at the registrar. Removing the mirror records earlier would leave visitors with an empty zone.

## After `commit-move`

The move cannot be rolled back: the three web firewall rules are deleted, and a deleted identity can never be declared again.
A tunnel problem after the commit is a tunnel context's problem, handled as in
[Serving a new context through a Cloudflare Tunnel](../user/cloudflare-tunnel.md): `tunnel status`, `tunnel rotate`, `doctor`.
Going back to direct ingress means a new context.

## A move to a new base domain

[Moving a context to a new base domain](../user/moving-to-a-new-base-domain.md) shares the cases above, and adds these:

- **`apply` refuses because `NAGARE_BASE_DOMAIN` names the other base.** The shell was loaded before the flip wrote the profile, or
  before a rollback restored it. Run `direnv reload` and run again.
- **`remove-passkeys` refuses because the passkey table differs.** The platform's Shomei changed its passkey columns. Roll back, or
  upgrade nagarectl with the platform; nothing was removed.
- **`carry-sites` keeps waiting.** `context move status` names each site without a route on its new name. Update its config's
  hostnames and redeploy it; a deploy is admitted during this step.
- **`verify-sites` refuses.** A listed subject does not get in on a new name, or an unlisted one does. Check the grant reviews
  `carry-sites` applied with `nagarectl access check --host NEW --user ID`; if the cause is not clear, roll back. The old grants were
  never touched.
- **`context move retire` refuses at the zone.** The old base's parent zone still delegates it. Remove those NS records first.

