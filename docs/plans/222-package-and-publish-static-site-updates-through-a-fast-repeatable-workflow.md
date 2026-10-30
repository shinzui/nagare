---
id: 222
slug: package-and-publish-static-site-updates-through-a-fast-repeatable-workflow
title: "Package and publish static site updates through a fast repeatable workflow"
kind: exec-plan
created_at: 2026-10-29T14:02:33Z
intention: "intention_01m63zddyhed6sqdete30scs28"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:02:33Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-30T17:03:51Z
      mode: "update"
      note: "Review for publish and update speed: explicit Docker cache policy (builder always passed --no-cache), unchanged-content no-op via context digest, prerequisite preflight before packaging, no required flags, symlink refusal, EP-224 trace evidence"
---

# Package and publish static site updates through a fast repeatable workflow

This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Record implementation friction using agents/skills/exec-plan/FRICTION.md and distill durable decisions into ADRs before completion.


## Purpose / Big Picture

An operator can publish a directory of static files, edit it, and publish again with one command and no required flags: `nagarectl site publish`. Nagare generates its own Nginx configuration and image, keeps Docker's layer cache between releases, chooses the context's architecture, and carries the accepted image identity into deployment. The operator does not copy Dockerfiles, discover the packaged compiler, invent publication keys, parse human output, or wait for a build when nothing changed.

Implement all four acceptance criteria in [IR-36](../improvement-requests/package-a-static-site-image-for-reviewed-publication.md), plus the user's requested fast repeat-release experience. Deliver both `site package` for an independently usable local artifact and `site publish` for the common complete release. A successful publish prints the deployed URL, release tag, accepted image resource and release directory. Editing the example's HTML and running publish again must change the served bytes; running publish again without an edit must finish without a Docker build and report the release already serving; rolling back must restore the earlier bytes. A prerequisite the release lacks (an accepted Namespace, the auth owner for a protected site, a CDN backend, a supplied-TLS Secret) is refused before any image is built, naming the prerequisite and the command that provides it.


## Progress

- [x] M1 (2026-10-30, 820de548): `site package --context-out` works from an external directory, matches the renderers byte for byte, and returns a deterministic content digest; `Nagare.Static.Package` tests and `just gate-fast` green. Open: the extended `nagarectl-external-config` nix check is written but not yet run.
- [ ] M2: Implemented and tested with a fake Docker runner (820de548). Real daemon (colima `nagare-mp23`, 2026-10-30, `--context local`, protected example): `skopeo inspect docker-archive:` accepts both archives and reports `arm64 linux` and `amd64` (`--override-arch`); the unchanged repackage shows both COPY layers `CACHED` (package.build 0.68 s), and a one-file edit rebuilds only `COPY site/` (0.74 s); the cold run was 1.29 s build, 2.54 s config load. Open: passing an archive unchanged to `app image-plan` (it would mutate the running local k3d inventory and registry, so it waits for a disposable context).
- [ ] M3 (coordinator, `site publish`, receipts and resume implemented 2026-10-30; not yet run against a cluster; `--contract 1` result not implemented): `site publish` with no flags performs the first publication and later updates by composing the existing reviewed operations: prerequisites refused before packaging, unchanged content a no-op, typed handoff, recoverable partial success.
- [ ] M4: The guide and protected-site drill prove publish, edit, republish, no-op republish and rollback; traced cold and warm runs demonstrate the repeat-release cost and the layer cache.


## Surprises & Discoveries

2026-10-30: The existing archive builder always disables Docker's layer cache, so "reuse the builder unchanged" (Decision Log, 2026-10-29) would rebuild every layer and recopy every file on every publish. `dockerBuildArguments` in `cli/nagarectl/src/Nagare/Inventory/ImageBuild.hs` emits:

```haskell
    [ "buildx", "build", "--load", "--no-cache", "--platform", T.unpack platform, "-f", dockerfile, "-t", T.unpack destination ]
```

The flag exists so a `RUN --mount=type=secret` instruction re-executes with fresh Build Secret values. Static packaging passes no secrets, so the cache policy is now explicit (Decision Log, 2026-10-30).


## Decision Log

2026-10-29: Include `site publish` as a small composition of existing publication and site services, alongside standalone packaging. Packaging alone closes the missing artifact step but leaves the user's frequent update workflow dependent on manual key allocation and resource-ID handoff. Preserve the two existing transactions rather than pretending publication and deployment are atomic.

