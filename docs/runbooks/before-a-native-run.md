# Before a native run (maintainers and agent sessions)

Run this checklist before any mutation on cp3 (the shared local cluster) or on a cloud context, and
before asking the operator to approve a cloud sequence. It applies to implementers and reviewers alike.
Every item comes from a defect or a lost run in MasterPlan 23; the
[2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md) has the data, and
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) is the rule
behind it. A native run confirms that the interpreters match reality. It must never be the first
execution of a path.

If any item fails, fix it before the native run. Do not record the failure as a known limitation and
go ahead.

## 1. The path is already covered by an interpreter

- Name every adapter path the run will exercise: create, update, verify, retire, collect, restore,
  recovery decision.
- For each, point to the in-memory test that drives it through the adversarial provider states:
  lost acknowledgement, landed but unready, landed and failed, replaced (new UID at the same address),
  renamed (address change inside a transaction), foreign field manager, and a transient provider or
  store failure.
- Point to the stuck-state invariant test that covers its transaction: every reachable stopped state
  has a supported reviewed exit, and nothing unreviewed becomes accepted.
- If no such test exists, write it first. It either passes, in which case the native run confirms it,
  or it fails, in which case you have found the defect in seconds instead of hours.

## 2. The workload actually runs

A saved review proves only that the change plans. Before applying any fixture application or
"corrected" configuration to a cluster:

- read the image's entrypoint or source for the environment variables and bindings it requires, and
  check that the declaration provides them; or
- run the container locally (`docker run` with the same environment) and see it serve.

For the acceptance fixtures this is `just fixture-smoke`. It builds every application listed in
[`fixtures/inventory-release/local/fixture-smoke.json`](../../fixtures/inventory-release/local/fixture-smoke.json),
starts its declared backing services (`postgres:18`, `redis:8`) on a throwaway network, runs it with
only the declared variables and probes it. It also checks that scenario-b bound only to PostgreSQL
fails. A new or "corrected" fixture is added to that manifest and smoke-run before any cluster apply.
The smoke refuses a Docker daemon that hosts a k3d cluster (cp3 or a local acceptance cluster), so
point `DOCKER_HOST` at a separate daemon, such as another Colima profile.

The phase-3a correction that wedged `mp23-c3i` ([F54](../audits/mp23-findings.md#f54)) reused the
scenario-b image, which needs `REDIS_URL`, with a PostgreSQL binding.

## 3. The gates are green at this revision

[EP-174](../plans/174-gate-every-commit-before-any-native-run.md) turns this section into commands:

- Every push: run `just install-hooks` once per clone. `.githooks/pre-push` then runs `just gate-fast`
  and refuses the push when it is red. The fast gate first runs `just haskell-style-check` and
  `scripts/test-managed-command-audit.sh` (the architecture checks and the managed-command audit), which take seconds,
  then builds and runs the `nagarectl` and `nagare-dsl` suites serially, each from its package directory. Its logs go under
  `${XDG_STATE_HOME:-~/.local/state}/nagare/gates/logs/`. The hook tests the working tree, so push
  from a clean tree.
- Every candidate: on a clean checkout of the exact revision, run `just gate`. It runs the fast gate,
  builds a salted probe derivation on every remote system (so a stopped Linux builder fails here
  instead of hiding behind cached outputs), runs `nix flake check --all-systems`, then dry-runs every
  check of every supported system and requires nothing left to build or fetch. It writes
  `${XDG_STATE_HOME:-~/.local/state}/nagare/gates/<commit>.json`.
- Before any native step: `just gate-verify <rev>` must print `green`. It refuses a missing, red or
  dirty-tree record, a record for a different tree, a failed probe, and any `release.json` system
  without every check realised.
- A green result from an earlier revision is not a green result for this one.

## 4. Scripts and the evidence pipeline are rehearsed

- Every non-trivial live command is in a script file (bash with `set -euo pipefail`, or a Haskell
  harness command under [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)),
  not a zsh one-liner. Run it once against scratch data or a dry run first.
- Never write a file in the same expression that reads it. Check `git diff --numstat` before every
  commit.
- Run the evidence consumer (the assembler, the scenario-assertion recorder, the findings tracker)
  against the planned layout using a scratch copy of real prior output. A cluster step that passes
  proves nothing about whether its evidence will assemble.
- Every assertion that a run "had zero X" must read the complete listing, not a sample, and must
  cover the whole window in which X could occur (for example the middle of a migration).

## 5. The environment facts are known

- The live shell is bash, started from `env -i` plus `nagarectl context env`. The kube server and node
  are asserted before any `kubectl`.
- The interactive shell is zsh: it does not word-split unquoted variables and aborts a command on an
  unmatched glob. GNU coreutils may shadow BSD tools on PATH (`date`, `sed`, `stat`).
- A foreground tool call times out after 120 seconds. Long reads and waits run in the background with
  a completion condition.
- Commit hashes are copied from `git` output, never typed from memory.

## 6. The stop threshold is written down

Before asking for approval, write the bounded sequence and, for each step, the result that means
"stop and report". Ask once for the whole sequence. Then:

- stop at the first unexpected result, and at any guard refusal;
- label every recorded value as observed or inferred when you write it;
- never propose deferring a finding to save time. Only the operator defers, and only with the current
  deferral ledger in front of them (see the retrospective's deferral section).
