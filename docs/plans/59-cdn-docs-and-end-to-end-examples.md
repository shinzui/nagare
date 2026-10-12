---
id: 59
slug: cdn-docs-and-end-to-end-examples
title: "CDN docs and end-to-end examples"
kind: exec-plan
created_at: 2026-06-10T18:57:36Z
intention: "intention_01ktsdz4s8er09txy9afce3hn4"
master_plan: "docs/masterplans/11-cdn-integration-for-nagare.md"
---

# CDN docs and end-to-end examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [59-cdn-docs-and-end-to-end-examples.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/59-cdn-docs-and-end-to-end-examples.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

A "CDN" — Content Delivery Network — is a globally distributed cache that sits in front of an
origin server: instead of every request travelling to Nagare's one VM in `us-west1`, visitors
are served cached copies from a nearby edge location. Nagare ships two CDN backends:
**Cloudflare** (a reverse proxy in front of the VM's public IP, configured through the
Cloudflare API by `nagarectl`) and **Google Cloud CDN** (a global HTTP(S) load balancer with
caching turned on, provisioned through Pulumi). A developer turns one on by adding a `cdn`
field to the same typed `nagare/Config.hs` they already write, and `nagarectl site deploy`
provisions and wires it as part of the normal deploy.

This plan is the **proof** of the whole CDN initiative (MasterPlan 11,
`docs/masterplans/11-cdn-integration-for-nagare.md`). It delivers the user documentation, the
DNS and origin-TLS runbook, and two worked end-to-end examples that demonstrate both headline
cases: a static site fronted by Cloudflare and a TanStack Start full-stack app fronted by
Google Cloud CDN. After this plan, a reader can: understand what a CDN buys them and which
backend to choose; add `cdn = Just (cloudflareCdn & …)` or `gcpCloudCdn` to a config; run
`nagarectl site deploy --dry-run` and see the generated Knative Service, DomainMapping, and the
**planned CDN changes** before anything touches the cloud; operate the edge with
`nagarectl cdn list|status|purge|disable`; and follow a step-by-step runbook to set the DNS
record and origin-TLS mode for a CDN-fronted hostname, including the cert-manager DNS-authority
caveat when a zone moves to Cloudflare.

This plan writes **documentation and examples only** — it adds no library or CLI code. It
depends on the typed model (EP-55, `cdn :: Maybe Cdn` on `StaticSite`/`ServerSite`/`Deployment`
with the `cloudflareCdn`/`gcpCloudCdn` presets and `with*` combinators), the deploy wiring and
`nagarectl cdn` command group (EP-58,
`docs/plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md`), the Google Cloud
CDN load balancer in Pulumi (EP-56,
`docs/plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md`), and the Cloudflare
provisioner in `nagarectl` (EP-57,
`docs/plans/57-cloudflare-cdn-provisioning-via-api-in-nagarectl.md`). The substrate decisions —
Cloudflare's steady-state origin-TLS mode is `Full (strict)`, Google's origin hop is HTTPS, the
load balancer preserves the `Host` header, and the cert-manager DNS-authority caveat — come
from the spike EP-54 (`docs/plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md`).

The honest limitation, stated up front exactly as the static-hosting and database docs do:
`nagare-01` is currently **powered off**, and no real delegated domain or Cloudflare token
exists in this environment. The **dry-run-verifiable** parts of every example work offline
today; the **live** legs — the actual `CF-Cache-Status: HIT` curl against Cloudflare and the
Google Cloud CDN cache-`Age:` curl — are documented as **deferred** until the box is powered on
and a real domain plus token exist. This is the same gating MasterPlan 3's docs plan (EP-17)
and the database/task docs plans used for the powered-off box.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — write `docs/user/cdn.md` (the guide + the DNS/origin-TLS runbook chapter)
      and wire it into the `docs/user/README.md` operator-guide index (a "CDN (edge caching)"
      bullet after the static-hosting entry and a `MP-11 (EP-54–59)` status-table row).
- [x] Milestone 2 — create `cluster/examples/static-cdn-site/` (static site behind Cloudflare):
      copied `public/`, `nagare/Config.hs` with a Cloudflare `cdn`, and a `README.md` walking
      through deploy + `nagarectl cdn status` + cache-purge + the deferred `CF-Cache-Status: HIT`
      curl.
- [x] Milestone 2 — create `cluster/examples/tanstack-start-cdn/` (TanStack Start behind Google
      Cloud CDN): `package.json`, `nagare/Config.hs` with a `gcpCloudCdn`, and a `README.md`
      walking through `pulumi config set nagare:enableCdn true && pulumi up`, deploy,
      `nagarectl cdn status`, and the deferred cache-`Age:` curl.
