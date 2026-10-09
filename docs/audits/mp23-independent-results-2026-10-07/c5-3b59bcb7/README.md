# C5 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09: the non-publishing release assembly (EP-157) for 0.4.0 from
candidate `3b59bcb7612d513bfd663c36c251f8454e615502`. Nothing was tagged or published.

**Inputs.** Each system's native inputs mirror the release workflow's `build` job, run locally:
- `check-release.sh --version 0.4.0 --json` (manifest and notes);
- the clone-free rehearsal (C4);
- `nix-output-<system>.json` from `nix path-info` of `.#nagarectl` and `.#nagare-platform`.

On aarch64-darwin these ran from a clean candidate worktree. On x86_64-linux they ran in the C4
amd64 container (`native-x86_64-linux/`: `x86-release.sh`, `gate.json` with `consistent: true`,
`release-run.log`). That container builds only the `release-tools` bundle; everything else is
substituted. It also installs `gawk` and the GNU basics, which a GitHub runner image already has.

The public scenario evidence is
[`docs/release-evidence/3b59bcb7…/`](../../../release-evidence/3b59bcb7612d513bfd663c36c251f8454e615502/).
It holds `coverage.json`, plus `local/` (C2) and `cloud/` (C3). Each scenario directory has
`target.json`, `<mode>-health.json`, `fixture.json`, `inventory-evidence.json`, and the
`checks/` files that its assertions bind by SHA-256.

**Result.** `scripts/assemble-release.sh --version 0.4.0` passed, and its output is `dist/`:
- the two native manifests are identical apart from `payloadDigest`, and the notes are
  byte-identical;
- both systems have exactly one output manifest and one clone-free rehearsal;
- the inventory index binds the local and cloud runs to the candidate's revision and payload;
- `shasum -a 256 -c SHA256SUMS` passes.

A second assembly from the same inputs is byte-identical.

**IR-24 mapping.** Every assertion named in the notes' "IR-24 acceptance evidence" table is in the
health record of the run it names:
- `retained-postgresql-rename` is local only;
- `shared-history-takeover` is cloud only;
- the other seven are in both runs;
- case 7 is this assembly.

The notes state the unmet production targets. They make production readiness conditional on
checklist sections 3 and 4.
