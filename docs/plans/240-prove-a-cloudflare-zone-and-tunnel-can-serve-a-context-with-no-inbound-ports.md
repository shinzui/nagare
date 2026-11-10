---
id: 240
slug: prove-a-cloudflare-zone-and-tunnel-can-serve-a-context-with-no-inbound-ports
title: "Prove a Cloudflare zone and tunnel can serve a context with no inbound ports"
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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:04:32Z
      verdict: "approved"
      note: "Complete with observations recorded for every item; P6's header-only control is weaker than stated because CDN-Cache-Control headers were not tested (EP-245 D1)"
---

# Prove a Cloudflare zone and tunnel can serve a context with no inbound ports

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

Decide, with evidence from a real Cloudflare account, whether the recommended path works: a base domain
on a full Cloudflare zone, a proxied wildcard record to a tunnel, and a login-protected site behind it.
This is a prototype on a disposable context. No product code lands. The output is a set of pass/fail
answers and a design decision.


## Progress

Each item passes only with a recorded observation.

- [x] P1: A proxied wildcard CNAME to `<id>.cfargotunnel.com`, with a catch-all ingress rule, serves a one-label name with its
  `Host` header intact. Observed: `https://probe-personal.topagentnetworklabs.com/echo` answered 200, `"host":
  "probe-personal.topagentnetworklabs.com"`, `server: cloudflare`, certificate `*.topagentnetworklabs.com` (Let's Encrypt YE1).
- [x] P2: The apex is served through the tunnel by a proxied CNAME with a free certificate. Observed: `https://topagentnetworklabs.com/echo`
  answered 200, `"host": "topagentnetworklabs.com"`, through a DomainMapping on the apex.
- [x] P3: `cloudflared` reaches the external Service `kourier` with `external-domain-tls` off and sites route. Observed: the key is unset in
  `config-network`, the probe and both protected sites route, no Certificate was requested. The hop from the connector to Kourier is plain
  HTTP inside the node, and that is accepted.
- [x] P4: Knative's domain template gives one-label default names served by the free certificate. Observed: with
  `domain-template: {{.Name}}-{{.Namespace}}.{{.Domain}}`, `ksvc.status.url` was `http://probe-personal.topagentnetworklabs.com` and it answered 200
  over HTTPS. A two-label name fails the TLS handshake (`a.b.<base>`, alert handshake failure), so flattening is required on the free certificate.
- [-] P5: Not observed, by decision (see Decision Log). Advanced Certificate Manager was not bought. {disposition=declined}
- [x] P6: Observed on one fresh cache key per case, signed in twice and then anonymous, on both `.pdf` and `.js`:
  neither control, signed-in `MISS` then `HIT`, anonymous `200 HIT` with the file's bytes (the leak);
  header only (`Cache-Control: private, no-store`), `BYPASS`, anonymous `302` to `/_nagare/login`;
  cache rule only, `DYNAMIC`, anonymous `302`; both, `DYNAMIC`, anonymous `302`. With the rule on, the key already cached by the first case also
  answered `302`, so the rule stops a stored copy being served. The header came from the site's header rule through the gateway, because no product
  code lands here; EP-242 moves it into the gateway.
- [x] P7: A real Chrome session signed in through the tunnel with the password form (typed by the operator) and reached the granted site over HTTPS
  (HTTP/3, `200`); `ungranted.<base>` answered `403 Forbidden`; `http://` redirected to `https://`. Set-Cookie: `nagare_session` and `nagare_refresh`
  with `Domain=.<base>; Path=/; HttpOnly; Secure; SameSite=Lax`, and JavaScript sees neither. A request with only the refresh cookie answered 200
  and set new cookies (renewal by curl through the tunnel, not by waiting in the browser). A forged `X-Forwarded-User` from an anonymous client got `302`.
  Edge: `http://` answers 301 to `https://`; TLS 1.0 and 1.1 fail and 1.2 and 1.3 answer 200, with zone `min_tls_version` 1.2. Passing the form needed
  a workaround: see Surprises. The auth portal app was not deployed; login was the gateway's built-in form.
- [x] P8: Time to first byte over 40 requests each, from the operator's workstation: direct to the VM over HTTP, p50 73 ms, p95 84 ms; through the
  tunnel over HTTPS with a new connection each, p50 134 ms, p95 226 ms; through the tunnel excluding TLS setup, p50 85 ms, p95 111 ms. A stream sending a
  chunk every 5 s ran its full 200 s. A stream silent after its first chunk was reset at 126 s (`HTTP/2 stream reset, INTERNAL_ERROR`).
- [x] P9: Observed, target under the policy then from a control pod with no policy: external `kourier` 404/404; `kubernetes.default.svc` 000/401;
  `kourier-internal` 000/404; `169.254.169.254` 000/200; `api.cloudflare.com` 000/301; `example.com` 000/200. Rules repointed through the API at the API
  server, `kourier-internal` and the metadata server each answered `502` through the edge, with `cloudflared` logging `Unable to reach the origin
  service`, while the probe answered 200 in the same configuration. A hostname outside the rules got the catch-all `404`. The original rules were restored
  and verified (tunnel configuration version 3); the policy was never removed, so no public path to the metadata server existed.
- [x] P10: After a `tunnel_secret` PATCH the token fingerprint changed. A pod restarted with the old token logged `Unauthorized: Invalid tunnel secret`
  and never became ready; with the new token it reconnected (4 connections) and sites answered. The listing shows each connector's `origin_ip`,
  `136.87.131.238`, equal to the VM's address. Rotation alone did not evict the running connector: see Surprises.
- [x] Result: pass (see Decision Log). [ADR 34](../adr/0034-a-context-may-serve-through-one-cloudflare-tunnel-on-a-full-zone.md) records the topology and threat model, and
  ADR 20 is amended.
- [x] Every prototype resource is removed from Cloudflare and the disposable context. Observed 2026-11-02: stack `ep240` holds 0 resources after 27 deletes; no `ep240` instance,
  service account, repository, bucket, network, zone, address, disk, snapshot or image remains in `tan-nb-exp`, and `nagare-01`, the `cell-*` VMs and the older images are unchanged.
  Cloudflare holds no tunnel, DNS record or cache ruleset; the zone stays active with its edge settings for the intranet. The Tailscale key is revoked. `nagare-ops`, the run root, the
  builder key copy, the private ADC and the named gcloud configuration are removed. At the last check `ep240-nagare` still listed as an offline ephemeral peer. The scoped Cloudflare API token is kept with the zone.


## Surprises & Discoveries

- 2026-11-02, observed. `scripts/rehearse-gcp-bootstrap.sh --live` no longer matches v0.15.0: a named cloud context gets its
  foundation, image, VM and host through `platform bootstrap plan`, so `init`, `context guard` before the foundation and
  `infra-up` all refuse or are wrong. A `context guard` run before the foundation creates an empty stack that the planner
  then refuses as `unverified-owner`. The sequence below was run stage by stage through the reviewed bootstrap instead.
- 2026-11-02, observed. A new context on the default `NIX_BUILDER_SSH_KEY` cannot plan its host image: the build goes through
  the daemon, but `build_present` in `scripts/upload-images.sh` runs `ssh` as the user, and `/etc/nix/builder_ed25519` is
  root-only. Pre-building does not help, because a present output with no history is also `unverified-owner`. The run used
  an operator-made user-readable copy of the key, deleted at teardown. Needs a finding for the operator's ledger.
- 2026-11-02, observed. The operator's tailnet has Tailnet Lock on and an auth key is not pre-signed, so a new host joins but
  has no connectivity (`this node is locked out`), and the host stage stayed ambiguous through 12 resumes with `host identity
  or closure does not match the reviewed activation`, which does not name the cause. The operator approved signing this one
  node key. Onboarding names neither the key copy nor the signature. Needs a finding for the operator's ledger.

- 2026-11-02, observed. The built-in login form fails in a real browser: after it loads, Chrome requests `/favicon.ico`, the anonymous request redirects to
  `/_nagare/login?rd=%2Ffavicon.ico`, and that response sets a new `__Host-nagare_csrf`, so the form's token no longer matches and the submit answers
  `403 csrf validation failed`. curl never hits this, which is why the site-access drill did not. It is in the gateway, not the tunnel. P7 passed only after the
  form's hidden field was set to the current cookie in the tab before the operator submitted. Needs a finding for the operator's ledger.
- 2026-11-02, observed. Cloudflare injects its analytics beacon (`static.cloudflareinsights.com`, posting to `/cdn-cgi/rum`) into HTML for browser-like requests,
  including the login form and signed-in protected pages; curl's default headers do not trigger it. Zone setting `rum` already read `off`, and the API token cannot
  read Web Analytics site settings (403). `Cache-Control: no-transform` stops it; `private, no-store` does not. `automatic_https_rewrites` and
  `server_side_exclude` are also on and were not in the plan's list. This changes EP-242: the gateway's header needs `no-transform`.
- 2026-11-02, observed. Rotating the tunnel secret does not evict a running connector: the old one kept its 4 connections and kept serving until restarted. So
  rotation alone does not remove a connector started with a stolen token. EP-241 must pair it with connection cleanup; that pairing was not tested here.
- 2026-11-02, observed. `cloudflared`'s precheck reports `Cloudflare API: API is reachable` under a policy that blocks that address (P9: 000), so it is not evidence of
  reachability. A pod with no policy reaches the node's metadata server (P9 control: 200), as expected, which is why the connector's policy matters.

## Decision Log

- Decision: Run in `tan-nb-exp` from a one-run set of step scripts in the session scratchpad, following
  `scripts/rehearse-gcp-bootstrap.sh --live` without its refusal of that project, its Let's Encrypt stages or its typed
  confirmations. The tracked script is unchanged.
  Rationale: operator, 2026-11-02, after being shown that line 470 refuses `tan-nb-exp` and that EP-139 requires a
  purpose-created project. `docs/guides/running-multiple-clusters.md` also calls two stacks in one project unsupported,
  so every project-scoped name is overridden (instance, service account, registry, both buckets) and the perimeter
  review is read before apply. `gcp.projects.Service` sets `disableOnDestroy: false`, so teardown turns no API off.
  Date: 2026-11-02

- Decision: The context runs from its own XDG root at `~/.local/state/nagare/ep240/run`, with its context, host,
  cluster-secret and Pulumi files in `nagare-ops` and symlinked into that root, not into `~/.config/nagare`.
  Rationale: `nagarectl init` makes its context current, and the operator's pointer names `intranet`, which other
  sessions rely on. Its ADC is a private copy with quota project `tan-nb-exp`, for the same reason.
  Date: 2026-11-02

- Decision: EP-240 passes. A full Cloudflare zone, a proxied wildcard and apex to one remotely managed tunnel, and a connector bounded by a NetworkPolicy serve a
  login-protected site with one-label names on the free certificate, for $0. The firewall stayed open during this run; EP-243 proves the closed perimeter.
  Rationale: P1 to P4 and P6 to P10 observed above. The browser form defect and the beacon do not change the topology; both are carried as findings and into EP-242.
  Date: 2026-11-02

- Decision: Remove the stack with raw Pulumi against its local state, after the legacy path refused it for having inventory history and the reviewed path refused it with `dangling-reference`.
  Rationale: operator, 2026-11-02, after both refusals were shown; the reviewed path also retains disks, buckets, IAM and the stack by design. The destroy preview was checked to hold only deletes of this stack's own URNs. Recorded as F137.
  Date: 2026-11-02

- Decision: Sign the one node key `ep240-nagare` with this workstation's Tailnet Lock key, after comparing the listed key with the one the VM reported.
  Rationale: operator, 2026-11-02; the auth key was not pre-signed and the node had no connectivity.
  Date: 2026-11-02

- Decision: The findings from this run that risk no data loss go to the deferral ledger as F135 to F138.
  Rationale: operator, 2026-11-02.
  Date: 2026-11-02

- Decision: P5 is not observed. Advanced Certificate Manager is not bought.
  Rationale: operator, 2026-11-02; the intranet will use the zone itself as its base, so a subdomain base has no customer.
  Date: 2026-11-02


## Outcomes & Retrospective

The recommended topology works: a full Cloudflare zone, proxied apex and wildcard records to one tunnel, and a connector bounded by a NetworkPolicy serve a login-protected site on one-label names
for $0, and the leak the security review predicted was observed and closed by each of its two controls. Not proved here: a closed perimeter (EP-243), a browser renewal by waiting out a session,
and the built-in form without a workaround (F135). The topology and threat model moved to ADR 34. Most of this run's cost came from the stale driver, the builder key and Tailnet Lock, carried as F136 and F138.


## Context and Orientation

[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md) compares
the options and lists Cloudflare's documented limits. A **full setup** means the domain's name servers point
at Cloudflare; it is the only setup on Free and Pro. A **proxied** record is served through Cloudflare's edge.
The **connector** is the `cloudflared` process.

What the documentation leaves open, and this plan tests:

- It says wildcard records are multi-level by default and that several records may point at one tunnel, but
  shows no wildcard pointing at a tunnel (P1).
- A wildcard certificate covers one level, so Nagare's default `<name>.<namespace>.<base>` is not covered.
  Flattening to one label avoids a paid add-on (P4).
- It does not say whether a request's Cookie affects default caching. By default Cloudflare caches by file
  extension, including `.js`, `.css` and `.pdf`, unless the response has `Set-Cookie` or `Cache-Control:
  private`, `no-store`, `no-cache` or `max-age=0` (P6).

Nagare facts:

- `cluster/bootstrap/knative-serving/config-network-tls.yaml` enables `external-domain-tls`, and
  `cluster/bootstrap/net-certmanager/README.md` describes the state with it off.
- `cluster/bootstrap/knative-serving/config-network.yaml` sets no `domain-template` today.
- `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` issues through Cloud DNS, which would no longer be
  authoritative for a domain on Cloudflare. Keeping a Cloudflare DNS-01 token in the cluster is the rejected
  default, because it gives the cluster power over the whole zone.
- Service `kourier` in namespace `kourier-system` is the external gateway; `kourier-internal` serves
  cluster-local routes and must never be the connector's origin. Kourier's `config-kourier` keeps
  `trusted-hops-count: "0"` and `use-remote-address: "false"`.
- Knative's default `http-protocol: Enabled` serves plain HTTP
  (`cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesReadiness.hs`), and nothing in the repository
  sends HSTS. The gateway hard-codes `Secure` cookies and `https://` portal URLs
  (`cli/nagare-access/src/Nagare/Access/Cookie.hs`, `Portal.hs`) and sets `Cache-Control: no-store` only on
  its own responses, not on the responses it proxies.
- Cloudflare's zone defaults are minimum TLS 1.0 and no HTTP to HTTPS redirect.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) records per-hostname access.


## Plan of Work

The operator supplies a Cloudflare account, a disposable registered domain on a full setup, and an API token,
and approves this as one bounded cloud sequence. The target is a disposable cloud context, never a context in
real use. Complete [Before a native run](../runbooks/before-a-native-run.md) first.

Create a remotely managed tunnel through the API, run the connector as a throwaway Deployment with one
catch-all rule to Kourier, create the records, then work through P1 to P10. Keep scratch files in the session
scratchpad. Nothing is committed except this plan and the ADR.

Prototype inputs, 2026-11-02: the disposable zone is `topagentnetworklabs.com`, registered through Cloudflare
Registrar, so it is on a full setup from the start. Account `d605625d4375aa3120a1374daf2f9a87`, zone
`a0bc2ff68ebe0ae99b7f9864a2219722`. The API token and the Tailscale test key are operator material, held as
files outside this repository and never recorded here.

Cloudflare side done on 2026-11-02 with the `cf` CLI (`nix run github:NixOS/nixpkgs/nixpkgs-unstable#cf`, 1.0.0-beta.21),
each step dry-run first: remotely managed tunnel `nagare-ep240` (`b855f1f5-a95c-4af1-af30-f707e1d3d6cd`) with ingress
rules for the apex and `*.<base>` to `http://kourier.kourier-system.svc.cluster.local:80` and a 404 catch-all; proxied
CNAMEs for `*` and the apex to the tunnel; zone settings Always Use HTTPS on, minimum TLS 1.2, SSL strict, email
obfuscation and Rocket Loader off (the zone's defaults were off, 1.0, full and on). Tunnel creation needed no Zero
Trust onboarding step. The cache bypass rule is deliberately not created yet, so P6 can first observe the leak. The
cluster side waits for the disposable context.

Bounded sequence for the cluster side, approved by the operator on 2026-11-02. Each step stops the run at the result
named, and any guard refusal or unexpected result stops it too.

1. Preflight, no mutation: gate record green, packaged `nagarectl` at v0.15.0's revision, a real API call to the project,
   and `ep240-01`, `ep240-node`, repository `ep240` and both `tan-nb-exp-ep240-*` buckets absent. Stop if any exists.
2. Operator material: fresh age identity, sops-encrypted host secrets, `context create`, `init --skip-enable`, `host init`,
   `context guard`. Stop if the guard names anything but `tan-nb-exp` and stack `ep240`, or the operator's current-context
   pointer changes.
3. Perimeter: saved preview, then apply. Stop if the review holds any update, replace or delete, or a create named outside
   this context's overrides.
4. Image: start `nix-builder-x86`, `nagare host-image`. Stop if the dry run names a builder outside the project.
5. VM: saved preview, then apply. Stop if the review touches anything but the instance and its attachments, or if
   `nagare-01`, `nix-builder-x86` or a `cell-*` VM changes state other than the builder start.
6. First boot: one Ready node, `place-age-key`, `server status` shows the key OK, `kubeconfig fetch`, `cluster guard`. Stop
   if the node is not Ready within 10 minutes or the guard names another node.
7. Bootstrap: `platform bootstrap plan` and `apply` until a review has no operations, at most 12 stages. Stop on a refusal
   or an ambiguous apply that does not resume. `external-domain-tls` stays off, so no certificate is requested.
8. Connector and fixtures: `domain-template` patch, connector Deployment with the P9 NetworkPolicy, echo service, protected
   site. Stop if the connector does not register or the site does not answer 302 to an anonymous request.
9. P1 to P10 in order, recording each. A failed observation is recorded and the rest continue only if they do not depend
   on it. P9's repointed rules are restored before the next item. Stop if a repointed rule reaches its target.
10. Teardown: protection off, stack destroyed through the same steps as the driver, image and object deleted, tunnel, both
    DNS records and any cache rule removed, Tailscale key revoked, `nagare-ops` files and the run root removed. Stop if the
    final stack export holds any resource, and list what is left.


## Validation and Acceptance

The acceptance is the Progress list. A browser session is the evidence for P7. Quote command output in Progress
for the others.


## Idempotence and Recovery

Everything is disposable. The firewall stays open throughout, so a failed experiment affects nothing else.
Removal is by tunnel and record ID.


## Interfaces and Dependencies

Cloudflare API, with a token scoped to the one account and the one zone holding exactly Account: Cloudflare
Tunnel Edit, Zone: DNS Edit, Zone: Zone Settings Edit and Zone: Cache Rules Edit. Cloudflare Tunnel Edit reads
every tunnel's token in the account, so the account should hold nothing but this installation. The token rests
sops-encrypted with the operator's other material and is exported for a command, never written to a context
file. Tunnel creation is `POST /accounts/{id}/cfd_tunnel`, configuration is
`PUT /accounts/{id}/cfd_tunnel/{tunnel}/configurations`, and rotation is `PATCH /accounts/{id}/cfd_tunnel/{tunnel}`
with a new `tunnel_secret`. Outbound port 7844 (TCP and UDP) must be open from the VM. No prerequisites.
