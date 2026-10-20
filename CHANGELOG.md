# Changelog

All notable user-visible changes to Nagare are recorded here. Nagare uses semantic versions and
immutable `v<major>.<minor>.<patch>` Git tags.

## [Unreleased]

## [0.9.0] - 2026-10-20

### Fixed

- **A ClickHouse server restart no longer blocks its app databases' reviews** (BUG-7). ClickHouse
  stored the migration user's `WRITE ON FILE` in a legacy form that a restart reloads as `READ`
  and `WRITE`, which every plan, quiesce and resume then refused as drift. Nagare's ClickHouse
  servers turn on `access_control_improvements.enable_read_write_grants`, and the next plan
  revokes a `READ` an older server reloaded. Each existing ClickHouse server restarts once.

### Added

- **App databases declare privileges inside their own databases and name owner workloads**
  (IR-35). On PostgreSQL the runtime takes `CREATE` in named schemas (`createIn`) or on the
  database (`createSchemas`), and the migration user becomes a member of the runtime role so
  backups and migrations reach runtime-owned objects; on ClickHouse either user takes any
  database-scoped privilege the running server knows. A workload named in `owners` binds the
  migration credential. `AppDatabaseAccess` gains `privileges` and `owners`.

## [0.8.0] - 2026-10-20

### Fixed

- **A scheduled run taken before its schedule changed is still ingested, restored and pruned.**
  Adding a logical database to an app database, or moving a server's image, used to leave the
  earlier runs unrecoverable through Nagare and every later prune refused. A restore of such a
  run loads only the databases it holds (EP-203 finding).

### Added

- **App databases declare reviewed grant exceptions and per-user limits** (IR-30, IR-32). An
  app database's `access` names, per user, ClickHouse system-table and temporary-table
  exceptions from a closed allow-list, ClickHouse ceilings constrained `MIN 1 MAX` the declared
  value, and a PostgreSQL connection limit and statement timeout; `monitoring = [PgMonitor]`
  tolerates PGMQ's grants to `pg_monitor`. A hand change outside the declaration is drift.
- **One app database can be quiesced, backed up on demand and resumed** (IR-31).
  `db app-database quiesce` closes the chosen users' logins, pauses the schedule and drains the
  app's sessions, scheduled run and mutations without restarting the shared server;
  `db app-database backup` takes the schedule's own Job on demand; `resume` reopens exactly the
  quiesced users; `evidence` prints the window's server identity, drain and backup.
- **App databases declare read-only readers** (IR-33). A reader is a user with `SELECT` on
  named tables or views of the app's own databases (or, on PostgreSQL, every view of a schema),
  under fixed ceilings. A workload in a declared consumer app binds it with
  `appDatabaseReaders` and receives only the reader's Secret. Readers rotate with
  `db app-database rotate --user reader-NAME` and are retired by declaring `retired`.
- **`AppDatabase` has an `access` field, and `Deployment` and `Worker` an `appDatabaseReaders`
  field.** A config that builds one of them literally adds `access = noAppDatabaseAccess` or
  `appDatabaseReaders = []`; presets and record updates are unaffected.

## [0.7.1] - 2026-10-19

### Fixed

- **A transition passes the kubeconfig stage with an operator-linked kubeconfig.** A symlinked
  context kubeconfig whose bytes match the accepted digest is read through the link and never
  written (F127).
- **`context apply` works on a symlinked context.** A reviewed change renames over the link's
  target, so the link into the operator's repository survives (F126).
- **Retiring an app database suspends its backup schedule**, which kept running and failing at
  login. Runs taken before retirement still ingest and restore (F131).

### Added

- **App databases' backups are graded and pruned.** `server status` and `doctor` show a
  recovery-point and a retention row for every app database, and
  `db app-database prune-scheduled-backups` and `recover-scheduled-prune` review the removal of
  runs past policy (F132).

## [0.7.0] - 2026-10-19

### Added

