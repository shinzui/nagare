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

## Installed scheduled backup and recovery continuation

The preceding `a027d1f6` listing and scheduled-restore refusals are superseded by
independent installed `76628094` execution. Its local cp3 gate reviewed 210 Verify
and three bounded updates: the two platform database backup CronJobs and their
bootstrap marker. Both schedules become fifteen-minute signed-v5 producers;
five referenced Secret data hashes and UIDs, eleven data/schedule UIDs, seventeen
other scope digests and all 37 healthy Pods remain exact. Plan/apply take
34.598/54.058 seconds. The marker preserves the accepted `705716b7` payload.
The [local proof](mp23-independent-results-2026-10-02/local-platform-candidate-76628094.json)
does not claim fresh candidate-payload installation.

Native scheduled GCS listing succeeds in 44.247 seconds, including the actual
UTC-offset provider metadata. The accepted v4 receipt's producer Job and Pod
remain absent. Its [isolated restore](mp23-independent-results-2026-10-02/scheduled-gcs-restore-76628094.json)
plans/applies in 39.483/39.603 seconds, reads the accepted exact generations,
completes both download and restore containers, and returns the expected
`1|mp23-after-backup` row. Source A and retained neighbor B retain their original
rows and existing UIDs; all 27 earlier accepted revisions remain exact.

Installed `ec2e1cd434855b86b16a6ffe8b0a0da24458668e` then passes the
[cp3 gate](mp23-independent-results-2026-10-02/local-platform-candidate-ec2e1cd4.json)
with 213 Verify operations in 36.152/49.524 seconds. In the eligible cloud
fixture, the public reviewed schedule-policy update contains exactly one
CronJob Update, preserving all other source-scope fields, 27 neighboring scope
revisions, the source StatefulSet/PVC and credential/signing Secret UIDs and
content hashes. Only schedule, signed producer scripts/metadata and ownership
annotations change. Its review is
`e7c0459735dd7bc4e0fb9485f74590b77ffc0b3c038b9fab0bd452a1a85fbfe5`.

The [historical accepted v4 restore](mp23-independent-results-2026-10-02/scheduled-historical-restore-ec2e1cd4.json)
still succeeds after that policy update, with the original producer absent.
Its new isolated target returns the expected row, both containers exit zero,
and all 28 existing scopes and source/neighbor UIDs remain unchanged. This
proves accepted historical authenticity is not rebound to the current producer
schedule. Unaccepted receipts from the old schedule correctly remain unresolved.

The CronJob controller creates a genuine automatic run at `2026-10-02T20:15:00Z`;
no manual Job trigger occurs. Its signed v5 recovery point is
`2026-10-02T20:15:01Z`. The [automatic producer/receipt/freshness proof](mp23-independent-results-2026-10-02/scheduled-v5-freshness-ec2e1cd4.json)
shows `--check-freshness` exits 1 while this verified candidate is unaccepted,
then exits 0 with `healthy; age=646s` after its independently guarded receipt
review applies. The ingestion adds only its one scope and two operations,
preserving all 29 existing revisions. Final generation 805/sequence 681 is idle
with 30 accepted/converged scopes. This is an observed recovery-point result;
it does not claim automatic ingestion or continuous one-hour compliance.

## Source-unavailable content and encrypted credential drill

The [manual content recovery proof](mp23-independent-results-2026-10-02/source-unavailable-content-ec2e1cd4.json)
uses a never-used HOME/config/state/cache root, absent source kubeconfig and an
explicitly failing kubectl in that root's PATH. Independent existing cloud
credentials fetch the accepted head and digest-bound receipt scope directly
from off-cluster GCS, then download the exact accepted object and receipt
generations and verify both lengths and SHA-256 digests. No original operator
root or source Kubernetes read is used during recovery. A disposable postgres18
container on the existing cp3 Docker host restores the known row with network
`none` and no published ports; the container is removed afterward. The remote
inventory head remains byte-identical. This models unavailable source access;
it does not claim a physical cluster outage or a supported public cross-cluster
restore/cutover command.

