---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Add hardened cross-cluster diagnostics deployment profiles to Nagare](cross-cluster-diagnostics-deployment-profile.md) - Package broker and production-probe profiles with identity, RBAC, network policy, and upgrade checks.
- [Confine every cloud-mutating path to the active context's project](confine-cloud-mutations-to-context-project.md) - Close four paths where a globally-unique name or an ambient gcloud default can direct a write outside the selected context's GCP project.
- [Make the ACME identity context-owned and remove the personal fallback defaults](context-owned-acme-identity.md) - Add the ACME contact and directory endpoint to the context schema and fail closed instead of registering Let's Encrypt accounts under a hardcoded personal address.
- [Seed and pin the VM shape keys at init so a routine apply cannot replace the instance](seed-vm-shape-keys-at-init.md) - Have nagarectl init seed machineType and bootDiskType, and warn before any plan that would destroy the boot disk holding k3s state and TLS material.
- [Document and automate growing the data disk](data-disk-grow-procedure.md) - Make the data-disk grow a real, tested procedure instead of a one-sentence reference that an operational alert already links to.

