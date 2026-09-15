---
id: 140
slug: make-clone-free-platform-upgrades-carry-release-pinned-operator-tools
title: "Make clone-free platform upgrades carry release-pinned operator tools"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp34dpemna40herdgrt346"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T14:28:54Z
      mode: "implement"
      note: "Implemented the documented target-release operator invocation and release rehearsal regression"
---

# Make clone-free platform upgrades carry release-pinned operator tools

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An operator following the release-upgrade guide can invoke the immutable target release from a
machine that has Nix but no ambient Pulumi installation and reach the reviewed infrastructure
preview. The same target-release invocation works for planning, status, apply, resume, and rollback,
so a recovery does not accidentally fall back to an older installed CLI or an incomplete developer
package. The defect and its reproduction are recorded in
[BUG-1](../bug-reports/upgrade-command-omits-operator-tools.md).

After this change, copying the command from `docs/user/upgrades.md` into an isolated environment
shows `pulumi` and `pulumi-language-nodejs` from the selected release and produces a planned upgrade
transaction instead of `pulumi was not found on PATH`. The native release rehearsal executes that
exact command shape and fails publication if the operator tool closure is absent.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-15 14:28Z) Milestone 1: defined `nix shell ...#nagare -c nagarectl` as the
  target-release operator invocation throughout the upgrade, multi-cluster, installation,
  reference, current release, release-maintainer, and changelog documentation.
- [ ] Milestone 2: make the clone-free release rehearsal execute the documented upgrade command
  with no ambient Pulumi and verify that planning reaches the reviewed preview.
- [ ] Milestone 3: update release/package documentation, distill any durable packaging decision,
  and pass the focused and full release gates.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Standardize on `nix shell "${TARGET_NAGARE}#nagare" -c nagarectl ...` for operations
  that must run the target release's CLI with its complete operator toolchain; do not add another
  public flake output merely to preserve the shorter `nix run` spelling.
  Rationale: `#nagare` already contains the operator-wrapped `nagarectl`, Pulumi, the Pulumi Node.js
  language host, `socat`, and the immutable payload. The smaller `#nagarectl` output is deliberately
  an application-developer interface under ADR 7. Reusing the existing operator package fixes the
  command without duplicating package ownership or weakening that boundary.
  Date: 2026-09-15.

- Decision: Test the literal documented invocation in the native clone-free release rehearsal, not
  only the underlying package or `nagarectl version --tools` output.
  Rationale: BUG-1 is an integration failure between documentation, flake selection, and runtime
  PATH construction. Package-level assertions passed while the copied command failed, so acceptance
  must cross the same public boundary an operator uses.
  Date: 2026-09-15.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Nagare publishes two intentionally different Nix packages. `nix/haskell-packages.nix` defines the
small `nagarectl` package by wrapping the Haskell executable with the typed configuration runtime and
DNS tools. It separately defines `operatorNagarectl`, which appends the release-pinned Pulumi CLI,
the Pulumi Node.js language host, and other operator tools. The public `nagare` package contains that
operator wrapper plus the `nagare` recipe launcher. `nix/packages.nix` exports both `#nagarectl` and
`#nagare`; `nix/apps.nix` makes `nix run ...#nagarectl` execute the small package and `nix run
...#nagare` execute the recipe launcher. Consequently, `nix run ...#nagarectl -- platform upgrade`
does not have Pulumi on PATH by design.

`docs/user/upgrades.md` currently tells operators to use the broken `nix run
"${TARGET_NAGARE}#nagarectl" -- ...` spelling for plan, status, apply, resume, and rollback. A Nix
shell selected from `#nagare` exposes the operator-wrapped `nagarectl` directly, so `nix shell
"${TARGET_NAGARE}#nagare" -c nagarectl ...` preserves clone-free and release-pinned behavior without
invoking the recipe launcher. Search `docs/releases/`, `docs/guides/`, `README.md`, and
`docs/user/` for other platform-operation examples that incorrectly select the developer output;
ordinary application deployment examples may continue to use `#nagarectl`.

`scripts/rehearse-clone-free-release.sh` is the release workflow's native-system proof. It clears
the ambient `NAGARE_*`, `CLOUDSDK_*`, and `PULUMI_*` variables, creates isolated HOME/XDG roots, and
currently checks both the small CLI and the operator package, but it does not run the documented
platform-upgrade command through the operator package. `nix/checks/platform.nix` and
`nix/checks/scripts/nagare-clone-free-platform.sh` provide a cheaper hermetic fixture with recording
fake cloud tools; reuse their established context and saved-plan patterns where practical, while
keeping the native release rehearsal as the acceptance boundary. `scripts/check-release.sh` checks
the published outputs and release manifest.

[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) makes immutable Git tags
the release identity and explicitly reserves `#nagare` for the complete operator toolchain while
keeping `#nagarectl` small. Preserve and, if needed, amend that distinction rather than moving
Pulumi into the developer package. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
requires upgrade Pulumi phases to use the retained reviewed plan and all context/project guards;
the new invocation must reach those existing paths unchanged. No cross-repository ADR governs this
fix. The originating live evidence is the canonical external artifact
`mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.


## Plan of Work

Milestone 1 establishes the public command contract. Replace the platform-upgrade examples in
`docs/user/upgrades.md` with a small shell helper or repeated explicit spelling based on `nix shell
"${TARGET_NAGARE}#nagare" -c nagarectl`. The rendered commands must be directly copyable for plan,
status, apply/resume, completed-status inspection, and rollback. Explain why `#nagare` is required
for infrastructure operations and why `#nagarectl` remains correct for app-developer commands.
Update affected release notes and cross-references whose current wording sends an operator back to
the incomplete output. This milestone is accepted when a documentation search finds no upgrade
operation selecting `#nagarectl`, while unrelated app examples remain intact.

