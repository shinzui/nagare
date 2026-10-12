{ pkgs, utils, ... }:

let
  # The device name EP-2 assigns to the attached data disk. GCP surfaces it at
  # /dev/disk/by-id/google-<deviceName>. EP-2's NagareInstance.ts attaches the
  # disk with deviceName "nagare-data", confirmed against that component.
  dataDiskDevice = "/dev/disk/by-id/google-nagare-data";
  dataDiskDeviceUnit = "${utils.escapeSystemdPath dataDiskDevice}.device";
  dataDiskFsckUnit = "systemd-fsck@${utils.escapeSystemdPath dataDiskDevice}.service";
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
    # systemd-fstab-generator schedules fsck for the same device as the mount.
    # With DefaultDependencies disabled there is no implicit edge between that
    # fsck and this formatter, so explicitly serialize the two consumers of a
    # blank disk. Otherwise fsck can open the device while mkfs is writing it.
    before = [ dataDiskFsckUnit "var-lib-nagare.mount" ];
    # ConditionPathExists guards against an absent disk: the service skips and
    # the nofail mount simply does not mount.
    #
    # DefaultDependencies must be OFF. With them on, systemd gives this service
    # an implicit After=basic.target, and once the mount below carries
    # autoResize (x-systemd.growfs) that closes an ordering cycle:
    #   local-fs.target -> systemd-growfs@var-lib-nagare -> var-lib-nagare.mount
    #   -> format-nagare-data -> basic.target -> sysinit.target -> local-fs.target
    # systemd breaks such a cycle by DELETING a job, and the job it drops is the
    # grow — so the filesystem silently never grows. Observed in the
    # data-disk-online-grow VM test (EP-111 Surprises). Turning default
    # dependencies off and ordering explicitly against local-fs-pre.target is
    # the standard shape for a unit that must run before a local mount.
    #
    # Without basic.target the service runs so early that udev has not yet
    # created the by-id link, the condition is unmet, the format is skipped,
    # and a blank disk fails to mount on first boot (EP-114 Surprises). So it
    # must also wait for the device unit. Wants (not Requires) keeps an absent
    # disk non-fatal: the device job times out and the condition skips.
    unitConfig = {
      ConditionPathExists = dataDiskDevice;
      DefaultDependencies = false;
    };
    wants = [ dataDiskDeviceUnit ];
    after = [ "local-fs-pre.target" dataDiskDeviceUnit ];
    conflicts = [ "shutdown.target" ];
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
    # Absorb a `dataDiskSizeGb` increase with no operator action. NixOS turns
    # autoResize into the `x-systemd.growfs` mount option, so systemd runs
    # systemd-growfs@var-lib-nagare.service right after the mount and grows the
    # ext4 filesystem to fill the device. ext4 grows ONLINE, so this is safe on
    # a running cluster and a no-op when the filesystem already fills the disk.
    # No partition grow is needed: format-nagare-data writes the filesystem
    # directly onto the whole block device, so there is no partition table.
    # The boot disk needs growpart as well, which google-compute-image.nix
    # already provides via boot.growPartition.
    autoResize = true;
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
