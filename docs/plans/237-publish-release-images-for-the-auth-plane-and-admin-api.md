---
id: 237
slug: publish-release-images-for-the-auth-plane-and-admin-api
title: "Publish release images for the auth plane and admin API"
kind: exec-plan
created_at: 2026-10-31T18:23:43Z
intention: "intention_01m69k6ss1e5797qfn2w8ytnyc"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-31T18:23:43Z
---

# Publish release images for the auth plane and admin API

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Record implementation friction using `agents/skills/exec-plan/FRICTION.md`, and promote durable decisions into the relevant ADRs before completion.


## Purpose / Big Picture

Implement [IR-39](../improvement-requests/publish-release-images-for-the-auth-plane-and-admin-api.md): a Nagare release supplies immutable Linux images for En (authorization), Shōmei (authentication), nagare-access (the request authorization gateway), and nagare-admin-api (the read-only administration service). Operators should bootstrap and upgrade enabled workloads without compiling or supplying image references. `platform status` must show which images actually run and refuse to call a context exact when they differ from the release.

An image digest is the SHA-256 identity of a container manifest, used in a reference such as `ghcr.io/shinzui/nagare-en@sha256:…`. It is not the hash of a compressed archive or a Nix output. This plan delivers four linux/amd64 images, their release metadata, automatic selection in reviewed inventory transactions, observable overrides and drift, and release/runbook verification. It does not enable the optional admin API on contexts that have not requested it.


## Progress

- [ ] M1: Four deterministic Nix images and one image manifest build from release-pinned sources; the packaged payload consumes the manifest without a dependency cycle.
- [ ] M2: Candidate and publication orchestration publish and independently verify the images and binary-cache closures, with safe retry and complete release evidence.
- [ ] M3: Bootstrap and transitions select release images by default, preserve explicit digest overrides in reviewed state, and roll matching migration Jobs and services together.
- [ ] M4: Platform status observes workload and running-container digests, reports release/override/drift/unknown states, and cannot report exact for non-release images.
- [ ] M5: Native candidate, bootstrap, upgrade, override, skew, and no-build acceptance pass; runbooks and ADRs describe the shipped procedure.


## Surprises & Discoveries


## Decision Log

2026-10-31: Use public GHCR repositories `ghcr.io/shinzui/nagare-en`, `nagare-shomei`, `nagare-access`, and `nagare-admin-api` (the latter three share the same prefix), with digest references as authority. Release tags are conveniences, never the selection input. Verify anonymous pulls before accepting publication.

2026-10-31: Derive the image manifest as a Nix output and include it in the packaged payload, rather than writing registry results back into the commit being released. This avoids changing a candidate after validation. Split executable/package construction from operator wrappers as needed to keep images independent of the final payload. The candidate must upload images before any rehearsal or intranet transition that needs to pull them.

2026-10-31: Retain explicit immutable overrides, but do not infer override intent from a differing live image or the environment of a later status command. Save intent in reviewed inventory state. An override whose digest differs from the release is visible and non-exact. Image skew must not prevent the reviewed transition that repairs it.

2026-10-31: Complete the release-image route directly. Additional Cloud Build caching and parallelism are not prerequisites: the request's interim workaround applies only while operators must use that route. Keep it documented for unreleased candidates; do not introduce a separate cache project here.


## Outcomes & Retrospective


## Context and Orientation

The source request is IR-39, originating at `mori://tan/tan-ng-labs`. This is a standalone plan, associated with intention `intention_01m69k6ss1e5797qfn2w8ytnyc`. Root `release.json` currently declares platform version 0.14.1 and the supported Nix systems x86_64-linux and aarch64-darwin. Both operator packages must select the same Linux service images.

`nix/haskell-packages.nix` defines a GHC 9.12.4 package set and already builds `nagare-api-server`. That package depends on the nagarectl library. The same Nix file also constructs operator wrappers that refer to `platformPackage`; blindly using those wrappers in an image would make the payload depend on itself. `nix/nagare-packages.nix` wires the packages and `nix/platform-package.nix` constructs the immutable payload, including its generated `release.json`. Root metadata is a source input, not a file to rewrite after a candidate run.

