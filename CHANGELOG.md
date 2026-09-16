# Changelog

All notable user-visible changes to Nagare are recorded here. Nagare uses semantic versions and
immutable `v<major>.<minor>.<patch>` Git tags.

## [Unreleased]

## [0.4.0] - 2026-09-16

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
