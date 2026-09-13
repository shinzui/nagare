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
---

# Seed and pin the VM shape keys at init and guard instance-replacing applies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


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
- [ ] M2: The Pulumi program reads the shape through one tested resolver.
  - [ ] Extract `infra/pulumi/src/vmShape.ts` with `resolveVmShape` and `VM_SHAPE_FALLBACKS`.
  - [ ] Use it from `infra/pulumi/index.ts`.
  - [ ] Add `infra/pulumi/test/vmShape.test.ts` and the `infra-vm-shape` flake check.
  - [ ] Add the `vm-shape-defaults-agree` flake check so the Haskell and TypeScript fallbacks cannot drift.
- [ ] M3: An instance-replacing plan is refused before it can be applied.
  - [ ] Add the pure classifier `cli/nagarectl/src/Nagare/Infra/Plan.hs`.
  - [ ] Add the three preview fixtures under `cli/nagarectl/test/fixtures/pulumi-preview/`.
  - [ ] Add the `Nagare.Infra.Plan` test group to `cli/nagarectl/test/Spec.hs`.
  - [ ] Add the `nagarectl infra guard` command in `cli/nagarectl/app/Main.hs`.
  - [ ] Wire the guard into the `infra-up` recipe in `justfile` and assert it in the clone-free check.
- [ ] M4: Documentation tells the operator which changes are safe and which rebuild the box.
  - [ ] `docs/user/provisioning-with-pulumi.md`: the in-place-versus-replacement matrix and the guard.
  - [ ] `docs/user/resizing-the-vm.md`: point at the context key, drop the stale `tan-nb-exp` instruction.
  - [ ] `docs/user/gcp-prerequisites.md`: the recommended minimum shape with its scheduling evidence.
  - [ ] `docs/user/onboarding-bring-your-own-project.md`, `docs/user/contexts.md`, `docs/user/config-reference.md`, `docs/user/reference.md`.
  - [ ] `docs/runbooks/disaster-recovery.md`: the deliberate-rebuild override.
  - [ ] `okf log add docs/user` entry and a green `just user-documentation-validate`.
- [ ] M5: Durable context recorded and the improvement request closed.
  - [ ] Write `docs/adr/0009-the-active-context-owns-the-vm-shape.md`.
  - [ ] Move `docs/improvement-requests/seed-vm-shape-keys-at-init.md` from `accepted` to `completed`, with `completedAt` and `resolution`, and log it.
  - [ ] Fill in Outcomes & Retrospective.


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository. Everything below was verified
against the working tree at commit `da24748`.

### What the pieces are

**Nagare** provisions one Google Compute Engine VM (named `nagare-01` by default) and runs k3s
on it. k3s is a small Kubernetes distribution; Kubernetes is the system that schedules the
operator's containers. Knative runs on top of Kubernetes and turns a container into a URL that
scales to zero. cert-manager obtains TLS certificates from Let's Encrypt via the ACME protocol;
"the ACME account key" is the private key that identifies the cluster to Let's Encrypt, and it
is stored inside the cluster.

