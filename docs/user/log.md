# Bundle Update Log

## 2026-09-12
* **Update**: Document growing the data disk: the preview to expect, the automatic grow on boot, the one-command online grow (systemctl restart, not start), that shrinking is impossible and when protect takes effect, that bootDiskSizeGb is create-time only, and the unsigned-path flag host-switch now passes to nix copy.
* **Update**: Make the ACME identity context-owned: document NAGARE\_ACME\_EMAIL and NAGARE\_ACME\_DIRECTORY across contexts, reference, onboarding and cluster bootstrap, including the no-default refusal, the staging rehearsal, and recovering an account registered under a wrong address.
* **Update**: Document the enforced project confinement: what keeps Nagare inside your project, the nagarectl context guard / context env commands, and the infra-up preflight.

## 2026-08-28
* **Migration**: Adopt the shared user-documentation profile and assign stable document handles.
