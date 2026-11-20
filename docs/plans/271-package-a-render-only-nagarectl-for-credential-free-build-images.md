---
id: 271
slug: package-a-render-only-nagarectl-for-credential-free-build-images
title: "Package a render-only nagarectl for credential-free build images"
kind: exec-plan
created_at: 2026-11-20T18:35:56Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-20T18:35:56Z
---

# Package a render-only nagarectl for credential-free build images

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This plan implements IR-48,
[`docs/improvement-requests/ship-a-render-only-nagarectl-for-credential-free-build-images.md`](../improvement-requests/ship-a-render-only-nagarectl-for-credential-free-build-images.md),
requested by `mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`
under `mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.
Rendering without GHC is a separate design question, filed as IR-49 and out of scope here.


## Purpose / Big Picture

Kotei builds a repository's Nagare site inside a credential-free Kubernetes build Job, because
the repository's `nagare/Config.hs` is untrusted and [ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md)
places config programs only in the credential-free build. The Job runs exactly two commands:

```bash
nagarectl site render -f nagare/Config.hs --out rendered.json
nagarectl site package -f nagare/Config.hs --archive image.tar --builder layered --platform linux/amd64
```

Today Kotei puts `packages.<system>.nagarectl` on the Job image's `PATH`, and the image is a
6.7 GB single layer. Most of that is not needed by those two commands: Helm, the platform payload,
the nagarectl Haskell library output, the GHC documentation, and every dependency's `-doc` output.

After this change, `packages.x86_64-linux.nagarectl-render` (and `aarch64-linux`) is a stable flake
output that runs those two commands and nothing else is shipped with it. On x86_64-linux its closure is at
most 2.5 GiB (hard ceiling 3.0 GiB, against 6.73 GiB for `nagarectl` on aarch64-darwin today
and an unmeasured, larger, x86_64-linux figure), it contains no `-doc` output, no test framework,
no Helm, no Pulumi, no Node.js, no gcloud and no platform payload, and a Nix check proves that its
`site render` and `site package` output is byte-identical to full `nagarectl`'s on the shipped
static-site examples. It also exposes its compiler, config runtime and CLI as separate
attributes so a nix2container image can keep the GHC layer cached across Nagare releases.

The operator-visible proof: `nix path-info -S .#packages.x86_64-linux.nagarectl-render` prints a
size at or under 2.5 GiB, and `nix build .#checks.x86_64-linux.nagarectl-render-equivalence
.#checks.x86_64-linux.nagarectl-render-closure` succeeds.


## Progress

- [ ] M1. The x86_64-linux closure of `packages.nagarectl` is measured and every path over
  50 MiB is attributed with `nix why-depends`; the base-archive fixed-output derivation the
  equivalence check needs builds and `site package --base-archive` accepts it. Evidence: the
  table and the attribution chains, recorded here.
- [ ] M2. `packages.<linux>.nagarectl-render` exists: the unchanged nagarectl executable from
  the nagarectl derivation's separate `bin` output, copied alone, wrapped with only the config
  runtime and skopeo on `PATH`. `nagarectl-render-equivalence` passes on x86_64-linux, and
  the closure size is recorded (expected about 4.4 GiB, because the stock GHC still drags in
  `ghc-doc`).
- [ ] M3. The render config runtime is built from the docs-free, profiling-free GHC 9.12.4
  that `mori://shinzui/haskell-nix-dev` publishes and caches in `shinzui.cachix.org`. Nagare's
  `haskell-nix-dev` pin is moved to a revision that has that output, with the same nixpkgs.
  The runtime's package set reaches only `nagare-dsl`, with no Haddock, no library profiling and
  no tests. An evaluation-time assertion fails if the render compiler's version differs from the
  main set's. `nagarectl-render-closure` passes (no forbidden path, size at most 2.5 GiB on
  x86_64-linux), `nagarectl-render-equivalence` still passes, and both sizes are recorded.
