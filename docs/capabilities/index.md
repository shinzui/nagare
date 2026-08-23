---
okf_version: "0.2"
---

# Nagare capabilities

This bundle catalogs what Nagare provides today to someone standing up or using the platform.
Every record names a mechanism a consumer can adopt and verify independently, carries a stable
`CAP-N` handle, and points to evidence in this repository.

Nagare has no release tags. Every capability is therefore `unreleased`, and every compatibility
promise is `experimental`. `shipped` means the implementation exists on the default branch; it does
not erase the live-verification limits recorded on individual pages.

## What is deliberately excluded

- Planned roadmap items and incomplete follow-ups are not capabilities. They remain in ExecPlans,
  MasterPlans, or the improvement-request bundle.
- A command is not automatically a capability. Subcommands that operate one mechanism are grouped
  into one record.
- Outcomes that only become true when other repositories cooperate are not claimed here. For
  example, the access record covers Nagare's forward-auth enforcement and route wiring, not the
  separate identity and authorization services it consumes.
- Tests, examples, and smoke harnesses are evidence for capabilities, not capabilities themselves.

## Catalog

| Handle | Capability | Packages or deployables |
|---|---|---|
| [CAP-1](target-contexts-and-onboarding.md) | Target contexts and project onboarding | `nagarectl` |
| [CAP-2](single-node-gcp-substrate.md) | Single-node GCP substrate | `infra-pulumi`, `nixos-hosts` |
| [CAP-3](local-platform-substrate.md) | Local platform substrate | `cluster-bootstrap`, `nagarectl` |
| [CAP-4](knative-serving-ingress-and-tls.md) | Knative serving, ingress, and TLS bootstrap | `cluster-bootstrap` |
| [CAP-5](victoria-observability-stack.md) | Victoria observability stack | `cluster-observability` |
| [CAP-6](typed-application-deployment.md) | Typed application deployment | `nagare-dsl`, `nagarectl` |
| [CAP-7](multi-workload-application-rollouts.md) | Multi-workload application rollouts | `nagare-dsl`, `nagarectl` |
| [CAP-8](static-and-full-stack-sites.md) | Static and full-stack site releases | `nagare-dsl`, `nagarectl` |
| [CAP-9](scoped-environment-and-secrets.md) | Scoped environment and secret management | `nagare-dsl`, `nagarectl` |
| [CAP-10](application-lifecycle-and-operations.md) | Application lifecycle and platform operations | `nagarectl` |
| [CAP-11](persistent-volume-snapshots.md) | Persistent application volumes and snapshots | `nagare-dsl`, `nagarectl` |
| [CAP-12](managed-databases-and-backups.md) | Managed databases and backups | `nagare-dsl`, `nagarectl` |
| [CAP-13](scheduled-tasks.md) | Scheduled and on-demand tasks | `nagare-dsl`, `nagarectl` |
| [CAP-14](long-running-workers.md) | Long-running workers | `nagare-dsl`, `nagarectl` |
| [CAP-15](kafka-compatible-brokers.md) | Kafka-compatible brokers | `nagare-dsl`, `nagarectl` |
| [CAP-16](bounded-one-shot-jobs.md) | Bounded one-shot Jobs | `nagare-dsl`, `cluster-bootstrap` |
| [CAP-17](edge-cdn-management.md) | Edge CDN management | `nagare-dsl`, `nagarectl`, `infra-pulumi` |
| [CAP-18](forward-auth-route-enforcement.md) | Forward-auth route enforcement | `nagare-access`, `nagarectl` |

## Validation

```sh
mori validate
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
```

The profile is the released `coordination.capabilities` descriptor at
`mori://shinzui/okf-profiles/profiles/capabilities` (profile version v0.9.0), pinned by Dhall
semantic hash.
