# MP-23 cloud continuation — 2026-09-30

The installed second-root checkpoint is already accepted at `6082dbd6aac0`;
see [the retained proof](mp23-fresh-root-discovery-repair.md). Its immutable
210-operation cluster review is
`1006f60f5e9afcf3e8e73b98462187b3cef1c268bcdb7035dccb6ab65e3262f1`.
Do not repeat that planning proof or reset the converged host history.

The current continuation verified the installed binary reports the same exact
revision. Reading nodes with the isolated recovered credential succeeded in
0.625 seconds. The single node remains Ready with UID
`d3745745-a1e2-4a07-9479-2832b893d7dc`.

The prerequisite public `inventory store status --json` refused in 1.429 seconds
with `StoreConditionFailed "gcloud credential or ownership command failed or
timed out"`. An independent read-only bucket describe under named configuration
`labs` identified the external cause:

```text
Reauthentication failed. cannot prompt during non-interactive execution.
```

The initial attempt required interactive `gcloud auth login --configuration=labs`
before another cloud command. The operator subsequently restored that login;
the continuation below supersedes this external blocker. No cluster apply was launched, no writer was acquired, and no
provider resource or shared history was changed by this continuation. Current
shared head state is unknown until authentication permits a fresh read; the
earlier generation 113 is retained evidence, not a current observation.

EP-153's prerequisite registration repair now records `KubeconfigRecover` as
bounded credential materialization and registers `loadTargetSnapshotReadOnly`
and `selectFoundationStore`. The coverage catalogue includes the exact existing
credential recovery contract and its refusal/native evidence. The audit and
`bash scripts/test-managed-command-audit.sh` pass: 140 routes, 34 recipes,
28 production library calls, zero registration errors, and injected mutation
refusal. Ten pending routes, seven pending recipes and 29 incomplete catalogue
rows remain; this is not release-coverage acceptance.

After authentication, read shared status again and refuse any changed
generation, active transaction, executor claim, data fence or migration before
admitting the retained review. Recheck the Ready node identity and exact six
prerequisite base revisions. Apply the original review through the same
installed candidate and isolated root. Observe operation/journal progress at
finite checkpoints; perform mandatory diagnosis within 15 minutes. Preserve
any admitted ambiguous transaction and use its original recovery identity.
Then continue healthy cluster convergence and the representative application,
GCS backup and isolated restore path. EP-156 M1/M2 remain open.

F02/F03/F04/F05/F06/F07/F08/F09/F10/F12/F13 remain unresolved at their
[tracker statuses](mp23-findings.md). This continuation does not independently
close them. The selected cluster review contains Kubernetes, Helm and artifact
operations; it contains no host activation or scheduled-prune effect. Existing
host and prune regression evidence remains applicable to their own boundaries.
Full active-cloud timing and native convergence have not been proved.

Supplemental private evidence lives in
`/tmp/nagare-mp23-cloud-continuation-20260930`; the original saved review remains
in `/tmp/nagare-mp23-fresh-root-installed-6082dbd6/cluster-review`.

## Restored-login continuation

The operator restored `labs` authentication. The same installed candidate
reports exact revision `6082dbd6aac0`; fresh shared status succeeds in
3.936 seconds and exactly matches generation 113, its recorded digest and
idle transaction/claim/fence state. The recovered credential reaches the same
Ready node in 0.469 seconds. The original cluster review is now applying as
`tx-1006f60f5e9afcf3e8e73b98462187b3cef1c268bcdb7035dccb6ab65e3262f1`.

At the ten-minute checkpoint, sequence 308 records verified completion of
Knative's `config-autoscaler` ConfigMap. Cert-manager, logging, tracing and
the VictoriaMetrics/Grafana workloads have Ready pods. This is intermediate
provider progress, not cluster convergence. The fifteen-minute diagnostic
checkpoint remains in force; preserve the admitted transaction on any failure.

