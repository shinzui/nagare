---
id: 110
slug: seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies
title: "Seed and pin the VM shape keys at init and guard instance-replacing applies"
kind: exec-plan
created_at: 2026-09-12T12:53:17Z
intention: "intention_01m2atvnagebcstgee18sjcyck"
provenance:
  created_by:
    model: "claude-opus-5[1m]"
    harness: "claude-code"
    at: 2026-09-12T12:53:17Z
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T13:09:52Z
      mode: "update"
      note: "Accept IR-4 with a targetPlan pointer and rewrite Milestone 5's closing steps from the pinned profile"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-13T04:29:00Z
      mode: "implement"
      note: "Implemented VM-shape seeding, resolver, guard, documentation, and closure milestones"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:53:19Z
      mode: "update"
      note: "Record resolved improvement-request review validation follow-up"
---

# Seed and pin the VM shape keys at init and guard instance-replacing applies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a single-node personal Platform-as-a-Service: one Google Compute Engine virtual
machine (a "VM" — a rented computer in Google's data centre) runs a small Kubernetes cluster
(k3s) that in turn runs the operator's applications. The cloud resources around that VM are
created by a Pulumi program (Pulumi is an infrastructure-as-code tool: a TypeScript program
declares the desired cloud resources, and `pulumi up` makes reality match the program). The
guided onboarding command `nagarectl init` writes the operator's chosen project, region, zone
and domain into a *target context* (a named file of `export VAR=value` lines) and copies eight
of those values into Pulumi's per-stack configuration.

Two settings that decide what the VM physically *is* are missing from that list: the machine
type (how many virtual CPUs and how much memory the VM has) and the boot-disk type (what kind
of storage the VM boots from). Because they are not written down anywhere, a freshly created
stack silently inherits whatever literal happens to sit in the Pulumi program on the day of
the first apply. For the machine type that is merely a sizing accident. For the boot-disk type
it is a trap with teeth: Google Compute Engine cannot convert a boot disk from one type to
another in place, so if that literal ever changes, the *next ordinary* `infra-up` — run for a
completely unrelated reason — plans to destroy and re-create the instance. The boot disk is
where the cluster actually lives: k3s keeps its cluster database under `/var/lib/rancher` on
the boot disk, not on the separately protected data disk, so a replacement would take with it
every Knative and cert-manager object, every issued TLS certificate, and the ACME account key
that Let's Encrypt issues certificates against.

After this change an operator gets three concrete things they do not have today.

First, `nagarectl init` asks for — or accepts as flags — the machine type, the boot-disk type,
the boot-disk size and the data-disk size, stores all four in the target context, and seeds
them into the Pulumi stack configuration alongside the existing eight keys. Running
`nagarectl context show` then displays the VM's shape, and `pulumi config` on a freshly created
stack lists `nagare:machineType`, `nagare:bootDiskType`, `nagare:bootDiskSizeGb` and
`nagare:dataDiskSizeGb` with the operator's chosen values. A later change to a literal inside
the Pulumi program cannot move a stack that has recorded its own answer.

Second, a new command `nagarectl infra guard` inspects the pending Pulumi plan and refuses to
let an apply proceed when that plan would replace the VM, printing exactly what a replacement
destroys. The recipe behind `nagare infra-up` (and `just infra-up`) runs the guard first, so
the refusal happens before anything touches Google Cloud rather than as a confusing mid-apply
failure. A deliberate rebuild is still possible — the operator sets
`NAGARE_ALLOW_VM_REPLACEMENT=1` for that one run — and the guard stays silent on an in-place
machine-type resize, which is the ordinary, supported way to give the box more CPU.

Third, the operator-facing documentation states which shape keys can be changed later on a
live VM and which force a rebuild, and names a recommended minimum machine type for a cluster
that will run the observability stack, so nobody starts below the waterline by accident.

You can see all three working without a Google Cloud account: the CLI test suite proves the
four keys are seeded and that the guard's plan classifier fires on a replacement and stays
quiet on an in-place update, and the hermetic end-to-end fixture in `flake.nix` runs a real
`nagarectl init` and asserts the four `pulumi config set` calls appear.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-13 04:29Z) M1: VM shape is part of the target context and is seeded by `init` / `context create`.
  - [x] Add `VmShape` and the four fields to `TargetProfile` in `cli/nagarectl/src/Nagare/Target.hs`.
  - [x] Resolve them in `profileFromContextMap` and `resolveProfileFrom`; render them in `renderTargetEnv`.
  - [x] Add `validateVmShape` with unit tests for every rejection message.
  - [x] Extend `seedKeys` in `cli/nagarectl/src/Nagare/Init.hs` from eight to twelve keys.
  - [x] Add the four flags and TTY prompts to `nagarectl init`, and the four flags to `nagarectl context create`.
  - [x] Export the four variables from `scripts/lib/target.sh` and document them in the two `*.env.example` files.
  - [x] Extend the hermetic `nagare-clone-free-platform` check in `flake.nix` to assert all four seeded keys.
