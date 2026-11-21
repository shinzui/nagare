#!/usr/bin/env bash
# The per-commit gate (operator, 2026-11-17): the style check, then a build and
# the tests of only the Haskell packages a change touches, in this checkout with
# its warm builds. `just gate-fast` on a clean committed revision stays the gate
# before `just land`; this one only keeps a broken commit from being made.
#
# The change is the uncommitted one (tracked and untracked files) or, with a
# clean tree, HEAD's own commit; `just gate-commit REV` takes REV's own commit.
# In nagarectl's suite it runs the test groups of the test modules the change
# touches or that import a module it touches, directly (a group name's
# punctuation matches any character, as tasty patterns have no escapes); a test module it cannot
# name a group for, or a change to the suite's assembly, runs the whole suite.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
rev="${1:-}"
if [ -n "$rev" ]; then
  changed="$(git diff --name-only "$rev^" "$rev")"
elif [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  changed="$( (git diff --name-only HEAD; git ls-files --others --exclude-standard) | sort -u)"
else
  changed="$(git diff --name-only HEAD^ HEAD)"
fi
started=$(date +%s)
say() { printf 'gate-commit: %s\n' "$*"; }
step() { # label, directory, command...
  local label="$1" dir="$2" t0=$(date +%s); shift 2
  ( cd "$dir" && "$@" ) || { say "$label FAIL ($(( $(date +%s) - t0 )) s)"; exit 1; }
  say "$label ok ($(( $(date +%s) - t0 )) s)"
}

packages="$(printf '%s\n' "$changed" | sed -n 's#^cli/\([^/]*\)/.*\.\(hs\|cabal\)$#\1#p; s#^cli/\([^/]*\)/cabal\.project$#\1#p' | sort -u)"
haskell=0; [ -n "$packages" ] && haskell=1
audit=0; printf '%s\n' "$changed" | grep -Eq '^(justfile|scripts/|cli/)' && audit=1
[ "$haskell" = 1 ] || [ "$audit" = 1 ] || { say "no Haskell, justfile or script change; nothing to gate"; exit 0; }
# nagare-core's modules are tested by nagarectl's suite and serve the admin API.
if printf '%s\n' "$packages" | grep -qx nagare-core; then
  packages="$(printf '%s\n' $packages nagarectl nagare-api-server | sort -u)"
fi
say "packages: ${packages:-none}"

[ "$haskell" = 0 ] || step haskell-style-check . just haskell-style-check
[ "$audit" = 0 ] || step architecture-and-command-audit . bash scripts/test-managed-command-audit.sh

# The test groups of nagarectl's suite that the change reaches. Prints the tasty
# pattern, "all" for the whole suite, or nothing when no test reaches it.
nagarectl_pattern() {
  python3 -I - "$repo/cli/nagarectl" "$changed" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
changed = [line.strip() for line in sys.argv[2].splitlines() if line.strip()]
prefix = "cli/nagarectl/"
def module(path):
    for base in ("src/", "app/", "test/"):
        if path.startswith(prefix + base) and path.endswith(".hs"):
            return path[len(prefix + base):-3].replace("/", ".")
    # nagare-core's modules are nagarectl's, re-exported (MasterPlan 37).
    if path.startswith("cli/nagare-core/src/") and path.endswith(".hs"):
        return path[len("cli/nagare-core/src/"):-3].replace("/", ".")
    return None
touched = {m for m in map(module, changed) if m}
if any(p.startswith(prefix + "test/") and module(p) in ("Spec", "Nagare.Test.Suite") for p in changed) \
        or any(p.endswith(".cabal") or p.endswith("cabal.project") for p in changed if p.startswith(prefix)):
    print("all"); sys.exit()
tests = sorted((root / "test").rglob("*.hs"))
selected = set()
for path in tests:
    name = str(path.relative_to(root / "test"))[:-3].replace("/", ".")
    text = path.read_text(errors="replace")
    imports = set(re.findall(r"(?m)^import\s+(?:qualified\s+)?([A-Z][\w.]*)", text))
    if name in touched or imports & touched:
        selected.add(path)
groups = set()
for path in selected:
    text = path.read_text(errors="replace")
    trees = re.findall(r"(?m)^(\w+)\s*::\s*TestTree\s*$", text)
    found = []
    for tree in trees:
        body = re.search(rf"(?ms)^{re.escape(tree)}\s*=\s*(.*?)(?=^\S)", text)
        group = body and re.search(r'testGroup\s+"([^"]+)"', body.group(1))
        if group:
            found.append(group.group(1))
    if trees and not found:
        print("all"); sys.exit()
    groups.update(found)
if groups:
    print(" || ".join("/" + g.split("/")[0] + "/" for g in sorted(groups)))
PY
}

for package in $packages; do
  case "$package" in
    nagarectl)
      step nagarectl-build cli/nagarectl cabal build -v1 nagarectl-test
      # The fast gate never compiles the executable's own modules.
      if printf '%s\n' "$changed" | grep -q '^cli/nagarectl/app/'; then
        step nagarectl-exe-build cli/nagarectl cabal build -v1 exe:nagarectl
      fi
      pattern="$(nagarectl_pattern)"
      if [ -z "$pattern" ]; then
        say "nagarectl-test: no test module imports a touched module; built only"
      elif [ "$pattern" = all ]; then
        step nagarectl-test cli/nagarectl cabal test nagarectl-test
      else
        selected="$(cd cli/nagarectl && "$(cabal list-bin -v0 nagarectl-test)" --list-tests -p "$pattern" | wc -l | tr -d ' ')"
        [ "$selected" != 0 ] || { say "nagarectl-test: the pattern selects no test: $pattern"; exit 1; }
        say "nagarectl-test: $selected tests selected by $pattern"
        step nagarectl-test cli/nagarectl cabal test nagarectl-test --test-option=-p --test-option="$pattern"
      fi
      ;;
    nagare-dsl)
      step nagare-dsl-build cli/nagare-dsl cabal build -v1 nagare-dsl-test
      step nagare-dsl-test cli/nagare-dsl cabal test nagare-dsl-test
      ;;
    nagare-api-server)
      step nagare-api-server-build cli/nagarectl cabal build -v1 nagare-api-server-test exe:nagare-events
      step nagare-api-server-test cli/nagarectl cabal test nagare-api-server-test
      ;;
    nagare-core)
      step nagare-core-build cli/nagarectl cabal build -v1 nagare-core
      ;;
    nagare-api|nagare-contract)
      step "$package-build" cli/nagarectl cabal build -v1 "$package"
      ;;
    nagare-harness)
      step nagare-harness-build cli/nagare-harness cabal build -v1 nagare-harness-test exe:nagare-harness
      step nagare-harness-test cli/nagare-harness cabal test nagare-harness-test
      ;;
    nagare-access)
      step nagare-access-build cli/nagare-access cabal build -v1 nagare-access-test
      step nagare-access-test cli/nagare-access cabal test nagare-access-test
      ;;
    *) say "no gate step for cli/$package" ;;
  esac
done
say "green in $(( $(date +%s) - started )) s; run just gate-fast on the clean commit before just land"