Before the fifteen-minute checkpoint, source/provider diagnosis established a
readiness deadlock: the activator Deployment exists and its pod runs, but its
healthcheck cannot connect to `autoscaler.knative-serving.svc.cluster.local:8080`.
The reviewed serial order had not yet created the autoscaler Deployment. Its
Service already exists. This is not an image-pull or authentication failure.
The original apply stopped naturally at its bounded Deployment rollout timeout
after 1032.826 seconds. Public status then succeeds in 4.318 seconds at shared
generation 416, digest
`3cd2bb79c02007a96e8173a77314feea23f5768f51da3e8adfd55cee739095af`,
with the original active transaction, no executor claim, and no fence/migration.
No review or journal was reset.

The candidate repair adds the explicit autoscaler predecessor to pinned and
configured Serving inputs. For the existing immutable review, it adds the
[bounded readiness recovery contract](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md):
prove the exact created Deployment remains owned and unchanged, leave it
ambiguous/uncompleted, and permit only an untouched dependency-ready stateless
Deployment create from the same review. Recovery freshly reobserves the waiting
Deployment after each completed create. Other uncertain effects, blocked states,
fences, durable resources, updates and declared data operations do not receive
this permission. Tests and installed original-transaction recovery must pass
before claiming this correction accepted; track it as [F14](mp23-findings.md#f14).

Source acceptance: all 987 CLI tests pass, including the four new ordering,
readiness-proof, same-transaction continuation and refusal cases. The managed
command audit and structural Haskell style check pass. Fourmolu check reports
existing file-wide formatting drift; the unrelated formatting debt is retained
and remains a final package/release check concern. The installed native recovery
has not yet converged; the bounded continuation below records actual progress.

The [redacted failure](mp23-native-bootstrap-results-2026-09-30/readiness-failure.json)
retains the activator UID, healthcheck message, elapsed apply time and stopped
head. The [candidate source identities](mp23-native-bootstrap-results-2026-09-30/readiness-candidate.json)
retain exact revision `0c757b7410b3cdf14cdaa026cd2ca9b6f6427de2`, hashes and
named acceptance results. The complete public bootstrap fixture also passes,
including original lost-acknowledgement resume, changed host-input refusals,
second-root credential recovery and the full cluster review. Cold/warm read-only
SDK CLI probes against the retained cloud head take 10.046/4.705 seconds and
preserve its object generation. These are bounded regression results, not native
cluster convergence.

The existing local application archive is ARM64. A separate Linux AMD64
stdlib HTTP fixture built against the existing Python 3.12 example's image
family passed HTTP 200 with body `nagare-mp23-cloud-hello` in an isolated
local container. Its archived image and copied two-application/PostgreSQL
configs are prepared for the cloud consumer; no application review or registry
publication has occurred. This preparation grants no new provider authority.

The operator confirmed that platform upgrades follow completion of the initial
feature set and verification that Nagare is safe to start using. MP-23's existing
feature, operational, local/cloud and release gates remain unchanged. Upgrade
implementation is the following phase, and no admitted context may change
payload version through an unsupported path now.

Private continuation evidence is retained separately at
`/tmp/nagare-mp23-cloud-continuation-20260930-login-restored`.

## Installed original-review readiness continuation

Installed CLI `0c757b7410b3cdf14cdaa026cd2ca9b6f6427de2` built successfully.
The public `platform root --json` command selects the original installed payload
`nagare-0.4.0-6082dbd6aac0` with its unchanged digest and workspace; no context
payload/version transition occurred. Public pre-resume status verifies exact
unchanged generation 416 and no claim/fence. Original-review `inventory resume`
creates webhook, controller and autoscaler through the journal. All three become
Ready. It stops after 54.204 seconds with activator still uncompleted; generation
424 retains the same transaction and no claim/fence. The activator Deployment UID
remains `c4f97afa-c174-4535-bdb6-92f9ab7ea7f7`. See the
[redacted continuation](mp23-native-bootstrap-results-2026-09-30/readiness-continuation.json).

The original pod has nine container restarts from earlier liveness failures and
is in Kubernetes' five-minute restart backoff. Autoscaler has a Ready endpoint
on port 8080. Wait for its ordinary container restart and actual availability
with a bounded read-only condition watch. A rollout-status watch refuses the
previously exceeded progress deadline immediately; use the Availability
condition rather than pretending that stale status is successful. No raw
restart, object replacement, review rewrite or manufactured completion is
authorized by this observation. Resume again only after new readiness evidence.
Private evidence is retained at `/tmp/nagare-mp23-readiness-recovery-20260930`.

The ordinary restart restores activator availability with its original Deployment
and pod UIDs. A second public resume takes 436.558 seconds and records the
activator's real adapter completion at journal sequence 372. It continues through
Kourier and certificate-controller configuration, then stops naturally at the
private `net-certmanager-controller` image pull: Artifact Registry responds 401.
Shared generation 469/digest
`1b1dc15dbe0a6f4b19de31c76d5ad4ba2fede31cd3dff33b447bb93de1d1df76`
retains the original transaction and no claim/fence/migration. Public status takes
4.206 seconds. This establishes installed F14 recovery; F15 now blocks bootstrap.

The accepted host's boot registry token has expired. Recurring pull Secrets cover
only the `personal` and `nagare-system` default accounts, while this private
controller uses the `knative-serving` controller account. A bounded recovery
candidate binds the original Deployment to its accepted host activation and unit
stamps, journals intent, and replays only the unchanged host's bootstrap credential
policy plus k3s restart. All 991 CLI tests pass (49.47 seconds), including real completed host-history/private Deployment binding, lost acknowledgement, same-proof replay and drift/marker refusals. The complete public bootstrap fixture, command audit/injected-mutation fixture and structural style checks pass; both new modules pass Fourmolu. Installed recovery proof remains pending.
No such host effect has run. General steady credential coverage remains an initial
safe-use requirement; a successful one-time recovery will not establish that gate.

The final source recheck passes all 991 CLI tests in 74.29 seconds and seven selected registry tests in 0.05 seconds. The recovery transport locks before inspection, refuses pending unit jobs, preserves landed phase proof across credential expiry, and permits read-only settlement when the original Deployment becomes ready. A lost host acknowledgement cannot be cleared through ordinary Kubernetes proof; the exact saved recovery capsule must first establish quiescent host execution. Production capability regression proves readiness after lost acknowledgement and changed boot requires no repeated unit effect. Installed proof remains pending.

The installed `1af2e317` package builds, but was superseded before native use: upstream verification found that `systemctl show --property=Job --value` represents no active job as an empty value. The transport now captures each successful query and requires an empty value, preserving refusal on a failed query. A regression executes the production transport script against controlled host responses and proves successful empty-value inspection plus pending/failed-job refusals. All 992 CLI tests pass in 53.16 seconds, with eight selected registry tests in 0.22 seconds. The public bootstrap fixture from `1af2e317` remains applicable to its unchanged original-review bootstrap assertions; the follow-up changes only the explicit recovery transport guard and adds its regression. Native recovery is still pending.

## Installed bounded registry recovery

Installed `39842f8058bdaaf94819365b1f2511a3a7147246` retains payload `nagare-0.4.0-6082dbd6aac0` and original review/transaction `1006f60f5e9afcf3e8e73b98462187b3cef1c268bcdb7035dccb6ab65e3262f1`. [Redacted retained results](mp23-native-bootstrap-results-2026-09-30/registry-recovery.json) bind the recovery to the accepted source host activation, original node and Deployment. Public `inventory registry-recovery-plan` takes 102.643 seconds, publishes private proof `e28e0e5a34767f7c6549cc960ae70d82a265feb848d5327927283ccda0199fc5`, and leaves generation 469 and the original head digest exact. The proof observes an image-pull failure and stale boot credentials.

Public `inventory recover` takes 101.552 seconds. It journals prerequisite intent at sequence 415 before the accepted unit actions and its host receipt at sequence 416. The shared head advances to generation 473 with the same active transaction and no executor claim, fence or migration. Neither event is a Deployment completion. Independent Kubernetes observation now proves the same `net-certmanager-controller` UID `83ba6feb-398d-4a9b-a302-5dc81b7118e5`, generation 1, observed generation 1, and one ready/available replica; all seven inspected Serving/network/certificate Deployments are Ready. The original saved transaction resumes through the remaining auth/data/Helm members and converges in 230.454 seconds. Shared generation 549/sequence 492 has no active transaction, executor claim, fence or migration. All 22 accepted revisions remain exact, including the six unchanged prerequisite converged revisions. All 22 scopes are now converged. The live platform has 31 Running Pods with all containers Ready and two Succeeded migration Pods. Steady private platform credential coverage, broader operational acceptance and independent F15 closure remain pending. This is no payload-version upgrade or safe-use signoff.

## Reviewed application publication and capacity boundary

Installed `39842f8058bdaaf94819365b1f2511a3a7147246` saves image review `6b270df2e237f6e514bd0ee24ed8efc3cbc4d22d450f58efc2cb2159173f30a7` in 17.073 seconds and applies it in 50.633 seconds. Its two artifact operations publish only `mp23-hello:ep156-v1` to the disposable registry, with every platform revision unchanged. Application A's first plan correctly refuses missing explicit database recovery intent before effects. With `mp23-pg-a=mp23-cloud-pg-a-v1:v1`, planning takes 56.749 seconds and saves review `0d2c60cd1a9d07f9a0c5d4c0b482aeba52adecb7f5b091b6f2ea7b83514ab00e`: exactly 11 Application/mp23-app-a creates, no barriers or other scope changes.

The saved apply stops in 365.186 seconds at its Knative Service. PostgreSQL is Ready and its retained PVC Bound, but the 2-CPU node's 1,785m allocated requests leave insufficient capacity for the 275m web pod. Generation 576 retains the original transaction with no claim/fence/migration. [Redacted capacity evidence](mp23-native-bootstrap-results-2026-09-30/application-capacity.json) records the original Service and managed-field ownership. F16 owns effect-free stopping of the incomplete application while preserving its accepted data ownership, followed by a corrected immutable review and conditional Knative update. Native recovery remains pending; the existing platform/bootstrap proof remains valid. Private app evidence is retained at `/tmp/nagare-mp23-cloud-apps-20260930`.

Installed `0f6fa7db` successfully stops this incomplete application in 12.441 seconds. [Redacted stop evidence](mp23-native-bootstrap-results-2026-09-30/application-stop-and-replan.json) proves unchanged accepted/converged vectors and the same Service, PostgreSQL and retained PVC identities. Generation 579 has no active transaction, claim, fence or migration. The corrected 50m web configuration then refuses in 17.365 seconds: the original backup signing key create never ran, but accepted durable absence was treated as lost data. Repair this distinction through immutable original review and validated journal evidence; do not recreate previously completed or uncertain durable members. Installed corrected convergence remains pending.

Installed `49db2199` saves and converges the corrected Application A review in 42.372 and 63.123 seconds. The [correction proof](mp23-native-bootstrap-results-2026-09-30/application-correction.json) retains its original NotReady Knative Service UID/resourceVersion precondition, unchanged Service/PostgreSQL/PVC identities, Ready Service and actual HTTP response. A test row seeded before the correction remains exact afterward. Only Application A's accepted revision changes; all 24 scopes converge at generation 605/sequence 539 with no active transaction, claim, fence or migration. The original platform payload remains installed. All 997 CLI tests pass in 52.48 seconds; structural style, mutation-injection audit and the installed public foundation/bootstrap fixture pass. Application B, backup/isolated restore, operational recovery, steady private credential coverage and final native/release gates remain open.

## Two applications, GCS data and unchanged replay

[The cloud data proof](mp23-native-bootstrap-results-2026-09-30/cloud-applications-and-isolated-restore.json) records installed `49db2199`: Application B converges in 85.129 seconds and serves its expected HTTP body. The reviewed GCS backup converges in 112.348 seconds with actual stored-byte verification. Isolated restore converges in 45.070 seconds into `mp23-pg-a_restore_mp23pgav1`. It recovers `mp23-before-correction`; the live source retains its later `mp23-after-backup` row and Application B retains `mp23-untouched-app-b`. All 27 scopes converge at generation 647/sequence 575; all prior 24 accepted revisions stay exact, with no active transaction, claim, fence or migration.

[The replay proof](mp23-native-bootstrap-results-2026-09-30/cloud-unchanged-application-replay.json) records installed `eb582eb0`: an unchanged Application A review saves in 38.965 seconds and converges through 11 verification-only operations in 48.678 seconds. Both Services, both PostgreSQL instances and both PVCs retain their UIDs, and all three data rows remain exact. Only Application A's revision advances; the other 26 revisions remain unchanged. Generation 673/sequence 599 is idle and all 27 scopes converge. The original platform payload remains installed.

The follow-up [readiness candidate](mp23-native-bootstrap-results-2026-09-30/stopped-scope-readiness-candidate.json) requires fresh native verification for unchanged managed members of a selected unconverged scope. This prevents remaining creates from silently completing an unchanged, still-unready workload. All 998 CLI tests pass in 67.46 seconds and structural style passes. The installed package and public bootstrap fixture now pass at `2101b834`; the next section records interruption/second-root recovery. Native verification of the unready replan guard, remaining operational/engine/volume checks, steady private credential coverage, exact cleanup and final local/native/release gates remain open. These representative proofs do not complete EP-156 or safe-use acceptance.


## Installed interruption and second-root recovery

[The retained redacted proof](mp23-native-bootstrap-results-2026-09-30/cloud-interruption-and-second-root.json) binds installed `2101b834882a31a77036103b00c03b9a9cc07019`, the original `nagare-0.4.0-6082dbd6aac0` payload, the same Ready node and the original cloud history. Its immutable aarch64-darwin package and installed public foundation/bootstrap fixture pass. Full native-system/release acceptance remains open.

The new operator root contains only copied context and host declarations, with no copied credential, migration marker, journal or cache. Public store status reads generation 673 in 4.836 seconds. Credential recovery initially refuses after 16.058 seconds because the selected provider project number is unavailable; the kubeconfig remains absent and the shared head is exact. A read-only probe using the same frozen gcloud identity returns the correct project number in 2.17 seconds. One bounded recovery retry succeeds in 18.747 seconds. The mode-0600 credential reaches the original Ready node in 0.642 seconds.

A separate backup review saves in 24.804 seconds. Its only operations create and verify `nagare-dbbackup-mp23-pg-a-mp23-pg-a-recovery`; only the new standalone owner changes. After that Job exists, the local executor is paused at generation 676/sequence 601, then interrupted after the clean root refuses its foreign claim in 11.295 seconds. The refusal and interruption leave the exact head and claim unchanged. No remote process is signalled. After verifying that the original executor exited, explicit takeover resumes the original immutable review in 23.858 seconds. Sequence 601 records `adapter recovery proved completion` for the original create intent. The same Job UID is Complete, and no second create intent appears. The original verification operation checks actual stored GCS bytes; an independent download matches receipt SHA-256 `bf3195efa54ad971761b18902e2ae4d4c83834f2693e5f84cb069c3eb9823c65` and contains the current source row.

Generation 682/sequence 605 has all 28 scopes converged and no active transaction, executor claim, data fence or migration. All prior 27 accepted revisions are exact. Both Knative Services are Ready, both PostgreSQL instances are Ready and both original PVCs remain Bound with unchanged UIDs. The live source retains `mp23-after-backup`, the existing isolated database retains `mp23-before-correction`, and the other application retains `mp23-untouched-app-b`.

The public recovery procedure is:

```bash
nagarectl --context ep150-preview inventory store status --json
nagarectl --context ep150-preview kubeconfig recover
# A live foreign executor claim refuses ordinary resume. Verify that the
# original executor has exited before taking over its exact transaction.
nagarectl --context ep150-preview inventory resume \
  tx-f9f4add089cd0b6859706c2726eda192b2a27305423a062dfbf466d543e8f039 \
  --yes --take-over
nagarectl --context ep150-preview inventory store status --json
```

Use the selected isolated operator root and unchanged fixture/payload inputs. Refuse a changed context, missing accepted credential/host binding, changed physical identity, incomplete history or an executor whose termination is unproved. Resume the original published transaction; a new review cannot replace uncertain original effects. These commands document the completed fixture procedure rather than instructing another unchanged replay.

Steady private platform credential expiry/re-pull coverage, remaining supported cloud assertions, engines/volumes, exact retirement/cleanup, complete local integration and final native/release gates remain open. Platform upgrades follow initial feature completion and safe-use acceptance.
