---
title: "Assert the active context's project on every cloud-mutating path"
status: accepted
date: 2026-09-12
authors: [shinzui]
related:
  - docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md
  - docs/plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md
  - docs/plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md
  - docs/adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
---

# ADR 9 — Assert the active context's project on every cloud-mutating path

## Status

Accepted, 2026-09-12. Implemented by
[ExecPlan 113](../plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md),
which closes the four paths named in
[IR-2](../improvement-requests/confine-cloud-mutations-to-context-project.md).

## Context

Nagare targets exactly one Google Cloud project at a time, named by the **active target
context** — a file of `export VAR=value` lines under
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`, selected with
`nagarectl context use`, `NAGARE_CONTEXT`, or `--context`. `CLAUDE.md` states the promise:
no script, command, or instruction may act on a project other than the active context's,
and the check must fail closed.

Until EP-113, that promise was enforced at the *entry points* — a script sourced
`scripts/lib/target.sh` and called `_require_target_project` once at the top — and was
assumed to hold for everything downstream. A pre-flight isolation audit of `v0.1.0`, run
before onboarding a new context into an organization that also holds production projects,
found four paths where the assumption fails. Two share a root cause and two are distinct:

**Globally unique names.** GCS bucket names are unique across all of Google Cloud. If a
bucket named `<project>-nagare-images` or `<project>-nagare-pulumi-state` already exists in
someone else's project and the operator can see it, then "does the bucket exist?" answers
*yes*, creation is skipped, and every later operation — `buckets update`,
`add-iam-policy-binding`, a multi-gigabyte `gsutil cp` — addresses that foreign bucket by
its global `gs://` name. The entry-point check cannot catch this, because the project the
script believes in is correct; the *object* is not ours.

**Ambient `gcloud` configuration.** `gcloud config get-value project` reports what the
operator's local `gcloud` installation is configured with, which has nothing to do with the
Nagare context. Two image-build scripts read it as a fallback and never sourced the
guardrail at all, so an operator whose `gcloud` still pointed at production submitted Cloud
Build jobs there.

**No preflight on the most consequential command.** `just infra-up` ran only
`nagarectl platform guard`, which answers the orthogonal release-compatibility question
(see [ADR 6](0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)).
The selected Pulumi stack's own `gcp:project` was the only thing standing between
`pulumi up` and the wrong project.

**No context outside a checkout.** The packaged `nagare` launcher exported only the platform
and workspace roots, because the design assumed the invoking shell already carried the
Pulumi selection. That holds for a `direnv`-loaded checkout and not for the clone-free
install that [ADR 4](0004-separate-immutable-platform-payloads-from-context-workspaces.md)
and [ADR 7](0007-publish-immutable-nix-releases-from-validated-tags.md) make the normal way
to run Nagare.

## Decision

**Project confinement is enforced at every mutation site, not only at the entry points.**
A guarded script asserts before each cloud write it performs, rather than once at the top
and then trusting its own control flow. The cost is a few extra reads on paths that already
make several; the benefit is that adding a mutation to a guarded script cannot silently
inherit a stale assertion.

**Bucket operations compare owning project numbers, and an unreadable number is a refusal.**
Because bucket names are global, existence is not evidence of ownership. The only reliable
identity is the owning project number, which a name collision cannot forge. Both
implementations read
`gcloud storage buckets describe gs://<bucket> --raw --format='value(projectNumber)'` and
`gcloud projects describe <project> --format='value(projectNumber)'` and proceed only when
both values are present, non-empty and equal. An absent value — missing tool, missing
permission, network failure — is treated as a mismatch. Fail-closed means the *absence* of
evidence is a refusal, never permission to continue.

**The assertion is implemented twice, in Bash and in Haskell, against one shared contract.**
`_require_bucket_in_target_project` in `scripts/lib/target.sh` and
`bucketOwnershipVerdict` / `runBootstrap` in
`cli/nagarectl/src/Nagare/Ops/PulumiBackend.hs` are separate implementations of the same
rule. A single implementation would mean `nagarectl` shelling out to Bash from the resolved
platform payload on every bootstrap, which adds failure modes (payload resolution, `bash` on
`PATH`, argument quoting) to a guardrail whose entire value is that it cannot fail open,
makes the Haskell path untestable without a shell, and produces messages the Haskell caller
cannot shape. What is shared is the *contract*: the same two reads, the same comparison, the
same refusal semantics, and the same message wording. **A change to either implementation
must change the other.** Both are tested against the contract —
`scripts/test-bucket-ownership-guard.sh` and the `Nagare.Ops.PulumiBackend (EP-93, EP-113)`
group in `cli/nagarectl/test/Spec.hs`, whose behavioral cases assert on the recorded `gcloud`
argv so a refusal is proven to have attempted no update and no IAM change.

**Ambient `gcloud config` is never a source of the target project.** The project comes only
from the resolved context. There is no fallback to `gcloud config get-value project` for
*deciding* the target. The one place `gcloud`'s configured project is read is inside
`_require_target_project`, as a cross-check when no context declares a project — and it is
read with `CLOUDSDK_CORE_PROJECT` stripped from the child environment, because `gcloud` lets
that variable shadow its own configuration, which would make the check compare a value
against itself. `Nagare.Ops.ContextGuard` reproduces both properties.

