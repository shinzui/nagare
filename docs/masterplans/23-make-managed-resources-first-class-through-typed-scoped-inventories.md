---
id: 23
slug: make-managed-resources-first-class-through-typed-scoped-inventories
title: "Make managed resources first-class through typed scoped inventories"
kind: master-plan
created_at: 2026-09-16T17:23:44Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:44Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Pre-implementation API validation: amended shared contract, recorded findings and open store question"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-22T03:21:48Z
      mode: "implement"
      note: "Implement EP-144 typed inventory foundation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T04:27:14Z
      mode: "implement"
      note: "Begin EP-145 reviewed plan persistence and resumable execution"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-22T13:49:36Z
      mode: "implement"
      note: "Begin EP-146 cloud host and artifact adapters"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T18:29:14Z
      mode: "implement"
      note: "Begin EP-147 cluster bootstrap inventory migration"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:05:31Z
      mode: "implement"
      note: "Record partial EP-147 Kubernetes List expansion"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-22T20:48:56Z
      mode: "implement"
      note: "Compile direct database objects into stable typed declarations"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-23T17:24:05Z
      mode: "implement"
      note: "Start lifecycle policy child after cluster ownership proofs"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:51:23Z
      mode: "implement"
      note: "Record current model contribution to accepted inventory status and shared store progress"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T20:05:12Z
      mode: "implement"
      note: "Advance child plans and complete EP-151"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T21:30:29Z
      mode: "implement"
      note: "Close EP147 registry status and synchronize cross-plan boundaries"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T22:07:28Z
      mode: "implement"
      note: "Track EP-149 recovery status, adoption proof, and dependency explanation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T23:54:34Z
      mode: "implement"
      note: "Track EP-149 collection screening transport boundary"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T01:53:11Z
      mode: "implement"
      note: "Classify immutable Kubernetes Deployment selector changes"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T04:46:40Z
      mode: "implement"
      note: "Track EP-149 StatefulSet immutable classification"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T14:21:55Z
      mode: "implement"
      note: "Complete EP-149 provider-independent lifecycle and update dependent plan gates"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T15:13:26Z
      mode: "implement"
      note: "Begin EP-148 application and data scope migration"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:33:40Z
      mode: "implement"
      note: "Track EP-148 renderer membership guard"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T22:38:00Z
      mode: "implement"
      note: "Track accepted database native evidence required by EP-150"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:29:37Z
      mode: "implement"
      note: "Track accepted broker topic bindings and saved-plan verification"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:41:53Z
      mode: "implement"
      note: "Track reviewed access owner contributions and central routes"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-24T23:47:34Z
      mode: "implement"
      note: "Track retained access DomainMapping collection capability"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:22:40Z
      mode: "implement"
      note: "Track reviewed stateless server preview scopes"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:28:16Z
      mode: "implement"
      note: "Track server preview PVC ownership and recovery"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:34:17Z
      mode: "implement"
      note: "Track guarded delete-policy PVC collection"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:36:41Z
      mode: "implement"
      note: "Track retained site PVC direct-write guard"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:42:55Z
      mode: "implement"
      note: "Track full companion-address guards for direct data commands"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-25T02:45:56Z
      mode: "implement"
      note: "Unify direct data create address guards"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-25T03:02:59Z
      mode: "implement"
      note: "Track EP-148 reviewed one-off Job scope and conditional collection"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T03:21:06Z
      mode: "implement"
      note: "Track active EP-150 integration and remaining full-release dependency gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T20:36:32Z
      mode: "update"
      note: "Replace EP-150 with six bounded remaining-work plans, preserve all release gates, and expose dependencies and forecast"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T03:47:41Z
      mode: "update"
      note: "Mark EP-152 complete and retain full local and GCP acceptance gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-27T13:29:05Z
      mode: "update"
      note: "Apply Codex execution-log diagnosis, fixed outcome ownership, production-path checkpoints, and restore/maintenance handoff without expanding release scope"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T14:00:52Z
      mode: "implement"
      note: "Credit EP-160 M1 and EP-153 registration checkpoint; select EP-154 installed smoke"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-27T22:09:47Z
      mode: "implement"
      note: "Record first public PostgreSQL maintenance review, fenced terminal, and converged recovery fixture"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T15:02:10Z
      mode: "update"
      note: "Reduce MP-23 lifecycle scope while retaining journal/state, existing recovery, and full supported-feature evidence"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-28T15:26:04Z
      mode: "implement"
      note: "Track deferred-admission and coverage schema checkpoint"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-28T18:26:14Z
      mode: "update"
      note: "Prioritize K8up backup evaluation and assess the operator concern about Velero project direction"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T04:19:41Z
      mode: "update"
      note: "Prioritize replay repair and require bounded autonomous diagnosis when execution stalls"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T15:00:50Z
      mode: "update"
      note: "Revise command-boundary repair work from retained append, history, recovery, and public CLI experiments"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-29T20:16:53Z
      mode: "implement"
      note: "Record authentication failure repair and retained cold/warm replay checkpoint"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T01:33:03Z
      mode: "implement"
      note: "Record EP-156 cluster-plan scan repair and remaining installed acceptance boundary"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-30T04:43:09Z
      mode: "update"
      note: "Prioritize cloud integration and safe ongoing operation ahead of full local integration; retain final release gates"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-09-30T13:13:47Z
      mode: "implement"
      note: "Reconcile installed cloud prerequisites and registration proof; retain explicit login-blocked cluster apply boundary"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T02:42:30Z
      mode: "update"
      note: "Record independent review: gate table, IR-24 evidence map, EP-157 status, store module names, digest-ownership discrepancy"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T03:07:03Z
      mode: "implement"
      note: "Verify installed initial GCS foundation recovery and preserve the pre-VM checkpoint"
    - model: "gpt-5.6-terra"
      harness: "codex-cli"
      at: 2026-10-01T04:02:25Z
      mode: "implement"
      note: "Advance entrypoint after EP-153 driver-consolidation checkpoint"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T05:44:42Z
      mode: "implement"
      note: "Record installed local candidate gate and advance single entrypoint to bounded F15 cloud rehearsal"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-01T13:57:32Z
      mode: "implement"
      note: "Begin reviewed access scope implementation and approved fresh F15 cloud sequence"
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-01T02:42:30Z
      verdict: "changes-requested"
      note: "Direction confirmed at cf269e72; fix red fourmolu gate, Main.hs policy accumulation, unverified findings, and IR-24 evidence map before EP-157"
---

# Make managed resources first-class through typed scoped inventories

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable decisions into docs/adr/ in the same change.


## Vision & Scope

**Current release boundary — operator-approved reduction (2026-09-28).** Keep the typed inventory, independent ownership scopes, cross-tool review/journal, and filesystem/GCS state. Narrow the unfinished lifecycle behavior as specified below. This decision supersedes earlier instructions to preserve every feature of the original decomposition; it does not waive proof for the behavior still supported. Historical implementation evidence remains credited. A plan edit does not itself disable a command or establish release readiness.

| Area | Required for MP-23 | Deferred from this release |
|---|---|---|
| Ownership and coordination | Typed composition, collision checks, reviewed native effects, resumable cross-tool journal, conditional state, independent releases | Replacing the journal/state with another tool; an always-on coordinator |
| Databases and messaging | Existing PostgreSQL, Redis, ClickHouse, and existing Redpanda/topic operations | New database or messaging engines; a generalized provider/plugin framework |
| Backups | Existing native backup formats; exact verified manual and scheduled receipts; survival after Job cleanup; local MinIO and cloud GCS proof | Generalized scheduled keep-N selection/pruning and automatic backup expiry |
| Restore | Verified isolated database destinations for all three existing engines; volume restore to a new PVC; source preservation | General live database/PVC overwrite and automatic recovery promotion/cutover |
| Maintenance | Existing statically declared reviewed hooks and read-only inspection; recovery of already-recorded sessions/fences | New custom interactive mutating maintenance and unrestricted exec/migration sessions (EP-161 cancelled) |
| Validation | Complete coverage of the declared supported contract, explicit guarded exclusions, every supported native system, actual local/GCP runs, immutable evidence | No reduction of these validation gates |

Backups are retained by default. Deferred scheduled keep-N/expiry must be visible as unenforced in review, status, and user documentation; operators must account for storage growth. Existing exact reviewed manual pruning is retained only where its current proof applies. EP-153 must prevent new admission through deferred command, library, recipe, and saved-review paths. Recovery of already-admitted transactions remains available under the original identity and evidence checks; scope reduction must never strand partial deletions, live fences, or sessions. Do not delete that recovery code or its history merely because new admissions are deferred.

[EP-163](../plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md) evaluates external tools beneath this boundary. K8up/restic is the primary volume/application-backup candidate, CloudNativePG/Barman is the separate PostgreSQL comparison, and Velero is a secondary desk comparison because of the operator's concern about its project direction. EP-163 assesses project direction and maintenance continuity alongside recovery behavior; no candidate is a selected dependency. No Flux, implicit replacement GitOps platform, or additional messaging engine is part of this work. Tool evaluation does not gate MP-23, and adoption needs a subsequent decision supported by evidence.

**MANDATORY OPERATOR BOUNDARY — NO GKE (2026-09-27).** Nagare supports local k3d/k3s and k3s on a NixOS VM in GCP Compute Engine. Do not create, start, use, authenticate to, select, or request access to a GKE cluster for this initiative. Existing workstation GKE contexts are unrelated. No child may add GKE credentials, probes, compatibility, or access as a completion gate. EP-156 owns actual GCP/NixOS/k3s and GCS integration; GCP does not mean GKE.

