---
type: Improvement Request
title: Add a command that packages a StaticSite's image for reviewed publication
description: Let an operator turn a StaticSite's typed config and output directory into the build context or Docker archive a static release uses, so app image-plan can publish it without hand-copying Nagare's Nginx renderer and Dockerfile.
timestamp: "2026-10-29T14:19:15Z"
generated:
  by: process:claude-code
  at: "2026-10-22T19:09:06Z"
requestId: IR-36
status: accepted
acceptedAt: "2026-10-29T14:19:15Z"
targetPlan: docs/plans/222-package-and-publish-static-site-updates-through-a-fast-repeatable-workflow.md
origin: mori://shinzui/tan-os
acceptanceCriteria:
  - id: AC-1
    statement: A nagarectl command given a StaticSite config and its output directory writes the static release build context, the Dockerfile from Nagare.Static.Image.staticDockerfile, nginx.conf from renderNginxConfig and site/ with the output's contents, to a directory the operator names.
    verification: A test packages cluster/examples/protected-static-site and compares Dockerfile and nginx.conf byte for byte with staticDockerfile and renderNginxConfig for the loaded site, and site/ with the example's public/ directory.
  - id: AC-2
    statement: The same command can instead write a linux/amd64 Docker archive tagged with the context registry reference for the config's image and the given tag, which app image-plan --archive accepts unchanged.
    verification: The site-access drill (scripts/site-access-drill.sh) replaces its runghc render and printf Dockerfile steps with the command, then passes unchanged from image publication through rollback.
  - id: AC-3
    statement: The command loads the config with the typed-config GHC nagarectl already uses, so it works from an operator shell whose own runghc cannot import Nagare.Dsl, and it contacts no cluster, registry or inventory store.
    verification: Run it in the clone-free external-config check (nix/checks/scripts/nagarectl-external-config.sh) with GHC_ENVIRONMENT and NAGARE_GHC_ENVIRONMENT unset, and assert no kubectl, gcloud or registry command was invoked.
  - id: AC-4
    statement: docs/user/static-hosting.md shows how to produce the archive that its reviewed deploy commands require.
    verification: The guide's static-site section runs end to end on a local context following only its own commands.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-22T19:09:06Z"
    document_timestamp: "2026-10-22T19:09:06Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against nagarectl's site command, Nagare.Static.Image,
      Nagare.Static.Build, the site-access drill and docs/user/static-hosting.md at
      v0.9.0 and at ee0587a4; no independent verification attestation is claimed.
---

# Add a command that packages a StaticSite's image for reviewed publication

**Status:** accepted for implementation in
[ExecPlan 222](../plans/222-package-and-publish-static-site-updates-through-a-fast-repeatable-workflow.md).
The plan covers packaging, repeat publication, recovery, and timing validation; implementation has not started.

**Authored by:** a `claude-code` session planning
`mori://shinzui/tan-os/plans/77-deploy-the-network-explorer-to-the-labs-intranet-as-a-login-protected-static-site`
with the tan-os `exec-plan` skill (`mori://shinzui/tan-os`, project-relative
`agents/skills/exec-plan/SKILL.md`; artifact-level URI pending).
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-22.


## Context

The work intranet (`mori://tan/tan-ng-labs`, on v0.9.0) is adding its first protected
`StaticSite`: a one-file page served at `network-explorer.labs.topagentnetwork.net` with
`access = Just requireLogin`. ADR 29 made that possible for every web kind.

The reviewed deploy needs an image that is already published. `nagarectl site deploy` without
`--skip-build` stops with `reviewed site deployment requires --skip-build`
(`cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`). `docs/user/static-hosting.md` then says to
"publish the exact site image archive with `app image-plan`", but no command produces that
archive or its build context.

The pieces exist in the library. `Nagare.Static.Image.withStaticImageContext` writes the build
context: `Dockerfile` from `staticDockerfile`, `nginx.conf` from `renderNginxConfig`, and `site/`.
`Nagare.Static.Build.prepareStaticOutput` prepares the output directory. Neither has a caller
under `cli/nagarectl/app` or `cli/nagarectl/src` at v0.9.0 or at `ee0587a4`.

Nagare's own site-access drill does the packaging by hand (`scripts/site-access-drill.sh`, step 6).
It runs the config with `runghc`, pipes the JSON through `scripts/lib/render-static-nginx.hs`,
and writes the Dockerfile with `printf`, commented "`Nagare.Static.Image.staticDockerfile`,
verbatim".

An operator repository has to do the same, and one step is harder there. The tan-ng-labs shell
gets `nagarectl` from the release flake, but its `runghc` cannot import the DSL:

```text
nagare/Config.hs:13:1: error: [GHC-87110]
    Could not find module ‘Nagare.Dsl.Access’.
```

The only GHC with `nagare-dsl` is the `typedConfigRuntime` that the `nagarectl` wrapper prepends
to its own `PATH`. The flake does not export it as a package. The tan-os plan's build script
recovers it by reading the inner wrapper script and extracting the
`/nix/store/…-ghc-9.12.4-with-packages/bin` directory, then copies the drill's renderer and the
Dockerfile text. That works on v0.9.0. It will break whenever the wrapper's layout changes, and
the copied Dockerfile drifts silently if `staticDockerfile` changes.


## Requested change

Add a `nagarectl` command, for example `nagarectl site package`, that takes the same `--file`,
`--project-dir` and `--ghc-env` options as `site deploy` and packages a `StaticSite`:

- `--context-out DIR` writes the build context exactly as `withStaticImageContext` lays it out,
  leaving the build to whatever OCI builder the operator uses.
- `--archive FILE --tag TAG` builds that context for linux/amd64 and writes a Docker archive
  tagged with the context registry reference, ready for `app image-plan --archive`.

The command reads the config and the output directory only. It needs no kubeconfig, registry
credentials or inventory store. With it, an operator's release becomes two steps: package, then
`app image-plan` and `site deploy --skip-build`. The drill's step 6 can use it as well.

This request does not ask which builder `--archive` should use. Today `app image-plan
--build-dockerfile` calls `docker build`, and IR-6 proposes Apple Container for the local
cluster. `--context-out` alone would remove the copied renderer and the wrapper lookup from the
operator repository, and would be enough to close this request if the archive mode needs a
builder decision first. Whether `ServerSite` needs the same command was not checked.
