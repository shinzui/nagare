---
id: 225
slug: keep-platform-revisions-stable-when-deployment-meaning-is-unchanged
title: "Keep platform revisions stable when deployment meaning is unchanged"
kind: exec-plan
created_at: 2026-10-29T14:39:33Z
intention: "intention_01m641jy1vem4rk38mpvk6ksp8"
master_plan: "docs/masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:39:33Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-29T16:44:53Z
      verdict: "approved"
      note: "Canonical-bytes comparison, bootstrapReview verify expansion and sameDeclarationsModuloSource usage verified at HEAD; ADR 22 amendment present"
---

# Keep platform revisions stable when deployment meaning is unchanged

This ExecPlan is a living document. Keep milestone evidence and discoveries current; its parent
coordinates integration and does not replace the implementation contract below.


## Purpose / Big Picture


Changing release identity or the path from which a manifest was loaded must not re-accept every
platform scope or schedule hundreds of unchanged resources as operations. A review must explain
which deployment inputs changed, retain the existing revision for equivalent scopes, and still
detect live drift before publishing the platform stamp. One member change should select that
member and its actual dependencies, not all installed applications.

This repairs semantic invalidation: “semantic” means a difference capable of changing desired
deployment behavior or safety policy. Source filenames are diagnostic provenance; an image digest,
dependency, permission, ownership rule or retention policy is deployment meaning. Semantic
equality does not prove that the live cluster is healthy.


## Progress


- [x] M1: Typed scope-equivalence and revision-preservation fixtures prove source-only changes
  retain accepted bytes, while every deployment-significant change remains visible.
  Pass, 2026-10-29: `Nagare.Resource.DeploymentMeaning` (version 1) normalizes only diagnostic
  sources. `cabal test --project-dir=cli/nagare-dsl --test-options='-p "deployment meaning"'`
  passes four cases (moved workspace equal; content, a field named `source`, address, alias,
  retention, data policy, sensitivity, dependency, operation, config digest and override each
  differ; significant sources stay significant). `-p PlatformIncremental` passes the retained
  revision and vector digest and the changed-scope revision. Platform candidate filtering and
  `bootstrapPreservedScopeVectorDigest` use it; `Bootstrap/Local.hs` and the transition table use
  the typed `sameDeclarationsModuloSources`, replacing the JSON-key deletion.
- [ ] M2: Planning separates fresh validation requirements from effects; a release-only change
  has no per-member verify operations and still refuses drift, missing ownership and stale health.
- [ ] M3: Previous-release review compatibility and the transition producer/consumer fixture
  pass, including one changed member, preserved scope vectors and final stamp dependencies.


## Surprises & Discoveries


2026-10-29 source review: `Bootstrap/Platform.hs` selects replacements by full canonical scope
bytes. `bootstrapPreservedScopeVectorDigest` uses the same comparison. `Platform/Transition.hs`
has `sameDeclarationsModuloSource`, but production use is limited to `Bootstrap/Local.hs`.
`Inventory/Plan/Changes.hs` also sets `bootstrapReview` for an unsettled generated marker, causing
unchanged Kubernetes and Helm members to become `VerifyResource`. Fixing source paths alone
cannot remove this global verification work.


## Decision Log


- 2026-10-29: Retain the existing accepted document and revision when typed deployment meaning is
  equal. Do not silently redefine the hash of persisted scope bytes or rewrite accepted history.
- 2026-10-29: Separate release provenance and fresh platform validation from resource operations.
  The stamp remains gated by proof, but proof of an unchanged resource is not a mutation intent.
- 2026-10-29: Use an explicit typed projection, never recursive deletion of JSON keys called
  `source`, `version` or `path`; those names can occur in actual workload configuration.
