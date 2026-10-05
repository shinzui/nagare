---
id: 174
slug: gate-every-commit-before-any-native-run
title: "Gate every commit before any native run"
kind: exec-plan
created_at: 2026-10-05T03:18:08Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-05T03:18:08Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T17:56:25Z
      mode: "implement"
      note: "M2 and M5 done; M3/M4 implemented (acceptance pending); nagare-harness package created"
---

# Gate every commit before any native run

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-10-04 the release candidate `84754389` reached its release gate with `nix flake check`
failing on both supported systems (finding F53). Nothing had run the flake check for many commits.
GitHub Actions has been off since 2026-09-22, and no local gate replaced it. The Linux builder was
down during at least one check that was reported as passing. The same day, a crash-looping fixture
application wedged a cloud context (F54's trigger), because nobody ran the container before applying
it. Each of these was found at the most expensive moment.

After this plan, every push runs a fast local gate, and every candidate requires a full local gate
record for its exact revision. The fast gate covers both Haskell suites, the style and architecture
checks, and exhaustiveness as a compile error. The full gate adds `nix flake check --all-systems`,
with proof that the Linux builder really built. The scripted acceptance harness refuses to start
without that record. A maintainer can also smoke-run every fixture application locally with its
declared environment before any cluster sees it.

A maintainer sees this work in four ways:
- `just gate` prints each step and writes a record;
- a push with a failing suite is refused by the pre-push hook;
- `nagare-harness gate verify --revision <rev>` refuses a revision without a green record;
- `just fixture-smoke` fails on the scenario-b image when it is given a PostgreSQL binding instead
  of `REDIS_URL`.

The operator decided on 2026-10-04 that gating does not use GitHub Actions ("so slow"). Everything
here runs on the maintainer's machine and the existing remote Nix builder. This plan implements
decisions 5 and 6 of
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md). The data is
in [the 2026-10-04 retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md).


## Progress

- [x] (2026-10-05) M1: Incomplete patterns are compile errors. Evidence (observed): the `common`
  stanzas of `nagarectl`, `nagare-dsl`, `nagare-access` and `nagare-harness` carry both flags; all
  four packages build with tests. With the per-module pragma removed, deleting the
  `RecoveryLandedUnready` alternative from the `case decision of` in
  `cli/nagarectl/src/Nagare/Inventory/Execute/Driver.hs` failed the build with "Patterns of type
  ‘RecoveryDecision’ not matched: RecoveryLandedUnready _" (the alternative was restored). Original
  acceptance: Incomplete patterns are compile errors in every Haskell package. Acceptance: all packages
  build and test with `-Werror=incomplete-patterns -Werror=incomplete-uni-patterns` in their shared
  stanza, and removing one alternative from a `case` over `RecoveryDecision` fails the build.
- [x] (2026-10-05) M2: A fast local gate runs on every push. Evidence (observed): with one
  `nagare-dsl` assertion deliberately broken, `git -c core.hooksPath=.githooks push` to a throwaway
  bare repository was refused ("pre-push: the fast gate is red; push refused"); with it restored the
  push went through after a green fast gate. That run passed 1,199 `nagarectl` and 461 `nagare-dsl`
  tests, the style check and the architecture check (logs `20261005T174651…` and
  `20261005T175155…` under `~/.local/state/nagare/gates/logs/`). The same gate caught a genuine
  house-style violation in this plan's own harness code before commit. Original acceptance: Acceptance: `just gate-fast` passes on a clean tree;
  with a deliberately failing test, `git push` is refused by `.githooks/pre-push` after
  `just install-hooks`.
- [ ] M3 (implemented 2026-10-05; acceptance runs pending): `nagare-harness gate --full`, the record
  writer and `just gate` exist, and the dry-run parser is unit-tested. The green run and the
  unreachable-builder run have not been made yet: the green run starts the on-demand Linux builder VM.
  A full local gate proves every system and writes a revision-bound record. Acceptance: on a
  clean tree, `just gate` writes a green record whose `systems` list shows every check of
  `aarch64-darwin` and `x86_64-linux` realised, plus a passing builder probe. With the Linux builder
  unreachable, `just gate` fails at the probe instead of reporting success.