`cli/nagare-access/cabal.project` is a separate dependency workspace. It pins Shōmei to `6179d5678747aeb8ee3c45423c2bf59385dbda88` and En to `c3ee100a0b2cc63a50a9473ef590de7086dca4d0`, plus reviewed WebAuthn, Biscuit and instrumentation forks. These are observed baseline pins, not a request to upgrade them. `cluster/bootstrap/auth-images/build-local-image.sh` archives those sources, creates Cabal projects, and builds four variants through `cluster/bootstrap/auth-images/Dockerfile.local-haskell`. Preserve its runtime behavior, including Shōmei's pinned entrypoint, signing-key initialization, Dhall tooling, migration tools, certificates and non-root execution. Do not copy an arbitrary current upstream checkout into a release.

`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` currently requires `NAGARE_AUTH_EN_IMAGE`, `NAGARE_AUTH_SHOMEI_IMAGE`, and `NAGARE_AUTH_ACCESS_IMAGE`; enabled admin API bootstrap also requires `NAGARE_ADMIN_API_IMAGE`. It compiles desired inventory scopes using `cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`, `PackagedAuth.hs`, and `AdminApi.hs`. An inventory review records intended operations before application. `cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs` uses bootstrap stages to move an admitted context between releases, then commits the context pin. Inspect `cli/nagarectl/src/Nagare/Platform/Transition.hs` as well: its scope table currently describes auth as unchanged and must agree with the new behavior.

`cli/nagarectl/src/Nagare/Platform/Workspace.hs` decodes `PayloadManifest`. `cli/nagarectl/src/Nagare/Platform/Status.hs` compares CLI, payload, context, host and cluster release identities. `cli/nagarectl/app/Nagare/Cli/Runtime/PlatformStatus.hs` observes a cluster version ConfigMap, not running workload images. Consequently a correct marker can conceal stale workloads. Existing version collection lives under `cli/nagarectl/src/Nagare/Platform/Versions/`; reuse its observation infrastructure where applicable, without making IR-39 depend on a separate general version-reporting project.

`cli/nagare-harness/src/Nagare/Harness/Release/Candidate.hs` coordinates candidate gates, rehearsals, native packages, assembly and an intranet transition. `scripts/release-candidate.sh` is a wrapper; `scripts/assemble-release.sh`, `scripts/release-native.sh`, and `scripts/release-publish.sh` remain integration points. Release evidence is bound to the candidate, with later evidence commits separate from released source.

Consulted [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md): service images and the gateway must share reviewed upstream pins and dependency constraints. [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md) requires each auth server and its migration executable in the same image and migration success before rollout. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable tags, candidate-bound evidence and retry without replacement; its later amendments describe the pre-tag intranet run. [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) requires new release logic in tested Haskell, with shell limited to process glue. Amend these records when implementation changes their durable contracts; preserve their existing filesystem metadata convention.


## Plan of Work

### M1 — Build images and prove the payload boundary

Add `nix/release-images.nix` and extend the package wiring with outputs `release-image-en`, `release-image-shomei`, `release-image-access`, `release-image-admin-api`, and `release-images-manifest`. Build native x86_64-linux packages on the configured Linux builder; Darwin consumes the same Linux manifest, not Darwin executables. Follow the existing package set and pinned sources. Introduce explicit fixed-output source hashes and a parity check against `cli/nagare-access/cabal.project`, including the fork pins and compatibility constraints. Any new dependency bound or workaround requires Mori source discovery followed by authoritative registry and upstream-tag verification, not a guess from the local corpus.

Separate unwrapped Haskell packages from payload-dependent launcher construction where necessary. Ensure tests and version embedding consume source metadata, never the final image-enriched payload. Use deterministic image timestamps, ordering and compression; pin the conversion tooling through the flake. Compute manifest digests locally from the exact image representation that will be uploaded. Include all runtime dependencies and migration executables; test command overrides used by Kubernetes Jobs as well as the normal entrypoint. Add image source revision and Nagare release-version labels without pretending an upstream package's version equals Nagare's.

