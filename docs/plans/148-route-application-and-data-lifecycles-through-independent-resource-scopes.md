---
id: 148
slug: route-application-and-data-lifecycles-through-independent-resource-scopes
title: "Route application and data lifecycles through independent resource scopes"
kind: exec-plan
created_at: 2026-09-16T17:23:45Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:45Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Cascaded consequences of MasterPlan 23 API validation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T15:13:26Z
      mode: "implement"
      note: "Begin application and standalone data scope compilation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:33:40Z
      mode: "implement"
      note: "Guard complete database and broker renderer membership"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:38:00Z
      mode: "implement"
      note: "Bind accepted standalone databases to reviewed Service and worker deploys"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:29:37Z
      mode: "implement"
      note: "Bind accepted broker topics to reviewed workload dependencies"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:41:53Z
      mode: "implement"
      note: "Compose reviewed access contributions and central routes"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:47:34Z
      mode: "implement"
      note: "Add exact-precondition collection for retained access DomainMappings"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:22:40Z
      mode: "implement"
      note: "Review stateless server previews"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:28:16Z
      mode: "implement"
      note: "Bind preview PVCs and retained-volume recovery"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:34:18Z
      mode: "implement"
      note: "Conditionally collect preview PVCs after consumers"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:36:41Z
      mode: "implement"
      note: "Refuse direct writes to retained site PVCs"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:42:55Z
      mode: "implement"
      note: "Guard direct data operations after workload collection"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:45:56Z
      mode: "implement"
      note: "Check retained companions across database config changes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T03:02:54Z
      mode: "implement"
      note: "Add reviewed manual Task Job scope and conditional collection proof"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T12:10:38Z
      mode: "implement"
      note: "Route stable-ID manual Task runs through single-invocation reviewed execution"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T14:25:44Z
      mode: "implement"
      note: "Guard Pulumi apex and accepted hostname claims in direct CDN paths"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T16:03:38Z
      mode: "implement"
      note: "Add reviewed Google CDN DNS ownership and provider adapter for application and site scopes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T19:23:31Z
      mode: "implement"
      note: "Route accepted Service stop and restart through reviewed scope updates"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T03:38:24Z
      mode: "implement"
      note: "Refuse direct app deploy after inventory initialization"
---

# Route application and data lifecycles through independent resource scopes

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Application, database, broker, environment, storage, and task commands participate in the same ownership protocol without becoming part of a platform release. Updating one application preserves other applications and platform intent. Review includes all resources that execution will create, including helper-created credentials and backups.

Every supported application-side mutation is either a desired-scope update, a reviewed operational action against owned resources, or an explicitly declared controller delegation. There is no independent imperative path that silently changes ownership.


## Progress

Implementation evidence is recorded in the commits linked to this plan and in Surprises & Discoveries. Reviewed application, standalone web Service, and standalone worker scopes, standalone brokers with create-only logical topics, accepted topic-bearing workload bindings, accepted auth backend contributions and central routes, database members, OCI publication, and reviewed set/delete/merge/exact Runtime/Build/app-wide Preview environment and versioned Secret channels are working slices. M1 is complete for the reviewed Kubernetes path. M2 has reviewed Google per-host DNS ownership, a Cloudflare host/zone owner with an offline HTTP transport proof, a combined offline application transaction, and typed application/production-site Cloudflare submission. Combined provider proof and remaining publication/input integration are still open. The Cloudflare provider proof is offline only because no disposable zone is available. M3 and M4 still require reviewed operational/data commands and removal of direct mutation paths. Application, standalone web Service, and standalone worker retirement select accepted native identities and preserve retained resources. Final plan acceptance remains open until M2 through M4 close.

Reviewed application deploy also declares the per-Service release-history ConfigMap, carries forward accepted entries, and offers exact adoption of existing direct-deploy history. Supported static and server production site scopes now declare their Service, domains, release history, server PVCs, accepted runtime Secret dependencies, and supplied TLS Secret dependencies, with exact import of existing direct objects. Site rollback now selects a release from accepted private history and reviews the prior image publication without adding a history entry. Static and server preview deployment has a separate reviewed scope with four accepted overlay stores, exact adoption of existing direct static previews, and reviewed retirement followed by collection. Server previews bind distinct PVCs with explicit recovery for retained volumes. Delete-policy preview PVCs can be conditionally collected after their Service, while durable PVCs remain retained. Manual runs of accepted CronJobs now compile stable Jobs in independent scopes from exact saved native evidence; Job collection uses conditional deletion and background pod cleanup. Reviewed application hooks have per-tag Jobs with explicit affected-resource proofs. Server Build/Preview Secret references and other operational commands remain open.

Stable-ID `task run` now publishes, reloads, and applies its reviewed Job in one invocation; `--save-plan` remains available for separate inspection and apply. The direct timestamped route remains for tasks outside accepted inventory.
In initialized inventory contexts, live `task run` now requires that stable-ID reviewed route, even for a newly named CronJob. Direct `task delete --yes` refuses there until schedule retirement has an exact reviewed operation. The read-only run/delete previews remain available; uninitialized contexts retain the legacy commands.
An isolated CLI regression exercised the live application and Task refusals against an initialized context and verified that its inventory head remained byte-for-byte unchanged.
The same boundary now refuses direct live database and broker creation, deletion, and restart for new names. Reviewed create, restart, and retirement remain available. Direct database shell, backup, and restore and app-volume snapshot and restore also refuse after initialization while their reviewed operational forms are still pending.
Direct live env set/delete/sync and unversioned Secret set/delete now also refuse after initialization, including a newly named app. Reviewed env changes use `--reviewed` or a saved review; Secret changes bind a version.
Legacy app stop, restart, and delete and direct site rollback and static preview deletion now refuse in an initialized context if they cannot select an accepted reviewed scope. Accepted app stop/restart, saved app retirement, site rollback, and preview retirement remain available. The CLI regression covers twenty-eight live refusals with an unchanged inventory head.
Versioned `secret set`, `secret delete`, and exact `secret sync` now use the same one-invocation review service when no saved review directory is supplied; private native Secret bytes remain in the immutable evidence store. Unversioned direct writes remain guarded legacy routes.
`env set`, `env delete`, and merged or exact `env sync` can opt into the same one-invocation reviewed path with `--reviewed`; the existing `--save-plan` route shares its compiler. Unreviewed direct env writes remain guarded legacy routes.
Reviewed aggregate pre-deploy hooks now bind independent per-tag scopes with stable Jobs and typed completion operations. The caller must list every affected resource or assert no data effects; hook Jobs wait for their CronJobs, affected resources, and preceding hooks, and workloads wait for completion. Old hook scopes remain accepted across tags, while a changed hook under the same tag refuses. CDN and remaining command paths stay in M2 through M4.

Accepted standalone broker topics now support a saved review and separate apply for a change from one explicit retention value to another. The adapter binds the previous accepted declaration into private mutation bytes, checks live retention before `rpk topic alter-config`, and verifies the result. Partition, replica, broker-address, and implicit-retention changes still refuse; an uncertain update requires operator recovery. This closes one bounded topic update path while broader M2/M3 provider work remains open.

The direct Google CDN plan now treats the Pulumi backend policy as a shared platform contract: it lists only host DNS changes and refuses per-application TTL, cache-mode, or path-rule overrides. This removes the second writer to the shared backend; the remaining direct DNS write still needs a claimed address and guarded reviewed adapter before M2 can close.

The direct Cloudflare DNS path now requires a successful exact A-record listing before creation. It verifies an already matching proxied record and refuses an existing different record rather than issuing an unowned PATCH. The typed inventory now has a separate Cloudflare proxied A-record claim for each workload host and platform-owned cache ruleset and origin-TLS setting claims per zone. A zone grant fixes the TLS mode and authorizes host-specific cache contributions; composition keeps all hosts in one deterministic ruleset and rejects missing grants, routes, duplicate hosts, or duplicate zone owners. An offline reviewed adapter contract binds prepared writes to a prior physical identity and expected complete content and leaves uncertain mutations unresolved. Direct Cloudflare provision and purge now refuse when any zone is accepted or retained in the context, or a review transaction is active, because those direct actions affect whole-zone settings. The Cloudflare HTTP transport, accepted context/zone binding, CLI routing, and provider proof remain open, so M2 remains open.

A two-host recording Cloudflare transaction now takes app A's cache change through observation, planning, immutable review publication, admission, and apply. It writes the complete shared ruleset once; app B's resources are absent from the plan, and both app B's and the platform zone owner's accepted revisions stay fixed. The host A record remains independently owned. This proves the shared-owner journal path offline, not Cloudflare HTTP behavior.

The reviewed CDN executor now dispatches Google DNS and Cloudflare claims by resource ID in CLI planning, apply, and status. Cloudflare's HTTP transport checks the declared zone ID against `CF_ZONE_ID`, verifies its account against `CF_ACCOUNT_ID` with a zone read, parses exact DNS/rules/TLS observations, records provider ID and version in the private review, and rechecks old state before mutation. A fake HTTP provider proved record create/update and stale-version refusal, exact ruleset normalization, and wrong-account refusal; no Cloudflare request was sent to a real zone. A disposable in-memory inventory context took a combined app, Preview env channel, Runtime Secret channel, broker topic, platform BackendService, and Google DNS record through review publication and apply. A subsequent app Service update verified the topic without mutating it and left platform, broker, Preview, and Secret generations fixed. This is combined journal membership evidence, not a native broker/preview or live multi-provider run. Typed application and production-site deploy/rollback bind the accepted platform zone grant and origin IPv4, emitting host DNS claims and cache contributions. Nine focused Cloudflare tests passed for the offline proof selected in the Decision Log; a live Cloudflare mutation is intentionally outside M2 acceptance.

The full CLI suite passed 810 tests and the DSL suite passed 458 tests. After the final direct-path guard and adapter checks, seven focused Cloudflare tests, the executable build, Haskell style check, strict user-documentation validation, and diff check passed. No Cloudflare provider mutation was attempted.

The direct Google CDN path now marks the Pulumi-owned apex A record as a read-only reference, verifies its target before any per-host write, and never upserts it. Direct deploy, site, purge, and disable commands refuse globally claimed hostnames in accepted or retained inventory, including external platform claims and claims from another namespace. The 800-test CLI suite passed before the final external-claim check; seven focused tests, the executable build, Haskell style check, and strict user-documentation validation passed after it. This protects existing reviewed owners while M2's per-host DNS adapter remains open.