- [ ] M4 (implemented 2026-10-05; live acceptance pending M3): `gate verify` exists, with unit tests
  for the missing, red, dirty, tree-mismatch, missing-system, partial-realisation and failed-probe
  refusals plus one acceptance. The runbooks call `just gate-verify <rev>` first in sections 1, 4, 6
  and 7. Native work refuses a revision without a green full record. Acceptance:
  `nagare-harness gate verify --revision <rev>` exits non-zero for a revision without a record,
  for a red record and for a dirty-tree record, and zero for a green one. The native verification
  runbook and [EP-168](168-script-the-local-acceptance-run-as-one-command.md)'s harness call it
  first.
- [x] (2026-10-05) M5: Fixture applications are smoke-run locally before a cluster sees them.
  Evidence (observed, on the separate `default` Colima daemon): scenario-a (PostgreSQL 18) and
  scenario-b (Redis 8) served HTTP 200. scenario-b bound only to PostgreSQL exited at import, so the
  negative self-test failed as required, and the run ended "fixture-smoke: green" in 94 s with no
  containers, networks or images left. Against the cp3 daemon the smoke refused ("this Docker daemon
  runs a k3d cluster"). Original acceptance: Acceptance:
  `just fixture-smoke` serves every entry of `fixtures/inventory-release/local/fixture-smoke.json`
  with its declared bindings, and fails for scenario-b bound to PostgreSQL only.


## Surprises & Discoveries

- Observation: The first `just gate-fast` in a fresh worktree failed 18 of 1,199 `nagarectl` tests,
  all config-loader tests ("Could not find module ‘Data.Generics.Labels’" when compiling
  `test/fixtures/app/*/Config.hs`). The cause: `cabal test nagarectl-test --project-dir=cli/nagarectl`
  run from the repository root writes the project's `.ghc.environment.*` into the current directory
  (the root), not `cli/nagarectl`, so the loader finds no package environment. The shared tree never
  showed this, because earlier runs from `cli/nagarectl` had left an environment file there. This is
  the same "18 false failures in a clean worktree" nagare-phase-b hit on 2026-10-04.
  Evidence: `~/.local/state/nagare/gates/logs/20261005T171940.002113Z/nagarectl-test.log` (observed).
  Running each suite from its package directory fixed it (1,199 passing in 190 s, observed).
  Date: 2026-10-05

- Observation: The same rerun then failed 14 of 461 `nagare-dsl` tests the same way, although it ran
  from `cli/nagare-dsl`. In a fresh checkout `cabal test` writes the environment file only after the
  tests have run: the file's timestamp followed the test run, a second `cabal test` passed all 461,
  and after deleting the file a plain `cabal build nagare-dsl-test` wrote it again (all observed). The
  fast gate now builds each suite, then tests it.
  Date: 2026-10-05

- Observation: `nix flake check` on the first EP-174 commit failed `managed-command-audit`, although
  the fast gate had been green. The five new `just` recipes were not registered in
  `scripts/audit-managed-commands.py`, and the command catalogue snapshot in
  `docs/architecture/managed-resource-coverage.md` was stale. The fast gate's architecture step ran
  only `check-haskell-architecture.py`, one of the five scripts the flake check runs. The fast gate
  now runs `scripts/test-managed-command-audit.sh`, the flake check's own script.
  Date: 2026-10-05


## Decision Log

- Decision: No hosted CI. The fast gate runs as a git pre-push hook, and the full gate runs locally
  before any candidate. x86_64-linux uses the existing remote Nix builder.
  Rationale: Operator decision, 2026-10-04. GitHub Actions took about 18 minutes per flake check and
  is "so slow". A local gate gives feedback in minutes and uses the builder the maintainer already
  depends on for host images.
  Date: 2026-10-04

- Decision: The gate runner and its record writer are a Haskell command, `nagare-harness gate`,
  invoked by thin `just` recipes.
  Rationale: [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
  forbids evidence shaping in shell, and the gate record is evidence that native work consumes. Use
  the `nagare-harness` package that [EP-168](168-script-the-local-acceptance-run-as-one-command.md)
  introduces. If this plan lands first, create the package skeleton exactly as EP-168 describes it,
  and EP-168 builds on it.
  Date: 2026-10-04

- Decision: Prove every system by checking that each check's output is realised, rather than by
  trusting the flake check's exit status.
  Rationale: A check can be skipped or substituted, and a builder can be down. A dry-run build of
  every `checks.<system>.*` attribute that reports nothing left to build proves the exact outputs
  exist. A salted probe derivation then proves the builder works now.
  Date: 2026-10-04


- Decision: `nagare-harness` is its own Cabal project with no `nagarectl` dependency yet; EP-168 adds
  the dependency when `local-acceptance` needs shared types. The MasterPlan's Decision Log records it.
  Rationale: There is no shared cabal workspace, and the pre-push hook builds the harness first, so
  the dependency would rebuild the whole `nagarectl` library in a second build directory on every push.
  Date: 2026-10-05

- Decision: Each gate step names a working directory. The two suites are built and then tested from
  `cli/nagarectl` and `cli/nagare-dsl` instead of using `--project-dir`.
  Rationale: See Surprises & Discoveries. Cabal writes the package environment the config-loader
  tests need into the current directory.
  Date: 2026-10-05

- Decision: The full gate reads the supported systems from `release.json` at the gated commit, probes
  only systems other than the local one, and `gate verify` re-reads `release.json` at the revision. A
  system's record holds `checks`, `realised` and `remaining` (the store paths the dry run would still
  build or fetch); `realised` equals `checks` only when `remaining` is empty. The record is written
  for red runs too.
  Rationale: `release.json` is the platform's declared system list, so adding a system can't silently
  shrink the gate. A red record explains itself, and `gate verify` refuses it.
  Date: 2026-10-05

- Decision: The fixture smoke manifest lists every directory under
  `fixtures/inventory-release/local/apps/`, enforced by a harness test. `scenario-collision` (never
  deployed by design) and `scenario-site` (a static site with no process to bind) carry a `skip`
  reason. The smoke refuses a Docker daemon that runs a k3d cluster unless `--allow-shared-daemon` is
  passed.
  Rationale: A fixture missing from the manifest would bypass the smoke. Running throwaway containers
  next to cp3 or a local acceptance cluster would mutate a host under verification (ADR 25, the
  native-run checklist).
  Date: 2026-10-05

- Decision: The fast gate's last step is `scripts/test-managed-command-audit.sh`, the same script the
  flake's `managed-command-audit` check runs, not just `check-haskell-architecture.py`. The new
  recipes are registered as `read` (`gate-fast`, `gate`, `gate-verify`) or `local` (`install-hooks`,
  `fixture-smoke`).
  Rationale: The narrower step let an unregistered recipe reach `nix flake check`. The full script
  adds about 50 seconds.
  Date: 2026-10-05

- Decision: M1 found no incomplete match in any library or executable (they were already clean
  under `-Wall`). Every one was a test fixture pattern binding: 23 in `nagare-dsl`'s
  `ResourceInventorySpec`, 5 in `nagarectl`'s `InventoryTransactionSpec`, 1 in
  `InventoryKubernetesConfigurationSpec`. They now go through named helpers that fail with the
  fixture's actual shape: `single` in `Nagare.Test.Support.Assertions`, plus `managedOf`/`single`
  local to the DSL spec. `InventoryTransactionSpec` was at its size allowance, so its
  `registryHostFixture` moved to `Nagare.Test.Support.RegistryHost`, and the allowance ratchets down
  from 3,798 to 3,766. `scripts/check-haskell-architecture.py` now requires both flags in every
  package's `common` stanza and refuses any module pragma that disables them. That replaces its
  per-module check on `Nagare.Inventory.Execute.*`, whose 14 pragmas are removed.
  Rationale: The plan forbids hiding constructors behind wildcards; the helpers keep each fixture's
  expectation explicit. Module-level opt-outs would undo the package flag silently, so the checker
  forbids them.
  Date: 2026-10-05

- Decision: Add `just gate-verify REV` beside the planned recipes, and have the runbooks call it.
  Rationale: Native-run steps in the runbooks are shell commands; a recipe keeps the call identical
  everywhere until EP-168's runner calls `gate verify` itself.
  Date: 2026-10-05


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All paths are relative to the repository root.

**Haskell packages and checks.**
- The packages are `cli/nagarectl` (the CLI, test suite `nagarectl-test`), `cli/nagare-dsl` (the
  typed configuration library) and `cli/nagare-access`. Each `.cabal` file has a `common` stanza
  that the library, executables and tests import.
- `cli/nagarectl/nagarectl.cabal`'s stanza sets `-Wall -Wno-unused-imports -threaded`, with no
  `-Werror`. Only 15 of 362 `nagarectl` modules opt in to `-Werror=incomplete-patterns` with a
  per-module `OPTIONS_GHC` pragma; one example is `src/Nagare/Inventory/Execute.hs`. The Kubernetes
  adapters, `src/Nagare/Inventory/Plan.hs` and `src/Nagare/Inventory/Plan/History.hs` do not.
- Finding F13 was a `case` that missed the `RecoveryTerminalFailure` constructor and crashed at run
  time.

**Existing check commands.**
- `just haskell-style-check` runs `scripts/check-haskell-style.sh` and the Fourmolu and cabal-gild
  format checks.
- `python3 scripts/check-haskell-architecture.py` enforces per-module line caps, which only ratchet
  down.
- The suites run with
  `cabal test nagarectl-test --project-dir=cli/nagarectl` and the matching `nagare-dsl` command,
  serially, because running both at once has been unreliable.
- `nix flake check` builds every flake check for the current system (36 on aarch64-darwin), and
  `--all-systems` also builds the 35 x86_64-linux ones.

**The Linux builder.**
- On the operator's Mac, x86_64-linux builds go to an on-demand GCP VM provisioned by
  `scripts/setup-nix-builder.sh`.
- Nix reaches it through an SSH `ProxyCommand` that starts the VM when needed; it shuts itself down
  when idle.
- Starting it is the existing, operator-accepted build path, and this plan creates no cloud
  resources. If the VM cannot be reached, a Linux build fails, or it may be skipped or substituted,
  depending on the cache.

**GitHub Actions.**
- `.github/workflows/ci.yml` exists, but Actions is disabled for the repository, and the operator
  does not want it.
- This plan neither edits nor relies on that workflow.

**Native verification.**
- Candidates are built and verified natively following `docs/runbooks/native-verification-harness.md`:
  section 1 builds the candidate, section 4 runs C1, section 6 runs C2 and section 7 runs C3.
- [EP-168](168-script-the-local-acceptance-run-as-one-command.md) replaces the hand-run C2 with a
  Haskell command in a new `nagare-harness` package.

**Fixture applications.**
- The acceptance scenarios deploy the fixture applications in `fixtures/inventory-release/local/apps/`:
  `scenario-a`, `scenario-b`, `scenario-collision` and `scenario-site`. Each has a `Dockerfile`, an
  `app.py` and a `nagare/Config.hs`.
- `scenario-b/app.py` reads `os.environ["REDIS_URL"]` at import, so it crashes without a Redis
  binding.
- On 2026-10-04 a reviewer deployed that image with a PostgreSQL binding. The resulting crash loop
  exposed F54 and wedged the cloud context `mp23-c3i`.

**ADR context.**
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), decision 5:
  every commit is gated, and a candidate cannot be frozen without a green gate record. Decision 6:
  fixture workloads are proven to run before a cluster sees them.
