# MP-23 independent verification — 2026-10-02

Independent reviewer: `gpt-6-astra`, session
`01a0fdf4-974a-7d50-a153-f08d0fd5a721`, resolved from this agent's own runtime
turn metadata. [Source and result hashes](mp23-independent-verification-2026-10-02.json)
bind the checks below. This reviewer did not implement the findings being closed.
The operator's latest instruction authorizes independent execution of the
technical runbook; operator-run verification is no longer a technical gate.

## Closed findings

F02 and F03 pass their exact retained production-path regressions in the
64-test inventory object group (7.45 seconds). `loadActiveTransactionStatus`
reads 50 and 500 chained events with zero individual GETs and one batch for each
prefix; a missing committed member refuses. Active recovery reads one journal
batch and retains one total provider effect across interrupted apply and resume.
Completed replay needs no provider registry. These assertions close the stated
caller/repeated-replay defects; F06 owns native latency and complete-command cost.

F05 passes the real loopback OpenSSH/control-master regression. Revoking the key
while keeping the existing master alive makes all three production fresh-login
paths refuse. Restoring authorization succeeds. Safe-switch exits 4 without a
commit. The separate transport argv regression passes as well.

F07 independently passes `python3 scripts/test-host-key-recovery.py`. The actual
helper and transport recover after injected sops/Tailscale failure on the same
activation request, with one key write and unchanged inode, mtime and content.
Wrong keys still refuse. Privileged service boundaries are modeled; this closes
the retry defect without claiming fresh native host acceptance.

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options=-pobject --test-show-details=direct
python3 scripts/test-host-fresh-login.py
bash scripts/test-inventory-host-transport.sh
```

The original spaced Tasty pattern was rejected by argument parsing before test
execution; the explicit `-pobject` command above is the passing invocation.

## Controller collection and operational verification

The independent interpreter run passes all 47 scenarios in 7.68 seconds. It
covers recorded 75-API discovery, complete graph authority, failed/partial lists,
UID and resourceVersion races, protected data, lost acknowledgement, fresh-process
recovery and zero repeated DELETE. The installed `8a820ce8` public Knative
retained-data fixture independently passes through real CLI subprocesses and
recording shims, including an unresolved intermediate resume and subsequent
original-transaction convergence. These remain local/model assertions.

```bash
just test-inventory-effects
python3 scripts/test-web-cleanup-public.py --nagarectl /tmp/nagare-mp23-knative-native-9001a43b/candidate/bin/nagarectl --knative --retain-data
```

Native runbook preflight independently resolves installed revision
`8a820ce89d532e441a3cde4374a38973d2639408`, context `ep150-preview`, project
`tan-ng-labs`, the original Ready k3s node UID
`d3745745-a1e2-4a07-9479-2832b893d7dc`, and idle GCS generation 742/sequence 639.
Context guard takes 3.601 seconds; store status takes 3.338 seconds. A fresh
complete namespace scan reads 75 APIs and 136 objects in 31.882 seconds, including
queries proving source `1|mp23-after-backup` and same-scope B database
`1|mp23-untouched-app-b` rows. Exact accepted scope objects are rehashed locally.

F20 is independently Closed. [The redacted native proof](mp23-independent-results-2026-10-02/native-same-scope-collection.json)
records one reviewed conditional parent DELETE after exact history collection.
SIGINT interrupts after server acceptance and before caller acknowledgement; the
original transaction stays active with its claim. A fresh CLI using the same
private root resumes its own claim in 47.010 seconds without another DELETE.
Terminal replay takes 11.888 seconds with zero kubectl calls. This is same-root
recovery, not a foreign-client takeover claim.

A fresh complete 75-API post-collection scan proves parent and sixteen reviewed
descendants absent, all 35 protected objects unchanged, and all nine same-scope
retained database resources preserved (ten native protected objects because the
StatefulSet's ControllerRevision inherits its inventory annotation). Both seeded
database rows remain exact, as do all 26 unselected accepted/converged revisions.
Generation 767/sequence 653 is idle. Only the reviewed history and Service receive
new tombstones; the nine database incarnations remain retained.

The broader namespace comparison preserves 106 original non-Event identities.
One additional uninventoried, ownerless Endpoints named
`mp23-app-b-00001-private` is absent; a same-name core Service is a reviewed
controller descendant. The evidence records this native boundary explicitly.
The contract protects inventoried objects and assumes trusted controller effects;
it does not freeze unowned ephemeral objects or promise an atomic namespace UID
set. No finalizer patch, child DELETE, retired-F15 access or history rewrite occurs.

The independent retirement fault injection also checks F17's Kubernetes boundary:
a substituted foreign PVC UID causes `retention-observation` refusal with exact
head preservation and zero effects. The unchanged original eleven-member review
then succeeds without provider mutations; retained-PVC explanation reports its
original UID. Separate history and Service collection succeed. F17 keeps its
remaining Helm-native verification visible.

This bounded installed proof does not assert final release-candidate acceptance,
source-cluster-loss recovery, HTTPS or the other engine/volume gates.

## Scheduled GCS and installed candidate gate

Independent review found two integration defects in the first scheduled GCS
increment: the command loaded all accepted native objects before selecting four
source IDs, and `gcloud storage ls --json` returned exit 1 for an unused prefix.
Both were corrected before candidate `a027d1f6`. Read-only native execution of
`gcloud storage objects list --format=json --raw` proves four existing entries
as flat GCS metadata and an empty array with exit 0 for an unused literal prefix.
The timestamp field is `updated`; generation remains a decimal string.

The independent existing test runner passes both scheduled GCS regressions in
1.18 seconds, including exact-generation reads and refusals for changed bytes,
foreign identity and invalid signatures. Subsequent installed native execution
found a missing provider timestamp case: raw metadata uses
`2026-10-02T03:17:15.502000+00:00`, while the parser only accepted a trailing `Z`.
The list command refused in 7.741 seconds without mutation. The existing exact-ID
ingestion preflight passes independently in 32.934 seconds, with one new scope
and exactly its CreateResource and RunDeclaredOperation. The scheduled GCS
restore command also still explicitly refuses that backend at this checkpoint.
Both provider boundaries are under correction; cloud ingestion, freshness and
source-cluster-loss recovery remain separate acceptance assertions.

The installed [scheduled ingestion proof](mp23-independent-results-2026-10-02/scheduled-gcs-ingestion-a027d1f6.json)
now passes with the original scheduled producer Job and Pod absent. After the
signed preflight, an exact UID/resourceVersion conditional deletion removes only
that completed CronJob child and its one Succeeded Pod, simulating normal Job
history cleanup. Inventory history and stored objects remain unchanged. The
public ingestion plan then returns the identical review digest in 37.309 seconds,
with zero reads of the removed producer; apply completes in 47.717 seconds.
The new ingestion Job succeeds after exact-generation downloads and signature
checks. Generation 775/sequence 659 is idle, all 26 earlier scope revisions are
exact, and both database rows and existing source/neighbor UIDs remain unchanged.
This proves signed receipt ingestion after producer cleanup; the listing and
isolated scheduled restore assertions await the corrected installed candidate.

Installed revision `a027d1f632d50ee4cf853127e7932ab94c09aaf1` independently passes
the [local candidate gate](mp23-independent-results-2026-10-02/local-platform-candidate-a027d1f6.json)
on the sole running Colima profile `nagare-mp23-cp3`. The real public bootstrap
plan takes 37.686 seconds and its apply takes 48.162 seconds. The review contains
213 VerifyResource operations, zero provider mutations and no lifecycle or
migration barriers. All nineteen accepted scope content digests remain exact;
generation 5186/sequence 5155 is idle with accepted equal to converged and all
37 Pods Ready or Succeeded. The preserved payload is `705716b7`, so this is an
installed CLI gate on an accepted platform, not fresh candidate-payload bootstrap.

The independent contribution-bearing public CDN-disable regression uncovered a
second integration boundary after native contribution overlap was fixed: the
runtime DNS guard required the desired target to equal the CDN IP even when
reviewed disable selected the origin IP. Both corrections now pass the actual
public CLI path in `scripts/test-cdn-disable-public.py`. A typed accepted
application grants and contributes its namespace, the planner observes that
generated object, and the saved review contains exactly one DNS update from
the CDN IP to the origin IP. All other application declaration fields and the
platform revision remain exact. The accepted head and original scope bytes are
unchanged; an unowned hostname refuses. Providers are strict read-only recording
processes, so this closes the command-integration defects without asserting live
CDN mutation or provider acceptance.

## Work in progress and limits

The source observer-test attempt overlapped another contributor's build and
stopped during compilation. It provides no observer-test result. Subsequent
verification uses installed executables while that contributor owns the build.
The already-built test runner independently passes 35 observation tests in
0.99 seconds. Source compilation was not invoked by that check.

Raw local verification logs are retained in [the result directory](mp23-independent-results-2026-10-02/).
No final local/cloud/native-system acceptance or production go/no-go follows
from these individual finding closures.
