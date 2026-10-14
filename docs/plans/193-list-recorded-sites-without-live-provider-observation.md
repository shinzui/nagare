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
- [ ] M2. `nagarectl site list` exposes the query through documented human and versioned JSON output, namespace selection, and optional previews, with no live workload/provider inspection or mutation setup; the `NAGARE_RECORDED_SITES_FIXTURE` probe seeds a disposable local context.
- [ ] M3. The no-write recording test, the empty-`PATH` fixture run, and cold/warm timing evidence meet the acceptance below, including remote-store startup; required gates pass and durable documentation is updated.


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

2026-10-14 (review): Read the head once and drop the re-read-and-refuse step. Scopes are
immutable and digest-checked, so a single head is already a consistent snapshot; a second read
only adds a GCS round trip and a spurious failure during concurrent deploys. Drop
`--all-namespaces`, because all namespaces are the default. Classify rows by Knative Service
address, scope kind, and the existing `previewOwner` predicate. Prove the absence of
subprocesses by running against the local fixture with an empty `PATH` instead of a shim
harness. Measure only wall time, so no new store instrumentation is needed. The public-command
fixture is a `Suite.hs` environment probe, because the test suite cannot import `app/`.


2026-10-14 (operator): Nagare's admin API is read-only, and
[EP-192](192-publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes.md) is now
the one public document contract that API will serve. `site list`'s versioned JSON is that
contract's `site-list` read document: emit it under `--contract 1`, and add its hand-written
schema and golden samples to `cli/nagarectl/contract/v1/` under the README rules, once EP-192's M1
has landed. Refusals use EP-192's `refusal` document. The query, its library location in `src/`,
and this plan's acceptance are unchanged.

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
Read the head exactly once. Every scope it names is immutable and digest-checked, so one head
read is already a consistent snapshot; a referenced scope that is missing or fails its digest
is an error, never an omitted row.

Produce one row per accepted declaration whose provider address is a Kubernetes
`serving.knative.dev/v1` `Service` and whose owning scope kind (`scopeKind`, defined with
`ScopeKind = Platform | Application | Standalone | Publication` in
`cli/nagare-dsl/src/Nagare/Resource/Types.hs`) is `Application` or `Standalone`. Derive its name
and namespace from that address, not by splitting a scope name. Classify the row as:
`preview` when `previewOwner` in `cli/nagarectl/src/Nagare/Inventory/PreviewCleanup.hs` holds for
its scope (export that predicate rather than copying the prefix test); `site` when the scope is a
`Standalone` scope named `site-<name>` (the owner built in `Site.hs`) and not a preview; and
`service` otherwise. Workers need no exclusion rule: `Application/Worker.hs` compiles Kubernetes
`Deployment`s, and application hook scopes (`standalone:app-hook-*` in `Application/Tasks.hs`)
compile no Knative Service, so neither produces a row. Do not guess static versus server rendering.

Associate a hostname with a Service through the DomainMapping declarations in the same scope:
each carries an `OrderedAfter` dependency on the Service's resource identity and a single
`Hostname` alias (`Site.hs` binds both; `Application/Service.hs` sets the alias). Read the
hostname from that alias, not from the native bytes or the mapping's namespace. Reject a
DomainMapping that depends on zero or several Services of its scope. Sort and deduplicate
hostnames. A Service without a DomainMapping appears with an empty hostname list; do not guess
the context's default URL or perform DNS lookups. A protected workload with no declared domain
still lists its default hostname, because `protectedHosts` in `ProtectedRoute.hs` records it as
an explicit DomainMapping. A platform Service, a release-history-only scope, a retained resource,
or a collected resource does not become an active site. A retired site disappears when its
Service leaves the accepted declarations, even if an older converged scope still exists.

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
in `cli/nagarectl/test/Nagare/Test/Suite.hs` and the `nagarectl-test` `other-modules` list in
`cli/nagarectl/nagarectl.cabal`. The test suite compiles only `test/` against the library, so
everything the tests must exercise, including opening the target's read-only store and rendering
JSON, lives in the library; the `app/` handler only parses, calls, and prints.

