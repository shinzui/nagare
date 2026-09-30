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
explain the full elapsed time. The next step is a focused observation repair that
keeps context and node validation and effect-time guards, followed by a bounded
development-binary probe, focused regression test, installed-package build, and
exact public cluster review. Do not apply a cluster review until it is inspected.

## Remaining native work

Three existing immutable auth image manifests were inspected read-only: all are
Linux/amd64. Their runtime compatibility remains subject to cluster acceptance.
A new disposable Grafana credential is encrypted under the fixture's existing age
recipient; plaintext is absent from checked-in evidence. Second-root bootstrap
still needs the shared-history discovery repair described above. No cluster apply
has occurred in this checkpoint. M1/M2 and the broader MP-23 native/recovery/release
gates remain open.
