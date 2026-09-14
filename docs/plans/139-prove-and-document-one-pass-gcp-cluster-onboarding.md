---
id: 139
slug: prove-and-document-one-pass-gcp-cluster-onboarding
title: "Prove and document one-pass GCP cluster onboarding"
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
      at: 2026-09-14T19:02:03Z
      mode: "implement"
      note: "Started EP-6 after all child and external dependencies completed"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T19:20:17Z
      mode: "implement"
      note: "Completed hermetic, documentation, IR-11, and repository gates; retained live authorization boundary"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T19:28:34Z
      mode: "implement"
      note: "Audited live evidence, release identity, TLS readiness, cleanup, and installed-workspace documentation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T23:19:22Z
      mode: "implement"
      note: "Made v0.3.0 CLI output deterministic under the Linux release locale"
---

# Prove and document one-pass GCP cluster onboarding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Nagare has one accurate, executable path from an installed release and empty GCP project to a Ready,
accessible, TLS-configured first cluster. A hermetic rehearsal checks command ordering, guards, and
failure behavior without cloud access; an explicitly authorized disposable-project rehearsal proves
the real path and records cleanup. User documentation no longer claims boot-disk size changes happen
in place. This integration plan implements IR-11 and accepts the composed outcome of child
ExecPlans 134–138 plus independent ExecPlans 132 and 133.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T19:15:20Z) Define one canonical bootstrap state machine and a hermetic rehearsal
  harness with focused refusal cases and a native flake check.
- [x] (2026-09-14T19:15:20Z) Consolidate onboarding/help, including truthful boot-disk replacement
  guidance and immutable reviewed-release placeholders.
- [ ] Run an explicitly authorized empty-project GCP rehearsal and verify cleanup/evidence.
- [x] (2026-09-14T19:20:00Z) Close IR-11, reconcile all cross-plan docs/ADRs, and run the final
  repository gate.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The latest published Nagare tag is `v0.2.2`, but it predates the completed bootstrap interfaces
  this plan composes. Hard-coding it would make the new runbook internally inconsistent, so the
  guide uses a reviewed immutable release placeholder and live mode verifies the installed version.

- Even `nagarectl init --dry-run` checks the external operator toolchain before rendering its public
  command sequence. The hermetic check therefore supplies a recording `npm` alongside cloud and
  cluster fakes; this is part of testing the packaged interface rather than bypassing it.

- Nix flake source filtering omits a new untracked rehearsal script. Staging that file before the
  first packaged build made the source closure accurate; subsequent packaged and root checks pass.

- The Linux release builder has an ASCII default text encoding, while several public CLI
  diagnostics intentionally contain Unicode punctuation. The v0.3.0 candidate passed all 552
  Haskell tests and reached the final GCP rehearsal before `nagarectl init --dry-run` failed while
  encoding its em dash. Explicit UTF-8 stdout/stderr encodings make the packaged interface stable
  independently of the caller's locale.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make the bring-your-own-project guide the canonical end-to-end narrative; focused guides
  link to its stages instead of maintaining competing full sequences.
  Rationale: The current contradiction arose because installation, provisioning, secrets, access,
  bootstrap, TLS, and upgrades each encode part of the order independently.
  Date: 2026-09-14.

- Decision: Separate hermetic acceptance from an opt-in live GCP rehearsal.
  Rationale: Guards and orchestration should be deterministic in CI, while proving real provider,
  IAP, boot, DNS, and certificate behavior costs money and mutates external infrastructure.
  Date: 2026-09-14.

- Decision: Require a purpose-created disposable project and explicit environment acknowledgement
  for live rehearsal; never infer a project from gcloud defaults.
  Rationale: End-to-end proof must preserve the same project-confinement safety it is validating.
  Date: 2026-09-14.

- Decision: Keep boot-disk resizing out of scope and state that changing `bootDiskSizeGb` replaces
  the instance.
  Rationale: That is the behavior observed by Nagare's protected replacement preview and requested
  by IR-11. The safe initial path is to size the boot disk for the VM lifetime.
  Date: 2026-09-14.

