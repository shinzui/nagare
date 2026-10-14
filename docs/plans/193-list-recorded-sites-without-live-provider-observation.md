---
id: 193
slug: list-recorded-sites-without-live-provider-observation
title: "List recorded sites without live provider observation"
kind: exec-plan
created_at: 2026-10-14T14:46:27Z
intention: "intention_01m4xe1h31e4m8hgrt986kx7p5"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-14T14:46:27Z
---

# List recorded sites without live provider observation


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Distill durable decisions into the relevant ADRs
before completing implementation.


## Purpose / Big Picture


An operator or another program should be able to ask which sites Nagare has recorded without
waiting for a health inspection of the entire platform. Add `nagarectl site list`, with stable
JSON output, namespace selection, and optional previews. Its reusable library query reads the
inventory store and reports recorded configuration and deployment convergence. Convergence
means that Nagare recorded completion of a particular scope revision; it does not prove that
the site is reachable or healthy now.

The first delivery is the library query and CLI. An HTTP service, background reconciler,
persistent discovery index, live readiness, DNS resolution, and certificate inspection are
outside this plan. Existing `inventory status`, `domains list`, and `domains check` retain
their live inspection roles.


## Progress


- [ ] M1. A reusable store-backed query lists recorded production sites and web services, associates hostnames correctly, and distinguishes accepted from converged revisions, with representative compiler-to-reader tests.
- [ ] M2. `nagarectl site list` exposes the query through documented human and versioned JSON output, namespace selection, and optional previews, with no live workload/provider inspection or mutation setup.
- [ ] M3. Recorded correctness, process-count, and cold/warm timing evidence meet the acceptance below, including remote-store startup; required gates pass and durable documentation is updated.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-14: Read authoritative stored declarations rather than wrapping `inventory status`
or `domains list`. The operator requested inexpensive discovery of recorded deployed sites;
both existing commands inspect live providers. Preserve accepted and converged state as
separate facts so a pending or failed update cannot appear successfully deployed.

2026-10-14: Start with a library query and `site list --json`, without a new HTTP endpoint or
persisted catalog. Include ordinary application web services alongside static/server sites,
because all are user-facing sites; exclude platform-owned services and worker-only applications.
Keep previews opt-in. This avoids the label-based omissions of the existing live `app list`.

2026-10-14: Keep the existing remote store authentication and context/bucket ownership checks.
Measure their startup cost explicitly. Performance work must not remove ownership checks,
trust a stale mutable head, or turn a corrupt/missing scope into an empty successful result.


## Outcomes & Retrospective


(To be filled during implementation.)


## Context and Orientation


Run commands from the Nagare repository root. A context identifies one installation and its
private inventory store. A scope is an independently versioned set of resource declarations.
A declaration records a logical resource identity, its owning scope, its provider address,
and dependencies. A DomainMapping is a declared association between a hostname and a Knative
web route. These records can be read without contacting Kubernetes.

`cli/nagarectl/src/Nagare/Inventory/Store.hs` defines `HeadManifest`, `ScopeRevision`, `readHead`,
`readObject`, and content-addressed immutable scope storage. The head's `headAccepted` map
names the configuration Nagare accepted; `headConverged` names revisions whose execution
completed. They may differ while an update is pending or stopped. `headActiveTransaction`
identifies an open execution. Content digests verify immutable scope bytes; mutable heads
must be read from the authoritative store each invocation.

`cli/nagarectl/src/Nagare/Inventory/Plan/History.hs` contains `loadInventoryHistory` and its
scope decoding/digest checks. It also loads retained and collected history, which discovery
must not need merely to list active sites. `cli/nagarectl/src/Nagare/Inventory/Store/Target.hs`
provides `openTargetStoreReadOnly`. Its remote path uses
`cli/nagarectl/src/Nagare/Inventory/Store/Remote.hs`, authenticating and verifying bucket/project
ownership before reading GCS. Immutable content is cached by digest in `Store.hs`. Reuse
these boundaries rather than constructing mutation adapters or preparing a platform workspace.

