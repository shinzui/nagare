{ config, ... }:

{
  services.tailscale = {
    enable = true;
    # The decrypted auth key, provided by the sops secret declared in
    # configuration.nix. sops-nix writes it to this runtime path at activation.
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    # Open the firewall for the tailscale interface and accept the default
    # join behavior (ephemeral=false so the node persists in the tailnet).
    extraUpFlags = [ "--ssh" ];
  };
}