- **App databases on shared servers.** One PostgreSQL or ClickHouse server hosts many apps'
  databases, each with its own runtime and migration users and explicit grants, provisioned,
  rotated and retired through reviewed `nagarectl db app-database` commands. Workloads bind them
  with `appDatabases` and receive only their runtime credential. Each app database has its own
  signed backup schedule, ingestion, and restore into scratch or after a server rebuild (IR-29).

### Changed

- **`Deployment` and `Worker` have an `appDatabases` field.** A config that builds either record
  literally adds `appDatabases = []`; presets and record updates are unaffected.
- **ClickHouse servers turn on SQL access management.** Each existing ClickHouse server sees one
  reviewed update and restarts once.

### Fixed

- **Backup and restore Job pods no longer receive database connections.** They carried the label
  a server's Service selects, so a running Job pod briefly refused connections routed to it. Each
  existing backup CronJob sees one reviewed update.

## [0.6.6] - 2026-10-18

### Fixed

- **Enabling a new cloud resource applies.** A zero-mutation update no longer runs `pulumi up`,
  whose plan check refused the resources it skipped (F128).
- **The admin API obtains its reader token.** Google's gzipped token response is decoded (F129).
- **A transition stranded by a close can finish.** A converged review records a re-verified scope
  a close kept unconverged, and a newer release may supersede an idle open transition (F130).

## [0.6.5] - 2026-10-17

### Fixed

- **An installed cloud context can enable the admin API.** Its reader account's creates no longer
  form an operation dependency cycle with the existing cloud members, which admission refused
  (F125).

## [0.6.4] - 2026-10-17

### Added

- **Read-only admin API.** `https://admin.<base domain>/v1/…` serves the inventory head, scopes,
  recorded sites, image publications and recorded grants as Relay connections with strong ETags and
  RFC 9457 problems, described by `docs/api/openapi.json`. Callers are a signed-in person or a
  Shomei service account, either with a grant on the hostname. It is opt-in per context with
  `NAGARE_ADMIN_API_ENABLED=1`; a cloud context also needs the dedicated read-only reader account
  and its key (MasterPlan 28).
- **`--contract 1`** prints versioned JSON documents for inventory status, publications, transaction
  outcomes, saved reviews, image publications and deploy previews, with problem documents for
  refusals (EP-192).
- **`nagarectl site list`** lists a context's recorded sites from one inventory read, without
  inspecting providers (EP-193).

### Changed

- **New ClickHouse databases default to 26.8**, including their backup and restore images. An
  explicit version is kept, and accepted databases are not upgraded (EP-199).
- **The access gateway answers API clients with problem documents**: an API backend's `/v1` paths,
  a bearer credential, or an `Accept` that prefers JSON. It bounds authorization at 5 s and never
  returns the HTTP client's exception text.

### Fixed

- Site and preview identities no longer collide, and an over-long preview hostname is refused. A
  preview route that never became ready can be removed through review, and preview cleanup skips
  a member it cannot collect (EP-195, F99, F100, F101).
- An ambiguous stop prints its reason (F94). An expired gcloud login asks for reauthentication
  (F107). `inventory status` explains an unprepared workspace (F118).

## [0.6.3] - 2026-10-13

### Added

- **Static and server sites can require login.** `StaticSite` and `ServerSite` take the same
  `access` field as an application and route through the shared enforcer; a preview of a protected
  site is its own protected hostname. A public route does not become protected in place: retire it
  through a reviewed plan first (EP-186).
- **Sites can be granted to a team.** `nagarectl access team add-member|remove-member|list-members`
  and `access grant|revoke --team` write reviewed En relationships. The bootstrap En schema adds
  group membership; the schema change rolls the `en` server during the upgrade (EP-187).
- **`nagarectl access check --host HOST --user EMAIL`** asks the context's En whether one user can
  reach a protected host now, without writing anything (EP-188).
- **`nagarectl domains tls HOST`** diagnoses one host's certificate chain, from DomainMapping to the
  ACME challenges, without reading Secrets. `--renew --yes` retries a failed certificate this
  context owns. A deploy that stops on TLS prints the verdict and this command (IR-28).

### Fixed

