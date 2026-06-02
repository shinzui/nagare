{ ... }:

{
  networking.hostName = "nagare-01";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    # Trust the Tailscale interface so the tailnet can reach node services
    # (e.g. the kube-apiserver on 6443) without opening them to the world.
    trustedInterfaces = [ "tailscale0" ];
    # Let Tailscale's UDP discovery work through the firewall.
    allowedUDPPorts = [ 41641 ];
  };
}
