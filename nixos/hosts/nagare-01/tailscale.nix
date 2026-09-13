{ config, ... }:

{
  services.tailscale = {
    enable = true;
    # The decrypted auth key, provided by the sops secret declared in
    # configuration.nix. sops-nix writes it to this runtime path at activation.
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    # Open the firewall for the tailscale interface and accept the default
    # join behavior (ephemeral=false so the node persists in the tailnet).
    extraUpFlags = [ "--ssh" "--accept-dns=false" ];
    # Keep the host's resolvers exactly as `networking.nameservers` declares
    # (networking.nix). MagicDNS would repoint /etc/resolv.conf at 100.100.100.100,
    # which k3s pods inherit through CoreDNS. `extraSetFlags` re-applies this to an
    # already-joined node on every start (ExecPlan 118).
    extraSetFlags = [ "--accept-dns=false" ];
  };
}
