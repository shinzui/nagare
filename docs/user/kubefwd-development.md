---
type: Guide
title: "Using kubefwd for development"
description: "Reach cluster services from a development machine with kubefwd and the active Nagare context."
docId: DOC-19
tags: [development, kubefwd, kubernetes, networking]
generated:
  by: human:nadeem
  at: 2026-07-01T14:31:04Z
---

# Using kubefwd for development

> **Status:** 🟡 **Compatible, external tool.**
>
> Nagare does not install or manage `kubefwd`, but its internal service model is
> a good match for it. Use this workflow when one service is under active local
> development and the rest of its dependencies are already running on Nagare.

`kubefwd` bulk-forwards Kubernetes `Service`s to your workstation, assigns each
forwarded Service a loopback IP, and writes the Service names into `/etc/hosts`.
That lets a local process use the same hostnames a pod would use in the cluster.

The common Nagare use case is a local GraphQL server with deployed backing
services:

```text
local GraphQL server
  -> http://orders.personal.svc.cluster.local
  -> http://billing.personal.svc.cluster.local
  -> postgresql://...@pg-main.personal.svc.cluster.local:5432/...
  -> redis://cache.personal.svc.cluster.local:6379
```

This avoids booting every microservice locally while preserving the production
connection names in your config.

## What this is for

Use `kubefwd` for local development against internal dependencies:

- managed databases such as Postgres, Redis, and ClickHouse;
- Redpanda brokers and other ClusterIP services;
- Shomei, en, MinIO, Grafana, or other platform services;
- Nagare HTTP services when you want service-to-service traffic, not public
  ingress behavior.

Do not use `kubefwd` as a substitute for Nagare's public route:

- It does not test Kourier, wildcard DNS, Knative `DomainMapping`, cert-manager
  TLS, CDN routing, or `nagare-access`.
- It can bypass browser-facing auth if you call a protected app's backend
  Service directly.
- It should not be used to expose databases publicly; it is a local workstation
  development tunnel.

## Prerequisites

Install `kubefwd` on your workstation. On macOS this is usually:

```bash
brew install kubefwd
```

`kubefwd` needs permission to bind local loopback ports and edit `/etc/hosts`,
so it is normally run with `sudo -E`.

You also need a working `kubectl` context for the target cluster:

- **Local mode:** use the k3d context created by `just local-up`.
- **Cloud mode:** connect to the k3s API through Tailscale or the documented
  IAP/SSH tunnel first. If `kubectl get ns` cannot reach the cluster, `kubefwd`
  cannot either.

## Forward dependencies

Start with the namespace that holds your app dependencies:

```bash
sudo -E kubefwd svc -n personal
```

Forward platform services only when your local app calls them directly:

```bash
sudo -E kubefwd svc -n nagare-system
sudo -E kubefwd svc -n monitoring
sudo -E kubefwd svc -n tracing
```

Keep the `kubefwd` process running while you develop. It cleans up its
`/etc/hosts` entries when it exits cleanly.

In another shell, verify that service names resolve from the workstation:

```bash
curl http://orders.personal.svc.cluster.local
psql "postgresql://USER:PASSWORD@pg-main.personal.svc.cluster.local:5432/DB"
redis-cli -h cache.personal.svc.cluster.local -p 6379 ping
```

## Run one service locally

Point the local service at the same dependency hosts it would use in Nagare:

```bash
export ORDERS_URL=http://orders.personal.svc.cluster.local
export BILLING_URL=http://billing.personal.svc.cluster.local
export DATABASE_URL=postgresql://USER:PASSWORD@pg-main.personal.svc.cluster.local:5432/graphql
export REDIS_URL=redis://cache.personal.svc.cluster.local:6379

npm run dev
# or:
# cabal run graphql-server
# bun run dev
```

For a GraphQL gateway, this means resolvers can call deployed microservices while
the gateway process itself hot-reloads locally.

## Service names to use

Nagare deliberately uses ordinary Kubernetes service DNS for internal
dependencies.

Managed databases:

```text
<database>.<namespace>.svc.cluster.local:<port>
```

Examples:

```text
pg-main.personal.svc.cluster.local:5432
redis-main.personal.svc.cluster.local:6379
clickhouse-main.personal.svc.cluster.local:9000
```

Managed brokers:

```text
<broker>.<namespace>.svc.cluster.local:9092
```

Nagare HTTP apps and platform HTTP services:

```text
http://<service>.<namespace>.svc.cluster.local
```

Examples:

```text
http://orders.personal.svc.cluster.local
http://shomei.nagare-system.svc.cluster.local
http://en.nagare-system.svc.cluster.local
http://vmks-grafana.monitoring.svc.cluster.local
```

## Knative scale-to-zero

Nagare HTTP apps are Knative Services by default, and many are configured with
`minScale = 0`. That is good for the platform, but it can be awkward for
`kubefwd`: a forwarded Service may have no ready backend pod while it is scaled
to zero, and a direct service forward may not exercise the same activation path
as Kourier.

For dependencies you call frequently during local development, prefer a dev
overlay/config that keeps them warm:

```haskell
sc <- first show (mkScale 1 1)
```

or:

```haskell
sc <- first show (mkScale 1 3)
```

Then redeploy that dependency. Use `minScale = 0` again when you no longer need
it kept warm for local work.

If you do want to test scale-from-zero, use the public Nagare URL through
Kourier instead of the `kubefwd` path.

## Auth and protected apps

Calling a protected app's backend Service through `kubefwd` bypasses
`nagare-access`, because the request does not enter through the public
DomainMapping. That is useful for service-to-service debugging, but it does not
test browser login or en authorization.

Use these paths for different tests:

| Goal | Path |
| --- | --- |
| Local gateway calls deployed dependencies | `kubefwd` + `*.svc.cluster.local` |
| Browser login, cookies, Shomei/en grants | public Nagare host through `nagare-access` |
| TLS, DomainMapping, CDN, Kourier behavior | public Nagare host |
| Database/broker client development | `kubefwd` + internal service DNS |

## Cloud-mode connection

In cloud mode, Nagare's k3s API is intentionally not public. Before starting
`kubefwd`, establish the same API path used for normal `kubectl` work:

1. Connect through Tailscale, if the host is on your tailnet.
2. Otherwise use the IAP/SSH tunnel flow from
   [Accessing the host](accessing-the-host.md).
3. Confirm `kubectl get ns` succeeds from the workstation.
4. Start `sudo -E kubefwd svc -n <namespace>`.

The forwarding data path is then workstation -> Kubernetes API port-forward ->
pod. It is for development convenience, not load testing.

## Cleanup and troubleshooting

Stop `kubefwd` with Ctrl-C so it can remove its `/etc/hosts` entries. If the
process is killed and names continue resolving unexpectedly, inspect
`/etc/hosts` and remove stale `kubefwd` entries.

If a service name does not resolve, confirm the relevant namespace is being
forwarded and that the Service exists:

```bash
kubectl -n personal get svc
```

If a forwarded HTTP service returns connection errors, check whether the Knative
Service is scaled to zero:

```bash
kubectl -n personal get ksvc
kubectl -n personal get pods
```

If ports below 1024 fail to bind, make sure `kubefwd` is running with the needed
privileges. On macOS and Linux, `sudo -E kubefwd ...` is the usual path.
