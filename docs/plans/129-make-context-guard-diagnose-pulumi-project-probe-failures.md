---
id: 129
slug: make-context-guard-diagnose-pulumi-project-probe-failures
title: "Make context guard diagnose Pulumi project probe failures"
kind: exec-plan
created_at: 2026-09-14T02:02:45Z
intention: "intention_01m2et8vb8e8va10xx0my86psf"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T02:02:45Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T02:30:14Z
      mode: "implement"
      note: "Implemented typed Pulumi project probes and began command integration"
---

# Make context guard diagnose Pulumi project probe failures

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [129-make-context-guard-diagnose-pulumi-project-probe-failures.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagarectl context guard` prevents a Pulumi operation from reaching the wrong Google Cloud
project, but today it reports every failure to read `gcp:project` as if that key were absent. After
this change, an operator sees whether Pulumi is missing, Pulumi started but failed, Pulumi returned
invalid data, or the selected stack genuinely has no project. Every refusal remains fail-closed and
names the selected stack and resolved `PULUMI_BACKEND_URL`, so the operator can correct the actual
problem instead of repeatedly re-projecting an already-correct stack.

The behavior is visible by running `nagarectl context guard` for a cloud context. Removing Pulumi
from `PATH` produces a specific “not found” refusal; making a fake Pulumi exit non-zero preserves its
stderr in the refusal; and returning a valid config object without `gcp:project` produces only the
unprojected-stack remedy. `nagarectl context guard --json` exposes the same distinctions as one
machine-readable JSON object.

## Progress

- [x] (2026-09-14 02:30Z) Added typed Pulumi project observations, strict JSON parsing,
  cause-specific verdicts, a stable observation renderer, and 15 passing focused unit tests.
- [x] (2026-09-14 02:30Z) Wired the detailed probe into the shared command and upgrade collector,
  used the resolved backend URL, and made JSON failures independently parseable.
- [x] (2026-09-14 02:42Z) Extended the hermetic operator-tools and clone-free-platform checks
  across missing, absent, failed, foreign, and agreeing Pulumi outcomes; both Nix derivations pass.
- [x] (2026-09-14 02:44Z) Updated operator documentation, the changelog, IR-9, and ADR 9; all 15
  focused and 469 full-suite Haskell tests pass, both affected Nix checks pass, and all 18
  applicable aarch64-darwin checks in the repository gate pass.

## Surprises & Discoveries

- Observation: The first `--json` missing-tool check contained the dependency-install notice before
  its JSON object, even though the refusal handler itself emitted only JSON.
  Evidence: the initial `nagare-operator-tools` build failed `jq` and printed:

  ```text
  Installing the Pulumi program's locked Node dependencies in .../infra/pulumi ...
  {"confined":false,...}
  ```

  The guard now suppresses that informational notice in JSON mode while still performing the
  installation and retaining errors.

- Observation: `docs/adr/` is not a Mori/OKF bundle in this checkout: `mori show --full` lists six
  bundles but no architecture-decisions bundle, and the directory has neither `profile.dhall` nor
  `log.md`.
  Evidence: `ls docs/adr` shows only the numbered Markdown records. Under `ADR.md`, ADR 9 therefore
  follows the established filesystem convention rather than the plan's anticipated profiled flow.

- Observation: strict improvement-request validation is not green at the repository baseline.
  Evidence: `okf validate docs/improvement-requests --strict --profile-enforce --log-enforce`
  reports the profile-recommended `reviews` field missing from all 20 requests, including requests
  untouched by this plan. Non-strict profile/log enforcement and the repository gate remain the
  meaningful validations for this change; the unrelated corpus-wide migration is out of scope.

- Observation: the repository gate evaluates the current host system by default, not every system
  exposed by the flake.
  Evidence: `nix flake check --print-build-logs` passed all 18 applicable aarch64-darwin checks and
  reported that x86_64-linux checks were omitted as incompatible unless `--all-systems` is used.

## Decision Log

- Decision: Keep the guard fail-closed for missing tools, failed commands, malformed output, and
  absent configuration; change only the diagnosis and remediation.
  Rationale: [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
  forbids an escape hatch when the next cloud target cannot be proved. IR-9 also explicitly makes
  relaxing the guard a non-goal.
  Date: 2026-09-14.

- Decision: Replace `pulumi config get gcp:project` with `pulumi config --json` for this probe and
  parse the `gcp:project` entry only after a successful exit.
  Rationale: `config get` uses a non-zero exit both when the key is absent and when Pulumi cannot
  access its backend, so stderr matching would make absence detection depend on unstable prose.
  Pulumi 3.255.0, the version pinned by this repository, returns a JSON object whose
  `gcp:project` member is `{ "value": "...", "secret": false }`; a successful object without the
  member proves genuine absence while any non-zero exit remains a command failure.
  Date: 2026-09-14.

- Decision: Add a guard-specific process result instead of changing
  `Nagare.Ops.Probe.captureTool` for every caller.
  Rationale: `captureTool` intentionally collapses inaccessible status/doctor data into `Nothing`
  so those observational commands can degrade to `UNKNOWN`. The context guard is a safety boundary
  with different diagnostic requirements. `System.Process.readProcessWithExitCode`, already used
  in `cli/nagarectl/app/Main.hs`, supplies exit code, stdout, and stderr without a new dependency.
  Date: 2026-09-14.

- Decision: Keep the existing nullable `observations.stackProject` JSON member and add detailed
  probe metadata rather than replacing it.
  Rationale: Existing scripts may read the simple member. Additive JSON fields provide the new
  diagnosis without needlessly breaking those consumers.
  Date: 2026-09-14.

- Decision: On `--json` failure, emit exactly one JSON object to stderr and exit non-zero without
  appending the human `nagarectl:` line.
  Rationale: The current handler writes JSON and then calls `dieT`, leaving a file that cannot be
  parsed as one JSON document. IR-9 requires the cause, backend, and stack in JSON output, so the
  structured failure must be independently consumable.
  Date: 2026-09-14.

- Decision: Suppress the Pulumi program dependency-install progress line only for JSON context
  guard invocations.
  Rationale: workspace preparation can legitimately install dependencies before probing Pulumi,
  but an informational prefix makes the promised JSON failure stream unparsable. Human commands
  retain the progress line, and installation failures remain visible.
  Date: 2026-09-14.

- Decision: Amend ADR 9 in place without OKF metadata or a bundle log.
  Rationale: the repository has no profiled `docs/adr` bundle, so `ADR.md` requires preserving its
  established local-filesystem convention. The improvement-request bundle remains profile-governed
  and receives its required timestamp and log update.
  Date: 2026-09-14.

## Outcomes & Retrospective

The context guard now preserves why the Pulumi project probe did not yield a project. Missing
configuration, a missing executable, a start-time failure, a non-zero Pulumi exit, malformed output,
and a found project are distinct typed observations with cause-specific remedies. Every refusal
identifies the resolved stack and backend, and JSON callers receive exactly one parseable object
whose additive `stackProjectProbe` field carries the same distinction while the original nullable
`stackProject` remains compatible.

The focused suite passed 15 tests and the full nagarectl suite passed 469 tests. The hermetic
`nagare-operator-tools` and `nagare-clone-free-platform` derivations passed their missing-tool,
missing-key, command-failure, foreign-project, agreement, and JSON-stream assertions. `nix flake
check --print-build-logs` passed all 18 checks applicable to aarch64-darwin; it did not evaluate the
incompatible x86_64-linux outputs. Strict user-documentation validation passed with 37 concepts,
and profile/log-enforced improvement-request validation passed with 21 concepts.

The only unmet command exactly as anticipated by the original plan is strict improvement-request
validation: the repository baseline has no profile-recommended `reviews` field on 20 existing
requests. ADR 9 also could not use the anticipated strict bundle workflow because `docs/adr/` is a
plain filesystem collection, not a registered OKF bundle. Both discoveries were documented and
validated with the repository's actual conventions; neither represents an implementation defect
or remaining work for IR-9.

