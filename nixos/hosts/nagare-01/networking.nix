{ ... }:

{
  networking.hostName = "nagare-01";

  # DNS. On this VM the GCE metadata server (169.254.169.254) — which DHCP
  # hands out as the resolver — is unreachable (ping/HTTP/DNS all fail), so
  # name resolution broke and k3s could not pull container images
  # ("Temporary failure in name resolution"; see EP-3 Surprises). Use public
  # resolvers and stop dhcpcd from overwriting resolv.conf with the broken
  # metadata nameserver. `metadata.google.internal` is still resolvable via
  # /etc/hosts (set by the GCE config), so the guest agent is unaffected.
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

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
