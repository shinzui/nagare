{ ... }:

let
  # The device name EP-2 assigns to the attached data disk. GCP surfaces it at
  # /dev/disk/by-id/google-<deviceName>. EP-2's NagareInstance.ts attaches the
  # disk with deviceName "nagare-data", confirmed against that component.
  dataDiskDevice = "/dev/disk/by-id/google-nagare-data";
in
{
  fileSystems."/var/lib/nagare" = {
    device = dataDiskDevice;
    fsType = "ext4";
    # nofail so a first boot before the disk is formatted does not hang the
    # boot; EP-2 attaches a pre-formatted disk, or the first boot formats it.
    options = [ "defaults" "nofail" ];
    # autoFormat is provided by some setups via a oneshot; if EP-2 does not
    # pre-format the disk, format once manually (see Idempotence and Recovery).
  };

  # Create the IP-3 subdirectory layout under the mount. These run on every
  # boot and are idempotent (tmpfiles only creates what is missing).
  systemd.tmpfiles.rules = [
    "d /var/lib/nagare 0755 root root -"
    "d /var/lib/nagare/victoria-metrics 0755 root root -"
    "d /var/lib/nagare/victoria-logs 0755 root root -"
    "d /var/lib/nagare/victoria-traces 0755 root root -"
    "d /var/lib/nagare/postgres 0755 root root -"
    "d /var/lib/nagare/sqlite 0755 root root -"
    "d /var/lib/nagare/backups 0755 root root -"
    "d /var/lib/nagare/local-path 0755 root root -"
  ];
}
