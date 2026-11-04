---
id: 244
slug: make-the-tunnel-the-recommended-path-for-new-nagare-installations
title: "Make the tunnel the recommended path for new Nagare installations"
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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T14:04:32Z
      verdict: "comments"
      note: "D1-D5 evidenced; D6 should wait for EP-245 D1-D3 and check a bearer request with no User-Agent and a 304 through the edge"
---

# Make the tunnel the recommended path for new Nagare installations

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

Someone installing Nagare for the first time is led to the tunnel path by default, understands what it costs and what it trades away, and
can choose direct ingress instead without friction. Someone with a running direct context sees a one-line pointer and nothing else changes.


## Progress

- [x] D1 ([onboarding](../user/onboarding-bring-your-own-project.md) leads with these steps and [the tunnel guide](../user/cloudflare-tunnel.md) carries them to a protected site): `docs/user/onboarding-bring-your-own-project.md` leads with the tunnel path: add your domain to Cloudflare and set the name servers,
  with no Cloud DNS delegation step. It says to turn on two-factor authentication at Cloudflare and the registrar, to remove any DS
  record before the name server change and turn DNSSEC on at Cloudflare after, and to create the API token with exactly the
  permissions EP-240 lists, in an account that holds nothing else. Direct ingress is a clearly labelled alternative.
- [x] D2 ([choosing-ingress.md](../user/choosing-ingress.md); `just user-documentation-validate`): A new page in `docs/user` states the recommendation and when not to follow it, covering cost ($0 with the domain as base, $10 a month
  with a subdomain base), Cloudflare decrypting traffic, the Cloudflare account and registrar as roots of trust, the tunnel token as an
  interception credential and when to rotate it, the absence of edge request logs on Free and Pro, the edge policy Nagare sets, the
  upload and timeout limits, and the alternatives from RES-7. `just user-documentation-validate` passes.
- [x] D3 (`resolveInitIngress`; an existing context keeps what it has): On a terminal, `nagarectl init` asks how the context receives traffic and preselects the tunnel, naming the trade-off in one line. It
  accepts `--ingress direct|cloudflare-tunnel`. A non-interactive run without the flag stays `direct` and prints one line pointing at the page.
  Tests cover each case.
- [x] D4 (`directIngressNotice`, tested in `Nagare.Test.Init`; silenced by `NAGARE_INGRESS_NOTICE=off` in the context file): `nagarectl platform status` and `nagarectl doctor` on a `direct` cloud context show one informational line: web ports are open to the
  internet, with the page to read. It never changes the exit code, makes no network call, and can be silenced per context.
- [x] D5 (README, `gcp-prerequisites.md`, both indexes): `README.md`'s ingress description, `docs/user/gcp-prerequisites.md` and the `docs/user` index reflect the recommendation.
- [ ] D6: Following the onboarding page alone on a fresh disposable project ends with a deployed protected site, working login, an outside port
  check finding nothing open, and a host listening on no web port. Each place the page was wrong is fixed in the page.


## Surprises & Discoveries

(None yet.)


## Decision Log

(None yet.)


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Onboarding today, in `docs/user/onboarding-bring-your-own-project.md`, delegates the operator's domain to a Cloud DNS zone that Pulumi creates
(Steps 5 and 6, and section 5 of `docs/user/gcp-prerequisites.md`). The tunnel path replaces that with adding the domain to Cloudflare. `nagarectl
init` is parsed in `cli/nagarectl/app/Nagare/Cli/Parser/Context.hs`, already prompts on a terminal for VM shape values, and writes the context
through `cli/nagarectl/src/Nagare/Init.hs`. `cli/nagarectl/src/Nagare/Ops/Doctor.hs` and
`cli/nagarectl/src/Nagare/Ops/Status.hs` produce the health output.

[RES-7](../research/cloudflare-tunnel-and-load-balancer-options-for-closing-inbound-web-ports.md) holds the comparison. Existing contexts must never
change mode on upgrade. Existing scripts and rehearsals run `init` without a terminal, so that case keeps its current result.


## Plan of Work

Write the page and rework onboarding first, then add the `init` choice and the status line. Finish by following the page on a fresh project, as a new
user would, and fixing what it gets wrong.


## Validation and Acceptance

Per Haskell commit run `just haskell-style-check`, then `just gate-fast`. `cabal test nagarectl-test` covers D3 and D4. D6 is the initiative's final gate.
It is a cloud mutation on a disposable project and needs the operator's go-ahead, after [Before a native run](../runbooks/before-a-native-run.md).


## Idempotence and Recovery

The documentation and prompts mutate nothing. The disposable project is removed after D6.


## Interfaces and Dependencies

Requires EP-243 complete, so that the recommendation rests on a proven path. Reads `NAGARE_INGRESS` from EP-241.
