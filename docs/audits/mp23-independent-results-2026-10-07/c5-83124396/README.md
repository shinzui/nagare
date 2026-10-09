# C5 on the final candidate `83124396`

nagare-verify ran this on 2026-10-09: the non-publishing release assembly (EP-157) for 0.4.0 from
candidate `831243962c6b80f91da1028cdab8238ae6acdabd`. Nothing was tagged or published. The
procedure is the one used for `3b59bcb7` ([`../c5-3b59bcb7/`](../c5-3b59bcb7/README.md)).

**Inputs.** Each system's native inputs mirror the release workflow's `build` job, run locally:
- `check-release.sh --version 0.4.0 --json`, which gives the manifest and the notes;
- the clone-free rehearsal (C4);
- `nix-output-<system>.json`, from `nix path-info` of `.#nagarectl` and `.#nagare-platform`.

On aarch64-darwin these ran from a clean candidate worktree. On x86_64-linux they ran in the C4
amd64 container: see [`../c4-83124396/`](../c4-83124396/README.md), with `x86-release.sh` and
`check-release-x86_64-linux.json`.

The public scenario evidence is
[`docs/release-evidence/83124396…/`](../../../release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/).
It holds `coverage.json`, plus `local/` from C2
([`../c2-acceptance-83124396/`](../c2-acceptance-83124396/README.md)) and `cloud/` from C3 on
`mp23-c3m` ([`../c3-acceptance-83124396/`](../c3-acceptance-83124396/README.md)). Each scenario
directory carries:
- `target.json`, `<mode>-health.json`, `fixture.json` and `inventory-evidence.json`;
- the `checks/` files that its assertions bind by SHA-256.

**Result.** `scripts/assemble-release.sh --version 0.4.0` passed (`assemble.log`), and its output
is `dist/`:
- the two native manifests are identical apart from `payloadDigest`, and the notes are
  byte-identical;
- both systems have exactly one output manifest and one clone-free rehearsal;
- the inventory index binds candidate source revision `83124396` and each system's payload
  digest, and both runs' `inventory-evidence.json` name the same source revision;
- `shasum -a 256 -c SHA256SUMS` passes.

A second assembly from the same inputs is byte-identical.

**IR-24 mapping.** Every assertion named in the notes' "IR-24 acceptance evidence" table is in the
health record of the run it names:
- `retained-postgresql-rename` is local only;
- `shared-history-takeover` is cloud only;
- the other seven are in both runs;
- case 7 is this assembly.

The local run has 16 assertions, and the cloud run 17.