2026-10-29: Package existing output by default, with explicit `--build` for the configured frontend build command. This honors IR-36's local read-and-package contract and avoids rerunning dependency installation on every artifact update. Publish uses the same default; documentation must distinguish editing source from editing prepared output.

2026-10-29: Reuse the existing Docker archive builder and ordinary layer cache. The context's target platform is the default for archives, with explicit `--platform linux/amd64` or `linux/arm64` supported by package. The production AMD64 acceptance and the existing ARM64 drill must both work. No new image builder, dependency upgrade, remote builder, or custom persistent build cache is needed.

2026-10-29: Keep archive and review paths immutable. Every changed release gets a distinct tag and publication key; old images remain accepted for rollback. A retry uses retained inputs and existing inventory recovery, never silently repackages a pending review.

2026-10-30: The builder's cache policy is an explicit parameter. `buildDockerArchiveWith` passes `--no-cache` only when the Build Secret map is non-empty (the fresh-secret contract that justified the flag) and never for static packaging. The existing test in `cli/nagarectl/test/InventoryArtifactSpec.hs` keeps asserting the flag for a secret-bearing build; a new test asserts its absence for the static argv. Nothing else about the builder's contract changes.

2026-10-30: Unchanged content is a no-op. The shared context writer computes a content digest over what it writes (sorted relative paths, regular-versus-executable mode, and the bytes of `Dockerfile`, `nginx.conf` and every site file). `site publish` compares it with the digest recorded for the site's latest accepted release in this context; equal digests with an unchanged config identity print the serving release, tag and URL and exit 0 with no Docker build, no inventory write and no new release. `--new-release` forces a release anyway. The digest is recorded in the receipt and as a scope override (`site-content`) on the image publication, so the comparison reads accepted inventory rather than only local files. An OCI manifest digest is not this identity: Docker stamps a creation time into the image config, so identical input yields different manifests across builds.

2026-10-30: Prerequisites are checked before packaging. Publish loads the config and resolves the context and profile once, loads the accepted snapshot once, and checks in order the foundation Namespace (`acceptedFoundationNamespace`), the auth owner when `access` is set (`acceptedAccessBinding`), the CDN backend when `cdn` is set, and every supplied-TLS Secret. The first missing prerequisite is refused with its name and the command that provides it, before Docker runs. That early read is a hint; each of the two transactions still opens its own pinned head, as ADR 22 requires.

2026-10-30: The common loop has no required flags. `--release-dir` defaults under the context's state directory; `--tag` is derived when omitted in both `package --archive` and `publish`, and printed; `--resume` takes an optional directory and otherwise selects the newest unfinished receipt for this site and context, refusing when more than one qualifies. Every refusal and partial failure prints the release directory and the exact resume command.

2026-10-30: Symlinks are refused, not materialized. The context writer copies regular files and directories, preserving dotfiles, structure and bytes, and refuses any symlink or special file naming the path and suggesting `cp -RL` to dereference before packaging. Materializing links with cycle and escape checks is complexity the common case does not need.

2026-10-30: Timing evidence comes from the EP-224 trace document, not a stopwatch. `NAGARE_TRACE_FILE=PATH` already writes a versioned document of spans, counts and process times for any command. The new stages wrap their work with `tracePhase` (config load, output preparation, context write, digest, build, save, inspect) and `traceProcess` (`docker`, `shasum`, `skopeo`), and M4 reads medians from those documents. EP-219's own phase tracing was never implemented; this plan no longer depends on it.

2026-10-30: Docker's build output goes to `build.log` in the release directory. The terminal shows one line per stage and the final URL, tag, image resource and release directory; `--verbose` also streams Docker's output to stderr. Machine stdout under `--contract 1` carries only the result document.

