---
id: 241
slug: run-a-reviewed-cloudflare-tunnel-connector-beside-direct-ingress
title: "Run a reviewed Cloudflare Tunnel connector beside direct ingress"
kind: exec-plan
created_at: 2026-11-02T03:17:41Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-02T03:17:41Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-02T20:19:20Z
      mode: "update"
      note: "Security review of MasterPlan 32: deliverables added for the connector bound, cache and edge policy, credential handling, hostnames and grants on a move"
---

# Run a reviewed Cloudflare Tunnel connector beside direct ingress

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

An operator sets `NAGARE_INGRESS=cloudflare-tunnel` on a context, reviews a plan, and gets a running tunnel
connector. `nagarectl platform status` shows whether it is connected. A context without the setting sees no
change at all.


## Progress

- [ ] D1: `NAGARE_INGRESS` parses to `direct` (the default) or `cloudflare-tunnel`, is refused in local mode
  and on any other value, and is exported by `.envrc`, `context env` and the Pulumi projection. Tests pass, and
  `CLAUDE.md` lists it among the canonical variables.
- [ ] D2: A `direct` context's Pulumi preview and inventory plan are unchanged, proven by the existing parity
  tests and `just release-rehearse`.
- [ ] D3: The tunnel and its ingress configuration are typed inventory resources. Fake-adapter tests cover
  create, a lost acknowledgement on create and on configuration, a drifted configuration and an expired token,
  and each ends in a reviewed outcome.
- [ ] D4: The connector runs in its own namespace from an image pinned by digest and pulled from the context's
  Artifact Registry, with bounded resources and no `latest` tag, as non-root with a read-only root filesystem,
  no capabilities, `automountServiceAccountToken: false` and no host network. Its readiness probe reads
  `cloudflared`'s own `/ready` endpoint, which no Service exposes. Pods restart without losing the route.
- [ ] D5: The tunnel token lives only in the operator's sops-encrypted `cluster-secrets/<context>/` material and
  one Kubernetes Secret in the connector's namespace. It is not a context variable, and a test proves it never
  appears in `context env`, a plan, a journal or a log. `CF_API_TOKEN` is never written into the cluster.
- [ ] D6: `nagarectl platform status` and `nagarectl doctor` report connector health in tunnel mode, and
  `gradeKourier` neither fails nor warns on a closed public IP in that mode. The probe also lists the connectors
  Cloudflare sees: their count and origin addresses must match the context's replicas and the VM, and any other
  connector, or a remote configuration that differs from the declared one, is a failing check.
- [ ] D7: On a disposable context, a rebuilt node rejoins the same tunnel with no new Cloudflare resource.
- [ ] D8: A NetworkPolicy in the connector's namespace allows egress only to the external `kourier` Service in
  `kourier-system`, cluster DNS, and port 7844 TCP and UDP, and allows no ingress. The declared ingress rules name
  `<base>` and `*.<base>` and end in a 404 catch-all. On the disposable context of D7, an ingress rule repointed
  from Cloudflare at the API server, `kourier-internal`, En, the object store and `169.254.169.254` fails to
  connect, and is then restored.
- [ ] D9: `nagarectl` rotates the tunnel secret: a new secret through the API, the Secret updated, the Deployment
  rolled, existing connections removed (EP-240 observed that rotation alone leaves a running connector serving), and
  the old token refused by Cloudflare, with no failed request in a continuous loop. `docs/user`
  names when to rotate: a suspected leak, an operator leaving, or a node rebuilt from untrusted material.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Web traffic today enters at Service `kourier` in `kourier-system`. A tunnel adds a second path to that gateway: a
`cloudflared` Deployment connects outbound to Cloudflare on port 7844 and forwards requests to Kourier. Its
origin is the external Service `kourier`, never `kourier-internal`, which serves cluster-local routes.

The tunnel's ingress configuration is managed from Cloudflare, so whoever holds the API token or the account can
repoint it at anything the connector pod can reach. The NetworkPolicy in D8 is the only control over that, as it
is for the admin API (ADR 29 amendment). The tunnel token is an interception credential: a connector started
anywhere with it receives a share of every request, session cookies included; D5, D6 and D9 follow from that.

Kourier's `config-kourier` keeps `trusted-hops-count: "0"` and `use-remote-address: "false"`, and Shomei keys
login attempts and throttling on the socket peer, which behind Kourier is already a proxy address. Do not raise
the trusted hops: while a move leaves both paths open, a direct client could forge `X-Forwarded-For`. Anything
new that records a visitor address in tunnel mode reads `CF-Connecting-IP`, and only once the perimeter is closed. Read the
accepted result of `docs/plans/240-prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports.md`
and its ADR first, since they fix the origin settings.

Key files:

- `cli/nagarectl/src/Nagare/Target.hs` holds the context fields, `NAGARE_MODE` being the model to copy.
- `cli/nagarectl/app/Nagare/Cli/Runtime/Context.hs` exports them.
- `cli/nagarectl/src/Nagare/Inventory/Adapters/Cloudflare.hs` is the reviewed Cloudflare owner, with
  `CloudflareTarget`. `CloudflareRuntime.hs` is the live transport, which verifies the zone and account binding on
  every read and leaves an uncertain mutation unresolved.
- `cli/nagarectl/src/Nagare/Ops/Probe.hs` holds `gradeKourier`, which curls the public IP.
- `cli/nagarectl/src/Nagare/Ops/Doctor.hs` also reads the public IP.

Relevant decisions:

- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): declare resources before
  mutating them.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): find defects with fake
  adapters first.
- [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md): the token
  is operator material.
- [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md): a
  rebuild must restore the connector.
- [ADR 23](../adr/0023-observability-resource-bounds-cover-chart-and-operator-created-containers.md): containers
  have explicit resource bounds.

Nagare images live in GCP Artifact Registry and never on GitHub Packages. The operator's secret flow is in
`docs/user/secrets.md`. Cloudflare's Kubernetes guide uses a remotely managed token, two replicas and no
autoscaling. Two replicas on one node tolerate a pod restart and not a node loss.


## Plan of Work

Add the mode and its refusals. Extend the Cloudflare adapter with the tunnel and its configuration, tested against
fakes before any live call. Add the connector as a platform component, then its status probe. Prove it on a
disposable context.


## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. Adapter behaviour is proven in
`cabal test nagarectl-test`. Run `npm test` in `infra/pulumi` if the projection changes. A native run on a disposable
context confirms D7, after [Before a native run](../runbooks/before-a-native-run.md) and with the operator's go-ahead.


## Idempotence and Recovery

Adding the connector changes no route and no DNS, so traffic is unaffected. Removal is a reviewed retirement of the
connector and tunnel. Setting the mode back to `direct` refuses while routes or a closed perimeter depend on the tunnel.


## Interfaces and Dependencies

Requires EP-240 complete, with the design accepted. Other plans read `NAGARE_INGRESS` through the `Target` value. The
Cloudflare binding reuses `CF_ACCOUNT_ID`, `CF_ZONE_ID` and `CF_API_TOKEN`. EP-242 extends `CloudflareTarget` too, so
keep this addition additive.
