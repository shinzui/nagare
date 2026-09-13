#!/usr/bin/env bash
set -euo pipefail

cd "$src"
# No specific project id and no email-shaped literal may appear as a
# value in anything under cluster/bootstrap/. Comment lines are
# skipped so illustrative addresses in documentation comments stay
# legal; *.md files are out of scope (IR-3 scopes this guard to the
# rendered assets).
#
# Addresses at the RFC 2606 / RFC 6761 reserved example domains
# (example.com/.org/.net and any *.example) are ERASED before
# matching rather than skipped by line: those names are reserved
# forever and can never be a real person's mailbox, and the
# renderer's own refusal message has to print one to tell an
# operator what a contact looks like. Erasing the address rather
# than exempting the whole line keeps a real address on the same
# line detectable. The surviving file:line prefix still points at
# the offending line.
offenders="$(find cluster/bootstrap -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.tmpl' \) \
  -exec grep -Hn -v '^[[:space:]]*#' {} + \
  | sed -E 's/[A-Za-z0-9._%+-]+@(example\.(com|org|net)|[A-Za-z0-9.-]+\.example)([^A-Za-z0-9.-]|$)/\3/g' \
  | grep -E 'tan-nb-exp|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true)"
if [ -n "$offenders" ]; then
  echo "cluster/bootstrap must not carry a personal address or a specific project id:" >&2
  echo "$offenders" >&2
  exit 1
fi

# The two ACME directory URLs live in exactly two places: the shell
# resolver and the Haskell resolver. Anywhere else is drift waiting
# to happen, except for the two test files that assert on them.
for url in \
  https://acme-v02.api.letsencrypt.org/directory \
  https://acme-staging-v02.api.letsencrypt.org/directory; do
  grep -qF "$url" scripts/lib/target.sh || {
    echo "missing $url in scripts/lib/target.sh" >&2
    exit 1
  }
  grep -qF "$url" cli/nagarectl/src/Nagare/Target.hs || {
    echo "missing $url in cli/nagarectl/src/Nagare/Target.hs" >&2
    exit 1
  }
  stray="$(grep -rlF "$url" \
    --include='*.sh' --include='*.hs' --include='*.nix' --include='*.yaml' --include='*.tmpl' \
    . \
    | grep -v -e '^\./scripts/lib/target\.sh$' \
              -e '^\./cli/nagarectl/src/Nagare/Target\.hs$' \
              -e '^\./scripts/test-render-context-template\.sh$' \
              -e '^\./cli/nagarectl/test/Spec\.hs$' || true)"
  if [ -n "$stray" ]; then
    echo "$url is duplicated outside the two resolvers:" >&2
    echo "$stray" >&2
    exit 1
  fi
done
touch "$out"