- [ ] M4. The outputs are landed (`just gate-fast`, `just land`), the full gate on the landed
  commit is green, the aarch64-linux size is recorded once from a native Apple container,
  [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md) carries an amendment
  naming `nagarectl-render`, `docs/user/` documents the output and its layer attributes, IR-48 is
  `completed` with the landed revision, and kotei-fa or the Kotei MasterPlan 26 owner has the
  revision to pin.


## Surprises & Discoveries

- The 7.2 GiB macOS closure Kotei measured overstates the leak of test frameworks on Linux. On
  Darwin each Haskell library carries `lib/links` dylib symlinks to every dependency, test
  dependencies included: `aeson-2.2.4.1` links `tasty-golden-2.3.6` and `vector-0.13.2.0`
  links `doctest-0.24.3` (`nix why-depends --precise`, 2026-11-20). Linux has no `lib/links`,
  so M1 must measure x86_64-linux rather than extrapolate.
- GHC's own output references its documentation. On x86_64-linux, `ghc-9.12.4` is 2.58 GiB,
  `ghc-9.12.4-doc` 0.79 GiB, and the whole GHC closure 3.73 GiB (`nix path-info --store
  https://cache.nixos.org -rS`, 2026-11-20). The reference is the `haddock-interfaces` field of
  GHC's `package.conf.d` entries, so `ghcWithPackages.override { installDocumentation = false; }`
  alone cannot drop `ghc-doc`; only a GHC rebuilt with `enableDocs = false` can. This is why M3
  exists.
- At v0.24.2, `packages.nagarectl` contains no Pulumi or Node.js: they are in
  `operatorNagarectl` and `nagare` only. On aarch64-darwin it is 569 paths and 6.73 GiB; Kotei's
  measurement of 672 paths with Pulumi was of an older pin or of `#nagare`.


## Decision Log

- Decision: Ship the full nagarectl executable, not a new render-only executable.
  Rationale: The two commands live in the executable-private `app/` modules
  (`Nagare.Cli.Commands.SitePublish`, `Nagare.Cli.Parser.Site`), so a second executable would
  move or duplicate CLI code and need a second link. The executable is about 170 MiB of a
  2.5 GiB target. Hiding commands is not a security boundary: `Config.hs` runs in a `runghc`
  child process either way, and ADR 35's boundary is the Job's lack of credentials. Shipping
  the same binary also makes byte identity follow from construction everywhere except the
  config runtime, which the check covers.
  Date: 2026-11-20

- Decision: Take the binary from a separate `bin` output of the one nagarectl derivation
  (`haskell.lib.enableSeparateBinOutput`) and copy `bin/nagarectl` alone into the package. Do
  not use `justStaticExecutables`.
  Rationale: `justStaticExecutables` is a second derivation and therefore a second full compile
  of nagarectl on every system, the most expensive package in the gate. A separate output costs
  nothing extra. Copying only `nagarectl` drops `nagared` (120 MiB) from the closure.
  Date: 2026-11-20

- Decision: The render runtime uses a GHC built with docs and profiled libraries off, and its own
  Haskell package set that reaches only `nagare-dsl`. The main package set, `nagarectl` and
  `nagare-config-sdk` keep the standard GHC.
  Rationale: Only a rebuilt GHC removes `ghc-doc` (see Surprises). Changing the main set's GHC
  would rebuild every Haskell package in the gate and change `nagare-config-sdk`, which ADR 3
  publishes as the runtime that nagarectl uses.
  Date: 2026-11-20

- Decision (operator, 2026-11-20, relayed by kotei-fa): Do M3, but take the docs-free GHC from
  `mori://shinzui/haskell-nix-dev`, the operator's reusable GHC toolchain flake, and do not
  rebuild it in Nagare. haskell-nix-dev gains that compiler as an output, its CI builds and pushes
  it to its existing cache `shinzui.cachix.org`, and Nagare consumes it through its existing
  `haskell-nix-dev` input. Nagare's GHC bumps follow haskell-nix-dev's.
  Rationale: The operator does not want Nagare to carry its own GHC builds from nixpkgs. One
  toolchain flake owns the compilers and their cache. Nagare already follows haskell-nix-dev's
  nixpkgs, so its main compiler is haskell-nix-dev's `ghc9124` today. The render compiler is the
  same source and version, built with other flags, so the compiler that evaluates `Config.hs`
  is the one the render set builds `nagare-dsl` with. The haskell-nix-dev change is separate
  work in that repository, and it is not made without the operator's approval (see Interfaces
  and Dependencies).
  Date: 2026-11-20