- Decision: Keep the plan In Progress after hermetic and repository acceptance pass.
  Rationale: The plan explicitly requires a billable disposable-project run from an installed
  release. No project, delegated domain, protected-project list, secret inputs, acknowledgement, or
  interactive authorization was supplied, and hermetic evidence cannot substitute for that run.
  Date: 2026-09-14.

- Decision: Set UTF-8 explicitly on both public Haskell executables' stdout and stderr handles.
  Rationale: Nagare owns Unicode diagnostics and JSON text, so their encodability must not depend on
  whether a pure builder or minimal operator environment happens to export a UTF-8 locale.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Hermetic and documentation outcomes are complete. `scripts/rehearse-gcp-bootstrap.sh --hermetic`
drives the packaged public command surfaces and an explicit fake state machine from empty state. It
passes the happy path with exactly two reviewed applies and one bootstrap invocation, and proves
refusals for foreign project/ADC identity, stale plan, foreign builder, non-Ready VM, missing age
key, wrong kubeconfig node, absent webhooks, and leaked certificate scope. The native
`gcp-bootstrap-rehearsal` and `shellcheck-scripts` checks pass.

The v0.3.0 release audit made that hermetic evidence portable across native systems: both Haskell
executables now select UTF-8 output before option parsing, including help and dry-run diagnostics.

The canonical onboarding guide now identifies release, project, context/stack, builder, and cluster
targets; its boot-disk guidance agrees with packaged help and focused references. IR-11 is completed.
All 527 Haskell tests, strict user/improvement-request OKF validation, NixOS all-system evaluation,
and all 29 buildable native root-flake checks pass.

The authorized live rehearsal remains outstanding. Live mode is implemented, requires a clean
installed release and empty stack, validates gcloud plus ADC confinement, prints its inventory,
records release revision and saved-plan digests, invokes bootstrap once, requires a Ready staging
certificate, and separately confirms guarded teardown without deleting the project. Until an
operator supplies its explicit inputs and runs it, this plan is not complete.


## Context and Orientation

`docs/user/onboarding-bring-your-own-project.md` is intended to take an operator from a fresh GCP
project to a running Nagare cluster. Today it includes release-specific examples, two unconstrained
`infra-up` runs, an impossible pre-first-boot private-key placement, hidden builder and kubeconfig
assumptions, and a bootstrap command known to need a retry. Focused details live in
`docs/user/installation.md`, `gcp-prerequisites.md`, `contexts.md`,
`provisioning-with-pulumi.md`, `host-image-and-boot.md`, `secrets.md`,
`accessing-the-host.md`, `cluster-bootstrap.md`, `reference.md`, and `upgrades.md`.

[IR-11](../improvement-requests/boot-disk-size-docs-say-in-place.md) records a particularly unsafe
claim in `provisioning-with-pulumi.md` and `reference.md`: increasing `bootDiskSizeGb` is described
as in-place, but Pulumi previews a GCE instance replacement. `nagarectl init` help warns about boot
disk type but not size. The existing replacement guard blocks accidental execution, yet initial
sizing advice is still wrong.

The required upstream plan behaviors are:

- [ExecPlan 134](134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md): clean
  install, kubeconfig fetch, and cluster guard.
- [ExecPlan 135](135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md): ADC preflight and
  undeployed re-pin.
- [ExecPlan 136](136-apply-reviewed-infrastructure-and-confine-remote-builders.md): saved Pulumi plan
  apply and context builder.
- [ExecPlan 137](137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md): first-boot storage/k3s.
- [ExecPlan 138](138-keep-bootstrap-tls-issuance-within-intended-names.md): safe TLS issuer/selector.
- Independent [ExecPlan 132](132-make-cluster-bootstrap-wait-for-knative-webhooks.md): first-run
  Knative readiness.
- Independent [ExecPlan 133](133-deliver-the-host-age-key-after-first-boot.md): post-boot age-key
  handoff and Tailscale recovery.

The canonical live sequence is: install release; authenticate gcloud and ADC with the disposable
project as quota project; initialize context; inspect/re-pin if needed; generate host configuration
and encrypted secrets; save/review/apply perimeter infrastructure; configure the context builder and
upload the host image; save/review/apply VM infrastructure; wait for first-boot k3s; deliver the age
key over IAP; fetch the context kubeconfig; pass cluster guard; run cluster bootstrap once; enable
TLS only after DNS/ACME prerequisites; run status/doctor; and cleanly destroy the disposable stack.

