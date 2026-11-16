---
id: 243
slug: close-a-context-s-inbound-ports-and-move-existing-contexts-onto-the-tunnel
title: "Close a context's inbound ports and move existing contexts onto the tunnel"
kind: exec-plan
created_at: 2026-11-02T03:17:42Z
master_plan: "docs/masterplans/32-serve-a-nagare-context-through-an-optional-cloudflare-tunnel-with-no-inbound-web-ports.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-02T03:17:42Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-02T20:19:20Z
      mode: "update"
      note: "Security review of MasterPlan 32: deliverables added for the connector bound, cache and edge policy, credential handling, hostnames and grants on a move"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-04T17:52:52Z
      mode: "update"
      note: "Move command, step list, host map and retained dnsName decided for EP-246"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:04:32Z
      verdict: "comments"
      note: "D1, D7 and D9 evidenced; D8 (operator paths and the Tailscale relay measurement) does not depend on the move and can run on a new context now"
---

# Close a context's inbound ports and move existing contexts onto the tunnel

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

A new tunnel-mode context is provisioned with no internet-facing firewall rule. An operator with a running direct context
can move it to the tunnel with a reviewed, reversible command. In both cases, a port check from the internet finds nothing
open on the VM.


## Progress

- [x] D1 (`resourceProgramParity.test.ts` tunnel variant, native on `ep243`: `fw-iap-ssh` is the network's only rule, no Cloud DNS, `kourier` is `ClusterIP`): In tunnel mode, Pulumi declares no `fw-web`, `fw-lb-health` or `fw-tailscale`, keeps `fw-iap-ssh`, and on a new
  context declares no Cloud DNS zone, wildcard or apex record. A `direct` context's preview is unchanged. `npm test` in
  `infra/pulumi` passes with new variants in `test/resourceProgramParity.test.ts`. In tunnel mode the `kourier`
  Service is `ClusterIP`, so ServiceLB binds no host port and a rule added by mistake reaches nothing.
- [ ] D2 (retention mechanism `0646b22e`: Pulumi and catalog parity tests keep the zone, both records and the solver's grants when
  `NAGARE_RETAINED_DNS_NAME` is set; the reviewed retirement is milestone 6): On a converted context, the existing Cloud DNS zone is retained until the operator retires it through a reviewed
  step. Nothing deletes it automatically.
- [ ] D3: A move runs in a fixed order and refuses to advance otherwise: refuse while the parent zone publishes a DS
  record for the domain, add the zone on Cloudflare with its records DNS-only and pointing at the VM, wait for the
  operator's name server change to activate it, turn DNSSEC on at Cloudflare and hand the operator its DS record,
  confirm direct ingress still works, start the connector, switch records to the tunnel, verify, wait out the old
  TTL, close the firewall, and only then make the `kourier` Service `ClusterIP`. Interpreter tests stop it at each
  step and prove that resume and rollback both end in a serving state. Between the record switch and the firewall
  step both paths are open; nothing in that window trusts a forwarded address.
- [ ] D4: The window where Cloud DNS is no longer authoritative but origin certificates are still in use is bounded. A move
  refuses to start if a certificate is close to renewal, and the behaviour for a hostname added during the window is defined
  and tested.
- [ ] D5: Rollback reopens the firewall before moving records back, and on a disposable context a site stays reachable
  throughout, sampled by a continuous request loop.
- [ ] D6: On a disposable context, a full move has no failed request in the same loop. A port check from outside the project
  and the tailnet then finds TCP 80 and 443 closed, `gcloud compute firewall-rules list` for the context's network shows
  exactly `fw-iap-ssh` from `35.235.240.0/20` and no other rule, and `ss -ltn` on the host shows no listener on 80 or 443.
- [x] D7 (native on `ep243`, bootstrapped by review with no move: TCP 80, 443, 6443 and 8443 closed from outside, `fw-iap-ssh` from `35.235.240.0/20` the only rule, no listener on 80 or 443): A new context reaches the same end state with no move.
- [ ] D8: Operator paths still work with no inbound web ports: `nagarectl` over the tailnet, `just host-switch`, IAP SSH,
  backups, and signed `nagared` webhooks through the edge. Tailscale's move to relays is measured on a `kubectl` round trip and
  reported to the operator.
- [x] D9 (native: `ep243` moved from a 0.15.0 build through published v0.16.0 with 220 requests and no failure, connectors and doctor intact; the v0.16.0 rehearsal read its seeded row back): The upgrade path holds: a tunnel-mode disposable context upgrades through a release and still serves, and the EP-172
  rehearsal for `direct` contexts still reads its seeded data back unchanged.
- [ ] D10: `docs/user` and `docs/runbooks` describe the move and rollback. ADR 20 records the final state.
- [ ] D11: The move carries hostnames. It first lists every URL that changes (default hostnames, OIDC redirect URIs,
  webhook hooks) and asks once whether to flatten or to keep two-label names with Advanced Certificate Manager. When
  flattening, the same reviewed move re-declares every default route, its protected route and its ADR 29 grants for
  `<name>-<namespace>.<base>`, retires the old routes, and `access check` passes for every previously granted subject
  on each new name. Interpreter tests cover a grant that fails to re-declare: the old route stays until it succeeds.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The move is one engine of named steps over existing machinery. Every provider effect is an ordinary reviewed
  inventory transaction run by the existing admission, journal, `inventory resume` and `inventory close`; the engine only
  sequences them. Its state is a marker in the inventory head, like the release transition's `TransitionMarker`, holding the
  move's kind, direction and step cursor, and admission refuses any review that is not the move's current step while it is
  open. The step list and its inverse are pure data run against an injected operations record, as
  `Nagare.Platform.Cutover` does, so interpreter tests stop it at every step, resume it and roll it back. A step either
  advances, waits for something outside Nagare (the operator's name server change, an old TTL), or refuses; a wait stops
  `move apply` with the instruction and the next run re-observes. Rollback runs the inverses of the completed steps in
  reverse order, which by the order of D3 reopens the firewall before records move back.
  Rationale: the inventory has one active transaction at a time and no record that ties several reviews together
  (`headActiveTransaction`, the release-only `headTransition`); a second executor for provider effects would duplicate the
  riskiest code. Exploration of 2026-11-15: bootstrap plans its next stage statelessly (`planNextStage`), the release
  transition is a head marker enforced by `transitionAdmission`, and `Platform.Cutover` is the only step machine with
  rollback.
  Date: 2026-11-15

- Decision: Tunnel mode becomes stageable. The planner reads the move's step from the marker: the connector runs while
  `kourier` stays a LoadBalancer and the issuer stays; the zone's records are DNS-only A records to the VM until the switch;
  the firewall closes through the reviewed collection used by cloud teardown (policy, retirement, collection of the three
  rules); `kourier` becomes `ClusterIP` last. Without an open move the planner behaves as today.
  Rationale: `tunnelUpstreamInputs` switches the issuer, `kourier` and the domain template at once, and the cloud stage
  refuses an accepted scope whose catalog lost members, so neither admits D3's order as it stands.
  Date: 2026-11-15

- Decision: The command is `nagarectl context move`, and its engine takes a step list and D11's carrier takes a host map, because
  [EP-246](246-move-a-context-to-a-new-base-domain-and-carry-its-routes-grants-and-sign-in.md) adds `--base-domain` to the same move.
  Retention (D2) holds the zone under a retained `dnsName`, not one derived from the current base. That plan's Decision Log
  states the division.
  Rationale: operator, 2026-11-04: reuse this plan's ordering and hostname work rather than duplicating it.
  Date: 2026-11-04

- Decision: The move of an existing context (D2 to D6, D8 to D11) follows v0.16.0 and does not block it.
  Rationale: operator, 2026-11-03. A new context reaches the end state without it (D7).
  Date: 2026-11-03



## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

`infra/pulumi/src/components/NagareNetwork.ts` declares four firewall rules unconditionally:

- `fw-web` opens TCP 80 and 443 to `0.0.0.0/0`.
- `fw-iap-ssh` opens port 22 to Google's IAP range.
- `fw-lb-health` opens 80 and 443 to Google load balancer ranges.
- `fw-tailscale` opens UDP 41641 to `0.0.0.0/0`.

Tailscale falls back to its relays when that UDP port is blocked. The GCP firewall is the control to change. k3s ServiceLB binds
Kourier to host ports 80 and 443, and that traffic probably bypasses the NixOS firewall in
`nixos/hosts/nagare-01/networking.nix`, so removing ports there would not close them.

`infra/pulumi/src/components/NagarePerimeter.ts` creates the Cloud DNS zone and the `nagare-wildcard` and `nagare-apex` records from
`resolveDomainTopology` in `infra/pulumi/src/domainTopology.ts`. `infra/pulumi/resource-catalog.json` lists each cloud resource, and
`cli/nagarectl/app/Nagare/Cli/Inventory/CloudCatalog.hs` reads it. The VM keeps its public IP for outbound traffic.

`nagared` verifies an HMAC-SHA256 signature on every GitHub delivery and checks no source address
(`cli/nagarectl/src/Nagare/Static/Webhook.hs`), so it works unchanged through the edge. Shomei and the gateway key on
the socket peer, which behind Kourier is already a proxy address, and Kourier keeps `trusted-hops-count: "0"`; this
plan does not change either. Flattening (EP-242) renames every default hostname, and ADR 29 grants are per hostname,
which is why D11 exists. A DS record left at the registrar makes the zone fail validation after the name server
change, which is why D3 refuses while one exists.

A Cloudflare full zone goes active only after the registrar's name servers change, so proxied routes cannot be tested at the edge
beforehand. That is why a move first mirrors the zone with DNS-only records: traffic keeps flowing directly while DNS moves. The name
server change is the operator's manual step at the registrar. Once it happens, cert-manager's Cloud DNS solver can no longer renew, which
is the window D4 bounds.

Relevant decisions:

- [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) pins cloud writes to the active project.
- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) says the wildcard targets the VM, which this plan changes for
  tunnel mode.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) means native runs only confirm.


