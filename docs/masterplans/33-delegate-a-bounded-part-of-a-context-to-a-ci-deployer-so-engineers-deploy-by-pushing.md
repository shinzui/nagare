---
id: 33
slug: delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing
title: "Delegate a bounded part of a context to a CI deployer so engineers deploy by pushing"
kind: master-plan
created_at: 2026-11-07T16:50:51Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T16:50:51Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-07T18:55:03Z
      mode: "update"
      note: "Named operator actor ({kind, name}) for future multi-operator compatibility"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-07T18:57:26Z
      mode: "update"
      note: "Record the permissions path for MP-24 streams 1-3 and the design rules MP-33 follows"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:04:19Z
      mode: "update"
      note: "Apply review findings: protected-route authority, exact rendered bytes and workers, local credential ownership and prerequisite order."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-11T05:04:00Z
      mode: "implement"
      note: "EP-247 in progress: delegation, actor, bounds and history landed; local confirmation pending"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T03:56:32Z
      verdict: "changes-requested"
      note: "Resolve protected-route authority, rendered-byte identity, local credential handoff, and standalone worker input coverage."
---

# Delegate a bounded part of a context to a CI deployer so engineers deploy by pushing

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This initiative delivers Nagare's half of [UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md):
on a context one operator administers, any engineer on the team deploys a site or app by pushing to its repository,
through a CI/CD deployer the operator delegated a bounded part of the context to. Kotei (`mori://shinzui/kotei`) is the
first deployer; its half is
`mori://shinzui/kotei/masterplans/24-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.

When this initiative is complete, an operator can:

- review one **delegation** that names a deployer and the namespaces, hostnames, resource kinds, quotas, image
  repository and team it covers, and revoke it with one reviewed change;
- issue that deployer a credential bundle that plans and applies inside the delegation and nothing else that Kubernetes
  or the registry can refuse, and a separate builder credential that can only run hardened one-shot build Jobs in the
  delegation's build namespace;
- let the deployer deploy apps and static sites from a **rendered configuration** document produced in a credential-free
  build, so the process holding deployer credentials never executes repository code;
- see every site created under the delegation protected and open to the delegation's team, with no per-site grant and
  no access-service write key held by the deployer;
- read in the inventory journal which actor applied each change and which repository, commit and CI run it came from.

All of it works on a local context (`mode=local`) and on a cloud context. Nothing in this initiative names an
installation, project or domain; installation rollouts belong in operators' private repositories (ADR 13).

Excluded: multiple operators, second-person approval and shared operator material (still excluded by
[UC-3](../use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md)); a deployer creating or changing managed
databases, brokers, volumes, CDN resources, public routes outside its hostname bounds, access policy, or the platform;
per-engineer identities inside Nagare (the deployer is the actor; the engineer and commit travel as source metadata);
sandboxing untrusted builds (Kotei's job); Kotei self-upgrade.


## Decomposition Strategy

The work splits into four core capabilities and two supporting prerequisites, each independently testable.

1. **Authority and attribution** (EP-247). There is no notion of a non-operator actor. `NamespaceGrant` exists in the
   inventory (`cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`) but is only produced for packaged observability
   scopes (`foundationGrantedScopes` in `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`), so no application scope
   can contribute a namespace. Neither `ReviewDocument` (`cli/nagarectl/src/Nagare/Inventory/Plan/Types.hs`) nor
   `JournalEvent` (`cli/nagarectl/src/Nagare/Inventory/Journal.hs`) names who applied a change. EP-247 adds the
   delegation resource, the actor, bound enforcement in planning, and the actor and source in reviews and the journal.
2. **Credentials** (EP-248). Today deploying needs the k3s cluster-admin kubeconfig from `nagarectl kubeconfig fetch`,
   and an operator `gcloud` session for the inventory store and registry. EP-248 issues and revokes a least-privilege
   bundle; the cluster session guard (`cli/nagarectl/src/Nagare/Inventory/ClusterSession.hs`) keeps listing nodes
   through a read-only node ClusterRole in the bundle.
3. **Rendered configuration** (EP-249). Every `load*` runs the config program with `runghc`
   (`cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs`), so a deployer evaluating an engineer's `nagare/Config.hs` runs
   engineer code next to its credentials. `decodeApplication` already decodes the JSON the program prints
   (`cli/nagare-dsl/src/Nagare/Dsl/Load/Application.hs`). EP-249 exposes render and `--rendered` deploys for apps and
   static sites and standalone workers, and makes a deployer context refuse config programs.
4. **Default access** (EP-250). Each hostname is its own authorization object with no bypass
   ([ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md)), and grants need the read-write En key
   (`NAGARE_EN_API_KEY`). EP-250 lets one reviewed grant on the delegation open every protected site in it, without the
   deployer touching En, and amends ADR 29.
5. **Two gaps found while drafting the children** (EP-251, EP-252). A local context's inventory store is always a
   directory on the operator's machine (`effectiveInventoryStore` in `cli/nagarectl/src/Nagare/Target.hs`), so nothing
   running in its cluster can apply; EP-251 lets a local context keep the store in its in-cluster S3-compatible object
   store. Static archives are built with `docker build` (`cli/nagarectl/src/Nagare/Static/Package.hs`), which a
   hardened build Pod cannot run; EP-252 packages a static site by appending one layer to a digest-pinned base.

Rejected alternatives. A server-side deploy service holding the credentials and enforcing delegation would make the
bounds hold even against a compromised deployer, but it is a second executor beside the one reviewed inventory executor
(ADR 22) and a large new service; the trust model below makes it unnecessary for UC-4. Giving engineers their own
contexts would hand out store write access to people instead of to one operator-run program. Extending `nagared`
(`cluster/bootstrap/nagared/`) was rejected as the deployer: it covers static sites only, does not build, and Kotei
already has policy, provenance, retries and forge reporting; `nagared` stays as it is.

**Trust model.** The deployer is trusted software that the operator runs. Repository content (the config program, the
image, the declared hostnames) is untrusted. Nagare's checks on a rendered configuration therefore bind what engineers
can make the deployer do. Client-side checks cannot bind the deployer process itself, which is why EP-248's credentials
add a second, enforced layer wherever Kubernetes RBAC and registry IAM can express it. The inventory store cannot be
scoped per resource scope (one head and journal per context), so the deployer holds write access to it; ADR 22 already
states that hashes give integrity, not authority, against an actor holding the store. This trust model becomes an ADR
(see Integration Points).

**ADRs consulted.**
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) (cloud writes stay on the
active project; the deployer bundle keeps this);
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) (operator
material stays private; the deployer bundle is operator material);
[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) (hostname ownership, which delegation bounds);
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (scopes, namespace grants, one
executor);
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) (interpreter tests first; a
local-context run only confirms);
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) (per-hostname access, amended by EP-250);
[ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) (static sites are a local
package then two reviewed stages, which EP-249 keeps). On Kotei's side,
`mori://shinzui/kotei/okf/adrs/concepts/ADR-23` binds Kotei's deployments to Nagare's reviewed inventory and
`mori://shinzui/kotei/okf/adrs/concepts/ADR-24` makes repository policy the source of deployment permits.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 247 | Review a bounded namespace delegation for a named deployer and record who applied each change | docs/plans/247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md | None | None | In Progress |
| 248 | Issue least-privilege credentials to a delegated deployer | docs/plans/248-issue-least-privilege-credentials-to-a-delegated-deployer.md | EP-247; EP-251 | None | Not Started |
| 249 | Deploy apps and static sites from a rendered configuration without running the repository's program | docs/plans/249-deploy-apps-and-static-sites-from-a-rendered-configuration-without-running-the-repository-s-program.md | EP-247 for D5 and D6 only | None | In Progress |
| 250 | Open a delegated namespace's sites to the delegation's team without a per-site grant | docs/plans/250-open-a-delegated-namespace-s-sites-to-the-delegation-s-team-without-a-per-site-grant.md | EP-247 | None | Not Started |
| 251 | Keep a local context's inventory store in its in-cluster object store so an in-cluster deployer can apply | docs/plans/251-keep-a-local-context-s-inventory-store-in-its-in-cluster-object-store-so-an-in-cluster-deployer-can-apply.md | None | None | In Progress |
| 252 | Package a static site image archive without a Docker daemon | docs/plans/252-package-a-static-site-image-archive-without-a-docker-daemon.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

