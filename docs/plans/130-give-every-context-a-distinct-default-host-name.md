---
id: 130
slug: give-every-context-a-distinct-default-host-name
title: "Give every context a distinct default host name"
kind: exec-plan
created_at: 2026-09-14T02:03:09Z
intention: "intention_01m2etae2sekzbr1mthbv4wxpr"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T02:03:09Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T02:53:19Z
      mode: "implement"
      note: "Implemented and validated Milestone 1 host-name derivation"
---

# Give every context a distinct default host name

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Before this plan, Nagare gave every generated cloud host the context's GCE instance name, which defaults
to `nagare-01`. When two contexts join the same Tailscale private network (a "tailnet"), both nodes
request the same name. Tailscale renames one of them, and an operator can no longer tell which
cluster `ssh deploy@nagare-01` or a Kubernetes API connection over that name will reach. The defect
and its acceptance criteria are recorded in
[IR-14](../improvement-requests/default-host-name-collides-across-clusters.md).

After this plan, `nagarectl host init --context prod` defaults the NixOS and Tailscale host name to
`prod-nagare`, while the same command for `labs` defaults it to `labs-nagare`. The GCE instance may
remain `nagare-01`; the command and documentation clearly distinguish the tailnet host name from
the project-scoped instance name. Before accepting an implicit default, `host init` also checks the
other generated host flakes under the Nagare configuration directory and refuses if one already
contains that host name. An explicit `--host-name` remains the escape hatch for a context name that
cannot become a valid NixOS host name or for an operator who wants a different stable name.

The observable result is a dry-run transcript in which two contexts with the same instance name
render different `hostName` values, plus a collision scenario that exits non-zero and names the
context already owning the proposed host name. The multi-cluster and host-access guides then show
`ssh deploy@prod-nagare` for Tailscale while retaining `nagare-01` for GCE/IAP commands.


## Progress

- [x] (2026-09-14 02:53Z) Milestone 1: added and unit-tested the deterministic, validated
  `<context>-nagare` default policy in `Nagare.Host.Config`, routed `nagarectl host init` through
  it, updated CLI help, and passed all 471 `nagarectl-test` tests.
- [x] (2026-09-14 03:02Z) Milestone 2: added deterministic sibling-flake collision discovery,
  current-context exclusion, symlink and unreadable-file coverage, and installed-command proof of
  refusal plus explicit recovery. All 472 Haskell tests and both `nagare-clone-free-platform` and
  `host-module-options-agree` passed.
- [x] (2026-09-14 03:06Z) Milestone 3: updated both operator guides, CHANGELOG, and ADR 5; passed
  user-documentation validation, Haskell style, all 472 Haskell tests, both focused Nix checks, and
  the full native flake check; then completed IR-14 and validated all 21 improvement requests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The improvement-request bundle contains 21 concepts, not the 16 predicted when this plan was
  drafted. IR-17 through IR-21 were added on the same date before implementation began. Evidence:
  the final profile/log enforcement reported `OK: 21 concepts (okf_version 0.2)`.

- On this `aarch64-darwin` workstation, `nix flake check --print-build-logs` passed every buildable
  native check and warned that it omitted incompatible `x86_64-linux` outputs. This is Nix's normal
  host-system behavior rather than a failed gate; the native run included `nagarectl-build-test`,
  `nagare-clone-free-platform`, `host-module-options-agree`, `shellcheck-scripts`, documentation-
  independent packaging checks, and the remaining repository checks.

- The repository style gate requires `import Data.Generics.Labels ()` in every Haskell module that
  uses an overloaded record label. Adding `#name` assertions to `HostSpec` exposed that requirement;
  after the explicit import, `scripts/check-haskell-style.sh` passed.


## Decision Log