Before denying source access, the reviewer selects fourteen live Secrets from
the exact accepted and retained inventory, including source/retained database,
auth, backup-signing and platform credentials. Their data is encrypted with age
to an existing independent operator key and stored outside the original root.
The fresh recovery root decrypts the archive in memory and verifies every
recorded UID/data hash. [The credential proof](mp23-independent-results-2026-10-02/encrypted-credential-recovery-ec2e1cd4.json)
records only metadata and digests; plaintext credentials are never persisted
or printed. The encrypted archive and its independently held decryption key
remain separate. Inventory exports alone still do not contain generated live
Secret values, and this bounded fixture drill is not a production credential
escrow or full destination rebuild claim.

F04 is independently closed against the current supported publication contract.
The retained 35-test observation run proves two reads for two selected bindings
with 500 unrelated reviews and 50 siblings, selected-corruption refusal and
verified warm-cache recovery. Modern publications contain the digest-bound raw
inputs. The disposable-prerelease decision removes obsolete missing-byte-store
compatibility as a release gate; cold legacy fallback may still search original
archives. That documented limit is preserved, without claiming constant scope
decode cost or rewriting legacy history.

## Independent native cost and fresh-root closure

F06 now has the missing [real native active measurement](mp23-independent-results-2026-10-02/native-active-timing.json).
Installed ec2 prepares one reviewed isolated restore from the accepted v5 receipt.
An [audit-only harness](mp23-reproductions/Mp23NativeActiveTiming.hs) then invokes
the production app registry and transaction driver with timing wrappers around
real ObjectOps and kubectl processes. [Binary and worktree input hashes](mp23-independent-results-2026-10-02/native-active-source-bindings.json)
bind this instrumented execution; it is not an installed-binary timing claim.
The process takes 44.317s, including 31.924s in apply, 1.930s registry construction
and one 6.244s GCS journal batch. Six journal PUTs take 0.084–0.098s each; their
conditional head advances take 0.097–0.140s. Claim and finalization PUTs take
0.102/0.165s. [Individual IO calls](mp23-independent-results-2026-10-02/native-active-objectops.json)
and [provider process timings](mp23-independent-results-2026-10-02/native-active-provider-timings.json)
remain separate: 58 kubectl calls total 19.323s, including one 0.240s create and
9.949s completion wait; three gcloud setup calls total 1.975s. These are individual
call durations/sums, not a fabricated disjoint wall-clock decomposition.

The new isolated target returns the known row. All 30 prior scope revisions and
source/neighbor data identities remain exact; generation 813/sequence 687 is idle
with 31 scopes. The automatic CronJob's normal history limit removes one old,
completed, unaccepted v4 producer Job/Pod during these checks; the proof records
those exact identities rather than claiming an unchanged set of ephemeral Jobs.
Together with the retained real 61/500-event three-pair cold/warm budgets and
independently passing append/conditional-write/lost-ack/replay regressions, this
closes F06's stated excessive serial cloud-command defect.

F08 independently closes through [installed fresh-root evidence](mp23-independent-results-2026-10-02/fresh-root-host-ec2e1cd4.json).
No journal, marker or credential is copied; all original host input hashes match
and the delivery-only age-key variable is absent. Missing credential refusal,
explicit recovery and original Ready-node verification pass. The read-only
cluster plan takes 351.077s under 360s, with exact prerequisite revisions and no
host/foundation/Pulumi operations. Shared status and global contexts remain
unchanged; no cluster apply occurs. The [independent public regression output](mp23-independent-results-2026-10-02/fresh-root-public.txt)
also proves altered host inputs and altered existing credential bytes refuse.

Independent execution of `scripts/test-release-evidence-public.py` against the
built d1f2f9ec release-gate source, and `scripts/test-inventory-release-index.py`,
both passes. The public path accepts complete synthetic evidence and rejects
missing assets, stale bindings, missing required Redis assertions and expanded
deferrals before a forge request. This verifies EP-157's gate implementation;
it does not supply final native candidate evidence or authorize publication.

## Independent local Redis, ClickHouse and volume recovery

The installed ec2 candidate creates two bounded standalone databases and one
Knative application volume on the existing cp3 fixture. Every reviewed apply
adds only its intended scope; all nineteen original platform revisions remain
exact. The [native recovery evidence](mp23-independent-results-2026-10-02/local-engine-recovery-ec2e1cd4.json)
records the accepted receipt versions/digests, producer/source/consumer UIDs,
review digests and known-content assertions. This checkpoint uses versioned
in-cluster MinIO S3, not off-cluster GCS.

