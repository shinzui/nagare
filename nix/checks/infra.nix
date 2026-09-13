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
    ts="$src/infra/pulumi/src/vmShape.ts"
    hs="$src/cli/nagarectl/src/Nagare/Target.hs"
    compare_default() {
      label="$1"
      ts_pattern="$2"
      hs_pattern="$3"
      ts_value="$(sed -n "$ts_pattern" "$ts" | head -n 1)"
      hs_value="$(sed -n "$hs_pattern" "$hs" | head -n 1)"
      test -n "$ts_value"
      test "$ts_value" = "$hs_value" || {
        echo "$label default differs: TypeScript=$ts_value Haskell=$hs_value" >&2
        exit 1
      }
    }
    compare_default machineType 's/^[[:space:]]*machineType: "\([^"]*\)",/\1/p' 's/^[[:space:]]*[{,][[:space:]]*machineType = "\([^"]*\)".*/\1/p'
    compare_default bootDiskType 's/^[[:space:]]*bootDiskType: "\([^"]*\)",/\1/p' 's/^[[:space:]]*[{,][[:space:]]*bootDiskType = "\([^"]*\)".*/\1/p'
    compare_default bootDiskSizeGb 's/^[[:space:]]*bootDiskSizeGb: \([0-9][0-9]*\),/\1/p' 's/^[[:space:]]*[{,][[:space:]]*bootDiskSizeGb = "\([0-9][0-9]*\)".*/\1/p'
    compare_default dataDiskSizeGb 's/^[[:space:]]*dataDiskSizeGb: \([0-9][0-9]*\),/\1/p' 's/^[[:space:]]*[{,][[:space:]]*dataDiskSizeGb = "\([0-9][0-9]*\)".*/\1/p'
    touch "$out"
  '';
}
