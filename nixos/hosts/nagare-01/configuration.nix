{ ... }:

{
  imports = [
    ./networking.nix
    ./storage.nix
    ./users.nix
    ./security.nix
    ./k3s.nix
    ./tailscale.nix
    ./registries.nix
  ];

  # sops-nix: decrypt secrets at activation using an age key on the host.
  # The encrypted file is committed to Git; the private age key lives only on
  # the host at the path below (placed before first boot — see the plan's
  # Concrete Steps). EP-7 expands this; here we manage exactly one secret.
  sops.defaultSopsFile = ./secrets/nagare-01.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/age-key.txt";

  # The Tailscale pre-authentication key. tailscale.nix consumes this path.
  sops.secrets."tailscale/authkey" = {
    # Mode 0400 owned by root; tailscaled reads it as root at start.
    mode = "0400";
  };
}