- [x] Milestone 2 — verified the offline acceptance: `nagarectl site deploy --dry-run` (run from
      `cli/nagarectl/`) renders nginx/Dockerfile + Knative Service + DomainMapping + the planned
      CDN-changes block in each example, and a no-CDN config prints zero CDN banners (unchanged).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The actual EP-58 dry-run block is `--- CDN plan (Cloudflare) ---` / `--- CDN plan (GcpCloudCdn)
  ---` with `DNS:` / `Origin TLS:` / `Cache:` lines (Cloudflare) and `gcloud …` lines (Google),
  produced by `renderCdnPlan`. This plan's draft showed an illustrative `--- Planned CDN changes
  ---` format; the guide and READMEs document the **real** output instead. The Google plan's
  `gcloud` lines each carry `--project=tan-nb-exp`, and unresolved stack outputs render as
  `<publicIp>`/`<cdnGlobalIp>`/`<dnsZoneName>`/`<cdnBackendService>` placeholders in the offline
  dry-run (the real values substitute when the Pulumi stack is available).

- The copied `tanstack-start` example config used a bare `EnvLiteral "0.0.0.0"` in the
  `ServerSite.env` map, which no longer type-checks — that field is `Map EnvName ScopedEnvVar`, so
  it needs `runtimeScoped (EnvLiteral "0.0.0.0")`. The pre-existing `tanstack-start` example shares
  this staleness (it is not exercised by tests). The new `tanstack-start-cdn` config uses
  `runtimeScoped` and dry-runs cleanly.

- Verified offline: the static example dry-run prints `--- Generated nginx.conf ---`, `--- Knative
  Service manifest ---`, `--- DomainMapping manifest ---` (`blog.apps.example.com`), the URL, and
  the `--- CDN plan (Cloudflare) ---` block; the no-CDN `static-site` baseline prints **zero** CDN
  banners (`grep -c "CDN plan"` → 0), confirming MasterPlan 11's "unchanged when no CDN" promise.

## Decision Log

Record every decision made while working on the plan.

- Decision: ship a dedicated CDN guide and runbook (`docs/user/cdn.md`) rather than folding CDN
  content into the existing `docs/user/static-hosting.md`.
  Rationale: a CDN introduces concerns that static hosting does not — splitting a hostname's DNS
  authority off to a different provider, edge versus origin TLS modes (`Flexible`/`Full`/
  `Full (strict)`), the cert-manager DNS-01 caveat when a zone moves to Cloudflare, and edge
  cache semantics (default TTL, per-path overrides, "never cache", purge). These warrant their
  own runbook a reader can follow under pressure, and `cdn` applies to `ServerSite` and
  `Deployment` too, not only static sites, so it does not belong inside the static-only page.
  Date: 2026-06-10

- Decision: provide two worked examples that prove both providers AND both runtimes — a static
  site behind Cloudflare (`cluster/examples/static-cdn-site/`) and a TanStack Start server site
  behind Google Cloud CDN (`cluster/examples/tanstack-start-cdn/`) — as new sibling directories
  rather than mutating the existing `static-site`/`tanstack-start` examples.
  Rationale: the existing examples are referenced by `docs/user/static-hosting.md` and its
  dry-run transcripts as the no-CDN baseline; leaving them untouched preserves that baseline and
  lets the CDN examples read as a clean diff (the same config plus a `cdn` field). Cross-pairing
  the providers and runtimes (Cloudflare+static, Google+TanStack) demonstrates that `cdn` is a
  uniform, provider-agnostic and runtime-agnostic field, which is MasterPlan 11's headline
  acceptance.
  Date: 2026-06-10

- Decision: deliver the docs and examples and the dry-run-verifiable acceptance now; defer the
  live cache-HIT proofs (Cloudflare `CF-Cache-Status: HIT`, Google Cloud CDN cache-`Age:`) until
  `nagare-01` is powered on and a real delegated domain plus a real `CF_API_TOKEN` exist.
  Rationale: the VM is powered off and the placeholder base domain `apps.example.com` is not
  delegated, so a live edge cannot be reached. This matches how MasterPlan 3's EP-17 and the
  database/task docs plans handle the powered-off box: ship everything that is verifiable offline,
  mark the live leg clearly as the intended behaviour, and gate it on the box coming back up.
  Date: 2026-06-10

- Decision: write the example `nagare/Config.hs` files threading `withCacheRule` monadically in
  the `Either String` do-block, not as the pure `&`-chain shown in MasterPlan 11's vision excerpt.
  Rationale: EP-55 (`docs/plans/55-typed-cdn-model-and-provider-renderer.md`) defines
  `withCacheRule :: Text -> Maybe Int -> Cdn -> Either Text Cdn` (it validates the per-path TTL),
  while `withDefaultTtl` and `withoutStaticAssetCache` are total `Cdn -> Cdn`. The MasterPlan's
  `&`-only excerpt is illustrative; the real, compiling code must bind the `Either` result. The
  examples must compile under `nagarectl site deploy --dry-run`, so they use the true signatures.
  Date: 2026-06-10

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-10).** The CDN initiative is proven end to end offline. `docs/user/cdn.md` is
a self-contained guide + DNS/origin-TLS runbook (what a CDN buys you and which to choose, the typed
`cdn` field, the cache model, the deploy flow with the real `--dry-run` block, the `nagarectl cdn`
command surface, and the runbook covering proxied-vs-more-specific DNS, the `Flexible →
Full (strict)` / Google-HTTPS origin-TLS modes, the cert-manager DNS-01 caveat, and provider
credentials). It is linked from the operator-guide index and the status table. Two worked examples
demonstrate both providers AND both runtimes — `static-cdn-site` (static + Cloudflare) and
`tanstack-start-cdn` (TanStack Start + Google Cloud CDN) — each a clean diff over its no-CDN
sibling (the same config plus a `cdn` field). Both dry-run cleanly from `cli/nagarectl/`, printing
the rendered Service/DomainMapping and the planned CDN changes; the no-CDN baseline is unchanged.

**Gaps / deferred.** The live cache-HIT proofs (Cloudflare `CF-Cache-Status: HIT`, Google Cloud CDN
growing `Age:`) and the live `nagarectl cdn list`/`status` discovery are deferred until `nagare-01`
is powered on, the base domain is delegated, and a real `CF_API_TOKEN` exists — documented in both
READMEs and the guide as the intended behaviour, matching the powered-off-box gating MasterPlan 3's
EP-17 and the database/task docs plans used. No code was changed by this plan; it consumes the
EP-55/56/57/58 surfaces verbatim.

