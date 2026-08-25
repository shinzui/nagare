{ ... }:

{
  # DNS. On this VM the GCE metadata server (169.254.169.254) — which DHCP
  # hands out as the resolver — is unreachable (ping/HTTP/DNS all fail), so
  # name resolution broke and k3s could not pull container images
  # ("Temporary failure in name resolution"; see EP-3 Surprises). Use public
  # resolvers and stop dhcpcd from overwriting resolv.conf with the broken
  # metadata nameserver. `metadata.google.internal` is still resolvable via
  # /etc/hosts (set by the GCE config), so the guest agent is unaffected.
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  # Pin the GCE metadata server (169.254.169.254) to the primary NIC with a
  # /32 host route. This is the robust fix for the IPv4LL hijack: k3s/flannel
  # self-assigns a 169.254.0.0/16 address to flannel.1 and the per-pod veths,
  # whose on-link /16 route otherwise captures the metadata IP into the VXLAN
  # overlay (`ip route get 169.254.169.254` -> dev flannel.1), black-holing it.
  # A /32 always beats any /16, so this guarantees metadata reachability from the
  # host (and, with the MASQUERADE below, from pods) regardless of what dhcpcd or
  # flannel do to the link-local addresses. Without it, keyless Application
  # Default Credentials break for every in-cluster GCP client — Litestream backups
  # (EP-7), managed-database backups (MP-9 EP-47), and cert-manager DNS-01
  # wildcard TLS (EP-4) all fail with "no route to host" / "could not find default
  # credentials". (The earlier assumption that DHCP leaves a /32 metadata route on
  # eth0 was wrong — GCE hands out only the default route, so the /16 always won;
  # MP-9 EP-43 caught this. Verified live: this route restores host + in-pod
  # metadata access and the litestream sidecar resumed writing WAL segments.)
  networking.interfaces.eth0.ipv4.routes = [
    {
      address = "169.254.169.254";
      prefixLength = 32;
      # No `via`: GCE answers ARP for the metadata IP on the primary link, so a
      # scope-link route out eth0 reaches it without depending on the subnet
      # gateway address.
    }
  ];

  # Also stop dhcpcd from assigning the spurious IPv4LL /16 addresses in the first
  # place (defense in depth — the /32 above already wins, but this keeps the
  # routing table clean of dozens of bogus 169.254.0.0/16 entries).
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