- [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md): new
  harness tooling is Haskell, shell only as thin glue, and existing Python tools are frozen. This
  plan therefore does not modify `scripts/run-local-candidate-gate.py`; the runbook calls the new
  verify command before it.
- [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md): `nix flake check` is
  the source of truth for checks. This plan keeps that and only changes where and when it runs.


## Plan of Work

### Milestone 1: exhaustiveness is an error

Add `-Werror=incomplete-patterns` and `-Werror=incomplete-uni-patterns` to the `ghc-options` of the
`common` stanza in:
- `cli/nagarectl/nagarectl.cabal`;
- `cli/nagare-dsl/nagare-dsl.cabal`;
- `cli/nagare-access/nagare-access.cabal`.

Build every package and fix each newly reported incomplete match by handling the missing
constructors explicitly. Do not use a wildcard that hides future constructors. In recovery code, the
right handling for an unexpected constructor is usually a refusal with a reason.

Remove the now-redundant per-module `OPTIONS_GHC -Werror=incomplete-patterns` pragmas. Format the
cabal files with `cabal-gild`.

To verify, temporarily delete one alternative from a `case` over `RecoveryDecision` in
`cli/nagarectl/src/Nagare/Inventory/Execute/Recovery.hs` and confirm the build fails. Record the
error excerpt in Surprises & Discoveries, then restore the alternative.