Direct Google host DNS now uses a successful exact-name A-record listing as the only proof of absence, creates only in that state, skips an exact current record, and refuses mismatched or unreadable records. Its old update argv is removed. Fourteen focused DNS tests passed; the reviewed per-host adapter remains M2 work.

Reviewed Google CDN application and production site scopes now declare one retained, hostname-specific Cloud DNS A record per DomainMapping. The record has a canonical project/zone/host claim and depends on both its route and an accepted platform Pulumi BackendService. A private adapter observes the exact record, creates only after confirmed absence, and submits the immutable review base's old-record deletion with the new record in one Cloud DNS change for reviewed updates. Reading that base revision keeps apply and resume bound to the same old precondition after the accepted head advances. The adapter waits for a pending change and exact target observation before completion. An existing unowned record refuses; uncertain writes stay unresolved, including an empty listing after a lost acknowledgement. Site rollback preserves the DNS declaration, and application retirement requires explicit retention decisions for both DNS and route. A recording application review executes all native members plus its DNS operation while preserving accepted platform, broker, Runtime Secret, and Preview channel revisions. A second composed application binds an accepted broker topic and Runtime Secret alongside CDN without exposing private Secret bytes. A disposable Cloud DNS zone in `tan-ng-labs` proved the real adapter's create, exact-old update, verification, and stale-old refusal; its record and zone were deleted. The combined broker/preview graph has not yet run against a disposable provider context, and Cloudflare ownership is still required before M2 can close.

The inventory planner now observes only resources selected by a scope change, effective shared-owner members changed by its contributions, required broker topics, and explicit bootstrap dependencies. An app A update no longer asks the unrelated app B or platform cloud adapter for observations; the operation builder uses the same selection so it does not repair or rerun unrelated members. Retained collection still observes its exact target. This advances the M4 isolation requirement but does not finish the command cutover or provider proof.

A recording transaction now takes that app A candidate through observation, review publication, admission, and apply with only a Kubernetes adapter registered. Its single effect is app A's resource ID; app B and the unrelated Pulumi scope retain their exact accepted revisions. The one-invocation command fixture now seeds both unrelated scopes in private context history and converges a new application with the same Kubernetes-only registry; five focused command tests passed. This proves command-service selection without cloud credentials or adapters; live CLI context selection remains open.

The disposable two-worker native review/resume fixture now also seeds accepted app B and Pulumi scopes. With only a Kubernetes adapter, it reviewed and applied app A, resumed a simulated lost acknowledgement without a duplicate native write, and kept both foreign revisions fixed. Eight focused resume tests passed against `k3d-nagare-inventory-ep148`, and the cluster was stopped afterward. This closes the selected-scope provider isolation check; full application membership and direct-path cutover remain open.

Direct aggregate `app deploy` now refuses in any context with initialized inventory history, including a newly named app. It checks before build or provider effects and directs the operator to publish an OCI archive with `app image-plan` and deploy with `--image-resource`. Single-Service, worker, static/server production, and static-preview live deploys now use the same initialized-store boundary; their image-free dry-run paths remain available. The executable build, Haskell style check, strict user-documentation validation, diff check, and 829 CLI tests passed for this boundary. Legacy deployment is still available before store initialization, and other direct command families remain M3/M4 work. EP-151 is complete, so its store dependency no longer gates the final cutover.

Accepted application and standalone Knative Services now route `app stop` and `app restart` through a one-invocation reviewed scope replacement. The compiler starts from accepted private native bytes, changes only the selected Service, and records a cluster-local or restart override while retaining the original config digest and sibling declarations. An explicit reviewed deploy compiles a fresh scope without the stop override. Unmanaged legacy Services keep the guarded direct command. The focused stop/restart regression, executable build, 815-test CLI suite, Haskell style check, strict user-documentation validation, and diff check passed. A recording journal test then proved that an interrupted stop resumes without a second write, a repeated stop plans no operation, and an explicit deploy plans the label removal. Live Knative provider validation remains open, so M3 remains incomplete.

Application OCI archive publication now uses the same one-invocation review service as deployment when `app image-plan` has no `--save-plan`; supplying it still writes a separate review. The artifact adapter refuses a remote tag whose digest differs from the reviewed archive, and execution reloads the immutable publication review. The executable builds; a live registry publication and integration of build inputs with this path remain M2 work.

Reviewed application, standalone Service, and worker deploy now accept a separately published image even when the typed config declares a Dockerfile or Nixpacks build. The accepted publication's destination and the explicit tag remain bound to the rendered workload. Build production and Build-channel input provenance are still outside the publication review, so M2 remains open.

Legacy `access portal sync` now refuses a direct Shomei write when either shared auth settings resource is accepted or retained. The same ownership guard protects direct Service/app deploy and delete. A context with no registered portal remains a read-only successful no-op. The reviewed application contribution path remains the managed way to change portal settings; direct access grant/revoke operations still need M3 routing.

Accepted database and broker `restart` commands now select their exact StatefulSet from accepted history and replace only its pod template restart annotation through the shared reviewed command service. They carry forward accepted credentials, PVCs, backup policy, Service, topic claims, and private native bytes for other members; `--save-plan` allows separate inspection and apply. Legacy workloads retain the direct restart route. Focused database and broker compiler tests passed, and the executable built. A disposable StatefulSet execution and the remaining data actions are still M3 work.

The restart compiler also verifies the database credential Secret or broker PVC in the same accepted scope, so a name shared with the wrong command family cannot authorize a restart.

A disposable `k3d-nagare-inventory-ep148` transaction then created a synthetic database credential Secret and zero-replica StatefulSet through the reviewed native adapter, published a second review containing only the StatefulSet update, applied its restart annotation, and observed it on the provider. Both test objects were removed and the cluster was stopped. This proves native restart transport and review selection, not a live database or broker pod rollout.

M1 completed for the reviewed Kubernetes lifecycle: application and standalone scope compilers bind the supported native members, accepted dependencies, explicit recovery and input choices, release history, scheduled tasks, and independent per-tag hook Jobs. The accepted-image dry-run, saved review, and one-invocation live route share those compiled declarations. At M1 closure, unsupported CDN and build publication inputs refused before mutation. The full CLI suite and a disposable native two-worker review/resume passed. Google DNS and the selected offline Cloudflare ownership proof have since advanced in M2; build/input integration and full native provider membership, reviewed operational/data actions in M3, and removal of direct render/apply paths in M4 remain required for final acceptance.

- [x] M1: Compile and execute reviewed application and standalone Kubernetes lifecycles for supported intent, with unsupported provider effects refusing before mutation.
- [ ] M2: Integrate shared-owner contributions, environment intent, and publication.
- [ ] M3: Route operational and data lifecycle commands through reviewed operations.
- [ ] M4: Remove duplicate render/apply paths and prove scope isolation.

Critical path from completed M1 to final acceptance, in execution order:

- [x] Bind the application, standalone Service, worker, database, broker, route, schedule, release, and accepted input dependencies to reviewed scopes.
- [x] Bind aggregate hooks to independent per-tag Job scopes, explicit affected resources, completion proofs, and workload ordering.
- [x] M2 CDN/DNS ownership (2026-09-25): Google application and production-site host records have reviewed claims, an exact platform BackendService reference, and disposable-zone provider proof. Cloudflare has separate host claims, platform rules/TLS owners, typed application/site submission, a context-bound reviewed HTTP transport, CLI review/apply/status dispatch, and nine focused offline provider tests. The Decision Log accepts offline Cloudflare proof because no disposable zone is available; no live Cloudflare mutation is claimed.
- [ ] Prove review and execution membership for a full application including a preview, CDN, broker topic, and Secret references against a disposable provider context. One disposable in-memory provider context passed the complete journal and apply flow, including independent scope generations after an app update; native broker/preview/provider integration remains.
- [ ] M4: Cut over remaining direct app render/apply entry points to the reviewed compiler and publication path.

## Surprises & Discoveries

2026-09-26: `cli/nagarectl/nagared/Main.hs` invokes `deployStaticProduction` and `deployStaticPreview` directly after a webhook checkout. It does not call the CLI dispatcher or know a selected inventory context, so the initialized-store guard on `site deploy` does not protect webhook deployments. M4 must give the webhook runner a context-bound reviewed submission or an explicit managed-context refusal before removing the last direct site path.

2026-09-25: The direct `access portal sync` path read the live backend map and rewrote Shomei settings without checking inventory ownership. The existing guard considered only the backend grant and retained backend map, so a retained or separately granted Shomei settings map could still be overwritten. The guard now covers both shared settings kinds and runs immediately before the sync write.

2026-09-25: The direct stop command patched only a Knative metadata label. Replaying an accepted deployment from its original native bytes would remove that label, so a reviewed stop must change the accepted Service declaration itself and record the operational visibility override. A restart must remove the label in the new native bytes and stamp the template to force a fresh revision. The reviewed action compiler carries forward sibling DomainMappings and private native members; a pure regression shows a second stop is identical and a restart changes only the Service member. Live Knative provider behavior still needs a dedicated probe.

2026-09-25: A recording Kubernetes adapter applied an initial Service, then returned an ambiguous result after applying the reviewed stop. Resuming the saved transaction observed the stopped digest and converged without another mutation. A later same-stop review contained no operations, while a candidate from the original explicit deploy contained one Service update to clear the override. The existing disposable `k3d-nagare-inventory-ep148` cluster lacks the Knative Serving Service CRD, so it cannot prove the live stop/restart provider path without a separate Knative bootstrap; it was returned to its stopped state.

2026-09-25: Cloud DNS accepted a uniquely named public zone under the reserved `.invalid` suffix in `tan-ng-labs`, so the live adapter proof required no delegation or existing zone changes. The explicit live test created an A record through the reviewed adapter, updated it by deleting the exact accepted old RRset, verified the new target, and refused a repeat update with the stale old value. Its cleanup removed the A record; only default NS and SOA remained before the disposable zone was deleted. This proves the Google DNS transport and precondition on one disposable provider zone, not the full multi-provider application transaction.

