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
- [Run the local cluster on Apple Container instead of k3d on Colima](local-cluster-on-apple-container.md) - Replace the k3d-on-Colima local substrate with k3s launched directly as an Apple Container, and make local image builds work without a Docker daemon.
- [Stop nagarectl init from inheriting derived fields from the active context](init-must-not-inherit-the-active-context.md) - A new context created while another is current silently takes that context's bucket names and other derived values, pointing a fresh project at another cluster's live buckets.
- [Ship Pulumi with the operator package and make init fail before it changes anything](ship-pulumi-with-the-operator-package.md) - The clone-free nagare package has no pulumi binary and no documented prerequisite, so init crashes after enabling APIs and creating the state bucket, and its recovery hints point the wrong way.
- [Make the context guard report a missing or failing pulumi instead of an unprojected stack](context-guard-misdiagnoses-a-missing-pulumi.md) - With pulumi absent from PATH the guard refuses with "declares no gcp:project" and advises context use, even though the stack config declares the right project.
- [Keep lib/links out of the installed nagare package so it installs beside other Nix profiles](operator-package-exports-lib-links.md) - The nagare and nagarectl packages expose the Darwin GHC lib/links dylib directory, which collides with home-manager and other profile entries on nix profile install.
- [Correct the docs that call a boot-disk size change in-place growth](boot-disk-size-docs-say-in-place.md) - provisioning-with-pulumi.md and reference.md still say NAGARE_BOOT_DISK_SIZE_GB grows in place, but a recorded preview shows the change replaces the instance and its k3s state.
- [Check the Application Default Credentials account and quota project against the context](check-the-adc-account-and-quota-project.md) - Pulumi authenticates with ADC, whose quota project can name a different, even production, project; neither init's preflight nor the context guard looks at ADC at all.
- [Make nagarectl host init render the host option the NixOS module declares](host-init-renders-an-unknown-host-option.md) - Since the semantic-record-label refactor, host init writes nagare.host.name, which the packaged module does not declare, so v0.2.0 and v0.2.1 cannot generate any new host flake.
- [Give each cloud cluster a distinct default host name so tailnet names do not collide](default-host-name-collides-across-clusters.md) - host init defaults the NixOS and Tailscale host name to the instance name, which is nagare-01 in every project, so a second cluster on the same tailnet is renamed and ssh deploy@nagare-01 becomes ambiguous.