ADRs 4 through 12, 14, and 18 cited by the upstream plans govern this integrated sequence. This
plan should not restate them. It must verify the final documentation agrees with any amendments
made by those plans. No new ADR is required for the rehearsal script itself.


## Plan of Work

### Milestone 1: make the complete flow executable without cloud access

Create `scripts/rehearse-gcp-bootstrap.sh` with `--hermetic` and `--live` modes. Hermetic mode builds
an isolated HOME/XDG tree and PATH of recording fake `gcloud`, `pulumi`, `nix`, `ssh`/IAP,
`kubectl`, and DNS/certificate observations. It drives the same public `nagare`/`nagarectl` commands
as the guide; do not duplicate implementation logic inside the harness. Each fake advances an
explicit state file only when required prior steps and exact context/project arguments are present.

Prove success from empty state and focused refusals: foreign ADC quota project, stale/different
Pulumi plan, foreign builder without acknowledgement, VM not Ready, missing age key, wrong
kubeconfig node, absent webhook readiness, and leaked TLS certificate name. Assert the successful
trace has two reviewed applies, one cluster-bootstrap invocation, all guards before mutations, and
no retry disguised as success. Register the script in `nix/checks/scripts.nix` and shellcheck.

### Milestone 2: make the documentation match the trace and close IR-11 behavior

Rewrite `docs/user/onboarding-bring-your-own-project.md` around the canonical stages and actual
public interfaces from all prerequisite plans. Use placeholders for current release/context/project,
not stale hard-coded versions or host names. Each destructive or billable step states what project,
builder, stack, and cluster will be affected and what successful output looks like. Link focused
guides for explanation without requiring the reader to discover missing steps elsewhere.

Correct `docs/user/provisioning-with-pulumi.md` and `docs/user/reference.md`: boot-disk size changes
replace the VM and its boot-resident k3s state, shrinking is unsupported, and the replacement guard
must be reviewed. Update `docs/user/gcp-prerequisites.md` to recommend sizing the boot disk for the
VM lifetime. Change the `--boot-disk-size-gb` help in `cli/nagarectl/app/Main.hs` to say changing a
live value replaces the instance. Add a documentation/help regression check that scans rendered
tables and CLI help and fails on “in-place” claims associated with boot disk size while allowing the
separate data-disk growth language.

### Milestone 3: prove one authorized real GCP bootstrap

Live mode must require all of `NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROJECT`,
`NAGARE_GCP_BOOTSTRAP_REHEARSAL_CONTEXT`, an explicitly delegated disposable base domain or staging
DNS fixture, and `NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACK=I-understand-this-creates-billable-resources`.
It verifies the project differs from every protected/default project listed by the operator, the
active gcloud and ADC quota projects match, and the Pulumi stack is empty before proceeding. It must
print the complete target inventory and require an interactive confirmation; do not make CI
credentials or a production domain a default.

Run the canonical sequence from an isolated XDG root and released package. Record timestamps,
release revision, project/context/stack, reviewed plan hashes, builder target, first boot ID, node
Ready evidence, age-key readiness without secret content, kubeconfig identity, first bootstrap exit
status, webhook rollouts, and certificate inventory. Cluster bootstrap must be invoked exactly once.
Run status and doctor. Cleanup uses the separately documented guarded teardown, verifies the stack
and context-owned temporary resources are gone, and never deletes the project itself. If cleanup
fails, print exact remaining resource identities and preserve evidence for manual recovery.

### Milestone 4: reconcile and close the initiative evidence