- Decision: The ordinary default is `<context>-nagare`, and it is available only when the context
  text is already a lowercase DNS label and the final value is at most 63 characters. Uppercase
  letters, underscores, dots, leading or trailing hyphens, an empty label, or excess length produce
  an actionable error that requires `--host-name`; automatic derivation does not silently
  lowercase, replace characters, or truncate. This stricter rule applies to defaults, not to the
  existing explicit option, whose compatibility remains governed by NixOS evaluation.
  Rationale: `ContextName` is a safe filesystem segment, not a host-name type: it permits uppercase
  letters, `_`, and `.` and does not impose a length limit. Silent normalization would make distinct
  contexts such as `prod_a` and `prod-a` request the same tailnet name, while truncation creates the
  same problem for long names, and lowercasing would alias `Prod` with `prod`. Rejecting every lossy
  conversion keeps the mapping injective and makes the existing explicit option the deliberate
  recovery path.
  Date: 2026-09-14

- Decision: A sibling collision is a hard error only for an implicit default. An explicitly passed,
  valid `--host-name` is treated as deliberate and bypasses this workstation-local ownership check.
  Rationale: The improvement request asks the command to warn or refuse when no explicit host name
  was supplied. Nagare can inspect only host flakes on the current workstation, not the complete
  tailnet, so the check is a defense against accidental reuse rather than a global uniqueness
  authority. The error tells the operator to choose a distinct explicit name after checking the
  tailnet.
  Date: 2026-09-14

- Decision: Collision discovery reads generated `host.nix` files and compares their rendered
  `nagare.host.hostName` assignment; it does not introduce a parallel registry or infer the name
  from the sibling context directory.
  Rationale: Existing flakes already record effective operator intent, including explicit
  overrides, and ADR 5 makes those files durable context-owned sources. Matching the generator's
  exact assignment avoids a general Nix parser; an unreadable generated sibling fails closed because
  uniqueness cannot be established.
  Date: 2026-09-14

- Decision: Implementation amends ADR 5 rather than creating a new ADR.
  Rationale: ADR 5 already owns the context-host-flake boundary, host versus instance identities,
  and generator safety properties. The new default and sibling check refine that contract.
  Date: 2026-09-14

- Decision: Inspect sibling context directories in sorted order and report the first collision.
  Rationale: More than one pre-existing flake can already contain the same host name. Sorting makes
  the owning context named by the refusal stable across filesystems without weakening the hard
  error or inventing a second host registry.
  Date: 2026-09-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All three milestones are complete. Contexts that are already lowercase DNS labels now receive an
injective `<context>-nagare` OS and Tailscale identity without changing their GCE instance name.
The `prod` and `labs` installed-command fixtures both retain `nagare-01` while rendering distinct
host names; a seeded `legacy` owner prevents implicit `prod-nagare`, and explicit
`--host-name prod2-nagare` succeeds. Unit coverage also proves invalid derivations, current-context
exclusion, missing and non-host entries, symlinked roots, exact assignment matching, and unreadable
sibling failure.

The multi-cluster and access guides now distinguish `ssh deploy@prod-nagare` over Tailscale from
IAP commands addressed to project-scoped instance `nagare-01`. ADR 5 holds the durable default,
collision, symlink, fail-closed, explicit-override, and existing-flake contracts; no new ADR was
needed. IR-14 is completed. Validation passed: all 472 Haskell tests, both focused Nix checks,
Haskell style, 37 user documents, 2 guides, 21 improvement requests, and every buildable native
flake check. Nix omitted incompatible `x86_64-linux` outputs on the `aarch64-darwin` host, and no
functional work remains in this plan.


## Context and Orientation

Nagare represents a deployment target with `Nagare.Target.ContextName` in
`cli/nagarectl/src/Nagare/Target.hs`. `mkContextName` accepts a non-empty safe path segment made of
ASCII letters, digits, hyphens, underscores, and dots. That is intentionally broader than a NixOS
host name. The repository's pinned NixOS `networking.hostName` type requires one label of at most 63
characters beginning and ending with an alphanumeric character; it accepts uppercase and legacy
underscores, but its own option documentation recommends lowercase DNS syntax and warns against
underscores. This plan deliberately uses that preferred syntax for generated defaults. Keep the
concepts separate and do not narrow `ContextName`, because it is already a public storage and
command-line identity.