2026-09-25: The legacy Cloudflare find-or-create path interpreted any list response without a parseable first ID as absence, including an API error or malformed body, and PATCHed an existing record without an accepted old value. It now checks a successful exact-name list with at most one A record and verifies a matching proxied record without mutation; a differing record or unreadable list refuses. [Cloudflare's list API](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/list/) supports an exact-name filter. This change does not solve shared cache-rules ownership, and no disposable Cloudflare zone is available for a provider proof.

2026-09-25: Cloudflare's direct cache-rule PUT replaces the zone entrypoint while each site supplied only its own hostname rules. The inventory model now gives the zone phase one platform claim, composes host contributions from application and site scopes, and gives each proxied A record a distinct workload claim. A composed rules payload sorts hosts and emits broad defaults before more specific rules. [Cloudflare applies the last matching cache setting](https://developers.cloudflare.com/cache/how-to/cache-rules/order/), so the renderer reverses declared path rules to preserve the first declared matching path as highest priority. It [escapes quoted filter strings](https://developers.cloudflare.com/ruleset-engine/rules-language/values/) and rejects non-path or control-character prefixes. Offline tests prove two hosts survive an app-only update without advancing the platform or second app scope revision, and refuse forged route or owner requests. No Cloudflare zone/token is available for live testing; transport and command routing must be added before this model authorizes any provider write.

2026-09-25: The platform Cloudflare zone grant now composes a separate origin-TLS setting with an explicit mode; the complete cache ruleset waits for that setting. A recording Cloudflare adapter prepares create, verify, explicit exact adoption, and accepted-old update plans for the TLS setting, zone ruleset, and per-host A records. Its private plan binds the observed physical identity and old content, rejects a changed identity before apply, and never auto-recovers a mutation with an uncertain acknowledgement. A recorded app A cache update selects its shared ruleset and app A members without observing app B or unchanged TLS; the full review/journal/apply transaction writes only that ruleset and keeps the platform and app B accepted generations fixed. This is an offline contract; no Cloudflare HTTP transport, zone/account check, conditional provider write, or live proof is present.

2026-09-25: The HTTP transport now makes the owner contract executable for generic inventory reviews: it verifies zone/account before every resource read, observes exact DNS records and normalized complete rules, and binds updates to an observed provider ID and version. The reviewed CDN adapter routes both providers without observing the absent provider. Cloudflare's documented zone ruleset PUT and DNS overwrite APIs do not expose a compare-and-swap precondition, so an external writer can still race the final read and write; this is an inference from the documented request shapes, not a claim that the provider has no other concurrency mechanism. An unsuccessful or unreadable response after submission remains ambiguous. The user selected offline Cloudflare proof only, so no real zone was touched. A combined disposable in-memory context proved journal membership for app, Preview env, Runtime Secret, broker, and CDN, but its providers were recording adapters. The remaining typed Cloudflare compiler and native combined provider proof are concrete M2 work, not an open-ended wait for credentials.

2026-09-25: Host-only direct CDN guards were insufficient for Cloudflare: provisioning replaces the zone ruleset and TLS mode, while an empty-path purge clears the whole zone. The direct provision and purge handlers now refuse whenever a Cloudflare zone is accepted or retained in the inventory context, and during any active review transaction. This is deliberately context-wide until the direct route can resolve and prove an exact zone binding; it protects unrelated accepted host contributions from an unreviewed whole-zone write.

2026-09-25: A hostname is represented twice in the desired graph when a Google CDN site owns both its Knative DomainMapping and its Cloud DNS A record. Ordinary duplicate-claim validation rejected that honest pair. The composer now accepts exactly a same-owner DomainMapping and DNS pair with an explicit DNS dependency on the route; a third claim or different owner still conflicts. Retiring that app also exposed the planner's executor allowlist, so CDN retention and a recording retirement decision were added.

2026-09-25: The prior disposable application replay had no unrelated accepted owners. Adding a second application and Pulumi bucket scope to its private history did not add observation requirements or provider work: the Kubernetes-only registry still converged after an interrupted write, and both foreign scope revisions remained fixed. This is native provider evidence for scope isolation, though the fixture has two workers and release history rather than every M2 provider kind.

2026-09-25: The direct Google DNS path treated a failed `describe` whose diagnostic contained "not found" as an absent record, and updated any existing different record without an ownership receipt. A successful exact-name `record-sets list --format=json` can distinguish an empty result from a failed read. Direct host provisioning now refuses a mismatched existing record, while the future reviewed adapter can use [Cloud DNS atomic changes](https://docs.cloud.google.com/dns/docs/reference/rest/v1/changes/create) and exact old-record deletions for authorized updates.

2026-09-25: The existing app A isolation fixture stopped at pure operation selection. Extending it through the immutable review and transaction executor with no Pulumi adapter proved that unrelated cloud credentials are not required by those layers. It does not exercise CLI context setup, so a live command check is still needed before M4 completion.

2026-09-25: The existing one-invocation command fixture used an empty accepted history, so it could not detect accidental observation of a foreign scope. Seeding an unchanged application and a Pulumi bucket before the command proved that the command service can publish, reload, and apply one application change with only a Kubernetes adapter; both accepted foreign revisions remain byte-for-byte unchanged. The live CLI context and provider are still outside this fake fixture.

2026-09-25: The direct Google CDN planner accepted the base-domain apex as certificate-covered and then included it in the same `gcloud` upsert list as application hostnames, despite the apex being Pulumi-owned. It now emits an explicit reference, checks the live apex target before other DNS effects, and leaves the apex unchanged. The existing native hostname alias can protect direct commands across namespaces; its accepted and retained claims are now checked before direct CDN effects.

2026-09-25: A blank review directory is a valid parsed option value, so using an empty string as the one-invocation marker could have turned `--save-plan ''` into an apply. Manual Job, env, and Secret command helpers now carry an explicit optional directory and only apply when it is absent.

2026-09-25: Both direct database backup and restore used a recursive local `name` binding while constructing their Job name, source/target address, and credential reference. Evaluating either live command could diverge before submitting a Job. The legacy paths now keep the database identity separate from the Job identity and retain the timestamp plus a database-name digest in long native Job names. Reviewed backup and restore operations remain M3 work.

2026-09-24: The existing database builder already binds all five retained-database members, including the credential template and backup CronJob, to canonical native bytes. Standalone and application database compilation now consume it without reconstructing database flags. The application preview used the old four-object render path; it now displays the data-free credential template and backup. The Knative Service, PVCs, and automatic-TLS domains bind to their rendered native bytes. Remaining workload declarations and command routing are open. Existing config literals must initialize the new optional keys explicitly because their records have strict fields.

2026-09-24: A service volume's existing PVC render stamped `nagare.dev/app` with the service name, which differed from the application aggregate's shared label. The aggregate stamper previously refused any preexisting differing label. It now replaces only the top-level app label before native binding; a retained PVC requires explicit recovery intent. This is why preview labeling and inventory compilation must consume the same rendered object.

2026-09-24: Automatic-TLS DomainMappings can join the same service bundle with a `Hostname` alias claim, so two scopes cannot silently route one hostname. A supplied TLS Secret is supported by the legacy renderer but lacks a typed resource/capability dependency in this component; compilation refuses that case until the dependency is supplied rather than assuming the namespace-local Secret is ready.

2026-09-24: The application loader sorts workers by name, so worker resource identity must derive from each worker's validated name or pinned logical key rather than list position. Each worker PVC uses a role that includes its worker key, preventing two workers' equal volume names from sharing a recovery grant.

2026-09-24: The current Task render describes a CronJob, while running a pre-deploy migration creates a separate Job with unknown data effects. The CronJob can be a native declaration now; managed hook execution still requires a reviewed operation with affected resources and recovery semantics.

2026-09-24: Component builders alone cannot establish a complete application review. `compileApplicationScope` now combines their declarations and retained native bytes, validates identities and provider claims across components, and refuses application broker/access plus service task/access/CDN fields until those ownership paths exist. This is a supported-subset scope builder, not a command cutover.

2026-09-24: The Redpanda renderer's direct Kubernetes membership is three objects. Broker topic creation currently happens later through `rpk`, so a broker with topics cannot be considered fully declared by those three objects; the standalone compiler refuses such input until the topic operation is reviewed.

2026-09-24: A co-located task can carry an `app` association that differs from the containing Application while the aggregate renderer still stamps the containing app's label. Aggregate validation now rejects that mismatch before declaration or preview.

2026-09-24: RolloutEnv is currently assembled outside the typed intent channel. Without a match check, its env map could inject values into native workload bytes that the Application did not declare. The supported-subset compiler now requires equality with the Application's env channel and refuses Secret references until a typed external or owned dependency is provided. Separately managed env inputs remain M2 work.

2026-09-24: The inventory executor marks subprocesses with `NAGARE_INVENTORY_TRANSACTION`; only the old database create command refused re-entry. App deploy and broker create now reject that marker before loading input or provider work, preventing an adapter from indirectly invoking a second imperative mutation path.

2026-09-24: Both the database and standalone broker builders paired roles with rendered objects using `zip`, which silently discards unmatched tail members. They now check the complete renderer cardinality first. This closes one path for a future renderer change to produce an unclaimed native member, but it does not establish command-path parity or finish M1.

2026-09-24: The database adapter bound each native member to a declaration but then built a `Map` without proving equal membership. A duplicate ID could collapse during that conversion. Binding now compares the exact declaration and native ID sets and counts before returning private execution bytes.

2026-09-24: The shared namespace composer already enforced owner grants, but the application scope compiler had no way to submit a request. An optional owner input now emits `RegisterNamespace` only after checking that its generated ID equals the Namespace ID used by application workloads. An offline composed candidate proves that the platform's accepted scope revision remains fixed, and missing grants refuse. Application command construction and other shared contributions remain open.

2026-09-24: The application Service binder already bound exact rendered bytes for Service, PVC, and DomainMapping members, but it minted IDs in an application scope. Extracting its member binder lets a standalone Service use the same declaration path with its own stable scope. The wrapper requires matching rollout identity and no undeclared shared app environment; it still has no public command cutover.

2026-09-24: DomainMapping IDs previously derived only from the hostname, so a hostname change could not preserve logical identity even when the operator intended a reviewed migration. DomainSpec now carries an optional logical key in config JSON. The unpinned path keeps the previous hostname-derived ID; pinning a key retains the ID, while EP-149 must still authorize any changed provider address.

2026-09-24: Composing a platform scope and two simple application scopes confirmed the existing omission rule at the application boundary: replacing one app leaves the other app and platform at their accepted generations. Giving the changed app the other app's Knative Service name fails the shared address claim check. This validates the compiler's isolation behavior but does not exercise legacy deploy command migration.

2026-09-24: The standalone database builder was adapter-ready but had no public reviewed entry point. `db create --save-plan` now shares the typed input resolver with direct create and composes one standalone scope against accepted context history. The command requires explicit recovery policy and credential key version; composition refuses missing platform dependencies. Applying the saved review is a separate `inventory apply --yes` step. This is a first routed path, not full operational-command migration.

2026-09-24: Broker and database renderers omitted discovery annotations and their direct create paths stamped them after applying the StatefulSet. Reviewed execution cannot perform an unreviewed follow-up annotation, so both renderers now include the annotations in the StatefulSet object. Direct create uses those same bytes and no longer issues separate annotations. Topics still refuse reviewed broker planning because they require typed logical operations.

2026-09-24: The generic retirement planner loads immutable accepted native evidence and `RetireScope RetainResources` performs no provider deletion. The domain retire commands use it only after proving that the selected standalone scope contains exactly one matching StatefulSet in the requested namespace. An explicit scope key handles a pinned logical identity after a display-name rename; missing or mismatched accepted scopes refuse before review publication. Reviewed native deletion requires a separate collection capability and remains open.

2026-09-24: The platform-database isolation fixture exposed a generic inventory claim gap: `validateGraph` indexed only managed declarations when checking provider-address collisions. External declarations already had canonical claims but were omitted from this map. Including them makes a platform external database address unavailable to an application-managed StatefulSet. Observed controller children remain excluded because they intentionally inhabit their parent's derived reservation.

2026-09-24: Supplied TLS rendering already carried the Secret name in the DomainMapping but the inventory builder refused the entire case. The builder now takes the exact managed or external Secret declaration, checks its cluster/namespace/name address, and adds its ResourceId as a dependency. It rejects unused bindings and observed children. Command routing still must source that declaration from accepted history; a caller-supplied name alone is not authority.

2026-09-24: Secret-backed runtime env has the same authority gap as supplied TLS. The application compiler now accepts exact typed Secret bindings and adds dependencies to every workload that inherits or declares the reference. It still refuses build and preview Secret scopes because Kubernetes runtime readiness cannot prove build-time secret publication or preview-overlay intent. Command routing must obtain bindings from accepted history, not caller-provided names.

2026-09-24: The application database compiler already supplies a password-free credential Secret in the same candidate. Runtime env references to that Secret now use the owned declaration directly; external Secret bindings are required only for names not owned by the application. This preserves the distinction between application-owned credential lifecycle and an accepted Secret in another scope.

2026-09-24: Reviewed standalone Service and worker deploys now accept database names only when one accepted standalone scope owns the matching Service, StatefulSet, and credential Secret. The command loads their original private native review, and the resolver verifies the credential template's engine against the saved Service and StatefulSet labels. Workloads receive typed StatefulSet ordering, connection fields, and Secret references without a live name lookup. Missing history, native evidence, changed namespace, and duplicate bindings refuse. Offline composition of either workload preserves the database scope's accepted generation; complete M1 still needs logical topics and the other unsupported resources.

2026-09-24: Standalone Redpanda topics now enter the broker scope as typed durable logical resources with canonical broker/topic claims, retained recovery policy, and a dependency on the StatefulSet. The new broker adapter uses guarded `rpk topic list`, create, and describe against the exact compiled broker target. Planning sees a topic already present without accepted history as unowned; creation requires confirmed absence, and changed settings or an uncertain create acknowledgement refuse automatic reconciliation. The installed rpk 26.2.3 description and metadata output expose settings but no stable topic ID, so the transport's physical marker includes the broker StatefulSet UID and topic name; a delete/recreate of a topic inside the same StatefulSet cannot be proved from that marker. Topic-bearing workload bindings, updates, and reviewed deletion remain open, so M1 and M3 stay open.

2026-09-24: Reviewed Service, worker, and application compilers now resolve every requested topic to an exact accepted standalone broker claim. They inject the existing topic environment values and depend on the broker Service and topic ResourceIds. A changed consumer scope verifies an unchanged accepted topic in its saved plan before creating its workload; missing or unaccepted topic evidence refuses compilation. Topic update, deletion, and the remaining application resource and command paths keep M1 and M3 open.

2026-09-24: The direct access resolver changes both a platform-auth backend ConfigMap and a DomainMapping in `nagare-system`; declaring only the shared map would leave a provider write outside the review. The application and standalone Service compilers now require one accepted auth owner with backend and Shomei grants plus the exact enforcer Service. They add an owner-composed `RegisterBackend` contribution and claim the central DomainMapping, including the default host when no custom domain is declared. The route depends on the enforcer and backend map, and portal routes also depend on Shomei settings. Direct Service/app deploy and app delete refuse their legacy resolver when the auth owner is accepted or its map is retained. Supplied TLS, CDN, other direct-path cutover, and explicit ownership migration for a legacy central route remain open.

2026-09-24: Reviewed app retirement retains its central access DomainMapping. Kubernetes collection now supports that stateless kind through a namespaced serving API DeleteOptions request with UID and resourceVersion preconditions. The decision and tombstone remain separate from retirement; a route cannot disappear through a name-only delete. On the disposable `k3d-nagare-inventory-ep147` context, an isolated `serving.knative.dev/v1beta1` DomainMapping under a unique temporary namespace refused a stale resourceVersion delete, remained at the same UID, then accepted the exact UID/resourceVersion DeleteOptions request and disappeared. The temporary namespace was deleted. This proves the native conditional deletion form; an end-to-end retained inventory collection of this kind remains open.

2026-09-24: A retained central DomainMapping can be unready when its origin is gone. The collection planner already classified an owned unready object with matching bytes as present, but Kubernetes mutation preparation rejected it. Conditional collection now accepts that unready state only for an exact owned UID, nonempty resourceVersion, and matching native digest; stale resourceVersion preflight still refuses. A recording regression covers the complete adapter operation. Creation and declared Job verification continue to require readiness.

2026-09-24: The legacy application/static release-history reader treated every nonzero `kubectl get` as an absent ConfigMap. A permission, context, or transport failure could therefore turn a later deploy into a fresh empty log. It now uses `--ignore-not-found`, accepts only a successful empty response as absence, and returns an error for all failed reads. A regression keeps an existing log from being interpreted as empty on failure. Full reviewed release metadata declaration and import are still open.

2026-09-24: Reviewed application deploy now requires a release-history ConfigMap bound to its stable application scope ID, using the web Service's legacy subject name even when the aggregate has a different name. The compiler checks the release tag, image, URL, and namespace against the rollout; the resource waits for all workloads. Accepted prior entries come from the immutable private native review, with malformed or missing history refused. The legacy reader also refuses a present ConfigMap without its history key. An existing direct ConfigMap without accepted ownership is treated as unowned, so its entries require explicit adoption before the first reviewed deploy. Static-site metadata and that import remain open.

2026-09-24: The reviewed standalone Service deploy path used the same direct per-Service history writer but did not declare that ConfigMap. It now includes a history member in the standalone scope, waits for the Service and scheduled tasks, and loads accepted prior entries from private native evidence. The direct path refuses the managed history address even after the Service is absent. Existing legacy logs still require an exact import; static and server site histories remain outside reviewed scopes.

2026-09-24: The direct aggregate rollout executes `Application.tasks` as pre-deploy hooks before any database or workload change, while the reviewed compiler had only declared their CronJobs. That could advance a reviewed workload without running a required migration. The application scope now refuses nonempty aggregate tasks until reviewed Job operations carry their effects and completion proof. Service-attached scheduled tasks still compile as CronJobs. The fixture checks this refusal and composes its supported scope with the aggregate hook list removed.

2026-09-24: An existing direct release ConfigMap cannot enter a normal reviewed deploy because the planner sees it as unowned. Both reviewed app and standalone Service commands now accept a private full-ConfigMap snapshot plus a versioned exact-incarnation adoption proposal. The import uses the old current release and its unchanged log as candidate content, checks its tag and image against the selected rollout, requires that the proposal include the release member and only unowned members of the selected scope, and sends it through the normal adoption reviewer. The Kubernetes adapter requires matching live content digest, UID, and resourceVersion before its conditional ownership patch; a later ordinary review reads the accepted private log and records the next release. This is a supported-subset import: a changed live log, mismatched app config/image, unreviewed hook, or other unmatched live resource refuses. Static/server site history import remains open.

2026-09-24: The legacy direct Secret dry-run printed the exact apply-able Secret manifest, including reversible base64 values, even though the reviewed inventory path keeps native values private. Direct dry-run now emits only the selected Secret's name, namespace, and keys. It does not claim to be an apply-able manifest. The public preview regression checks both plaintext and base64 canaries.

2026-09-24: Static-site production rendering already returns exact Knative Service and DomainMapping bytes. A new static-site scope binds these native objects plus the per-site release ConfigMap to an accepted prepublished OCI image and Namespace. `site deploy --save-plan` compiles the scope with the existing renderer and preserves accepted private release history; missing foundation/image authority, CDN, supplied TLS, or unowned direct objects refuse. The direct path remains for server sites, static-site previews, rollback, and initial image preparation. This advances M1 but does not complete site migration or M4.

2026-09-24: Existing direct static sites need the same exact-incarnation adoption as direct application releases. `site deploy --save-plan` now accepts a full legacy release ConfigMap and versioned proposal covering its unowned release member and any other current site members. The importer preserves the old ordered log and selected image/tag, while the common reviewer checks content and physical identity before conditional ownership patches. Subsequent reviewed deploys read accepted private history. Server-site history import remains open.

2026-09-24: Static and server sites use the same release ConfigMap, Service address, and DomainMapping ownership protocol. The production server render now feeds the shared site member binder, and direct and reviewed server deploys share generated identity environment assembly. `site deploy --save-plan` supports stateless server sites with literal env, automatic TLS, and no CDN. Existing server sites can import the old log and current native members through the same exact adoption review. Server volumes and Secret references remain refused until they have typed recovery/dependency inputs, and previews/rollback remain direct.

2026-09-24: A site scope named `site-<name>` under the Application kind could collide with an unrelated application literally named `site-<name>`. Site scopes now use the Standalone kind, keeping their stable resource IDs separate from application scopes even when display names overlap.

2026-09-24: The server-site renderer has a separate `renderServerVolumeClaims` path that its direct deploy does not include in `ServerManifests`. Reviewed server scope compilation now binds every rendered PVC as an explicit member, orders the Service after them, and requires exact `VOLUME=BACKUP:KEY:VERSION` recovery inputs for retained claims. This avoids treating volume-bearing server sites as complete when only their Service and domains were reviewed. Direct server deploy parity remains a separate M4 cutover concern.

2026-09-24: Runtime `EnvSecretRef` values in server sites now require exact accepted Secret bindings. The compiler checks each binding's cluster, namespace, name, and declaration kind, then orders the Service after those ResourceIds; missing and extra bindings refuse. Build and Preview Secret references remain unsupported because their publication/overlay semantics are not the runtime Secret dependency.

2026-09-24: Static and server site production scopes now accept supplied TLS only with an exact accepted Secret declaration for each referenced name. The shared binder checks cluster, namespace, and Secret identity, rejects missing or extra bindings, and orders each DomainMapping after its certificate Secret. The site review command resolves `--tls-secret-resource` through accepted history; CDN, previews, and rollback remain open.

2026-09-24: Direct site deploy, rollback, and preview commands previously checked only the Knative Service address. A collected Service could leave a retained release ConfigMap, and a changed site name could still target another scope's DomainMapping. Direct site guards now check every Service, domain, and release-history address they write against accepted and retained history before provider mutation. Reviewed preview and rollback operations remain open.

2026-09-24: Reviewed site rollback now reads only accepted private release history, verifies that the selected release exists without inventing or reordering entries, and binds its tagged image to an accepted OCI publication. Static and server compilers rebuild the same native scope with the old tag and a changed `current` pointer, preserving the accepted source root. Server retained PVC recovery and runtime/TLS Secret bindings remain explicit. A changed site image or URL refuses rather than silently replaying an older tag under a different site config. Site previews, CDN, and reviewed operational actions remain open.

2026-09-24: Static preview rendering always injects optional references to four Runtime/Preview ConfigMap and Secret stores. A reviewed preview cannot safely omit their authority, since a later store creation would change the workload without its review. The new standalone preview scope binds its Service and one automatic-TLS DomainMapping to a prepublished image, accepted Namespace, and all four exact accepted store identities. Missing, duplicate, or differently addressed stores refuse. Direct previews remain guarded, while preview retirement, existing-preview adoption, and server previews remain open.

2026-09-24: Preview delete now selects only an accepted scope containing exactly the expected stateless Knative Service and DomainMapping, and saves a retirement review that preserves both native members. A second `inventory collect` review conditionally deletes their exact retained incarnations. The collection policy and Kubernetes transport now cover the Knative `serving.knative.dev/v1` Service path with UID/resourceVersion preconditions, alongside the already supported DomainMapping. On the disposable `k3d-nagare-inventory-ep147` context, a unique temporary Knative Service refused a stale resourceVersion delete and accepted an exact UID/resourceVersion DeleteOptions request; both probe namespaces were removed. One first attempt used an earlier valid resourceVersion and correctly conflicted after the controller updated the Service, showing that a review must be refreshed after such a race. End-to-end retained inventory collection and existing-preview adoption remain open.

2026-09-24: Existing direct static previews may already occupy the new preview Service and DomainMapping addresses. Reviewed preview deploy now accepts a versioned exact-incarnation adoption proposal under candidate `.` and confines every target to a distinct unowned member of that one preview scope. The common adoption planner still checks live bytes, UID, and resourceVersion before conditional ownership. This path does not invent a production release or adopt unrelated site resources.

2026-09-24: The server renderer already understands a preview Service name but the CLI had no server-preview route. Reviewed stateless server previews now render that name and automatic-TLS domain with the same Runtime/Preview overlay stores as static previews. Generated identity environment uses the preview name and URL. The compiler binds any Runtime Secret references to exact accepted Secrets and refuses volumes and Build/Preview Secret references until they have distinct claim/publication inputs. Preview list and delete now accept either site kind; direct preview deploy stays static-only.

2026-09-24: Server preview volumes now render PVCs under the derived preview Service name in the same scope as its Service and domain. Retained volumes require explicit recovery intent; delete-policy volumes use the existing stateless claim policy. Reviewed preview retirement checks the exact PVC addresses as well as Service and domain before retiring the scope. The native adapter cannot collect PVCs yet, so retired claims remain visible pending that capability. Direct server preview deletion refuses rather than leaving unreviewed claims behind.

2026-09-24: The guarded Kubernetes collection transport now admits only delete-policy stateless PVCs, using the same exact UID and resourceVersion DeleteOptions as other collected kinds. A disposable PVC passed create, conditional collection, and absence verification. Durable PVCs remain uncollectable. Collection screening counts retained consumers, including members selected in the same review; preview removal therefore collects DomainMapping, then Service, then an eligible PVC in separate reviews.

2026-09-24: Direct server deploy now checks every rendered PVC address against accepted and retained inventory history before calling its legacy volume creator. This closes the case where the reviewed Service and domain were already collected but a retained volume still occupies the direct deploy target. The guard does not block unrelated volume names.

2026-09-24: Legacy database and broker operations that receive only a native name now check their full possible companion-address sets in accepted and retained history. They refuse even when the StatefulSet was collected but its Service, credential, backup CronJob, ConfigMap, or PVC remains. The typed database/broker selector is shared by restart/delete and the database shell, backup, and restore paths; reviewed operation routing is still open.

2026-09-24: Direct database and broker create now reuse that same complete native-address selector. In particular, a new database config with Delete retention still refuses an older retained backup CronJob, and an engine change cannot overlook a retained configuration object at the same name.

2026-09-24: The legacy env and Secret store reader had the same failed-read-to-empty behavior. Its JSON extractor also silently dropped any `data` entry whose value was not a string, contrary to its strictness comment. Both stores now accept only a successful empty `--ignore-not-found` response as absence; failed reads, non-object `data`, and non-string values refuse before a merge or exact replacement. Disposable-context reads of absent ConfigMap and Secret names both exited successfully with empty output, and 785 CLI tests pass. The reviewed channels still need complete preview/deploy integration.

## Decision Log

2026-09-26: Apply the initialized-context boundary to remaining direct application actions that already have reviewed counterparts. Accepted Service stop/restart select their reviewed scope; unaccepted names cannot direct-patch. App deletion, site rollback, and static preview deletion require their saved reviews after admission. This keeps direct legacy behavior in uninitialized contexts without letting a fresh name bypass inventory.

2026-09-26: Require the reviewed environment and versioned Secret channels for every live write after inventory initialization. The previous native-address guard protected accepted stores but let a newly named store bypass the channel revision, private Secret evidence, and review journal. Keep direct dry-run output and the legacy uninitialized-context route.

2026-09-26: Extend the initialized-store cutover to data command fallbacks. A native-address check cannot authorize a new, unreviewed StatefulSet, backup Job, maintenance shell, or snapshot in a context already using inventory. Keep direct commands for uninitialized contexts and read-only dry-run forms where provided. Manual backup, restore, maintenance, and deletion still require reviewed operations; this refusal is an intermediate safety boundary, not M3 completion.

2026-09-26: Use inventory initialization as the boundary for direct Task Job submission and schedule deletion. A timestamped manual run has no stable retry identity, and direct CronJob deletion has no reviewed lifecycle decision. Require the accepted-CronJob `--run-id` route for live runs; refuse live deletion until schedule retirement is implemented. Plan-only and dry-run output remain available.

2026-09-26: Treat inventory store initialization as the direct application, Service, worker, and site deploy boundary. The earlier native-address guards allowed a new name to perform unreviewed namespace, credential, route, and workload writes in a context already using inventory. The reviewed OCI archive and accepted-image deployment route is available there; keep live legacy deployment only for contexts without initialized history until build input publication and the other command cutovers close. Read-only offline dry-runs remain available.

2026-09-25: The operator selected offline-only Cloudflare proof because no disposable Cloudflare zone is available. M2 will use a fake HTTP provider and complete reviewed journal transaction for Cloudflare acceptance; live Cloudflare mutation is deferred and will not hold this milestone open. This does not relax the requirement for typed host/zone ownership, stale-state refusal, uncertain-write recovery, and honest documentation of the external-race limit.

2026-09-25: Represent Cloudflare's `http_request_cache_settings` entrypoint as one platform-owned `CloudflareRuleset` resource per zone, derived from granted host contributions. The same platform zone grant fixes a separate origin-TLS setting; the ruleset waits for it. Each workload owns its own `CloudflareDnsRecord` and DomainMapping, and references the shared ruleset. The ruleset declaration and complete sorted rule payload are composed from accepted scopes; a workload cannot submit a replacement whole-zone ruleset. This follows the [provider's guidance to update a whole ruleset in one operation](https://developers.cloudflare.com/ruleset-engine/rulesets-api/). The offline adapter requires old content and physical identity at preflight, but provider serialization, conditional writes, and uncertain-write recovery still need an HTTP transport and proof. This is an architecture choice and offline model, not a claim that the provider mutation is ready.

2026-09-25: Route Google DNS and Cloudflare through one `CdnExecutor` adapter selected by resource ID, because the inventory registry permits one adapter per executor. The Cloudflare runtime requires `CF_ZONE_ID` and `CF_ACCOUNT_ID` to match the reviewed claim and provider zone response, and rechecks complete old content, provider ID, and version immediately before writes. Generic inventory plan/apply/status uses this path; typed application/site submission binds the accepted zone grant separately. The journal serializes Nagare's writes within one context, while a provider that does not expose an atomic old-value precondition still allows an external race. Preserve uncertain outcomes as unresolved rather than retrying a whole-zone PUT.

2026-09-25: Bind each reviewed Google host A record to its application or production-site scope, while retaining the load balancer BackendService in the accepted platform Pulumi scope. The route and DNS record share a hostname claim only as an ordered same-owner pair. Cloud DNS provides an atomic additions/deletions change but no independent RRset incarnation in this contract, so updates delete the exact accepted old RRset and ambiguous create/update acknowledgements require operator recovery. Even an empty record listing after a lost create response cannot prove that a pending change will not later commit. Stateless DNS operations use `VerifyBeforeRetry`; retirement retains the record and address until a separate collection capability is defined. This implements the earlier Google adapter direction below, pending a disposable-zone proof.

2026-09-25: Until M2 binds per-host Cloud DNS to a reviewed owner and exact provider observation, direct Google CDN provisioning is create-or-verify only. An existing different A record requires the reviewed path; a failed listing cannot authorize creation. This removes an unreviewed ownership transfer while preserving initial direct provisioning.

2026-09-25: Recut M1 to the reviewed Kubernetes application and standalone lifecycle it actually owns. The previous M1 exit wording required CDN work already assigned to M2 and direct-path removal assigned to M4, so it could not close in dependency order. This change preserves CDN, publication, full provider membership, data actions, and direct-path removal as final plan acceptance; M1 completion does not claim those effects are implemented.

2026-09-25: CDN requires an owner protocol before an adapter can replace the direct provisioner. The [Cloudflare DNS update API](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/edit/) documents patching a record but does not document a conditional write parameter for record content; [Cloudflare ruleset guidance](https://developers.cloudflare.com/ruleset-engine/rulesets-api/) warns against concurrent updates to one ruleset and recommends updating the whole ruleset in one operation. This is a source-based inference about the documented API, not proof that conditional DNS writes are impossible. M2 must establish provider-specific serialization, physical identity, and recovery before claiming these effects. The standing Google backend remains a Pulumi/platform-owned shared resource.

2026-09-25: The older CDN deployment contract allowed each site to run `gcloud compute backend-services update` against the same Pulumi-owned Google backend. This could overwrite another site's cache settings and be reverted by a platform apply. The direct planner now accepts only the standing Pulumi policy and does not emit a backend update. Per-host Cloud DNS records remain direct and must move to explicit claimed ownership; the Pulumi-owned apex record must be referenced rather than mutated.

2026-09-25: Scope isolation must apply to observation and operation selection together. The planner previously observed and classified every accepted managed resource for any scope replacement; app-only changes could therefore require cloud credentials or repair another owner's drift. Selection now includes the replaced/retired scope's members, changed effective declarations, contribution targets, broker topics required by new consumers, and bootstrap dependencies. The composer still checks the complete inventory for claim conflicts without observing unrelated providers.

2026-09-25: For future reviewed Google DNS changes, prefer the [Cloud DNS `changes.create` method](https://docs.cloud.google.com/dns/docs/reference/rest/v1/changes/create), which documents an atomic record-set collection update with explicit additions and deletions plus a client operation ID. A reviewed per-host adapter can bind an exact old record set and requested new record in one change, then verify the resulting record. This is an implementation direction, not current provider proof; exact mismatch behavior and recovery after a lost response still need a disposable-zone test before enabling live reviewed DNS mutation.

2026-09-25: Supersede the blanket topic-update refusal below for one bounded operation. The [Redpanda `rpk topic alter-config` reference](https://docs.redpanda.com/streaming/current/reference/rpk/rpk-topic/rpk-topic-alter-config/) supports changing `retention.ms` in place. Only explicit-to-explicit retention changes with the same accepted broker, topic address, partitions, and replicas receive this capability. A saved review and separate apply are required because shortening retention can delete data. Live old-value mismatch refuses before mutation; a lost acknowledgement does not auto-retry because the broker-scoped physical address is not a topic incarnation proof. Other topic changes remain refused.

2026-09-25: Each aggregate hook owns a separate release-tag scope. An application revision references its completion operation, but replacing that revision does not retire earlier hook Jobs. A same-tag change to the Job or affected set refuses; the next tag creates a new operation identity. Application-local databases can be named in the CLI, while other effects use exact resource IDs.

2026-09-16: Preserve separately submitted environment/secret intent across configuration deploys. Inputs are explicit versioned intent channels composed into one owner declaration, not live cluster data silently copied into desired state.

2026-09-16: App-only deployments can update their authorized contribution to shared routing configuration, but cannot replace the platform-owned resource or advance the platform release.

2026-09-16: Interactive administrative shells cannot be represented as read-only commands. Journal a scoped maintenance session with bounded resource authority and re-observe afterward; arbitrary SQL effects remain explicitly unknown until reconciled.

2026-09-24: Give the Application aggregate an optional logical key as well as its contained resources. The aggregate owns the ScopeId, so a display-name change needs a pinned scope key to retain accepted history; absent a key, the current name remains the backward-compatible default. This is an extension of ADR 22's resource identity rule.

2026-09-24: Require an explicit owner scope for application namespace contributions and bind the request to the exact Namespace ResourceId used by its workloads. Rationale: a custom namespace belongs to the shared owner, while an application may also consume an existing Namespace without requesting a new one; neither case grants the application lifecycle ownership of the Namespace.

2026-09-24: Resolve a standalone database connection's engine from the accepted private credential template and check the other native members against it. Rationale: a live label or caller-provided engine would not be bound to the reviewed scope revision, and the full typed database input is unavailable when a separate workload is deployed.

2026-09-24: Treat `rpk` topic observation as configuration evidence and broker-scoped location evidence, not an independent Kafka topic incarnation proof. Rationale: the installed CLI reports no stable topic ID in `topic describe` or `cluster info`; adoption by name and automatic recovery after an uncertain create could take authority over unrelated data. Retain topic claims on scope retirement, refuse in-place mutation and collection, and require a stronger provider capability before those actions are offered.

2026-09-24: Keep each protected DomainMapping in its application or standalone Service scope even though its native namespace is `nagare-system`; compose only the backend and Shomei ConfigMaps under the platform auth owner. Rationale: route deletion and lifecycle must follow the workload's reviewed scope, while two applications cannot replace the shared auth settings. Require the accepted owner grants and enforcer identity before a route can be declared.


## Outcomes & Retrospective

M1 complete for the reviewed Kubernetes application and standalone lifecycle. Stable identities, accepted data and broker bindings, auth contributions, release history, environment and Secret references, and per-tag hook scopes are compiled into reviewed declarations. Reviewed Google CDN host DNS has explicit ownership for applications and production sites; Cloudflare has offline host/zone/TLS ownership, an HTTP adapter contract, and typed application/production-site submission, while live Cloudflare validation and unsupported build intent remain open. The 810-test CLI suite, 458-test DSL suite, disposable two-worker native review/resume, and one live Cloud DNS adapter create/update/stale-old proof passed. A bounded reviewed topic retention update is implemented. The overall plan remains in progress: M2 publication and full provider membership; M3 data and operational actions; and M4 direct-path removal and full scope-isolation proof remain open.


## Context and Orientation

Hard dependencies are [cloud/artifact adapters](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [cluster components](147-compile-cluster-bootstrap-into-owned-resource-components.md), and [lifecycle policy](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), which themselves depend on the typed inventory and durable executor. They provide canonical context/scope/resource identity, opaque review boundaries, typed publication outputs, a complete database declaration builder, guarded Kubernetes execution, owner-composed contributions, and identity-bound adoption/retirement.

cli/nagarectl/src/Nagare/App/Deploy.hs has renderAppObjects, renderPlan, liveDeploy, livePhaseExec, ensureDatabase, and runHooks. Its current database render path omits credentials and backup CronJobs that live creation adds, and reconstructs flags from a richer Database value. Database/Create.hs, Broker/Create.hs, Env/Store.hs, App.hs, Task/Run.hs, Task/Delete.hs, Storage/Snapshot.hs, and Storage/Restore.hs contain independent mutations. Worker/Deploy.hs, Static/Deploy.hs, Server/Deploy.hs, and app/Main.hs supply additional deployment paths.

Access/Resolve.hs writes shared auth backend configuration and shomei settings. Cluster/Namespace.hs applies namespaces from multiple callers. Cdn/Provision.hs and Cdn/Cloudflare.hs mutate DNS/CDN resources, so application scopes are not exclusively Kubernetes scopes. Broker/Topic.hs manages logical Kafka topics through rpk. App/Deployments.hs writes release metadata. These resources all belong in declarations or reviewed operations.

[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) protects hostname claims and separate TLS readiness. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) excludes private material from payloads. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) establishes independent scopes and delegation. Preserve [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) for application cloud mutations.


## Plan of Work

### M1 — Application and standalone declarations

Add cli/nagarectl/src/Nagare/Inventory/Application.hs and DataService.hs, backed by pure builders in cli/nagare-dsl/src/Nagare/Resource/Application.hs and Broker.hs. Reuse Resource/Database.hs from EP-147. Feed the validated application/database/broker values through these builders for supported Kubernetes intent; provider effects whose owner is not yet modeled, especially CDN, refuse until M2 supplies that owner.

Give each independently deployed application a stable ScopeId. Standalone databases/brokers have their own scopes; application-owned data may be in the application's scope but is retained separately when the application retires. Referencing a platform database does not grant lifecycle ownership. ResourceId is stable across display-name or provider-name changes, with physical replacement recorded separately. That stability has to be built: mint each ResourceId from the scope, a stable logical key, and the builder's role path, following EP-144. Add the optional logical key to the user-facing Deployment, broker, and volume values and their Config/Load wire forms; it defaults to the first declared name and is pinned explicitly to rename. A changed key is a new resource, and only EP-149's reviewed migration turns a rename into anything else.

Compile workload manifests, routes, access contributions, schedules, one-shot Jobs, volumes, backup policy, credentials, image references, logical broker topics, and release metadata. Revisions record immutable compiled declarations plus source/config digest and explicit overrides, so reconstituting context intent does not require every application's source checkout to be available. Compilation cannot infer complete desired state from a partial live resource listing.

Make reviewed render/dry-run, saved planning, and accepted-image live deploy consume the same ResourceBundle. M4 removes the remaining direct render/apply paths. Public rendering shows secret references or redacted placeholders, never reusable passwords. An unsafe low-level rendering API may exist only inside the private execution adapter and cannot feed public review.

### M2 — Contributions, durable input channels, and publication

Model configuration, separately submitted environment variables, secret references, and temporary preview overlays as explicit intent inputs with documented precedence. A deploy omitting an env key from its own input channel does not erase a separately managed env channel. Explicit removal changes that channel's revision. Secret rotations bind opaque version tokens and private access paths; unknown reads refuse instead of regenerating credentials.

Submit namespace/certificate registration and auth backend/domain requests to EP-147's designated owners. The owner validates each contribution and composes the complete shared object. A shared resource's effective digest is the digest of its composed content, as EP-144 and EP-147 define it; an application transaction can execute only the derived change its contribution authorizes, and a redeploy whose contribution is unchanged does not touch the shared object. The platform's base scope revision and release pin do not advance. Reject a forged contribution requesting arbitrary shared-object fields.

Use EP-146 publication adapters for OCI images and assets. Move existing CDN/DNS decisions into Inventory/Adapters/Cdn.hs using explicit provider accounts/zones and canonical address claims. Provider configuration remains context/scope-bound. Where a resource is already owned by Pulumi/platform, applications contribute/reference it rather than mutate it through a second API. Cloudflare-managed application records have explicit separate ownership and observed physical identity.

### M3 — Operational actions and data safety

Route deploy/preview create/delete, restart/stop/delete, worker/server/site variants, database and broker create/delete/restart, topic creation, task run/delete, job submission, env/secret writes, snapshot/backup/restore/pruning, and access/CDN changes through the shared command service. Read-only list/get/log/inspect commands remain read-only and use typed observations.

Operational actions such as restart or backup are journaled against the accepted scope revision; they do not rewrite desired declarations unnecessarily. A manual Job has a stable operation identity and execution incarnation, so retry cannot accidentally submit duplicate work. A backup includes logical backup identity, storage object address, source data identity, expiry policy, verification, and restore dependency. Pruning uses lifecycle proof, not a broad prefix deletion.

Preserve the existing app-stop contract in App.hs explicitly: stop records a desired operational override making the Knative service cluster-local, and ordinary convergence/resume preserves it. An explicit deploy or restart clears that override as today's commands do; review displays that change. When restart clears a stopped override it is therefore a scope intent update as well as an operational action. Test stop followed by reconciliation, interrupted resume, explicit deploy, and explicit restart so the new engine neither unexpectedly exposes a stopped app nor leaves an explicitly restarted app stopped.

A restore is a data-changing operation with write-fencing, backup selection, target identity, verification, and explicit forward-recovery requirements. Ordinary resource update cannot masquerade as restore. Retiring an app preserves durable volumes/databases/brokers and the credentials/keys needed for recovery. Delete interfaces invoke EP-149's retained-resource policy; retained records stay visible after their original scope is retired.

Audit runHooks, interactive database shells, exec-like maintenance, and user-supplied migration commands. Hooks must declare their affected resource set and recovery semantics or refuse in managed execution. Interactive maintenance receives an explicit scoped session receipt, excludes concurrent managed mutation, and triggers re-observation afterward; Nagare must not claim its contents were statically planned or that unknown schema changes can be automatically rolled back. Credential extraction/public diagnostic paths remain redacted.

### M4 — User surface and removal

Keep existing command names where practical, adding review output and saved-plan use behind a shared Inventory.Command service. Application commands observe only what EP-145's observationRequirements names for the selected scope, so a deploy needs cluster access and not cloud or Pulumi credentials. They do need the context's inventory store. With the local store that is one workstation's private directory, so a deploy from any other machine refuses. [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) lets a cloud context keep the store in its state bucket instead. It is a soft dependency of this plan: M1 through M3 do not need it, but do not remove the last legacy deploy path in this milestone until EP-151 is Complete, and state the store requirement plainly in the user documentation either way. Standard non-destructive commands may prepare/display/apply their exact plan in one invocation under existing acknowledgement conventions; adoption, replacement, data restore, and deletion still need their explicit reviewed decisions. A generic --yes must never bypass a refused policy.

Refactor App/Deploy.hs and Nagare.Deploy so there is one declaration path and one internal guarded adapter path. Replace direct kubectl/gcloud/rpk/storage mutations in the command modules with typed operation requests. Do not create a parallel application journal. The developer package must include the pure model and command support it uses, while platform-only tooling remains in the operator package.

Extend docs/architecture/managed-resource-coverage.md and existing user docs for apps, databases, brokers, env/secrets, tasks/jobs, backups, and storage. Follow the repository's user-documentation profile and log requirements when implementation edits those documents. Keep only the provider-boundary scripts that perform unique work; remove shell/pure tests that merely duplicate the new authoritative model after equivalent assertions pass.


## Concrete Steps

Run from the repository root with its development environment. Add InventoryApplicationSpec.hs and InventoryDataServiceSpec.hs to cli/nagarectl/test and ResourceApplicationSpec.hs/ResourceBrokerSpec.hs to cli/nagare-dsl/test.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
bash scripts/check-haskell-style.sh
```

Extend the existing AppDeploySpec.hs, AccessResolveSpec.hs, DomainBindingSpec.hs, and golden fixtures. Test commands must run against isolated temporary state and recording adapters. The separate EP-150 local/cloud scenarios validate actual provider integration.


## Validation and Acceptance

Compose platform plus two applications, then deploy only app A. Platform base revisions, app B declarations, and unrelated resource identities remain unchanged. Authorized shared backend contributions from both apps survive. An app cannot claim the platform's database or another app's Service/hostname, even if the native provider would accept the write.

Review/execution membership matches for a multi-workload application with database, backup, broker topic, schedule, preview, CDN, and secret references. A retained database's full retention/resources values survive compilation. Permission failure reading a password never generates a replacement. Secret canaries do not appear in text/JSON dry-run, errors, or exported evidence.

An interrupted one-shot Job does not submit again without recovery proof. Restore refuses the wrong data incarnation. Removing an application retains its durable data/recovery credentials unless a separately reviewed deletion policy permits retirement. Env updates survive a later config deployment. Commands fail safely when authoritative scope history is absent, rather than adopting by labels.


## Idempotence and Recovery

Every command records a scope replacement or operation against an exact base revision. Retry consumes the same saved review and operation identity. A changed input requires a new review. Legacy objects require EP-149 adoption. Do not erase earlier history when converting release-log ConfigMaps or env stores into the new model; preserve private backups and explicit import provenance.


## Interfaces and Dependencies

```haskell
compileApplication
  :: ApplicationIntent -> DependencyExports
  -> Either (NonEmpty InventoryError) ScopeDeclaration

compileDataService
  :: DataServiceIntent -> DependencyExports
  -> Either (NonEmpty InventoryError) ScopeDeclaration

planOperationalAction
  :: OwnedResourceSet -> OperationalAction -> ObservationSet
  -> Either (NonEmpty PlanError) ChangeProposal
```

DependencyExports contains typed capability witnesses and selected revision/physical bindings; raw names are not ownership authority. Command handlers submit intents through Inventory.Store/Plan/Execute. Resource and executor interfaces are owned by EP-144/145; Kubernetes/shared contributions/database declarations by EP-147; publication by EP-146; lifecycle proof by EP-149. No external library version changes are specified. Use Mori for dependency source discovery and never search/read /nix/store.


## Revision Notes

2026-09-26: Closed direct app stop/restart/delete and site rollback/preview deletion after inventory admission, with twenty-eight isolated CLI refusal cases.

2026-09-26: Closed unreviewed live env and Secret writes after inventory admission and extended the isolated CLI refusal proof to twenty-three cases.

2026-09-26: Refused direct live data operations in initialized inventory contexts and documented the remaining reviewed operation gaps. Expanded the isolated CLI refusal regression to eighteen cases.

2026-09-26: Closed direct live Task run/delete after inventory initialization. Reviewed stable-ID manual runs remain available; reviewed schedule retirement is still M3 work.

2026-09-26: Refused direct aggregate app deployment after inventory initialization, then applied the same live deploy boundary to standalone Service, worker, production site, and static preview routes. Documented the reviewed archive publication route and recorded EP-151 completion. M4 remains open for the other direct paths and build input integration.

2026-09-25: Added a gated disposable Kubernetes review/apply test for accepted data restart. It verifies initial Secret/StatefulSet creation, selected-only restart membership, exact saved native bytes, and the live StatefulSet annotation before cleanup. A real database/broker pod rollout remains M3 validation.

2026-09-25: Allowed accepted OCI publications to satisfy reviewed deployment for configs that describe a Dockerfile or Nixpacks build. This removes a source-mode refusal while retaining exact image/tag validation; build production and its input provenance still need M2 integration.

2026-09-25: Routed accepted database and broker restart through an exact native StatefulSet scope update, with one-invocation apply or an optional saved review. Kept legacy direct restart for unclaimed workloads and refused managed `--dry-run` in favor of the actual saved review. M3 remains open for provider proof and backup, restore, deletion, and access actions.

2026-09-25: Routed accepted Service stop/restart through reviewed application or standalone scope updates, preserving stopped visibility across ordinary convergence and documenting the guarded legacy fallback. Added a one-invocation OCI archive publication route while retaining saved review. M3 still needs live provider proof and the remaining data and operational commands; M2 still needs build-input integration and full application provider membership.

2026-09-25: Guarded legacy portal sync against accepted or retained shared auth settings, including the Shomei settings owner that the prior backend-only guard missed. Reviewed portal contributions remain the managed route.

2026-09-25: Bound typed application and production static/server-site Cloudflare deploy and rollback to exactly one accepted platform zone grant selected by `CF_ZONE_ID` and the platform `publicIp` output. The compilers emit per-host proxied DNS and cache contributions; no live Cloudflare zone was used. M2 remains open for publication/input integration and provider proof.

2026-09-25: Added the reviewed Cloudflare HTTP transport and single CDN CLI dispatcher with exact zone/account checks, provider ID and version observations, and ambiguous-write handling. A fake Cloudflare API and a disposable recording context proved transport refusal and combined application/Preview/Secret/broker/CDN journal membership. M2 remains open for typed Cloudflare submission and native provider validation.

2026-09-25: Proved the reviewed Google DNS adapter in a disposable `tan-ng-labs` zone and removed the zone afterward. Added offline Cloudflare host DNS claims, granted zone-ruleset and origin-TLS composition, deterministic complete-rules rendering with provider-correct precedence and escaped expressions, a recording reviewed-adapter contract, and direct DNS create-or-verify and whole-zone guard safeguards. Cloudflare HTTP transport, context binding, CLI routing, and combined disposable application provider proof remain M2 work.

2026-09-25: Added reviewed Google per-host DNS ownership and a guarded provider adapter for application and production-site deploys, including site rollback and explicit retirement. The recording application review includes its DNS operation; the full M2 membership proof and Cloudflare owner composition remain open.

2026-09-25: Until a claimed Cloud DNS adapter exists, the direct Google host route creates only after a successful exact-name empty listing and refuses mismatched records. This removes unreviewed updates to potentially foreign DNS records; M2 still owns the reviewed update and provider recovery path.

2026-09-16: Recorded EP-151 as a soft dependency that gates only M4's removal of the last legacy deploy path, after the operator added the shared store as the eighth child.

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. ResourceIds are minted from a stable logical key carried in the user-facing values; shared-resource digests follow composed content; application commands use observationRequirements; and the machine-local store's effect on application deploys is stated as a release constraint. The reasons are rename safety, no-op convergence, keeping deploys free of cloud credentials, and ADR 13's new-machine promise.

2026-09-24: Added a reviewed exact Runtime Secret input channel with an explicit rotation version. It has a separate scope from application deployment and plain Runtime env so replacing one channel preserves the others. The existing M2 milestone remains open for Build/Preview input, merge intent, and publication integration.

2026-09-24: Resolved Service and worker broker bindings independently against accepted standalone broker scopes. Application-level bindings apply to all workloads, while local bindings affect only their workload; a workload with conflicting generated broker targets refuses. This completes the existing per-workload binding part of M1 without changing its milestone boundary.

2026-09-24: Added a reviewed standalone worker deploy route under its own scope. It reuses the application worker binder, requires an accepted Namespace and exact OCI publication, binds retained PVC recovery and runtime Secrets, and refuses unresolved database and broker inputs. M1 remains open for the other declared resource kinds and complete application review.

2026-09-24: Standalone worker retirement now selects the exact accepted Deployment and optional stable scope key before saving a plan. The retirement engine keeps retained PVC declarations. M3 remains open for the other operational and data actions already listed above.

2026-09-24: The reviewed standalone worker route now binds topic-free broker references to accepted standalone broker Services, adds explicit Deployment dependency edges, and derives connection environment from the typed binding. This advances the existing M1 broker coverage; logical topics and standalone database dependencies remain open.

2026-09-24: The standalone web Service route now uses the same accepted topic-free broker binding and records a dependency from its Knative Service to the broker Service. The original M1 milestone remains open for logical topics and other incomplete resources.

2026-09-24: Reviewed standalone Service and worker deploys bind accepted standalone databases through saved private native evidence. The supported subset expands, but M1 and the remaining operational command migrations stay open.

2026-09-24: Added a reviewed one-off Job route for accepted CronJobs. An explicit run ID fixes the Job name and independent scope; compilation checks the accepted native digest and app label before copying the Job template, so a changed source cannot silently alter a saved run. Conditional Job collection uses exact UID and resourceVersion preconditions and requests background cleanup of child Pods; a disposable cluster created and deleted the Job. M1 remains open for complete application source/render parity, and M3 remains open for migration hooks, task deletion, and data actions.

2026-09-24: The scheduled-task guide called a co-located Task with `taskApp = Nothing` app-less, but the aggregate renderer stamps the containing application's ownership label. Corrected the CLI examples to address that accepted CronJob by the containing app. `taskApp` controls managed runtime `envFrom` and `NAGARE_APP`, while `taskImage = Nothing` selects the app image; truly unlabeled task deployment is a separate unresolved path.

2026-09-24: A valid accepted CronJob name plus a valid run ID can exceed the native 63-character Job limit. Reviewed manual runs now retain the readable suffix when it fits and derive a bounded digest suffix otherwise; the independent scope retains the full task and run identity.

2026-09-24: The immutable scope wire now carries an optional digest of canonical JSON for validated application, standalone Service, and standalone worker config. Existing scope documents remain valid without the field. This distinguishes effective config revisions from native spec digests and lets accepted history identify the loaded config without requiring its source checkout. Explicit command overrides and full render parity remain M1 gates.

2026-09-24: Manual Job scopes now carry the digest of their exact accepted CronJob template as config evidence. A retry can identify the original task intent even if a later application revision changes the scheduled template.

2026-09-24: Scope documents now carry an optional canonical map of public explicit command overrides. Reviewed app deploy records its tag, optional base domain, accepted image-resource ID, and optional namespace request with the validated config digest. The saved scope therefore preserves these choices after the source checkout is gone; other command input channels and full public render parity still gate M1.

2026-09-24: The pure application compiler now checks those recorded overrides against the rollout tag, effective base domain, accepted image identity, and namespace-contribution decision. It rejects unknown keys or inconsistent metadata before a review can save misleading source evidence.

2026-09-24: `app deploy --dry-run` now uses the same supported reviewed application compiler as `--save-plan`, with an accepted image, explicit tag, and typed recovery/binding inputs. Human output lists declared identities and addresses, and `--json` emits the canonical public scope. It does not publish a review or expose private native manifests. The direct live path still uses its legacy renderer, so full render/apply parity and M1 remain open.

2026-09-24: A minimal disposable k3d context accepted a two-worker application scope and release ConfigMap from its saved native review. The test simulates a lost acknowledgement after the first provider write, reloads native members from the published review without the application source path, resumes to convergence without a duplicate write, and compares the exact live Deployment/ConfigMap membership before cleanup. This establishes one native application replay slice; Service, database, broker topic, schedule, CDN, and hook integration remain open.

2026-09-24: Reviewed standalone Service and worker deploys now retain their explicit tag and accepted image-resource inputs in the canonical scope; Service also retains an explicit base-domain override. A pure check rejects metadata that disagrees with the compiled rollout or image, and the scope wire round-trip is covered by the composed application fixture. Other input channels and full M1 parity remain open.

2026-09-24: Standalone Service `deploy --dry-run --image-resource` now compiles and checks the same public scope as `--save-plan`, printing canonical scope JSON without private native manifests or publishing a review. The existing `deploy --dry-run` without an image resource remains an offline renderer for documented config checks. Direct live deploy and broader application effects still gate M1.

2026-09-24: Standalone worker `worker deploy --dry-run --image-resource` now uses its saved-plan compiler and prints the canonical public scope. The image-free offline renderer remains for config checks. The worker guide now describes the already supported accepted broker-topic dependency. Direct live mutation paths and the remaining application effects still gate M1.

2026-09-24: A 12-member application fixture now publishes a saved review and reconstructs exact native bytes for its Service, DomainMapping, three workers, database and backup, scheduled task, and release metadata. A recording Kubernetes adapter executes every reviewed member once in dependency order. This revealed that the native binder omitted the DomainMapping hostname alias, causing review reconstruction to refuse; the binder now derives that alias from the native address and reserves the hostname. The proof is simulated provider execution, while the earlier two-worker test remains the limited live-provider replay. Broker topic, preview, CDN, and hook integration remain open.

2026-09-24: `app deploy --tag TAG --image-resource RESOURCE-ID` without `--save-plan` now uses the shared Inventory.Command create/update path: it prepares and publishes an immutable review, reloads it from the context store, prints public operation summaries, and applies with the existing transaction journal. An isolated local-store test drove that command service through one exact ConfigMap create with a recording adapter and confirmed accepted scope history; CLI dispatch smoke checks passed. Adoption, replacement, and retirement still require separate review decisions; pre-deploy hooks, CDN, build-mode image publication, legacy no-image live deploy, and a native app command-path proof remain open.

2026-09-24: The accepted-image single-invocation reviewed live route now also handles standalone Service and worker deploys. Both use the same saved-plan scope compiler and shared publish/reload/apply command service; Service adoption still requires a separately saved review. Image-free legacy live commands, build publication, and the remaining M1 effects and provider proof stay open.

2026-09-24: Explicit-recovery `db create` and `broker create` now use their existing standalone scope compilers and the same single-invocation immutable review path when no saved plan is requested. Missing recovery fields refuse before publication; image-free or recovery-free legacy creation remains separate. This advances M3 command routing, while topic changes, deletion, backup/restore, and the remaining direct paths keep it open.

2026-09-24: Supported static and server production deploys and previews now publish/reload/apply their reviewed scopes in one invocation when an accepted image resource is supplied without `--save-plan`. They reuse their saved-plan compilers and require explicit tag and skip-build inputs. Exact adoption continues through a separate saved review. CDN, Build/Preview Secret bindings, direct build publication, and other site operations remain open for M1/M3/M4.

2026-09-25: Aggregate pre-deploy Tasks now compile into independent per-tag hook scopes alongside the application scope, each with a release-tag-stable Job and `PreDeployHook` completion operation. CLI inputs bind each hook to application databases by name or other managed resource IDs, or assert no data effects; the public scope records resolved effects. The planner orders affected resource readiness before Job creation, and workloads after all hook proofs. Old hook scopes remain accepted on a new tag, avoiding a routine retirement decision. It retains converged completion proof after Job TTL cleanup and refuses a changed Job or affected set under the same release identity. The Kubernetes adapter verifies the one Job even when the operation lists other affected resources. This completes the recut M1 reviewed Kubernetes lifecycle; CDN, direct-path cutover, and broader data actions keep M2 through M4 open.

2026-09-25: Full validation passed: 799 nagarectl tests, nagare-dsl tests, Haskell style, and the strict user-documentation profile. The disposable `k3d-nagare-inventory-ep148` cluster ran the two-worker native application review/resume scenario after a simulated lost acknowledgement; its selected test passed and the cluster was returned to its stopped state. This provider run covers exact saved native members and retry, not the new hook Job or CDN provider effects.

2026-09-25: Accepted Redpanda topics now allow an explicit-to-explicit retention change through a saved review and separate apply. The topic adapter carries the accepted old retention in its private mutation plan, checks the live old value twice before transport, executes `rpk topic alter-config --set retention.ms`, and verifies the new value. The public operation summary shows both values. Partitions, replicas, broker address, and implicit-retention changes refuse. An uncertain update remains unresolved; version-1 saved create/verify plans still decode. A pure command gate prevents one-invocation updates to an accepted topic. The 799-test CLI suite, strict user-documentation validation, and style checks passed; no live Redpanda provider run was performed. CDN ownership and full M2 acceptance remain open.

2026-09-25: The direct Google CDN planner no longer emits a shared backend-service mutation. Only the standing Pulumi cache policy is accepted; per-app TTL, cache-mode, and path-rule settings refuse before DNS mutation. The TanStack CDN example and user guide now use the standing preset. The focused 24-test CDN suite, strict user-documentation validation, and style checks passed. Host Cloud DNS writes still use the direct path, so this is an owner-boundary correction rather than M2 completion.

2026-09-25: Scoped planning no longer observes and classifies every unrelated accepted resource. The selector includes the changed scope, changed composed declarations, Kubernetes contribution targets, required broker topics, bootstrap dependencies, and exact collection targets. An app update fixture excludes a second app and an unrelated Pulumi resource; shared Namespace contribution and bootstrap readiness fixtures still pass. The focused 188-test inventory selection and full 799-test CLI suite passed. Command-level credential isolation and live multi-scope provider proof remain M4 work.
