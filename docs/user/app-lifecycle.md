---
type: Reference
title: "App lifecycle"
description: "Look up Nagare application inspection, logging, restart, stop, deletion, and deployment-history operations."
docId: DOC-4
tags: [applications, lifecycle, nagarectl, operations]
generated:
  by: human:nadeem
  at: 2026-06-10T04:02:47Z
---

# App lifecycle

> **Status:** 🟡 **Built, not yet exercised against the live cluster.**
>
> The `app` and `deployments` commands are implemented and unit-tested, and the
> example config renders end-to-end with `nagarectl deploy --dry-run`. The *live*
> verbs (`list`/`get`/`logs`/`restart`/`stop`/`delete`) read and patch real
> Knative state, so their transcripts below are the intended behaviour until
> `nagare-01` is back up. The flags and output shapes are exact.

This page is for the **operator of an already-deployed app**. [Deploying
apps](deploying-apps.md) gets you to a running HTTPS service with one command;
this page is everything *after* that first deploy — list what you have, inspect
one, tail its logs, roll a fresh revision, take it offline, delete it, and read
its deployment history — all from `nagarectl`, without `kubectl`.

Everything here works against the bundled
[`app-lifecycle-demo`](../../cluster/examples/app-lifecycle-demo/) example, whose
config declares a health check, resource limits, and two domains.

---

## Commands at a glance

```text
nagarectl app list [-n NS] [--all]                    # Nagare-managed apps in a namespace
nagarectl app get NAME [-n NS] [-f FILE]              # one app's image, revision, URL, readiness
nagarectl app logs NAME [--follow] [--tail N] [-n NS] # tail the running container's logs
nagarectl app restart NAME [-n NS]                    # roll a fresh revision (also un-stops)
nagarectl app stop NAME [-n NS]                       # take the app offline, recoverably
nagarectl app delete NAME [-n NS] [-f FILE]           # remove Service, DomainMappings, history

nagarectl deployments list NAME [-n NS]               # deployment history, newest first
nagarectl deployments logs NAME [ID] [--follow]       # logs for the live or a past deployment
```

The namespace defaults to `personal` everywhere; pass `-n/--namespace` to target
another. `NAME` is the Knative Service name — the `name` in your `nagare/Config.hs`.

## Listing and inspecting

`app list` shows the apps Nagare manages in a namespace. It finds them by the
`nagare.dev/managed-by: nagarectl` label the renderer stamps on every app
Service, so static sites and other Knative Services are excluded:

```bash
nagarectl app list
```

```text
  NAME              READY   URL
  lifecycle-demo    True    https://demo.example.com
  notes             True    https://notes.personal.apps.example.com
```

Pass `--all` to drop the label filter and list *every* Knative Service in the
namespace (useful to spot a Service that wasn't deployed through Nagare). When
the managed list is empty, `app list` says so and hints at `--all`:

```text
(no Nagare-managed apps; pass --all to list every Knative Service)
```

`app get NAME` describes one app. The first block is live Knative state; if a
readable `nagare/Config.hs` is present (or pointed at with `-f`), the output is
enriched with the config's declared domains, health check, and resource limits:

```bash
nagarectl app get lifecycle-demo
```

```text
Name:     lifecycle-demo
Ready:    True
URL:      https://demo.example.com
Revision: lifecycle-demo-00001
Image:    us-west1-docker.pkg.dev/tan-nb-exp/nagare/lifecycle-demo:20260602-120000
Domains:  demo.example.com (canonical), www.demo.example.com
Health:   /healthz (HTTP)
Limits:   cpu 500m, memory 512Mi
```

The `Domains`/`Health`/`Limits` lines appear only when the config declares them;
run `app get` from a different directory (no config in reach) and you get just
the five live-state lines.

## Logs

`app logs NAME` streams the running container's logs (the Knative
`user-container`). By default it prints the last 200 lines and exits:

```bash
nagarectl app logs lifecycle-demo            # last 200 lines, then exit
nagarectl app logs lifecycle-demo --tail 50  # last 50 lines, then exit
nagarectl app logs lifecycle-demo --follow   # stream until you Ctrl-C
```