- [x] (2026-09-13 04:32Z) M2: The Pulumi program reads the shape through one tested resolver.
  - [x] Extract `infra/pulumi/src/vmShape.ts` with `resolveVmShape` and `VM_SHAPE_FALLBACKS`.
  - [x] Use it from `infra/pulumi/index.ts`.
  - [x] Add `infra/pulumi/test/vmShape.test.ts` and the `infra-vm-shape` flake check.
  - [x] Add the `vm-shape-defaults-agree` flake check so the Haskell and TypeScript fallbacks cannot drift.
- [x] (2026-09-13 04:36Z) M3: An instance-replacing plan is refused before it can be applied.
  - [x] Add the pure classifier `cli/nagarectl/src/Nagare/Infra/Plan.hs`.
  - [x] Add the three preview fixtures under `cli/nagarectl/test/fixtures/pulumi-preview/`.
  - [x] Add the `Nagare.Infra.Plan` test group to `cli/nagarectl/test/Spec.hs`.
  - [x] Add the `nagarectl infra guard` command in `cli/nagarectl/app/Main.hs`.
  - [x] Wire the guard into the `infra-up` recipe in `justfile` and assert it in the clone-free check.
- [x] (2026-09-13 04:39Z) M4: Documentation tells the operator which changes are safe and which rebuild the box.
  - [x] `docs/user/provisioning-with-pulumi.md`: the in-place-versus-replacement matrix and the guard.
  - [x] `docs/user/resizing-the-vm.md`: point at the context key, drop the stale `tan-nb-exp` instruction.
  - [x] `docs/user/gcp-prerequisites.md`: the recommended minimum shape with its scheduling evidence.
  - [x] `docs/user/onboarding-bring-your-own-project.md`, `docs/user/contexts.md`, `docs/user/config-reference.md`, `docs/user/reference.md`.
  - [x] `docs/runbooks/disaster-recovery.md`: the deliberate-rebuild override.
  - [x] `okf log add docs/user` entry and a green `just user-documentation-validate`.
- [x] (2026-09-13 04:43Z) M5: Durable context recorded and the improvement request closed.
  - [x] (2026-09-13 04:40Z) Write `docs/adr/0014-the-active-context-owns-the-vm-shape.md` (ADR 9 was already allocated).
  - [x] Move `docs/improvement-requests/seed-vm-shape-keys-at-init.md` from `accepted` to `completed`, with `completedAt` and `resolution`, and log it.
  - [x] Fill in Outcomes & Retrospective.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Recorded during planning, before any code was written:

**The pinned Pulumi CLI's `preview --json` field names were confirmed from the binary, not from
memory.** The guard parses the JSON document that `pulumi preview --json` prints. Rather than
assume its shape, the field names were read out of the exact Pulumi build this repository pins
(3.239.0, overridden in `flake.nix`):

```text
$ strings "$(which pulumi)" | grep -E 'json:"(steps|op|urn|diffReasons|replaceReasons|detailedDiff|oldState|newState|diagnostics|duration)'
Op	json:"op"
json:"urn"
json:"steps"
json:"detailedDiff"
json:"oldState,omitempty"
json:"newState,omitempty"
json:"diffReasons,omitempty"
json:"diagnostics,omitempty"
json:"replaceReasons,omitempty"
$ strings "$(which pulumi)" | grep -o 'create-replacement\|delete-replaced\|import-replacement\|read-replacement\|discard-replaced' | sort -u
create-replacement
delete-replaced
discard-replaced
import-replacement
read-replacement
```

