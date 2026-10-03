# MP-23 fresh-root discovery repair — 2026-09-29

The repair is committed as `27462937`, with the second-root observation follow-up
in `6082dbd6`. It addresses the separate blocker proved in
[the investigation](mp23-fresh-root-discovery-proof.md). The cluster timeout
repair `2d6b57c0` and evidence `71fce0a4` remain separate. This checkpoint does
not accept cluster convergence, EP-156 M1/M2 or independent F08 closure.

## Implemented authority boundary

Bootstrap now selects authority before workspace/provider setup through one
read-only service. It validates the persisted/active/ambient project, selected
URL, globally named bucket's numeric owner, canonical format, supported head
and exact context/project binding. An unmarked fresh root uses existing GCS
history. Discovery does not initialize format/head, create client identity or
cache, or acquire a writer. The total deadline is 60 seconds; SDK requests and
gcloud credential/ownership subprocesses retain their shorter limits.

A structured global bucket 404 proves the missing-bucket case. An owned prefix
with no format requires a one-member query proving emptiness. Project-list
omission, denied/failed reads, partial pages and timeouts cannot mean absence.
Foreign format/head/owner, missing head, remaining objects without format,
future schema and migrated remote history refuse. Substantive unmarked local
history beside remote history requires conflict resolution. Exact migration
destinations, verified migration and missing-destination refusals remain.
Foundation apply repeats this selection before constructing provider adapters.
Both default SDK and legacy object-transport selections use structured SDK
reads for authority discovery; unsupported SDK identity/endpoints refuse.

## Two-root consumer failures and recovery

The first source consumer found shared history but planned a Pulumi stack
update in 104.249 seconds: `pulumi config` read an empty workstation file as
drift. That diagnostic review was not applied. Bootstrap now restores only an
empty context-owned configuration from the already accepted backend with
`pulumi config refresh`; nonempty operator configurations stay drift-checked.
This updates local config/encryption metadata, not provider resources.

The next never-used root reached the explicit missing-current-root credential
refusal in 86.583 seconds under the existing 120-second bound. Accepted
kubeconfig scopes retain the first root's absolute source/destination paths.
`nagarectl --context ep150-preview kubeconfig recover` fetches credentials for
the accepted host, validates identity, content/spec digest, dependencies and
policies, and installs an absent current-root projection privately. Changed
existing files, symlinks and uninitialized/unresolved history refuse. Recovery
succeeded in 13.080 seconds, with global contexts unchanged.

The actual cluster consumer then refused the first root's artifact-observation
destination in 146.447 seconds. The follow-up makes only the planner's read-only
observation use an unchanged accepted credential's validated current-root bytes.
Retained scopes, review bytes, native preparation and effect paths remain bound
to their original envelopes. The repaired source consumer saved 210 operations
with zero barriers in 334.580 seconds under the separate 360-second cluster-plan
bound. No operation targets any of the six accepted prerequisite scopes.
Shared generation 113, sequence 65 and head digest remained unchanged. No
cluster apply ran.

Private source evidence is retained under
`/tmp/nagare-mp23-fresh-root-repair-consumer-v1` and
`/tmp/nagare-mp23-fresh-root-repair-consumer-v2`. These experiments copied only
context profile and host inputs into separate config/state/cache roots, without
inventory, migration marker, original Pulumi config or credential.

## Local acceptance

- All 983 CLI tests pass; the original 81-test focused group and subsequent
  12-test artifact group pass.
- The 36-case public authority matrix covers both transport selections,
  existing/empty/missing authority, foreign owner/format/head, incomplete/future/
  migrated history, denied bucket/object reads, partial listing, local conflict,
  wrong migration destination and a missing migrated destination. Discovery
  performs no head, cache or provider writes. Negative recovery paths refuse too.
- The complete public foundation/bootstrap fixture passes, including API/Pulumi/
  image/host/kubeconfig lost-ack recovery, second-config-root credential
  materialization, changed-file refusal and the 211-operation cluster review.
- SDK migration and cold/warm read-only regression fixtures pass; Haskell style
  checks and Python fixture/reproducer syntax checks pass.
- The optional local-bootstrap fixture stops at its stale 209-operation
  assertion, observing 217. The unchanged installed `2d6b57c0` baseline produces
  the identical failure with current source assets. Its script was preserved;
  this is not a passing local-bootstrap acceptance claim.

## Installed acceptance

Clean candidate `6082dbd6aac0` built as an installed Darwin package. The
never-used-root status read shared generation 113 in 3.177 seconds. Bootstrap
reached the explicit missing-current-root credential refusal in 54.109 seconds
under the unchanged 120-second limit. Recovery succeeded in 7.713 seconds;
the mode-0600 credential reached the same Ready node in 0.348 seconds.
The installed cluster plan succeeded in **319.659 seconds** under the original
360-second limit, saving review
`1006f60f5e9afcf3e8e73b98462187b3cef1c268bcdb7035dccb6ab65e3262f1`.
It contains 210 operations (203 Kubernetes, five Helm and two artifact), zero
barriers, and exact base revisions for all six accepted prerequisite scopes.
No operation targets those scopes; no bucket, Pulumi stack, retained host image,
host or kubeconfig recreation is proposed. The artifact operations concern the
new controller image and its declared operation, and have not executed.

Final status in 3.736 seconds matches the initial status exactly: generation 113,
sequence 65, the same head digest, and no active transaction, executor claim,
data fence or migration. Global gcloud/kube contexts are unchanged. No local
inventory exists; no marker, journal, original Pulumi config or credential was
copied. No cluster apply occurred. Private evidence is retained in
`/tmp/nagare-mp23-fresh-root-installed-6082dbd6`; the
[redacted metrics](mp23-native-bootstrap-results-2026-09-29/fresh-root-repair.json)
retain package identity, timings, scope revisions and review digest.

The reusable [runner](../mp23-reproductions/probe-bootstrap-second-root.py) retains
120-second credential and 360-second cluster-plan bounds, verifies the expected
Ready node, checks the six accepted prerequisite scopes, compares shared status
and global contexts, and never invokes cluster apply.

This is a fresh local-root consumer proof. Previously published immutable
members may be reused; it is not a cold remote-publication benchmark or
acceptance of the cluster review's effects.