`cli/nagarectl/src/Nagare/Inventory/Site.hs` compiles production static/server sites into
`standalone:site-<name>` scopes containing a Knative Service and DomainMappings.
`cli/nagarectl/src/Nagare/Inventory/Site/Preview.hs` compiles independent
`standalone:site-preview-<service-name>` scopes. `cli/nagarectl/src/Nagare/Inventory/Application/Service.hs`
compiles application and independently owned web services; inspect its actual resource identities
rather than treating every standalone scope as a site. Both static and server sites share the
production scope format, so do not invent a static/server distinction from names or container images.

`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` exposes the scope declarations and composition
functions; `cli/nagare-dsl/src/Nagare/Resource/Types.hs` defines typed scope/resource identities and
provider addresses. `cli/nagarectl/src/Nagare/Inventory/ProtectedRoute.hs` moves protected
DomainMappings into `nagare-system` and points their native route at the shared enforcer.
Their accepted declaration still belongs to the workload scope and depends on its origin
Service. Join by ownership and explicit resource dependencies, not equal Kubernetes namespaces
or the route's native `spec.ref`. Do not list the enforcer as each protected site's origin.

`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs` constructs observers for every
provider. `cli/nagarectl/app/Nagare/Cli/Commands/Domains.hs` also queries Pulumi and live DNS.
Neither belongs in this query. [ExecPlan 185](185-make-inventory-status-answer-in-seconds.md)
recorded full status improving from 139 seconds to 22.7–27.7 seconds, while store-only status
usually took 5.6–7.2 seconds and occasionally stalled on GCP ownership reads. Those historical
measurements motivate this separate query; they are not acceptance evidence for this work.

Relevant decisions are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
which separates immutable inspection evidence from mutation execution and forbids implicit
review archive scans; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md),
which describes context/project and shared-bucket ownership checks;
[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md), which separates declared
routing from DNS/TLS health; [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md),
which explains protected origin/route placement; and
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), which
requires interpreter proof before native confirmation and gates before commits.
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
requires checked live identity for live ownership claims; this command makes no such claim.
No ADR or inventory format change is needed merely to add the read API.


## Plan of Work


M1 delivers a library module at `cli/nagarectl/src/Nagare/Inventory/Site/Recorded.hs` with a
pure projection from validated stored scope revisions to recorded-site summaries, and a
read-only loader using the existing store. Keep projection separate from store/network IO
so future HTTP consumers can reuse it. Read a head, decode and verify referenced scopes,
compose the accepted declarations through the existing typed composition boundary, and load
previous converged scope revisions only where they differ and contain a selected site's last
recorded deployment. Reuse immutable values by digest within the invocation. Avoid loading
journals, archived reviews, native execution envelopes, or retained/collected history.
Extract a small shared scope reader if needed instead of duplicating digest and owner checks.
Re-read the head before emitting output; if it changed, fail with a retry diagnostic rather
than combining revisions from two heads.

Produce one row per accepted web Service owned by an application or recognized standalone
web/site scope. Derive its name and namespace from its declared Service address, not by splitting
a scope name. Associate DomainMapping hostnames using their dependency on that exact Service
and scope ownership; reject ambiguous associations. Use only recorded hostnames, sorted and
deduplicated. A Service without an explicit hostname still appears with an empty hostname
list; do not guess the context's default URL or perform DNS lookups. Classification distinguishes
`site`, `preview`, and `service`, without guessing static versus server rendering. An unrelated
platform Service, a worker, a release-history-only scope, a retained resource, or a collected
resource does not become an active site. A retired site disappears when its Service leaves
the accepted declarations, even if an older converged scope still exists.