### Milestone 2: the fast gate and the pre-push hook

Add `nagare-harness gate --fast`. It runs, in order and stopping at the first failure:
1. `cabal test nagarectl-test --project-dir=cli/nagarectl`;
2. the `nagare-dsl` suite;
3. `just haskell-style-check`;
4. `python3 scripts/check-haskell-architecture.py`.

It prints each step's duration and result.

Add three `just` recipes in `justfile`:
- `gate-fast` runs that command.
- `install-hooks` runs `git config core.hooksPath .githooks`.
- `gate` is described in Milestone 3.

Add `.githooks/pre-push`, a short `bash` script with `set -euo pipefail` that runs `just gate-fast`.
Document the hook in `docs/runbooks/before-a-native-run.md` section 3.

The hook runs on the working tree. A maintainer who pushes with uncommitted changes gets a result
for the tree, not the commit; the full gate in Milestone 3 refuses dirty trees for that reason.

### Milestone 3: the full gate and its record

Add `nagare-harness gate --full`, which runs these steps in order:

1. **Require a clean tree.** `git status --porcelain` must be empty. Read the commit
   (`git rev-parse HEAD`) and tree (`git rev-parse HEAD^{tree}`).
2. **Run the fast gate.**
3. **Probe the Linux builder** by building a salted trivial derivation:

    ```bash
    nix build --no-link --impure --expr \
      'derivation { name = "nagare-builder-probe"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "echo SALT > $out" ]; }'
    ```

    Replace `SALT` with a fresh random value so the probe cannot be substituted. A failure ends the
    gate with "Linux builder unreachable".