First prove a representative admin API path: build its image, calculate the distribution digest, embed that reference into a payload, decode it through `PayloadManifest`, and compile an admin scope using it. This exposes the library/payload cycle before expanding to the auth closure. Then require all four images to start in linux/amd64, with En and Shōmei migration and signing-key initialization smoke checks against disposable databases. Acceptance includes both native-system payload manifests agreeing byte-for-byte and a second image construction producing the same manifest digests.

### M2 — Publish once and bind release evidence

Add `cli/nagare-harness/src/Nagare/Harness/Release/Images.hs` and shared image-manifest types in `cli/nagare-contract/src/Nagare/Contract/ReleaseImages.hs`. Extend candidate orchestration so image publication completes before dependent rehearsals begin. Use its existing process transport for builds, cache upload, registry inspection and copies; never put credentials into evidence. Push executable/image closures to the configured release binary cache and verify a fresh consumer can substitute them. Public pull access is required even if GHCR package creation initially defaults to private.

The candidate uploads content by digest and verifies remote bytes. Final publication verifies these same objects and adds release-version aliases only when absent or already identical. Persist receipts binding candidate revision, image names, platform, manifest digests and source pins. An interrupted upload queries registry state and retries missing identical content; unknown network outcomes are not absence, and mismatched tags or manifests refuse rather than overwrite. Never remove an existing published image to repair a run.

Carry the manifest and receipts through native evidence, assembly and the checked publisher. Port any frozen shell evidence-shaping logic that must change to Haskell under ADR 24, retaining thin wrappers. Tests must include lost acknowledgements, one missing image, wrong platform, mismatched remote digest, changed candidate and unauthenticated pull failure. No GitHub release may publish until all four images and cache evidence validate. M2 passes with a recorded candidate registry roundtrip and repeat invocation producing identical evidence without rebuilding or replacing images.

### M3 — Default bootstrap and transitions to the release

Extend `PayloadManifest` with optional versioned `releaseImages` metadata, populated by `nix/platform-package.nix` from the manifest output. Define one pure image resolver used by auth and admin bootstrap. Its precedence is an explicit validated override, then the target payload's reference. For older payloads without metadata, preserve the legacy explicit-image requirement with an actionable error; never silently select `latest`. A new release missing one of the four manifest entries fails its release check.

Record selected image, expected release image and override intent in the reviewed scope and accepted inventory state. Apply executes the saved selection even if environment variables change after review. Remove a previous override by planning again without that override input; document this behavior. Changes to image digests must change desired resource identity and produce migration/rollout operations. The target payload, rather than the installed source payload or an accepted historical scope, supplies defaults during transition. Keep admin enablement unchanged and make both migration Jobs use exactly their server's selected digest.

Exercise existing `InventoryAuthSpec`, `InventoryAdminApiSpec`, `PlatformTransitionSpec` and `PlatformTransitionTableSpec` with a pair of payloads containing distinct digests. Prove all enabled workloads update with the four variables absent, an override changes only its selected workload, mutable tags are rejected, removing the override restores the release image, and failed migration prevents server advancement. Include resume after a partially applied transition. Acceptance is an actual reviewed change to the workloads, not only a changed metadata record.

### M4 — Observe and classify running images

Add a pure image assessment module under `cli/nagarectl/src/Nagare/Platform/` and bounded Kubernetes observation in the runtime status path. Compare the payload expectation, accepted override intent, Deployment container image and ready Pod container `imageID`. Use exact container names and ownership; ignore sidecars. During a rollout, mixed old/new ready replicas remain non-exact. Failed reads, missing workloads and unparseable image identities are unknown, never success. Account for the runtime's digest prefix format and compare the single-platform manifest identity consistently.

Emit per-workload JSON and human status including expected, selected and observed references, selection source, classification and reason. Classifications are `release`, `override`, `other-release`, `drift`, `unknown`, and `not-enabled`. Identify `other-release` only when retained release metadata proves the mapping; an arbitrary mismatch is `drift`, not a fabricated version. An explicit override equal to the expected digest retains its intent but may classify as release. Disabled admin API is `not-enabled` and does not force skew; an enabled-but-absent service is unknown.