- **Static sites keep their public URL on redirects and serve text as UTF-8.** The generated Nginx
  configuration issued directory and configured redirects as `http://<host>:8080/…`, the
  container's internal port. Redirects are now relative (`Location: /guide/`), and text responses
  carry `charset=utf-8`. Existing sites pick this up on their next `nagarectl site deploy`
  (BUG-5, BUG-6).
- **A review with access operations refuses before admission when `NAGARE_EN_API_KEY` is unset.**
  `inventory apply` and `inventory resume` name the variable and keep the saved review valid;
  status findings and plan errors name why an access observation was unavailable (IR-27).

## [0.6.2] - 2026-10-12

- **A converged upgrade plan has no operations.** Every platform stage selects the bootstrap stamp,
  and selecting it planned a check of every Kubernetes and Helm member, so a converged transition
  replanned the same verifications forever. The planner now checks before the stamp only when
  something changed (F124).
- **nagarectl ships its pinned Helm.** The observability release refuses any Helm but v4.2.4, and
  the package carried none, so a transition ran whatever `helm` the operator had. The wrapper now
  puts the pinned Helm first on its PATH, and `version --tools` reports it (F123).
- **The release guard runs on every stage.** `inventory apply` ran it only for stages that select
  Pulumi, host or artifact operations, so a Kubernetes- and Helm-only stage skipped it.
- **`inventory status` is about five times faster.** It reads each Kubernetes kind and namespace
  once and observes independent executors concurrently: 22.7–27.7 s against the intranet, from
  139 s, with the same findings. `inventory store status` also reports the transition and the
  accepted and converged revisions.
- **Auth images follow current En and Shomei.** Nagare pins current upstream revisions, handles
  En's Problem Details responses, and stages every auth image from the selected source commits.

## [0.6.1] - 2026-10-12

- **A cloud context's transition stages apply.** 0.6.0's `inventory apply` ran the ordinary release
  guard on every cloud stage, which refuses the minor skew a transition exists to close, so no cloud
  context could leave 0.5.0. A reviewed transition stage now refuses only a major mismatch (F122).
- **The host builds on the context's builder.** The host stage built its NixOS closure on the
  operator machine's default Nix builders. It now builds on the context's builder
  (`NAGARE_BUILDER_*`) through the same pinned IAP tunnel as the host image, and refuses a builder in
  another project or a Nix daemon that would ignore it (F121).

## [0.6.0] - 2026-10-12

- **Upgrade an installed context in place.** `nagarectl platform transition plan --out DIR` reviews
  each stage that moves an admitted context from its pinned release to this one, and
  `platform transition commit --yes` pins it once every scope has converged. A transition marker in
  the store head keeps other reviews out until the commit, and every stop resumes with this
  release's `nagarectl`. This release accepts contexts on 0.4.0 and 0.5.0.
- **Grant access by email.** `access grant --user` accepts a Shomei user's email and resolves it to
  exactly one user id (F96).
- **Access changes reach en through a private port-forward**, not the address a grant was first
  recorded through; grants made by 0.5.0 still bind (F97).
- **`env set` refuses a key the Config sets inline**, which would otherwise silently win (F98).
- **A partially applied Pulumi stage closes by proof.** `inventory close` settles a create the
  provider refused partway from the stack export, and the replan no longer hits a dependency cycle
  (F113, F114).
- **A clearer prebuilt-image refusal.** A reviewed deploy whose image differs from its publication
  names both images and says a PrebuiltImage takes its tag from the Config; `--tag` help says the
  same (F116).
- **Releases bind the upgrade rehearsal.** Release assembly and `nagarectl release publish` require
  the EP-172 transition rehearsal record (a disposable local context moved from the previous release
  to the candidate, its seeded row read back unchanged) and the platform metadata, in place of the
  per-release local and cloud evidence chain.

## [0.5.0] - 2026-10-10

- **Protected HTTPS login for every deploy.** The access enforcer re-reads its route map, so a
  route protected after the bootstrap is served without a restart; `nagare-harness route-check`
  checks a protected route over verified HTTPS.
