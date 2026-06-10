# EP-21 Nixpacks feasibility spike

Date: 2026-06-09
Plan: `docs/plans/21-nixpacks-zero-dockerfile-builder.md` (Milestone 1)

## Goal

Prove that `nixpacks` can build a Dockerfile-free app into an OCI image that runs
and serves traffic on its port, before wiring `nixpacks` into `nagarectl`.

## Setup

- Host: macOS (aarch64-darwin).
- `nixpacks` **1.41.0**, obtained from nixpkgs via `nix-shell -p nixpacks`
  (no `nixpacks` was on `PATH` otherwise).
- Docker daemon **running** and required — `nixpacks build` drives BuildKit
  through the Docker daemon (`docker.io/library/...` exporter in the build log).
- Sample app: a throwaway Node HTTP server with **no Dockerfile**, just a
  `package.json` (with a `start` script) and a `server.js` that listens on
  `process.env.PORT || 8080` and replies `Hello from a Dockerfile-free app`.

## Invocation

```bash
nixpacks build . --name nixpacks-spike:local        # builds + locally tags, no push
docker run --rm -d -p 8080:8080 nixpacks-spike:local
curl -fsS localhost:8080                            # -> Hello from a Dockerfile-free app
```

## Findings

- **It works.** The image built, ran, and served the expected body on 8080.
- **Port:** Nixpacks does not hard-code a port. The Node provider runs the
  `package.json` `start` script (`node server.js`), and the app binds whatever
  `$PORT` says (default 8080). This composes well with Knative, which injects
  `PORT` = the container port — so a Nixpacks image listens on the right port
  with no extra configuration, provided the app honors `$PORT`.
- **Start command:** taken from the `start` script in `package.json` for Node.
  Other ecosystems (Go, Python, Rust) are auto-detected from their manifest files
  (`go.mod`, `requirements.txt`/`pyproject.toml`, `Cargo.toml`).
- **`--name image:tag`** builds and **locally tags** the image; it does **not**
  push. This is exactly the contract `Nagare.Build.performBuild` needs: build/tag
  `ref`, then let `runDeploy` call the existing `pushImage ref`.
- **`--env KEY=VALUE`** passes build-time environment variables — the analogue of
  a Dockerfile `--build-arg`, and the mapping chosen for `NixpacksBuild.buildArgs`.
- One harmless BuildKit warning (`UndefinedVar: $NIXPACKS_PATH`); the build
  succeeds regardless.

## Recommended CLI invocation

```
nixpacks build <context> --name <ref> [--env K=V ...]
```

which is what `Nagare.Image.nixpacksBuildArgs`/`buildNixpacks` implement
(Milestone 2). No blocker found; proceed with the CLI wiring.

## Cleanup

The sample dir, the `nixpacks-spike:local` image, and any provider cache are
throwaway: `docker rmi nixpacks-spike:local` and delete the sample dir.
