{ pkgs, nagarePackages, src }:

{
# Lint the shell scripts at error severity (clean on the current tree;
# SC1091 "not following sourced file" and SC2034 "appears unused" — the
# TARGET_* vars other scripts consume — are info/warning, not errors).
shellcheck-scripts = pkgs.runCommand "shellcheck-scripts"
  { nativeBuildInputs = [ pkgs.shellcheck ]; src = src; }
  ''
    cd "$src"
    shellcheck --severity=error \
      scripts/*.sh \
      scripts/lib/*.sh \
      cluster/bootstrap/render-context-template.sh \
      cluster/bootstrap/auth-images/build-local-image.sh \
      cluster/bootstrap/nagare-access/build-image.sh \
      nixos/hosts/nagare-01/forge-credentials-refresh.sh
    touch "$out"
  '';

# EP-113: the fail-closed GCS bucket-ownership assertion in
# scripts/lib/target.sh. Bucket names are global, so "the bucket
# exists" is not evidence that it is ours.
bucket-ownership-guard = pkgs.runCommand "nagare-bucket-ownership-guard-test"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
    src = src;
  }
  ''
    cd "$src"
    bash scripts/test-bucket-ownership-guard.sh
    touch "$out"
  '';

# EP-113: the auth-plane image builders take their project only from the
# active context, with no `gcloud config get-value project` fallback.
image-build-guard = pkgs.runCommand "nagare-image-build-guard-test"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.rsync ];
    src = src;
  }
  ''
    cd "$src"
    bash scripts/test-image-build-guard.sh
    touch "$out"
  '';

# EP-112: the cert-manager ClusterIssuer's ACME identity comes from the
# active context, and the renderer refuses — with EMPTY stdout — rather
# than inventing one.
render-context-template = pkgs.runCommand "nagare-render-context-template-test"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    src = src;
  }
  ''
    cd "$src"
    bash scripts/test-render-context-template.sh
    touch "$out"
  '';

# EP-112: no personal address and no specific project id may reappear as
# a default under cluster/bootstrap/, and the two Let's Encrypt directory
# URLs — which are deliberately duplicated between the shell resolver and
# the Haskell one — may not drift apart.
cluster-bootstrap-defaults = pkgs.runCommand "nagare-cluster-bootstrap-defaults"
  { nativeBuildInputs = [ pkgs.gnugrep pkgs.gnused pkgs.findutils ]; src = src; }
  ''
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
    # to happen — excepting the two test files that assert on them and
    # this file, which has to name them to perform this very check.
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
                -e '^\./cli/nagarectl/test/Spec\.hs$' \
                -e '^\./flake\.nix$' || true)"
      if [ -n "$stray" ]; then
        echo "$url is duplicated outside the two resolvers:" >&2
        echo "$stray" >&2
        exit 1
      fi
    done
    touch "$out"
  '';

forge-credential-refresh = pkgs.runCommand "nagare-forge-credential-refresh-test"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.jq pkgs.openssl ];
    src = src;
  }
  ''
    cd "$src"
    bash scripts/test-forge-credentials-refresh.sh
    touch "$out"
  '';
}
