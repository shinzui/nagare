# Bundle Update Log

## 2026-09-14
* **Update**: Make the canonical GCP onboarding sequence use reviewed-release and target placeholders, identify billable targets and observable success, and document boot-disk replacement versus online data-disk growth.
* **Update**: Document supported post-boot host age-key delivery over IAP.
* **Update**: Document opt-in public wildcard namespaces, self-signed internal issuer roles, payload-bundled patched net-certmanager delivery, certificate-policy verification, and reviewed stale-certificate cleanup.
* **Update**: Document context-bound reviewed Pulumi plans, guarded non-interactive apply and teardown, upgrade resume semantics, and explicit per-context image builders with named shared-project exceptions.
* **Update**: Document bundled Pulumi, separate Node.js and Google Cloud SDK prerequisites, the version --tools report, and the 0.2.2 installation pin.

## 2026-09-13
* **Update**: Document the context-owned Pulumi stack config and its workspace links, the npm dependency install for payload workspaces, the merging context create --force, the DNS zone and bucket replacement guard, and the guarded Pulumi phases of platform upgrade.
* **Update**: Add a resumable macOS runbook for trusting and removing the local CA and completing the three real-browser passkey ceremonies.
* **Update**: Document deploying, customizing, synchronizing, and safely removing an operator-owned authentication portal.
* **Update**: Document the context-owned VM shape, the in-place versus replacement matrix, and the infra-up replacement guard.

## 2026-09-12
* **Update**: Document growing the data disk: the preview to expect, the automatic grow on boot, the one-command online grow (systemctl restart, not start), that shrinking is impossible and when protect takes effect, that bootDiskSizeGb is create-time only, and the unsigned-path flag host-switch now passes to nix copy.
* **Update**: Make the ACME identity context-owned: document NAGARE\_ACME\_EMAIL and NAGARE\_ACME\_DIRECTORY across contexts, reference, onboarding and cluster bootstrap, including the no-default refusal, the staging rehearsal, and recovering an account registered under a wrong address.
* **Update**: Document the enforced project confinement: what keeps Nagare inside your project, the nagarectl context guard / context env commands, and the infra-up preflight.

## 2026-08-28
* **Migration**: Adopt the shared user-documentation profile and assign stable document handles.
