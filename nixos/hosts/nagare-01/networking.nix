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

  # Stop dhcpcd from assigning IPv4 link-local (169.254.0.0/16) addresses to the
  # k3s/flannel/CNI interfaces. Without this, flannel.1 (and the per-pod veths)
  # self-assign a 169.254/16 address whose on-link route HIJACKS the GCE metadata
  # server 169.254.169.254 into the VXLAN overlay (`ip route get 169.254.169.254`
  # -> dev flannel.1). The host and pods then cannot reach the metadata server, so
  # keyless Application Default Credentials break for in-cluster GCP access —
  # Litestream backups (EP-7) and cert-manager's DNS-01 wildcard TLS (EP-4) both
  # fail with "no route to host" / "could not find default credentials". Denying
  # these interfaces leaves the GCE-provided /32 metadata route on eth0 intact.
  networking.dhcpcd.denyInterfaces = [ "veth*" "flannel*" "cni*" "kube*" "datapath*" ];

  # Pods reach the metadata server via the node; SNAT their traffic to the node's
  # primary IP so the metadata server (which only serves the instance identity)
  # accepts the request and the reply routes back. flannel's default masquerade
  # excludes link-local destinations, so add an explicit rule for the metadata IP.
  networking.firewall.extraCommands = ''
    iptables -t nat -C POSTROUTING -d 169.254.169.254/32 -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -d 169.254.169.254/32 -j MASQUERADE
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t nat -D POSTROUTING -d 169.254.169.254/32 -j MASQUERADE 2>/dev/null || true
  '';

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
