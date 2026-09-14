{ pkgs, dataFs, sample }:

pkgs.testers.runNixOSTest {
  name = "nagare-data-disk-first-boot-${toString sample}";

  nodes.machine = { ... }: {
    # Exercise the shipped storage and k3s modules rather than copies of their
    # service definitions.
    imports = [
      ../hosts/nagare-01/storage.nix
      ../hosts/nagare-01/k3s.nix
    ];

    # QEMU calls the blank scratch disk /dev/vdb. The udev-owned by-id link is
    # required so systemd also creates the .device unit used by storage.nix.
    services.udev.extraRules = ''
      SUBSYSTEM=="block", KERNEL=="vdb", SYMLINK+="disk/by-id/google-nagare-data"
    '';
    virtualisation.emptyDiskImages = [ 2048 ];

    # qemu-vm.nix replaces fileSystems with virtualisation.fileSystems. Copy
    # the evaluated shipped definition across so this VM tests its real mount
    # options, including nofail and x-systemd.growfs.
    virtualisation.fileSystems."/var/lib/nagare" = {
      inherit (dataFs) device fsType options autoResize;
    };

    environment.systemPackages = [ pkgs.e2fsprogs pkgs.util-linux ];
  };

  testScript = ''
    boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()

    print("SAMPLE ${toString sample} BY-ID " + machine.execute("ls -l /dev/disk/by-id/")[1])
    machine.wait_until_succeeds("test -e /dev/disk/by-id/google-nagare-data", timeout=120)
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("var-lib-nagare.mount")
    machine.wait_for_unit("nagare-data-layout.service")
    machine.wait_for_unit("k3s.service")

    machine.wait_until_succeeds(
        "test \"$(k3s kubectl get nodes --no-headers | wc -l)\" -eq 1 "
        "&& k3s kubectl get nodes --no-headers | awk '$2 == \"Ready\" { ready = 1 } END { exit !ready }'",
        timeout=300,
    )

    machine.succeed("test \"$(findmnt -n -o FSTYPE /var/lib/nagare)\" = ext4")
    machine.succeed(
        "test \"$(readlink -f \"$(findmnt -n -o SOURCE /var/lib/nagare)\")\" "
        "= \"$(readlink -f /dev/disk/by-id/google-nagare-data)\""
    )
    for directory in (
        "victoria-metrics",
        "victoria-logs",
        "victoria-traces",
        "postgres",
        "sqlite",
        "backups",
        "local-path",
    ):
        machine.succeed(f"test -d /var/lib/nagare/{directory}")

    machine.succeed(
        "systemd-analyze verify format-nagare-data.service var-lib-nagare.mount "
        "nagare-data-layout.service k3s.service"
    )
    machine.fail("journalctl -b --no-pager | grep -F 'Device or resource busy'")
    machine.fail(
        "systemctl --failed --no-legend | "
        "grep -E '(format-nagare-data|systemd-fsck@.*nagare|var-lib-nagare|nagare-data-layout|k3s)'"
    )

    # Model the transaction left behind by a transient mount failure. Starting
    # only the recovered mount must pull layout and k3s back in; an operator
    # must not need a reboot or two manual service starts.
    machine.succeed("systemctl stop k3s.service nagare-data-layout.service var-lib-nagare.mount")
    machine.succeed("systemctl reset-failed k3s.service nagare-data-layout.service var-lib-nagare.mount")
    machine.succeed("systemctl start var-lib-nagare.mount")
    machine.wait_for_unit("nagare-data-layout.service")
    machine.wait_for_unit("k3s.service")
    machine.wait_until_succeeds(
        "test \"$(k3s kubectl get nodes --no-headers | wc -l)\" -eq 1 "
        "&& k3s kubectl get nodes --no-headers | awk '$2 == \"Ready\" { ready = 1 } END { exit !ready }'",
        timeout=300,
    )
    machine.succeed(f"test \"$(cat /proc/sys/kernel/random/boot_id)\" = {boot_id}")

    print("SAMPLE ${toString sample} READY\n" + machine.succeed("k3s kubectl get nodes -o wide"))
  '';
}
