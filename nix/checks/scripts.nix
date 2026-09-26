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
        cluster/bootstrap/nix-cache/*.sh \
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

  observability-grafana = pkgs.runCommand "nagare-observability-grafana-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.yq-go ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-observability-grafana.sh
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

  # MP-23 EP-146: a transport invoked while the inventory lock is held must
  # belong to the current typed adapter. Foreign/nested entry points fail
  # before context resolution or any provider process can run.
  inventory-transport-guards = pkgs.runCommand "nagare-inventory-transport-guards-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.jq ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-inventory-transport-guards.sh
      touch "$out"
    '';

  inventory-entrypoint-guards = pkgs.runCommand "nagare-inventory-entrypoint-guards-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.python3 ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-inventory-entrypoint-guards.sh ${nagarePackages.nagarectl}/bin/nagarectl
      touch "$out"
    '';

  # MP-22 EP-139 / IR-11: rehearse the complete public GCP bootstrap ordering
  # and its focused refusals without cloud access. The check also locks the
  # truthful boot-disk replacement wording in rendered CLI help and user docs.
  gcp-bootstrap-rehearsal = pkgs.runCommand "nagare-gcp-bootstrap-rehearsal"
    {
      nativeBuildInputs = [
        nagarePackages.nagare
        pkgs.bash
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.ripgrep
      ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/rehearse-gcp-bootstrap.sh --hermetic
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

  net-certmanager-controller-install = pkgs.runCommand "nagare-net-certmanager-controller-install-test"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      inherit src;
    }
    ''
      cd "$src"
      bash scripts/test-install-net-certmanager-controller.sh
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

  bootstrap-vendor-assets = pkgs.runCommand "nagare-bootstrap-vendor-assets"
    { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils ]; inherit src; }
    ''
      cd "$src"
      bash scripts/test-bootstrap-vendor-assets.sh
      touch "$out"
    '';

  # EP-96: the optional Attic provider remains digest-pinned, hardened, and
  # syntactically renderable without requiring a live Kubernetes API server.
  nix-cache-bootstrap-assets = pkgs.runCommand "nagare-nix-cache-bootstrap-assets"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.gnugrep pkgs.gnused pkgs.yq-go ];
      inherit src;
      checkScript = ./scripts/nix-cache-bootstrap-assets.sh;
    }
    ''
      cd "$src"
      bash "$checkScript"
      touch "$out"
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
