# Build modes

> **Status:** 🟡 **Built and tested.** The typed model, the CLI dispatch, and the
> Nixpacks builder are implemented and unit-tested; `nagarectl deploy --dry-run`
> shows the planned build for each mode today. Build/push is target-aware:
> Artifact Registry in cloud mode, the k3d registry in local mode.

Every `Deployment` carries a typed `build` field that says **how** its container
image is produced. There are three modes:

| Mode | Use when | Builds locally? |
| --- | --- | --- |
| **Prebuilt image** | The image already exists in a registry (a third-party image, or one your CI built). | No — deploys it directly. |
| **Dockerfile build** | You have a hand-written `Dockerfile`. | Yes — `docker build`, then push. |
| **Nixpacks build** | You have **no Dockerfile** and want one auto-generated from source. | Yes — `nixpacks build`, then push. |

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

Deploy:

```bash
nagarectl deploy -f nagare/Config.hs --dry-run
```

```text
        image: ghcr.io/acme/web:v1.2.3
Build mode: prebuilt image (no local build), tag v1.2.3
```

A real deploy applies the Knative Service referencing the upstream image — no
`docker build`, no `docker push`.

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

Deploy:

```bash
nagarectl deploy -f nagare/Config.hs --dry-run
```

```text
Build mode: docker build -f Dockerfile .
```

A real deploy runs `docker build -f Dockerfile -t <ref> --build-arg
SITE_MESSAGE=... .`, pushes, and waits for Ready. Each `buildArgs` entry becomes
one `--build-arg KEY=VALUE`, in sorted-key order.

**Overrides.** The Dockerfile path and context can be overridden on the command
line — handy for building one service out of a monorepo subdirectory. The flags
win over the config:

| Flag | Overrides |
| --- | --- |
| `--dockerfile FILE` | the `dockerfile` field |
| `-c, --build-context DIR` | the `context` field |

```bash
nagarectl deploy --dockerfile docker/Dockerfile.prod --build-context services/web
```

**Gotchas.**
- Paths are validated: an absolute path or a `..`-escaping path is rejected.
- The default (from `webService`) is `Dockerfile`, context `.`, no build args.

---

## Nixpacks build (zero Dockerfile)

Build from source with **no Dockerfile** using
[Nixpacks](https://nixpacks.com), which inspects the source tree, detects the
language and framework (Go, Node, Python, Rust, …), and produces a runnable OCI
image. Nagare pushes and deploys it exactly like the Dockerfile path.

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

Deploy:

```bash
nagarectl deploy -f nagare/Config.hs --dry-run
```

```text
Build mode: nixpacks build .
```

A real deploy runs `nixpacks build .` (build args become `--env KEY=VALUE`),
pushes the image, and waits for Ready.

**Prerequisite: install `nixpacks`.** The build runs wherever you run
`nagarectl deploy` (your machine), so `nixpacks` must be on your `PATH` and the
Docker daemon must be running (Nixpacks builds through Docker/BuildKit). Install
it from <https://nixpacks.com/docs/install>, or in a Nix environment use
`nix-shell -p nixpacks`. If it is missing, the deploy stops with an actionable
message instead of a raw shell error:

```text
nagare: nixpacks not found on PATH; see docs/user/build-modes.md
```

**Gotchas.**
- Your app must honor `$PORT` — Knative sets it to the container port. Most
  Nixpacks providers wire this up via the framework's conventional start command.
- `buildArgs` are passed to the build as **environment variables** (`--env`),
  Nixpacks' analogue of `--build-arg`.
- Run the deploy from the app directory so the build context `.` is the app.

---

## Choosing a mode

- **No Dockerfile, want zero config?** → Nixpacks.
- **Have a Dockerfile, or need full control of the build?** → Dockerfile.
- **Image already built (CI / third-party)?** → Prebuilt.

The three `cluster/examples/` projects (`prebuilt-image-app`, `dockerfile-app`,
`nixpacks-app`) are copy-and-deploy starting points. For the typed surface, see
the [Config reference](config-reference.md#build-modes); for the deploy workflow,
[Deploying apps](deploying-apps.md).