Aggregate non-release enabled images into non-exact platform status while preserving stronger existing incompatibility diagnoses. Audit callers of `platformProbe`, mutation guards and transition finalization so skew remains repairable through reviewed reconciliation, and candidate acceptance cannot bypass the new check. Add tests to `cli/nagarectl/test/PlatformSpec.hs` and runtime transport tests proving status needs no image environment variables or registry writes. M4 passes when a previous-release live digest is named as skew despite matching version markers, and restoration returns exact only after ready replicas agree.

### M5 — Verify native behavior and document adoption

Extend the existing release rehearsal and `cli/nagare-harness/test/ReleaseTransitionSpec.hs` to cover the four-image contract. On disposable local and cloud contexts, bootstrap an enabled admin API with no image variables, then transition between two immutable payloads with different image digests. Capture the saved review, migration completion, ready workload image identities, admin version response, auth health/smoke results and final status. Demonstrate a one-workload override and a deliberately stale workload, then restore defaults. Do not alter a consumer's production environment as part of writing this plan.

Measure the cloud transition and record that no Cabal, GHC, Docker build or Cloud Build image compilation ran in the operator context. Nix substitution and registry pulls are expected. Run a clean-cache rebuild of the four image outputs from the immutable candidate/tag on the maintainer builder separately from the substitution test; compare distribution digests with the payload and registry. Publish the actual release through the existing release workflow when performing release acceptance; never invent a future release version in this plan.

Update `docs/runbooks/releases.md`, `docs/user/cluster-bootstrap.md`, `docs/user/upgrades.md`, and `docs/runbooks/admin-api-reader.md`, plus references to the image helper. Explain default release images, digest overrides, override removal, status classifications, optional mirroring and the candidate-only Cloud Build path. Retain old explicit pins in legacy instructions where required. Distill the packaging/publication changes into ADRs 1, 2, 7 and 24 as applicable. Complete only after all five IR acceptance criteria have recorded evidence.


## Concrete Steps

Run commands at the repository root. The new output names and harness commands below are interfaces to implement, not claims that they exist today. Use the existing dev environment and trusted Linux builder. No dependency sources should be discovered by traversing the Nix store.

```bash
mori registry show shinzui/en --full
mori registry docs shinzui/en
mori registry show shinzui/shomei --full
mori registry docs shinzui/shomei
nix build --no-link .#packages.x86_64-linux.release-image-en .#packages.x86_64-linux.release-image-shomei .#packages.x86_64-linux.release-image-access .#packages.x86_64-linux.release-image-admin-api .#packages.x86_64-linux.release-images-manifest
nix build --no-link .#packages.x86_64-linux.nagare-platform .#packages.aarch64-darwin.nagare-platform
cabal test nagare-harness-test --project-dir=cli/nagare-harness --test-show-details=direct
just haskell-style-check
python3 scripts/check-haskell-architecture.py
```

Builds must finish successfully; harness tests must cover image publication and resume. Put the focused CLI tests on the remote builder at the committed implementation revision, following repository practice:

```bash
just test-remote HEAD '/platform/'
just gate-release HEAD
```

Update the test filter to the actual registered image-test group if it differs, and record the number of executed cases so an empty selection cannot count as passing. Implement a harness entrypoint for independent image verification:

```bash
scripts/harness.sh release images verify --manifest "$IMAGE_MANIFEST" --anonymous
just release-candidate "$RELEASE_VERSION" --revision "$CANDIDATE_REVISION"
```

`IMAGE_MANIFEST` is the exported JSON from `release-images-manifest`; `RELEASE_VERSION` is the candidate's root metadata version; `CANDIDATE_REVISION` is its immutable commit. These commands require maintainer registry/cache credentials and the existing release environments. Verification must name four successful linux/amd64 digest checks. The candidate command also operates the configured intranet under the release workflow; use its rehearsal mode first when validating orchestration.

