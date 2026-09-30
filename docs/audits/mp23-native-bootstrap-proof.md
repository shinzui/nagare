# MP-23 native bootstrap continuation — 2026-09-29

This EP-156 checkpoint uses the retained disposable `ep150-preview` fixture in
`tan-ng-labs`, Compute Engine `us-west1-a`, running NixOS/k3s. It does not use GKE
or change global gcloud/kubectl contexts. Native credentials, reviews and full logs
remain private under `/tmp/nagare-mp23-native-acceptance`.

## Native host evidence

At source candidate `4db1e2e1`, read-only provider inspection found VM instance ID
`865479739011671762` RUNNING with account
`nagare-ep150@tan-ng-labs.iam.gserviceaccount.com`. IAP inspection using the host's
actual authorized operator key found k3s active and node `nagare-ep150` Ready,
version `v1.35.8+k3s1`. The system and profile closures agreed, the rollback timer
was inactive, and the persisted age-key digest matched the original review.

After the operator logged into Tailscale, the production host transport's `inspect`
returned `HostTransportCommitted` for the exact retained native plan and physical
VM. This ran the repaired fresh-login path, including an actual Tailnet SSH login;
it did not replay the converged transaction or reactivate the host.

The installed Darwin package built from `4db1e2e1` was invoked outside the checkout
with isolated XDG roots, explicit `labs` gcloud configuration and project, the
exact SSH key, one IAP attempt, and no `NAGARE_HOST_AGE_KEY_FILE`. The next public
bootstrap plan failed in 43.501 seconds before any provider mutation: its retained
host lock referenced the mutable local `nixos` source, whose NAR hash changed when
the fresh-login repair was committed. The accepted configuration and lock bytes
had not changed. This exposed an unnecessary installation-source dependency in
bootstrap continuation, not failed host convergence.

## Repair and discriminating validation

`runAfterCloudStage` now validates the accepted host inputs and proceeds to
kubeconfig/cluster stages once the host is accepted. First installation still
reviews and executes build, publication and host stages in order. Accepted image
scopes stay in the composed inventory.

The public bootstrap fixture disables Nix after host acceptance, verifies that
changing each of `flake.nix`, `host.nix`, and `flake.lock` still refuses, then
requires kubeconfig planning/recovery and the complete cluster review. Its first
run against the sequencing repair reached the final cluster review and exposed a
second source evaluation in artifact observation. `upload-images.sh --inspect-build`
now checks the reviewed output path and its digest directly; actual build execution
still reevaluates and validates the selected output. The dedicated upload-images
fixture passes with evaluation disabled and refuses a mismatched path digest.
The fixture also now supplies its own mock builder transport instead of depending
on ambient tunnel environment. Haskell build and style checks pass. The complete public bootstrap regression then passes, including lost-acknowledgement recovery, the unchanged 211-operation cluster review, kubeconfig dependencies, the final marker, and native local Pulumi stack initialization.

## Follow-up native diagnoses

Installed candidate `b137d0c7` passed the installation-source boundary, then
refused in 55.095 seconds during accepted host comparison. Current configuration,
lock, credential and resource-spec digests exactly matched the retained native
review. Its operation input list was canonicalized on persistence (lock digest
before configuration digest), while the compiler produced configuration first.
Raw Haskell equality therefore rejected the same declaration. Host comparison now
uses the existing canonical scope encoder; the public fixture forces reversed
input ordering to reproduce this boundary instead of relying on favorable hashes. The strengthened complete public fixture passes, including its 211-operation cluster review; Haskell build and style checks pass.

A separate development-binary plan from `/tmp/nagare-mp23-native-second-root`,
with copied context/host inputs but no journal or delivery-key environment, refused
in 32.555 seconds before effects. `cloudFoundationPending` and
`foundationStageTarget` treat a missing local migration marker as a new foundation,
without consulting existing shared history. The existing bucket and stack then
correctly refuse ownership adoption. Second-root bootstrap remains blocked: probe
the exact selected remote foundation/store when no local history exists, distinguish
proved absence from unavailable/foreign ownership, and retain conflict/migration
refusals for nonempty local history. Verify both an actually fresh foundation and
an existing shared GCS head before claiming this repaired; copying a migration
marker is not the acceptance path.

The [fresh-root investigation](mp23-fresh-root-discovery-proof.md) now reproduces
that blocker on clean installed candidate `2d6b57c0`. Direct status from the same
never-used config/state/cache root reads correctly bound shared history in 3.434
seconds; bootstrap uses empty local history and refuses the stamped bucket/stack
in 38.228 seconds. Shared head generation 113 and the global context files remain
unchanged. Installed recording-provider probes distinguish missing/unavailable/
foreign state and expose project-list false absence, incomplete-prefix and head-
binding boundaries. A real separate empty-prefix read refuses in 2.873 seconds
without local state/cache writes. The report and
[redacted results](mp23-native-bootstrap-results-2026-09-29/fresh-root-discovery.json)
define the effective repair and its source-established follow-on kubeconfig path
portability check. The 38 object-operation and 17 SDK transport tests pass.
No production discovery fix or cluster apply was made; this remains separate
from the accepted cluster planning timeout repair below.

## Installed native kubeconfig acceptance