**Local workstation budget (operator instruction, 2026-10-01).** Reuse only the `nagare-mp23-cp3` Colima profile for this initiative's local k3d checks; do not create or start additional profiles. The redundant `nagare-mp23` profile and unused `default` profile are stopped with disks preserved. Run local validations sequentially and preserve the accepted native evidence. Cloud builds use the existing fixture builder.

Address [IR-24](../improvement-requests/make-managed-resources-first-class.md): an operator can obtain one complete, typed, revision-bound account of Nagare-managed cloud, host, Kubernetes, data, credential, artifact, and release/control resources. Compilation rejects conflicting ownership before mutation. Review exposes creation, adoption, update, replacement, migration, retention, and deletion. Apply executes dependency-aware native operations with durable evidence; resume skips proven completed work. Status explains identity, ownership, dependencies, drift, health, and retirement decisions.

Platform components and applications retain independent desired-state ownership and release cadence. Each scope is one owner's complete declaration with its own revision. The context inventory composes these declarations and validates their shared claims; it is not another independently editable desired-state document. Updating one selected scope preserves every unselected scope. Application deployments can submit authorized contributions to platform-owned routing/configuration, but cannot seize the entire shared object or advance the platform release.

The architectural objective is to reduce policy scripting through a shared Haskell model. Smart constructors, explicit alternatives, typed capability references, and opaque validated/reviewed values enforce structural guarantees. Pure functions validate whole-graph properties. Adapters observe live facts and execute native provider operations. The same declarations produce inventory, review, rendering, and execution inputs. A separate handwritten inventory mirroring existing scripts is not acceptable. Acceptance includes removing superseded orchestration and duplicated guards after their replacement is proven.

Desired state, observed state, and execution history remain separate. Logical IDs survive names and ownership transfers; physical identities identify individual incarnations. Resource membership and policy are known before external mutation. Generated values are constrained typed references, not permission to introduce new resources. Data defaults to retention; unknown observations never imply absence. Credentials are private adapter inputs, absent from public review/evidence representations.

The first implementation runs in the operator CLI with private context-owned state, one writer, immutable snapshots, and a durable journal. Its release claim begins with fresh inventory-backed contexts; existing contexts and their data are disposable for this first release. Pulumi, NixOS, Kubernetes, Helm, storage, and registry tools retain their native responsibilities. This does not add a daemon, distributed coordinator, new provider engine, automatic foreign-resource adoption, generic schema rollback, in-place platform version upgrade of an admitted context, or production rollout. It does not complete the separate replacement-upgrade initiative. A later controller can implement the same store/adapter protocol; multi-workstation exclusion requires shared coordination and is not claimed by the filesystem implementation. A cloud context may instead keep that state in its state bucket, beside its Pulumi state. That store refuses a second writer from another machine through conditional writes and needs an explicit operator takeover to resume someone else's work; it still has no lease or liveness detection and is not a distributed coordinator.


## Decomposition Strategy

The foundation and adapter children EP-144–147, EP-149, and EP-151 are complete. EP-148 is superseded implementation history: EP-158 owns access/CDN, EP-159 scheduled backup receipts and the retention boundary, and EP-160 verified isolated database/volume restore with its accepted shared fence preserved. EP-161 is Cancelled under the 2026-09-28 decision; its delivered code and recovery evidence remain historical inputs. EP-153 owns supported command coverage and enforcing the deferred-operation boundary; EP-154 installed native packages; EP-155 local integrated recovery; EP-156 GCP integrated recovery; and EP-157 immutable release evidence. EP-152 fresh bootstrap is Complete. EP-150 is superseded history; its publication, store restoration, compatibility, and test infrastructure are inherited, not reimplemented.

This update reduces product scope by the operator's explicit decision. Local success remains an engineering checkpoint, not adoption readiness. EP-157 closes only after EP-152–156 and EP-158–160 satisfy their revised acceptance and the deferred routes have proven admission guards. EP-148, EP-150, and EP-161 are Cancelled records, not pending dependencies or claims of completed implementation. The fresh-context release boundary, no-GKE rule, and offline-only Cloudflare proof remain unchanged. Preserve IR-24's seven verification cases, including the bounded retained PostgreSQL rename in EP-155; this does not require universal live overwrite or automatic recovery cutover.

The local ADR corpus was scanned by filename/title and relevant records were read. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates payloads/private workspaces; [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) preserves operator host identity; [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) defines release/version transaction semantics; [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) binds immutable release evidence; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) confines cloud writes; [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) preserves self-reversion; [ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) protects forward-only storage growth; [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) protects private operator/state material; [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) guards protected replacements; [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) governs Haskell style; [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds native review and receipts; [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) protects irreversible cutover; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route/TLS ownership; and [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) defines cache retention and trust boundaries.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) records the accepted architecture from this discussion; it is a design decision, not a claim of implementation. Mori searches found no relevant cross-repository ADR to import. The local mori.dhall and mori show --full do not declare docs/adr as a profiled bundle, so the existing ADR filename/frontmatter convention is preserved. Dependency APIs must be researched through Mori during implementation and current upstream releases checked before changing bounds; this plan prescribes no dependency upgrades.

Rejected alternatives were isolated platform/application inventories without shared conflict checks; one global release coupling all applications to platform upgrades; a manually maintained resource list beside imperative scripts; replacing native reconcilers; and an always-on control plane before the operator-driven protocol is proven.


## Exec-Plan Registry


**Implementation entrypoint.** `$master-plan implement docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md` resumes the ordered checkpoints in Progress. For this initiative, the operator-requested producer/consumer sequence overrides the skill's default of selecting the first eligible registry child and finishing that entire child before switching. The registry records ownership and whole-child status; it does not express the checkpoint schedule. Hard dependencies still apply.

**Open implementation findings.** Read [the MP-23 audit tracker](../audits/mp23-findings.md) before selecting affected work. It owns stable finding IDs, fix evidence, independent verification, and unresolved handoffs. Record repairs there; an acknowledged message or source edit does not close a finding. Reconcile affected P1 findings before another native rehearsal and include unresolved IDs in every implementation handoff.


**Current entrypoint (2026-10-01).** Continue parent step 3 on frozen installed operator `d871d9131566ff12d3e4114a9944cd68cb7fe7de`, preserving admitted cloud payload `nagare-0.4.0-d73c1dc4d379`, the existing VM and sole local `nagare-mp23-cp3` profile. Accepted bootstrap, credential expiry/re-pull and clean-root recovery remain credited. Both applications, isolated configuration/replay and one grant → lost-ack resume → revoke are accepted. [Auth synchronization](../audits/mp23-native-bootstrap-results-2026-10-01/f15-auth-synchronization.json) now passes: exact two-rollout review preserves all 25 neighbors and original images/UIDs, then protected HTTP gives 302/401, public backend bypass gives 404, and neighboring public content remains exact. [The installed local gate](../audits/mp23-native-bootstrap-results-2026-10-01/local-platform-candidate-d871d913.json) proves 213 read-only checks, 19 unchanged scope content digests and 35 healthy/completed Pods. A temporary runner initially invoked the previous binary; no review/effect resulted, and every stage now verifies its actual executable revision before provider calls. Known-content seed is complete and the exactly guarded first backup review is applying. Finish isolated restore, bounded original-transaction interruption/takeover and exact cleanup. HTTPS/browser login remain unaccepted. Step 4 requires the operator runbook/F14–F18 verification and restriction disposition; stop before step 5 for that review. Full supported/native/release gates remain open.

**Execution control for every remaining checkpoint.** The implementing agent owns detection and diagnosis of stalled work; the operator must not have to ask why progress stopped.

- Before a costly run, name the user-visible assertion, expected observable progress, elapsed-time budget, and safe interruption/recovery boundary. Use an existing measured budget where available. For an unmeasured path, allow at most 15 minutes before a mandatory diagnostic checkpoint; this is not an automatic process-kill timeout. Known replay failures already trigger diagnosis and must not consume that allowance again.
- At the budget breach, or the second attempt with the same failure and no new evidence, stop launching dependent work. Inspect the process/provider state and identify where time is spent. Distinguish journal loading, provider work, and verification. Report the evidence, current hypothesis, and one bounded check that can confirm or reject it. Change the approach when that check rejects the hypothesis.
- A long build or provider operation may continue only with observed useful progress, a revised finite checkpoint, and a reason waiting is preferable to safe interruption. Process liveness, repeated polls, and an advancing replay counter on a known unusable path are insufficient. Preserve ambiguous transactions; never reset history to get past a delay.
- Retry only after a relevant input, implementation, or observed external condition changes, or for an explicitly bounded transient-failure diagnostic. After the fix, prove the previously failing public path and retain the measurements before resuming dependent work. Report accepted behavior and remaining blockers; command count, patch count, and passing unrelated tests are not progress evidence.

Reviews of remaining checkpoints must test the riskiest operational assumption against code and representative evidence, including aggregate command cost and recovery after interruption. A completed prerequisite can contain a newly discovered blocking defect. Assign that defect and prevent affected execution immediately rather than deferring it to final release assembly. Do not require a new broad audit before fixing the known blocker.

**Resume procedure after the 2026-09-28 scope reduction.** Follow this procedure before selecting implementation work:

