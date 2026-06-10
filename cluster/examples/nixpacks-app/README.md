# nixpacks-app — Nixpacks build mode (zero Dockerfile)

Builds the container image **from source with no Dockerfile** using
[Nixpacks](https://nixpacks.com), then pushes it to
`us-west1-docker.pkg.dev/tan-nb-exp/nagare/nixpacks-app`.

This directory holds only a tiny Node app (`package.json` + `server.js`) — there
is no `Dockerfile`. Nixpacks inspects the source, detects Node, and produces a
runnable OCI image. The same path works for Go, Python, and Rust apps detected
from their manifest files.

## Prerequisite

The `nixpacks` CLI must be on your `PATH` and the Docker daemon must be running
(Nixpacks builds through Docker/BuildKit). Install it from
<https://nixpacks.com/docs/install>, or, in a Nix environment,
`nix-shell -p nixpacks`. If `nixpacks` is missing, `nagarectl deploy` stops with:

```text
nagare: nixpacks not found on PATH; see docs/user/build-modes.md
```

## Deploy

```bash
# Dry-run (no nixpacks or cluster needed): see the planned build action.
nagarectl deploy -f cluster/examples/nixpacks-app/nagare/Config.hs --dry-run
```

Expected:

```text
Build mode: nixpacks build .
```

A real `nagarectl deploy` (run from this directory so the build context `.` is
this app) runs `nixpacks build .`, pushes the image, and waits for the Knative
Service to become Ready. The app honors `$PORT`, which Knative sets to the
container port.

See [build modes](../../../docs/user/build-modes.md) for the full guide.
