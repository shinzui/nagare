# Changelog

All notable user-visible changes to Nagare are recorded here. Nagare uses semantic versions and
immutable `v<major>.<minor>.<patch>` Git tags.

## [Unreleased]

Nagare's maintained Haskell packages now follow the shared `haskell-jitsurei` source conventions.
Record fields use semantic names, so downstream Haskell source may need updates before the next
release. Serialized JSON, rendered deployment manifests, command names and help, and access-service
HTTP behavior remain unchanged.

## [0.1.0] - 2026-08-28

The first release packages `nagarectl`, its typed Haskell configuration runtime, and the
Nagare platform payload as Nix flake outputs. Named contexts isolate operator state, generated host
flakes keep personal configuration outside the release, and platform status and upgrade commands
make release skew visible and recoverable.

See [the 0.1.0 release notes](docs/releases/v0.1.0.md) for installation, compatibility, and known
limitations.
