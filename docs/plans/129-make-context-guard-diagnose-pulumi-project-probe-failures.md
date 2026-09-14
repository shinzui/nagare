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
- [ ] Update operator documentation, the changelog, IR-9, and ADR 9 as implementation evidence
  becomes available; run focused and repository-wide validation.


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare calls a named collection of operator settings a “context.” A cloud context declares a Google
Cloud project, a Pulumi stack name, and a Pulumi backend URL. A Pulumi stack is one independently
managed infrastructure state; the backend URL says where its state is stored, such as a local
`file://` directory or a `gs://` Google Cloud Storage path. Before `infra-preview`, `infra-up`, or a
platform upgrade reaches Pulumi, `nagarectl context guard` compares the context project with the
stack’s `gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, and gcloud’s configured project.

The defect is recorded as
[IR-9](../improvement-requests/context-guard-misdiagnoses-a-missing-pulumi.md). Its observed command
had a correct context-owned `Pulumi.labs.yaml`, but a shell without `pulumi` received the same
“declares no gcp:project” message as a truly missing key. Backend authentication, locked state, and
wrong-backend errors take the same path.

`cli/nagarectl/src/Nagare/Ops/ContextGuard.hs` owns the pure `ProjectGuardInputs` record,
`projectGuardVerdict`, and the success renderer. `ProjectGuardInputs.stackProject` is currently a
`Maybe Text`, where `Nothing` means both “absent” and “could not be read.” The unit group named
`Nagare.Ops.ContextGuard (EP-113)` in `cli/nagarectl/test/Spec.hs` constructs that record directly
and tests the comparison table.

`cli/nagarectl/app/Main.hs` owns process execution and command rendering.
`runContextGuard` resolves the active context and its `PulumiEnv`, calls `ensurePulumiForContext`,
collects the three project observations through `projectGuardInputsFor`, applies the pure verdict,
and renders human or JSON output. `projectGuardInputsFor` currently calls
`Nagare.Ops.Probe.captureTool` with `pulumi -C <dir> config get gcp:project --stack <stack>`.
`captureTool`, in `cli/nagarectl/src/Nagare/Ops/Probe.hs`, catches a missing executable and maps both
that exception and every non-zero exit to `Nothing`; its contract is appropriate for best-effort
status probes but not for this guard. The same `projectGuardInputsFor` is called by the Pulumi phases
of `platform upgrade`, so the new refusal automatically protects both direct recipes and upgrades.

`ensurePulumiForContext` prepares the payload workspace, context-owned stack-config link,
`PULUMI_HOME`, backend directory, passphrase file, and environment. Its `pulumiQuiet` stack selection
also maps an unavailable Pulumi to exit 127, so execution reaches the project probe and can report a
specific missing-tool result. Do not weaken or remove this preparation; it makes the probe observe
the same stack and backend as the following operation.

`nix/checks/scripts/nagare-clone-free-platform.sh` tests successful and cross-project guard cases
with a fake Pulumi. `nix/checks/scripts/nagare-operator-tools.sh` already runs the unwrapped
nagarectl binary in a hermetic `PATH` with fake gcloud and npm but no Pulumi, making it the correct
place for IR-9’s missing-Pulumi command test. `nix/checks/platform.nix` supplies that script with the
unwrapped CLI and installed platform payload. `docs/user/contexts.md` and
`docs/user/provisioning-with-pulumi.md` describe the current refusal messages and remedies.
`CHANGELOG.md` is the unreleased user-facing change summary. The historical
`docs/releases/v0.2.2.md` correctly lists IR-9 as a known issue in that immutable release and must
not be rewritten.

Two local architecture decisions govern this work. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
requires every cloud-mutating path to prove the active context’s project and fail closed on any
unknown or disagreement. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
establishes the context-owned Pulumi stack configuration and remote-state model that the guard must
report accurately. No cross-repository ADR is needed. Implementation should append an amendment to
ADR 9 for the durable diagnostic contract; ADR 13 needs no change unless implementation alters
stack-config or backend ownership, which this plan does not intend.

The repository pins the Cradle process library from the registered dependency
`mori://garnix-io/cradle/packages/cradle`. Its local source confirms that a tuple containing
`ExitCode`, `StdoutRaw`, and `StderrRaw` captures all three values. This plan nevertheless uses the
already-imported `process` package in `Main.hs` because the guard’s runner is local to the CLI and
`readProcessWithExitCode` already has the required result shape.


## Plan of Work

### Milestone 1: represent and render the real probe result

Change `cli/nagarectl/src/Nagare/Ops/ContextGuard.hs` so the stack project is no longer represented
by `Maybe Text`. Introduce `PulumiProjectObservation` with cases for a found project, a genuinely
absent key, a missing Pulumi executable, a non-zero Pulumi exit carrying its numeric exit status and
trimmed stderr, and a successful command whose JSON cannot be interpreted. Add the resolved backend
URL to `ProjectGuardInputs`.