Each row carries its scope and Service resource identities, accepted revision, last converged
revision if any, accepted name/namespace/hostnames, and a separate last-converged Service
summary when present. The record state is `converged` only when accepted and converged scope
revisions match; otherwise use `pending` when an earlier converged Service exists, or
`never-converged` when none exists. These labels describe scope records, not current workload
health. A renamed Service keeps the earlier converged address in the separate summary.
An active transaction is a report-level fact; do not mark every site pending solely because
some other scope has an open transaction.

Prove the producer/consumer path early using production static/server/preview and application
compilers already exercised by `cli/nagarectl/test/Nagare/Test/SiteInventory/` and
`cli/nagarectl/test/InventoryApplicationSpec.hs`. Serialize their scopes into a memory store
and consume them through the new loader. Include a protected site before expanding fixtures.
Add `cli/nagarectl/test/RecordedSiteSpec.hs` under a `recorded sites` test group and register it
in `cli/nagarectl/test/Nagare/Test/Suite.hs` and `cli/nagarectl/nagarectl.cabal`.

M2 adds `SiteListOpts` and a `SiteList` command to
`cli/nagarectl/app/Nagare/Cli/Options.hs`, parses it in
`cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, dispatches it in
`cli/nagarectl/app/Nagare/Cli/Dispatch.hs`, and implements a thin read-only command handler
at `cli/nagarectl/app/Nagare/Cli/Commands/SiteList.hs`. Resolve the selected context, open its
read-only store once, invoke the library, filter and render. All namespaces in that context
are the default; `-n/--namespace NS` filters by the origin Service namespace and is mutually
exclusive with explicit `--all-namespaces`. `--include-previews` includes preview scopes.
Default output is an aligned table of namespace, name, recorded state, and hostnames, preceded
by a notice that health was not checked. JSON is one complete document with `schemaVersion: 1`,
`context`, `headGeneration`, `activeTransaction`, `liveObserved: false`, and `sites`.
Sort rows by namespace, name, then resource identity; an initialized empty store prints
`sites: []`. Uninitialized/unavailable/corrupt stores fail clearly and nonzero. Buffered output
must not leak partial JSON before a failure. Update `docs/user/static-hosting.md`,
`docs/user/app-lifecycle.md`, and `docs/user/reference.md` to explain this recorded view and
its distinction from live inspection. Do not change existing live command defaults.

M3 proves the process and latency contract through the public command. Extend the existing
recording `ObjectOps` test patterns in `cli/nagarectl/test/InventoryObservationSpec.hs` and
`cli/nagarectl/test/InventoryObjectOpsSpec.hs` to reject archive listings and any writes.
Use an executable fixture/shim check to prove that `site list` never starts `kubectl`,
`pulumi`, `helm`, `dig`, `nix`, host transports, En checks, or other workload observers. GCS
store authentication and ownership subprocesses are allowed and must be separately counted.
Resolve the executable from the candidate being tested, rather than the global profile CLI.
Measure local and remote cold/warm invocations after interpreter tests and required gates.
Record timings and process counts, including failed or stalled attempts. If remote startup
misses its budget, identify and repair the bottleneck within the existing checked store
boundary; do not silently drop the latency criterion or weaken ownership checks.


## Concrete Steps


From the repository root, develop and run the focused suite in the project dev shell:

```bash
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "recorded sites"' --test-show-details=direct
nix develop -c cabal build nagarectl --project-dir=cli/nagarectl
```

The focused group must pass without contacting a real cluster. Exercise the public command
against the suite's disposable local-store fixture, with its generated context name:

```bash
nix develop -c cabal run nagarectl --project-dir=cli/nagarectl -- --context recorded-sites-fixture site list --all-namespaces --include-previews --json
nix develop -c cabal run nagarectl --project-dir=cli/nagarectl -- --context recorded-sites-fixture site list -n personal
```

The fixture helper added in M2 must create that context/store under temporary XDG directories
and print the environment needed for these commands; it must not touch an operator context.
The JSON should show both production and preview records, `liveObserved: false`, and stable
identities/revisions. The namespace command shows only origins in `personal`, including
protected routes whose DomainMapping namespace is `nagare-system`.

Run required implementation gates before commits and native measurements:

```bash
just gate-fast
```

For authorized read-only remote confirmation, invoke the built candidate binary with the
explicit context and time `site list --all-namespaces --include-previews --json`. Resolve its
path once with `cabal list-bin exe:nagarectl --project-dir=cli/nagarectl` inside the dev shell,
then time that executable directly; do not include Cabal/Nix startup or a build in timings.
Use a disposable cache directory for cold runs and reuse it for warm runs, preserving the
real context/store and credentials. Record the tested binary revision, context resource
count, scope/blob read counts, store-open time, query time, and total wall time. Never print
tokens or private store contents in the evidence.


## Validation and Acceptance


A converged production site appears once with its recorded hostnames. An accepted first
installation with no converged Service is `never-converged`; a pending update shows its new
accepted configuration and distinct previous converged configuration. Closing a failed
transaction must not manufacture convergence. A matching accepted/converged revision is
`converged` even if the cluster has subsequently become unreachable: `liveObserved: false`
remains explicit. Empty, duplicate-name across namespaces, renamed, protected, retired,
preview, worker-only, and platform-service fixtures follow the rules above. Hostname ordering
is deterministic, and a missing/corrupt referenced scope or changing head yields a nonzero
error without partial success output.

The recording store and public-command fixture prove no writes, no journal/review archive
scan, no live workload probes, and no dependency on a reachable Kubernetes/Pulumi/DNS service.
A warm local fixture containing at least 250 declarations completes in under one second when
timing the already-built executable. For a representative existing GCS-backed context,
all five warm invocations complete in under ten seconds, including authentication and
ownership verification; also record a cold invocation without making it a warm-cache claim.
Store-open and query times are reported separately. A slow or failed measurement keeps M3
open until corrected or the operator explicitly changes acceptance.

Before calling the implementation complete, the focused checks and required repository gates
must pass, command documentation must match its actual flags/schema, and existing live
inspection behavior must remain covered. Summarize evidence here instead of copying full
private JSON responses. Follow ADR 25 for native confirmation; no deployment or retirement
is required to validate this read-only feature.


## Idempotence and Recovery


Listing is repeatable and never initializes or migrates a store, acquires a writer claim,
changes accepted/converged revisions, materializes historical native evidence, or changes
provider resources. Existing content-verified immutable cache population is allowed. Retry
an invocation after a transient store error or head-change refusal. Cache loss changes cost,
not correctness. A local cache cannot substitute for a fresh authoritative head or make an
unavailable store look successfully empty. Fixture setup uses temporary paths and leaves
operator contexts alone. No data migration or new persistent index is planned.


## Interfaces and Dependencies


The new `Nagare.Inventory.Site.Recorded` module exports a recorded-site result type, pure
projection, read-only store query, and versioned JSON rendering (or a separate renderer in
the same library boundary). Public signatures should use the existing `InventoryStore`,
`HeadManifest`, `ScopeRevision`, `ScopeDeclaration`, `ResourceId`, and `ProviderAddress`
types rather than a mutation adapter registry. Keep IO/context selection out of the pure
projection. The CLI should contain only context selection, invocation, filtering and display.
Do not expose native Secret/configuration payloads in summaries.

Use the repository's existing Aeson, containers, text, and inventory store dependencies.
No new package, server, storage engine, or persisted schema is required. If implementing a
store optimization requires a dependency API, locate its source/docs through Mori and check
upstream releases before choosing pins or bounds. This is a standalone ExecPlan; it does
not add work to the fixed finish line of MasterPlan 26. ExecPlan 185 supplies historical
context, not a pending prerequisite. The intention in frontmatter was created for this plan.