- Decision: Publish `nagarectl-render` for `x86_64-linux` and `aarch64-linux` only. Accept on
  x86_64-linux. Record aarch64-linux's size once.
  Rationale: Kotei's build Jobs run Linux images (linux/amd64 on the intranet, ARM64 on native
  local contexts). A Darwin variant would add a third GHC build for no consumer.
  Date: 2026-11-20


## Outcomes & Retrospective




## Context and Orientation

Terms used here:

- A **closure** is a Nix store path together with every store path it references, transitively.
  A container image built from Nix contains the closure of what it puts on `PATH`.
  `nix path-info -S PATH` prints its total size; `nix path-info -rs PATH` lists its members;
  `nix why-depends A B` prints the reference chain from `A` to `B`.
- The **typed config runtime** is `ghcWithPackages (hp: [ hp.nagare-dsl ])`: a GHC whose global
  package database contains `nagare-dsl`. `nagarectl` runs a repository's `nagare/Config.hs`
  with `runghc` from that runtime and reads the JSON the program prints
  (`cli/nagare-dsl/src/Nagare/Dsl/Load.hs`). [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md)
  makes it part of nagarectl's distribution contract and, by its 2026-11-09 amendment, publishes
  it as `packages.<system>.nagare-config-sdk`.
- **nix2container** is the image builder Kotei uses. `buildLayer { deps = [ … ]; }` makes one
  layer from a closure, and its `layers` argument leaves out paths already in earlier layers.

Relevant ADRs: ADR 3 (above); [ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md),
under which config programs run only in the credential-free build and the deployer accepts
rendered envelopes. No ADR covers container layering or closure size.

Where the packaging lives:

- `flake.nix` declares release systems from `release.json` (`x86_64-linux`, `aarch64-darwin`) and the
  tooling system `aarch64-linux`, and imports `nix/nagare-packages.nix`, `nix/packages.nix` and
  `nix/checks/default.nix`.