- 2026-10-29: A source location stays significant when code reads it as data: `generated:` and
  `packaged:` records, `contribution`, and the artifact input markers `oci-archive-v1`,
  `kubeconfig-prepared-v1` and `local-substrate-v1` (an artifact executor opens that file). An
  artifact scope whose input moved is therefore still re-accepted. The local substrate keeps
  re-accepting on any source-only difference so its new input path replaces the old one.


## Outcomes & Retrospective


Planning only; no revision behavior has changed.


## Context and Orientation


`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` defines scopes, resource bundles and composition.
`cli/nagare-dsl/src/Nagare/Resource/Wire.hs` canonically encodes them. The content digest identifies
stored bytes; a scope revision combines digest with a generation representing accepted history.
`cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs` computes the scope vector (the map of scope IDs
to revisions), hashes it and embeds that binding in the cluster's bootstrap stamp.

`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` compiles Kubernetes and Helm inputs, filters
scope replacements and adds the stamp. `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs`
classifies desired members, including `sameManaged`, `bootstrapReview` and `markerSettled`.
`cli/nagarectl/src/Nagare/Inventory/Plan.hs` and its submodules own review construction and
validation. `cli/nagarectl/src/Nagare/Platform/Transition.hs` checks source/target compatibility.
`cli/nagarectl/app/Nagare/Cli/Inventory/Planning.hs` prepares the actual adapters and native bytes.
The impact closure is the changed members plus the dependencies and proofs needed for them.