1. Read the current Vision & Scope and Progress, then the selected child's current milestones and recorded acceptance evidence. The revised scope governs; historical notes are evidence, not instructions to resume deferred work. EP-161 is Cancelled. Do not continue new live-overwrite, interactive-maintenance, or scheduled-prune feature work from an older handoff.
2. Preserve concurrent edits and retained fixture/state identities. Before mutating a selected fixture, inspect its existing transaction/fence/session state through the supported read-only path. An already-admitted operation may need its existing evidence-bound recovery; do not reset its history or treat cancellation as completion.
3. After the command-boundary repairs above pass, reconcile EP-153's deferred-admission and retained-recovery checkpoint, which Progress already records as passing. Reuse that proof while its inputs remain applicable; do not repeat a full command audit. Continue any remaining boundary assertions only when current evidence identifies them.
4. Reconcile the EP-154 installed checks needed by the selected cloud command and the existing EP-157 evidence inputs. Skip accepted outputs whose evidence remains applicable. Continue orders 3–4 through EP-156: installed second-root recovery, cluster convergence, then a real cloud application/database and recovery path. Pull EP-153/158–160 implementation into that path as needed. Reuse existing local roundtrips and keep EP-160 M1 accepted; do not require EP-155 fixture completion or all-engine local expansion first.
5. After the representative cloud path, complete remaining cloud M1/M2 assertions and supported feature gaps, then the full local scenario in order 5 and the final-candidate gates in order 6. MP-24/EP-163 research, K8up/Velero evaluation, and tool adoption are not prerequisites. Record the exact next child/assertion at every handoff; do not end at a passing partial checkpoint when more authorized work is ready.

At each checkpoint handoff, record the accepted output/evidence and next checkpoint in the owning child's living sections and keep the parent's brief Progress snapshot current. Switch children and continue within the authorized MP scope; a partial checkpoint does not mark its whole milestone or child Complete. If blocked, name the missing input and first select a ready repair, feature, or package check that advances the cloud path. Select broader local integration only when no cloud-relevant work is ready. Do not repeat an unchanged failed gate or restart a broad audit. Final acceptance remains order 6 and every active child's revised criteria remain required.

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 144 | Define typed resource scopes and validate composed inventories | docs/plans/144-define-typed-resource-scopes-and-validate-composed-inventories.md | None | None | Complete |
| 145 | Persist reviewed resource plans and resumable execution receipts | docs/plans/145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md | EP-144 | None | Complete |
| 146 | Reconcile cloud host and artifact resources through inventory adapters | docs/plans/146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md | EP-144, EP-145 | EP-149 | Complete |
| 147 | Compile cluster bootstrap into owned resource components | docs/plans/147-compile-cluster-bootstrap-into-owned-resource-components.md | EP-144, EP-145 | EP-146, EP-149 | Complete |
| 148 | Application/data history — superseded by EP-153–161; delivered work retained | docs/plans/148-route-application-and-data-lifecycles-through-independent-resource-scopes.md | None | None | Cancelled |
| 149 | Explain drift and execute reviewed adoption migration and retirement | docs/plans/149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md | EP-144, EP-145 | EP-146, EP-147 | Complete |
| 150 | Integration history — superseded by EP-152–157; delivered work retained | docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md | None | None | Cancelled |
| 151 | Store inventory history in the context state bucket with conditional writes | docs/plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md | EP-145 | EP-146 | Complete |
| 152 | Complete fresh platform bootstrap through reviewed components | docs/plans/152-complete-fresh-platform-bootstrap-through-reviewed-components.md | EP-146, EP-147, EP-149, EP-151 | None | Complete |
| 153 | Close managed command coverage for the inventory release | docs/plans/153-close-managed-command-coverage-for-the-inventory-release.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-158, EP-159, EP-160 | In Progress |
| 154 | Validate installed inventory packages on every supported system | docs/plans/154-validate-installed-inventory-packages-on-every-supported-system.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-158, EP-159, EP-160 | In Progress |
| 155 | Prove local application and data recovery end to end | docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-158, EP-159, EP-160 | In Progress |
| 156 | Prove fresh GCP convergence and shared history recovery | docs/plans/156-prove-fresh-gcp-convergence-and-shared-history-recovery.md | EP-146, EP-147, EP-149, EP-151; native resumption additionally requires EP-153 M2 phase repair and EP-159 M2 public F09 fixture (order 0a) | EP-152, EP-153, EP-154, EP-155, EP-158, EP-159, EP-160 | In Progress |
| 157 | Gate the inventory release on complete immutable evidence | docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md | EP-146, EP-147, EP-149, EP-151 | EP-152, EP-153, EP-154, EP-155, EP-156, EP-158, EP-159, EP-160 | In Progress |
| 158 | Complete reviewed access and CDN operations | docs/plans/158-complete-reviewed-access-and-cdn-operations.md | EP-146, EP-147, EP-149, EP-151 | None | In Progress |
| 159 | Complete scheduled receipts and explicit retention limits | docs/plans/159-complete-scheduled-backup-receipts-and-exact-retention-pruning.md | EP-146, EP-147, EP-149, EP-151 | None | In Progress |
| 160 | Complete verified isolated database and volume restore | docs/plans/160-complete-fenced-live-data-restore-across-supported-engines-and-volumes.md | EP-146, EP-147, EP-149, EP-151 | EP-159 | In Progress |
| 161 | Interactive maintenance deferred; delivered recovery history retained | docs/plans/161-provide-scoped-interactive-maintenance-with-durable-recovery.md | None | None | Cancelled |

Hard dependencies must be Complete before starting the dependent child; soft dependencies supply additional real-adapter coverage but allow independent fixture-backed work. Registry status values are Not Started, In Progress, Complete, or Cancelled.


## Dependency Graph

For the current repair, order 0a is a hard prerequisite of EP-156 native resumption, not of its offline store diagnostics: EP-153 M2 supplies phase-correct factory construction and EP-159 M2 supplies the public retained-prune fixture before effect and after partial deletion. Neither whole child must close first. EP-153's selected-target work and EP-156's selected-native loader have an integration dependency at order 0b; their producer/consumer fixture is accepted together. Order 0c then proves the complete append/command path. These explicit checkpoint dependencies override the former broad replay-first handoff and create no whole-child closure cycle.

EP-144 must complete first because all later work consumes its identity, declaration, wire, and validation contracts. EP-145 then defines the one authoritative store, review boundary, journal, and adapter protocol.

EP-146, EP-147, EP-149, and EP-151 may proceed after EP-145. EP-151 needs only EP-145's store contract, conformance suite, and head format; its soft dependency on EP-146 is the handoff of a new context's first bootstrap transaction, which necessarily runs on the local store because the state bucket does not exist yet. Cloud and cluster builders test against declared typed outputs without needing each other's live executors. Lifecycle policy tests against recording adapters without claiming native behavior. Their integration dependency is that every adapter exposes identity/precondition/verification capabilities required by lifecycle policy; reconcile that contract before any real adoption/migration/retirement is enabled. Until then these actions refuse explicitly, while fresh-resource/convergent operations remain independently verifiable.

EP-148's delivered code supplies EP-158–160; no active child depends on the superseded EP-148 or cancelled EP-161. EP-146/147/149/151 are complete prerequisites. EP-158 access/CDN and EP-159 backup receipts can proceed independently. EP-160 M1's shared fence is accepted and retained; M2/M3 prove isolated recovery destinations. EP-159 receipts feed EP-160 restore; existing manual receipts allow independent development. EP-153 preserves recovery of already-admitted deferred operations and proves refusal of new admissions.

EP-152 bootstrap is complete. EP-156 cloud integration has scheduling priority over EP-155 local integration; there is no hard dependency from full EP-155 acceptance to EP-156. Reuse shared scenario definitions and applicable local evidence, but implement and verify missing shared bindings through the cloud consumer when needed. EP-155 and EP-156 both remain prerequisites of EP-157 final release acceptance. EP-153 command coverage, EP-154 packaging, and EP-158–160 features proceed alongside it. Fixture and schema work can start before all features finish; final evidence must include their working implementations. Shared native proofs do not require administrative closure of the feature plan that will cite them. EP-157 requires every active predecessor's full accepted outcome. Numerical order is not execution order. MasterPlan 21's separate replacement-upgrade initiative remains independent; reuse its safety principles without silently adding its unfinished live cutover to this release. EP-158 M1 is a prerequisite of the safe-use gate in Progress, not of EP-156 M1/M2; its hard dependencies are complete, so it may start immediately and does not wait for cloud checkpoints.


## Integration Points

**Command-boundary repair — EP-153 owns selection and factory construction, EP-156 owns store/evidence lookup, EP-159 owns the retained-prune consumer.** EP-153 must resolve an explain target before workspace/native/provider initialization and construct recovery adapters without running pre-effect eligibility checks. EP-156 supplies selected evidence loading and generation-bound append operations, without making an index or a cache a source of authority. EP-159 supplies actual saved-review CLI fixtures that cross both boundaries. The [2026-09-29 experiments](../audits/mp23-operational-experiments.md) are the initial reproductions. These owners change shared interfaces together before broadening the native scenario; the shared driver's production regression now establishes recovery-before-dependent-preflight for the fixed consumer.

**Reduced recovery contract (2026-09-28).** EP-160 M1 is accepted; retain its state machine, store integration, and existing recovery evidence without reopening its six closure criteria. EP-160 M2/M3 now prove isolated destinations and preserved sources. Deferred live overwrite and maintenance cannot gain new admission through generic apply/resume; EP-153 distinguishes new admission from observing and resolving an already-admitted operation. A recovery action remains bound to its original target, review, and observed effect; it cannot become a route for new unreviewed maintenance.

**Backup/tool boundary.** Native engines own backup/restore semantics. Nagare owns resource/source identity, declared membership, review, dependencies, and durable cross-tool outcomes. A future operator or backup tool must have one explicit lifecycle owner and bounded delegation; Nagare must not also reconcile its generated children. Tool evaluation under MP-24 is independent of this release and selects no dependency now.