4. **Run the flake check:** `nix flake check --all-systems --print-build-logs`.
5. **Prove every check is realised.** For each system, list the check attributes with
   `nix eval .#checks.<system> --apply builtins.attrNames --json`, then run
   `nix build --no-link --dry-run` on them all. The dry run must report that nothing remains to be
   built or fetched. Any remaining derivation fails the gate and names it.
6. **Write the record.** It goes to `${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/<commit>.json`
   and holds:
   - commit, tree and a clean-tree flag;
   - each step's command, exit code and duration;
   - the realised check count per system;
   - the probe result;
   - the GHC, cabal and Nix versions;
   - a `green` boolean.

   The record lives outside the repository because it describes a machine's verification, not
   source.

The `just gate` recipe runs this command.

### Milestone 4: native work requires a green record

Add `nagare-harness gate verify --revision <rev>`. It resolves `<rev>` to a commit, reads the
record, and exits non-zero with a reason when any of these holds:
- the record is missing;
- `green` is false;
- the tree was dirty;
- the record's tree differs from the commit's tree;
- a system is missing.

Edit `docs/runbooks/native-verification-harness.md`:
- section 1 (build the candidate) and section 4 (C1) start with this command;
- section 6 (C2) and section 7 (C3) state that the scripted harness calls it.

Record in the MasterPlan's Integration Points that [EP-168](168-script-the-local-acceptance-run-as-one-command.md)'s
runner calls `gate verify` for the candidate revision before any cluster step.

### Milestone 5: fixture smoke

Add `fixtures/inventory-release/local/fixture-smoke.json`, with one entry per fixture application.
Each entry holds:
- the application directory;
- the bindings it declares, read from its `nagare/Config.hs` and written explicitly here, for
  example `{"REDIS_URL": "redis"}` for scenario-b and a PostgreSQL URL for scenario-a;
