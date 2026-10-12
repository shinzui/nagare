---
id: 40
slug: nagarectl-domains-list-with-dns-and-certificate-readiness
title: "nagarectl domains list with DNS and certificate readiness"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# nagarectl domains list with DNS and certificate readiness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [40-nagarectl-domains-list-with-dns-and-certificate-readiness.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/40-nagarectl-domains-list-with-dns-and-certificate-readiness.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After this change an operator can run one command and see every domain the platform serves —
the shared platform base domain plus every per-app Knative `DomainMapping` — together with the
Service each domain belongs to, what DNS record the domain *should* resolve to, and whether its
TLS certificate is ready. Today that knowledge is scattered: the base domain lives in a Pulumi
stack output and an in-cluster ConfigMap, per-app domains live in `DomainMapping` objects across
namespaces, and certificate state lives in cert-manager `Certificate` objects. There is no single
place to answer "what domains do I have, where should they point, and are they HTTPS-ready?" This
plan adds `nagarectl domains list` to answer exactly that, in one aligned table.

The command surface this plan delivers:

```text
nagarectl domains list [-n NS] [--all-namespaces] [--base-domain DOMAIN]

  list   Enumerate the platform base domain and every per-app DomainMapping,
         showing the owning Service, the expected DNS record, and certificate
         readiness. Read-only.
```

`domains` is introduced as a command *group* (like the existing `site` group) so that future
`domains add` / `domains remove` subcommands have a home, but this plan ships only `domains list`.

You can see it working end to end. Deploy an app that requests a custom domain, which makes
`nagarectl deploy` create a Knative `DomainMapping`; then run `domains list`:

```text
$ nagarectl deploy            # app config maps app.nadeem.dev -> the Service
...
$ nagarectl domains list
  DOMAIN                          SERVICE          DNS                              CERT
  apps.example.com               (base)           *.apps.example.com A -> 34.x.x.x  disabled
  app.nadeem.dev                 blog             *.apps.example.com A -> 34.x.x.x  Ready
```

The first row is the platform base domain (the wildcard apex). Each subsequent row is a
`DomainMapping`: its hostname, the Service it routes to (`.spec.ref.name`), the DNS record the
domain is expected to match (computed from the Pulumi wildcard + reserved IP — not a live `dig`),
and its certificate readiness. When external-domain TLS is disabled (the current bootstrap state,
because the placeholder `apps.example.com` cannot pass an ACME DNS-01 challenge), the `CERT` column
reads `disabled` rather than erroring.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-06-10): Pure module `Nagare.Ops.Domains` — `DomainRow`/`DnsExpectation`/`CertState`/`DomainMapping`
  types, the `DomainMapping` and `Certificate` JSON extractors (`extractDomainMappings`,
  `extractCertReadiness`), the DNS-expectation computation (`dnsExpectationFor`), the cert grader
  (`certStateFor`), and the `formatDomainList` table formatter. Added to the cabal library `exposed-modules`.
  Covered by `testGroup "Nagare.Ops.Domains"` (15 cases) in `test/Spec.hs` — all green.
- [x] M2 (2026-06-10): `nagarectl domains list` wired — `domains` command group with a `list`
  subcommand, namespace selection (`-n` / `--all-namespaces`, default `personal`), base-domain
  resolution (Pulumi `baseDomain` → flag/env/literal fallback), and graceful TLS-disabled handling so a
  missing `Certificate` (or a TLS-off cluster) shows `disabled`, not an error. The thin kubectl IO
  (`queryDomainRows`/`listNamespaces`) lives in the library and reuses EP-38's `captureTool` (IP4) so a
  missing `kubectl` degrades to the base row, not a crash.
- [x] M3 (2026-06-10): Tests green (`cabal build && cabal test`, 163 tests) and a captured
  `nagarectl domains list --help` transcript (below). Degradation proven with an empty PATH (base row
  with `(unknown)` IP, exit 0). Live cluster run deferred (pure parsers/formatters validated by unit tests).

## Surprises & Discoveries

- 2026-06-10 (M2): `cli/nagarectl/app/Main.hs` does **not** depend on `cradle` (the executable's
  cabal `build-depends` omits it; every existing command delegates subprocess work to library
  modules). The plan sketched `runDomainsList` doing the kubectl IO inline in `Main.hs`, which would
  require adding `cradle` to the executable. Instead the thin kubectl IO (`queryDomainRows`,
  `listNamespaces`) lives in the library module `Nagare.Ops.Domains`, and `Main.hs`'s `runDomainsList`
  just resolves the base/IP (via the library `Nagare.Ops.Pulumi.stackOutput`), calls those library IO
  functions, and prints `formatDomainList`. This keeps `Main.hs` cradle-free and matches the existing
  codebase convention.
- 2026-06-10 (M2): The kubectl queries must tolerate `kubectl` being **entirely absent**, not just a
  non-zero exit. A first cut using raw `cradle` `run` threw an uncaught `IOException` (`posix_spawnp:
  does not exist`) when `kubectl` was off PATH. Switched `queryDomainRows`/`listNamespaces` to reuse
  EP-38's `captureTool` (the IP4 wrapper, which catches the missing-binary `IOException` and returns
  `Nothing`), so `domains list` prints just the base row (`*.<base> A -> (unknown) disabled`) and exits
  0 when no tooling is reachable — exactly the plan's "no cluster reachable" shape.