Both database CronJobs run automatically at `2026-10-02T21:00:00Z` and sign v5
recovery points at `21:00:01Z`. After completion, the reviewer conditionally
removes only those exact producer Jobs and their Pods with UID/resourceVersion
preconditions. Shared history and other observed identities remain exact.
Public receipt listing, reviewed ingestion and isolated restores then succeed
with the original producers absent. Redis restores its original key into a
separate server/PVC while the source retains its subsequently changed value.
ClickHouse restores only the original row into a separate database while the
source retains its additional post-backup row. Both accepted-only freshness
checks report healthy at age 515s. This proves an observed accepted recovery
point, not automatic ingestion or continuous one-hour compliance.

The volume snapshot contains `independent-volume-v1`; the live file is then
changed to `independent-volume-after`. Reviewed restore creates a distinct
scratch PVC. A read-only content check through the exact bound local PV on the
cp3 node verifies the original SHA-256, while the original Pod/PVC and changed
source contents remain intact. The storage command consumes the typed Service
Deployment projection of the application. Its current receipt contract checks
archive SHA-256; this evidence does not claim provider-version pins for volumes.
Final head generation 6166/sequence 6111 is idle with 29 accepted/converged scopes.

The [independently executed interrupted-upload regression](mp23-independent-results-2026-10-02/interrupted-upload-regression.txt)
also passes: failed stored-byte readback yields no signed receipt, and retrying
an orphan object refuses. These isolated restore assertions do not establish
live-target cutover or full source-cluster-unavailable recovery for every engine.

## Cloud volume recovery and remaining ClickHouse verification

The [independent cloud volume proof](mp23-independent-results-2026-10-02/cloud-volume-recovery-ec2e1cd4.json)
uses the installed ec2 candidate and the eligible ep150 fixture. A reviewed
linux/amd64 image publication and application volume are followed by a manual
GCS snapshot and isolated scratch-PVC restore. A disposable nonroot verifier
mounts only the exact scratch claim read-only, uses the observed image digest,
and reads the original file. Its UID/version-bound cleanup changes no shared
history. The source Pod/PVC remain intact with their later file contents; all
31 original scope revisions remain exact. This is a manual volume snapshot and
isolated content restore, without provider-version pins or a scheduled-volume
recovery-point claim. Intermittent project-number lookup refusals stopped planning
before effects; later real ownership lookups succeeded without a guard override.

A genuine automatic ClickHouse GCS run is ingested after exact producer cleanup.
Its restore writes the correct isolated data but the immediate follow-up SELECT
hits a transient connection refusal, making the Job terminal Failed. Independent
queries confirm backed-up and later source rows. Original-transaction resume
stops stably ambiguous; explicit digest-bound terminal recovery releases history
while preserving the failed Job, archive and scratch database. [F22 evidence](mp23-independent-results-2026-10-02/cloud-clickhouse-terminal-verification-ec2e1cd4.json)
is retained. The repaired source's [six focused tests](mp23-independent-results-2026-10-02/clickhouse-retry-regressions.txt)
independently pass in 1.67s, and the native 25.8 client accepts the bounded timeout
flags. The installed repaired-candidate continuation below closes the native gap.

The [public Google and Cloudflare collection proof](mp23-independent-results-2026-10-02/cdn-retained-collection-public-71068ad0.json)
independently passes changed-record refusal, exact retained hostname pairing,
lost-response recovery without resend, and preserved namespaces/neighbors after
last-contributor withdrawal. Source review confirms narrowly recognized namespace
carry and digest-bound historical DNS ownership. These use isolated provider
recorders; final installed/native candidate bindings remain separate.

A local evidence-selection correction replaces the ClickHouse consumer metadata
accidentally taken from an earlier Redis scope in the same review. The collector
now selects the exact engine/owner scope, and the actual completed ClickHouse Job
UID and restored row were independently checked again. The local recovery result
records this correction and its updated hash; native product behavior was unchanged.

## Installed ClickHouse repair, authenticated Redis, and operation recovery

