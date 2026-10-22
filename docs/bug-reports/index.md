---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [A ClickHouse server restart widens every app database's migration FILE grant into drift](clickhouse-restart-widens-app-database-file-grant.md) - ClickHouse persists the migration user's WRITE ON FILE as FILE ON *.*, so after any server restart Nagare observes an undeclared server-wide READ and refuses every review of every ClickHouse app database.
- [A one-tuple access change takes about two minutes because every plan reloads the whole inventory history one object at a time](reviewed-access-change-reloads-inventory-history-sequentially.md) - Saving and applying one team membership or site grant reads every accepted scope from the GCS inventory store with sequential GETs, twice per plan and again during apply, so routine access changes take about 100 seconds each and grow slower with every scope the context accepts.
- [Static-site directory redirects expose the internal HTTP port](static-directory-redirect-exposes-internal-port.md) - Generated Nginx directory redirects send HTTPS readers to HTTP port 8080 instead of preserving the public URL.
- [Static-site text responses omit their UTF-8 charset](static-text-omits-utf8-charset.md) - Generated Nginx serves UTF-8 Markdown as text/plain without a charset, allowing browsers to render non-ASCII punctuation incorrectly.
- [The documented release-upgrade command omits the operator toolchain](upgrade-command-omits-operator-tools.md) - The target `#nagarectl` application lacks Pulumi, so the published upgrade command fails before preview.
- [Upgrade host switching confuses GCE instance and generated host names](upgrade-host-switch-confuses-instance-and-host-names.md) - A context whose host name differs from its instance name evaluates the wrong NixOS attribute and may address another tailnet node.
- [Upgrade does not migrate the namespace wildcard certificate selector](upgrade-does-not-migrate-certificate-selector.md) - A TLS-enabled 0.2.2 cluster retains the broad selector, fails the 0.3.0 certificate policy, and leaves stale Secrets.
- [Resume reapplies an already successful Pulumi phase](upgrade-resume-reapplies-successful-pulumi-phase.md) - Resuming a later upgrade failure invokes Pulumi again even though the reviewed infrastructure phase succeeded.
