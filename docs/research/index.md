---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Research Document

- [Agent Substrate on Nagare as an execution platform for Shikigami](agent-substrate-on-nagare-for-shikigami.md) - Assess the host, Kubernetes, storage, security, lifecycle, and application integration needed to run Agent Substrate on Nagare and provide governed resumable workspaces for Shikigami.
- [Kubernetes API semantics for inventory proofs](kubernetes-api-semantics-for-inventory-proofs.md) - First-principles, experiment-validated semantics of the Kubernetes kinds in MP-23 release line (b), the ADR 26 proof classes they imply, and a gap analysis of the Kubernetes adapter and its world model.
- [Managed-resource inventory scope and overlap with established tooling](managed-resource-inventory-scope-and-tooling-overlap.md) - Assess which parts of MasterPlan 23's typed inventory are unique to Nagare and which re-implement established infrastructure, Kubernetes, backup, and database tooling, now that Nagare also serves as a workplace intranet PaaS.
- [Secrets architecture assessment for Kikan, Kotei, and Nagare](openbao-first-class-secrets-assessment.md) - Assess whether first-class OpenBao support is the right credential boundary for Nagare and its CI/CD consumers.
- [Web Application Firewall integration options for Nagare](web-application-firewall-integration-options.md) - Compare managed edge and self-hosted WAF placements against Nagare's ingress, CDN, and origin-access design.