`--follow` tails live and ignores `--tail`. This shows logs for whichever
revision is currently serving; to read a *specific past* deployment's logs, use
`deployments logs NAME ID` below.

## Restart, stop, delete

**`app restart NAME`** rolls a fresh revision by stamping the Service template, then
waits for the new revision to become Ready:

```bash
nagarectl app restart lifecycle-demo
```

```text
Restarted: lifecycle-demo
```

**`app stop NAME`** takes the app offline *recoverably*. Knative has no native
"pause", so `stop` labels the Service `networking.knative.dev/visibility:
cluster-local`, which removes its public route — the app stops answering on its
URL but its history and config are untouched:

```bash
nagarectl app stop lifecycle-demo
```

```text
Stopped lifecycle-demo (run 'nagarectl deploy' or 'nagarectl app restart lifecycle-demo' to restore public serving)
```

Bring it back with either `nagarectl deploy` (a fresh deploy) or `nagarectl app
restart lifecycle-demo` — `restart` also clears the cluster-local label, so the
public route returns.

**`app delete NAME`** is permanent. It removes the Service, each of its
DomainMappings, and its deployment-history ConfigMap. Domains come from the
config when a readable `nagare/Config.hs` is in reach (or `-f FILE`); otherwise
they're discovered by querying the cluster for DomainMappings that point at the
Service:

```bash
nagarectl app delete lifecycle-demo
```

```text
Deleted lifecycle-demo
```

Every underlying `kubectl delete` uses `--ignore-not-found`, so re-running
`app delete` on an already-gone app is a clean no-op.

## Deployment history

Every successful `nagarectl deploy` records a deployment in a per-app ConfigMap
(`nagare-app-deployments-<app>`), exactly like the static-site release log. Tag
each deploy with provenance using `--source`:

```bash
nagarectl deploy --source "$(git rev-parse --short HEAD)"
```

**`deployments list NAME`** prints the history newest-first, with the live
deployment starred (`*`):

```bash
nagarectl deployments list lifecycle-demo
```

```text
  RELEASE ID        CREATED                SOURCE      URL
* 20260602-120000   2026-06-09 18:30:02.41 a1b9f4c     https://demo.example.com
  20260601-091500   2026-06-08 14:05:11.83 9d2c0a7     https://demo.example.com
```

The `RELEASE ID` is the image tag the deploy used (also surfaced to the
container as `NAGARE_RELEASE_ID`); `SOURCE` is whatever you passed to `--source`,
or `-` if you passed nothing.

**`deployments logs NAME [ID]`** streams logs for a deployment. With no id it
follows the same path as `app logs` — the live revision. With an id, it maps that
deployment's image tag to the Knative revision that carries it and streams that
revision's logs:

```bash
nagarectl deployments logs lifecycle-demo                   # the live deployment
nagarectl deployments logs lifecycle-demo 20260601-091500   # a specific past one
```

If a past deployment's pods have already been garbage-collected by Knative,
there's no revision left to read and the command says so plainly:

```text
nagarectl: no live revision for deployment 20260601-091500 (its pods may have been garbage-collected; try 'nagarectl deployments logs lifecycle-demo' for the live deployment)
```

> A deploy of a **prebuilt image** records the deployment under that image's tag,
> so `deployments logs <id>` for it reports "no live revision" — the running
> container carries the prebuilt tag, not the deploy id.

## How it works

A handful of conventions tie this together; you rarely need them, but they
explain the behavior:

- **Apps are Knative Services** labeled `nagare.dev/managed-by: nagarectl`. That
  label is what `app list` filters on and what distinguishes a Nagare app from any
  other Service in the namespace.
- **Logs come from the `user-container`**, selected by the
  `serving.knative.dev/service=<name>` pod label (plus
  `serving.knative.dev/revision=<rev>` when a specific deployment is requested).
- **History lives in a per-app ConfigMap** named `nagare-app-deployments-<app>`,
  storing the newest 50 deployments as JSON. `app delete` removes it along with
  the Service.

For the platform identifiers and registry path these commands assume, see
[Reference](reference.md). For the config fields (`healthCheck`, resource limits,
multiple `domains`) the demo app uses, see
[Config reference](config-reference.md).