EP-247 comes first because it defines the delegation and the actor that the others read. EP-248 needs the delegation's
namespaces and image repository to scope credentials, and writes the actor into the bundle's context. EP-250 needs the
delegation's team and namespace list. EP-249 can start at once: render and `--rendered` deploys are useful to any
client on their own; D5 (config-program refusal) and D6 (deployer confirmation) hard-depend on EP-247's accepted actor and delegation. The earlier rendered-input milestones can proceed independently.

EP-251 and EP-252 can start independently. EP-248 hard-depends on both EP-247 and EP-251; its
required local acceptance uses the scoped object-store bundle, while filesystem contexts retain the workstation-only
`NAGARE_INVENTORY_STORE_ROOT` option. The default execution order is EP-247, EP-251, EP-249, EP-248, EP-250, EP-252.
This schedules rendered inputs before the credential-backed proof and avoids blocking on a later registry row. Kotei's
`mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer` hard-depends
on EP-247, EP-248 and EP-249, and owns the end-to-end UC-4 acceptance on a local context. That acceptance also needs
EP-251 (the deployer is hosted in the local cluster) and EP-252 (the fixture is a static site built in a Job). EP-250 is
needed for its access check, not for deploying.


## Integration Points

**Compatibility with several operators.** MasterPlan 24
([24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md)) records the permissions path for its unplanned
multi-operator streams and the design rules that work done now must follow. The rules are:

