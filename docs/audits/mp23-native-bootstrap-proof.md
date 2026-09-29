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

## Remaining native work

The repaired public bootstrap regression passes. Installed-package continuation
must still pass before claiming native kubeconfig acceptance. Three existing immutable auth
image manifests were inspected read-only: all are Linux/amd64. Their runtime
compatibility remains subject to cluster acceptance. A new disposable Grafana
credential is encrypted under the fixture's existing age recipient; plaintext is
absent from checked-in evidence. No cluster apply has occurred in this checkpoint.
M1/M2 and the broader MP-23 native/recovery/release gates remain open.
