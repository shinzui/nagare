---
id: 136
slug: apply-reviewed-infrastructure-and-confine-remote-builders
title: "Apply reviewed infrastructure and confine remote builders"
kind: exec-plan
created_at: 2026-09-14T04:16:15Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:15Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T13:38:21Z
      mode: "implement"
      note: "Started EP-3 implementation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:18:39Z
      mode: "implement"
      note: "Completed EP-3 implementation and validation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T22:59:26Z
      mode: "implement"
      note: "Hardened v0.3.0 release fixtures after Linux CI evidence"
---

# Apply reviewed infrastructure and confine remote builders

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator or CI job can save, inspect, and non-interactively apply the same constrained Pulumi
plan after every Nagare guard succeeds. The saved artifact is bound to one Nagare context, GCP
project, Pulumi backend, stack, program, configuration, and Pulumi version, so a plan from another
cluster is refused before cloud mutation. `nagare host-image --dry-run` also names the effective GCP
builder, and the real build uses the selected context's builder unless the operator explicitly
allows a logged cross-project exception. This plan implements IR-15 and IR-17.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T13:51Z) Define a context-bound saved-plan bundle and classify its reviewed operations.
- [x] (2026-09-14T13:51Z) Implement guarded preview/apply and reuse it in the upgrade transaction.
- [x] (2026-09-14T14:05Z) Generate and select a per-context GCP builder, with visible cross-project refusal/opt-in.
- [x] (2026-09-14T14:18Z) Cover teardown and non-interactive operation in docs, close the IRs, and run all gates.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: A newly added proxy or test is invisible to Nix flake evaluation until it is staged,
  even though ordinary shell tests see the worktree file. Evidence: the first operator-tools build
  refused the untracked `scripts/nix-builder-proxy.sh`; staging the two new scripts made the same
  three-check build proceed and pass.

- Observation: The strict improvement-request structure and log pass, but the optional
  `--profile-enforce` audit now reports the same missing recommended `reviews` field on 22 of the 23
  existing records. This is bundle-wide pre-existing provenance debt, not a schema or log failure;
  adding invented reviews to unrelated records would make the history less truthful.

- Observation: The native Darwin gate did not expose fixture executables whose
  `#!/usr/bin/env bash` shebangs are unavailable in a pure Linux Nix builder. Evidence: the
  v0.3.0 candidate's first Linux CI run passed all 552 Haskell tests, then failed before exercising
  the upload logic; invoking the repository script with the check-provided Bash and rendering that
  exact Bash path into every fake tool made the focused pure-build check pass.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store a Pulumi plan and a Nagare metadata sidecar as one directory bundle, and digest
  every member rather than modifying Pulumi's JSON.
  Rationale: `mori://pulumi/pulumi/packages/pulumi` serializes resource plans, configuration, and a
  manifest but no Nagare context, GCP project, backend, stack, or program digest. A sidecar preserves
  Pulumi compatibility while making those bindings explicit and independently testable.
  Date: 2026-09-14.

- Decision: Describe saved-plan apply as constrained, not atomic.
  Rationale: Pulumi permits safer operations such as `same` in place of update and update in place
  of replace, and cloud operations still execute over time. Nagare must promise that apply cannot
  exceed the reviewed plan, not that all resources change in one transaction.
  Date: 2026-09-14.

- Decision: Make the context's project the default builder project and require a named
  `--allow-shared-builder` acknowledgement for a known foreign project.
  Rationale: Cross-project builders can be useful, but an ambient `/etc/nix/machines` entry must not
  silently start and bill a VM outside the context.
  Date: 2026-09-14.

- Decision: Amend ADR 18 for context-bound saved plans and ADR 9 for builder project ownership.
  Rationale: Both are durable extensions to existing guarded-execution boundaries.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The public infra commands now make one Pulumi preview, preserve its plan plus review and binding
metadata in a private immutable directory, and pass that exact plan to non-interactive apply. The
upgrade transaction uses the same boundary. Focused Haskell tests (508 cases) and the clone-free
packaged scenario pass.

