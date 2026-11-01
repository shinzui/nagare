---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Line caps forced restructuring mid-feature](1-line-caps-forced-restructuring-mid-feature.md) - Hard line caps on Inventory/Store.hs (1000), Cli/Dispatch.hs (200) and test Suite.hs (300) each failed the architecture check after a few added lines and forced a constructor merge, a re-export and a regrouping.
- [New CLI command needs undocumented audit registration](2-new-cli-command-needs-undocumented-audit-registration.md) - A new Command constructor must be registered in scripts/audit-managed-commands.py with a coverage family and a catalogue row; nothing at build or style time says so, and the fast gate went red only at architecture-and-command-audit with a log that hides the error.