**Typed domain contract — owned by EP-144, consumed by every child.** cli/nagare-dsl/src/Nagare/Resource/{Types,Reference,Policy,Inventory,Compile,Wire}.hs and schemas/resource-inventory-v1.json define stable ContextId/ScopeId/ResourceId, provider claims/aliases, physical identity, typed exports, owner contributions/delegation, lifecycle/data/sensitivity policy, and deterministic serialization. New provider kinds extend this contract explicitly. Do not derive Generic, public setters, unchecked FromJSON, or coercible phantom roles for any type whose constructor is hidden, identity newtypes included.

EP-144 also owns the types the builders return and the planner consumes: ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, the closed contribution-kind dispatch, and the per-kind claim function. They live in nagare-dsl because nagarectl depends on it and not the reverse. composeInventory is the only route to a ValidatedInventory and returns a CompositionCandidate: the desired inventory, the base generation vector, and the explicit replace/retire changes. There is no decoder from bytes to a validated inventory; the wire form is one canonical document per scope plus a manifest, and a loader composes again. A ScopeSnapshot carries every accepted scope's full declaration and the claims still reserved by retained incarnations, candidate incarnations, and unresolved transactions. A claim set includes derived reservations for the deterministically named children of a controller. ResourceId is minted from a stable logical key, never from the provider name.

Digests identify content; revisions identify history. The recorded decision is that nagare-dsl neither computes nor stores a digest of inline content and that nagarectl derives every digest in one module. As implemented since `84afb03e` (2026-09-22), the canonical SHA-256 content digest lives in nagare-dsl's Nagare/Resource/Canonical.hs and nagarectl's Nagare/Inventory/Digest.hs re-exports it; receipt, HMAC, and live-restore hashing are computed in their own modules. nagare-dsl still stores no digest. The reversal is pending operator confirmation (Surprises 2026-09-30); until then, add no further hashing to nagare-dsl. A scope revision is a purely derived generation plus that digest. No revision enters a desired digest or provider metadata, including the effective digest of a shared resource, which follows its composed content.

**State, review, and operation protocol — owned by EP-145, consumed by the adapter, application, and integration children.** cli/nagarectl/src/Nagare/Inventory/{Store,Plan,Journal,Execute,Adapter}.hs owns desired/converged heads, complete scope revision vectors, historical/retained incarnations, review bundles, operation identity, adapter capabilities, completion/recovery states, and writer locking. All persistent state stays outside payload workspaces. EP-149 adds lifecycle decisions through this interface; adapters cannot write their own scope heads.

The pipeline is compile, observationRequirements, observe, planChanges, prepareReview, publish the bundle by digest, verifyReview, then admit and execute under the process lock. planChanges is the single pure planner and takes opaque LifecycleDecisions; EP-145 exports only the empty value and EP-149 builds the rest. prepareReview calls each adapter's prepare method to produce the retained native bundle, so adapters implement observe, prepare, preflight, execute, verify, and recover. A ReviewedPlan is evidence against a snapshot read outside the lock; only admit, under the lock, yields the ExecutablePlan that authorizes effects, and its type is scoped to that lock. Refusal is an error; every admitted outcome is a TransactionResult naming its transaction. The store is specified as conditional writes (publish-if-absent, append-at-sequence, replace-head-if-generation-matches) and the transaction suite runs against an in-memory store with only those semantics, so the filesystem implementation is replaceable. Adapters never call back into a command that takes the context lock.

**Store selection and the state bucket — owned by EP-151, with the contract owned by EP-145; touches EP-146, EP-152, and EP-156.** EP-151 adds cli/nagarectl/src/Nagare/Inventory/Store/{ObjectOps,Remote,Discovery,Gogol,GcloudAuth}.hs (corrected 2026-09-30 to the actual module names), the `NAGARE_INVENTORY_STORE` and `NAGARE_INVENTORY_STORE_URL` context fields in Target.hs and scripts/lib/target.sh, and `nagarectl inventory store status|migrate`. It implements EP-145's InventoryStore unchanged and passes EP-145's transaction suite; it does not alter the head, journal, or member formats. EP-145 defines the executor claim in the head manifest that EP-151 uses to refuse a second machine. The store defaults to a sibling prefix of the Pulumi state in the same bucket and reuses Nagare.Ops.PulumiBackend's bucket bootstrap and ownership assertion and Nagare.Ops.ContextGuard's project guard rather than adding new ones. A local-mode context always uses the filesystem store. EP-146's first bootstrap transaction runs locally and moves with EP-151's migrate command. EP-156 runs its production-shaped rehearsal with the GCS store selected.

**Declaration versus native execution — owned by EP-146 for cloud/host/artifact, EP-147 for cluster, consumed by the EP-148 baseline and EP-152–160.** One provider operation may cover multiple declared resources. Pulumi native plans and TypeScript registration mapping remain authoritative for native semantics but must agree with validated membership. Kubernetes/Helm rendering is expanded and retained before mutation. Native plan/config/output changes require a new review, including bounded preparation when a provider cannot preview before a prerequisite exists.

**Shared cluster resources and data builders — owned by EP-147, consumed by the EP-148 baseline and EP-158–160.** Resource/Database.hs emits the entire database bundle, including credentials and backup operations, from the full typed Database value. Namespace/auth/shared configuration owners compose validated consumer contributions. Their effective desired resource digest is the digest of the composed content, so it changes when a contribution's content changes and not when a contributing scope is merely redeployed; neither case changes the owner's base scope revision or platform release. The contribution composers are pure and are dispatched from EP-144's composition phase, because contribution-made declarations such as a registered Namespace must exist before claims are validated. Owner authorization and complete contribution-vector checks prevent arbitrary app writes and lost updates. Credential refreshers and controller children have explicit bounded delegation.

**Lifecycle and observation semantics — owned by EP-149, consumed by EP-146–148 and EP-152–160.** Lifecycle.hs, Migration.hs, Status.hs, and Explain.hs own drift categories, adoption/transfer proofs, retained resources, incarnation-aware migration, and collection decisions. EP-149 validates proposals into LifecycleDecisions against the same CompositionCandidate the planner sees; it does not plan on its own, does not redefine RetirementIntent, and its proposals do not restate what a declaration already fixes. A stable ResourceId can have active/candidate/retained physical incarnations. Every deletion is bound to exact identity/history; restore/schema migration/write admission have explicit data recovery contracts. Existing Replacement/Cutover semantics remain specialized.

**CLI routing and compatibility — initial compile command owned by EP-144, generic command service by EP-145, domain registrations by EP-146–149, fresh platform bootstrap and legacy-upgrade confinement by EP-152; remaining command audit by EP-153.** app/Main.hs and justfile remain shared registration surfaces. Move behavior into named modules, coordinate registrations, and do not reintroduce separate orchestration in these files. Existing version/context/project/cluster guards remain until their authoritative replacements are proven. Preserve old receipts without converting unproven success into new proof. No admitted context may change platform payload version through the coarse upgrade runner.

**Coverage and tests — format owned by EP-146, contributions by EP-147/148 and EP-158–160, completeness owned by EP-153.** docs/architecture/managed-resource-coverage.md records each supported mutation family, owner scope, declaration compiler, executor, test evidence, delegation, and legacy disposition. A child running earlier may create the file using that format; later children preserve its entries. This is a traceability aid, not a second resource authority. Shared Cabal/Spec.hs/Nix test registrations must preserve each other's modules. Pure cases use existing Haskell tests; provider behavior retains focused integration checks.

**Release evidence — owned by EP-157, supplied by all earlier children.** Native tool identities, inventory/review digests, scope revisions, receipts, coverage status, and final observed state are archived under a payload identity and distinct run identity. Global release publication has a dedicated publication owner/context, not whichever deployment first consumes it. Published artifacts are references in consuming contexts. Private secrets/native bundles do not enter public evidence.

EP-157 maintains the already-implemented .github/workflows/release.yml publisher and Nagare.Inventory.Adapters.GitHubRelease. Its narrowly scoped durable publication record lives in the provider draft release: atomically bound intent/review, exact declared assets, a pre-publication verification receipt, and observed publication completion. Ephemeral Actions artifacts are not authoritative history. All authorized same-tag publishers share workflow serialization. This provider protocol does not expand the initial context store into a remote multi-writer service; ordinary context history stays in its private context-selected filesystem or GCS store.

These ownership, identity, review, storage, migration, and controller-delegation decisions belong in ADR 22 and relevant amendments. Each child updates durable decisions when implementation evidence changes them rather than leaving contradictory prose in separate plans.


## Progress

**Operator-directed finish sequence (2026-10-01).** The operator requests deliberate execution of steps 1–6 below and a review when step 4 is complete. Continue steps 1–4, then stop before step 5 and present an evidence-backed usable/deferred capability list, restrictions, remaining defects and the exact candidate/context. Step 4 is complete only after the existing safe-use criteria below, including the operator's runbook verification, pass; implementer evidence alone is not that decision. This sequence changes scheduling and communication, not product scope or release acceptance.