Update `CHANGELOG.md`, complete IR-11 only after the help/docs check passes, and append its bundle
log entry. Review the ten target IRs and two external IRs for correct state/plan links; do not mark
requests complete on behalf of unfinished upstream plans. Review all cited ADR amendments for
consistency. Update this plan and the MasterPlan's living sections with evidence, run strict OKF
validation and repository gates, and record any unavailable live acceptance as incomplete rather
than substituting hermetic evidence.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`. After every prerequisite plan is complete:

```bash
bash scripts/rehearse-gcp-bootstrap.sh --hermetic
nix build .#checks.aarch64-darwin.gcp-bootstrap-rehearsal --print-build-logs
cabal test nagarectl-test
```

Expected summary:

```text
ok: two reviewed Pulumi plans applied in context project
ok: context builder and kubeconfig identities match
ok: first host boot reached Ready and cluster-bootstrap ran once
ok: public certificate policy contains only labeled app namespaces
gcp bootstrap rehearsal: PASS
```

The live command is intentionally not copy-pasteable until the operator supplies a disposable
project, context, domain, protected-project list, and acknowledgement:

```bash
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROJECT=DISPOSABLE_PROJECT_ID
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_CONTEXT=DISPOSABLE_CONTEXT
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_BASE_DOMAIN=DELEGATED_STAGING_DOMAIN
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_PROTECTED_PROJECTS=PROD_PROJECT_ID,OTHER_PROTECTED_PROJECT_ID
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_RELEASE=CURRENT_REVIEWED_RELEASE_TAG
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACME_EMAIL=OPERATOR_EMAIL
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_SSH_PUBLIC_KEY_FILE=/secure/path/operator.pub
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_SOPS_FILE=/secure/path/host-secrets.yaml
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_AGE_KEY_FILE=/secure/path/host.agekey
export NAGARE_GCP_BOOTSTRAP_REHEARSAL_ACK=I-understand-this-creates-billable-resources
scripts/rehearse-gcp-bootstrap.sh --live
```

After cleanup, run:

```bash
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
nix flake check ./nixos --no-build --all-systems
nix flake check --print-build-logs
```


## Validation and Acceptance

Hermetic acceptance requires a trace from empty state that uses the public commands in canonical
order, applies exactly the two saved plans it reviewed, selects only the context builder, reaches a
Ready first-boot node, delivers the age key, fetches and guards the correct kubeconfig, invokes
cluster bootstrap once, and passes TLS policy. Each injected mismatch must stop before the relevant
mutation and name a recovery action.

Documentation acceptance requires every command in the canonical guide to exist in the packaged
release, focused guides to agree with its order, and rendered help/tables to contain no claim that
boot-disk size changes are in-place. The text must distinguish boot disk replacement from
forward-only online data-disk growth.

Final initiative acceptance requires one authorized disposable-project run with real evidence for
project/ADC confinement, saved-plan hashes, builder project, first boot, Ready node, age-key status,
context kubeconfig, one-shot bootstrap, ready webhooks, and certificate inventory. Doctor exits zero
before teardown. Teardown leaves no Pulumi-managed resources. Without that run, the plan remains in
progress even if hermetic CI passes.


## Idempotence and Recovery

Hermetic mode owns only a freshly created temporary directory and is safe to repeat. Live mode must
create a unique evidence directory and refuse to reuse a nonempty Pulumi stack or previous context.
Most individual bootstrap commands are convergent, but the acceptance run records the first
invocation and must not erase a failure by rerunning it. Diagnose and retain evidence; start a new
disposable rehearsal after the owning plan is fixed.

Cloud creation is billable and teardown is destructive. The harness never chooses targets from
ambient defaults, never deletes the project, and never runs teardown until it has displayed the
exact stack/project inventory and obtained confirmation. If interrupted, resume only the guarded
saved-plan/upgrade operations that explicitly support it; otherwise use the recorded context and
stack with the documented guarded teardown.


## Interfaces and Dependencies

`scripts/rehearse-gcp-bootstrap.sh` is a test/orchestration interface:

```text
scripts/rehearse-gcp-bootstrap.sh --hermetic
scripts/rehearse-gcp-bootstrap.sh --live
```

Hermetic mode depends on Bash, the packaged Nagare commands, and generated fake executables. Live
mode additionally depends on the installed operator toolchain, gcloud/ADC, Pulumi, GCP/IAP, Nix
remote builder, k3s/kubectl, DNS, cert-manager, Knative, and an explicitly delegated domain. It must
consume, not reimplement, interfaces from ExecPlans 132–138. All five MasterPlan children are hard
dependencies; ExecPlans 132 and 133 are external completion prerequisites.


Revision note (2026-09-14): Hardened v0.3.0's hermetic GCP rehearsal after Linux CI demonstrated
that public Unicode diagnostics must not inherit a pure builder's ASCII encoding.
