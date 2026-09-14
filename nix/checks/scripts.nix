{ pkgs, nagarePackages, src }:

{
  # Lint the shell scripts at error severity (clean on the current tree;
  # SC1091 "not following sourced file" and SC2034 "appears unused" — the
  # TARGET_* vars other scripts consume — are info/warning, not errors).
  shellcheck-scripts = pkgs.runCommand "shellcheck-scripts"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
      inherit src;
      checkScripts = ./scripts;
    }
    ''
      cd "$src"
      shellcheck --severity=error \
        scripts/*.sh \
        scripts/lib/*.sh \
        cluster/bootstrap/render-context-template.sh \
        cluster/bootstrap/auth-images/build-local-image.sh \
        cluster/bootstrap/nagare-access/build-image.sh \
        nixos/hosts/nagare-01/forge-credentials-refresh.sh \
        "$checkScripts"/*.sh
      touch "$out"
    '';

  # EP-113: the fail-closed GCS bucket-ownership assertion in
  # scripts/lib/target.sh. Bucket names are global, so "the bucket
  # exists" is not evidence that it is ours.
  bucket-ownership-guard = pkgs.runCommand "nagare-bucket-ownership-guard-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
      inherit src;
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
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-image-build-guard.sh
      touch "$out"
    '';

  # EP-136 / IR-17: host-image renders and passes one context-owned builder,
  # refuses a foreign project by default, and records an explicit exception.
  upload-images-builder-confinement = pkgs.runCommand "nagare-upload-images-builder-confinement-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gzip ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-upload-images.sh
      touch "$out"
    '';

  # EP-112: the cert-manager ClusterIssuer's ACME identity comes from the
  # active context, and the renderer refuses — with EMPTY stdout — rather
  # than inventing one.
  render-context-template = pkgs.runCommand "nagare-render-context-template-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-render-context-template.sh
      touch "$out"
    '';

  # EP-132: fresh cloud and local bootstrap wait for Knative admission
  # endpoints, and their convergent ConfigMap patches have bounded retries.
  knative-bootstrap-readiness = pkgs.runCommand "nagare-knative-bootstrap-readiness-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.just ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-knative-bootstrap-readiness.sh
      touch "$out"
    '';

  # EP-138 / IR-22 / IR-23: public ACME issuance is external-domain-only and
  # wildcard certificates are limited to explicitly opted-in app namespaces.
  cluster-certificate-policy = pkgs.runCommand "nagare-cluster-certificate-policy-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.gawk pkgs.gnugrep pkgs.just pkgs.yq-go ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-cluster-certificate-policy.sh
      touch "$out"
    '';

  # EP-112: no personal address and no specific project id may reappear as
  # a default under cluster/bootstrap/, and the two Let's Encrypt directory
  # URLs — which are deliberately duplicated between the shell resolver and
  # the Haskell one — may not drift apart.
  cluster-bootstrap-defaults = pkgs.runCommand "nagare-cluster-bootstrap-defaults"
    { nativeBuildInputs = [ pkgs.gnugrep pkgs.gnused pkgs.findutils ]; inherit src; }
    ''
      bash ${./scripts/cluster-bootstrap-defaults.sh}
    '';

  forge-credential-refresh = pkgs.runCommand "nagare-forge-credential-refresh-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.jq pkgs.openssl ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-forge-credentials-refresh.sh
      touch "$out"
    '';
}