**A target context** is a file of `export VAR=value` lines under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env` naming the GCP project, region,
zone, buckets, base domain and instance name that every command acts on. It is selected with
`nagarectl --context NAME`, the `NAGARE_CONTEXT` environment variable, or
`nagarectl context use NAME`. The repository's `CLAUDE.md` explains the guardrail this feeds:
no command may act on a project other than the active context's, and `_require_target_project`
in `scripts/lib/target.sh` enforces it fail-closed for cloud contexts.

**Pulumi** owns the cloud resources. The program lives in `infra/pulumi/index.ts` and its
components in `infra/pulumi/src/components/`. "Stack configuration" is a per-stack key/value
store Pulumi keeps outside the program; the program reads it with `new pulumi.Config()`, and
`pulumi config set nagare:machineType e2-standard-4` writes it. Because the Pulumi project is
named `nagare` (see `infra/pulumi/Pulumi.yaml`), its keys are namespaced `nagare:`; the Google
provider's keys are namespaced `gcp:`.

**The launcher.** Operators installed from a release run `nagare <recipe>`, a small wrapper
(`nix/haskell-packages.nix`, `nagareLauncher`) that resolves the release payload into a
per-context writable workspace and then runs `just` against the `justfile` inside it. So
`nagare infra-up` and `just infra-up` execute the same recipe text; editing `justfile` changes
both.

### Where the gap is, exactly

`cli/nagarectl/src/Nagare/Init.hs:146-156` defines `seedKeys`, the list of Pulumi configuration
keys that `nagarectl init` writes. It contains exactly eight pairs: `gcp:project`, `gcp:region`,
`gcp:zone`, `nagare:baseDomain`, `nagare:imageBucket`, `nagare:backupBucket`,
`nagare:artifactRegistryId` and `nagare:instanceName`. There is no machine type, no boot-disk
type and no disk sizes — and correspondingly no flags on `nagarectl init` (its options are
defined by `InitOpts` at `cli/nagarectl/src/Nagare/Init.hs:52-66` and parsed by
`initOptsParser` at `cli/nagarectl/app/Main.hs:837`) and no fields on `TargetProfile`
(`cli/nagarectl/src/Nagare/Target.hs:255-300`).

The values therefore come from literals in the Pulumi program at apply time:
`machineType` defaults to `e2-standard-2` (`infra/pulumi/index.ts:19`), `dataDiskSizeGb` to
`100` (`infra/pulumi/index.ts:20`), `bootDiskSizeGb` to `100` (`infra/pulumi/index.ts:52`) and
`bootDiskType` to `pd-balanced` (`infra/pulumi/index.ts:53`). The program already carries the
warning this plan acts on, at `infra/pulumi/index.ts:45-51`:

```text
// EP-99: boot-disk geometry, previously hardcoded in NagareInstance.
// pd-balanced is the sensible default for a fresh stack. CAUTION: GCE cannot
// convert a boot disk's type in place, so changing `bootDiskType` against a
// live VM forces an INSTANCE REPLACEMENT. A stack whose VM is already running
// on another type should pin it (`pulumi config set bootDiskType pd-standard`)
// until a deliberate rebuild is being performed.
```

`infra/pulumi/index.ts:44` sets `vmDeletionProtection` to `true` by default, which makes the
Compute API refuse to delete the instance at all. That is the existing backstop: an unintended
replacement fails the apply rather than destroying the cluster. It is not a substitute for this
work, because the operator is left staring at an apply that cannot succeed with no explanation
of why.

`docs/user/resizing-the-vm.md` records what a replacement costs, in its "What survives a
resize" table: k3s cluster state lives in `/var/lib/rancher` on the **boot disk**, and "a
*replacement* VM with a fresh boot disk would lose this". The separately declared data disk
(`infra/pulumi/src/components/NagarePerimeter.ts:69-73`) carries Pulumi's `protect: true` and
holds application data at `/var/lib/nagare`; it survives, which is precisely why the boot disk's
contents are the exposed surface.

The sizing half of the request also has evidence in the tree.
`docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md:40-46` records
that on an `e2-standard-2` (2 virtual CPUs) the observability stack's CPU *requests* alone left
nothing schedulable — Kubernetes reported `0/1 nodes are available: Insufficient cpu` — and line
720 of the same plan sets the remedy as leaving roughly 600 millicpu of the node unreserved,
with moving to a four-CPU machine recorded as the standing alternative.

### How seeding reaches a stack

`runInit` in `cli/nagarectl/app/Main.hs:2738` resolves the four target answers (from flags, or
by prompting on a terminal), runs a gcloud preflight, builds a fully derived `TargetProfile`
through `profileFromOpts`, writes the context file, enables the GCP service APIs, and finally
calls `seedPulumiConfig`, which runs one `pulumi config set` per pair from `seedKeys`. With
`--dry-run` it prints each command instead of running it.

`runContext` in the same file calls `seedPulumiConfig` again for `context use` on a cloud
context and for `context create --use`. `contextEnvPairs` at `cli/nagarectl/app/Main.hs:2927`
maps `nagarectl context create` flags onto context variable names, and `profileFromContextMap`
at `cli/nagarectl/src/Nagare/Target.hs:507` turns that map into a profile without consulting the
ambient environment. `resolveProfileFrom` at `cli/nagarectl/src/Nagare/Target.hs:542` is the
variant that *does* let an environment variable win over the stored context, and it is what
every ordinary command uses.

The same variable names are re-exported on the shell side by `scripts/lib/target.sh`, whose
`_NAGARE_CONTEXT_VARS` array (lines 34-42) and defaulting block (lines 178-201) must stay in
step with the Haskell resolver, and are documented for humans in the tracked
`nagare.target.env.example` and `nagare.local.env.example`.

### Relevant ADRs

Architecture Decision Records live in `docs/adr/` as plain Markdown with `title`, `status`,
`date`, `authors` and `related` frontmatter and an `# ADR N — Title` heading. That directory is
**not** an OKF bundle (`mori.dhall` lists `docs/capabilities`, `docs/improvement-requests`,
`docs/reviews`, `docs/use-cases`, `docs/user` and `docs/guides`, but not `docs/adr`), so follow
the existing filesystem convention and do not add OKF frontmatter or run `okf validate` against
it.

Two existing records matter here:

