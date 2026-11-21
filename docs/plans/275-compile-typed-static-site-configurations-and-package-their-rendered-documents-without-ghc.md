---
id: 275
slug: compile-typed-static-site-configurations-and-package-their-rendered-documents-without-ghc
title: "Compile typed static-site configurations and package their rendered documents without GHC"
kind: exec-plan
created_at: 2026-11-21T15:43:00Z
intention: "intention_01m7zchtvrea5a8mpy8mh8sx1r"
provenance:
  created_by:
    model: "gpt-6.2-astra"
    harness: "codex-cli"
    at: 2026-11-21T15:43:00Z
---

# Compile typed static-site configurations and package their rendered documents without GHC

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

A static-site author can keep writing ordinary Haskell in `nagare/Config.hs`. A credential-free builder compiles that program with Nagare's pinned SDK. Running the resulting executable once produces the configuration for a release. Kotei can then package the site's assets with a compiler-free `nagarectl` and pass the same rendered document to its existing delegated deployer. A changed Haskell source still requires a compiler on a cache miss. The saving comes from keeping that compiler out of the packaging Job's image and runtime dependencies.

The pilot covers one shipped static site on `x86_64-linux`, the platform of the Kotei build image motivating [IR-49](../improvement-requests/render-site-configuration-without-ghc.md). Its success criteria are identical deployable documents and image archives, a measured compiler-free runtime, and a working offline source path for existing installations.

## Progress

- [ ] M1. A compiled project config and the existing source renderer emit byte-identical contract-1 site documents. ADR 3 records which package owns source compilation.
- [ ] M2. `site package --rendered` accepts that document from a directory containing only the built assets and produces the same content digest as packaging from source. Invalid inputs fail before packaging.
- [ ] M3. The compiler-free Linux package and the project build example pass the isolated render, archive-equivalence and runtime-closure checks. The documented handoff uses the same document for packaging and deployment.

## Surprises & Discoveries

## Decision Log

- 2026-11-21. Use Kotei's project-compiled Haskell producer and data-consuming CLI pattern. Reuse the existing Nagare DSL and contract-1 envelope. This gives projects ordinary Haskell imports and type checking without maintaining a second configuration language or interpreter. Kotei's comparable interface is a compiled pipeline's `emit-dag` output consumed by `kotei run --dag`. See `mori://shinzui/kotei/plans/25-user-authored-pipelines-and-dsl-documentation`.
- 2026-11-21. Introduce an opt-in Linux output for the pilot. Keep the default SDK-backed install for users who run `nagarectl` directly against a checkout. A change to the default, additional workload kinds and adoption in Kotei's image are separate decisions after the pilot has measured results.

## Outcomes & Retrospective

## Context and Orientation

