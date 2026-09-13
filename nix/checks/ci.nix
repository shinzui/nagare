{ pkgs, nagarePackages, src }:

{
github-actions = pkgs.runCommand "github-actions"
  { nativeBuildInputs = [ pkgs.actionlint ]; src = src; }
  ''
    actionlint "$src/.github/workflows/"*.yml
    touch "$out"
  '';
}