Host-image now renders a private per-context SSH route and explicit `--builders` value. Its default
builder is in the target project; a different `NAGARE_BUILDER_PROJECT` is refused unless the command
names that exact project with `--allow-shared-builder`. Hermetic confinement, packaged-proxy, and
shellcheck gates pass without consulting ambient builder configuration.

The v0.3.0 release audit also aligned the standalone clone-free rehearsal with the public reviewed
preview boundary, made its isolated Homebrew cleanup tolerate short-lived cache writers, and made
the upload-images confinement fixture portable to the pure Linux builder. The focused native Nix
checks pass with those release-hardening corrections.

IR-15 and IR-17 are completed, ADR 18 owns the retained constrained-plan boundary, and ADR 9 owns
builder project selection. The five focused operator guides, disaster-recovery teardown, reference,
and changelog now use the public commands. `just docs-validate`, strict/logged improvement-request
validation, all 508 Haskell tests, clone-free integration, and every buildable native flake check
pass. The optional profile-enforcement audit retains the bundle-wide review-provenance advisory
described above; no live disposable-project mutation was authorized in this implementation run.


## Context and Orientation

[IR-15](../improvement-requests/infra-up-cannot-apply-a-reviewed-plan-non-interactively.md) records
that `nagare infra-preview`, `nagarectl infra guard`, and the final `pulumi up` currently perform
separate previews. A non-TTY operator can skip confirmation only by applying a newly computed plan.
`justfile` owns `infra-preview` and `infra-up`; `cli/nagarectl/app/Main.hs` implements
`runInfraGuard` and the upgrade transaction's `PulumiApply` phase.

`cli/nagarectl/src/Nagare/Infra/Plan.hs` already parses preview events into `PlanStep`, classifies
protected replacements/deletes, and produces `PlanVerdict`. Extend this owner rather than creating
a second policy engine. Pulumi's registered source is
`mori://pulumi/pulumi/packages/pulumi`. Its preview command writes a JSON deployment plan with
`--save-plan`; update reads it with `--plan`. The resource-plan source states that inputs and
operations are constraints: unknown inputs may resolve later, `same` may replace update/replace,
and update may replace a planned replacement. It does not embed stack/context identity. Use the
Pulumi version already shipped by Nagare; this plan does not change a dependency bound.

Define a “saved-plan bundle” as a private directory containing `pulumi-plan.json`,
`review.json`, and `metadata.json`. `review.json` is the normalized, redacted step list and verdict
from the same preview invocation that saved the plan. `metadata.json` binds schema version, Nagare
context, target project, stack reference, backend URL, platform payload revision/digest, Pulumi
version, Pulumi project/config digests, creation time, and SHA-256 digests of the other members.
Do not include decrypted secret values. Apply recalculates every stable binding before invoking
Pulumi.

[IR-17](../improvement-requests/host-image-builder-escapes-the-context-project.md) records the
other ambient execution escape. `scripts/upload-images.sh` enforces the target project on its own
gcloud calls but invokes plain `nix build`; workstation configuration may route that build through
a different GCP VM. `scripts/setup-nix-builder.sh` provisions a builder in `TARGET_PROJECT` but
ships no context-parameterized workstation proxy. Dry-run does not show builder selection.

[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires all
cloud mutation to follow the context. [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md)
keeps instance shape in that context. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
requires upgrade phases to be resumable and guarded. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md)
requires Pulumi and helper tools in the released operator package. EP-2 may extend the context guard
with ADC evidence; consume it rather than forking it.


## Plan of Work

### Milestone 1: create and verify one reviewed-plan bundle

Extend `cli/nagarectl/src/Nagare/Infra/Plan.hs` with saved-bundle metadata, canonical JSON encoding,
member hashing, and pure binding verification. Add `InfraPreviewOpts` and `InfraApplyOpts` to
`cli/nagarectl/app/Main.hs`. Public commands are:

```text
nagarectl infra preview --save-plan DIR [--allow-replacement]
nagarectl infra apply --plan DIR --yes
```