| Step | Concrete outcome and stopping condition | Current state |
|---|---|---|
| 1 — freeze | Installed operator `71288437`, admitted cloud payload and existing VM remain fixed; use only the retained local `nagare-mp23-cp3` profile. Preserve accepted bootstrap, credential and clean-root recovery evidence. | Accepted baseline; change only for a demonstrated defect. |
| 2 — application/access | Two bounded fixture applications/databases; reviewed configuration change with neighboring ownership preserved; verification-only replay; installed grant/revoke, lost-response recovery and portal sync. | Bounded HTTP integration passed: both applications, isolated update/replay, native lost-ack grant/revoke and exact two-workload synchronization. Protected HTTPS/browser login remain unaccepted. |
| 3 — recovery/cleanup | Known-content GCS backup and isolated restore with source preservation; one interrupted operation, writer refusal, explicit takeover and original-transaction resume; exact disposable-resource cleanup preserving retained data. | In progress: known-content seed complete; exact first backup applying. Historical applicable evidence remains credited. |
| 4 — safe-use review | All safe-use criteria pass on the frozen candidate and the operator verifies the runbook/F14–F18. Deliver a usable/deferred capability list with evidence and restrictions. | Open. Mandatory handoff to the operator before step 5. |
| 5 — supported matrix | Finish remaining engine/volume backups and restores, CDN, command guards/coverage and the complete local scenario including bounded PostgreSQL rename/collection. | Pending; existing accepted milestones remain accepted. |
| 6 — full closure | Resolve engineering/review gaps; validate installed packages on both native systems; assemble complete immutable evidence without publishing; finalize children, ADRs and MasterPlan. | Pending; full release requirements remain in force. |

**Cost checkpoint (operator correction, 2026-10-01).** Fast validation must reproduce actual accepted-history conditions, not only a minimal happy path. Group a complete affected workflow before building/installing a candidate. Before an expensive native operation, record its assertion, completed cheap preparation, exact effects, finite diagnostic bound and stop condition. A failed native boundary is first reproduced locally; do not respond with another incremental install/cloud attempt. Preserve all unrelated accepted evidence. Current cheap preparation covers retained bootstrap marker plus auth siblings, exact portal writes and neighbor revisions, genuine bootstrap verification, manual GCS receipt/readback, isolated restore UID/source/archive guards and retained-resource collection; the affected full suite is green. Native step-3 proof is still required on the fresh context and may not be replaced by these fixtures or historical evidence.

Every native check has a named assertion and a recorded result. Repeat accepted checks only when changed inputs or a relevant implementation change invalidate their proof. A failure gets a specific repair and only affected verification; do not restart a broad rehearsal without a concrete unmet requirement. The bounded cloud operational sequence is described in [its saved review report](../audits/mp23-native-bootstrap-results-2026-10-01/f15-operational-sequence-review.json).

**Remaining access boundary (2026-10-01).** The route and stale startup-reader defects are repaired and natively verified. The HTTP-only fixture has no HTTPS listener. Protected browser login remains unaccepted; its restriction needs explicit operator disposition at step 4. Do not infer browser usability from route readiness, 302/401 responses or accepted En relationships.

**Review snapshot (2026-09-30, independent, at `cf269e72`).** Direction is confirmed: the typed-scope, reviewed-plan, journal, and conditional-store foundations are implemented as recorded, and the representative cloud day-two path now has installed evidence for every item in the operational acceptance list below except steady credential expiry/re-pull (F15) and Helm-native retirement. The following cross-plan gates are not represented by any child and must be true before EP-157 assembles a candidate; they are the current coordination backlog.

| Gate | State at review | Owner |
|---|---|---|
| `just haskell-style-check` green at the candidate revision | Red: structural rules pass, but the repository's Nix-provided fourmolu 0.19.0.1 flags 45 tracked files, including `app/Main.hs` and `Nagare/Resource/Inventory.hs`; child "structural style passes" notes cover only `scripts/check-haskell-style.sh`. | EP-153 (shared surfaces); every child for its own modules |
| Independent closure of tracker findings | 16 of 18 findings are Partial/Verifying; no verifier entry since 2026-09-29 (F01/F11). For safe-use, the operator's runbook run is the check (Decision Log, 2026-09-30); release acceptance keeps the tracker rule. | Operator for safe-use; tracker steward for release |
| IR-24 seven verification cases mapped to evidence (see table) | Cases 4 and 6 have installed cloud evidence; 5 is partial; 1, 2, 3, and 7 cite none. | EP-157 assembles; EP-144/149/155/156 supply |
| `app/Main.hs` holds registration only | 13,557 lines (6,282 at `686a39d8`), including 600–700-line policy functions and the F18 authority check; see Surprises 2026-09-30. | EP-153 |
| Safe-use gate (below) met on one candidate | Open: installed EP-158 M1 integration, remaining fresh operational checks/cleanup, operator runbook and F14–F18 disposition. Installed `71288437` local platform gate, fresh cloud convergence, expired-credential re-pull and clean-root recovery are accepted in the current entrypoint/evidence. | EP-156, EP-158, EP-153 |
| Digest ownership matches the recorded decision | Reversed by `84afb03e` without a Decision Log entry; operator decision pending (Surprises 2026-09-30). | EP-144 contract owner |

IR-24 verification-case evidence map (update when a case gains proof; do not infer closure from neighboring cases):

| IR-24 case | Evidence cited today |
|---|---|
| 1. Collision fixtures refused before mutation | EP-144 unit coverage only; no retained native or installed collision fixture is cited. |
| 2. Foreign or absent owner reported as an adoption decision, not modified | Foreign-UID refusal at retirement (installed, 2026-09-30); no adoption-decision report cited. |
| 3. Rename creates, migrates, verifies, and retires with data preserved | Recording-adapter proof only (EP-149); the retained PostgreSQL rename is order 5 (EP-155). |
| 4. Interrupted multi-component operation resumes without replaying completed effects | Installed cloud: original 210-operation resume, interrupted backup with second-root refusal and takeover (2026-09-30); local EP-160 interruption cases. |
| 5. Drift categories distinguished | Foreign ownership, missing resource, retained orphan, and policy-bound collection are proven; repairable configuration drift and immutable-replacement classification are not. |
| 6. Disposable context renders, applies, converges, no-ops, and removes per policy | Installed cloud: 22–29 scopes converged, unchanged-application replay with verification-only operations, exact Job collection; full-platform cloud no-op rerun and the EP-155 local scenario remain open. |
| 7. Release evidence archived under one immutable payload identity | EP-157 index schema and fixtures only; assembly is order 6. |

**Cloud operational acceptance.** A healthy newly booted cluster is only the first checkpoint. Before describing the selected cloud configuration as usable, EP-156 must demonstrate the existing supported day-two contract: a reviewed application/configuration change with owner isolation and unchanged replay; verified GCS backup and isolated restore of known data; interrupted-operation recovery without duplicate effects; credential and history recovery from a clean operator root; shared-writer refusal/takeover; and exact retirement/cleanup that preserves retained data and neighboring resources. EP-153 and EP-158–160 own missing command/feature implementations and are pulled forward when these checks need them. Record executable operator procedures, evidence and remaining restrictions against the candidate. Keep unproved procedures visibly unavailable rather than treating bootstrap success as maintainability.

Platform-version upgrades remain excluded for admitted contexts in MP-23; isolated restore also does not establish automatic application promotion/cutover. On 2026-09-30 the operator confirmed that upgrade work follows completion of the initial supported feature set and its safe-use acceptance. Finish the existing cloud/local operational and release gates before starting that next phase. This sequencing does not waive any current maintenance or recovery proof and does not authorize an in-place payload-version change now.

**Operator procedure (2026-10-01).** [The inventory operations runbook](../runbooks/inventory-operations.md) is written with retained-cloud command timings and explicit recovery/takeover and support constraints. Its fresh-context operator execution and F14–F18 verification remain pending; this is documentation preparation, not safe-use acceptance.

**Safe-use gate (2026-09-30).** This is a cross-plan acceptance gate separate from EP-157 release acceptance: it is what must be true before real low-risk intranet workloads run on an inventory-backed cloud context. Release acceptance (order 6) continues behind it and is not waived. The gate is met when every item below has installed evidence on one candidate and the independent-verification question is settled by decision.

- The six cloud operational checks above on a fresh context bootstrapped with the typed-host credential delegation, including steady credential expiry and re-pull (F15) and exact cleanup of the rehearsal's disposable resources.
- EP-158 M1: reviewed access grant and revoke with lost-acknowledgement recovery, so an operator can admit people to an application.
- An operator runbook for `inventory apply`, `resume`, `recover`, `store status`, and takeover, with the retention-unenforced and no-in-place-upgrade constraints stated in operator terms, the measured command latencies on the cloud fixture as known values, and the statement that a crashed operator machine holds its executor claim until another operator takes over explicitly; keep unproved procedures visibly unavailable.
- Findings F14 through F18 checked by the operator's end-to-end runbook run on the fresh context (Decision Log, 2026-09-30 verification policy), recorded in the tracker; any that fail reopen.
- The candidate passed the installed local k3d platform bootstrap before its cloud rehearsal.
- EP-153's driver consolidation and model-based driver tests (Decision Log, 2026-09-30 robustness) are in the candidate.

**Local platform bootstrap before every cloud candidate (2026-09-30).** F14, F16, and F17 were Kubernetes-level defects found in multi-hour installed cloud runs; the local k3d platform bootstrap converges in minutes and would have exposed each of them. Before a candidate is used for any cloud rehearsal, run the installed local platform bootstrap and the focused regressions for the touched path. This is a candidate gate, not a requirement to complete EP-155's full scenario; EP-155's remaining assertions stay in order 5.

**Operator priority — cloud integration first (2026-09-29).** The operator urgently needs a cloud cluster that can be maintained safely after bootstrap. Prioritize EP-156's installed Compute Engine/NixOS/k3s/GCS convergence and recovery ahead of completing EP-155's local integration scenario. Pull EP-153 command repairs, EP-154 installed-package checks, and EP-158–160 features forward only as the selected cloud assertion needs them. Local focused regressions still prove a repair before native mutation; completing the local k3d/MinIO scenario is not a cloud prerequisite. Preserve existing local evidence and finish full local integration and both native-system gates before EP-157 release acceptance. This changes execution order, not supported scope, child completion, or the fresh-context/no-GKE boundary.