Candidate `0870fa200d07` built as an installed Darwin package. Its complete public
plan ran outside the checkout in 47.702 seconds without the transient age-key
variable and selected only `platform:kubeconfig/context-kubeconfig/ep150-preview`.
Review `c18ab36123739145ebefe9025a6ea62e4ca72f2874d58e9b85e5fda065eae21a`
binds payload `nagare-bootstrap:nagare-0.4.0-0870fa200d07`, context and project.
The public apply converged that exact transaction in 15.348 seconds. The installed
kubeconfig is mode 0600 and reached the same Ready node in 0.247 seconds; node UID
`d3745745-a1e2-4a07-9479-2832b893d7dc` is unchanged. A 3.654-second store status
returned GCS head generation 113 with no active transaction, executor claim or
data fence. Before apply it was generation 107. No global context was switched.

[The redacted result](mp23-native-bootstrap-results-2026-09-29/kubeconfig.json)
retains candidate, review, timing and before/after head evidence. The preceding
development-binary plan and prepared-credential API probe took 65.413 and 0.835
seconds respectively; they are separately labelled, not installed-package claims.
This establishes a complete public active transaction with real GCS authority and
native artifact execution, not full multi-resource cloud convergence.

## Cluster-review timeout checkpoint

The installed cluster plan reached its 360-second limit without publishing a review
or starting an apply. A 120-second development-binary probe localized the delay to
observation of 201 Kubernetes resources, before change planning or review
publication. The observation path visits those resources serially; each visit runs
the cluster guard, which executes `kubectl config current-context` and
`kubectl get nodes`, before the resource's own `kubectl get`. This is a measured
location and a source-level command count, not yet proof that guard calls alone
explain the full elapsed time. The repair and bounded runs below test that
hypothesis while retaining context/node validation and effect-time guards.

## Kubernetes scan repair and source proof

The runtime now brackets the read-only Kubernetes scan with two fresh cluster
guards. Each object read still selects the explicit context. A refused check at
either boundary makes every result unavailable; a failed initial check performs
no object reads. Preparation, preflight, execution, verification and recovery
retain their individual guarded observations and conditional write behavior.

The focused suite passes 77 tests, including 201 reads with exactly two scan
guards, both boundary refusals, and individual reads across all effect paths.
The public bootstrap regression still produces its expected 211-operation review.
The structural Haskell style scan passes. Whole-file Fourmolu checks fail on
existing formatting at HEAD as well as the changed files; unrelated formatting
was not rewritten for this repair.

A 120-second source probe completed all 201 object reads in 40.424 seconds but
did not complete the composed observation. Executor tracing then measured the
Kubernetes scan at 44.036 seconds and located the diagnostic cutoff in artifact
observation. A complete source run under the original 360-second bound succeeded
in 341.907 seconds. It measured Kubernetes observation at 43.780 seconds and
retained 203 individual preparation guards (49.751 seconds total). Review
publication remains sequential and slow; the scan repair does not establish a
separate publication performance gate.

The saved source review has 210 operations (203 Kubernetes, two artifact, five
Helm), zero barriers, and digest
`25fa33d46d5d66da21441acb1a1977a7e868f641ae72cfd7332d07607d6a845b`.
The already accepted kubeconfig explains the difference from the public fixture's
211 operations. This is development evidence against the retained installed
payload, not final installed acceptance. The [redacted metrics](mp23-native-bootstrap-results-2026-09-29/cluster-plan.json)
distinguish the original installed timeout from source proof. Temporary tracing
has been removed. The installed acceptance below uses the committed clean
candidate; no cluster apply is authorized by this debugging checkpoint.

## Installed cluster-plan acceptance

Clean candidate `2d6b57c0` built as an installed Darwin package and ran outside
the checkout with the same isolated credentials and the original 360-second
limit. Its fresh payload workspace installed the locked Pulumi Node dependencies.
The complete public plan succeeded in **295.454 seconds** and saved review
`90cd2f8cf18a441c4f6ae9f1261e6dff7def393c800233d1b9c0202688268f75`,
bound to `nagare-bootstrap:nagare-0.4.0-2d6b57c02179` and the exact fixture
context/project. The inspected review has 210 operations (203 Kubernetes, five
Helm, two artifact), zero barriers, only platform resource identities, and a
bootstrap marker depending on all 209 other operations. The two artifact
operations create the controller image resource and run its declared operation;
neither has executed.

This run reused immutable members published by the successful source probe;
it is not a cold publication benchmark. A fresh installed store status took
5.356 seconds and returned unchanged head generation 113 and digest
`f536c6d2f48c5d5bde01460a072f15e2d328d2a49433a1f0e20c44baf59416fe`,
with no active transaction, executor claim or data fence. Explicit-kubeconfig
verification took 0.583 seconds and found the same Ready node UID
`d3745745-a1e2-4a07-9479-2832b893d7dc`. The linked redacted metrics retain these
final-candidate results separately from source timing and the original timeout.
No cluster apply or global context switch occurred. This accepts the bounded
planning repair, not cluster convergence or the second-root history repair.

## Remaining native work

Three existing immutable auth image manifests were inspected read-only: all are
Linux/amd64. Their runtime compatibility remains subject to cluster acceptance.
A new disposable Grafana credential is encrypted under the fixture's existing age
recipient; plaintext is absent from checked-in evidence. Second-root bootstrap
still needs the shared-history discovery repair described above. No cluster apply
has occurred in this checkpoint. M1/M2 and the broader MP-23 native/recovery/release
gates remain open.