So the top-level document has `steps`, `changeSummary`, `diagnostics` and `duration`; each step
has `op` and `urn`, and optionally `diffReasons`, `replaceReasons`, `detailedDiff`, `oldState`
and `newState`. The operation tokens that mean "this resource is being torn down and rebuilt"
are `replace`, `create-replacement`, `delete-replaced`, `read-replacement`,
`import-replacement` and `discard-replaced`.

**`nagarectl context use` re-seeds the Pulumi config, so existing contexts heal themselves.**
`runContext` in `cli/nagarectl/app/Main.hs` calls `seedPulumiConfig` on every `context use` of a
cloud context and on `context create --use`, not only on `init`. Extending `seedKeys` therefore
pins the four keys on an already-created stack the next time the operator selects that context —
no separate migration command is needed. This is why M1 must keep the defaults equal to the
literals the Pulumi program uses today: re-seeding an existing stack must be a no-op against the
running VM, never a change that plans a replacement.

**The focused M1 tests pass, but the ambient Cabal package environment makes eight unrelated
application-fixture tests see two `nagare-dsl` package versions.** `cabal build all` succeeded
and `cabal test nagarectl-test --test-options='-p /Nagare.Init/'` reported all 27 focused tests
passing. The unfiltered run reached and passed the new tests, then the fixture loader failed with:

```text
Ambiguous module name ‘Nagare.Dsl.Application’.
it was found in multiple packages: nagare-dsl-0.1.0 nagare-dsl-0.1.0.0
```

This is local package-environment contamination rather than a VM-shape regression; the final
hermetic Nix check remains the acceptance source of truth.

**The planned ADR number was stale by implementation time.** The plan named ADR 9, but
`docs/adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md` now exists and
the corpus continues through ADR 13. The repository uses sequential plain Markdown records rather
than a profiled OKF bundle, so the VM-shape decision was allocated as ADR 14 without changing any
existing record.

**The strict improvement-request validator treats the bundle's pre-existing missing `reviews`
recommendations as errors.** The plan expected the strict command to print those four findings and
exit 0, but the installed `okf` exits 1 when `--strict` and `--profile-enforce` are combined. The
output contained only the four already-documented missing-`reviews` findings, including IR-4; the
same profile and log validation without `--strict` exited 0 with `OK: 5 concepts (okf_version 0.2)`.
No review provenance was invented to silence the strict check.

**The hermetic suite cleared the ambient Cabal false negative.**
`nix flake check --print-build-logs` built and ran the complete `nagarectl-test` suite in isolation,
then passed all 15 compatible aarch64-darwin checks, including `infra-vm-shape`,
`vm-shape-defaults-agree`, and `nagare-clone-free-platform`. This confirms that the eight local
fixture failures recorded above came from the ambient two-version package environment rather than
the implementation.

## Decision Log

Record every decision made while working on the plan.