- authority is read from the accepted head;
- authorization checks are pure functions run when a review is prepared and at admission;
- approvals cover the review digest;
- each identity has its own credential;
- store writes go only through `ObjectOps`.

Every child plan here follows them. A change that would break one is recorded in both MasterPlans' Decision Logs.

**Delegation record** — owned by EP-247; read by EP-248 (namespaces, image repository), EP-250 (team, namespaces) and
[Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer) (through `--contract 1` reads). EP-247 defines it as an inventory-owned resource with a stable name and
these fields: deployer name; namespaces (created and owned by the delegation, accepted directly through its namespace members; application scopes receive no unrestricted `NamespaceGrant`); hostname bounds under the context's base domain; allowed scope kinds (web apps, workers, scheduled
tasks and static sites; nothing else); `protected = true` for every host; per-namespace quota; image repository path;
the default team; and an optional build namespace with its own quota, where the builder identity runs one-shot Jobs. Later plans read it through one accessor; they do not add fields without amending EP-247's
Decision Log.

**Actor** — owned by EP-247. The context gains `NAGARE_DEPLOYER=<name>`; absent means the operator, who may be named
with `NAGARE_OPERATOR=<name>`. The actor is stored as `{kind, name}`, so naming several operators later needs no wire
change. In a deployer context nagarectl attaches the actor `deployer:<name>` to every review and refuses any command or scope the delegation does
not allow. EP-248 writes `NAGARE_DEPLOYER` into the bundle's context file; EP-249 reads it to refuse `-f`.

**Review provenance** — owned by EP-247. `ReviewDocument` gains `actor` and an optional
`source {repository, revision, run}`, filled from `--source-repository`, `--source` (already passed by Kotei) and
`--source-run`. `JournalEvent` does not change: its transaction id is `tx-` plus the review digest and reviews are kept
under `reviews/<digest>`, so every journal event already binds its review. A new `nagarectl inventory history` reads
them. The review wire still changes, so it rides the EP-172 transition rules, coordinated with
[MasterPlan 31](31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md)'s EP-231 if both are in
flight; EP-247 checks EP-231's state before choosing the version.

**Stale-review refusal** — owned by EP-247 (D11). Admission refusals caused only by another change landing first map to
a new retryable contract problem `review_stale`, distinct from `admission_refused`. [Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer) re-plans only on it.

**Static archives built without a daemon** — owned by EP-252; consumed by [Kotei EP-136](mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs)'s build Jobs through
`nagarectl site package --archive --builder layered --base-archive FILE`.

**Local object-store inventory** — EP-251 owns the S3 transport, endpoint selection, migration and private
credential-file reader. EP-248 owns scoped policy and identity creation, issuance, rotation, revocation and bundle
delivery. Its D10 proves a bundle-only in-cluster apply, workstation visibility of the same head, prefix isolation
and old-key refusal. EP-251 can complete with fixture credentials; EP-248 cannot complete without this integration.
The file contract is JSON with `accessKeyId` and `secretAccessKey`, named by
`NAGARE_INVENTORY_STORE_CREDENTIALS_FILE`; neither the context nor a review carries secret bytes.