Milestone 2 turns the report into an executable release regression. Extend
`scripts/rehearse-clone-free-release.sh` so its isolated environment contains no ambient Pulumi,
selects the candidate release's `#nagare` package, invokes `nagarectl platform upgrade` using the
same command form as the guide, and observes a successful saved preview/transaction plan. Before
adding any test doubles to PATH, assert the isolated environment cannot resolve Pulumi; then enter
`#nagare` and assert `nagarectl version --tools` resolves both Pulumi executables from the release
closure. For the mutation-free preview itself, add recording Pulumi, gcloud, Nix, and Kubernetes
doubles following `nix/checks/platform.nix`, prepend them intentionally, and rely on the operator
wrapper's documented suffix behavior so the doubles win. Do not contact or mutate a real project.
Assert the trace reaches `pulumi preview --save-plan` and no host, Kubernetes, context, or cloud
apply phase runs. Add or adjust a cheaper check in `nix/checks/scripts/nagare-clone-free-platform.sh`
if it materially shortens local diagnosis, but keep the native release rehearsal authoritative.

Milestone 3 synchronizes release claims and durable context. Update `[Unreleased]` in
`CHANGELOG.md` and any package/output inventory in `docs/user/installation.md`,
`docs/user/reference.md`, or `docs/runbooks/releases.md` that describes upgrade tooling. Amend
`docs/adr/0007-publish-immutable-nix-releases-from-validated-tags.md` only if implementation changes
the durable invocation contract beyond its existing operator/developer split. Record the result in
this plan's Outcomes & Retrospective and run the focused release checks plus the full native flake
check. This milestone is accepted when the isolated copied command plans successfully and release
validation still proves both public packages expose only their intended files.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/nagare`. Begin by confirming the report still
matches the tree and by finding every affected example:

```bash
git status --short
rg -n '#nagarectl.*platform (upgrade|status|repin|adopt)' docs README.md scripts
sed -n '70,170p' docs/user/upgrades.md
sed -n '40,140p' nix/haskell-packages.nix
sed -n '1,80p' nix/apps.nix
```

After editing the documentation and rehearsal, run the cheap checks first:

```bash
bash -n scripts/rehearse-clone-free-release.sh
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nagare-operator-tools
nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).nagare-clone-free-platform
```

Rehearse the candidate from the working tree without cloud mutation:

```bash
./scripts/rehearse-clone-free-release.sh \
  --version "$(jq -r '.platformVersion' release.json)" \
  --flake-ref "path:$PWD"
```

The final trace must contain the equivalent of:

```text
pulumi version: v3.255.0
pulumi preview --json --save-plan ...
upgrade state: planned
```

Then run repository validation:

```bash
just user-documentation-validate
./scripts/test-release.sh
nix flake check --print-build-logs
```

When committing implementation, use a Conventional Commit message and include:

```text
ExecPlan: docs/plans/140-make-clone-free-platform-upgrades-carry-release-pinned-operator-tools.md
```


## Validation and Acceptance

Acceptance requires an isolated HOME/XDG environment whose original PATH has Nix but no `pulumi` or
`pulumi-language-nodejs`. Before inserting recording doubles, `nagarectl version --tools` inside the
target release's `#nagare` shell must report both tools from that release closure. With the explicit
recording doubles then prepended for safety, running the exact target-release command copied from
`docs/user/upgrades.md` must complete Nix evaluation, write a context-bound Pulumi review bundle,
and return a transaction whose three planning phases are `succeeded`. Its tool log must contain one
guarded Pulumi preview and zero `pulumi up`, host switch, Kubernetes apply, cluster stamp, or context
commit calls.

The corresponding command with `#nagarectl` should remain outside the supported operator path; do
not make acceptance depend on ambient tools leaking into it. Documentation validation, release
source consistency, `nagare-operator-tools`, `nagare-clone-free-platform`, and the native release
rehearsal must pass. The final `nix flake check --print-build-logs` may skip foreign-system outputs,
but every check buildable on the current system must succeed.


## Idempotence and Recovery

Documentation and test changes are additive and repeatable. The rehearsal must use fresh temporary
HOME/XDG directories and recording tools, so rerunning it neither reuses a prior transaction nor
touches a real cloud stack. If the rehearsal fails after creating temporary state, its existing trap
must remove that state; preserve evidence long enough to print the failing command and tool log.
Do not publish a tag or release while implementing this plan. A failed candidate remains a normal
working-tree change and can be retried after correcting the package selection.


## Interfaces and Dependencies

No new Haskell API is required. The public interface is the command template:

```bash
nix shell "${TARGET_NAGARE}#nagare" -c nagarectl <platform-command> <arguments>
```

`nix/haskell-packages.nix` must continue to expose `nagarePackages.nagare` containing
`operatorNagarectl`, and `nagarePackages.nagarectl` must remain the smaller developer package.
`scripts/rehearse-clone-free-release.sh` consumes Nix, the selected flake reference, and its own
isolated test doubles; it must not add an unpinned download or a dependency on a source checkout at
runtime. If a helper function is added to the script, give it one responsibility: invoke
`nagarectl` inside `${flake_ref}#nagare` while forwarding arguments without shell re-parsing.


Revision note (2026-09-15): Implementation began by standardizing the target-release operator
invocation across current user, release, and multi-cluster documentation. Historical bug-report
reproduction and application-developer `#nagarectl` examples remain unchanged because they describe
the failure and the intentionally smaller package respectively.
