---
okf_version: "0.2"
---

# Nagare terminology

This catalog defines Nagare vocabulary for developers and operators. Start with [target context](target-context.md), [typed app config](typed-app-config.md), and [deployment](deployment.md). The linked guides give configuration and operating steps.

## Platform and targets

- [cloud mode](cloud-mode.md) - The Nagare operating mode that provisions a GCP VM and uses its NixOS and k3s platform.
- [cluster bootstrap](cluster-bootstrap.md) - The installation and configuration of Nagare services on an existing k3s or k3d cluster.
- [context guard](context-guard.md) - A preflight check that refuses cloud mutations when the active context, credentials, stack, or project disagree.
- [host flake](host-flake.md) - A context-owned Nix flake that defines the NixOS configuration for a Nagare host.
- [local mode](local-mode.md) - The Nagare operating mode that runs the application platform on k3d with a local registry and MinIO.
- [Nagare](nagare.md) - A single-node personal application platform that deploys and operates projects on a cloud or local Kubernetes cluster.
- [operator package](operator-package.md) - The Nagare Nix output that includes the CLI, immutable platform payload, recipe launcher, and operator tooling.
- [platform identity](platform-identity.md) - The set of release versions reported by the CLI, payload, context, host, and cluster for compatibility checks.
- [Pulumi stack](pulumi-stack.md) - The per-context Pulumi state and configuration used to manage Nagare cloud resources.
- [release payload](release-payload.md) - The immutable platform files packaged with a versioned Nagare release for operator recipes.
- [target context](target-context.md) - A named set of settings that selects the Nagare project, cluster, domain, registry, and operating mode for a command.

## Applications and delivery

- [multi-workload application](multi-workload-application.md) - A typed application declaration that groups related workloads and services for one coordinated deploy.
- [build mode](build-mode.md) - The rule Nagare uses to obtain the container image deployed for an application.
- [CDN origin](cdn-origin.md) - The Nagare hostname or service to which an edge cache forwards requests it cannot serve itself.
- [deployment](deployment.md) - A Nagare declaration of an HTTP application that renders to a Knative Service.
- [domain mapping](domain-mapping.md) - The Knative resource that routes an optional public hostname to a Nagare service.
- [Knative Service](knative-service.md) - The request-serving Kubernetes resource Nagare creates for an HTTP app or site.
- [preview deployment](preview-deployment.md) - An isolated static-site deployment used to inspect a proposed change before replacing the main site.
- [server site](server-site.md) - A Nagare site whose framework build runs as an origin server inside a Node.js image.
- [static site](static-site.md) - A Nagare site whose built files are served from a small Nginx image.
- [typed app config](typed-app-config.md) - An application-authored Haskell configuration file that emits a validated Nagare workload declaration.

## Background work

- [one-shot job](one-shot-job.md) - A finite Nagare workload declared for a single bounded execution without a recurring schedule.
- [scheduled task](scheduled-task.md) - A named finite workload that Nagare runs on a cron schedule or on demand.
- [task app association](task-app-association.md) - The optional link that lets a scheduled task inherit a deployed app image and runtime environment.
- [worker](worker.md) - A continuously running Nagare workload with a fixed replica count and no HTTP ingress.

## Data and recovery

- [app volume](app-volume.md) - A durable disk mounted at a declared path in a Nagare app container.
- [backup store](backup-store.md) - The context-selected object store that holds Nagare database backups and volume snapshots.
- [broker topic](broker-topic.md) - A named message stream inside a Nagare messaging broker.
- [managed database](managed-database.md) - A Nagare-operated single-replica database with typed configuration, persistent storage, and an internal service address.
- [managed database credential](managed-database-credential.md) - A generated Kubernetes Secret that holds a managed database password and connection URL.
- [messaging broker](messaging-broker.md) - A Nagare-operated stateful process that hosts named Kafka-compatible topics for application messages.
- [Nix binary cache](nix-binary-cache.md) - An optional context-local service that distributes signed prebuilt Nix store closures to opted-in jobs.
- [persistent volume claim](persistent-volume-claim.md) - The Kubernetes request for durable storage backing a Nagare app volume or stateful service.
- [retention policy](retention-policy.md) - The rule deciding whether a workload data disk is kept or deleted when its owning resource is removed.
- [volume snapshot](volume-snapshot.md) - An object-store copy of an app volume used for later restore.

## Security and operations

- [ACME identity](acme-identity.md) - The contact address and certificate authority endpoint a context uses for automated TLS issuance.
- [auth portal](auth-portal.md) - The operator-owned sign-in entry point for Nagare sites protected by identity-aware access.
- [inventory candidate](inventory-candidate.md) - A digest-bound proposed resource inventory produced by composing declared scopes and explicit changes.
- [managed secret](managed-secret.md) - An app-scoped secret value stored in Kubernetes and injected into a workload by reference.
- [observability stack](observability-stack.md) - The Nagare services that collect and display metrics, logs, and traces from the platform and apps.
- [replacement cutover](replacement-cutover.md) - A guarded upgrade that moves service from an old host to a separately prepared candidate host.
- [resource inventory](resource-inventory.md) - A typed declaration of managed resource identities, ownership, dependencies, and lifecycle intent across scopes.