A site config is already an executable Haskell module with a `main`. The example at `cluster/examples/static-site/nagare/Config.hs` calls `emitStaticSite` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs`. Its stdout is the **inner config**. The **rendered document** wraps those exact UTF-8 bytes in a JSON string with a SHA-256 digest, kind, document name, contract version and emitting Nagare version. A digest verifies the bytes. Deployment still validates the input and enforces the actor's bounds. The implementations are `cli/nagare-dsl/src/Nagare/Dsl/Load/Rendered.hs` and `cli/nagarectl/app/Nagare/Cli/Runtime/Rendered.hs`.

Today `runRender` provisions GHC, calls the bounded source loader, selects a kind with the DSL decoder, and calls `renderedDocument`. `loadSiteInput` already handles source and rendered input for deployment. In `cli/nagarectl/app/Nagare/Cli/Commands/SitePublish.hs`, `runSitePackage` independently provisions GHC and calls `Load.loadSite`. This is the second evaluation to remove. Packaging still needs the actual frontend output directory, because the rendered document describes the site and carries no assets.

[ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) guarantees offline loading of an external source config and publishes `nagare-config-sdk`. The SDK check at `nix/checks/scripts/nagare-config-sdk-consumer.sh` already compiles a consumer's Haskell program to an executable. [ADR 17](../adr/0017-the-root-flake-follows-the-shared-haskell-nix-dev-toolchain-pin.md) establishes the shared toolchain pin. [ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) defines local packaging and the deterministic layered archive builder. [ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md) confines repository programs to the credential-free build. The compiled config is still repository code, including at compilation time. The deployer receives only the rendered document and the image publication inputs.

[EP-271](271-package-a-render-only-nagarectl-for-credential-free-build-images.md) plans a smaller `nagarectl-render` that still runs arbitrary source configs with GHC. That output and its size target serve a different workflow. This pilot can use its executable packaging and pinned base-archive fixture if available when implementation begins. It can proceed using the current SDK and CLI sources independently of EP-271's compiler rebuild.

## Plan of Work

### M1. Compile one site's config and emit the existing document

Start by amending ADR 3 with the proposed producer and consumer responsibilities, including the cold-build cost and the default install's direct-source guarantee. Link IR-49. Agree the amendment through the repository's ADR process before treating this distribution as accepted. Preserve the existing site authoring interface, including `emitStaticSite`.

Add `nagarectl site render --from-stdout [--out PATH]`. This switch reads the compiled program's raw stdout from standard input. It never launches a supplied executable. In `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`, make the switch exclusive with explicit source-loader arguments (`--file` and `--ghc-env`). With neither input selector the normal command still loads its default file. Carry the choice through `cli/nagarectl/app/Nagare/Cli/Options.hs` and `cli/nagarectl/app/Nagare/Cli/Dispatch.hs`. Factor the existing byte validation and envelope writer in `Nagare.Cli.Runtime.Rendered` so both inputs use the same site decoder, kind inference, version and output handling. Keep the new input specific to the site command. Preserve all bytes, including trailing whitespace. Validate before writing output. Invalid JSON, invalid site fields and invalid UTF-8 must exit unsuccessfully.

Add a project-consumable Nix example under `cluster/examples/static-site/`. Its compiler comes from the SDK of the same pinned Nagare revision as the CLI. Use the whole declared config source tree, including sibling Haskell modules and any explicitly declared build inputs. Compile with the SDK's `ghc --make -XGHC2024 -package nagare-dsl -inagare` in the project root, with a private build directory. Produce a native executable for the builder architecture. Run it in a separate credential-free build step in the documented project working directory. Bound its execution as the current loader does (see `cli/nagare-dsl/src/Nagare/Dsl/Load/Process.hs` and its default timeout). Check the producer's exit status before wrapping its bytes. A program that prints valid JSON and then exits unsuccessfully must fail the build. Export only the successful `rendered.json` as the project's reusable Nix output. A helper-module edit must invalidate the result. Capture diagnostic output separately so it cannot become configuration.

Compare the compiled example's document to the full CLI's `site render --file` output from the same revision. This proves the producer interface before work on the package distribution.

### M2. Package a rendered site with the existing packager

Extend `SitePackageOpts` in `cli/nagarectl/app/Nagare/Cli/Options/Site.hs` and the parser in `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`. Reuse `configInputOpt` from `cli/nagarectl/app/Nagare/Cli/Parser/Common.hs` as site deploy does. Route the two input forms through `loadSiteInput` in `runSitePackage`. Retain its static-site check, output validation, image qualification and layered builder. Resolve assets against the caller's `--project-dir` even when the rendered document lives in a different directory. Default and explicit source inputs on the full install retain existing behavior.

Validate both the envelope's kind and the inner site's kind before accepting it as a static site. Currently `loadSiteInput` discards the envelope kind after checking it is an allowed site kind. For the new path, require a static envelope and a decoded static body, with a clear diagnostic for a server site. Verify a bad digest, a newer unsupported Nagare version and simultaneous explicit `-f` and `--rendered` all fail before creating an output. Keep the existing `--build` behavior confined to the credential-free packaging environment. Leave the deployer command allowlist in `cli/nagarectl/src/Nagare/Inventory/DeployerCommands.hs` intact.

### M3. Ship and prove the compiler-free consumer

Add `packages.x86_64-linux.nagarectl-site` in `nix/packages.nix`, constructed in `nix/haskell-packages.nix`. Install the executable as `bin/nagarectl`. Start from the unwrapped executable output and copy only the required binary. Supply the layered builder's existing base-fetch tool, skopeo. Avoid references to the full CLI wrapper, platform payload or SDK. If the executable itself retains the compiler, use the repository's executable-only Haskell packaging pattern in `nix/release-images.nix` and check the dependency graph again. The supported pilot commands are `site render --from-stdout` and `site package --rendered`. Document direct source use with the existing full package.

Wire isolated derivations into `nix/checks/default.nix`. Keep the source-rendering reference check and the compiler-free runtime test in separate build environments. For the latter, run the prebuilt emitter and the new CLI without an SDK, emit the document, then package in a fresh directory with just the exported document, public assets and pinned base archive. The compiler stage is a build dependency. It must have no runtime reference from the emitter, published document or CLI to the SDK or GHC toolchain. Query Nix's registered dependency metadata for each output, including transitive references. Record the full and pilot CLI closure sizes on the same revision and system. Report sizes as measurements without assigning EP-271's ceiling to this pilot. A second invocation with the same inputs can reuse the rendered output without starting the compiler.

Update `docs/user/static-hosting.md` with the two-stage recipe, including how to build on a separate worker or substitute the cached document on a fresh packager. Demonstrate the artifact handoff to the existing `site deploy --rendered … --skip-build` flow with the accepted image resource for that archive. Use the local reviewed-deploy fixture documented in [the delegated deployer confirmation](../audits/mp33-local-confirmation-2026-11-11.md), or its existing contract proof together with byte identity. Production credentials and real deployment are unnecessary. Record IR-49's acceptance evidence against the ADR and the two flake checks. Kotei's consuming build image and release pin belong to `mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`.

## Concrete Steps

From the repository root on the pilot Linux system, use this smoke test after M1 and M2. It runs the compiler explicitly and compares both public command paths. Use a fresh temporary directory per invocation. The example uses prebuilt assets.

```bash
set -eu
repo="$PWD"
site="$repo/cluster/examples/static-site"
work=$(mktemp -d)
mkdir -p "$work/obj" "$work/assets"
cp -R "$site/public" "$work/assets/"
cd "$site"
nix shell "$repo#nagare-config-sdk" -c ghc --make -XGHC2024 -package nagare-dsl \
  -inagare -outputdir "$work/obj" -o "$work/config" nagare/Config.hs
