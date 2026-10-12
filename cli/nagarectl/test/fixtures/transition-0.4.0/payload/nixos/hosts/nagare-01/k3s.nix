{ ... }:

{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--disable=traefik"
      # Keep the root-owned cluster-admin kubeconfig available to wheel members
      # such as deploy, without exposing it to every local process.
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
      # Encrypt Secret objects before they reach the datastore. Existing clusters
      # still require the documented online enable/rotation procedure; fresh
      # clusters start encrypted from their first Secret.
      "--secrets-encryption"
      "--default-local-storage-path=/var/lib/nagare/local-path"
    ];
  };

  # The kubeconfig is root:wheel 0640, so wheel members also need search
  # permission on its parent directory. Keep this declarative: the registry
  # bootstrap unit creates the same directory before k3s starts and must not
  # accidentally reduce it back to root-only access.
  systemd.tmpfiles.rules = [
    "d /etc/rancher/k3s 0750 root wheel - -"
  ];

  # k3s needs the storage mount AND the /var/lib/nagare subdirectory layout to
  # exist before it starts, so the local-path-provisioner's storage path
  # (/var/lib/nagare/local-path) is present. Order the unit after both the
  # mount and the layout oneshot (see storage.nix).
  systemd.services.k3s.after = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];
  systemd.services.k3s.requires = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];

  # Retrying the mount must also retry k3s after a transient first-boot mount
  # failure. wantedBy creates var-lib-nagare.mount.wants/k3s.service without
  # weakening the Requires/After edges above, so k3s can never fall through to
  # an unmounted /var/lib/nagare path.
  systemd.services.k3s.wantedBy = [ "var-lib-nagare.mount" ];
}
