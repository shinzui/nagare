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
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T20:37:07Z
      mode: "implement"
      note: "M3/M4 accepted (green full gate over tailnet at 07c954a6); plan complete"
---

# Gate every commit before any native run

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [174-gate-every-commit-before-any-native-run.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/174-gate-every-commit-before-any-native-run.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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
in [the 2026-10-04 retrospective](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-engineering-retrospective-2026-10-04.md).

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
- [x] (2026-10-05) M3: The full gate proves every system and writes a revision-bound record.
  Observed:
  - **Negative:** at `99b51003`, with the builder pointed at `nagare-unreachable.invalid`, the gate
    stopped at `builder-probe-x86_64-linux` and wrote a RED record.
  - **Green:** at `07c954a6`, after the builder moved to the tailnet (see Surprises), `just gate`
    passed every fast step and the probe (7.5 s), then `nix flake check --all-systems` (1,312 s). It
    reported "realised x86_64-linux 36/36" and "realised aarch64-darwin 37/37" and wrote a green
    record at `~/.local/state/nagare/gates/07c954a6….json`.
  - **IAP failures:** three earlier real runs failed on IAP tunnel drops and were each correctly
    recorded RED.
- [x] (2026-10-05) M4: `just gate-verify 07c954a6` printed "07c954a6… green, tree c7297228…, systems x86_64-linux aarch64-darwin" (observed). Earlier:
  Observed: `just gate-verify 7fbc6345` refused "no gate record". After the negative run it refused
  `99b51003` with "the gate record is red". `just gate` on a tree with an untracked file refused "the
  full gate needs a clean tree". `gate verify` exists, with unit tests
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

- Observation: Both real full-gate runs lost their remote builds to "Timeout, server nix-gcp-builder
  not responding" mid-build, once in `nagare-platform` and once in `nagarectl`. The probe had passed
  minutes earlier. The builder VM is `n2-standard-16`; it was resized outside
  `scripts/setup-nix-builder.sh`, which still said `n2-standard-2`. Its serial log showed no OOM, no
  hang and no reboot, and its SSH sessions outlived the client's timeout by 5–10 minutes (observed).
  The client's keepalive budget was 90 s (`ServerAliveInterval 30`, default count 3), and the gcloud
  IAP tunnel path stalled longer than that (inferred; the proxy discarded its stderr). Fixed on the
  host side in `mori://shinzui/dotfiles.nix` (`darwin/gcp-nix-builder.nix`: `ServerAliveCountMax 10`,
  tunnel stderr logged to `/tmp/nix-gcp-builder-proxy-<user>.log`). This repo's provisioning default
  now matches the live shape (`fa421e39`).
  Date: 2026-10-05

- Observation: The IAP keepalive change (`ServerAliveCountMax 10`) was not enough. The newly kept
  tunnel log showed the real cause: gcloud's IAP websocket dropped during a long build, and its
  reconnect failed ("ConnectionCreationError: Unexpected error while reconnecting"), so SSH saw a
  broken pipe. The builder now joins the operator's tailnet on every boot (`a885433c`). The host
  ProxyCommand prefers the tailnet and falls back to IAP (`mori://shinzui/dotfiles.nix`,
  `darwin/gcp-nix-builder.nix`). The next full gate went green with no fallback (observed in
  `/tmp/nix-gcp-builder-proxy-root.log`).
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

**2026-10-05: all five milestones met in one day.**

**What every push and candidate now gets:**
- a fast gate (both suites built then tested, style, and the flake's own architecture and command-audit script) enforced by `.githooks/pre-push`, installed repo-wide;
- a full gate that proves both systems' check outputs exist after a salted builder probe, with a revision-bound record;
- `gate verify` before native work;
- a fixture smoke that refuses a daemon hosting k3d;
- exhaustiveness as a compile error in every package.

**What the gate caught while being built:**
- its own house-style violation;
- two unregistered recipes (the first flake check failure);
- two fresh-checkout cabal traps, which explain the earlier "18 false failures";
- three real Linux builder transport failures, recorded RED instead of reported green.

**Remaining:**
- EP-168's runner should call `gate verify` itself (runbook steps do it until then);
- the gate's Linux half depends on the builder's tailnet membership, so key expiry for `nix-builder-x86` should be disabled in the Tailscale admin console.

