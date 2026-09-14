{ pkgs, nagarePackages, src }:

{
  infra-vm-shape = pkgs.runCommand "nagare-infra-vm-shape-test"
    { nativeBuildInputs = [ pkgs.nodejs pkgs.typescript ]; src = src; }
    ''
      mkdir build
      tsc --strict --target ES2020 --module commonjs --outDir build \
        "$src/infra/pulumi/src/vmShape.ts" \
        "$src/infra/pulumi/test/vmShape.test.ts"
      node build/test/vmShape.test.js | grep -qx ok
      touch "$out"
    '';

  infra-domain-topology = pkgs.runCommand "nagare-infra-domain-topology-test"
    { nativeBuildInputs = [ pkgs.nodejs pkgs.typescript ]; src = src; }
    ''
      mkdir build
      tsc --strict --target ES2020 --module commonjs --outDir build \
        "$src/infra/pulumi/src/domainTopology.ts" \
        "$src/infra/pulumi/test/domainTopology.test.ts"
      node build/test/domainTopology.test.js | grep -qx ok
      touch "$out"
    '';

  host-module-options-agree = pkgs.runCommand "nagare-host-module-options-agree"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.gnused ]; src = src; }
    ''
      bash ${./scripts/host-module-options-agree.sh}
    '';

  vm-shape-defaults-agree = pkgs.runCommand "nagare-vm-shape-defaults-agree"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.gnused ]; src = src; }
    ''
      bash ${./scripts/vm-shape-defaults-agree.sh}
    '';
}
