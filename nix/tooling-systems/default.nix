# Systems that receive only the packaged CLI, its configuration SDK and the SDK
# consumer check: tooling support, not host support (ADR 3). This is a flake
# input so the full gate's `nix flake check --all-systems` can leave these
# systems out, as nix/tooling-systems/none does: their checks need a native
# builder that the landing gate does not have.
[ "aarch64-linux" ]