**`nagarectl context guard` is separate from `nagarectl platform guard`, and has no escape
hatch.** Project confinement and release compatibility are orthogonal questions with
different failure modes and different remedies; keeping them separate keeps each command's
output honest about what it checked, and the `justfile` composes both. `platform guard`
keeps its `NAGARE_UPGRADE_APPLY` escape hatch, because an in-progress platform upgrade
legitimately runs with skewed versions. `context guard` has none: there is no situation in
which writing to the wrong project is correct.

**Local mode is exempt, because it has no GCP project.** A `mode=local` context points every
primitive at loopback substitutes, so there is nothing to confine. Every guard added here
returns success in local mode *without invoking any tool*, preserving MasterPlan 16's rule
that local mode never calls `gcloud`. The compensating check is the one
`_require_target_project` already performs: it asserts that `NAGARE_BASE_DOMAIN` and
`NAGARE_REGISTRY_HOST` are provably loopback, so a misconfigured context cannot disarm the
protection while pointing at real infrastructure.

**The packaged launcher exports the active context itself.** `nagare` evaluates
`nagarectl context env`, which prints the `CLOUDSDK_*` / `NAGARE_*` contract plus the
per-context Pulumi selection as shell-quoted `export` lines. This restores parity with a
`direnv`-loaded checkout for every Pulumi-invoking recipe at once, and it is what makes
`context guard` meaningful outside a source tree: a guard is only as good as the environment
it inspects.

## Consequences

Commands that previously completed by silently using an ambient default now refuse. That is
the intended behavior, and each refusal names both compared values and the remedy. Three
behavior changes are worth stating plainly:

A GCS state-bucket bootstrap failure is now **fatal** to `nagarectl init` and
`nagarectl context create --use`, rather than a warning. A partially-applied bootstrap that
lets `init` report success is exactly the state that hides a foreign-bucket refusal from the
operator. The blast radius is small: the bootstrap is a no-op for every context whose Pulumi
backend is `local`, which is the default.

An auth-plane image build with a conflicting `CLOUDSDK_CORE_PROJECT`, or with no context
declaring a project, now fails instead of building into whatever `gcloud config` names.

`just infra-up` and `just infra-preview` refuse before Pulumi is invoked when the stack's
`gcp:project`, the ambient `CLOUDSDK_CORE_PROJECT`, or `gcloud`'s configured project
disagrees with the context.

A refusal is a non-event: every guard reads two values and either returns or stops, mutating
nothing, so a refused command leaves the system exactly as it was and is safe to re-run once
the cause is fixed. No ownership answer is cached — a cached answer is precisely the stale
assumption this decision removes.

The per-field precedence of the context contract is unchanged: environment beats context
file. `nagarectl context env` therefore echoes an ambient override rather than overriding it,
and `context guard` is what refuses when such an override disagrees with the context. The two
are complementary, and neither is a substitute for the other.

## Amendment — 2026-09-12

gcloud 570 omits `projectNumber` from the formatted `gcloud storage buckets describe` resource, so
the assertion read an empty value and refused every bucket, including one just created in the
target project. Both implementations now pass `--raw` to read the API field
([ExecPlan 116](../plans/116-move-operator-private-deployment-material-into-a-private-development-repository.md)).
The comparison is unchanged and still refuses a foreign bucket.

## Amendment — 2026-09-14

[ExecPlan 128](../plans/128-isolate-init-from-the-active-context-ship-pulumi-with-the-operator-package-and-release-nagare-0-2-2.md)
extends the fail-closed project boundary to named context creation. `nagarectl init NAME` never
consults the active context, the global `--context` selection, or ambient target variables. A fresh
context is derived only from explicit flags and built-in defaults; `init NAME --force` may additionally
reuse `NAME`'s own stored fields.

Before any workspace, context, or cloud mutation, named init prints its derived resource names and
refuses image or backup bucket names that do not start with the selected project. It applies the same
rule to an effective GCS Pulumi backend inherited from the named context; an explicitly supplied
backend URL remains a deliberate operator choice. This prevents a context from being born with
another project's resource names, complementing the mutation-time ownership checks recorded above.
The rule shipped in signed release `v0.2.2`.

## Amendment — 2026-09-14: unknown stack projects retain their cause

[ExecPlan 129](../plans/129-make-context-guard-diagnose-pulumi-project-probe-failures.md)
clarifies the fail-closed context-guard contract: an unknown stack project is a typed observation,
not an absent value. A missing Pulumi executable, a start failure, a non-zero command with captured
stderr, invalid successful output, and a valid config object without `gcp:project` are distinct
outcomes. Every one refuses; only the last recommends regenerating the context-owned projection.

The guard reads the complete successful config as JSON because Pulumi's single-key command uses a
non-zero exit for both absent configuration and backend/process failures. It never infers absence
from human stderr text. Human and JSON diagnostics identify the exact selected stack and resolved
backend URL they protected. JSON failures are one independently parseable object, retain the
nullable `stackProject` compatibility member, and add a typed `stackProjectProbe` object.