**Current direction — design reassessment, 2026-09-29.** [The reassessment](../audits/mp23-design-reassessment.md) replaces patch-by-patch orchestration repair as the implementation strategy. Retain typed ownership, native adapters, immutable review/history, and conditional storage. EP-153 owns one serial operation driver shared by apply/resume, total recovery outcomes, and immutable registry construction; EP-159 supplies the fixed two-operation consumer fixture. EP-156 now separates status/explain native reads from execution history and carries a validated provider head through append; command-wide cursor work remains bounded by measured active-command costs. The proposed evidence-index publication/rebuild rollout is no longer a mandatory prerequisite of historical recovery. E8/E9 remain prototype evidence, not an architectural obligation.

Seven children remain Complete and eight active. [The first production repair now passes](../audits/mp23-rescue-proof.md): one shared driver, the same saved public transaction through terminal/completed/interrupted/changed-source cases, zero provider mutations in the recorders, and 935 regression tests. This establishes the execution boundary; it does not finish immutable source selection, retained-source/receipt-only native cases, or command-cost gates. F09/F12/F13 remain Verifying for independent closure. The selected-read and append repairs now have [their own bounded proof](../audits/mp23-selected-read-proof.md). Continue active-command cost and the recorded host/native recovery prerequisites before feature expansion or long native rehearsals. No supported feature, release requirement, or old transaction is silently dropped. Earlier dated next-step instructions are superseded by this direction and the implementation table.


**Implementation order.** Check current child evidence before rerunning a checkpoint. Preserve concurrent work and already-admitted recovery records. The registry states whole-child ownership, not numerical execution order.

| Order | Work and owner | Required handoff |
|---|---|---|
| 0a — replace operation dispatch | EP-153 M2 single serial driver + immutable registry; EP-159 M2 existing two-operation prune fixture | Apply/resume share dependency-ready dispatch; all recovery outcomes are explicit; historical identity and conditional effects remain protected. Remove the duplicate live-preflight route. Preserve deferred-admission guards and explicit recovery. |
| 0b — separate resource reads | EP-153 M2 target selection + EP-156 M2 selected observation evidence; no mandatory new index prerequisite for old recovery | Unknown target needs no workspace/native/provider initialization; fixed selected state costs no additional evidence reads when unrelated reviews grow from 0 to 500; selected corrupt evidence still refuses. |
| 0c — append boundary | EP-156 M2 complete append protocol | Measure full append and public resume; remove duplicate head discovery with generation-bound compare-and-swap, preserve race/lost-ack/takeover behavior, then satisfy the existing real GCS latency gate. |
| 1 — accepted | EP-160 M1 shared fence | Retain accepted proof and recovery interfaces; do not reopen this milestone for deferred consumers. |
| 2 — cloud prerequisites | EP-153 affected registrations/guards; EP-154 installed cloud-command checks; EP-157 existing evidence schema | Reconcile accepted repairs and affected findings. Complete only the package/command checks needed for the next cloud assertion; full EP-155 acceptance is not a prerequisite. |
| 3 — cloud platform convergence | EP-156 M1/M2 installed fresh-root recovery → reviewed cluster apply/convergence | Use a never-used root without copied history, preserve accepted prerequisites, and reach healthy cloud platform services through the installed operator. Keep existing timing and identity guards. |
| 4 — cloud application and recovery | EP-156 real application/database, app-only isolation, unchanged replay, GCS receipt → isolated restore, interruption and second-root recovery; EP-153/158–160 supply needed bindings | First prove one representative cloud application/data path, then the cloud operational acceptance checks above, with verified content and preserved sources. Then expand to remaining supported cloud assertions, engines/volumes, writer conflict/takeover and exact cleanup. Report this checkpoint separately from full child/release acceptance. |
| 4b — safe-use gate | EP-156 fresh-context credential proof and cleanup; EP-158 M1 access grant/revoke; EP-153 runbook and command surface; tracker closure or accepted deferral for F14–F18 | Every safe-use gate item in Progress has installed evidence on one candidate that passed the local platform bootstrap first. Real low-risk workloads may start behind this gate; release acceptance continues in orders 5–6. |
| 5 — remaining supported work and local integration | Remaining EP-153/158–160 obligations; EP-155 full local scenario and retained PostgreSQL rename/collection | Finish the full supported matrix and local k3d/MinIO evidence after cloud integration. Pull a shared binding forward when order 3 or 4 needs it; add no engine or generic lifecycle framework. |
| 6 — final candidate | EP-154 every native system; EP-155 local; EP-156 actual Compute Engine/NixOS/k3s/GCS; EP-157 non-publishing assembly | Same candidate, complete supported coverage plus guarded exclusions, all required native assertions. Reuse applicable evidence only with exact input bindings. Full local and cloud acceptance remain required. No GKE. |

EP-157's evidence inputs grow with cloud work. EP-155 retains existing evidence and receives shared fixes, but broad local scenario expansion follows cloud integration. External-tool evaluation is not a prerequisite. Final native proof may be reused only when recorded inputs and assertions remain applicable; relevant implementation changes invalidate affected proof. A documentation-only scope edit does not itself invalidate unchanged native behavior, but final manifests must identify the final candidate and support contract.


**Finite remaining outcomes.** EP-159 must finish scheduled receipts, source/schedule history, interrupted uploads, and GCS binding, while making deferred scheduled retention explicit. EP-160 must close all three isolated engine restores and new-PVC recovery. EP-153 must close existing platform/consumer gaps and prevent new deferred operations at all entrypoints. EP-154–157 retain their complete package/local/cloud/evidence obligations for that supported set. EP-158 is unchanged. Recovery of pre-existing partial prunes, fences, and sessions cannot be removed or relabelled successful.

Earlier hour ranges are uncalibrated historical estimates, not a forecast for this revised scope. Report the selected assertion, last newly passing production-path check, and next concrete blocker. Before adding helpers, connect compile → saved review → native execution → verification/recovery in the corresponding fixture. Apply the timed execution-control procedure at the implementation entrypoint whenever progress stalls. Findings must map to a supported assertion, a missing binding, or an explicit new scope proposal; do not turn missing evidence into an exclusion. No new provider, generalized security framework, or child plan enters implicitly.

Historical implementation findings and dated checkpoints are in [the evidence ledger](../audits/mp23-evidence-ledger.md). They describe the contract in force at their date; their former live-restore, maintenance, and scheduled-prune completion requirements are superseded by the 2026-09-28 decision, while their observations and recovery records remain evidence.

## Surprises & Discoveries

**2026-09-30 — Independent review of the implementation state at `cf269e72`.** The review checked the code, gates, child plans, tracker, and ADR 22 against this file. The architecture claims hold where it matters: `composeInventory` is the only candidate route and `composeSnapshot` is a read-only reconstruction through the same closed composer and graph validation; identity newtypes hide constructors and decode only through smart constructors; the store exposes exactly publish-if-absent, append-at-sequence, and replace-head-if-generation-matches, and the transaction suite runs on the in-memory variant; apply and resume share `runOperations` in Execute.hs. Discrepancies between this file and the tree:

- `app/Main.hs` has more than doubled under this initiative and now carries policy: `scheduledProducerInFlight` (730 lines), `runListScheduledReceipts` (649), `bootstrapRegistryRecovery` (608), `runInventoryStatus` (340), an inline adapter decorator overriding preflight, three apply-style flows outside the driver (`applyReviewedKubernetesPlan`, `applyVerifiedReviewedPlan`, and `prepareBootstrapRegistryRecovery` in Execute.hs, a 615-line function that executes adapters outside `runOperations`), and today's `foundationResumeTarget` authority check. This contradicts the CLI routing integration point. Each fix that lands in Main.hs raises the cost of the handoffs this file already complains about; EP-153 should move these into named modules as it touches each command, not in a final sweep.
- Commit `84afb03e` (2026-09-22, EP-147) moved canonical SHA-256 content digests into `cli/nagare-dsl/src/Nagare/Resource/Canonical.hs`; nagarectl's `Nagare/Inventory/Digest.hs` is now a re-export with 69 importers, `Nagare/Database/Backup.hs` imports the DSL function directly, and receipt, HMAC, and live-restore hashing live in three further modules. The 2026-09-16 decision ("nagare-dsl stays free of hashing; nagarectl derives every digest in one module") was reversed without a Decision Log or ADR 22 entry. The operator should either confirm the reversal and amend ADR 22 or assign the move back to EP-144's contract owner; the review takes no position on which, only that the record and the code must agree.
- The store module list in Integration Points named files that do not exist; corrected to the actual `Store/{ObjectOps,Remote,Discovery,Gogol,GcloudAuth}.hs`.
- Registry status for EP-157 was Not Started while the plan carries two implement revisions and delivered index scripts; corrected to In Progress.
- EP-153 and EP-156 contain ten verbatim-identical 2026-09-30 progress paragraphs. Keep one owner for each checkpoint and cross-reference the other; duplicated prose drifts.
- EP-158 is the only active child without the 2026-09-28 scope-alignment entry its siblings carry. EP-159 and EP-160 file titles and slugs predate their registry titles. EP-160's historical Progress still phrases live overwrite as remaining work; its milestone text is clean.
- No child plan has ever received a `reviews` provenance entry. The tracker's independent-verifier role has produced no entry since 2026-09-29, and F16's Verification paragraph was written by the implementer, against the tracker's own rule.
- The nagare-dsl config-as-program loader tests read the ignored `.ghc.environment.*` file and fail spuriously when another cabal project rebuilds in the same store concurrently; run the two suites serially.
- The 2026-09-29 reassessment asked for latency targets before cloud expansion and no long native rehearsals during the driver replacement. The 2026-09-30 installed cloud work proceeded while F06 remains Partial; that trade was reasonable under the operator's cloud-first priority but should be recorded as accepted, not left implicit.