**Deployer credential bundle** — owned by EP-248; consumed by [Kotei EP-135](mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application) and [Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer) as the runner's
`KOTEI_DEPLOYMENT_HOME`. Layout follows the XDG layout nagarectl already reads, so Kotei's byte-equality check of
`$HOME/.config/nagare/kubeconfigs/CONTEXT.yaml` holds: `.config/nagare/contexts/<context>.env`,
`.config/nagare/kubeconfigs/<context>.yaml`, and a cloud credential file for cloud contexts. EP-248 also issues a
builder kubeconfig for the delegation's build namespace, limited to the resources `renderJob` in
`cli/nagare-dsl/src/Nagare/Dsl/Job` creates (a tokenless ServiceAccount, a NetworkPolicy and a Job) plus reading Pods
and their logs there. [Kotei EP-136](mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs) consumes it to run credential-free builds with Nagare's hardened one-shot Job
renderer ([Bounded one-shot jobs](../user/one-shot-jobs.md)); the builder kubeconfig holds no deploy rights and the
deploy bundle holds no build rights.

**Rendered configuration documents** — owned by EP-249, added to `docs/api/` as contract-1 documents (additive under
`docs/api/README.md`'s rules): `rendered-application`, `rendered-worker` and `rendered-site`, printed by
`nagarectl app|worker|site render` and consumed by `app check|deploy`, `worker deploy` and
`site deploy|preview deploy --rendered FILE`. Each envelope carries exact UTF-8 program stdout as a JSON string
in `config`; its digest hashes that string's UTF-8 bytes after outer JSON decoding, never a re-serialized object. Kotei plan
136 produces them in the build; [Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer) consumes them. The representative producer/consumer check is EP-249's own
acceptance: render a fixture app, standalone worker and site, then deploy each with `--rendered` on a local context.

**ADR ownership.** [ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md)
records the accepted design; EP-247 updates its implementation evidence. The deployer is trusted, repository content
is not, and the store is not scope-partitioned. EP-250 amends ADR 29. EP-248 amends ADR 9 or records why it already holds for the bundle.

**The access backend map.** A protected site deploy regenerates the `nagare-access-backends` ConfigMap in `nagare-system`
from every scope's contributions, so the deployer must update that one object outside its namespaces (EP-248), and
EP-247's bounds check must allow the generated member. Kubernetes cannot limit which hosts the deployer writes into the
map; EP-247's bounds on the rendered configuration are the control, under the trust model.
Protected DomainMappings also live in `nagare-system`. EP-247 owns the exception for generated, owned, in-bound
hostnames targeting only the accepted enforcer; EP-248 owns the Role granting DomainMapping lifecycle verbs there.
RBAC cannot express the hostname suffix or fixed target, so those remain client-side controls. No other system
resource writes are added. EP-248 D10 proves the actual protected-route create/update/retire path using its bundle.

**Contention.** Admission is serialized per context: any accepted change makes every outstanding saved review stale
(`cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`). With a deployer applying on every push, the operator's
saved reviews go stale more often and must be re-planned, and the deployer must re-plan on `stale-head`. [Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer)
owns automatic re-planning; this initiative adds no lock. If contention becomes the bottleneck, it belongs to
[MasterPlan 29](29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md)'s
territory, not here.


## Progress

EP-247 and EP-251 are In Progress: their interpreter evidence passes (EP-247 landed in `8cf692e7`) and each waits
only for its local confirmation, batched into one disposable local run with EP-249's (Decision Log, 2026-11-10).
EP-248 D10 is the required local credential/route integration gate. Remaining cross-repository gate, owned by [Kotei EP-138](mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer):

- [ ] UC-4 end to end on a local context: an operator applies one delegation and issues the bundle; a fixture repository
  pushed to its release branch is built by Kotei in a credential-free Job and deployed with `--rendered`; the site is
  protected and opens for a team member; the journal names `deployer:<name>` with the repository, commit and run; a
  repository declaring a hostname outside the delegation is refused before any mutation.


## Surprises & Discoveries

- 2026-11-07, drafting the children. A local context cannot host an in-cluster deployer: its store is a workstation
  directory (`effectiveInventoryStore`). Both MasterPlans' local gates assumed it could. Added EP-251.
- 2026-11-07, drafting Kotei's plans. Static archives need Docker, which a hardened build Job lacks ([Kotei EP-136](mori://shinzui/kotei/plans/136-run-forge-builds-in-credential-free-kubernetes-jobs));
  added EP-252. Nagare's contract mapped stale reviews to the non-retryable `admission_refused`, which would make
  Kotei's automatic re-plan guess from message text; added EP-247 D11. [Kotei EP-135](mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application) also found Nagare cannot share
  one volume across workloads, has environment-only secrets, and forbids `CREATE ROLE` in an app database; Kotei plan
  135 carries a fallback for each, so no Nagare plan is added for them.
- 2026-11-07, drafting EP-247. The journal needs no new field, because transaction ids already bind the review digest.


## Decision Log

- Decision: Confirm EP-247 D9, EP-251 D7 and EP-249's local acceptance in one disposable local context, after their
  interpreter evidence passes, instead of three native runs.
  Rationale: each needs the same freshly bootstrapped local platform with the auth plane; one run, after the
  interpreters prove each path (ADR 25), costs one bootstrap. EP-247 stays In Progress until then, so EP-248 and
  EP-250 (whole-child dependants) wait; EP-251, EP-249 and EP-252 proceed.
  Date: 2026-11-10

- Decision: Close the review gaps with a generated protected-route exception, exact-text rendered envelopes including workers, and an explicit EP-251 → EP-248 credential handoff.
  Rationale: namespace-only rules blocked protected sites, parsed JSON lost digest input bytes, and the local hosted-deployer gate lacked an owner. EP-248 owns the combined credential and route proof.
  Date: 2026-11-08


- Decision: Add EP-251 (object-store inventory for local contexts) and EP-252 (daemonless static archives) to this
  initiative rather than weakening the local gate to a workstation deployer.
  Rationale: UC-4's deployer is hosted on the installation; a local gate that cannot host it would prove less than the
  use case asks, and both gaps are generic Nagare capabilities. EP-248's workstation deployer stays as a fallback.
  Date: 2026-11-07

- Decision: The delegated deployer is trusted and repository content is untrusted. Nagare enforces delegation bounds on
  the rendered configuration in planning, and adds Kubernetes RBAC and registry IAM limits as a second layer; the
  deployer holds inventory-store write access.
  Rationale: Nagare's executor is client-side and the store has one head per context, so no client-side check can bind a
  holder of the store. Binding repository content is what UC-4 needs; a server-side executor would duplicate ADR 22's one
  executor for a threat UC-4 does not have.
  Date: 2026-11-07

- Decision: This initiative does not start MasterPlan 24's multi-operator streams. A deployer is not an operator.
  Rationale: UC-3's exclusions stand; UC-4 asks for one delegated machine actor with bounds, not for a second
  administrator, approval roles or shared operator material.
  Date: 2026-11-07

- Decision: The review actor is `{kind, name}` with an optional operator name, not an anonymous `operator`.
  Rationale: keeps the initiative compatible with several named operators later (MasterPlan 24's team streams) without
  a second review-wire transition. The limits that remain for multi-operator are recorded in EP-247 and ADR 0035: the
  actor is asserted, not proved, and approval enforced against another holder of the store would need a server-side
  check or signed reviews, which this initiative does not build and does not preclude.
  Date: 2026-11-07

- Decision: Builds and deploys use two identities. The delegation may name a build namespace; EP-248 issues a builder
  credential limited to one-shot Jobs there, separate from the deploy bundle.
  Rationale: Kotei hosted on Nagare must start build Jobs, and without this it would need a hand-applied RBAC manifest
  outside the reviewed inventory. Keeping the identities apart means a compromised build path cannot deploy and the
  deployer cannot run arbitrary pods.
  Date: 2026-11-07

- Decision: The deployer never executes a repository's config program; it deploys rendered documents, and a deployer
  context refuses `-f`.
  Rationale: `runghc` gives a config program the deployer's environment and files. Rendering inside Kotei's
  credential-free build moves that execution to where there is nothing to steal, and the decoder already exists.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled during and after implementation.)

Revision (2026-11-08): applied the review findings across EP-247, EP-248, EP-249 and EP-251; clarified prerequisites, shared authority and credential ownership, and exact rendered bytes. No implementation status changed.