2026-10-30: Writing the archive straight from the build (`docker buildx build --output type=docker,dest=FILE`, which removes `--load` and the separate `docker image save`) is a measured candidate, not a requirement. Adopt it only when M4's traces show save time at or above EP-219's selection rule (median of at least 2 s or 10 % of the command's warm wall time) and after proving that `inspectArchive` and the transport accept its output exactly as they accept today's archives.

2026-10-30: The unchanged check reads the serving release's recorded `source` (the existing release-log provenance field) instead of a `site-content` scope override on the image publication. Publish records `content=<digest>;config=<digest>` there, so the comparison needs only the accepted site release log, which the deploy already loads; a config-only change (the config digest is a hash of the loaded `StaticSite`) is never reported unchanged. Releases made by other commands have no such source and are treated as changed.

2026-10-30: `--resume` is a switch and the directory comes from `--release-dir`; optparse has no optional-value option. Command handlers may not import each other (CLI architecture check), so the dispatcher passes the existing image-plan and static-deploy handlers into `runSitePublish`. The image resource is computed from the publication key by the same constructors the publication uses, not parsed from output.

2026-10-30: `site publish` pays one config load but still prepares the platform workspace once in image publication and once in site deployment; collapsing that needs the two handlers to share a resolved workspace and is left to the M4 traces to justify.

## Outcomes & Retrospective


## Context and Orientation

A StaticSite is a typed Haskell configuration that declares the output directory and HTTP behavior. A build context is a directory containing `Dockerfile`, `nginx.conf`, and `site/`. A Docker archive is the saved container image consumed by `app image-plan`. An inventory review records exact proposed effects and input hashes; apply journals and verifies those effects. A publication key identifies an immutable accepted image publication, not a mutable site's name. A content digest is the SHA-256 this plan computes over a written build context; it identifies what the operator asked to serve, independently of how Docker packaged it.

`cli/nagarectl/src/Nagare/Static/Build.hs` provides `prepareStaticOutput`; passing True skips the frontend command but validates the configured directory. `cli/nagarectl/src/Nagare/Static/Image.hs` provides `staticDockerfile` and `withStaticImageContext`. The latter copies output contents with `cp -R`, renders `renderNginxConfig`, and deletes its temporary context afterward. Expose one shared durable-context writer beneath this wrapper rather than duplicating rendering; the writer is where the content digest is computed.

`cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` compiles and runs `nagare/Config.hs` with `runghc` on every call, so each typed-config load is a fixed cost of seconds. The manual release pays it once in `site deploy`; publish must also pay it exactly once.

`cli/nagarectl/app/Nagare/Cli/Options.hs`, `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, and `cli/nagarectl/app/Nagare/Cli/Dispatch.hs` own CLI options, parsing, and dispatch; `Dispatch.hs` wraps contract-bearing commands with `withContract`. `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` loads typed configs through `provisionGhcEnv` and `Load.loadSite`, qualifies images with `qualifyImage`, and builds reviewed site scopes. Deployment requires `--skip-build`, an explicit tag, and an accepted image resource. Without `--save-plan`, normal production deployment already saves and applies a review in one invocation. Its `runReviewedSiteDeployPlan` resolves every accepted prerequisite (`acceptedFoundationNamespace`, `acceptedAccessBinding`, `reviewedCdnBinding`, `acceptedSecretBindings`) from one loaded snapshot; publish runs those same checks before packaging.

`cli/nagarectl/app/Nagare/Cli/Commands/Image.hs` similarly converges a publication when `--save-plan` is absent. It refuses a reused publication key with changed content, and attaches scope overrides such as `build-method` through `withScopeOverrides`; the `site-content` digest override uses the same mechanism. Its `--contract 1` result carries `imageResource` (see `docs/api/samples/image-publication-result.json`). `cli/nagarectl/src/Nagare/Inventory/ImageBuild.hs` exposes `buildDockerArchiveWith`, an injectable Docker runner, platform-explicit build arguments, and save logic; `dockerBuildArguments` always passes `--no-cache` today (Surprises & Discoveries). It rejects existing archives, but its direct final-path save needs staging for the new package contract. `inspectArchive` in `cli/nagarectl/src/Nagare/Inventory/Components/ControllerImage.hs` runs `shasum -a 256` over the whole archive and `skopeo inspect docker-archive:`; `scripts/inventory-artifact-transport.sh publish` re-hashes and re-inspects before `skopeo copy --preserve-digests`. Those repeated proofs are ADR 22's fresh-proof rule and stay. `skopeo copy` skips blobs the registry already holds, so after the first publish only the changed site layer is uploaded; the drill evidence must show that. `cli/nagarectl/src/Nagare/Image.hs` owns image qualification and tag composition. `cli/nagarectl/app/Nagare/Cli/Runtime/Target.hs` separates local profile resolution (`activeProfile`) from platform workspace preparation (`resolvePlatformWorkspace`); packaging needs only the former for archive naming.

The site stage's apply waits for the Knative Service to become ready (`waitForReadiness` in `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs`, 180 s). The node already holds the base layers from the previous revision, so an update pulls only the site layer. That wait is cluster time this plan reports but does not own.

EP-224 landed the command trace: `NAGARE_TRACE=1` prints a summary on stderr and `NAGARE_TRACE_FILE=PATH` writes a versioned document (`cli/nagare-contract/src/Nagare/Contract/Trace.hs`) of spans, counts and operations through `Nagare.Inventory.Trace.withCommandScope`; `tracePhase` and `traceProcess` in `cli/nagarectl/src/Nagare/Inventory/Store/Counters.hs` add a timed phase or program run. [EP-219](219-profile-the-image-publication-and-site-deployment-path-and-remove-its-measured-waste.md) owns general publication and deployment profiling and remains unimplemented; its M4 selection rule (median of at least 2 s or 10 % of the command's warm wall time) is reused here to judge optimization candidates. Do not block packaging on it or duplicate it. Existing untracked benchmark files are unrelated work and must be preserved.

`scripts/site-access-drill.sh` step 6 hand-copies the renderer and Dockerfile; its cluster is explicitly linux/arm64. `nix/checks/scripts/nagarectl-external-config.sh` is the packaged external-config check. `cli/nagarectl/test/Nagare/Test/Static.hs` contains existing build and Dockerfile tests, registered in `cli/nagarectl/test/Nagare/Test/Suite.hs` under groups named `Nagare.Static.Image`, `Nagare.Static.Build`, `Nagare.Static.Release` and `Nagare.Static.Preview`; that file is at its 300-line limit, so new groups join the existing `Nagare.Test.Static` import and group lines. Tasty patterns are case-sensitive: `-p /Nagare.Static/` selects these groups. `scripts/audit-managed-commands.py` keeps the exhaustive command-constructor registry in its `ROUTES` table and `docs/architecture/managed-resource-coverage.md` the catalogue between its registry markers; `scripts/test-managed-command-audit.sh` fails on an unregistered constructor. `docs/user/static-hosting.md` describes deployment but does not produce its required archive.

Relevant decisions are [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md), which makes the packaged compiler authoritative; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), which requires immutable reviewed effects, identity checks, recoverable journals, and one pinned head per transaction; [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), which requires deterministic failure tests before native confirmation; and [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md), which keeps access relationships attached to reviewed hostnames. Packaging must not alter access enforcement. ADRs currently use the filesystem convention; `mori show --full` declares no profiled ADR bundle.


## Plan of Work

### M1 — Expose the canonical build context


Add `SitePackageOpts`, a `SitePackage` command, and a thin `cli/nagarectl/app/Nagare/Cli/Commands/SitePackage.hs` boundary. Put testable orchestration and typed errors in new `cli/nagarectl/src/Nagare/Static/Package.hs`, registered in `cli/nagarectl/nagarectl.cabal`. Require exactly one of `--context-out DIR` and `--archive FILE`; `--tag TAG` is optional for archives and derived when omitted (M3's derivation, printed in the result). Support the familiar `--file`, `--project-dir`, and `--ghc-env` flags, optional `--output-dir DIR`, and explicit `--build`. Relative config paths follow existing CLI working-directory semantics; relative output overrides resolve from project-dir, and artifact destinations resolve from the invocation directory. Document and test these distinctions.

Load once with the normal packaged compiler and reject ServerSite with an actionable error before building. With no output override, use `prepareStaticOutput True`; with `--build`, run the configured build once and then resolve the selected output. Context mode must work with no active context and no Docker. Archive mode reads local context metadata only. Neither calls inventory, Kubernetes, gcloud, registry publication, or platform preparation. This is an orchestration property, not a sandbox for arbitrary executable Haskell or an explicitly requested build command.

Extract a shared context writer from `withStaticImageContext` and have the wrapper call it. Stage output beside the destination and publish it only when complete; reject existing destinations. Reject source/destination overlap after resolving paths, including destinations inside the source tree. Copy regular files and directories, preserving dotfiles, structure and bytes; refuse any symlink or special file before copying (Decision Log, 2026-10-30). While writing, compute the content digest over the sorted relative paths, regular-versus-executable mode and bytes of everything written, and return it in the package result; the same tree must produce the same digest on every machine, and one changed byte must change it. Tests compare Dockerfile and nginx.conf byte-for-byte to their generators and the copied example tree to public/. Include spaces, nested paths, dotfiles, invalid config, missing output, existing destinations, a symlink, an interrupted copy, and digest stability and sensitivity. Verify a sentinel BuildCommand never runs by default and runs exactly once with `--build`.

Extend the external-config check with the protected-site example in an unrelated temporary directory, both GHC environment overrides unset, and failing/logging provider shims. Require successful context packaging and zero calls to Docker, kubectl, gcloud, registry tools or inventory. This closes AC-1 and the context half of AC-3.

### M2 — Produce a reusable archive


Use `qualifyImage` and `taggedImageRef` to derive the exact destination from the loaded config and local target profile. Validate the tag and platform before Docker. Default to the profile platform, never the host architecture or ambient DOCKER_DEFAULT_PLATFORM. Reject unsupported platforms, malformed tags and qualified images outside the selected publication registry before expensive work. Context export needs neither tag nor profile.

Give `buildDockerArchiveWith` an explicit cache policy and pass `--no-cache` only for a build with Build Secrets (Decision Log, 2026-10-30); static packaging builds with the ordinary layer cache. Build with empty build-argument and secret maps. Do not add timestamps, cache-busting labels, or unconditional pulls, and retain the existing staticDockerfile bytes, so an unchanged context hits the cache for every instruction and a one-file change rebuilds only the `COPY site/` layer. Use a unique sibling staging archive, then publish with no-clobber semantics; clean owned staging files on failure and interruption without deleting a preexisting final file. Ensure failure cleanup is exception-safe, not only a False return. Keep concurrent package attempts from overwriting each other's archive. Docker may fetch the base image on a cold build; "no registry contact" means no target-registry authentication, inspection, or publication by packaging, not a claim that a cold Docker build is network-free.

Wrap the stages with `tracePhase` and the `docker` runs with `traceProcess` so a traced package run shows config load, output preparation, context write, digest, build and save separately. Before adding convenience orchestration, prove the real producer/consumer boundary: package an example archive and pass that file unchanged to the existing image-plan inspection path. Test runner argv and failures without Docker first, then inspect a real AMD64 archive and an ARM64 archive. Verify the selected architecture, embedded tag and expected HTTP content; do not infer platform from the requested argv alone. Archive mode must work without inventory or cluster credentials. Docker-daemon credentials and a cached or fetchable public base image are its only external requirements.

### M3 — Make repeated publication one command


Add `site publish` with the same source/build options plus optional `--tag`, `--release-dir`, `--new-release`, `--verbose` and `--resume [DIR]`. Default release directories live under the context's XDG state directory, separate from platform workspaces. Allocate a collision-resistant release identifier once; derive a valid tag and publication key from site identity plus that identifier when omitted. An explicit tag still gets a unique publication key. Never use the existing second-resolution `computeTag` alone for uniqueness. Once chosen, record tag, key, context, config identity, content digest, platform, archive path and eventual image resource in a versioned private receipt.

Create a small typed coordinator in new `cli/nagarectl/src/Nagare/Static/Publish.hs` with injectable package, image-publication and site-deployment operations. Refactor command-boundary helpers in `cli/nagarectl/app/Nagare/Cli/Commands/Image.hs` and `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` to return typed results before rendering output. Load the site, resolve the context and profile, and prepare the platform workspace once for this coordinator. Reuse existing inventory planning, execution, accepted-image validation and site compilation; do not spawn nagarectl subprocesses or parse console output. Register the new constructor in `scripts/audit-managed-commands.py` and the catalogue, and wrap it with `withContract` in `Dispatch.hs`.

The ordered path is preflight, no-op check, package, reviewed image convergence, then reviewed site convergence. Preflight loads the accepted snapshot once and refuses the first missing prerequisite with its name and the providing command, before any build (Decision Log, 2026-10-30). The no-op check compares the context's content digest and config identity with the site's latest accepted release; when equal and `--new-release` is absent, print the serving release, tag and URL and exit 0 without building. Otherwise record `site-content` as a scope override on the image publication. Display each review's operations through existing output conventions; Docker output goes to `build.log` in the release directory and to stderr only with `--verbose`. A failed or ambiguous publication cannot proceed to deployment. A successful publication followed by a deployment failure retains the archive, receipt, review and transaction identity; print the release directory and the exact resume command. `--resume` without a directory selects the newest unfinished receipt for this site and context and refuses when more than one qualifies. Resume checks the retained receipt and current context, verifies archive identity, delegates ambiguous work to existing inventory recovery, and continues only after accepted publication is proved. It must not rebuild, overwrite a review, replay proved effects, or reuse stale live observations. If configuration changes, refuse resume and explain how to start a new release while retaining the old transaction for recovery.

Support `--contract 1` with a versioned package/publish result through the existing contract machinery: archive/context path, content digest, tag, destination, platform, image resource when available, release directory, stage, and transaction outcome, with a distinct `unchanged` stage for the no-op. Keep progress and Docker output off machine stdout. Human success prints URL, tag, image resource and release directory. Manual review remains available through standalone package, image-plan --save-plan, inventory apply, and site deploy --save-plan; do not invent one combined review across two inventory heads.

Deterministic coordinator tests cover initial creation, changed output, unchanged output as a no-op, `--new-release` on unchanged output, each missing prerequisite refused before the package operation runs, repeated explicit tag behavior under existing publication rules, missing image acceptance, publication failure, deployment failure, changed config/archive, lost acknowledgement, resume with and without a directory, and ambiguous resume. Ensure old accepted image resources remain available for rollback. Match existing site deployment's CDN/TLS binding options needed by static sites; access continues to resolve through the existing site service. Server-site packaging is outside scope.

### M4 — Prove the operator loop and its cost


Replace drill step 6's copied renderer and Dockerfile with package; retain its separate publication reviews so AC-2 exercises archive compatibility. Add a focused publish-update scenario using the same disposable context: first publish, an HTML marker change and republish, an unchanged republish that must report the serving release without a build, and rollback to the original marker, checking served bytes and protected access at each step. Keep unique archives and keys for each release. Update `docs/user/static-hosting.md` with one-command first publish, editing prepared output, rebuilding source explicitly, repeat publish, the unchanged no-op, retained recovery paths, manual review, architecture selection, and rollback. Remove stale claims that site dry-run produces a Dockerfile.

Run every timed command with `NAGARE_TRACE_FILE` and keep the documents: one cold package, at least three warm unchanged and three warm one-file-update packages in the same builder, then complete publish and update commands against the same disposable context, excluding user think time and platform bootstrap. From the traces report medians and ranges per phase (config load, output preparation, context write, digest, build, save, inspect, each transaction, readiness wait), total wall time, image size, and cache evidence: Docker's `CACHED` lines for unchanged instructions and the transport's skipped-blob lines for the base layers. Do not promise an arbitrary latency independent of compiler, builder and cluster readiness. Acceptance requires cached unchanged layers, only the site layer uploaded on an update, no frontend command by default, no provider calls during package, exactly one config load and one workspace preparation within publish, no build on an unchanged republish, no redundant rebuild after successful publication on resume, and no manual renderer/key/resource-ID steps in the common loop. If a trace shows avoidable repetition in these new paths, or save time meets the selection rule for the direct-output exporter candidate, remove it and rerun matched samples. General provider latency remains EP-219's ownership, with measured residual explicitly reported.


## Concrete Steps


Run implementation commands from the repository root. New commands below describe the interface to implement, not functionality already available. For contributor checks:

```bash
just haskell-style-check
python3 scripts/check-haskell-architecture.py
bash scripts/test-managed-command-audit.sh
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Nagare.Static/' --test-show-details=direct
```

Place new tests under groups named `Nagare.Static.Package` and `Nagare.Static.Publish` beside the existing `Nagare.Static.*` groups in `cli/nagarectl/test/Nagare/Test/Suite.hs` and verify the runner executes them. Run the packaged external-config flake check declared in `nix/checks/haskell.nix` through the normal gate. After meaningful implementation commits, run `just gate-fast <commit-sha>`. Before native confirmation, use the exact-revision full gate and the prerequisites in `docs/runbooks/before-a-native-run.md`. Do not run the shared or cloud context merely to benchmark.

From an operator project containing `nagare/Config.hs` and its configured output, with a selected initialized context whose Namespace and, for a protected site, auth owner are accepted, the whole loop is:

```bash
nagarectl site publish            # first publication: prints URL, tag, image resource, release directory
# Edit a file in the configured output directory, then:
nagarectl site publish            # update: new tag and image resource, same URL
nagarectl site publish            # unchanged: reports the serving release and exits 0 without a build
nagarectl site publish --build    # source projects: run the configured frontend build first
```

Standalone artifacts and the less common options:

```bash
nagarectl site package --context-out ./artifacts/context-v1
nagarectl site package --archive ./artifacts/site-v1.tar --platform linux/amd64   # tag derived and printed; add --tag v1 to choose it
nagarectl site publish --new-release                                              # release unchanged content anyway
nagarectl site publish --release-dir ./artifacts/release-a --verbose              # explicit directory, Docker output on stderr
```

Create missing parent artifact directories automatically, but never replace an existing final context/archive. Each release directory is owned by exactly one release. First publish and update print distinct release tags and image resources and the same production URL. On a recoverable interruption:

```bash
nagarectl site publish --resume                 # the newest unfinished release of this site in this context
nagarectl site publish --resume ./artifacts/release-b
```

The guide must also show a complete manual-review transcript using the actual package result destination and image-plan result image resource, then site rollback with the earlier accepted resource. Use contract JSON fields instead of sed. For native confirmation run `bash scripts/site-access-drill.sh` only after satisfying its documented disposable-daemon, CLI, image-pin and GHC-environment prerequisites at the script header. Record the exact candidate revision, environment, trace documents, medians and observed HTTP markers under `docs/audits/ep222-static-publication.md`.


## Validation and Acceptance


M1 closes AC-1 through byte/tree comparisons and AC-3 through the packaged external-config check. M2 closes archive AC-3 using a fake Docker runner and forbidden-provider shims, proves the static argv carries no `--no-cache`, and proves real archive compatibility before M3. M4 closes AC-2 through the revised complete protected-site drill and AC-4 through a transcript following only the guide. The guide must cover both an existing local context and link its setup prerequisites; do not imply packaging initializes a cluster.

M3's acceptance is an observable four-step user loop: publish, edit, publish again, publish again unchanged, with distinct served markers, a no-op third run, and preserved rollback. Each missing prerequisite must be refused before the fake package operation is called. Test failures at every boundary before native runs, including retry after accepted publication with no second build. The final evidence must distinguish implemented deterministic checks from actual native observations. No milestone is complete because code merely compiles or a saved review exists. Publish speed claims require the recorded trace documents and cache evidence.


## Idempotence and Recovery


Packaging never overwrites final artifacts. A failed stage cleans only its owned temporary files. A completed archive is immutable input to publication, retained until the operator no longer needs review/resume material; do not add automatic archive or image pruning here. Repeating package with a new destination reuses Docker layers; existing destinations are an actionable refusal. Repeating publish on unchanged content is a no-op that changes nothing.

A publish receipt is local coordination metadata, not authority to mutate providers. Accepted inventory history and transaction journals remain authoritative. Resume rechecks context, exact input identities and transaction state, and uses existing recovery rules. It must handle a crash between provider success and receipt update by reconciling against those journals, never trusting a receipt's phase alone. Deployment failure does not roll back or erase a successful publication. Rollback remains the existing saved-review operation selecting the earlier accepted image; confirm the site returns the original content afterward.


## Interfaces and Dependencies


`Nagare.Static.Package` owns validated packaging inputs, a closed context/archive output choice, typed errors and a result with artifact path, content digest, optional destination/tag and platform. `Nagare.Static.Image` remains the only Dockerfile/context generator. `Nagare.Inventory.ImageBuild` remains the Docker build/save boundary and gains an explicit cache policy. `Nagare.Static.Publish` sequences typed operation results and receipts, never provider-specific commands. CLI modules own parsing, compiler/profile acquisition, service wiring and presentation.

Use existing dependencies and pinned toolchain. Cradle's process behavior was located through Mori at `mori://garnix-io/cradle/packages/cradle`; its guide confirms argv-based execution without implicit shell parsing. No new dependency bounds or pins are chosen here. Before introducing unfamiliar dependency APIs, use Mori to locate their source; verify upstream registry/releases if dependency selection becomes necessary. Do not inspect or traverse `/nix/store` to find a compiler.

This is a standalone plan, not a new child of the completed static-hosting MasterPlan. Coordinate shared tracing edits with EP-224 and preserve unrelated work. Implementation commits carry this plan's ExecPlan trailer and the frontmatter intention's Intention trailer. Update or create a filesystem-convention ADR for the local-package versus reviewed-publication boundary, the content-digest identity and two-stage recovery once implementation establishes the final contract.