Product risk outside any child: the first release claim treats admitted contexts as disposable and excludes in-place platform upgrade. Once real intranet workloads and data land on the cloud cluster, that claim stops being true. The upgrade design does not need to start now, but EP-157's release notes and `docs/user/upgrades.md` must state the constraint in operator terms before safe-use acceptance, and the head schema version already present in Store.hs must be exercised by at least one forward-compatibility test so the next phase is not blocked by this phase's evidence.

2026-09-30: The installed cloud apply exposed an undeclared readiness edge: activator waits for the autoscaler websocket while the serial executor waits for activator before creating autoscaler. F14 records the native failure. Add the edge to future typed Serving declarations and preserve the old immutable review through narrowly guarded readiness continuation; never manufacture a completion proof or reset history.


**Architecture assessment.** Typed scopes, independent ownership, exact native identity, retained private reviews, and durable recovery have working compiler/store/bootstrap evidence. This inspection found no basis for discarding those foundations. It also cannot certify the whole design from unit or component proof. The weak point was treating native data exclusion and every remaining operation as routine adapter wiring: their lifecycle and authority semantics required concrete design and early end-to-end probes. The failure involves both planning and observed execution behavior. Session metadata identifies repeated `gpt-6-sol` execution, while plan provenance includes multiple authoring models; this is not a controlled model comparison and does not establish that changing a model alone fixes the problem.

Earlier architecture discoveries remain relevant: derived controller claims must participate in collision checks; candidates carry explicit changes and their base revisions; native preparation precedes immutable review; admission grants authority under the store lock; ambiguous effects recover before obsolete preflight checks; lifecycle operations retain exact incarnations; and shared history uses conditional writes. Their decisions remain in Integration Points, the child plans, ADR 22, and this file's history at `f79329f0`. Routine historical “still open” lists are not the current backlog.


## Decision Log

2026-10-01 (operator finish sequence): Execute the six-step sequence deliberately, preserving accepted proof and keeping `71288437` frozen for safe use. Stop after step 4 for the operator to review usable and deferred capabilities before step 5. The operator's instruction to perform steps 1–6 authorizes the already prepared bounded fresh operational sequence; each stage still requires its exact saved-review and history guards. No new standing-resource change or VM is included.

2026-09-30 (verification policy): For the safe-use gate, the independent check for findings F14 through F18 and for the cloud operational checks is the operator running the runbook end to end on the fresh `f15-preview` context with the installed candidate, recording the result in the tracker. Rationale: the tracker's verifier role has produced nothing since 2026-09-29, implementer-written Verification entries do not meet its own rule, and an operator-run runbook validates the procedures and the findings in one pass. This policy covers safe-use only; EP-157 release acceptance keeps the tracker's closure rule for every remaining finding.

2026-09-30 (robustness): Before the safe-use gate, EP-153 folds the registry recovery path under the shared operation driver as a recovery decision and adds a regression that the legacy upgrade runner refuses any inventory-admitted context; it also adds model-based driver tests on the in-memory store and recording adapters with interruption injected at every step. Rationale: the two remaining effect paths duplicate the claim and lock guards rather than lacking them, and today's two planner defects were invariant violations that example tests do not catch while the existing harness can.

2026-09-30 (review consolidation): Separate a safe-use gate from EP-157 release acceptance. Rationale: the operator needs a maintainable cloud cluster now; the release matrix (full local scenario, x86_64-linux native, complete command coverage, every engine/interruption case, immutable assembly) is weeks of work and should not block first low-risk use once day-two safety is proven. No release requirement is waived.

2026-09-30 (review consolidation): Start EP-158 M1 now as a safe-use prerequisite. Rationale: access grant and revoke refuse on every inventory-admitted context and nobody was assigned; an intranet nobody can be admitted to is not usable. Its hard dependencies are complete; M2 CDN work stays in order 5.

2026-09-30 (review consolidation): Every candidate passes the installed local k3d platform bootstrap before a cloud rehearsal. Rationale: three of the five 2026-09-30 P1 findings were Kubernetes-level and discoverable locally in minutes rather than in multi-hour cloud runs. This does not reorder EP-155's full scenario.

2026-09-30 (review consolidation): Move dated checkpoint and discovery history into docs/audits/mp23-evidence-ledger.md and keep one entrypoint paragraph in this file. Rationale: eleven competing dated "entrypoint" paragraphs and a 150 KB coordination document made every session reconstruct its position; the MasterPlan specification asks for a concise snapshot with child plans owning milestone detail. The ledger is verbatim; no evidence loses credit.

2026-09-30: The operator schedules platform upgrades after the initial feature set is complete and Nagare is verified safe to start using. Keep MP-23's current supported contract and full operational/release gates; upgrade implementation is the following phase, rather than a new prerequisite of initial safe use.

2026-09-29: Prioritize EP-156 cloud convergence and application/data recovery because the operator urgently needs that deployment path. Pull shared implementation and installed-package prerequisites into the selected cloud assertion; schedule full EP-155 local integration afterward. Keep both native systems, complete local/cloud evidence, supported scope and release acceptance unchanged. This is execution scheduling, not an architectural change.

2026-09-29 (design reassessment): Replace distributed phase decisions with one serial operation driver; separate resource read inputs from mutation evidence. Retain models, native adapters, wire history, and conditional storage. Supersede mandatory index rollout before recovery; preserve release scope. See the linked reassessment for alternatives, ownership, compatibility, and the stopping rule.

2026-09-29 (E8–E10): Publication and restored-history experiments validate the local protocol direction. The actual partial-prune CLI and paired executor counterfactuals add F12/F13 to order 0a; factory-only repair is insufficient. No production fix, audit closure, or new child is declared.

2026-09-29: Replace the generic replay-repair priority with three command-boundary repairs demonstrated by local experiments: phase-correct registry construction, selected target/native evidence, and observed-generation append cost. Retain passing batch replay and warm-cache behavior. Make F04/F10 prerequisite defects for affected commands despite their lower audit priority; primitive/foundation acceptance does not establish command acceptance. No product scope or release requirement changes.

2026-09-28: Synchronize external evaluation priority with MP-24/EP-163: K8up/restic first for volume/application backups, Velero as a secondary desk comparison because the operator is concerned about its project direction, and CloudNativePG/Barman retained for PostgreSQL. This supersedes the earlier Velero-first evaluation emphasis, selects no dependency, and changes no MP-23 feature or release gate.

2026-09-28: The operator authorizes a scope reduction while explicitly retaining the cross-tool journal and state. Keep typed ownership, reviews, conditional filesystem/GCS history, existing engines, verified backups, isolated restores, and full validation of that contract. Defer general live overwrite/automatic recovery cutover, custom interactive maintenance (cancel EP-161), and generalized scheduled retention pruning. EP-153 guards new admission and preserves existing recovery; EP-159 makes retention limits visible; EP-160 retains accepted M1 and narrows M2/M3. This supersedes earlier no-feature-reduction instructions and producer/maintenance scheduling. Historical work is preserved, not declared complete or erased.

2026-09-28: Keep external-tool evaluation independent in MP-24/EP-163. No Flux and no additional messaging engines. Keep the cross-tool journal/state as an architectural constraint. Evaluate CloudNativePG/Barman for PostgreSQL and Velero specifically for backup/recovery fit; the operator's Velero question is an evaluation request, not selection or adoption authorization. Do not make a prototype, tool migration, or new controller a release gate for MP-23.

2026-09-27: Order remaining implementation by producer/consumer checkpoints: early package/fixture/evidence preparation, representative scheduled receipt and restore, early maintenance handoff, then remaining engine/volume cases and final candidate evidence. The full 24-hour history exposes late planning/replay interface changes; avoid completing one entire producer plan before testing its consumers. EP-160 M1 stays unchanged.

2026-09-27: Keep the existing nine remaining children and full release contract. Replace microtask tracking with a current outcome registry and production-path execution order; withdraw stale aggregate estimates. Require findings to map to existing acceptance or an explicit scope decision. Distinguish the shared fence state machine from operation-specific access to fenced data, assigning restore to EP-160 M2/M3 and maintenance to EP-161 without reopening EP-160 M1. Preserve the concurrent implementation and all earlier evidence.

2026-09-27: Enforce the operator’s explicit no-GKE instruction and correct EP-160’s milestone ownership. Its prior rolling estimates included an invented provider gate and are not a current M1 forecast. All required behavior and actual local/cloud release proof remain required in their assigned plans.

2026-09-26: Recompose unfinished EP-148 work into EP-158–161 and transfer its cross-cutting M4/native proof obligations to EP-153–157. Keep completed evidence; supersede the original without waiving acceptance. EP-160 alone owns shared data fencing, EP-161 consumes it, and provider proof remains reusable without a plan-closure cycle. Extend the effort forecast to include the previously excluded feature work.

2026-09-26: Split EP-150 into EP-152–157 at the operator’s request because four oversized milestones hid substantial delivered work and the remaining release path. Preserve every existing requirement, credit implemented baseline once, and separate preparation from native acceptance. No reduced or knowingly broken version is an acceptable outcome. EP-157 owns the final all-gates decision; partial local evidence is not release readiness.

2026-09-26: The first full release claim targets fresh inventory-backed
contexts because the operator confirmed every existing context and its data
can be discarded. EP-150 proves a complete reviewed first bootstrap and
legacy mutation refusal; it does not need a dedicated in-place upgrade
command or translation of old coarse transaction evidence. Old bundles stay
inspectable. A future platform version transition requires a separately
reviewed design before an admitted context changes payload version. EP-148's
scope command migration and all local/GCP, coverage, and immutable evidence
gates remain in force. This narrows the first release claim without weakening
its ownership and recovery protocol.