M2 adds `SiteListOpts` and a `SiteList` command to
`cli/nagarectl/app/Nagare/Cli/Options.hs`, parses it in
`cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, dispatches it in
`cli/nagarectl/app/Nagare/Cli/Dispatch.hs`, and implements a thin read-only command handler
at `cli/nagarectl/app/Nagare/Cli/Commands/SiteList.hs` (a new module, so the 969-line
`Commands/Site.hs` does not grow). Register `site list` beside the existing `deploy`, `releases`,
`rollback`, and `preview` subcommands in `Parser/Site.hs`. Resolve the selected context, open its
read-only store once through `openTargetStoreReadOnly`, invoke the library, filter and render.
All namespaces in that context are the default; `-n/--namespace NS` filters by the origin
Service namespace. There is no `--all-namespaces` flag, because it would only restate the
default. `--include-previews` includes preview scopes.
Default output is an aligned table of namespace, name, recorded state, and hostnames, preceded
by a notice that health was not checked. JSON is one complete document with `schemaVersion: 1`,
`context`, `headGeneration`, `activeTransaction`, `liveObserved: false`, and `sites`.
Sort rows by namespace, name, then resource identity; an initialized empty store prints
`sites: []`. Uninitialized/unavailable/corrupt stores fail clearly and nonzero. Buffered output
must not leak partial JSON before a failure. Update `docs/user/static-hosting.md`,
`docs/user/app-lifecycle.md`, and `docs/user/reference.md` to explain this recorded view and
its distinction from live inspection. Do not change existing live command defaults.

M2 also adds the public-command fixture, following the environment-driven probe pattern already
in `cli/nagarectl/test/Nagare/Test/Suite.hs` (for example `NAGARE_COLLECTION_ROOT`). When
`NAGARE_RECORDED_SITES_FIXTURE=DIR` is set, the test executable writes a `mode=local` context
named `recorded-sites-fixture` under `DIR/config/nagare/contexts/` (fields as in
`nagare.local.env.example`, with the local inventory store) and seeds its filesystem store at
`DIR/state/nagare/recorded-sites-fixture/inventory`, which is where `openTargetStoreReadOnly`
looks for a local store. The seed uses the same production compilers as the M1 tests,
including at least one protected site, one preview, one application web service, one
worker-only application, and enough sites to exceed 250 declarations. It then exits without
running the tests.

M3 proves the process and latency contract through the public command. Extend the recording
`ObjectOps` pattern in `cli/nagarectl/test/InventoryObjectOpsSpec.hs` so that a GCS-backed
`site list` query fails the test on any write or archive/journal listing. Prove that no workload
or provider tool runs by invoking the built binary against the local fixture with `PATH` pointing
at an empty directory: success shows it never started `kubectl`, `pulumi`, `helm`, `dig`,
`nix`, or a host transport. Do not build a shim harness. Resolve the executable from the
candidate being tested, rather than the global profile CLI. Measure local and remote cold and
warm invocations after the tests and required gates pass. Record wall times, including failed or
stalled attempts. If remote startup misses its budget, identify and repair the bottleneck within
the existing checked store boundary. Do not silently drop the latency criterion or weaken
ownership checks.


## Concrete Steps


From the repository root, develop and run the focused suite in the project dev shell:

```bash
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p "recorded sites"' --test-show-details=direct
nix develop -c cabal build nagarectl --project-dir=cli/nagarectl
```

The focused group must pass without contacting a real cluster. Seed the M2 fixture in a
scratch directory, then exercise the public command with only that directory's XDG paths and an
empty `PATH`, so no operator context is visible and no subprocess can start:

```bash
fixture=$(mktemp -d)
nix develop -c cabal build nagarectl nagarectl-test --project-dir=cli/nagarectl
bin=$(nix develop -c cabal list-bin exe:nagarectl --project-dir=cli/nagarectl)
NAGARE_RECORDED_SITES_FIXTURE="$fixture" $(nix develop -c cabal list-bin test:nagarectl-test --project-dir=cli/nagarectl)
mkdir "$fixture/empty-path"
env -i HOME="$fixture" XDG_CONFIG_HOME="$fixture/config" XDG_STATE_HOME="$fixture/state" XDG_CACHE_HOME="$fixture/cache" PATH="$fixture/empty-path" \
  "$bin" --context recorded-sites-fixture site list --include-previews --json
env -i HOME="$fixture" XDG_CONFIG_HOME="$fixture/config" XDG_STATE_HOME="$fixture/state" XDG_CACHE_HOME="$fixture/cache" PATH="$fixture/empty-path" \
  "$bin" --context recorded-sites-fixture site list -n personal
```

The JSON shows both production and preview records, `liveObserved: false`, and stable
identities and revisions. The namespace command shows only origins in `personal`, including
protected sites whose DomainMapping namespace is `nagare-system`. Time the first command five
times with `time` for the local latency criterion.

Run the required gates before each Haskell commit:

```bash
just haskell-style-check
just gate-fast
```

For the authorized read-only remote confirmation, run the same `"$bin"` with the real context
name and the operator's normal environment, timing `site list --include-previews --json`. Do
not include Cabal/Nix startup or a build in timings. For the cold run, point `XDG_CACHE_HOME` at
a fresh directory, because `inventoryCacheRoot` in `Store/Target.hs` places the blob cache at
`$XDG_CACHE_HOME/nagare/<context>/inventory-blobs`. Reuse that directory for the five warm runs.
Record the tested binary revision, the context's declaration count, and each wall time. Never
print tokens or private store contents in the evidence.


## Validation and Acceptance


A converged production site appears once with its recorded hostnames. An accepted first
installation with no converged Service is `never-converged`; a pending update shows its new
accepted configuration and distinct previous converged configuration. Closing a failed
transaction must not manufacture convergence. A matching accepted/converged revision is
`converged` even if the cluster has subsequently become unreachable: `liveObserved: false`
remains explicit. Empty, duplicate-name across namespaces, renamed, protected, retired,
preview, worker-only, and platform-service fixtures follow the rules above. Hostname ordering
is deterministic, and a missing or corrupt referenced scope yields a nonzero error without
partial success output.

The recording store proves no writes and no journal or review archive scan. The empty-`PATH`
fixture run proves no live workload probe and no dependency on a reachable
Kubernetes/Pulumi/DNS service. A warm local fixture containing at least 250 declarations
completes in under one second when timing the already-built executable. For a representative
existing GCS-backed context, all five warm invocations complete in under ten seconds, including
authentication and ownership verification. Also record a cold invocation, without making it a
warm-cache claim. A slow or failed measurement keeps M3 open until corrected or the operator
explicitly changes acceptance.

Before calling the implementation complete, the focused checks and required repository gates
must pass, command documentation must match its actual flags/schema, and existing live
inspection behavior must remain covered. Summarize evidence here instead of copying full
private JSON responses. Follow ADR 25 for native confirmation; no deployment or retirement
is required to validate this read-only feature.


## Idempotence and Recovery


Listing is repeatable and never initializes or migrates a store, acquires a writer claim,
changes accepted/converged revisions, materializes historical native evidence, or changes
provider resources. Existing content-verified immutable cache population is allowed. Retry
an invocation after a transient store error. Cache loss changes cost,
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