[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) says digests
identify content and revisions identify history; omission never authorizes deletion. Its new
architecture amendment distinguishes provenance from deployment meaning.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) keeps
the release pin last. [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md)
and [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
require per-resource proof and exact incarnation identity, even for unchanged members.


## Plan of Work


### M1 — Preserve semantic identity without rewriting history


Add `cli/nagare-dsl/src/Nagare/Resource/DeploymentMeaning.hs` with a typed projection of scope
declarations and a versioned comparison function. Normalize only schema-defined diagnostic
source locations and unordered collections whose ordering is already semantically irrelevant.
Include every resource identity, address, executor, desired spec/native content digest, dependency,
claim, contribution, capability, data policy, lifecycle policy and declared operation. Fields
not explicitly classified remain significant. Do not drop release versions from workloads:
a version in a pod environment, chart value or image reference can change behavior.

Use it in platform candidate filtering and scope-vector construction. Equivalent new declarations
reuse the exact accepted scope object, generation and digest; collect new release provenance in
the review's diagnostic metadata. When retained declarations refer to old source locations,
resolve their native inputs from retained content digests or the candidate's supplied bytes after
digest verification, never by requiring the old workspace to exist. Keep canonical content hashes
unchanged. Correct the local-substrate helper to use the same typed comparison where appropriate.

Create `cli/nagarectl/test/PlatformIncrementalSpec.hs`, and DSL tests registered in its existing
test suite for the pure projection. Run two candidate roots containing identical inputs under
different paths; require unchanged revisions, no native rebuild solely for provenance and the
same final scope-vector digest. Individually change an image, value, dependency, owner, address,
retention, permission, contribution and operation body; each must change meaning or refuse under
the existing explicit lifecycle rules. Include a real spec field literally named `source`.

### M2 — Express validation separately from effects


Replace the blanket `bootstrapReview` verify expansion with explicit `ValidationRequirement`
values under `cli/nagarectl/src/Nagare/Inventory/Plan/ValidationRequirements.hs`. Each binds
resource ID, accepted/desired revision, expected incarnation, desired digest, adapter identity
and required health policy. The review distinguishes changed effects, re-acceptance with a real
policy change, already-converged resources and validation-only coverage. Explain every selected
scope and dependency in the rendered review. Keep full fresh platform validation for a new
platform stamp, performed as grouped reads rather than N journaled operations. Ordinary member
updates observe their impact closure; unrelated application scopes are not selected.

Implement a correct serial consumer first: at apply admission, recheck review bindings against
the locked head, observe the requirements freshly and refuse unknown, foreign, replaced,
terminating, unready or drifted members as required by their existing adapter semantics. This
child must not depend on future batching to be correct. EP-227 later replaces the serial proof
consumer with the same contract. Planning observations are preview evidence, not apply proof.
For changed resources, the final stamp depends on their completed operations and fresh final
health; EP-228 supplies the integrated final barrier. No-op release validation can be one fresh
apply epoch followed by the guarded stamp write, with no intervening workload mutations.

Bind validation requirements into the review digest so tampering fails. A new review field
cannot be optional to an older mutating reader. Inspect its decoder; if it ignores unknown fields,
increment the review/policy or adapter version that old apply reliably refuses. New readers must
still execute old admitted reviews under their original interpretation. Test a decoder from the
previous supported release fixture. Never claim compatibility because a JSON parser accepts bytes.

### M3 — Prove the complete producer and consumer


Using the EP-224 production-interpreter fixture, compile two releases with identical deployment
meaning but different provenance and marker release IDs. Plan, save, load, admit, apply and replan.
No unchanged member creates a `VerifyResource` operation or a journal entry; unchanged scope
revisions remain identical; the marker changes only after fresh proof. Repeat after moving/removing
the old workspace. Then alter one member and require exactly its authorized operation plus marker
and genuinely required dependency work. Inject drift between plan and apply, UID replacement,
failed readiness, missing retained bytes, stale head and an unfulfilled declared operation.
Every case must refuse or produce an explicit repair review, never publish a healthy stamp.

Update `PlatformTransitionTableSpec.hs`, `PlatformTransitionSpec.hs`, the human transition table
and affected ADR wording to describe retained revisions and the separate provenance record.
Keep bootstrap behavior for a new context and unknown/unconverged scopes: accepted equality alone
does not skip incomplete work. Stable revision behavior must also hold on the second replan.


## Concrete Steps


From the repository root, after registering the new tests:

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p PlatformIncremental' --test-show-details=direct
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p platform' --test-show-details=direct
cabal test --project-dir=cli/nagare-dsl --test-show-details=direct
just haskell-style-check
```

The first command must select the new test group, not an empty test set. Tests emit the changed
scope/operation counts and assert the old/new review compatibility matrix. After committing a
candidate run `just gate-fast <revision>`; preserve existing lifecycle and bootstrap regressions.
Native confirmation is coordinated by EP-224 after all architectural children integrate.


## Validation and Acceptance


M1 passes the equivalence/change matrix and retains bytes without needing an old workspace. M2
proves a no-op release still detects live drift while emitting zero per-member verify operations,
and old readers cannot accidentally bypass new proof requirements. M3 passes the real saved-review
round trip, second replan, UID/stale-head/unready faults and one-change scope-selection assertions.
The full platform live scan may remain proportional to grouped resource reads; eliminating
operations is not permission to fabricate live observations.


## Idempotence and Recovery


No accepted scope is rewritten during comparison. Old open transactions run with their original
review and adapters until closed or resumed. Unsupported old writers refuse new review versions
before mutation. A stopped marker update is recovered through the ordinary exact-identity path.
Missing provenance is diagnostic; missing native bytes or proof is a refusal. No migration may
change digests in place or infer ownership from names.


## Interfaces and Dependencies


Hard prerequisite: [EP-224 M1](224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md)
provides the baseline fixture and trace codec. This plan owns `DeploymentMeaning`,
`ValidationRequirement`, review versioning and scope selection. Its correct serial validation
consumer unblocks [EP-227](227-commit-verification-proofs-without-per-resource-remote-transactions.md);
the bounded live reader comes from [EP-226](226-share-bounded-cluster-observations-through-a-guarded-command-session.md).
[EP-228](228-run-incremental-platform-rollouts-with-bounded-waits-and-durable-progress.md) owns
execution scheduling and final barrier integration. No external dependency change is prescribed;
use Mori and authoritative release metadata before choosing one.