- Where the compiler comes from: `flake.nix` sets `inputs.nixpkgs.follows =
  "haskell-nix-dev/nixpkgs"`, and `flake.lock` pins `haskell-nix-dev` at `206ecd25` and, through
  it, nixpkgs `d5dfd8e6`. haskell-nix-dev's toolchain `ghc9124` is `pkgs.haskell.packages.ghc9124.ghc`
  from that same nixpkgs (its `flake.nix`, `toolchainFor`), so Nagare's main package set, and
  with it `nagare-dsl`, `nagarectl` and `nagare-config-sdk`, already uses haskell-nix-dev's GHC
  derivation. Nagare does not yet read the compiler from haskell-nix-dev's outputs. It names the
  attribute `ghc9124` itself. haskell-nix-dev's CI (`.github/workflows/build.yml`) runs `nix flake
  check` for the systems its `config/toolchain-policy.nix` marks `ciRequired` (aarch64-darwin and
  x86_64-linux; aarch64-linux is not required) and pushes to `shinzui.cachix.org`, which Nagare's
  `nixConfig` already lists.
- `nix/haskell-packages.nix` builds the GHC 9.12.4 package set (`pkgs.haskell.packages.ghc9124`
  with Nagare's overrides), the Haskell `nagarectl` derivation (tests run in it on x86_64-linux),
  `typedConfigRuntime`, and the shipped `nagarectl`: a `buildEnv` over the Haskell package whose
  wrapper prefixes `PATH` with `typedConfigRuntime`, `bind.dnsutils`, `kubernetes-helm`, `skopeo`
  and `jq` and sets `NAGARE_PLATFORM_ROOT` to the platform payload (`nix/platform-package.nix`).
  `operatorNagarectl` and `nagare` add Pulumi, Node.js and the rest.
- `nix/packages.nix` maps those to flake `packages`. `nix/checks/sdk-consumer.nix` and
  `nix/checks/scripts/nagare-config-sdk-consumer.sh` are the model for a hermetic consumer check:
  empty `HOME`, no checkout marker above the working directory, no network.

What the two commands need, read from the source:

- `site render` (`cli/nagarectl/app/Nagare/Cli/Parser/Site.hs`) loads the config through `runghc` and
  prints the rendered-site document. It needs the typed config runtime and no context or credentials.
- `site package` (`runSitePackage` in `cli/nagarectl/app/Nagare/Cli/Commands/SitePublish.hs`) loads
  the config, optionally runs the site's build command, writes the context, and for `--archive`
  resolves the active target profile (`activeProfile`; with no context it uses the built-in
  default) to qualify the image reference. The layered builder (`cli/nagarectl/src/Nagare/Static/Layered.hs`)
  takes the pinned nginx base from `--base-archive`, from `$XDG_CACHE_HOME/nagare/static-base/`,
  or fetches it with `skopeo copy` from `docker.io/library/nginx:1.30.7-alpine` by the digest in
  `basePinFor` (`cli/nagarectl/src/Nagare/Static/Image.hs`). The pins are compiled in, so the
  platform payload is not needed. Without `--tag`, the tag is derived from the clock and written
  into the archive's `RepoTags`, so two runs differ. The equivalence check passes `--tag`.
- Neither command reads `NAGARE_PLATFORM_ROOT`, Helm, `dig` or `jq`. The package keeps `skopeo`
  so a Job without `--base-archive` still works (Kotei's Job has public egress).

Coordination: release work runs through the `nagare-release` skill and its sessions. Do not land
while a release candidate is being published. Rebase on `origin/master` before landing.


## Plan of Work

M1, measurement. On a machine that can build x86_64-linux (the remote builder through
`nix-gcp-builder`, or a native Apple container per the global build rule), build
`.#packages.x86_64-linux.nagarectl` and record `nix path-info -S`, the member list sorted by size,
and `nix why-depends` for each member over 50 MiB. Add the pinned base as a fixed-output
derivation in `nix/static-base.nix`:
`pkgs.dockerTools.pullImage { imageName = "docker.io/library/nginx"; imageDigest = <linux/amd64 manifestDigest from basePinFor>; os = "linux"; arch = "amd64"; sha256 = …; }`, and confirm
`nagarectl site package --base-archive` accepts it; `readBaseArchive` verifies the config
digest. If it refuses, convert it with `skopeo copy docker-archive:… docker-archive:…` inside a
plain derivation and record what the difference was.

M2, the package. In `nix/haskell-packages.nix`, wrap the Haskell `nagarectl` derivation in
`hl.enableSeparateBinOutput`. Executables then live in the `bin` output, so three consumers that
read `bin/` from the default output must change. The shipped `nagarectl` `buildEnv` sets `paths =
[ haskellPackages.nagarectl haskellPackages.nagarectl.bin ]`, so its tree and behaviour do not change.
`nix/checks/platform.nix` (`nagare-operator-tools`) reads
`${nagarePackages.haskellPackages.nagarectl.bin}/bin/nagarectl`. `nix/test-runs.nix`'s
`testBinary` override is checked for any `bin/` path it reads. Confirm with `nix why-depends` that the `bin` output does not
reference `out` or GHC. If it does, find the embedded path with `--precise` and remove it with
`remove-references-to`, or with `disallowGhcReference` for GHC. Then add:

```nix
renderCli = pkgs.runCommand "nagarectl-render-cli-${releaseVersion}" { } ''
  install -Dm555 ${haskellPackages.nagarectl.bin}/bin/nagarectl "$out/bin/nagarectl"
'';
nagarectlRender = pkgs.symlinkJoin {
  name = "nagarectl-render-${releaseVersion}";
  paths = [ renderCli ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram "$out/bin/nagarectl" \
      --prefix PATH : ${lib.makeBinPath [ renderConfigRuntime pkgs.skopeo ]} \
      ${lib.optionalString (sourceRevision != null) "--set NAGARE_SOURCE_REVISION ${sourceRevision}"}
  '';
  passthru = { compiler = renderGhc; configRuntime = renderConfigRuntime; cli = renderCli; };
  meta.mainProgram = "nagarectl";
};
```

In M2, `renderGhc = haskellPackages.ghc` and `renderConfigRuntime =
(haskellPackages.ghcWithPackages.override { installDocumentation = false; }) (hp: [ hp.nagare-dsl ])`. Return `nagarectlRender` from the module and expose
`nagarectl-render` in `nix/packages.nix` under `lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux`.

Add `nix/checks/render.nix`, imported by `nix/checks/default.nix` for x86_64-linux only, with two
checks:

- `nagarectl-render-equivalence`: a `runCommand` running
  `nix/checks/scripts/nagarectl-render-equivalence.sh`. For each of `cluster/examples/static-site`,
  `cluster/examples/protected-static-site` and `cluster/examples/static-cdn-site`, it copies the
  example into a fresh directory with an empty `HOME`, `XDG_*` and no checkout marker (as the SDK
  consumer script does). It then runs `site render --out` and `site package --archive --builder
  layered --platform linux/amd64 --tag equivalence --base-archive $base`, first with the shipped
  `nagarectl` and then with `nagarectl-render`, and requires `cmp` to report both outputs
  identical, along with the `content-digest:` lines. It fails if the network is reachable.
- `nagarectl-render-closure`: given `pkgs.closureInfo { rootPaths = [ nagarectlRender ]; }`, it
  fails if any store path's name ends in `-doc`, if any name after the hash starts with
  `doctest-`, `tasty`, `hspec`, `QuickCheck-`, `pulumi`, `kubernetes-helm-`, `nodejs`,
  `google-cloud-sdk`, `nagare-platform-` or `bind-`, if any name is exactly `nagarectl-0.0.0` (the
  library output), or if the summed `NAR` size exceeds 2.5 GiB. It prints the 15 largest
  members either way. In M2 this check is expected to fail on `ghc-9.12.4-doc` and the size.
  Record that failure and do not land the check until M3.

M3, the docs-free runtime. It depends on the haskell-nix-dev integration point described in
Interfaces and Dependencies. First check whether haskell-nix-dev has a revision with the
runtime compiler output, built by its CI and present in `shinzui.cachix.org` for x86_64-linux.
If it does not, stop and ask the operator; do not change haskell-nix-dev from this plan. Then move
Nagare's pin with `nix flake update haskell-nix-dev`. Confirm that `flake.lock`'s `nixpkgs_2`
revision is unchanged, or record the new one and expect the main set to rebuild. Confirm that
`nix path-info --store https://shinzui.cachix.org` finds the compiler. In
`nix/haskell-packages.nix`, take `haskellNixDev` (the flake input) as an argument from
`nix/nagare-packages.nix`, factor Nagare's overrides into a function both sets use, then define:

```nix
renderGhc = haskellNixDev.lib.${pkgs.stdenv.hostPlatform.system}.ghcVersions.ghc9124.runtimeCompiler;
renderHaskellPackages = assert renderGhc.version == haskellPackages.ghc.version;
  pkgs.haskell.packages.ghc9124.override {
  ghc = renderGhc;
  overrides = lib.composeExtensions nagareOverrides (_hfinal: hprev: {
    mkDerivation = args: hprev.mkDerivation (args // {
      doHaddock = false; enableLibraryProfiling = false; doCheck = false;
    });
  });
};
renderConfigRuntime = (renderHaskellPackages.ghcWithPackages.override { installDocumentation = false; })
  (hp: [ hp.nagare-dsl ]);
```