- **Scheduled volume backups.** Backup-included application volumes are backed up on the database
  schedule with signed receipts, graded freshness, ingestion and scratch restore.
- **Retention and prune.** Scheduled database and volume backups are kept for 48 hours, then daily
  for 30 days, always keeping the newest; reviewed prunes with one recovery for a stopped prune.
- **Rebuild of a lost durable member** from its verified recovery point, with recorded lineage.
- **Health-checked services deploy through review.** A zero probe `initialDelaySeconds` (the
  `httpHealthCheck` default) is no longer rendered, so a reviewed deploy no longer reads it back as
  drift and stops ambiguous.
- **Unambiguous certificate-policy inventory.** `nagarectl cluster certificate-policy` now queries
  `certificates.cert-manager.io` explicitly, so clusters that also install Knative's distinct
  `Certificate` resource do not produce a false issuer-policy failure during bootstrap or upgrade.

## [0.4.0] - 2026-09-16

- **Typed resource inventory.** Each context keeps one typed, scoped inventory of what Nagare owns
  across cloud, host, cluster, data, secrets and artifacts. Changes are reviewed, context-bound plans
  applied as journalled, resumable transactions; collisions and ambiguous ownership refuse before
  mutation, and a stopped transaction closes only by per-operation proof (ADR 26, ADR 27).
- **Data protection.** Signed scheduled database backups off-cluster in GCS under a per-context
  recovery-point objective, unattended freshness, escrowed signing keys, and a drilled total
  cluster loss recovery from escrow and GCS.
- **Reviewed data and host operations.** Isolated restores, a fenced PostgreSQL rename with a
  backward exit, a side-by-side PostgreSQL major upgrade with refusal of in-place major or engine
  changes, `app deploy --retire-database`, and NixOS/k3s node upgrades by reviewed lock re-pin with
  a no-effect close for an activation that did not commit. Host activations run detached, so an
  upgrade that restarts `tailscaled`, `sshd` or the network no longer hangs or commits a cut-off
  activation.

- **Optional in-cluster Nix binary cache.** Cloud contexts can opt into a context-local Attic
  service backed by a protected GCS bucket and managed PostgreSQL. Nagare publishes a digest-pinned
  server image, owns encrypted storage and JWT credentials, emits a public-read client ConfigMap,
  restricts cache traffic with NetworkPolicies, schedules garbage collection and database backups,
  and includes positive substitution and wrong-key smoke workloads.

- **Provider-free Pulumi upgrade resume.** A private receipt now binds successful Pulumi apply to
  the exact upgrade transaction and retained reviewed plan. Later-phase resumes skip Pulumi without
  probing its executable or provider, while ambiguous crashes and successful legacy journals
  require the explicit audited `platform upgrade recover-pulumi` workflow.
- **Guarded legacy certificate migration.** Platform upgrades from a TLS-enabled 0.2.2 cluster now
  retain a private, context-bound Kubernetes review of the legacy `{}` wildcard selector and its
  exact certificate chains. Apply narrows the selector before the policy gate, preserves opted-in
  application wildcards, and removes only unchanged obsolete Certificates and generated Secrets;
  drift refuses without advancing the context.
- **Upgrade host identity confinement.** Host switches now derive their Nix attribute and
  Tailscale SSH destination from the context's validated generated host name instead of the GCE
  instance name. Upgrade transactions bind both values to the staged `host.nix`, reject ambiguous
  identity before host mutation, and cannot inherit a sibling context's ambient override.
- **Clone-free platform upgrades.** The upgrade and multi-cluster guides now invoke target-release
  platform operations through `nix shell ...#nagare -c nagarectl`, so planning, status, apply,
  resume, and rollback carry the release-pinned Pulumi CLI and Node.js language host instead of
  relying on ambient operator tools.

## [0.3.0] - 2026-09-14