Add a pure `parsePulumiProjectConfig` function that accepts the bytes emitted by `pulumi config
--json`. It must return a found project for the object form used by pinned Pulumi 3.255.0, return the
absent case only for a valid object without `gcp:project`, and return a parse/shape error for invalid
JSON, a non-object top level, an entry without a textual `value`, or a blank value. Do not infer a
missing key from stderr text.

Update `projectGuardVerdict` to render a distinct refusal for every observation. Each refusal,
including the existing foreign-stack, ambient-project, and configured-project refusals, must name
the stack and backend. The missing-tool remedy points the operator at `nagarectl version --tools`
and the operator package; a non-zero exit prints Pulumi’s trimmed stderr and tells the operator to
fix that error under the environment shown by `nagarectl context env`; an absent key retains
`nagarectl context use <context>` as its remedy. A blank stderr uses a clear fallback such as
`(no stderr)` instead of producing an empty diagnosis. Keep the existing accepted confirmation line
unchanged.

Add `projectGuardObservationsValue`, or an equivalently named explicit JSON renderer, in the same
module. Its object keeps `context`, `declaredProject`, `stack`, `stackProject`, `ambientProject`, and
`configuredProject`; adds `pulumiBackendUrl`; and adds a `stackProjectProbe` object with a stable
`status` token. Use `found`, `missing`, `tool-not-found`, `command-failed`, and `invalid-output`.
Only applicable details are non-null: `project` for `found`, `exitCode` and `stderr` for
`command-failed`, and `error` for invalid output or startup failure. `stackProject` remains the found
text or JSON null for compatibility.

Expand `contextGuardTests` in `cli/nagarectl/test/Spec.hs`. Test all five observation cases, the
exact remediation distinction among missing tool, command failure, and absent key, inclusion of
stack/backend in every refusal family, parser behavior for found/absent/malformed JSON, and JSON
status/details. Existing agreement and disagreement tests remain.

At the end of this milestone the pure test group passes without invoking Pulumi, proving that the
model cannot collapse one failure cause into another.

### Milestone 2: collect detailed process evidence and prove the command behavior

In `cli/nagarectl/app/Main.hs`, replace `projectGuardInputsFor`’s `captureTrimmed` call with a
guard-specific `probePulumiProject`. First use `findExecutable "pulumi"`; when it returns `Nothing`,
return the missing-tool observation without starting a process. Otherwise run this exact command
with the environment already established by `ensurePulumiForContext`:

```text
pulumi -C <workspace>/infra/pulumi config --json --stack <stack> --non-interactive
```

Capture exit code, stdout, and stderr through `readProcessWithExitCode`, catching `IOException` in
case the executable disappears or cannot start after lookup. Successful output goes through
`parsePulumiProjectConfig`. A non-zero exit becomes the command-failed observation and preserves
trimmed stderr; if stderr is blank, preserve trimmed stdout as the diagnostic before falling back to
`(no stderr)`. A caught startup exception uses the tool/start-failure observation and retains the
exception text. This path must not call the best-effort `captureTool`.

Have `projectGuardInputsFor` set `pulumiBackendUrl` from `pulumiEnvFor`’s resolved `backendUrl`, not
from the possibly empty raw `NAGARE_PULUMI_BACKEND_URL` context field. Replace the hand-built
`observed` object in `runContextGuard` with the library renderer. On a human failure, retain `dieT`.
On a JSON failure, write one encoded failure object to stderr and call `exitFailure` directly so no
plain-text suffix corrupts it. The failure object keeps the top-level `confined: false`, `refusal`,
and `observations`; success keeps `confined: true` and `observations` on stdout.

Extend `nix/checks/scripts/nagare-operator-tools.sh` after its existing missing-Pulumi init test.
Using the same unwrapped CLI, isolated home/config/state directories, installed platform root, and a
`PATH` containing fake npm/gcloud but no Pulumi, create a cloud context whose ambient project agrees.
Run the human guard and assert a non-zero exit, a “pulumi was not found” diagnosis, the stack name,
the resolved local `file://` backend, and no “declares no gcp:project” text. Run the JSON form into a
separate stderr file, assert stdout is empty, parse the whole stderr file with jq, and assert
`confined == false`, `stackProjectProbe.status == "tool-not-found"`, and the expected stack/backend.

Extend the fake Pulumi in `nix/checks/platform.nix` and the cases in
`nix/checks/scripts/nagare-clone-free-platform.sh` for the new `config --json` invocation. The fake
must be able to return an agreeing project, a foreign project, a valid object without the key, or a
controlled non-zero exit with a distinctive stderr line. Assert that the existing success and
foreign-project cases still work, the missing-key case gives the projection remedy, and the failed
command case reports the fake stderr and does not claim the key is absent. Also parse one JSON
failure to exercise the additive observation schema with Pulumi present.