## Plan of Work

Milestones, each landed with its interpreter tests before the next:

1. Retention (D2): `NAGARE_RETAINED_DNS_NAME` keeps the Cloud DNS set in the Pulumi program and the cloud catalog. Landed in
   `0646b22e`; its reviewed retirement belongs to milestone 6.
2. The engine (D3, D5): the step list, inverses, waits and refusals as pure data over an operations record, with tests that stop at
   every step and prove resume and rollback both end serving. Landed with `Nagare.Context.Move` and its interpreter tests
   (`Nagare.Test.ContextMove`): a modelled world of name servers, mirror, records, DNSSEC and DS, connector, carried names, firewall,
   `kourier` and resolver caches is checked after every effect; a stop after any step's effect resumes to the end and rolls back to
   direct ingress, a rollback stopped after any inverse resumes, a DS registered after DNSSEC holds rollback until removed, and a
   list without the TTL wait stops at the firewall.
3. The marker and the commands: the head marker, admission while a move is open, and `context move` plan, apply, status and
   rollback. The marker, its store operations and admission landed with `Nagare.Context.MoveStore` and
   `Nagare.Test.ContextMoveStore`: a move opens only on an idle head and beside no release transition, reopens as itself, saves
   progress only while the head is idle, closes only when finished or fully rolled back, and admits only its step in progress; a
   head holding both a move and a transition refuses to decode, and an older CLI refuses the field. The commands come with
   milestone 4, whose steps they run.
