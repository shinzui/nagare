{ pkgs, ... }:

let
  # The device name EP-2 assigns to the attached data disk. GCP surfaces it at
  # /dev/disk/by-id/google-<deviceName>. EP-2's NagareInstance.ts attaches the
  # disk with deviceName "nagare-data", confirmed against that component.
  dataDiskDevice = "/dev/disk/by-id/google-nagare-data";
in
{
  # EP-2 attaches a BLANK persistent disk (no filesystem). Format it ext4 on
  # first boot if and only if it has no filesystem yet, then the mount below
  # can succeed. Without this, the mount fails and k3s (which requires the
  # mount, see k3s.nix) never starts. This is idempotent: once a filesystem
  # exists, blkid reports it and we skip mkfs, so existing data is never
  # touched. Discovered when the first nagare-01 boot left k3s with
  # "Dependency failed for k3s service" because the blank disk would not mount.
  systemd.services.format-nagare-data = {
    description = "Format the Nagare data disk on first boot if it is blank";
    wantedBy = [ "var-lib-nagare.mount" ];
    before = [ "var-lib-nagare.mount" ];
    # The attached disk's by-id device node exists early in boot (udev), well
    # before the local-fs mount is processed, so ConditionPathExists is a
    # sufficient and robust guard without naming the (awkwardly-escaped)
    # systemd .device unit. If the disk is somehow absent, the condition skips
    # the service and the nofail mount simply does not mount.
    unitConfig.ConditionPathExists = dataDiskDevice;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.util-linux pkgs.e2fsprogs ];
    script = ''
      if ! blkid ${dataDiskDevice} >/dev/null 2>&1; then
        echo "no filesystem on ${dataDiskDevice}; creating ext4"
        mkfs.ext4 -F -L nagare-data ${dataDiskDevice}
      else
        echo "${dataDiskDevice} already has a filesystem; leaving it alone"
      fi
    '';
  };

  fileSystems."/var/lib/nagare" = {
    device = dataDiskDevice;
    fsType = "ext4";
    # nofail so a transient disk problem never wedges the whole boot; the
    # format-nagare-data oneshot above ensures the disk is formatted first.
    options = [ "defaults" "nofail" ];
  };

  # Create the IP-3 subdirectory layout AFTER the disk is mounted. This must
  # not use systemd.tmpfiles.rules: those run at systemd-tmpfiles-setup, which
  # can fire before the (nofail, possibly-just-formatted) data disk is mounted
  # — the dirs would then be created on the root fs and immediately shadowed by
  # the mount, leaving only lost+found visible under /var/lib/nagare (observed
  # on the first boot; see EP-3 Surprises). Ordering an explicit oneshot after
  # the mount guarantees the dirs land on the data disk. Idempotent.
  systemd.services.nagare-data-layout = {
    description = "Create the /var/lib/nagare subdirectory layout (IP-3)";
    wantedBy = [ "multi-user.target" ];
    after = [ "var-lib-nagare.mount" ];
    requires = [ "var-lib-nagare.mount" ];
    unitConfig.RequiresMountsFor = "/var/lib/nagare";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0755 \
        /var/lib/nagare/victoria-metrics \
        /var/lib/nagare/victoria-logs \
        /var/lib/nagare/victoria-traces \
        /var/lib/nagare/postgres \
        /var/lib/nagare/sqlite \
        /var/lib/nagare/backups \
        /var/lib/nagare/local-path
    '';
  };
}
