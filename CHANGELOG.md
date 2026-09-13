# Changelog

All notable user-visible changes to Nagare are recorded here. Nagare uses semantic versions and
immutable `v<major>.<minor>.<patch>` Git tags.

## [Unreleased]

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