4. Stageable tunnel mode: the planner phases of the second 2026-11-15 decision, each a reviewed stage.
5. The window and the hostnames (D4, D11): the renewal refusal, a hostname added during the window, and the carrier with its host map.
6. Retirement, docs and the native run (D2's retirement, D6, D8, D10).

Add the Pulumi variants first, proven in parity tests. Build the move and rollback on the interpreter, then prove them on a disposable
context with a continuous request loop. Prove a new context, the operator paths and the upgrade path there too.


Bounded sequence for D7, the first native run of a new tunnel context (2026-11-03). Disposable context `ep243` in `tan-nb-exp`, base domain `topagentnetworklabs.com`, from the packaged build of
the landed revision, in its own XDG root with its names overridden as in EP-240. Each step stops the run at the result named, and any guard refusal stops it too.

1. Preflight, no mutation: gate record green, no `ep243` resource exists, the zone holds no tunnel, record or cache rule. Stop if anything exists.
2. `context create --ingress cloudflare-tunnel`, then stages through the perimeter. Stop if the review or Pulumi preview holds an update, replace or delete, or declares a firewall rule other than `fw-iap-ssh` or any Cloud DNS member.
3. Image, VM, host. Stop if `nagare-01`, a `cell-*` VM or another image changes. Sign exactly the new node's key if Tailnet Lock locks it out.
4. The zone stage. Stop if a member is planned outside this zone or the base domain is refused.
5. `nagarectl tunnel token`, then platform stages until a review has no operations. Stop if the token reaches a log or plan, or an apply stays ambiguous.
6. Observe: a protected site on its flattened default name through a real browser login without the form workaround; `nagarectl tunnel status` and `doctor` green; anonymous fetch of a protected `.pdf` and `.js` gets `302` and never `HIT`; a browser-like request gets no analytics beacon; from outside, TCP 80 and 443 closed; `firewall-rules list` shows only `fw-iap-ssh`; `ss -ltn` on the host shows no 80 or 443.
7. Teardown as EP-240 did it, recording F137, and check the same list of leftovers. The zone and its edge settings stay.

## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. Land with `just land`. The outside port check must run from a
machine that is neither on the tailnet nor in the project:

```bash
nc -z -w 5 "$PUBLIC_IP" 80; nc -z -w 5 "$PUBLIC_IP" 443
```

Both must fail. UDP cannot be proven this way, so the firewall listing in D6 is the evidence for 41641. On the host:

```bash
ss -ltn '( sport = :80 or sport = :443 )'
```

must list no socket. Cloud mutation needs the
operator's go-ahead, once for a bounded sequence, after [Before a native run](../runbooks/before-a-native-run.md).


## Idempotence and Recovery

A move resumes from its journal. Until the firewall step, direct ingress still works. Rollback reopens the firewall first, then restores
records, so no state exists where neither path works. No application data moves. If the tunnel fails after a move, rollback is the recovery,
and it needs only Pulumi state, the Cloudflare token and the operator's IAP or tailnet access. Returning a context fully to Cloud DNS means
reversing the registrar change, and DNS-01 renewal resumes after that.


## Interfaces and Dependencies

Requires EP-241 and EP-242 complete. Consumes `NAGARE_INGRESS`, the connector health probe and `nagarectl domains check`. The exact command
names are this plan's choice. Add no `just` recipe unless the operator asks for one.
EP-246 consumes the move engine, D2's retention, D5's rollback rule and D11's carrier.