For operator acceptance select the disposable context and matching kubeconfig using `docs/user/upgrades.md`, enter the candidate's `#nagare` shell, and clear overrides before the normal reviewed transition:

```bash
unset NAGARE_AUTH_EN_IMAGE NAGARE_AUTH_SHOMEI_IMAGE NAGARE_AUTH_ACCESS_IMAGE NAGARE_ADMIN_API_IMAGE
nagarectl platform transition plan --out /tmp/release-images-review
nagarectl platform status --json
```

Apply each review and finalize through the existing transition procedure in `docs/user/upgrades.md`; the plan command returns the next stage, not an all-at-once apply. Retain the review and transaction IDs in acceptance evidence. Status after completion must report the four enabled images as release and aggregate exact. Repeat with one immutable admin override and with one observed stale auth deployment, using disposable fixtures.


## Validation and Acceptance

IR-39 AC-1 passes only when all four public images exist at the payload digests, the sources match the release pins, an independent rebuild reproduces those distribution digests, and binary-cache substitution succeeds. The M1 producer-to-payload-to-scope proof is the early integration gate.

AC-2 passes when bootstrap and a subsequent reviewed transition change all enabled workloads to the target digests without image overrides or operator builds; migration Jobs and servers agree and health/version evidence identifies the corresponding builds. Do not infer service version from a platform ConfigMap alone. Upstream version and Nagare release association are separate facts.

AC-3 passes when status names an intentionally stale workload and is non-exact, including mixed replicas and failed observations, then returns exact after restoration. AC-4 passes when a reviewed immutable admin override runs and remains identified as an override on a fresh status invocation with no environment inputs; the other three remain release images. AC-5 passes with measured cloud transition evidence showing no image compilation and reviewed runbooks that make release consumption the default.

Pure tests cover precedence, invalid/missing metadata, legacy payloads, provenance persistence and classification. Recording transports cover publication/retry and observation failures. Native verification proves anonymous registry access, executable runtime dependencies, migrations, real rollout and cache behavior. Compilation or invented fixtures alone cannot satisfy the acceptance criteria.


## Idempotence and Recovery

Builds and manifest generation are deterministic and repeatable. Uploads use content identity; retries verify before accepting already-present objects. If publication fails halfway, retain receipts and query the registry, then upload only missing content. A changed version tag or digest refuses. Never rewrite a published tag, release attachment or image alias to repair a release.

A failed transition resumes its existing inventory transaction. Keep the source release pin until every required stage verifies. Migration failure does not authorize deleting a database or editing migration history; follow the owning service's supported recovery. Restore default images by a new reviewed plan without override inputs. Rolling back a server image does not promise database downgrade compatibility. When evidence cannot be gathered because a registry, cache or disposable cloud environment is unavailable, record the unfinished criterion explicitly rather than calling the plan complete.


## Interfaces and Dependencies

The new `Nagare.Contract.ReleaseImages` module owns versioned JSON shared by release tooling and the CLI. A manifest contains `schemaVersion`, Nagare `platformVersion`, `sourceRevision`, and exactly four entries keyed `en`, `shomei`, `nagare-access`, `nagare-admin-api`. Each entry carries `platform` (`linux/amd64`), repository, digest, full immutable reference and upstream source revisions. The payload's `releaseImages` member embeds this structure. Packaging must yield identical content on both supported operator systems; release evidence duplicates it only for verification, not as a second authority.

The resolver returns expected release reference, selected reference and selection source (`release` or `override`) or a typed validation error. Accepted inventory state persists that selection. Observation remains separate from intent and stores per-container digest evidence with errors. Add fields through the existing serialization/versioning contracts and test old records, rather than invalidating historical payloads or inventing an override for them.

Dependencies remain the flake-locked Nix package set, existing Haskell packages, public GHCR and the existing release binary cache. Source discovery uses `mori://shinzui/en` and `mori://shinzui/shomei`; any newly required dependency is located through Mori before API work. This plan chooses no new dependency versions and makes no claim that the local corpus has the latest release. It requires no upstream source change unless runtime/package verification proves one necessary; document any such change using canonical Mori references and refresh this plan's prerequisites.