`cli/nagarectl/app/Main.hs` defines `HostInitOpts`, parses `nagarectl host init`, and implements the
`HostInit` branch in `runHost`. The parser explains that `--host-name` defaults to
`<context>-nagare`. The handler derives and collision-checks that value only when the option is
absent; an explicit value passes through unchanged. `HostConfig.instanceName` remains independently
resolved from `--instance-name` or `profile.instanceName`, whose cloud default is `nagare-01`.

`cli/nagarectl/src/Nagare/Host/Config.hs` owns the `HostConfig` record and generated-flake behavior.
`HostConfig.name` becomes both `nixosConfigurations.<name>` in `flake.nix` and
`nagare.host.hostName` in `host.nix`. `hostConfigDir` maps a context to
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/hosts/<context>/`. `renderHostModule` emits the stable line
`hostName = "...";`, and `installHostFlake` validates a staging tree before atomically installing it.
This module now owns pure host-name validation/defaulting and the filesystem query over sibling host
flakes; `Main.hs` orchestrates those APIs rather than repeating their rules.

`nixos/modules/nagare-host.nix` assigns `nagare.host.hostName` to `networking.hostName`. The checked-in
`nixos/hosts/nagare-01/` tree is only an evaluation fixture; changing its name or the GCE instance is
outside this plan. Tailscale's module in `nixos/hosts/nagare-01/tailscale.nix` passes no independent
`--hostname`, so Tailscale uses the OS host name and needs no direct change.

`cli/nagarectl/test/HostSpec.hs` contains focused tests for host rendering, generated-flake safety,
and two context fixtures. Extend it for the pure name policy and collision discovery.
`nix/checks/scripts/nagare-clone-free-platform.sh` exercises the installed command against temporary
XDG directories without an operator checkout; extend its host scenario so the actual `Main.hs`
wiring is covered. `nix/checks/infra.nix` exposes `host-module-options-agree`, which prevents the
generated `host.nix` option names from drifting from `nixos/modules/nagare-host.nix`.

The user-facing distinction belongs in `docs/guides/running-multiple-clusters.md`, which lists the
project-scoped VM name but does not choose a distinct tailnet name, and
`docs/user/accessing-the-host.md`, which uses `nagare-01` for both Tailscale SSH and GCE/IAP. Both are
profile-governed user-documentation bundles and must pass `just user-documentation-validate`.

Two local ADRs are relevant.
[ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) requires one
generated, operator-owned host flake per context and makes `host.nix` the source of host identity;
update it with the new default and collision guard.
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
allows the XDG `hosts/` directory to be a symlink into a private repository, so sibling scans must
follow ordinary directory and file symlinks and never replace them. No cross-repository ADR is
needed.


## Plan of Work

Milestone 1 introduces the naming policy and routes host initialization through it. In
`cli/nagarectl/src/Nagare/Host/Config.hs`, add and export `defaultHostName`, which appends `-nagare`
to a lowercase DNS-label context and rejects any context whose resulting spelling would require
lossy normalization or exceed 63 characters. Preserve explicit `--host-name` handling exactly as
it is today. In `cli/nagarectl/app/Main.hs`, resolve `HostConfig.name` from `defaultHostName` when the
option is absent and use the explicit value unchanged when present. Keep `HostConfig.instanceName`
derived from `profile.instanceName` and update the option help. Extend
`cli/nagarectl/test/HostSpec.hs` with `prod`/`labs` contexts sharing `nagare-01`, a preserved explicit
override, and rejected default derivation for uppercase, underscore, dot, boundary-hyphen, and
length cases. This milestone is accepted when the Haskell suite proves `prod-nagare` and
`labs-nagare` are distinct while both configurations retain instance `nagare-01`.

Milestone 2 adds a workstation-local collision guard. In
`cli/nagarectl/src/Nagare/Host/Config.hs`, add an IO helper that locates the common `hosts/` parent,
examines every sibling context except the context being initialized, and finds the exact stripped
`hostName = <nixString candidate>;` line in an existing `host.nix`. A missing `hosts/` directory or
non-host entry is harmless. A sibling `host.nix` that exists but cannot be read is an error with its
path. In `Main.hs`, call the helper only when the host name was implicit, before both dry-run output
and installation. On collision, exit before writing and name the owning context, path, and recovery
flag. Use `withSystemTempDirectory` and a temporary `XDG_CONFIG_HOME` in `HostSpec` to prove
no-directory, non-collision, collision, current-context exclusion, and symlinked-directory behavior.
Extend `nix/checks/scripts/nagare-clone-free-platform.sh` with installed-command dry runs for `prod`
and `labs`, plus a seeded sibling collision. This milestone is accepted when focused and clone-free
checks show distinct defaults, an actionable refusal, and successful explicit recovery.

Milestone 3 makes the behavior operable and records the durable contract. In
`docs/guides/running-multiple-clusters.md`, add the tailnet host name to planning, explain that it
defaults from the context while the VM remains project-scoped, and show distinct host-init and SSH
examples. In `docs/user/accessing-the-host.md`, use `prod-nagare` (or `<context>-nagare`) for
Tailscale and `nagare-01` for IAP, explain `--host-name`, and tell operators where `nagarectl host
show` records the effective name. Amend
`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md`; do not create a new ADR.
Update `[Unreleased]` in `CHANGELOG.md`. After acceptance passes, change IR-14 from `accepted` to
`completed`, add `resolution` and `completedAt`, update `docs/improvement-requests/log.md`, and fill
Outcomes & Retrospective. This milestone is accepted when documentation, IR bundle, focused, and
full flake checks pass.


## Concrete Steps

Run commands from repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless stated otherwise.
Inspect the dirty worktree first and preserve unrelated changes:

```bash
git status --short
sed -n '1,240p' cli/nagarectl/src/Nagare/Host/Config.hs
sed -n '1678,1702p;2777,2820p' cli/nagarectl/app/Main.hs
sed -n '1,260p' cli/nagarectl/test/HostSpec.hs
```

Implement Milestone 1, format the changed Haskell files, and run the suite from its package:

```bash
fourmolu --mode inplace --config cli/fourmolu.yaml \
  cli/nagarectl/src/Nagare/Host/Config.hs \
  cli/nagarectl/app/Main.hs \
  cli/nagarectl/test/HostSpec.hs