timeout --kill-after=1s 120s "$work/config" > "$work/config.stdout"
nix run "$repo#nagarectl" -- site render -f nagare/Config.hs --out "$work/reference.json"
nix run "$repo#nagarectl" -- site render --from-stdout --out "$work/rendered.json" < "$work/config.stdout"
cmp "$work/reference.json" "$work/rendered.json"
nix run "$repo#nagarectl" -- site package --rendered "$work/rendered.json" \
  --project-dir "$work/assets" --context-out "$work/context"
test -s "$work/context/nginx.conf"
```

For M3 expose the following named checks. From the repository root, use a local Apple Linux container when it can build `x86_64-linux`, or an available builder for that system. Build the ordinary external-source compatibility check as well.

```bash
nix build --no-link -L .#checks.x86_64-linux.compiled-site-equivalence
nix build --no-link -L .#checks.x86_64-linux.nagarectl-site-closure
nix build --no-link -L .#checks.x86_64-linux.nagarectl-external-config
nix path-info -Sh .#packages.x86_64-linux.nagarectl .#packages.x86_64-linux.nagarectl-site
```

## Validation and Acceptance

M1 passes when `cmp` is silent, the current version and digest verify with `decodeRendered`, a sibling module change affects the artifact, and invalid or unsuccessful producer output yields no published document. Exercise a valid inner JSON document with trailing whitespace to catch accidental re-encoding. Compile and run the project on a builder with no deployment credentials.

M2 passes when the package command reads a document from outside the assets-only directory and succeeds in an isolated environment with no source config. A recording `runghc` on PATH must receive zero calls. Check both input-selection errors and the version, digest and kind refusals described above. Verify the existing full package still handles `--file` and omitted input.

M3 passes when the isolated emitter and packager complete with no compiler available, and the three runtime outputs pass the transitive closure check. Compare archives made by the full CLI from source and by the pilot from the exact rendered document. Supply both with identical assets, profile values, `--platform linux/amd64 --tag equivalence --builder layered`, and the same verified `--base-archive`. Use the fixture from EP-271 if present, otherwise materialize the base pinned by `basePinFor` in `cli/nagarectl/src/Nagare/Static/Image.hs` as a fixed-output archive and verify it with the existing builder. Run the comparison offline. Require byte equality of the two rendered documents and archives and equality of their reported content digests. Record those values and the measured closure sizes in this plan. Retain the existing deployed-document version and delegated review checks. A successful cold compilation is expected only on the builder.

## Idempotence and Recovery

Nix outputs are immutable. Repeating with the same declared inputs reuses successful outputs. A failed compile, render or package can be retried in a fresh work directory after correcting the input. Existing output directories and archives are protected by the packager. If the new consumer has a compatibility or closure regression, select the same revision's full CLI and use the project's source config. The pilot performs no inventory migration and needs no change to installed contexts.

## Interfaces and Dependencies

The stable artifacts crossing stages are the existing contract-1 `rendered-site` document, the built site files, and the image archive used by the existing publication flow. The emitter binary is private to its build platform. The rendered document can travel across architectures. Pin the project's SDK and consuming Nagare tools to a single release for the equivalence test. Use the repository's existing GHC, DSL, envelope validation, Nix package set and image pins. This plan introduces no dependency version changes.