The GHC version and every library version are the same as the main set's, so the JSON a config
program prints is the same. The equivalence check proves this. Build both checks on
x86_64-linux and record the closure size and the largest members. The compiler comes from the
cache. Only `nagare-dsl`'s dependency set is built against it, and the release's usual cache
push carries that set, so Kotei does not rebuild it.

M4, landing. Land through `just gate-fast` and `just land`, then wait for the landed commit's
full gate. Build `.#packages.aarch64-linux.nagarectl-render` once in a native Apple container
and record its size. Amend ADR 3 with a dated section: `nagarectl-render` is the render-only
distribution, its runtime is built from a docs-free GHC of the same version, and it is
contractually equivalent for `site render` and `site package` through the equivalence check.
Document the output and its `compiler`, `configRuntime` and `cli` attributes in
`docs/user/`, next to the configuration SDK's documentation (find it with
`grep -rln nagare-config-sdk docs/user`). Mark IR-48 `completed` with the landed revision and
send the revision to the Kotei session.


## Concrete Steps

Run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`.

M1 measurement (x86_64-linux):

```bash
p=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.nagarectl)
nix path-info -S "$p"
nix path-info -rs "$p" | sort -k2 -n | tail -25 | awk '{printf "%8.0f MiB  %s\n",$2/2^20,$1}'
nix why-depends "$p" <member>
```

M2/M3 size and checks:

```bash
nix build --no-link .#packages.x86_64-linux.nagarectl-render
nix path-info -S "$(nix build --no-link --print-out-paths .#packages.x86_64-linux.nagarectl-render)"
nix build --no-link -L .#checks.x86_64-linux.nagarectl-render-equivalence .#checks.x86_64-linux.nagarectl-render-closure
```

Expected after M3: the size line prints at most `2684354560` bytes (2.5 GiB), and both checks
build. The closure check's log lists `ghc-9.12.4` (the docs-free build) as its largest member and
no `-doc` path.

Landing (M4):

```bash
git fetch origin && git rebase origin/master
just gate-fast
just land
```


## Validation and Acceptance

- `nagarectl-render-equivalence` passes on x86_64-linux. Run its script by hand once with the render
  side given `--tag other`, and record that it fails and names the differing archive. That shows
  the comparison can fail.
- `nagarectl-render-closure` passes, and its printed size is at most 2.5 GiB.
- The shipped `packages.x86_64-linux.nagarectl` closure is unchanged apart from the derivation hash
  that the `bin` output split causes. `nix path-info -S` before and after differs only by the
  size of the new `bin` path, and the `nagare-config-sdk-consumer` check and the full gate stay
  green.
- Kotei acceptance is Kotei's: in its build image it replaces `packages.nagarectl` with
  `packages.nagarectl-render`, and its site deploy runs green. Kotei's plan 148 records that, not
  this plan.


## Idempotence and Recovery

Every step is a Nix build or a file edit, so it can be repeated. Nothing here touches a context,
cloud project, host or the intranet. To back out M3, set `renderGhc = haskellPackages.ghc` and
`renderConfigRuntime = typedConfigRuntime`. Revert the `haskell-nix-dev` pin in `flake.lock`
only if the move changed nixpkgs. To back out the whole plan, remove the
`nagarectl-render` attribute and the two checks. The `bin` output split can stay.


## Interfaces and Dependencies

The flake outputs Kotei consumes, stable from the landing revision on:

- `packages.x86_64-linux.nagarectl-render` and `packages.aarch64-linux.nagarectl-render`: a
  directory with `bin/nagarectl`. `nagarectl site render` and `nagarectl site package` behave
  exactly as in `packages.<system>.nagarectl` of the same revision. Other commands are present
  but unsupported in this package: no platform payload, Helm, `dig` or `jq` is on its `PATH`.
- `nagarectl-render.compiler`: the GHC store path (changes only when GHC or nixpkgs moves).
- `nagarectl-render.configRuntime`: the `ghcWithPackages` runtime with `nagare-dsl` (changes when
  `nagare-dsl` or its dependencies change).
- `nagarectl-render.cli`: the bare executable (changes every revision).

Layer advice for Kotei's `nix/kotei-forge-build-image.nix` (`mori://shinzui/kotei`, project-relative
path; artifact-level URI pending), which today builds one layer with `nix2container.buildImage`.
Check it against nix2container v1.1.0's `buildLayer`:

```nix
let
  render = nagareRendering.packages.${system}.nagarectl-render;
  compilerLayer = imageBuilder.nix2container.buildLayer { deps = [ render.compiler ]; };
  runtimeLayer = imageBuilder.nix2container.buildLayer {
    deps = [ render.configRuntime ];
    layers = [ compilerLayer ];
  };
in
imageBuilder.nix2container.buildImage {
  layers = [ compilerLayer runtimeLayer ];
  # extraTools = [ render ]; the CLI, skopeo and Kotei's own tools stay in the final layer.
}
```

A Nagare release that changes neither GHC nor the DSL then changes only the last layer, about
0.3 GiB. Kotei's seed init container copies the whole image `/nix` into a writable store at Job
start (`kotei-seed-nix`), so the closure size is also a per-Job copy cost, not only a pull cost.

Integration point with `mori://shinzui/haskell-nix-dev`. This is separate work in that
repository, made only with the operator's approval and not by this plan:

- haskell-nix-dev exposes, for each available compiler, a runtime variant of the compiler:
  `pkgs.haskell.compiler.<ghc>.override { enableDocs = false; enableProfiledLibs = false; }`
  from its own pinned nixpkgs. The suggested attribute is
  `lib.<system>.ghcVersions.<ghc>.runtimeCompiler`. Its CI builds it, through a check or package
  output such as `toolchain-runtime-<ghc>` that `nix flake check` realizes, and pushes it to
  `shinzui.cachix.org` for every `ciRequired` system.
- The variant has the same version and source as `<ghc>.compiler`, so a consumer can assert that
  the two versions are equal.
- aarch64-linux is not CI-required there, so an aarch64-linux `nagarectl-render` builds the
  compiler locally until haskell-nix-dev caches that system.

Nagare then reads `renderGhc` from that attribute. The name in M3's code is the suggested one, so
use whatever haskell-nix-dev actually exports. Its compiler bumps reach Nagare when Nagare moves
its `haskell-nix-dev` pin, as nixpkgs does today.

Other dependencies: nixpkgs' `haskell.compiler.ghc9124` override arguments `enableDocs` and
`enableProfiledLibs`, and `ghcWithPackages.override { installDocumentation }`, both checked with
`nix eval` against the locked nixpkgs on 2026-11-20; `dockerTools.pullImage` for the base archive.


## Out of Scope and Follow-ups

- **Render without GHC (IR-49).** Even the docs-free package carries a GHC and `nagare-dsl`
  (about 2 GiB), because `site render` compiles the repository's typed `Config.hs`. Removing the
  compiler is a design change, not packaging, and needs an ADR. There are two candidate
  directions. (a) A precompiled evaluator: a compiled program that loads a config without the
  compiler toolchain, through an embedded interpreter or a restricted, evaluable subset of the DSL
  for sites. (b) A data format for simple sites: a static site declares validated JSON or Dhall
  instead of `Config.hs`, so its build needs no GHC, and typed `Config.hs` stays for
  applications. Both would amend ADR 3, which makes the compiler part of the CLI's contract. (a)
  replaces the full language with a smaller one that Nagare must keep sound. (b) splits the
  configuration model, so a site written in data cannot use the typed helpers and validation.
  Under ADR 35 the evaluation of untrusted config stays in the credential-free build either way,
  and a data format shrinks what that build must contain. IR-49 records the request.
- A render-only executable with a reduced command set (see Decision Log).
- Shipping the nginx base archive in the package so a Job needs no registry egress; Kotei can pass
  `--base-archive` today.
- Kotei's own image changes, its tag choice for `site package`, and its layering, which Kotei
  plan 148 owns.