The [e625 local gate](mp23-independent-results-2026-10-02/local-platform-candidate-e6255e6f.json)
passes 213 verification operations with zero provider mutations and unchanged
contents for all 29 accepted scopes. Its public plan/apply take 46.315s/64.086s.

The [cloud engine evidence](mp23-independent-results-2026-10-02/cloud-engine-recovery-e6255e6f.json)
binds exact accepted GCS generations, producer cleanup, reviewed consumers and
known-content queries. ClickHouse's repaired installed consumer experiences the
same transient connection refusal after one successful RESTORE; its bounded
read-only retry completes. The new isolated database contains the backed-up row,
the source retains its later row, and the prior failed Job/database remain intact.
All 42 previous scope revisions survive, including the original 31 fixture scopes.
Neighboring PostgreSQL Pod UIDs and known rows remain exact. F22 is Closed.

Redis's second automatic run uses an authenticated seed and restores that exact
value into a separate server while the live source retains its later value. The
first cloud Redis seed omitted authentication; Redis returned NOAUTH with exit
zero. That first receipt/restore represents an empty backup and is excluded from
known-content claims. Corrected evidence uses the second genuine automatic run.
Its accepted-only freshness check warns at age 1806s, despite a newer verified
upload awaiting ingestion. Automatic upload and reviewed manual acceptance are
distinct. These results prove observable recovery-point health/warnings, not
unattended continuous one-hour RPO or critical-workload production readiness.

The [independent public operation driver](mp23-independent-results-2026-10-02/operation-driver-e6255e6f.json)
passes 11 fresh-process commands on an isolated build. Absent, terminal, running,
completed and changed-source states behave correctly; explicit terminal recovery
remains reachable and completed replay performs no provider IO. The probe-only
overlay now imports the extracted Execute.Journal helper and disambiguates the
new BackupReceipt memory import; production source is unchanged. F12/F13 close.
F09 retains its finite separate retained-source CLI verification requirement.
New scheduled-prune admission independently refuses before effects. No real
provider deletion or newly supported prune mutation is claimed.

The F09 retained-source follow-up is a negative graph-validity test: removing the
source owner while its accepted prune still depends on it refuses before IO in
all 11 commands, with identical history. It is not reachable supported history.
The [recorded boundary](mp23-independent-results-2026-10-02/invalid-retained-source-e6255e6f.json)
closes F09 against the existing supported contract and disposable-prerelease
disposition; new pruning and invalid historical-state repair remain unsupported.

## Producer-free manual GCS recovery and selected-read scaling

The [installed manual recovery](mp23-independent-results-2026-10-02/manual-gcs-recovery-e6255e6f.json)
passes on a new eligible disposable backup. Reviewed receipt acceptance retains
the completed Job; a separate reviewed collection removes its exact UID. A fresh
isolated restore then completes with the producer absent and both accepted GCS
generations present in the real download-container environment. The known row,
live source and neighbor rows/Pod UIDs remain exact; all 43 prior scopes survive.
The source was not changed to manufacture a new post-backup difference. F19 closes
without accessing or changing retired F15 history. The [installed public GCS
regression](mp23-independent-results-2026-10-02/manual-gcs-public-e6255e6f.txt) also
executes the rendered generation-pinned download shell with strict recorders.

[Independent selected-read runs](mp23-independent-results-2026-10-02/selected-read-scaling-e6255e6f.json)
at 50 and 500 unrelated resources preserve the same one-call Kubernetes/Helm
boundary, early invalid-target refusal and unchanged history. F10 is Closed.
The installed [foundation public fixture](mp23-independent-results-2026-10-02/foundation-e6255e6f.txt),
[release evidence gate](mp23-independent-results-2026-10-02/release-public-e6255e6f.txt),
[ten readiness/registry/stopped-driver tests](mp23-independent-results-2026-10-02/readiness-registry-stop-e6255e6f.txt),
and [rendered registry delegation checks](mp23-independent-results-2026-10-02/registry-delegation-e6255e6f.txt)
independently pass. These strengthen their source/public boundaries; they do not
substitute for fresh-host credential expiry/re-pull acceptance or native Google
CDN backend acceptance. Active ep150 still has its legacy accepted host and
disabled platform CDN backend.
