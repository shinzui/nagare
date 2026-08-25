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

  # k3s needs the storage mount AND the /var/lib/nagare subdirectory layout to
  # exist before it starts, so the local-path-provisioner's storage path
  # (/var/lib/nagare/local-path) is present. Order the unit after both the
  # mount and the layout oneshot (see storage.nix).
  systemd.services.k3s.after = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];
  systemd.services.k3s.requires = [ "var-lib-nagare.mount" "nagare-data-layout.service" ];
}
