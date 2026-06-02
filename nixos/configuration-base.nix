{ pkgs, ... }:

{
  imports = [ ./modules/gcp.nix ];

  services.gcp.enable = true;

  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [ vim curl git jq ];

  # Flakes are required for `nixos-rebuild --flake`. trusted-users lets the
  # deploy user push a closure during a remote rebuild without sudo for nix.
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # State version pins the semantics of stateful options. Match the nixpkgs
  # release line; never bump on an existing system without a migration.
  system.stateVersion = "26.05";
}
