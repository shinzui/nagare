---
type: Explanation
title: "Build modes"
description: "Understand Nagare prebuilt-image, Dockerfile, and Nixpacks build modes and choose the right mode for an application."
docId: DOC-6
tags: [builds, containers, dockerfile, nixpacks]
generated:
  by: human:nadeem
  at: 2026-07-01T01:38:13Z
---

# Build modes

> **Current live path:** Build an image separately, export its Docker archive,
> publish that archive with `nagarectl app image-plan`, then deploy with an
> explicit tag and accepted `--image-resource`. `nagarectl deploy` and
> `nagarectl app deploy` no longer build or push an image. The typed build modes
> below describe how to prepare the archive. Accepted Build channel inputs can be declared
> on `app image-plan` with `--build-input-resource RESOURCE-ID`.

Every `Deployment` carries a typed `build` field that says **how** its container
image is produced. There are three modes:

| Mode | Use when | Image preparation |
| --- | --- | --- |
| **Prebuilt image** | Your CI or another builder produced the image. | Export its archive for reviewed publication. |
| **Dockerfile build** | You have a hand-written `Dockerfile`. | Build and export an archive before deploying. |
| **Nixpacks build** | You have **no Dockerfile** and want one generated from source. | Build and export an archive before deploying. |

The mode is chosen in `nagare/Config.hs`, not by a CLI flag — illegal states are
made unrepresentable in the typed config, the same principle as the rest of the
[Config reference](config-reference.md). One runnable example per mode lives under
`cluster/examples/` (`prebuilt-image-app`, `dockerfile-app`, `nixpacks-app`).

> **What changed (migration note).** The `build` field is now part of
> `Deployment`. If you build a `Deployment` with the `webService` preset, you get
> a Dockerfile build (`Dockerfile`, context `.`, no build args) for free — no
> change needed. If you **hand-assemble a `Deployment` record literal**, add a
> `build` field: `build = ...` with one of the modes below, or import
> `Nagare.Dsl.Build (defaultBuild)` and write `build <- defaultBuild` in the
> `Either` block (`build = unsafe defaultBuild` in pure code). A config that omits
> `build` in its emitted JSON still loads (it defaults to a Dockerfile build), so
> older configs keep working.

---

## Prebuilt image

Deploy an image that already exists in a registry. Nothing is built or pushed;
the tag to deploy lives in the config. Useful for third-party images
(`ghcr.io/...`) and images an external CI pipeline already pushed.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "web" "ghcr.io/acme/web")
  tag  <- first show (mkTag "v1.2.3")
  Right (base {build = PrebuiltImage tag})

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

The reviewed live deploy requires a matching accepted OCI publication, even
when the image was built by an external CI pipeline.

**Gotchas.**
- The repository path (`image`) carries **no tag** — the tag is the argument to
  `PrebuiltImage`. The full reference the cluster sees is `image:tag`.
- The deploy timestamp tag (used by the build modes) is **ignored** for a
  prebuilt image; the config's tag wins.
- `--context`/`--dockerfile` are build-mode overrides; passing either with a
  prebuilt config is an error
  (`nagarectl: --context/--dockerfile cannot be used with a prebuilt-image config`).

---

## Dockerfile build

Build from a hand-written `Dockerfile` and push to the deployment's registry
path. `webService` already defaults to this mode; set `build` explicitly to
control the Dockerfile path, the build context, or build arguments.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "web" "web")
  df   <- first show (mkFilePathText "Dockerfile")
  ctx  <- first show (mkFilePathText ".")
  let args = Map.fromList [("SITE_MESSAGE", "hello from a build arg")]
  Right (base {build = DockerfileBuild {dockerfile = df, context = ctx, buildArgs = args}})

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

Prepare the archive with the required Dockerfile and nonsecret build arguments,
then publish it with `app image-plan`. Each `buildArgs` entry describes an
argument that the external build must supply; the reviewed deploy does not run
`docker build`.

Choose the Dockerfile and context in the external build. The reviewed deploy
refuses `--dockerfile` and `--build-context` because it uses the accepted image
archive rather than building from source.

**Gotchas.**
- Paths are validated: an absolute path or a `..`-escaping path is rejected.
- The default (from `webService`) is `Dockerfile`, context `.`, no build args.

---

## Nixpacks build (zero Dockerfile)

Build from source with **no Dockerfile** using
[Nixpacks](https://nixpacks.com), which inspects the source tree, detects the
language and framework (Go, Node, Python, Rust, …), and produces a runnable OCI
image. Publish its archive through the same reviewed image path as a Dockerfile build.

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Build (BuildSpec (..))
import Nagare.Dsl.Config (emitDeployment)
import Nagare.Dsl.Path (mkFilePathText)
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Types (Deployment (..))

deployment :: Either String Deployment
deployment = do
  base <- first show (webService "web" "web")
  ctx  <- first show (mkFilePathText ".")
  Right (base {build = NixpacksBuild {context = ctx, buildArgs = Map.empty}})

main :: IO ()
main = either (ioError . userError) emitDeployment deployment
```

Use Nixpacks while preparing the archive, then publish and deploy the accepted
image. The reviewed deploy does not run Nixpacks.

**Prerequisite:** Install `nixpacks` in the external build environment. The
reviewed deploy only consumes the published archive.

**Gotchas.**
- Your app must honor `$PORT` — Knative sets it to the container port. Most
  Nixpacks providers wire this up via the framework's conventional start command.
- `buildArgs` are passed to the build as **environment variables** (`--env`),
  Nixpacks' analogue of `--build-arg`.
- Run the external build from the app directory when the build context is `.`.

---

## Choosing a mode

- **No Dockerfile, want zero config?** → Nixpacks.
- **Have a Dockerfile, or need full control of the build?** → Dockerfile.
- **Image already built (CI / third-party)?** → Prebuilt.

The three `cluster/examples/` projects (`prebuilt-image-app`, `dockerfile-app`,
`nixpacks-app`) are copy-and-deploy starting points. For the typed surface, see
the [Config reference](config-reference.md#build-modes); for the deploy workflow,
[Deploying apps](deploying-apps.md).
