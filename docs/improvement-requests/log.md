# Bundle Update Log

## 2026-09-12
* **Update**: Deliver IR-5: the data disk grows itself (ordering-cycle fix proven by a VM test), the procedure is documented with recorded previews and a live grow on nagare-01, and the DiskUsageHigh alert points at it.
* **Update**: IR-5 is in progress: docs/plans/111-automate-and-document-growing-the-data-disk.md implements the data-disk grow.
* **Update**: Complete IR-3. The ACME contact and directory endpoint are now context fields with no built-in default, the issuer renderer fails closed instead of inventing an identity, and a CI guard keeps personal defaults out of cluster/bootstrap/. Decision recorded as ADR 10.
* **Update**: Accept IR-2 and record its target plan: docs/plans/113-confine-every-cloud-mutating-path-to-the-active-context-s-project.md.
* **Update**: Accept IR-3 and record its target plan: docs/plans/112-make-the-acme-identity-context-owned-and-remove-the-personal-fallback-defaults.md.
* **Update**: Accept IR-5 and target it at docs/plans/111-automate-and-document-growing-the-data-disk.md.
* **Update**: Accept IR-4 and record its target plan: docs/plans/110-seed-and-pin-the-vm-shape-keys-at-init-and-guard-instance-replacing-applies.md.
* **Add**: Record IR-2 through IR-5 from the pre-flight isolation and readiness audit of v0.1.0: project confinement for cloud-mutating paths, context-owned ACME identity, seeded VM shape keys, and a real data-disk grow procedure.

## 2026-08-23
* **Migration**: Repin to okf-profiles v0.12.0 and record catalog review provenance; the new
dependency and acceptance-criteria fields are optional, so request semantics are unchanged.

## 2026-08-04
* **Migration**: Repin to okf-profiles v0.8.0 and move the bundle to OKF v0.2.

## 2026-07-30
* **Move**: Accept the diagnostics deployment-profile request from Kikan.
* **Migrate**: Assign `IR-1` and adopt the shared typed improvement-request profile.
