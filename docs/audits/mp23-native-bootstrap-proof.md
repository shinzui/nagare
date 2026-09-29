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

## Remaining native work

The repaired public bootstrap regression passes. Installed-package continuation
must still pass before claiming native kubeconfig acceptance. Three existing immutable auth
image manifests were inspected read-only: all are Linux/amd64. Their runtime
compatibility remains subject to cluster acceptance. A new disposable Grafana
credential is encrypted under the fixture's existing age recipient; plaintext is
absent from checked-in evidence. No cluster apply has occurred in this checkpoint.
M1/M2 and the broader MP-23 native/recovery/release gates remain open.