- 2026-06-10 (M1): The DNS column follows the spec (computed wildcard membership), not the loose
  illustrative example in Purpose — an unrelated domain like `app.nadeem.dev` renders
  `(outside wildcard)`, while apex and single-label subdomains of the base render
  `*.<base> A -> <publicIp>`. Two-label subdomains (`a.b.<base>`) are correctly outside the
  single-label wildcard.

## Decision Log

Record every decision made while working on the plan.

- Decision: `domains list` is strictly read-only. It only runs `kubectl get … -o json` (and reads
  the base domain). It never patches, deletes, or applies anything.
  Rationale: An inventory command must be safe to run anywhere, anytime, including against a
  production cluster, with no risk of side effects. Mutating domains (`add`/`remove`) is explicitly
  out of scope for this plan.
  Date: 2026-06-09

- Decision: Reuse `Nagare.App`'s existing `DomainMapping` query path rather than duplicating kubectl
  plumbing. `Nagare.App.extractDomainsFor` already decodes a `kubectl get domainmapping … -o json`
  list and pulls `.spec.ref.name`; the new `Nagare.Ops.Domains` extractors decode the same JSON shape
  and extend it (keep the hostname, the owning Service, and the Ready condition) instead of inventing
  a new query.
  Rationale: One JSON shape, one tested decoder family. Diverging plumbing would risk the two
  commands disagreeing about what domains exist.
  Date: 2026-06-09

- Decision: Readiness is shown for both the `DomainMapping` and the `Certificate`. The table has a
  per-row `CERT` column derived from the cert-manager `Certificate` Ready condition; the
  `DomainMapping`'s own Ready condition is also surfaced (so a routing-not-ready domain is visible
  distinct from a cert-not-ready one).
  Rationale: A domain can be live-but-insecure (route Ready, cert pending) or
  configured-but-unrouted (mapping not Ready). Operators need to tell those apart.
  Date: 2026-06-09

- Decision: The DNS column is a *computed expectation*, not a live DNS lookup, for v1. It is derived
  from the Pulumi `publicIp` and the wildcard `*.<baseDomain>` record Pulumi provisions — the column
  states whether the domain falls under that wildcard and what IP it should resolve to. No `dig` /
  resolver call is made.
  Rationale: Live DNS resolution is flaky, slow, and environment-dependent (split-horizon, caching),
  and would make the command non-deterministic and untestable without network. A computed
  expectation is deterministic, unit-testable, and still answers "is this domain provisioned to
  resolve?". Live resolution can be layered on later.
  Date: 2026-06-09

- Decision: Soft-reuse EP-38's helpers when present, but do not block on EP-38. If
  `Nagare.Ops.Pulumi.stackOutput` and EP-38's shared table `pad`/formatter exist, use them;
  otherwise read the base domain via the existing fallback chain and copy the `pad` helper from
  `Nagare.App.formatAppList` verbatim. EP-38's probe *grading* model is not used.
  Rationale: EP-40 has its own data sources (`DomainMapping`, `Certificate`) and can be built
  independently against the same kubectl patterns; coupling its delivery to EP-38 would serialize
  two otherwise-parallel plans.
  Date: 2026-06-09

## Outcomes & Retrospective

Delivered `nagarectl domains list`: the pure `Nagare.Ops.Domains` module (the
`DomainRow`/`DnsExpectation`/`CertState`/`DomainMapping` types, the
`extractDomainMappings`/`extractCertReadiness` extractors, `dnsExpectationFor`,
`certStateFor`, and `formatDomainList`) plus a thin library IO layer
(`queryDomainRows`, `listNamespaces`) and the `domains` command group in
`cli/nagarectl/app/Main.hs` (a `Domains DomainsCommand` constructor with
`DomainsCommand = DomainsList DomainsListOpts`, `domainsListOptsParser`,
`command "domains" domainsCmd`, the `runDomainsList` handler, and the `main`
dispatch arm). All 163 tests pass, including the new 15-case
`testGroup "Nagare.Ops.Domains"`.

Captured transcript (2026-06-10):

```text
$ nagarectl domains list --help
Usage: nagarectl domains list [-n|--namespace NS] [--all-namespaces]
                              [--base-domain DOMAIN]

  List the base domain and per-app DomainMappings with DNS and cert state

Available options:
  -n,--namespace NS        Kubernetes namespace (default: personal)
  --all-namespaces         List domains across all namespaces
  --base-domain DOMAIN     Apps base domain (overrides NAGARE_BASE_DOMAIN,
                           default apps.example.com)
  -h,--help                Show this help text
```

Degradation (empty PATH — no kubectl/pulumi reachable; base row still prints,
exit 0):

```text
$ PATH=/var/empty nagarectl domains list
  DOMAIN                          SERVICE         DNS                               CERT
  apps.example.com                (base)          *.apps.example.com A -> (unknown) disabled
$ echo $?
0
```

What changed from the plan: the kubectl IO lives in the library (Main.hs has no
`cradle` dep) and reuses EP-38's `captureTool` for missing-binary tolerance; the
DNS column follows the computed-wildcard spec. The live cluster run (with a
deployed app owning a DomainMapping, and the TLS-on `Ready`/`pending` cert path)
is deferred per the plan's M3 convention; the pure extractors, DNS expectation,
cert grader, and formatter are fully unit-tested, and the graceful TLS-disabled /
no-cluster paths are proven by the empty-PATH run above.

