#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/rehearse-clone-free-release.sh --version VERSION [--flake-ref REF] [--output FILE]

Exercise a versioned Nagare flake from an isolated home and a directory outside its source checkout.
When --flake-ref is omitted, the current clean HEAD is consumed through an exact git+file revision.
EOF
}

die() {
  printf 'nagare clone-free rehearsal: %s\n' "$*" >&2
  exit 1
}

version=""
flake_ref=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --flake-ref)
      [[ $# -ge 2 ]] || die "--flake-ref requires a value"
      flake_ref="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "--version must be an unpadded major.minor.patch semantic version"
command -v git >/dev/null 2>&1 || die "git is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v nix >/dev/null 2>&1 || die "Nix with flakes is required"

repo_root="$(git rev-parse --show-toplevel)"
revision="$(git -C "$repo_root" rev-parse HEAD)"
if [[ -z "$flake_ref" ]]; then
  [[ -z "$(git -C "$repo_root" status --porcelain)" ]] \
    || die "the default exact-commit rehearsal requires a clean worktree"
  flake_ref="git+file://${repo_root}?rev=${revision}"
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-clone-free.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/home" "$test_root/config" "$test_root/state" "$test_root/work"
cp "$repo_root/cluster/examples/hello-knative-service/nagare/Config.hs" "$test_root/work/Config.hs"
cp "$repo_root/cli/nagarectl/test/fixtures/operator.pub" "$test_root/work/operator.pub"

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_STATE_HOME="$test_root/state"
cd "$test_root/work"

run_cli() {
  nix run "${flake_ref}#nagarectl" -- "$@"
}

run_operator() {
  nix run "${flake_ref}#nagare" -- "$@"
}

run_cli version --json > version.json
jq -e --arg version "$version" '.version == $version and (.revision | length > 0)' version.json >/dev/null

run_cli context create local --mode local \
  --registry-host localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio:9000/nagare-backups \
  --use
run_cli context show local > local-context.env
run_cli deploy --dry-run --file "$test_root/work/Config.hs" > typed-config.out
run_cli platform root --json > platform-root.json
jq -e --arg version "$version" \
  '.source == "installed" and .platformVersion == $version and (.workspaceRoot | length > 0)' \
  platform-root.json >/dev/null
run_operator --dry-run local-up > local-init.out 2>&1

run_cli context create rehearsal-cloud \
  --project nagare-release-rehearsal \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain rehearsal.example.com \
  --use
run_cli init cloud-onboarding \
  --project nagare-release-rehearsal \
  --base-domain rehearsal.example.com \
  --skip-preflight --skip-enable --skip-seed --dry-run > cloud-init.out
run_cli host init --context rehearsal-cloud \
  --ssh-public-key-file "$test_root/work/operator.pub" --dry-run > host-init.out
run_operator --dry-run infra-preview > infra-preview.out 2>&1

current_system="$(nix eval --raw --impure --expr builtins.currentSystem)"
supported_systems="$(nix eval "${flake_ref}#lib.release.supportedSystems" --json)"
jq -e --arg system "$current_system" 'index($system) != null' <<<"$supported_systems" >/dev/null \
  || die "current system $current_system is absent from the release metadata"

result="$(jq -n -S \
  --arg version "$version" \
  --arg revision "$(jq -er '.revision' version.json)" \
  --arg flakeRef "$flake_ref" \
  --arg system "$current_system" \
  --argjson supportedSystems "$supported_systems" \
  '{version: $version, revision: $revision, flakeRef: $flakeRef, system: $system,
    supportedSystems: $supportedSystems, cloneFree: true,
    checks: ["version", "context", "typed-config", "payload", "host-config", "local-init", "cloud-init", "operator-recipe"]}')"

if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "$result" > "$output"
else
  printf '%s\n' "$result"
fi
