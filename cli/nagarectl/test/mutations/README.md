# Recovery-model mutation records (EP-173)

Each diff reverts one finding's guard. Applied in a scratch worktree (never in a
shared checkout), it must make the recovery model fail with a violation that names
that finding's scenario:

```bash
git worktree add "$SCRATCH/mut" HEAD
git -C "$SCRATCH/mut" apply "$PWD/cli/nagarectl/test/mutations/<name>.diff"
(cd "$SCRATCH/mut/cli/nagarectl" && cabal test nagarectl-test --test-options='-p "recovery model"')
git worktree remove --force "$SCRATCH/mut"
```

| Diff | Guard reverted | Expected failure (2026-10-05, at `c9a86b82`) |
|---|---|---|
| `F16-unready-create-stop.diff` | the stop of an unready created Service (`RecoveryAwaitingReadiness`) | I1 under `LandsUnready` on the Service create (5 violations) |
| `F30-refresh-before-state-at-write.diff` | a version-2 write submits the current resourceVersion | I7: under persistent status churn a good update needs an exit (16 violations) |
| `F35-abandon-after-fresh-preflight-refusal.diff` | abandoning a never-intended operation after a fresh preflight refusal | I1 under `ForeignObject` at a planned create (11 violations) |
| `F37-abandon-journalled-no-effect-refusal.diff` | abandoning an operation whose journal shows a no-effect refusal | I1 under a persistent foreign field manager (16 violations) |