- **Production domain routing and TLS.** Ordinary applications, static sites, and server sites now
  share one normalized multi-domain model with an explicit canonical hostname and automatic or
  supplied-Secret origin TLS. Deploys refuse conflicting hostname ownership before apply, wait for
  every route and certificate, and expose observed DNS, routing, and certificate health through
  `nagarectl domains list --json` and the strict `nagarectl domains check` gate. Pulumi owns an exact
  base-domain apex record in addition to the wildcard, and Google CDN gains a guarded
  `legacy` → `prepare` → `certificate-map` migration covering the apex and first-level hostnames.
- **Replacement cutover safety core.** Provider-independent replacement transactions now journal
  intent and observation around every operation, reserve rollback time before write admission,
  reconcile interrupted handoffs, and guard cleanup by exact resource identity. No production
  replacement command is exposed until the remaining GCE, Kubernetes, state-transfer, and live
  rehearsal plans supply their adapters and evidence.

- **One-pass GCP onboarding rehearsal (IR-11).** The canonical onboarding path now has a hermetic
  state-machine rehearsal for command ordering and refusal behavior. Operator help and guides state
  that changing boot-disk size replaces the VM and its boot-resident k3s state, distinguish that
  from online data-disk growth, and recommend sizing the boot disk for the VM lifetime.
- **Post-boot host age-key delivery (IR-18).** New cloud hosts now boot from secret-free images and
  accept an operator-held age identity through `nagarectl host place-age-key` over context-confined
  IAP SSH stdin. The host verifies metadata and SHA-256, retries sops-nix activation, starts
  Tailscale without an interactive login, and exposes ready/missing/invalid state through server
  status and doctor.
- **Confined bootstrap TLS (IR-22, IR-23).** Public wildcard certificates now require the
  `nagare.dev/app-namespace=true` opt-in label, which every application workload path reconciles,
  while internal roles explicitly stay on Knative's self-signed issuer. Nagare carries a focused
  fix for an issuer-pointer alias in the latest archived net-certmanager v1.14.0 controller, builds
  it reproducibly with Nix, embeds the archive in the immutable platform payload, and imports it
  directly into k3s. Bootstrap and doctor fail closed on leaked internal ACME names or unlabeled
  public wildcards.
- **Reliable first-boot data disk (IR-19).** The blank-disk formatter now runs before the
  generated systemd-fsck unit, and a recovered mount pulls layout and k3s back into its transaction
  without weakening their hard data-disk requirements. Five independent NixOS VM samples require
  exactly one `Ready` node in the original boot and reject the former `Device or resource busy`
  failure.
- **Reviewed infrastructure apply (IR-15).** `infra preview --save-plan` now creates a private
  context-bound Pulumi plan, redacted review, and binding metadata; `infra apply --plan --yes`
  verifies and applies that exact plan without a second preview or TTY. Upgrades retain the same
  bundle across resume, and guarded `infra destroy --yes` owns deliberate teardown.
- **Context-owned image builders (IR-17).** Host-image prints and explicitly selects a private
  per-context Nix builder route. The shipped IAP proxy receives project, zone, and instance as
  parameters; foreign-project builders refuse unless the command acknowledges that exact project.
- **ADC project confinement (IR-12).** Initialization and every cloud context guard now inspect the
  Application Default Credentials file Pulumi uses before its first invocation. A foreign quota
  project refuses with the exact repair command; missing, malformed, or unreadable credentials
  refuse without exposing tokens, while absent or mismatched principal evidence is an explicit
  warning. The GCP setup guides now make ADC login and quota attribution context-switching duties.
- **Never-deployed context re-pin (IR-16).** Platform status now distinguishes a confirmed-absent
  GCE host and its cluster from legacy or unreachable resources, so a patch-behind fresh context
  reports `patch-skew`. `nagarectl platform repin --version VERSION --yes` advances only a guarded,
  never-deployed context and its recognized generated host flake; existing or inconclusive cloud
  evidence refuses, and operator-owned host configuration and secrets remain untouched.
