#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

files_file="$(mktemp "${TMPDIR:-/tmp}/nagare-haskell-style.XXXXXX")"
trap 'rm -f "$files_file"' EXIT

rg --files \
  cli/nagare-dsl/src cli/nagare-dsl/test \
  cli/nagarectl/src cli/nagarectl/app cli/nagarectl/nagared cli/nagarectl/test \
  cli/nagare-access/src cli/nagare-access/app cli/nagare-access/test \
  -g '*.hs' \
  -g '!**/fixtures/**' \
  -g '!**/generated/**' \
  -g '!**/negative/**' \
  | sort >"$files_file"

xargs ast-grep scan --config sgconfig.yml -- <"$files_file"
ast-grep test --config sgconfig.yml --skip-snapshot-tests

if rg -n '^\s*PackageImports\b' cli -g '*.cabal'; then
  printf '%s\n' 'PackageImports must not be enabled by a Cabal component' >&2
  exit 1
fi

printf '%s\n' 'Haskell style checks passed (nagare-dsl, nagarectl, nagare-access).'
