#!/usr/bin/env bash
# EP-112: prove that cluster/bootstrap/render-context-template.sh takes the ACME
# identity and the DNS-01 solver's project from the ACTIVE CONTEXT, and refuses —
# with empty standard output — when it has no contact or an unrecognized
# endpoint. "Empty standard output" is the machine-checkable form of "no
# ClusterIssuer is applied": `just cluster-bootstrap` renders to a file and
# applies only on success.
#
# The last scenario is the regression test for the two traps in this change: the
# renderer must still render a NON-ACME template with no contact configured, and
# a caller-supplied NAGARE_REGISTRY_PREFIX must still win over the value
# scripts/lib/target.sh derives (cluster/bootstrap/local-auth/install.sh passes
# one per invocation).
#
# No network, no gcloud, no pulumi, no cluster: every fixture context declares a
# project, which is the guardrail branch that compares two strings.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

ctx_dir="$test_root/config/nagare/contexts"
mkdir -p "$ctx_dir" "$test_root/state"

issuer_tmpl="$repo_root/cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl"
plain_tmpl="$repo_root/cluster/bootstrap/shomei/service.yaml"

write_cloud_context() {
  # $1: context name, remaining args: extra export lines.
  local name="$1"
  shift
  {
    printf '%s\n' \
      'export CLOUDSDK_CORE_PROJECT=acme-prod' \
      'export CLOUDSDK_COMPUTE_REGION=us-west1' \
      'export CLOUDSDK_COMPUTE_ZONE=us-west1-a' \
      'export NAGARE_BASE_DOMAIN=apps.acme.example' \
      'export NAGARE_MODE=cloud'
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
  } > "$ctx_dir/${name}.env"
}

cat > "$ctx_dir/localdev.env" <<'CTX'
export NAGARE_MODE=local
export NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io
export NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000
export NAGARE_LOCAL_OBJECT_STORE=http://127.0.0.1:9000/nagare-backups
CTX

# Render in a scrubbed environment so a developer's direnv-loaded profile cannot
# supply any value the context under test is supposed to provide. NAGARE_CONTEXT
# is deliberately kept: selecting the context is the point.
render() {
  local ctx="$1" template="$2"
  shift 2
  env -i \
    PATH="$PATH" \
    HOME="$test_root" \
    XDG_CONFIG_HOME="$test_root/config" \
    XDG_STATE_HOME="$test_root/state" \
    NAGARE_CONTEXT="$ctx" \
    "$@" \
    bash "$repo_root/cluster/bootstrap/render-context-template.sh" "$template"
}

out="$test_root/out"
err="$test_root/err"

# 1. A cloud context's OWN contact, project and production endpoint — none of
#    which matches any built-in default anywhere in the repository.
write_cloud_context acme 'export NAGARE_ACME_EMAIL=ops@acme.example'
render acme "$issuer_tmpl" > "$out" 2> "$err"
grep -q '^    email: ops@acme.example$' "$out"
grep -q '^            project: acme-prod$' "$out"
grep -q '^    server: https://acme-v02.api.letsencrypt.org/directory$' "$out"
echo "ok: cloud context renders its own contact, project and production endpoint"

# 2. The staging token selects Let's Encrypt's staging directory.
write_cloud_context acme \
  'export NAGARE_ACME_EMAIL=ops@acme.example' \
  'export NAGARE_ACME_DIRECTORY=staging'
render acme "$issuer_tmpl" > "$out" 2> "$err"
grep -q '^    server: https://acme-staging-v02.api.letsencrypt.org/directory$' "$out"
grep -q '^    email: ops@acme.example$' "$out"
echo "ok: staging token selects the staging directory"

# 3. No contact: refuse, name the field, and write NOTHING to standard output.
write_cloud_context acme
if render acme "$issuer_tmpl" > "$out" 2> "$err"; then
  echo "FAIL: a missing ACME contact was accepted" >&2
  cat "$err" >&2
  exit 1
fi
[ ! -s "$out" ] || {
  echo "FAIL: the refusal still wrote a renderable ClusterIssuer:" >&2
  cat "$out" >&2
  exit 1
}
grep -q 'NAGARE_ACME_EMAIL' "$err"
echo "ok: missing contact refuses with empty stdout"

# 4. An unrecognized endpoint token is an error, never a silent fallback to
#    production (which would burn a real rate limit) or staging (which would
#    install certificates no browser trusts).
write_cloud_context acme \
  'export NAGARE_ACME_EMAIL=ops@acme.example' \
  'export NAGARE_ACME_DIRECTORY=stagingg'
if render acme "$issuer_tmpl" > "$out" 2> "$err"; then
  echo "FAIL: an unrecognized ACME directory token was accepted" >&2
  cat "$err" >&2
  exit 1
fi
[ ! -s "$out" ] || {
  echo "FAIL: the refusal still wrote output" >&2
  exit 1
}
grep -q 'NAGARE_ACME_DIRECTORY' "$err"
echo "ok: unrecognized directory token refuses"

# 5. The local auth path is untouched: a non-ACME template renders with no
#    contact anywhere, and the caller's explicit registry prefix still wins.
render localdev "$plain_tmpl" \
  NAGARE_REGISTRY_PREFIX=k3d-registry.localhost:5000 \
  NAGARE_AUTH_TAG=testtag > "$out" 2> "$err"
grep -q '^          image: k3d-registry.localhost:5000/shomei:testtag$' "$out" || {
  echo "FAIL: the caller's registry prefix did not survive sourcing the resolver:" >&2
  grep 'image:' "$out" >&2
  exit 1
}
echo "ok: non-ACME template renders with no contact and honors the caller's registry prefix"
