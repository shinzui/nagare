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
has not yet been accepted.

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