cd cli/nagarectl
nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct
cd ../..
```

The transcript must contain a passing `Nagare.Host.Config` group and end like:

```text
All tests passed
```

After Milestone 2, repeat the Haskell command and build the installed-command and host-option
checks:

```bash
nix build .#checks.aarch64-darwin.nagare-clone-free-platform --print-build-logs
nix build .#checks.aarch64-darwin.host-module-options-agree --print-build-logs
```

On another Nix system, replace `aarch64-darwin` with the value from `nix eval --raw --impure --expr
builtins.currentSystem`. The collision scenario should seed context `legacy` with an explicit
`prod-nagare` host name, initialize context `prod` with its implicit default, and produce equivalent
stderr:

```text
nagarectl: default host name 'prod-nagare' is already used by context 'legacy' at .../hosts/legacy/host.nix; choose a distinct --host-name
```

After Milestone 3, run documentation, metadata, style, and full validation:

```bash
just user-documentation-validate
okf validate docs/improvement-requests \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
scripts/check-haskell-style.sh
nix flake check --print-build-logs
```

The IR command should report `OK: 21 concepts`. The bundle lacks independent `reviews` metadata for
historical requests, so do not invent reviews to make a strict run pass; the profile/log enforcement
above is the existing gate. Record exact results in Progress and Outcomes & Retrospective. Every
implementation commit must use a Conventional Commit message and carry both trailers:

```text
ExecPlan: docs/plans/130-give-every-context-a-distinct-default-host-name.md
Intention: intention_01m2etae2sekzbr1mthbv4wxpr
```


## Validation and Acceptance

Acceptance is behavioral. With temporary `prod` and `labs` context files whose
`NAGARE_INSTANCE_NAME` is `nagare-01`, and a valid temporary public key, these commands must succeed
without writing a host flake and render different OS identities:

```bash
nagarectl host init --context prod --ssh-public-key-file /tmp/operator.pub --dry-run
nagarectl host init --context labs --ssh-public-key-file /tmp/operator.pub --dry-run
```

The first transcript contains `name: prod-nagare`, `hostName = "prod-nagare";`, and
`instanceName = "nagare-01";`. The second contains `labs-nagare` and the same instance name. Neither
contains the other context's host name.

When `${XDG_CONFIG_HOME}/nagare/hosts/legacy/host.nix` already contains the explicit assignment
`hostName = "prod-nagare";`, initializing context `prod`, whose implicit default resolves to the same
value, must exit non-zero before rendering or installing. Stderr names `legacy`, the sibling file,
and `--host-name`. A distinct explicit value such as `--host-name prod2-nagare` succeeds. Explicit
values continue through the existing renderer and NixOS evaluation path without a new CLI policy.

Unit tests must cover both IR regressions: two contexts with the same instance name resolve distinct
defaults, and a sibling generated flake with the same resolved name causes refusal. They also cover
current-context regeneration not colliding with itself, missing host roots, symlinked roots, and
lossy or overlong context conversion. Documentation is accepted when a reader can distinguish:

```bash
ssh deploy@prod-nagare
scripts/iap-ssh.sh ssh nagare-01 --project acme-prod --zone us-west1-a
```

All focused commands and `nix flake check --print-build-logs` must pass. IR-14 remains `accepted`
until these outcomes are observed; only then may implementation mark it `completed`.


## Idempotence and Recovery

`host init --dry-run` remains read-only and repeatable. A sibling scan only reads the context-owned
tree; it must not create, rewrite, or canonicalize symlinks. `installHostFlake` retains its staging
and atomic replacement behavior, so failure leaves existing host flakes byte-identical.

Existing flakes already contain an explicit rendered `hostName` and are not migrated automatically.
Re-running `host init --force` without `--host-name` intentionally adopts the new default, so an
operator preserving the old name must pass it explicitly. Recover from a collision by choosing a
distinct valid `--host-name` after confirming tailnet ownership. If a sibling is unreadable, fix its
permissions or symlink and retry; do not add a flag that silences unknown state.

Tests use temporary XDG roots and clean them automatically. If a full check fails in an unrelated
dirty path, record the exact failure and run this plan's focused checks; never discard unrelated
worktree changes.


## Interfaces and Dependencies

No new package or service dependency is needed. Use existing `text`, `directory`, `filepath`, and
`temporary` dependencies and the current Tasty/HUnit stack. Do not query Tailscale or require
network access; this check guarantees only uniqueness among locally visible generated host flakes.

`cli/nagarectl/src/Nagare/Host/Config.hs` exposes these interfaces:

```haskell
defaultHostName :: ContextName -> Either Text Text
findHostNameCollision :: ContextName -> Text -> IO (Either Text (Maybe (ContextName, FilePath)))
```

Names may improve during implementation, but boundaries remain: validation and derivation are pure;
filesystem discovery is IO; collision results retain the owning context and path for an actionable
error. Avoid a general Nix parser and reuse the private `nixString` renderer for exact assignment
matching.

`cli/nagarectl/app/Main.hs` distinguishes an absent host-name option from `Just value`, invokes
`defaultHostName` only for the absent case, runs collision discovery only for that implicit value,
and otherwise preserves the explicit text before constructing `HostConfig`. `HostConfig.instanceName`
keeps independent option/profile resolution. No field is added to context files, generated host
modules, or the NixOS option namespace.

`docs/adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md` is the durable architecture
record. `docs/improvement-requests/default-host-name-collides-across-clusters.md` is the lifecycle
record and points to this plan through `targetPlan`; it is accepted now and completed only after
implementation evidence exists.


Revision note (2026-09-14): Recorded Milestone 1 implementation and its passing 471-test evidence;
the remaining milestones are unchanged.

Revision note (2026-09-14): Recorded Milestone 2 collision enforcement, deterministic scan order,
and passing Haskell plus installed-command checks.

Revision note (2026-09-14): Completed Milestone 3, refreshed stale current-state prose, recorded the
21-concept bundle discovery and native-system scope, distilled durable policy into ADR 5, and closed
IR-14 after every acceptance gate passed.