Preview runs platform guard, the context/ADC guard, and one Pulumi preview from `infra/pulumi` with
machine-readable events and `--save-plan DIR/pulumi-plan.json`. It feeds those same events to the
existing classifier, refuses prohibited operations, then atomically writes the redacted review and
metadata. Because Pulumi output modes may not safely carry both event JSON and a saved plan in every
shipped version, first add a hermetic capability test against the packaged Pulumi; if necessary use
its event-log/summary output from the same process, never a second preview.

Apply requires `--yes`, checks private directory/file modes and no symlinks, validates hashes and
every current binding, reruns platform and context/ADC guards, reclassifies `review.json`, then runs
exactly `pulumi up --plan <file> --yes --non-interactive`. Refuse stale program/config/payload
digests, different stack/backend/project/context/Pulumi version, or a plan whose review permits
replacement only through an absent apply acknowledgement. Preserve useful Pulumi diagnostics.

Add pure and fake-Pulumi coverage in `cli/nagarectl/test/Spec.hs`, including different context,
stack, backend, project, modified member, changed program, prohibited replacement, guard failure,
and successful argv/order. Add launcher recipes `nagare infra-preview --save-plan DIR` and
`nagare infra-up --plan DIR`; an interactive recomputed apply may remain, but it must say it is not
the saved-plan path.

### Milestone 2: make upgrades consume the saved plan

Update the upgrade transaction in `cli/nagarectl/app/Main.hs` so its preview phase stores a bundle
inside the transaction state directory and `PulumiApply` consumes that exact bundle. Resume must
verify the bundle and current bindings again. If inputs changed, stop and require an explicit new
preview/transaction plan rather than silently recomputing. Add interruption/resume tests. Amend ADR
18 with the bundle boundary and constrained-not-atomic semantics.

### Milestone 3: make builder selection context-owned and visible

Ship a parameterized proxy/helper through `nix/haskell-packages.nix` and add context builder fields
or derived defaults to `scripts/lib/target.sh`: project defaults to target project, zone and
instance default to the values provisioned by `scripts/setup-nix-builder.sh`, and SSH alias includes
the context. Render a private per-context Nix builders specification under the context state or
config directory. Every gcloud command in the proxy must receive explicit project, zone, and
instance values.

Change `scripts/upload-images.sh` to resolve and print local system, target system, builder URI,
project, zone, instance, and whether a cross-project exception is active during `--dry-run` and
before build. Invoke `nix build` with the explicit rendered builder selection so ambient
`/etc/nix/machines` cannot choose another VM. Refuse a known different builder project unless the
operator passes `--allow-shared-builder PROJECT`; include that acknowledgement in output/logging.
Do not accept an unscoped environment escape. Keep a local compatible builder available where the
host system can build the target natively.

Add hermetic script tests for same-project rendering, foreign-project refusal, explicit opt-in,
dry-run evidence, and exact `nix build` argv. Extend installed-tool checks for the proxy. Amend ADR 9
with the default ownership and explicit exception.

### Milestone 4: document lifecycle and close

