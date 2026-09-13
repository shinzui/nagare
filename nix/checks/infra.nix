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

  vm-shape-defaults-agree = pkgs.runCommand "nagare-vm-shape-defaults-agree"
    { nativeBuildInputs = [ pkgs.coreutils pkgs.gnused ]; src = src; }
    ''
      bash ${./scripts/vm-shape-defaults-agree.sh}
    '';
}
