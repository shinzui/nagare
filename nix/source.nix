# The repository source that checks and the platform payload build from. The Nix wiring
# itself (root flake.nix, flake.lock, and nix/) is excluded, so refactoring the flake does
# not change any check's derivation and editing it does not re-run every check.
{ lib, root }:

let
  rootString = toString root;
  isNixWiring = path:
    let p = toString path;
    in p == "${rootString}/flake.nix"
      || p == "${rootString}/flake.lock"
      || p == "${rootString}/nix"
      || lib.hasPrefix "${rootString}/nix/" p;
in
{
  inherit isNixWiring;
  src = lib.cleanSourceWith {
    name = "nagare-source";
    src = root;
    filter = path: _type: !(isNixWiring path);
  };
}
