---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [The documented release-upgrade command omits the operator toolchain](upgrade-command-omits-operator-tools.md) - The target `#nagarectl` application lacks Pulumi, so the published upgrade command fails before preview.
- [Upgrade host switching confuses GCE instance and generated host names](upgrade-host-switch-confuses-instance-and-host-names.md) - A context whose host name differs from its instance name evaluates the wrong NixOS attribute and may address another tailnet node.
- [Upgrade does not migrate the namespace wildcard certificate selector](upgrade-does-not-migrate-certificate-selector.md) - A TLS-enabled 0.2.2 cluster retains the broad selector, fails the 0.3.0 certificate policy, and leaves stale Secrets.
- [Resume reapplies an already successful Pulumi phase](upgrade-resume-reapplies-successful-pulumi-phase.md) - Resuming a later upgrade failure invokes Pulumi again even though the reviewed infrastructure phase succeeded.
