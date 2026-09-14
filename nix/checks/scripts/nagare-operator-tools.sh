#!/usr/bin/env bash
set -euo pipefail

operator_package="$1"
unwrapped_cli="$2"
platform_root="$3"
jq_bin="$4"
coreutils_bin="$5"
bash_bin="$6"
grep_bin="$7"

mkdir -p packaged/home packaged/config packaged/state packaged/empty
export HOME="$PWD/packaged/home"
export XDG_CONFIG_HOME="$PWD/packaged/config"
export XDG_STATE_HOME="$PWD/packaged/state"
export PATH="$operator_package/bin"
cd packaged/empty

"$operator_package/bin/nagarectl" version --json --tools > tools.json
"$jq_bin" -e '.tools.pulumi | startswith("/nix/store/")' tools.json >/dev/null
"$jq_bin" -e '.tools["pulumi-language-nodejs"] != null' tools.json >/dev/null
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

touch "$out"