At the end of this milestone both Nix checks pass. The absent-PATH case fails before an
infrastructure operation, and each fake Pulumi outcome is observable in the command’s exit status
and output.

### Milestone 3: document, distill, and validate

Update `docs/user/contexts.md` and `docs/user/provisioning-with-pulumi.md` with the three primary
operator-visible failure classes and their different remedies. State that every refusal names the
resolved stack and backend, and document the additive `stackProjectProbe` JSON object. Keep the
warning that the guard has no bypass. Add a concise IR-9 item under the unreleased section of
`CHANGELOG.md`. Do not change the v0.2.2 release notes.

Append an amendment to
`docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md`: an unknown stack
project is a typed observation, not an absent value; the guard reports process failures while still
refusing; and its diagnostics identify the exact stack/backend it protected. Preserve any existing
uncommitted amendment and use the profiled ADR workflow, including timestamp/log updates and strict
validation. Re-read ADR 13 and change it only if implementation unexpectedly changes ownership or
persistence, recording that discovery in this plan first.

As work proceeds, maintain this plan’s Progress, Surprises & Discoveries, Decision Log, and Outcomes
& Retrospective sections. When implementation is complete, set IR-9 to completed with evidence and
update the improvement-request bundle log; the link to this plan is added when the plan is created,
before implementation begins. Every implementation commit must use Conventional Commits and both
active trailers, for example:

```text
fix(nagarectl): diagnose Pulumi context guard failures

ExecPlan: docs/plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md
Intention: intention_01m2et8vb8e8va10xx0my86psf
```

At the end of this milestone the focused tests, both affected Nix checks, strict OKF validations,
and the full flake check pass, and the plan records the observed totals and outcomes.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/nagare` unless a subshell changes directory.
Before editing, inspect the worktree and preserve unrelated changes:

```bash
git status --short
git diff -- cli/nagarectl/src/Nagare/Ops/ContextGuard.hs cli/nagarectl/app/Main.hs \
  cli/nagarectl/test/Spec.hs nix/checks/platform.nix \
  nix/checks/scripts/nagare-clone-free-platform.sh \
  nix/checks/scripts/nagare-operator-tools.sh docs/adr docs/improvement-requests
```

After Milestone 1, run the focused unit group:

```bash
(cd cli/nagarectl && \
  nix develop ../.. -c cabal test nagarectl-test \
    --test-options='-p "Nagare.Ops.ContextGuard"' \
    --test-show-details=direct)
```

The transcript should end with a passing test summary and no case that calls a real Pulumi binary.
Then run the full Haskell suite to catch record-constructor changes outside the focused group:

```bash
(cd cli/nagarectl && \
  nix develop ../.. -c cabal test nagarectl-test --test-show-details=direct)
```

After Milestone 2, build the two command checks on the current supported system:

```bash
nix build .#checks.aarch64-darwin.nagare-operator-tools --print-build-logs
nix build .#checks.aarch64-darwin.nagare-clone-free-platform --print-build-logs
```

The missing-tool scenario should prove output equivalent to the following, with the actual resolved
temporary backend path:

```text
nagarectl: refusing to run: pulumi was not found on PATH while reading gcp:project for stack 'guardcloud' at backend 'file://.../state'.
```

The failed-command fake should preserve its sentinel stderr, for example:

```text
error: could not access backend: test authentication failure
```

The JSON assertion should be able to parse the entire file, not just its first line:

```bash
jq -e '
  .confined == false and
  .observations.stack == "guardcloud" and
  .observations.pulumiBackendUrl == $backend and
  .observations.stackProjectProbe.status == "tool-not-found"
' --arg backend "$expected_backend" guard-missing.json
```

After documentation and ADR edits, enforce the two profiled bundles:

```bash
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
okf validate docs/improvement-requests \
  --strict \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Finish with the repository gate:

```bash
nix flake check --print-build-logs
```

Record the exact test count, Nix derivations, and any platform-specific limitation in this plan
before marking its final Progress item complete.


## Validation and Acceptance

The change is accepted when all of the following behavior is demonstrated.

A valid Pulumi config containing `gcp:project: acme-prod` and an agreeing context exits zero and
keeps the existing success line. A valid config object without `gcp:project` exits non-zero, names
the stack and backend, says the key is absent, and recommends `nagarectl context use <context>`.

With no Pulumi executable on `PATH`, the unwrapped CLI exits non-zero, names the absent executable,
stack, and backend, offers the tool/package remedy, and never says the stack lacks `gcp:project`.
This must be proven by the hermetic `nagare-operator-tools` derivation, not only by a pure test.

