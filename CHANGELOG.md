# Changelog

All notable user-visible changes to Nagare are recorded here. Nagare uses semantic versions and
immutable `v<major>.<minor>.<patch>` Git tags.

## [Unreleased]

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
