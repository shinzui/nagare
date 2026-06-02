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

  # k3s needs the storage mount to exist before it starts so the
  # local-path-provisioner path is valid. Order the unit after the mount.
  systemd.services.k3s.after = [ "var-lib-nagare.mount" ];
  systemd.services.k3s.requires = [ "var-lib-nagare.mount" ];
}