- the container port;
- a probe path and the expected HTTP status.

Add `nagare-harness fixture-smoke`. For each entry it:
1. builds the image with Docker;
2. starts each declared backing service in a throwaway Docker network (`redis:8`, `postgres:18`,
   `clickhouse/clickhouse-server:25`, per the operator's engine-version rule);
3. starts the application with only the declared environment;
4. polls the probe path for up to 60 seconds;
5. removes everything it started.

The `just fixture-smoke` recipe runs it. A negative self-test runs scenario-b with a PostgreSQL
binding substituted and expects failure, so the smoke cannot pass vacuously.

Document in `docs/runbooks/before-a-native-run.md` section 2 that a new or "corrected" fixture must
be added to the manifest and smoke-run before any cluster apply.


## Concrete Steps

From the repository root, after `just install-hooks` once:

```bash
just gate-fast
```

Expected tail on a healthy tree:

```text
gate: nagarectl-test        ok   (… s)
gate: nagare-dsl-test       ok   (… s)
gate: haskell-style-check   ok   (… s)
gate: architecture          ok   (… s)
gate: fast gate green
```

The full gate:

```bash
just gate
nagare-harness gate verify --revision "$(git rev-parse HEAD)"
```

Expected:

```text
gate: builder probe x86_64-linux   ok
gate: nix flake check --all-systems ok
gate: realised aarch64-darwin 36/36, x86_64-linux 35/35
gate: record ~/.local/state/nagare/gates/<commit>.json (green)
gate verify: <commit> green, tree <tree>, systems aarch64-darwin x86_64-linux
```

The fixture smoke:

```bash
just fixture-smoke
```


## Validation and Acceptance

M1 is proven by a clean build of every package with the new flags, and by the deliberate removed
alternative failing to compile.

M2 is proven by `git push` being refused when one test is made to fail (on a throwaway local
commit, never pushed), and by the push proceeding once the test is restored.

M3 is proven by a green record on a clean tree with both systems fully realised. It is also proven
by a red result when the builder is unreachable: make the builder's SSH host alias unresolvable in a
scratch `NIX_SSHOPTS` or a temporary `nix.conf` override, never by stopping the operator's VM. Here
the gate must stop at the probe.

M4 is proven by the four refusal cases (missing, red, dirty, tree mismatch) and one acceptance.

M5 is proven by all manifest entries serving, and by the negative self-test failing as expected.

The plan as a whole is accepted when a fresh candidate is built only after `just gate` is green for
its revision, and the runbook's first step for that candidate is `gate verify`.


## Idempotence and Recovery

Every gate step is read-only with respect to the repository. The full gate builds Nix derivations
and may start the on-demand Linux builder VM through its existing `ProxyCommand`; it creates no
resources. Records are keyed by commit, and a rerun overwrites the record for the same commit. The
fixture smoke removes its containers and network even on failure. Use a `trap` in the thin `bash`
glue, or bracket in Haskell. Running it twice is safe. The pre-push hook is opt-in through
`just install-hooks`, and `git config --unset core.hooksPath` removes it.


## Interfaces and Dependencies

**`nagare-harness` commands** (Haskell, in the package [EP-168](168-script-the-local-acceptance-run-as-one-command.md) introduces):
- `gate --fast`;
- `gate --full`;
- `gate verify --revision REV`;
- `fixture-smoke [--manifest PATH]`.

**The gate record.** A JSON object with these fields, owned by this plan and consumed by EP-168 and
by [EP-170](170-size-the-release-gate-to-the-change.md):
- `version: 1`;
- `commit`, `tree`, `clean`;
- `steps: [{name, command, exit, seconds}]`;
- `systems: {<system>: {checks, realised}}`;
- `builderProbe: {system, ok}`;
- `tools: {ghc, cabal, nix}`;
- `green`.

**Fixture manifest.** `fixtures/inventory-release/local/fixture-smoke.json`, owned by this plan and
read by EP-168's runner before it deploys fixtures.

**Tools.** Docker (the maintainer's Colima profile) for M5, and the existing remote Nix builder for
M3. No hosted CI.