- Decision: Build the replacement guard as a blocking preflight on the `infra-up` recipe
  (`nagarectl infra guard`), not as an advisory `nagarectl doctor` check.
  Rationale: IR-4 leaves the choice open ("in `nagarectl doctor`, or as a preflight on
  `infra-up`") and the operator chose the preflight. Its acceptance says the operator "is told
  exactly what will be destroyed before it happens"; a doctor check only helps an operator who
  thinks to run doctor, whereas a routine `infra-up` is precisely the path the improvement
  request is about. `just infra-up` already invokes `nagarectl platform guard` before
  `pulumi up`, so a second guard on the same line is an established shape, not a new idea.
  Date: 2026-09-12

- Decision: Keep the four shape values as `Text` inside `TargetProfile`, and validate them
  where they enter the system (`init`, `context create`) and again inside `infra guard`, rather
  than parsing them into numbers during context resolution.
  Rationale: every other field of `TargetProfile` is `Text` resolved by `ctxOr`, and making
  resolution fail on a malformed value would break unrelated read-only commands such as
  `nagarectl server status` for an operator with one bad character in a context file. Validating
  at write time stops bad values entering, and validating inside the guard makes the apply path
  fail closed, which is where fail-closed actually matters.
  Date: 2026-09-12

- Decision: Prove "a change to a program default does not alter the plan for a seeded stack" as
  a TypeScript unit test over an extracted pure resolver, not as a live `pulumi preview` diff.
  Rationale: a real preview needs Google Cloud credentials and a live stack, so it cannot run in
  `nix flake check`, which is this repository's CI. Extracting `resolveVmShape` and asserting
  that a reader carrying all four keys produces exactly those values even when the fallback
  record is deliberately different proves the property at the point where the value that feeds
  the resource is computed. The plan states this scope honestly rather than claiming a
  cloud-level guarantee it does not test.
  Date: 2026-09-12

- Decision: Keep `e2-standard-2` as the shipped default machine type and only recommend a larger
  one in prose.
  Rationale: IR-4 lists "a different default machine type by itself" as a non-goal, and changing
  the default would alter the plan for every unpinned stack — exactly the failure mode this work
  exists to prevent.
  Date: 2026-09-12

- Decision: Move IR-4 to `status: accepted` with a `targetPlan` pointer as soon as this plan
  existed, rather than leaving it `proposed` until the work lands.
  Rationale: the request's claims were all verified against the working tree during planning, so
  the decision to take it up has genuinely been made, and `accepted` is the profile's value for
  exactly that. `targetPlan` is the profile's optional field for "repository-relative path or
  Mori URI of the implementation plan", so the request and the plan now point at each other and
  a reader of either can find the other. `completed` is deliberately left for M5, when there is
  evidence to put in `resolution`.
  Date: 2026-09-12

- Decision: This plan is not a child of a MasterPlan.
  Rationale: IR-4 comes from a pre-flight review of the `v0.1.0` release, which has no MasterPlan
  of its own; MasterPlan 19 covers the July 2026 five-track review and is a different initiative.
  The work is a single self-contained change, so it stands alone.
  Date: 2026-09-12

- Decision: Record the context-owned VM-shape decision as ADR 14 rather than the planned ADR 9.
  Rationale: ADR 9 was allocated to project confinement after this plan was drafted, and the local
  plain-file ADR corpus now runs through ADR 13. Preserving stable existing numbers and taking the
  next sequential number follows the repository convention.
  Date: 2026-09-12

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

ExecPlan 110 delivered the original request without changing Nagare's shipped VM-size default.
Every target context now carries the machine type, boot-disk type, boot-disk size, and data-disk
size; init and context creation validate them; and selecting a cloud context seeds all four into
the matching Pulumi stack. The Pulumi resource consumes those values through one pure resolver,
with tests proving explicit values win over deliberately changed fallbacks and a Nix check proving
the Haskell and TypeScript defaults stay equal.

Routine `infra-up` now runs a Pulumi JSON preview before apply. The pure classifier permits an
in-place machine-type update, refuses every replacement operation for the GCE instance, and fails
closed on preview failure, malformed JSON, or an unknown operation. Its refusal names the k3s,
Knative, cert-manager, certificate, and ACME-key state on the boot disk and points to the deliberate,
invocation-scoped override. The operator documentation now distinguishes in-place changes from
instance replacement and recommends `e2-standard-4` for the observability workload while retaining
`e2-standard-2` as the default.

The required init-seeding, pinned-default, replacement, and in-place-update evidence is permanent:
27 focused init tests and seven plan-classifier tests passed; both TypeScript/Nix resolver checks
passed; the command-level guard scenario passed for refusal, override, and local mode; and
`nix flake check --print-build-logs` passed the full hermetic repository suite. The user-documentation
bundles also validate cleanly. IR-4 is completed and the durable ownership and safety policy is
recorded in ADR 14.

There are no implementation gaps. At implementation completion, the only validation caveat was
bundle-wide: strict OKF validation exited 1 for absent `reviews` provenance on four September
improvement requests. A 2026-09-14 content-and-metadata audit subsequently reviewed every request,
recorded truthful review provenance, and made the 23-concept strict validation pass.

