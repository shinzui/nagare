#!/usr/bin/env bash
set -euo pipefail

operator_package="$1"
cli_package="$2"
unwrapped_cli="$3"
platform_root="$4"
jq_bin="$5"
coreutils_bin="$6"
bash_bin="$7"
grep_bin="$8"

mkdir -p packaged/home packaged/config packaged/state packaged/empty
export HOME="$PWD/packaged/home"
export XDG_CONFIG_HOME="$PWD/packaged/config"
export XDG_STATE_HOME="$PWD/packaged/state"
export PATH="$operator_package/bin"
cd packaged/empty

test ! -e "$operator_package/lib/links"
test ! -e "$cli_package/lib/links"
"$operator_package/bin/nagarectl" version --json > version.json
"$jq_bin" -e '.version != null' version.json >/dev/null
"$operator_package/bin/nagarectl" version --json --tools > tools.json
"$jq_bin" -e '.tools.pulumi | startswith("/nix/store/")' tools.json >/dev/null
"$jq_bin" -e '.tools["pulumi-language-nodejs"] != null' tools.json >/dev/null
"$jq_bin" -e '.tools.socat | startswith("/nix/store/")' tools.json >/dev/null
pulumi_bin="$("$jq_bin" -er '.tools.pulumi' tools.json)"
"$pulumi_bin" version >/dev/null
"$operator_package/bin/nagare" --list >/dev/null

cd ../..
export PATH="$coreutils_bin/bin"
mkdir -p absent/fake-tools absent/home absent/config absent/state
tool_log="$PWD/absent/tools.log"
: > "$tool_log"

for tool in gcloud npm; do
  tool_path="$PWD/absent/fake-tools/$tool"
  printf '#!%s/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "${NAGARE_FAKE_TOOL_LOG:?}"\n' \
    "$bash_bin" "$tool" > "$tool_path"
  chmod +x "$tool_path"
done

export HOME="$PWD/absent/home"
export XDG_CONFIG_HOME="$PWD/absent/config"
export XDG_STATE_HOME="$PWD/absent/state"
export NAGARE_PLATFORM_ROOT="$platform_root"
export NAGARE_FAKE_TOOL_LOG="$tool_log"
export PATH="$PWD/absent/fake-tools:$coreutils_bin/bin"

if "$unwrapped_cli" init nopulumi --project p --acme-email ops@example.com \
  > absent/init.out 2> absent/init.err; then
  echo "unwrapped nagarectl unexpectedly initialized without Pulumi" >&2
  cat absent/init.out absent/init.err >&2
  exit 1
fi
"$grep_bin" -q 'required tools are not on PATH: pulumi' absent/init.err
test ! -s "$tool_log"
test ! -e "$XDG_CONFIG_HOME/nagare/contexts/nopulumi.env"

# EP-129 / IR-9: a cloud context guard without Pulumi must report the
# unavailable executable, not claim that the selected stack lacks gcp:project.
mkdir -p "$HOME/.config/gcloud"
printf '%s\n' \
  '{"type":"authorized_user","client_id":"fixture","client_secret":"fixture","refresh_token":"fixture","quota_project_id":"acme-prod"}' \
  > "$HOME/.config/gcloud/application_default_credentials.json"
"$unwrapped_cli" context create guardcloud \
  --project acme-prod \
  --region us-west1 \
  --zone us-west1-a \
  --base-domain apps.acme.example
export CLOUDSDK_CORE_PROJECT=acme-prod
expected_backend="file://$XDG_STATE_HOME/nagare/guardcloud/state"

if "$unwrapped_cli" --context guardcloud context guard \
  > absent/guard-missing.out 2> absent/guard-missing.err; then
  echo "unwrapped context guard unexpectedly accepted missing Pulumi" >&2
  exit 1
fi
"$grep_bin" -q 'pulumi was not found on PATH' absent/guard-missing.err
"$grep_bin" -q 'guardcloud' absent/guard-missing.err
"$grep_bin" -q "$expected_backend" absent/guard-missing.err
if "$grep_bin" -q 'declares no gcp:project' absent/guard-missing.err; then
  echo "context guard misdiagnosed missing Pulumi as an absent project" >&2
  exit 1
fi

if "$unwrapped_cli" --context guardcloud context guard --json \
  > absent/guard-missing-json.out 2> absent/guard-missing.json; then
  echo "unwrapped JSON context guard unexpectedly accepted missing Pulumi" >&2
  exit 1
fi
test ! -s absent/guard-missing-json.out
if ! "$jq_bin" -e '
  .confined == false and
  .observations.stack == "guardcloud" and
  .observations.pulumiBackendUrl == $backend and
  .observations.stackProject == null and
  .observations.stackProjectProbe.status == "tool-not-found"
' --arg backend "$expected_backend" absent/guard-missing.json >/dev/null; then
  echo "context guard did not emit the expected standalone JSON failure:" >&2
  cat absent/guard-missing.json >&2
  exit 1
fi

touch "$out"