Update `docs/user/provisioning-with-pulumi.md`, `docs/user/host-image-and-boot.md`,
`docs/user/onboarding-bring-your-own-project.md`, `docs/user/upgrades.md`, and
`docs/user/reference.md`. Document saved-plan confidentiality, staleness, retry, and constrained
semantics; explain the deliberately separate guarded teardown command or sequence. Teardown must
run context/ADC guard immediately before `pulumi destroy` and remain interactive or require a
specific destructive confirmation. Update `CHANGELOG.md`, complete IR-15 and IR-17, and run gates.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`.

```bash
cabal test nagarectl-test
bash scripts/test-upload-images.sh
nix build .#checks.aarch64-darwin.nagare-operator-tools --print-build-logs
nix build .#checks.aarch64-darwin.nagare-clone-free-platform --print-build-logs
```

With fake Pulumi and an isolated context, the public transcript should have this shape:

```bash
nagarectl infra preview --context labs --save-plan .tmp/labs-plan
nagarectl infra apply --context labs --plan .tmp/labs-plan --yes
```

Expected output names context `labs`, its project/stack/backend, an accepted review verdict, and
`pulumi up --plan ... --yes --non-interactive`. Repeating apply after changing context or one program
file must refuse before fake Pulumi records an update. Builder evidence:

```bash
NAGARE_CONTEXT=labs nagare host-image --dry-run
```

must name the builder project as the labs target project. A foreign fixture exits nonzero unless
`--allow-shared-builder <project>` is supplied. Finish with OKF validation and `nix flake check
--print-build-logs`.


## Validation and Acceptance

A fake-Pulumi integration test must prove exactly one preview creates both the Pulumi plan and its
classified review, and apply invokes no preview. Successful apply runs every guard first and passes
`--plan`, `--yes`, and `--non-interactive`. Plans from another context, project, stack, backend,
payload, program/config digest, or Pulumi version fail before update; tampered files and prohibited
steps also fail. An interrupted upgrade resumes with the same verified bundle and refuses changed
inputs rather than recomputing.

The builder test must prove dry-run reports the effective project/zone/instance and real build argv
contains the explicit per-context builders value. Ambient builder configuration must not appear in
that argv. A known foreign project fails before any fake gcloud start or Nix build; explicit shared
builder opt-in succeeds and is visible. On an authorized disposable GCP context, the reviewed saved
plan applies without a TTY and `host-image` starts only the displayed builder.


## Idempotence and Recovery

Preview bundles are immutable after successful creation; refuse an existing destination unless the
operator explicitly chooses a new directory. A failed preview removes only its private staging
directory. A failed apply leaves the bundle for diagnosis and retry, but the retry first refreshes
all bindings; because Pulumi execution is not atomic, use `pulumi stack`/Nagare status to inspect
partial cloud progress and create a new reviewed plan if the old constraints no longer match.

Builder rendering is repeatable. Starting an already-running builder and rebuilding immutable image
outputs are safe. Never fall back to ambient builders after a context builder failure. Correct its
configuration or repeat with an explicit shared-builder acknowledgement. Teardown is destructive
and must never be inferred as a recovery step.


## Interfaces and Dependencies

Extend `Nagare.Infra.Plan` with stable data contracts equivalent to:

```haskell
data SavedPlanMetadata = SavedPlanMetadata
  { schemaVersion :: Int, context :: Text, project :: Text
  , stack :: Text, backend :: Text, payloadDigest :: Text
  , programDigest :: Text, configDigest :: Text, pulumiVersion :: Text
  , planDigest :: Text, reviewDigest :: Text }

verifySavedPlan :: CurrentInfraIdentity -> SavedPlanMetadata -> Either PlanBindingError ()
```

Keep secrets encrypted/redacted in Pulumi's file and out of `review.json`. Use the existing
`PlanStep`/`PlanVerdict`, SHA-256 support already used in Nagare, filesystem atomic rename, Pulumi,
Nix, gcloud, OpenSSH, and the existing target/context modules. Treat
`mori://pulumi/pulumi/packages/pulumi` as the canonical dependency source. EP-2 supplies ADC guard
evidence when available; EP-6 consumes the public preview/apply and builder behavior.


Revision note (2026-09-14): Began implementation with Milestone 1 after the MasterPlan confirmed
that EP-3 has no hard dependencies and EP-2's shared ADC guard evidence is available.

Revision note (2026-09-14): Completed the reviewed-plan, upgrade-reuse, and context-owned builder
milestones. Added focused and packaged regression evidence; documentation, ADRs, IR closure, and the
complete gate remain.

Revision note (2026-09-14): Completed EP-3. Documented the saved-plan and builder lifecycle, closed
IR-15 and IR-17, amended ADRs 18 and 9, and passed the full native flake gate.

Revision note (2026-09-14): Hardened the v0.3.0 release evidence after Linux CI exposed a fixture
shebang outside the pure-builder closure; the fixture now uses only the Nix-provided Bash.
