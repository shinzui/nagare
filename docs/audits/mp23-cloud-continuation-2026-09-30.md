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

Interactive `gcloud auth login --configuration=labs` is required before another
cloud command. No cluster apply was launched, no writer was acquired, and no
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
