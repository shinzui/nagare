---
okf_version: "0.2"
---

# Explanation

- [Build modes](build-modes.md) - Understand Nagare prebuilt-image, Dockerfile, and Nixpacks build modes and choose the right mode for an application.

# Guide

- [Accessing the host](accessing-the-host.md) - Reach a Nagare host through Tailscale SSH or an IAP break-glass tunnel and obtain cluster access.
- [CDN (edge caching)](cdn.md) - Configure and operate edge caching for Nagare applications through the supported CDN workflow.
- [Target contexts](contexts.md) - Create, select, inspect, migrate, and troubleshoot named Nagare target contexts.
- [Deploying apps](deploying-apps.md) - Define, deploy, verify, and operate applications on Nagare with the typed configuration model and nagarectl.
- [Environment and secrets](env-and-secrets.md) - Configure scoped application environment variables and secrets, including imports, overlays, and build-time values.
- [GCP prerequisites](gcp-prerequisites.md) - Prepare authentication, billing, IAM, service APIs, and DNS before provisioning Nagare on Google Cloud.
- [Installing Nagare](installation.md) - Install, select, upgrade, and remove released Nagare commands with Nix.
- [Using kubefwd for development](kubefwd-development.md) - Reach cluster services from a development machine with kubefwd and the active Nagare context.
- [Managed databases](managed-databases.md) - Declare, provision, connect, back up, restore, and operate Nagare-managed databases.
- [Messaging brokers](messaging-brokers.md) - Provision, bind, size, observe, and operate Kafka-compatible messaging brokers on Nagare.
- [Observability](observability.md) - Install, access, emit to, and verify Nagare metrics, logs, traces, and Grafana dashboards.
- [Bounded one-shot jobs](one-shot-jobs.md) - Define, run, observe, and safely constrain deadline-bounded one-shot jobs on Nagare.
- [Persistent storage](persistent-storage.md) - Declare, deploy, back up, restore, and operate persistent application volumes on Nagare.
- [Protecting observability UIs](protecting-observability-uis.md) - Expose Nagare observability interfaces behind identity-aware access and remove unsafe public access.
- [Scheduled tasks](scheduled-tasks.md) - Declare, deploy, run, observe, and troubleshoot scheduled application tasks on Nagare.
- [Static & full-stack site hosting](static-hosting.md) - Configure, deploy, release, preview, and troubleshoot static and full-stack sites on Nagare.
- [Running workers](workers.md) - Define, deploy, observe, scale, pause, and test long-running worker workloads on Nagare.

# Navigation

- [Nagare operator guide](README.md) - Route operators and developers through Nagare setup, deployment, platform operations, and reference documentation.

# Reference

- [App lifecycle](app-lifecycle.md) - Look up Nagare application inspection, logging, restart, stop, deletion, and deployment-history operations.
- [Config reference](config-reference.md) - Look up the typed Nagare application configuration model, fields, defaults, and rendering behavior.
- [Reference](reference.md) - Look up Nagare identifiers, context variables, commands, infrastructure contracts, ports, paths, and operational interfaces.
- [Troubleshooting](troubleshooting.md) - Diagnose and resolve known Nagare host, cluster, networking, backup, broker, and deployment failures by symptom.

# Runbook

- [Identity-aware access](access.md) - Configure, verify, operate, and revoke identity-aware access to protected Nagare services.
- [Backups and disaster recovery](backups-and-disaster-recovery.md) - Back up Nagare state, recover platform and workload data, and drill the documented failure procedures safely.
- [Cluster bootstrap](cluster-bootstrap.md) - Install, configure, smoke-test, and verify the Nagare Kubernetes platform components.
- [Day-2 host changes](day-2-host-changes.md) - Apply, verify, and recover from routine Nagare host configuration changes after initial provisioning.
- [Forge credentials](forge-credentials.md) - Provision, install, rotate, verify, and recover Nagare forge credentials without storing long-lived tokens.
- [Host image and first boot](host-image-and-boot.md) - Build and register the Nagare NixOS image, boot the VM, and verify the first host startup.
- [Provisioning with Pulumi](provisioning-with-pulumi.md) - Configure, preview, apply, verify, and recover Nagare cloud infrastructure managed by Pulumi.
- [Resizing the VM (vertical scale)](resizing-the-vm.md) - Resize the Nagare virtual machine safely, verify retained state, and roll back an unsuitable machine type.
- [Secrets](secrets.md) - Set up, edit, rotate, and recover Nagare host, application, and cluster-bootstrap secrets safely.
- [Upgrades](upgrades.md) - Plan, apply, verify, and roll back Nagare platform, host, cluster, and observability upgrades.

# Tutorial

- [Getting started](getting-started.md) - Install Nagare, choose a target, and complete an initial working deployment.
- [Local development](local-development.md) - Create a local Nagare platform, deploy a sample workload, and exercise the development and smoke-test workflow.
- [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md) - Onboard a new Google Cloud project and complete the first Nagare platform setup from prerequisites through verification.
