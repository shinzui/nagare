# shellcheck shell=bash

set -euo pipefail
umask 077

role=${1:?missing role}
app_id_file=${2:?missing App ID path}
installation_id_file=${3:?missing installation ID path}
private_key_file=${4:?missing private-key path}
kubernetes_secret=${5:?missing Kubernetes Secret name}
namespace=${6:?missing Kubernetes namespace}
source_version=${7:?missing host credential source version}
runtime_dir="${RUNTIME_DIRECTORY:?systemd did not provide RUNTIME_DIRECTORY}"

[[ "$source_version" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'invalid host credential source version' >&2
  exit 1
}

jwt_file="$runtime_dir/github-app.jwt"
curl_config="$runtime_dir/github-api.curlrc"
response_file="$runtime_dir/github-api-response.json"
token_file="$runtime_dir/token"
github_token_file="$runtime_dir/GITHUB_TOKEN"
expiry_file="$runtime_dir/expires_at"

cleanup() {
  rm -f -- "$jwt_file" "$curl_config" "$response_file"
}
trap cleanup EXIT

fail() {
  printf 'nagare-forge-%s-refresh: %s\n' "$role" "$1" >&2
  exit 1
}

app_id="$(tr -d '[:space:]' < "$app_id_file")"
installation_id="$(tr -d '[:space:]' < "$installation_id_file")"
[[ "$app_id" =~ ^[0-9]+$ ]] || fail "App ID is not a positive integer"
[[ "$installation_id" =~ ^[0-9]+$ ]] || fail "installation ID is not a positive integer"
[ "$app_id" != 0 ] || fail "App ID is not a positive integer"
[ "$installation_id" != 0 ] || fail "installation ID is not a positive integer"

base64url() {
  base64 --wrap=0 | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
issued_at="$((now - 60))"
expires_at="$((now + 540))"
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)"
payload="$(jq -cn \
  --argjson iat "$issued_at" \
  --argjson exp "$expires_at" \
  --argjson iss "$app_id" \
  '{iat: $iat, exp: $exp, iss: $iss}' | base64url)"
unsigned_jwt="$header.$payload"
if ! signature="$(printf '%s' "$unsigned_jwt" \
  | openssl dgst -sha256 -sign "$private_key_file" -binary \
  | base64url)"; then
  fail "could not sign the GitHub App JWT"
fi
printf '%s' "$unsigned_jwt.$signature" > "$jwt_file"

# Keep the bearer credential out of argv and the journal. The config and
# response are root-only files in systemd's private runtime directory.
{
  printf '%s\n' \
    'silent' \
    'show-error' \
    'fail-with-body' \
    'request = "POST"' \
    'header = "Accept: application/vnd.github+json"' \
    "header = \"Authorization: Bearer $(< "$jwt_file")\"" \
    'header = "X-GitHub-Api-Version: 2026-03-10"' \
    "url = \"https://api.github.com/app/installations/$installation_id/access_tokens\"" \
    "output = \"$response_file\"" \
    'write-out = "%{http_code}"'
} > "$curl_config"

http_status=""
if ! http_status="$(curl --config "$curl_config")"; then
  fail "GitHub rejected the installation-token request (HTTP ${http_status:-unknown})"
fi
case "$http_status" in
  2??) ;;
  *) fail "GitHub rejected the installation-token request (HTTP $http_status)" ;;
esac

next_token="$runtime_dir/token.next"
next_expiry="$runtime_dir/expires_at.next"
if ! jq -er '.token | select(type == "string" and length > 0)' \
  "$response_file" > "$next_token"; then
  fail "GitHub returned a malformed installation-token response"
fi
if ! jq -er \
  '.expires_at | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
  "$response_file" > "$next_expiry"; then
  rm -f -- "$next_token" "$next_expiry"
  fail "GitHub returned a malformed installation-token expiry"
fi
next_expiry_epoch="$(date -u -d "$(< "$next_expiry")" +%s)" \
  || fail "GitHub returned an unreadable installation-token expiry"
if [ "$next_expiry_epoch" -le "$((now + 300))" ]; then
  rm -f -- "$next_token" "$next_expiry"
  fail "GitHub returned an installation token with less than five minutes remaining"
fi

mv -f -- "$next_token" "$token_file"
cp -- "$token_file" "$github_token_file"
mv -f -- "$next_expiry" "$expiry_file"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! existing_secret="$(k3s kubectl -n "$namespace" get secret "$kubernetes_secret" --ignore-not-found -o json)"; then
  fail "could not inspect the Kubernetes Secret before refresh"
fi
if [ -n "$existing_secret" ] && ! printf '%s' "$existing_secret" \
  | jq -e '.metadata.annotations["nagare.dev/delegated-owner"] == "host-forge-timer"' >/dev/null; then
  fail "Kubernetes Secret is not owned by the host forge timer"
fi
write_action=create
resource_version=""
if [ -n "$existing_secret" ]; then
  write_action=replace
  resource_version="$(printf '%s' "$existing_secret" | jq -er '.metadata.resourceVersion | select(type == "string" and length > 0)')" \
    || fail "Kubernetes Secret has no resource version"
fi
if ! k3s kubectl -n "$namespace" create secret generic "$kubernetes_secret" \
  --from-file="token=$token_file" \
  --from-file="GITHUB_TOKEN=$github_token_file" \
  --from-file="expires_at=$expiry_file" \
  --dry-run=client -o json \
  | jq --arg version "$source_version" --arg expiry "$(< "$expiry_file")" --arg rv "$resource_version" \
      '(if $rv == "" then del(.metadata.resourceVersion) else .metadata.resourceVersion = $rv end)
      | .metadata.annotations = ((.metadata.annotations // {}) + {
        "nagare.dev/delegated-owner": "host-forge-timer",
        "nagare.dev/credential-source-version": $version,
        "nagare.dev/credential-expires-at": $expiry
      })' \
  | k3s kubectl -n "$namespace" "$write_action" -f -; then
  fail "could not publish the Kubernetes Secret"
fi