- **Safe operator access (IR-10, IR-20).** The installable operator package no longer exports
  Haskell `lib/links`, includes `socat`, and can coexist with Home Manager without priority
  overrides. `nagarectl kubeconfig fetch` retrieves and atomically normalizes a private
  per-context kubeconfig through project-confined IAP; `nagarectl cluster guard` verifies its
  context and sole server node before cloud Kubernetes mutation recipes run.
- **Reliable first cluster bootstrap (IR-21).** Cloud and local bootstrap now wait with explicit
  deadlines for Knative admission webhooks before changing dependent ConfigMaps, and convergent
  Knative ConfigMap merge patches retry briefly so a fresh cluster succeeds without a second run.
- **Distinct context host names (IR-14).** `nagarectl host init` now defaults the NixOS and
  Tailscale name to `<context>-nagare` independently of the project-scoped VM instance name. It
  refuses an implicit name already recorded by a sibling context while preserving `--host-name` as
  an explicit override, and the access guides distinguish Tailscale names from GCE/IAP names.
- **Context guard diagnostics (IR-9).** `nagarectl context guard` now distinguishes a missing
  Pulumi executable, a failed command with captured stderr, invalid JSON, and a genuinely absent
  `gcp:project`; every refusal names the selected stack/backend, and `--json` failures are standalone
  parseable objects.

See [the 0.3.0 release notes](docs/releases/v0.3.0.md).

## [0.2.2] - 2026-09-13

- **Host initialization (IR-13).** Generated host modules once again set the declared
  `nagare.host.hostName` option, so new host flakes evaluate.
- **Context isolation (IR-7).** `init NAME` derives a new context without reading the active
  context or ambient target variables, prints the derived names before mutation, and refuses
  stored bucket names owned by another project. Under `--force`, omitted Pulumi backend fields now
  keep the named context's stored values instead of resetting to `local`.
- **Operator tools (IR-8).** The full `nagare` package includes Pulumi and its Node.js language
  plugin. `init` preflights every required tool before side effects, missing Pulumi becomes a
  recoverable error, installed next steps use the `nagare` launcher, and `version --tools` reports
  the binaries selected from `PATH`.

See [the 0.2.2 release notes](docs/releases/v0.2.2.md).

## [0.2.1] - 2026-09-13

A safety release for cloud contexts; do not run `nagarectl platform upgrade` with 0.2.0.
- **Stack config.** The Pulumi stack config now has a context-owned home that every workspace links
  to, and payload workspaces install the Pulumi program's locked Node dependencies.
- **Upgrade guards.** The upgrade's Pulumi phases run the project guard and the replacement guard,
  and apply no longer skips its preview.
- **Replacement guard.** The guard also protects the Cloud DNS zone and storage buckets.
- **Contexts.** `context create --force` merges instead of resetting omitted fields.
- **Status.** Host release identities are read correctly.

See [the 0.2.1 release notes](docs/releases/v0.2.1.md).

## [0.2.0] - 2026-09-13

This breaking pre-1.0 release confines every cloud-mutating path to the active context's project.
The ACME contact and VM shape now belong to the context, with no default ACME contact. Host
switches revert themselves unless a fresh SSH login is verified. Operator secrets moved out of the
repository, and operators can deploy their own authentication portal for protected sites. The data
disk grows online, and managed-database backups and readiness are hardened. The host nixpkgs pin
moves to Tailscale 1.102.3.

Nagare's maintained Haskell packages now follow the shared `haskell-jitsurei` source conventions.
Record fields use semantic names, so downstream Haskell source may need updates. Serialized JSON,
rendered deployment manifests, command names and help, and access-service HTTP behavior remain
unchanged.

See [the 0.2.0 release notes](docs/releases/v0.2.0.md) for breaking changes, the upgrade path from
0.1.0, and validation gaps.

## [0.1.0] - 2026-08-28

The first release packages `nagarectl`, its typed Haskell configuration runtime, and the
Nagare platform payload as Nix flake outputs. Named contexts isolate operator state, generated host
flakes keep personal configuration outside the release, and platform status and upgrade commands
make release skew visible and recoverable.

See [the 0.1.0 release notes](docs/releases/v0.1.0.md) for installation, compatibility, and known
limitations.
