#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/candidate"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

cat > "$test_root/bin/nagarectl" <<'FAKE_CLI'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == 'version --json' ]]; then
  printf '{"version":"0.4.0","revision":"%s"}\n' "${NAGARE_TEST_REVISION:-fixture-revision}"
  exit 0
fi
[[ "${1:-}" == --context && "${2:-}" == demo ]] || exit 30
shift 2
case "$1 $2" in
  'context guard') printf '%s\n' '{"context":"demo","mode":"local","confined":true}' ;;
  'inventory plan')
    [[ "$3" == --inventory && "$5" == --out ]] || exit 31
    mkdir -p "$6"
    if [[ "$6" == */no-op-review && "${NAGARE_TEST_NON_NOOP:-0}" != 1 ]]; then
      jq -n '{operations: []}' > "$6/review.json"
    else
      jq -n '{operations: [{summary: "one reviewed operation"}]}' > "$6/review.json"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$6/review.json" | cut -d ' ' -f 1 > "$6/review.sha256"
    else
      shasum -a 256 "$6/review.json" | cut -d ' ' -f 1 > "$6/review.sha256"
    fi
    ;;
  'inventory apply')
    [[ "${4:-}" == --yes ]] || exit 32
    [[ "${NAGARE_TEST_FAIL_APPLY:-0}" != 1 ]] || exit 35
    ;;
  'inventory status') printf '%s\n' '{"observed":true}' ;;
  *) exit 33 ;;
esac
FAKE_CLI
cat > "$test_root/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'config view -o json' ]] || exit 34
printf '%s\n' '{"contexts":[{"name":"demo","context":{"cluster":"fixture-cluster"}}]}'
FAKE_KUBECTL
chmod +x "$test_root/bin/nagarectl" "$test_root/bin/kubectl"
jq -n '{version: 1, desired: {scopes: []}}' > "$test_root/candidate/candidate.json"
sha256_file "$test_root/candidate/candidate.json" > "$test_root/candidate/candidate.sha256"

export NAGARECTL_BIN="$test_root/bin/nagarectl"
export PATH="$test_root/bin:$PATH"
runner="$repo_root/scripts/rehearse-managed-resources.sh"
common=(--mode local --context demo --expected-cluster fixture-cluster --evidence-dir "$test_root/evidence")

"$runner" --phase plan "${common[@]}" --candidate "$test_root/candidate" > "$test_root/plan.out"
jq -e '.state == "planned"' "$test_root/evidence/run.json" >/dev/null
if "$runner" --phase plan "${common[@]}" --candidate "$test_root/candidate" >/dev/null 2>&1; then
  printf 'existing review was overwritten\n' >&2
  exit 1
fi
if "$runner" --phase apply "${common[@]}" >/dev/null 2>&1; then
  printf 'apply without --yes was accepted\n' >&2
  exit 1
fi
if NAGARE_TEST_REVISION=changed "$runner" --phase apply "${common[@]}" --yes >/dev/null 2>&1; then
  printf 'changed operator revision was accepted\n' >&2
  exit 1
fi
jq -e '.state == "planned"' "$test_root/evidence/run.json" >/dev/null
"$runner" --phase apply "${common[@]}" --yes > "$test_root/apply.out"
jq -e '.state == "applied"' "$test_root/evidence/run.json" >/dev/null
"$runner" --phase verify "${common[@]}" --candidate "$test_root/candidate" > "$test_root/verify.out"
jq -e '.state == "verified" and .noOp == true' "$test_root/evidence/run.json" >/dev/null

if "$runner" --phase plan --mode local --context demo --expected-cluster wrong-cluster \
  --candidate "$test_root/candidate" --evidence-dir "$test_root/wrong-cluster" >/dev/null 2>&1; then
  printf 'wrong cluster was accepted\n' >&2
  exit 1
fi
[[ ! -e "$test_root/wrong-cluster" ]]
if "$runner" --phase plan --mode local --context demo --expected-cluster fixture-cluster \
  --expected-project foreign --candidate "$test_root/candidate" \
  --evidence-dir "$test_root/wrong-project" >/dev/null 2>&1; then
  printf 'local mode accepted a cloud project\n' >&2
  exit 1
fi
[[ ! -e "$test_root/wrong-project" ]]

other=(--mode local --context demo --expected-cluster fixture-cluster --evidence-dir "$test_root/non-noop")
"$runner" --phase plan "${other[@]}" --candidate "$test_root/candidate" >/dev/null
"$runner" --phase apply "${other[@]}" --yes >/dev/null
if NAGARE_TEST_NON_NOOP=1 "$runner" --phase verify "${other[@]}" \
  --candidate "$test_root/candidate" >/dev/null 2>&1; then
  printf 'non-no-op verification was accepted\n' >&2
  exit 1
fi
jq -e '.state == "applied"' "$test_root/non-noop/run.json" >/dev/null

interrupted=(--mode local --context demo --expected-cluster fixture-cluster --evidence-dir "$test_root/interrupted")
"$runner" --phase plan "${interrupted[@]}" --candidate "$test_root/candidate" >/dev/null
if NAGARE_TEST_FAIL_APPLY=1 "$runner" --phase apply "${interrupted[@]}" --yes >/dev/null 2>&1; then
  printf 'failed apply was accepted\n' >&2
  exit 1
fi
jq -e '.state == "applying"' "$test_root/interrupted/run.json" >/dev/null
if "$runner" --phase apply "${interrupted[@]}" --yes >/dev/null 2>&1; then
  printf 'ambiguous apply was repeated\n' >&2
  exit 1
fi

printf 'managed-resource rehearsal launcher tests passed\n'
