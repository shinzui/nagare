---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Bug Report

- [Changing the Shomei or En image strands the previous migration Job and blocks every platform plan](auth-image-change-strands-the-previous-migration-job.md) - The auth component names each migration Job after a digest of its image, so a new Shomei or En image pin drops the accepted Job from the desired inventory, and the platform planner refuses with retirement-required because no lifecycle decision can retire one member of the auth scope.
- [A ClickHouse server restart widens every app database's migration FILE grant into drift](clickhouse-restart-widens-app-database-file-grant.md) - ClickHouse persists the migration user's WRITE ON FILE as FILE ON *.*, so after any server restart Nagare observes an undeclared server-wide READ and refuses every review of every ClickHouse app database.
- [Closing a failed release hook blocks subsequent application reviews](closing-a-failed-release-hook-blocks-application-reviews.md) - After a failed migration hook is closed as terminal partial, Nagare refuses subsequent application reviews because a never-started operation from the closed review has no bound Job.
- [A one-tuple access change takes about two minutes because every plan reloads the whole inventory history one object at a time](reviewed-access-change-reloads-inventory-history-sequentially.md) - Saving and applying one team membership or site grant reads every accepted scope from the GCS inventory store with sequential GETs, twice per plan and again during apply, so routine access changes take about 100 seconds each and grow slower with every scope the context accepts.
- [Static-site directory redirects expose the internal HTTP port](static-directory-redirect-exposes-internal-port.md) - Generated Nginx directory redirects send HTTPS readers to HTTP port 8080 instead of preserving the public URL.
- [Static-site text responses omit their UTF-8 charset](static-text-omits-utf8-charset.md) - Generated Nginx serves UTF-8 Markdown as text/plain without a charset, allowing browsers to render non-ASCII punctuation incorrectly.
- [The documented release-upgrade command omits the operator toolchain](upgrade-command-omits-operator-tools.md) - The 0.3.0 upgrade runbook invokes the target release through #nagarectl, whose unwrapped CLI cannot find Pulumi, so a cloud upgrade fails before preview.
- [Upgrade does not migrate the namespace wildcard certificate selector](upgrade-does-not-migrate-certificate-selector.md) - A TLS-enabled 0.2.2 cluster retains its broad wildcard selector during a 0.3.0 upgrade, so the new certificate-policy gate fails and stale TLS Secrets remain.
- [Upgrade host switching confuses GCE instance and generated host names](upgrade-host-switch-confuses-instance-and-host-names.md) - The 0.3.0 host phase uses NAGARE_INSTANCE_NAME as both the NixOS attribute and SSH destination, so a context with a distinct generated host name cannot upgrade safely.
- [Resume reapplies an already successful Pulumi phase](upgrade-resume-reapplies-successful-pulumi-phase.md) - Resuming a 0.3.0 transaction after a later host or Kubernetes failure invokes Pulumi again even though the reviewed infrastructure phase is recorded as successful.