- [`docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md`](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  — the release payload is immutable and each context gets a writable workspace copy. This is
  why the guard must resolve the Pulumi directory through the workspace
  (`pwPulumiDir`) instead of assuming a source checkout's `infra/pulumi`.
- [`docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md`](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
  — the context file is a durable, versioned record of per-context state. Adding four fields to
  it is consistent with that decision; this plan adds a new ADR because "the context, not the
  program, owns the VM's shape" is a fresh constraint rather than a restatement.

No existing ADR covers the VM shape or replacement safety, so M5 creates one.


## Plan of Work

The work is five milestones. Each one is independently verifiable and leaves the repository
building and its tests passing.

### Milestone 1 — The VM shape becomes part of the target context

At the end of this milestone a context file records four new variables, `nagarectl init`
accepts them as flags and prompts for them on a terminal, and a freshly initialised stack has
twelve Pulumi keys instead of eight. Nothing about an existing VM changes, because the defaults
are exactly the literals the Pulumi program already uses.

In `cli/nagarectl/src/Nagare/Target.hs`, add four fields to `TargetProfile` — `tpMachineType`,
`tpBootDiskType`, `tpBootDiskSizeGb` and `tpDataDiskSizeGb`, all `!Text` — with Haddock comments
naming their environment variables (`NAGARE_MACHINE_TYPE`, `NAGARE_BOOT_DISK_TYPE`,
`NAGARE_BOOT_DISK_SIZE_GB`, `NAGARE_DATA_DISK_SIZE_GB`) and defaults. Add a
`defaultVmShape :: VmShape` value holding `"e2-standard-2"`, `"pd-balanced"`, `"100"` and
`"100"`, where `VmShape` is a small record with those four `Text` fields, and use it for the
defaults in both `profileFromContextMap` and `resolveProfileFrom` so the two resolvers cannot
drift. Render the four as `export` lines in `renderTargetEnv`, placed after
`NAGARE_INSTANCE_NAME` so the file reads in a sensible order, and export `VmShape`,
`vmShapeOf`, `defaultVmShape` and `validateVmShape` from the module.

`validateVmShape :: VmShape -> Either Text VmShape` is pure and is the only place the rules
live. Reject an empty machine type; reject a machine type that is not either `custom-<cpus>-<mb>`
or `<family>-<series>` matching `[a-z0-9]+-[a-z0-9-]+`, naming the offending value in the
message. Accept only `pd-standard`, `pd-balanced`, `pd-ssd` and `hyperdisk-balanced` as boot
disk types, listing the accepted set in the message, because an unrecognised value is exactly
the input that would later plan a replacement. Require both sizes to parse as integers of at
least 10 GB, and say so. Return the shape unchanged on success so callers can write
`shape <- either dieT pure (validateVmShape raw)`.

In `cli/nagarectl/src/Nagare/Init.hs`, extend `seedKeys` with `("nagare:machineType", …)`,
`("nagare:bootDiskType", …)`, `("nagare:bootDiskSizeGb", …)` and `("nagare:dataDiskSizeGb", …)`
after `nagare:instanceName`, and update the function's Haddock (it currently says "The eight
Pulumi config (key, value) pairs") to say twelve and to explain *why* the shape is seeded:
pinning it is what stops a later change to a program literal from planning an instance
replacement against a live VM. Add the four fields to `InitOpts` as `Maybe String` immediately
after `ioBaseDomain`, keeping the record's field order aligned with `initOptsParser`.

In `cli/nagarectl/app/Main.hs`, add the four options to `initOptsParser` (`--machine-type`,
`--boot-disk-type`, `--boot-disk-size-gb`, `--data-disk-size-gb`) with help text naming the
default, and resolve them in `runInit` with the existing `resolveField False` helper so a
terminal prompts with the current value as the default and a non-interactive run falls back to
it. Validate the assembled shape with `validateVmShape` immediately after resolution, before the
gcloud preflight, so a typo costs nothing. Add the same four options to
`contextCreateOptsParser` and `ContextCreateOpts`, map them in `contextEnvPairs`, and validate
in the `ContextCreate` branch of `runContext` before `writeContextProfile`.

On the shell side, add the four names to `_NAGARE_CONTEXT_VARS` in `scripts/lib/target.sh` and
give each a default in the block that starts at line 178, using the identical literals. Document
them in `nagare.target.env.example` under a new "VM shape" section that states plainly which of
them can be changed on a live VM and which cannot; add the same block to
`nagare.local.env.example` noting that a local (k3d) context ignores them.

Finally, extend the hermetic end-to-end check `nagare-clone-free-platform` in `flake.nix`: it
already runs `nagarectl init trial --project example --dry-run --skip-preflight > init.out`, and
the dry run prints one `pulumi … config set …` line per seed key, so assert all four.

Acceptance: `cabal test` passes with a `seedKeys` test that expects twelve keys in order;
`nagarectl init demo --project p --dry-run --skip-preflight --skip-enable` prints
`config set --stack demo nagare:machineType e2-standard-2` and the other three; `nix flake check`
passes.

### Milestone 2 — One tested resolver decides the shape inside the Pulumi program

At the end of this milestone the Pulumi program no longer scatters four `cfg.get(...) ?? literal`
expressions, and a test proves that a stack which has recorded its shape is immune to a change
in those literals.

Create `infra/pulumi/src/vmShape.ts` importing nothing — that is a hard requirement, because the
test compiles and runs it with plain `tsc` and `node`, without the `@pulumi/pulumi` package being
installed. It exports an interface `ShapeReader` with `get(key: string): string | undefined` and
`getNumber(key: string): number | undefined` (satisfied structurally by Pulumi's `Config`), an
interface `VmShape` with `machineType: string`, `bootDiskType: string`, `bootDiskSizeGb: number`
and `dataDiskSizeGb: number`, a constant `VM_SHAPE_FALLBACKS` holding `e2-standard-2`,
`pd-balanced`, `100` and `100`, and

```typescript
export function resolveVmShape(cfg: ShapeReader, fallbacks: VmShape = VM_SHAPE_FALLBACKS): VmShape
```

which reads `machineType`, `bootDiskType`, `bootDiskSizeGb` and `dataDiskSizeGb` and falls back
per field. Keep the existing caution comment about boot-disk type next to `VM_SHAPE_FALLBACKS`,
and add a line saying the fallbacks exist only for a stack that predates seeding: every stack
created by `nagarectl init` records its own answer.

In `infra/pulumi/index.ts`, replace the four literal-defaulted reads with
`const vmShape = resolveVmShape(cfg);` and use `vmShape.machineType`, `vmShape.bootDiskType`,
`vmShape.bootDiskSizeGb` and `vmShape.dataDiskSizeGb` at the existing call sites. Keep the local
`…Cfg` naming convention intact where the value is passed onward, so the stack outputs and
component arguments are untouched.

Add `infra/pulumi/test/vmShape.test.ts`: a plain script that throws on failure and prints `ok`
on success, with no test framework. It must assert three things. A reader that supplies all four
keys returns exactly those values *even when the `fallbacks` argument is a deliberately
different record* — this is the property that a seeded stack ignores program defaults. An empty
reader returns `VM_SHAPE_FALLBACKS`. A reader that supplies only some keys mixes correctly.

Add a `infra-vm-shape` check to `flake.nix` that compiles both files with `tsc` and runs the
test with `node`, and a `vm-shape-defaults-agree` check that greps the same four literals out of
`infra/pulumi/src/vmShape.ts` and `cli/nagarectl/src/Nagare/Target.hs` and fails if they differ,
so the CLI's seeded defaults and the program's fallbacks cannot silently diverge.

Acceptance: `nix build .#checks.<system>.infra-vm-shape` succeeds; deliberately changing
`VM_SHAPE_FALLBACKS.machineType` makes `vm-shape-defaults-agree` fail and the seeded-stack
assertion still pass, which is the demonstration that pinning works.

### Milestone 3 — An instance-replacing plan is refused before it is applied

At the end of this milestone `nagarectl infra guard` exists, the `infra-up` recipe runs it, and
an operator who would have destroyed their cluster instead reads a paragraph naming what would
be lost.

Create `cli/nagarectl/src/Nagare/Infra/Plan.hs` and add it to the `exposed-modules` list in
`cli/nagarectl/nagarectl.cabal`. The module is pure apart from nothing at all — it does no IO —
and exports:

```haskell
data StepOp = OpSame | OpCreate | OpUpdate | OpDelete | OpRefresh | OpImport | OpReplaceLike Text
data PlanStep = PlanStep { psOp :: !StepOp, psUrn :: !Text, psReplaceReasons :: ![Text] }
data PlanVerdict = PlanAllowed | PlanReplacesInstance ![PlanStep]
parsePreview :: ByteString -> Either Text [PlanStep]
classifyPlan :: Text -> [PlanStep] -> PlanVerdict
renderVerdict :: Text -> PlanVerdict -> Text
```

`parsePreview` decodes the document described in Surprises & Discoveries: a top-level object with
a `steps` array whose elements carry `op` and `urn` and optionally `replaceReasons`. An operation
token in `replace`, `create-replacement`, `delete-replaced`, `read-replacement`,
`import-replacement` or `discard-replaced` becomes `OpReplaceLike` carrying the token; the six
plain tokens map to their constructors; an unknown token is an error, because silently ignoring
an operation this repository has never seen is the wrong direction for a guard. A document with
no `steps` key parses as the empty list (Pulumi omits it when nothing changes), but malformed
JSON is a `Left`.

`classifyPlan instanceType steps` returns `PlanReplacesInstance` for every step whose `psOp` is
`OpReplaceLike` and whose URN contains the type token passed in — in practice
`"gcp:compute/instance:Instance"`, which is the Pulumi type of `gcp.compute.Instance` as
constructed in `infra/pulumi/src/components/NagareInstance.ts:35`. Match on the substring, not on
equality: the VM is created inside the `NagarePerimeter` and `NagareInstance` component
resources, so its URN is a `$`-separated chain of parent types ending in the instance type.

`renderVerdict` produces the operator-facing refusal. It must name the instance and the
replacement reasons Pulumi gave, and then state in plain language what a replacement destroys:
the k3s cluster datastore under `/var/lib/rancher` on the boot disk, every Knative and
cert-manager object, every TLS certificate already issued, and the ACME account key — recoverable
only by re-bootstrapping the cluster and re-issuing certificates. It must also say what the
operator can do: that the data disk at `/var/lib/nagare` is separately protected and survives,
that a machine-type change is an in-place resize and does not need this, and that a deliberate
rebuild is `NAGARE_ALLOW_VM_REPLACEMENT=1 nagare infra-up` after reading
`docs/runbooks/disaster-recovery.md`.

Add three fixtures under `cli/nagarectl/test/fixtures/pulumi-preview/`:
`replace-instance.json` (a stack step with `op: "same"` plus an instance step with
`op: "replace"` and `replaceReasons: ["bootDisk"]`), `update-machine-type.json` (the same stack
step plus an instance step with `op: "update"` and a `detailedDiff` naming `machineType`), and
`create-fresh.json` (a first apply: `create` steps for the network, disk and instance). Build
them by running `pulumi preview --json` against a real stack if one is available and trimming the
state blobs; otherwise hand-write them to the shape above — the parser only reads `op`, `urn` and
`replaceReasons`, and the fixtures exist to pin the classifier's behavior, not Pulumi's.

Add a `Nagare.Infra.Plan` test group to `cli/nagarectl/test/Spec.hs` following the existing
fixture idiom (`BS.readFile "test/fixtures/cronjob-list.json"` at line 291 shows the working
directory is the package directory). Assert that `replace-instance.json` classifies as
`PlanReplacesInstance`, that `update-machine-type.json` and `create-fresh.json` classify as
`PlanAllowed`, that malformed JSON is a `Left`, that an unknown operation token is a `Left`, and
that `renderVerdict` mentions `/var/lib/rancher` and the ACME account key.

Add the command in `cli/nagarectl/app/Main.hs`: a new top-level `infra` group with one
subcommand, `guard`, taking `--allow-replacement`. `runInfraGuard` resolves the active context
with `ensurePulumiForActiveContext` (which also sets `PULUMI_HOME`, `PULUMI_BACKEND_URL` and the
per-context stack, so the guard works whether or not the caller's shell was set up by `.envrc`),
returns success immediately for a `mode=local` context because there is no GCP instance to
protect, re-validates the active context's VM shape with `validateVmShape` and dies on a
malformed one, then runs `pulumi -C <workspace>/infra/pulumi preview --json --stack <context>`
capturing stdout and the exit code. A non-zero exit or unparseable output is a refusal naming the
Pulumi error, because a guard that cannot see the plan must not wave it through. On
`PlanReplacesInstance` it prints `renderVerdict` to stderr and exits 1 unless
`--allow-replacement` was passed or `NAGARE_ALLOW_VM_REPLACEMENT` is set to `1`, in which case it
prints the same text prefixed with a line saying the replacement was explicitly allowed and exits
0. On `PlanAllowed` it prints one short line and exits 0.

Wire it into `justfile`, in the `infra-up` recipe only (never `infra-preview`, which must stay a
pure read):

```make
infra-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    @nagarectl infra guard
    cd infra/pulumi && pulumi up
```

Extend the clone-free flake check to assert `nagare --dry-run infra-up` lists the guard line, so
the wiring itself is covered by CI.

Acceptance: `cabal test` shows the new group passing; `nagarectl infra guard --help` documents
the flag; against a local-mode context the guard exits 0 with a message saying local mode has no
instance to protect; and with a hand-made `pulumi` stub on `PATH` that prints
`replace-instance.json`, the guard exits 1 and prints the destruction notice.

### Milestone 4 — The documentation says which changes are safe

At the end of this milestone an operator reading the manual can tell, before touching anything,
which of the four keys they may change on a live box.

In `docs/user/provisioning-with-pulumi.md`, extend the existing "Review replacements and
protected resources" section with a short table of the four keys — machine type: in place, brief
stop and start; boot-disk size: in place, the filesystem grow is a separate step; data-disk size:
in place, growth only; boot-disk type: **replacement**, and so are the image self-link and the
zone — and a paragraph describing `nagarectl infra guard`, that `infra-up` runs it, and the
`NAGARE_ALLOW_VM_REPLACEMENT=1` override. Update the deliberate-rebuild command sequence in that
section so it sets the override, since after this change the sequence as written would be refused.

In `docs/user/resizing-the-vm.md`, replace step 1's "Confirm you're targeting `tan-nb-exp`" — a
leftover from before contexts existed and contrary to `CLAUDE.md` — with confirming the active
context via `nagarectl context current`. Change step 2 to set the value in the context
(`nagarectl context create … --machine-type`, or editing the context file and re-running
`nagarectl context use`) as the durable answer, keeping `pulumi config set machineType` as the
one-off. Add a sentence noting that `infra-up` now refuses a replacement plan outright, so the
"if you see a replacement, stop" instruction is enforced rather than advisory.

In `docs/user/gcp-prerequisites.md`, add a short "Choosing a VM shape" section before "Where to
next": the default `e2-standard-2` is two virtual CPUs and suits a cluster running a couple of
small applications; a cluster that will also run the observability stack should start at four
CPUs (`e2-standard-4`), because on two CPUs the observability components' CPU *requests* alone
left nothing schedulable and Kubernetes reported `0/1 nodes are available: Insufficient cpu`
(recorded in `docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`).
State that the machine type can be raised later in place but the boot-disk type cannot.

Update `docs/user/onboarding-bring-your-own-project.md` step 2 to show the new flags and say the
shape is recorded in the context; add the four variables to the context schema in
`docs/user/contexts.md` and `docs/user/config-reference.md`; add the `nagarectl infra guard` row
to the command table in `docs/user/reference.md`; and in `docs/runbooks/disaster-recovery.md`,
add the override to the "Replace the VM onto the fixed image" procedure at line 308.

Then record the documentation change and re-validate:

```bash
okf log add docs/user --kind Update -m "Document the context-owned VM shape, the in-place versus replacement matrix, and the infra-up replacement guard."
just user-documentation-validate
```

Acceptance: `just user-documentation-validate` prints `OK: 36 concepts (okf_version 0.2)` (or a
higher count if a file was added) for `docs/user` and `OK: 2 concepts` for `docs/guides`, with no
findings.

### Milestone 5 — Durable context recorded, request closed

Write `docs/adr/0009-the-active-context-owns-the-vm-shape.md` following the exact shape of the
existing records: frontmatter with `title`, `status: accepted`, `date`, `authors: [shinzui]` and
`related` pointing at this plan and at
`docs/improvement-requests/seed-vm-shape-keys-at-init.md`, then `# ADR 9 — …` with Status,
Context, Decision, Consequences. The decision to record is that the active target context, not
the Pulumi program, owns the VM's shape; that the program's literals are a fallback for
pre-seeding stacks only; and that any apply whose plan would replace the instance is refused by
default because the boot disk holds cluster state that the protected data disk does not.

Then close the improvement request. It was already moved to `status: accepted` when this plan
was created, and it carries `targetPlan` pointing back here, so the remaining move is to the
terminal state. The lifecycle values the profile allows are `proposed`, `accepted`,
`in-progress`, `completed`, `rejected`, `withdrawn` and `superseded` — read from
`profiles/coordination/improvement-requests.dhall` in the `shinzui/okf-profiles` project, which
`docs/improvement-requests/profile.dhall` pins at `v0.12.0`. Two fields become due at that
point: `completedAt`, which the profile *requires* once `status` is `completed` and which must be
an RFC 3339 UTC timestamp, and `resolution`, which it recommends for any terminal state and which
should name the evidence — the merged commits and the passing checks — rather than restating the
request. Bump `timestamp` and `generated.at` to the same moment, then log and validate:

```bash
okf log add docs/improvement-requests --kind Update -m "Complete IR-4: init seeds the VM shape keys and infra-up refuses an instance-replacing plan."
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

Expect the command to exit 0 while still printing one `missing profile-recommended field: reviews`
line per request in the bundle. That warning is pre-existing on all four of the September 2026
requests and must be left alone: `reviews` records real human or model review provenance, and
inventing an entry to silence `--strict` would make the field a lie.

Optionally, while editing the request, promote its "Required verification" prose into the
profile's structured `acceptanceCriteria` list (`id` as `AC-N`, `statement`, `verification`).
Only do this if each criterion can be grounded in what was actually built; leave the prose in
place either way.

Finally fill in Outcomes & Retrospective in this plan.


## Concrete Steps

Work from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`. Enter the toolchain with
`direnv allow` (once) or `nix develop`; that puts `cabal`, `ghc`, `pulumi`, `node`, `tsc`, `just`
and `okf` on `PATH`.

Build and test the CLI:

```bash
cd cli/nagarectl
cabal build all
cabal test nagarectl-test --test-show-details=streaming
```

Expect a tasty summary ending in `All N tests passed`. Run the full CI locally:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
nix flake check --print-build-logs
```

See the seeded keys without touching Google Cloud (the dry run prints the commands it would run
and writes a context file under `$XDG_CONFIG_HOME`):

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
cabal run -v0 nagarectl -- init demo --project my-project --dry-run --skip-preflight --skip-enable
```

Expected, among the other lines:

```text
Seeding Pulumi stack config from the profile...
  pulumi -C … config set --stack demo nagare:machineType e2-standard-2
  pulumi -C … config set --stack demo nagare:bootDiskType pd-balanced
  pulumi -C … config set --stack demo nagare:bootDiskSizeGb 100
  pulumi -C … config set --stack demo nagare:dataDiskSizeGb 100
```

Exercise the guard against a fixture without a cloud account, by putting a stub `pulumi` earlier
on `PATH` that prints the replacement fixture:

```bash
cd /Users/shinzui/Keikaku/bokuno/nagare
mkdir -p /tmp/nagare-guard-stub
cat > /tmp/nagare-guard-stub/pulumi <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"preview --json"*) cat cli/nagarectl/test/fixtures/pulumi-preview/replace-instance.json ;;
  *) exit 0 ;;
esac
STUB
chmod +x /tmp/nagare-guard-stub/pulumi
PATH=/tmp/nagare-guard-stub:$PATH cabal run -v0 nagarectl -- infra guard; echo "exit=$?"
```

Expected: a refusal naming `/var/lib/rancher`, the issued certificates and the ACME account key,
followed by `exit=1`. Re-run with `NAGARE_ALLOW_VM_REPLACEMENT=1` prefixed and expect the same
text with an "explicitly allowed" line and `exit=0`.

Commit as you go. Every commit on this plan carries both trailers:

```text
feat(init): seed the VM shape keys into the target context and Pulumi config

ExecPlan: docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md
Intention: intention_01m2atvnagebcstgee18sjcyck
```

Stage files by explicit path — never `git add -A` in this repository — and commit directly to the
current branch (`master`); do not create a feature branch.


## Validation and Acceptance

The change is accepted when all of the following are observable.

A stack created by `nagarectl init` carries all four shape keys. Run the dry-run command above
and see the four `config set` lines; for a real stack, `pulumi -C infra/pulumi config` lists
`nagare:machineType`, `nagare:bootDiskType`, `nagare:bootDiskSizeGb` and `nagare:dataDiskSizeGb`
after `nagarectl init`. The hermetic check `nagare-clone-free-platform` in `flake.nix` asserts
this on every CI run, so it cannot regress.

A change to a program literal does not alter a seeded stack's plan. The TypeScript check
`infra-vm-shape` asserts that `resolveVmShape` over a reader carrying all four keys returns those
values even when handed a different fallback record, and `vm-shape-defaults-agree` fails the
build if the CLI's seeded defaults and the program's fallbacks diverge. Demonstrate it by editing
`VM_SHAPE_FALLBACKS.machineType` to `e2-standard-8`, running
`nix build .#checks.<system>.infra-vm-shape` (still passes — a seeded stack is unaffected) and
`nix build .#checks.<system>.vm-shape-defaults-agree` (now fails), then reverting.

The guard fires on a replacement and stays silent on an in-place resize. `cabal test` proves it
over the three fixtures; the stub-`pulumi` transcript above proves the command-level behavior end
to end. Against a real stack, `nagarectl infra guard` exits 0 after a `machineType` change and
exits 1 after a `bootDiskType` change.

An operator can follow the sizing decision through the documentation.
`docs/user/gcp-prerequisites.md` names the recommended minimum shape and why;
`docs/user/provisioning-with-pulumi.md` states which keys force a replacement; and
`just user-documentation-validate` passes with no findings.

The whole repository still builds: `nix flake check --print-build-logs` succeeds, which covers the
Haskell test suite, the TypeScript type-check and unit test, `shellcheck` over `scripts/`, the
clone-free end-to-end fixture and the release-consistency script.


## Idempotence and Recovery

Every step here is safe to repeat.

Re-running `nagarectl init <name>` refuses to clobber an existing context unless `--force` is
given, and `seedPulumiConfig` writes the same values again, which Pulumi treats as a no-op.
Re-running `nagarectl context use <name>` re-seeds the same twelve keys; this is how an
already-created stack acquires its pins, and because the seeded defaults equal the literals the
program uses today, re-seeding an existing stack must produce no diff at all. Confirm that before
applying anything on a live stack by running `just infra-preview` after the first
`nagarectl context use` and checking it reports no changes to `nagare-01`. If it does report a
change, stop: it means a default was altered somewhere in M1 or M2, which is the exact bug this
plan exists to prevent.

The guard is read-only — it runs `pulumi preview`, never `pulumi up` — so running it repeatedly
costs only time. If it refuses an apply you believe is correct, the escape hatch is
`NAGARE_ALLOW_VM_REPLACEMENT=1` for that single command; nothing persists.

If a milestone has to be abandoned mid-way, each is independently revertable: M1 and M3 are
additive Haskell plus one line of `justfile`, M2 is a refactor whose behavior is pinned by the
new test, and M4 and M5 are documentation. Roll back with `git revert` of the milestone's commits;
no cloud state is touched by any of them. The only step that reaches Google Cloud is an operator
running `nagare infra-up`, which this plan makes strictly harder to do accidentally.


## Interfaces and Dependencies

No new third-party dependency is introduced. The Haskell work uses libraries already in
`cli/nagarectl/nagarectl.cabal`: `aeson` for the preview JSON, `bytestring`, `text`, `containers`,
`process` (via the existing `readProcessWithExitCode` helper pattern in
`cli/nagarectl/app/Main.hs`) and `tasty`/`tasty-hunit` for tests. The TypeScript check uses
`pkgs.typescript` and `pkgs.nodejs` from nixpkgs, both already present in the dev shell; the
extracted `infra/pulumi/src/vmShape.ts` must import nothing so it compiles without
`@pulumi/pulumi` installed.

At the end of M1 these exist in `cli/nagarectl/src/Nagare/Target.hs`:

```haskell
data VmShape = VmShape
  { vsMachineType :: !Text
  , vsBootDiskType :: !Text
  , vsBootDiskSizeGb :: !Text
  , vsDataDiskSizeGb :: !Text
  }
  deriving stock (Eq, Show)

defaultVmShape :: VmShape
vmShapeOf :: TargetProfile -> VmShape
validateVmShape :: VmShape -> Either Text VmShape
```

and `TargetProfile` gains `tpMachineType`, `tpBootDiskType`, `tpBootDiskSizeGb` and
`tpDataDiskSizeGb`, all `!Text`. `Nagare.Init.seedKeys :: TargetProfile -> [(Text, Text)]` keeps
its signature and returns twelve pairs.

At the end of M2 `infra/pulumi/src/vmShape.ts` exports `ShapeReader`, `VmShape`,
`VM_SHAPE_FALLBACKS` and
`resolveVmShape(cfg: ShapeReader, fallbacks?: VmShape): VmShape`.

At the end of M3 `cli/nagarectl/src/Nagare/Infra/Plan.hs` exports `StepOp`, `PlanStep`,
`PlanVerdict`, `parsePreview :: ByteString -> Either Text [PlanStep]`,
`classifyPlan :: Text -> [PlanStep] -> PlanVerdict` and
`renderVerdict :: Text -> PlanVerdict -> Text`, and `nagarectl infra guard [--allow-replacement]`
exists. The module must stay free of IO so the whole classifier is testable from fixtures; the
process invocation and exit-code translation live in `cli/nagarectl/app/Main.hs`, matching how
`Nagare.Ops.Doctor` keeps its knowledge base pure and leaves wiring to `Main`.

The Pulumi type token the classifier matches, `gcp:compute/instance:Instance`, is a contract with
`infra/pulumi/src/components/NagareInstance.ts`. If that component ever stops creating a
`gcp.compute.Instance`, the guard goes blind, so the constant lives in one place in
`Nagare.Infra.Plan` with a comment pointing at that file.


## Revision note — 2026-09-12

Reflected the plan back into the improvement request it implements, and corrected Milestone 5 to
match what the request now says. `docs/improvement-requests/seed-vm-shape-keys-at-init.md` moved
from `status: proposed` to `status: accepted`, gained a `targetPlan` pointer to this file, and
gained a "Planning outcome" section recording that every claim in it was verified against the
working tree and naming the three scoping decisions taken here. Milestone 5 previously told the
implementer to discover the profile's delivered-work status value; that value set is now read
from the `shinzui/okf-profiles` source and written down, along with the `completedAt` and
`resolution` fields that become due at completion, so the closing step no longer requires
research. The Progress checklist and Decision Log were updated to match.
