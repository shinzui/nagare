{ ... }:

{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--disable=traefik"
      "--write-kubeconfig-mode=0644"
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