2026-09-24: Mark EP-149 Complete at its explicitly provider-independent boundary: exact adoption and retirement routes have native proof where implemented, and migration is proved by command-path and stage-aware recording adapters while production provider stages still refuse. EP-148 and EP-150 remain responsible for application command migration and real provider/integrated coverage; completion of this child does not authorize unproved migration or collection. ADR 22 records the durable two-incarnation and recovery constraints.

2026-09-24: Keep immutable replacement distinct from configuration drift at the shared observation boundary. An adapter may report replacement required, but the generic planner must refuse an ordinary update until EP-149 provides a reviewed replacement or migration contract. ADR 22 records this durable rule.

2026-09-23: Keep adoption authority consistent at the operator DTO, generic lifecycle validator, and planner boundaries. A matching provider stamp without accepted history is not proof of ownership; the current route requires an unowned physical incarnation. Rationale: direct callers of the shared validator must not bypass the reviewed proposal's ownership check.

2026-09-23: Mark EP-147 Complete when its supported bootstrap path, reusable database/cache builders, cluster executors, shared owner composition, and host timer delegation have evidence. Keep EP-148's standalone/application database command migration and EP-149/150's lifecycle and integrated cloud work visible as separate children; completion of this child does not imply complete mutation coverage for the MasterPlan.


2026-09-16: Preserve deliberate platform/application ownership boundaries while composing their claims and dependencies in one context inventory. Rationale: independent deployments should not erase unrelated resources, but isolated inventories cannot detect cross-boundary collisions.

2026-09-16: Use one typed declaration path for render, review, and execution, with removal of superseded policy scripts as acceptance. Rationale: a handwritten inventory beside scripts would duplicate and drift from the behavior it is meant to govern.

2026-09-16: Separate desired state, observations, and execution history. Rationale: partial failures must remain explainable without advancing a false converged or release marker.

2026-09-16: Keep native executors and their safety boundaries. Rationale: the common model coordinates identity/lifecycle; it does not reproduce Pulumi state, NixOS activation, Kubernetes controllers, or Helm reconciliation.

2026-09-16: Model complete declarations plus constrained late-bound outputs and explicit review barriers. Rationale: generated IPs/credentials/keys exist only after some effects, but that cannot authorize unreviewed resources or changed native plans.

2026-09-16: Initially serialize mutations in one private operator state store and bind revisions with compare-and-swap. Rationale: local concurrency/crash safety is required now; shared remote coordination is a later implementation, not an assumed property.

2026-09-16: Seven children with three parallel adapter/policy streams after two foundation plans. Rationale: this balances concerns and independent tests without assigning all executable behavior to the final integration plan.

2026-09-16: Link every plan to intention_01m2nkkn0deaht66kevpmkjjpp, created through mina ci --json. Rationale: this is one initiative even though its resource ownership and work streams are separate.

2026-09-16: Adoption, migration, retirement, global artifact retention, and delegated maintenance are explicit model elements. Rationale: labels/names cannot prove authority, generated children must not compete with controllers, and retained data needs recovery credentials and dependency history.

2026-09-16: Amend the shared interface before implementation, following the validation recorded in Surprises & Discoveries. composeInventory returns a CompositionCandidate and is the only route to a validated inventory; claims include derived and reserved claims; EP-144 owns ScopeDeclaration, ResourceBundle, DeclaredOperation, RetirementIntent, and the contribution dispatch; digests follow content and never revisions; nagare-dsl stays free of hashing; ResourceId comes from a stable logical key. Rationale: each change removes a contradiction, an unowned type, or a path by which the compiler would have accepted a collision or a silent deletion.

2026-09-16: One planner, explicit native preparation, and lock-scoped execution authority. planChanges takes LifecycleDecisions that only EP-149 can build; prepareReview and an adapter prepare method create native evidence; admit under the process lock is the only source of an ExecutablePlan; admitted outcomes are TransactionResults that name their transaction. Rationale: the earlier interface could not produce a review bundle, could not express a mixed adopt-and-update change, and treated a proof about a stale snapshot as permission to mutate.

2026-09-16: Specify the store as conditional writes and keep the filesystem as the only shipped implementation for now. Rationale: it costs nothing today and keeps a shared store possible without a protocol change. Whether a shared store joins this initiative is left open for the operator because it changes scope and touches ADR 13.

2026-09-16: Add EP-151, a shared inventory store in the context's state bucket, as the eighth child, and group the children into four phases. This settles the question the previous entry left open. Rationale: replication or export/restore lets two machines restore the same history and both apply, after which each may believe it can retire what the other created, and the state at risk is deletion authority; ADR 13 moved the less critical Pulumi state off the workstation days earlier for the same reason; and because the store contract is already conditional writes, a real shared store costs about what replication would. It is deliberately narrow: single writer, no lease, explicit operator takeover, filesystem store retained for local mode, tests, and a new context's first transaction. EP-151 depends only on EP-145; it gates EP-148's removal of the last legacy deploy path and is a hard dependency of EP-150.

2026-09-16: Assign GitHub publication recovery to EP-150 with provider-durable draft evidence and serialized workflow ownership. Rationale: a complete platform resource model includes the actual publisher, and temporary CI files cannot establish recovery after a runner disappears. App stop and nondeterministic Helm rendering also receive explicit compatibility/parity tests.


## Outcomes & Retrospective

EP-144, EP-145, EP-146, EP-147, EP-149, EP-151, and EP-152 are complete. Eight active outcomes EP-153–160 remain required under the revised scope; EP-148 and EP-150 are superseded history, and EP-161 is deferred/Cancelled with delivered recovery work preserved. EP-150 delivered a recoverable release publisher, deterministic integration tests, history restoration, evidence projection, and compatibility safeguards; cancelling its umbrella does not erase those implementations. EP-152 adds reviewed fresh platform stages, public recovery, and a focused native marker smoke. Final acceptance still requires IR-24's full verification set, native local/GCP behavior, independent-scope isolation, complete command coverage, clone-free native packages, and immutable evidence. EP-152's focused marker proof is an input to that acceptance, not a substitute for full local and GCP recovery evidence.

At completion, compare these outcomes with IR-24, update its status only with evidence, and distill durable lessons into ADR 22 and affected existing ADRs. Do not publish a release or modify existing operator deployments as a side effect of updating plan status.


## Revision Notes

2026-10-01: Record the operator-directed six-step finish sequence, mandatory step-4 capability review, finite verification policy and accepted credential/local gate status. Existing supported scope and full release requirements are unchanged.

2026-09-30: Consolidate history into the evidence ledger, replace the dated entrypoint sequence with one current entrypoint, add the safe-use gate and the local-bootstrap-before-cloud rule, pull EP-158 M1 forward, and record the four decisions. Scope, dependencies, and release gates are unchanged; EP-158's registry row stays Not Started until its first checkpoint.

2026-09-30: Independent review of the implementation at `cf269e72`. Confirm direction; add the cross-plan gate table and IR-24 evidence map to Progress; correct EP-157's registry status and the store module list; record the Main.hs growth, digest-ownership reversal, duplicated child prose, and verification debt in Surprises. No scope, dependency, or child change.

2026-09-29: Apply the operator's cloud-first priority to the entrypoint, dependency narrative, resume procedure and checkpoint schedule; align EP-154–156 without waiving final local/native/release gates.

2026-09-29: Revise implementation order and shared ownership from measured append/history costs, a controlled recovery-order experiment, and the built CLI's unknown-target failure. Keep passing replay/cache behavior credited and add no new child. See the retained experiment report for limits and counterexamples.

2026-09-28: Make the observed GCS replay defect the immediate implementation priority, reconcile the stale EP-153 entrypoint, and replace vague stalled-work advice with timed diagnosis, evidence-based waiting/retry decisions, and representative operational review. This changes execution order and responsibility; it does not claim the replay defect is fixed.

2026-09-28: Align the external-tool reference with the operator's K8up-first evaluation preference and Velero project-direction concern; release scope and gates remain as previously agreed.

2026-09-28: Apply the operator-approved reduction to active scope, dependencies, execution order, and release acceptance; keep the cross-tool journal/state and all required proof for retained features. Coordinate affected children and ADR 22. Velero remains a backup evaluation candidate only.

2026-09-27: Extend diagnosis to every commit/file in the fixed last-24-hour window and correct the whole-plan ordering to exercise producer/consumer contracts before broadening engine coverage; make early package/fixture/evidence preparation explicit.

2026-09-27: Diagnose the stalled execution from original plans, commits, Codex logs, and the current audit. Correct EP-153/160 registry status, withdraw stale forecasts, remove duplicate historical microtask tracking, and require existing production-path assertions to drive work. Make the restore/maintenance handoff explicit in ADR 22 and affected successor plans. EP-160 is concurrently implemented and its file is unchanged by this pass. No feature, supported target, or release evidence requirement is removed; no child is added.

2026-09-27: Prohibit GKE across all children and fix the finite EP-160 M1 boundary without weakening M2/M3 or EP-156 acceptance.

2026-09-26: Split remaining EP-148 and EP-150 obligations into EP-152–161, preserve delivered work and full acceptance, and redirect ownership and dependencies. The initial estimates are historical and are superseded by the forecast correction in Progress.

2026-09-16: Validate and amend the shared API before implementation, then add EP-151 at the operator's decision for conditional shared history. Detailed earlier revision and implementation entries are retained in this file at git revision `f79329f0`; their durable decisions remain above and in ADR 22.