When Pulumi starts but exits non-zero, the guard exits non-zero, identifies it as a command failure,
includes the numeric exit code and captured stderr, names the stack/backend, and never recommends
re-projecting the stack merely because the command failed. A successful command with malformed JSON
also refuses and explicitly says its output could not be interpreted.

For `--json`, success remains a JSON object on stdout. Failure produces exactly one JSON object on
stderr and no stdout, so `jq` can parse the complete stream. The object preserves the existing
`stackProject` member, adds `pulumiBackendUrl`, and gives the exact probe state under
`stackProjectProbe`. The stack name remains present for every outcome.

The guard remains fail-closed for every pre-existing mismatch: foreign stack project, disagreeing
ambient `CLOUDSDK_CORE_PROJECT`, and disagreeing configured gcloud project. Platform upgrade’s
Pulumi preview/apply phases receive the same detailed refusal because they share
`projectGuardInputsFor`. No test or implementation adds an override.

The focused Haskell group, full nagarectl suite, `nagare-operator-tools`,
`nagare-clone-free-platform`, both strict OKF bundle validations, and `nix flake check
--print-build-logs` all exit zero.


## Idempotence and Recovery

All planned code, test, and documentation edits are additive or local replacements and can be
applied and validated repeatedly. The guard and its tests perform only reads of Pulumi configuration;
they do not run `pulumi config set`, `pulumi up`, or another cloud mutation. Hermetic command tests
use Nix build directories and isolated `HOME`, `XDG_CONFIG_HOME`, and `XDG_STATE_HOME` values.

If the JSON listing proves incompatible with a supported Pulumi output shape, capture the exact
non-secret output in Surprises & Discoveries, add a fixture and parser case, and retain the
fail-closed invalid-output result until the shape is understood. Do not fall back to matching the
English missing-key error.

If an edit collides with existing work in ADR 9 or another dirty file, preserve the existing text
and append or integrate the new material. Do not reset or overwrite unrelated changes. The current
worktree already contains edits to ADR 9 from completed v0.2.2 work, so implementation must inspect
the diff before adding its amendment.

If a focused test fails after changing `ProjectGuardInputs`, update every constructor reported by
the compiler; do not introduce a temporary `Maybe Text` adapter that recreates the ambiguity. A
failed Nix build is safe to rerun after correcting its script. No data migration or rollback is
needed because the command’s stored context, stack config, and backend state formats do not change.


## Interfaces and Dependencies

`cli/nagarectl/src/Nagare/Ops/ContextGuard.hs` must export the new observation type, parser, existing
verdict/success renderer, and explicit JSON renderer. Exact constructor names may follow repository
style, but the semantic interface must be equivalent to:

```haskell
data PulumiProjectObservation
  = PulumiProjectFound Text
  | PulumiProjectMissing
  | PulumiToolNotFound
  | PulumiCommandFailed Int Text
  | PulumiProjectInvalidOutput Text

data ProjectGuardInputs = ProjectGuardInputs
  { context :: Text
  , declared :: Text
  , stack :: Text
  , pulumiBackendUrl :: Text
  , stackProject :: PulumiProjectObservation
  , ambient :: Maybe Text
  , configured :: Maybe Text
  }

parsePulumiProjectConfig :: ByteString -> Either Text PulumiProjectObservation
projectGuardVerdict :: ProjectGuardInputs -> Either Text ()
renderProjectGuard :: ProjectGuardInputs -> Text
projectGuardObservationsValue :: ProjectGuardInputs -> Aeson.Value
```

If a start-time `IOException` needs detail beyond `PulumiToolNotFound`, add a separate
`PulumiToolStartFailed Text` constructor and its `tool-start-failed` JSON token rather than
mislabeling permission or race errors. The no-PATH preflight must still produce
`tool-not-found` exactly.

`cli/nagarectl/app/Main.hs` must provide an IO collector equivalent to:

```haskell
probePulumiProject :: FilePath -> Text -> IO PulumiProjectObservation
projectGuardInputsFor :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ProjectGuardInputs
```

The collector uses `System.Directory.findExecutable` and
`System.Process.readProcessWithExitCode`, both already available through the existing `directory`
and `process` dependencies in `cli/nagarectl/nagarectl.cabal`. JSON parsing/rendering uses the
existing `aeson` and `bytestring` dependencies. No new package bounds, external service, Pulumi
plugin, stack schema, or persistent data format is introduced.

The external Pulumi CLI contract is the pinned 3.255.0 behavior checked during plan research:
`pulumi config --json --stack <stack> --non-interactive` returns a JSON object on success, and the
`gcp:project` entry has a textual `value` member. The implementation must treat every non-zero exit
as process failure before parsing stdout. The context’s resolved `PulumiEnv.backendUrl` and
`PulumiEnv.stack` remain authoritative; raw ambient values must not be substituted for them.
