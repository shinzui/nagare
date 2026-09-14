{ nagareHostModule, pkgs }:

pkgs.testers.runNixOSTest {
  name = "nagare-host-age-key-delivery";

  nodes.machine = { lib, pkgs, ... }: {
    imports = [ nagareHostModule ];

    nagare.host = {
      evaluationFixture = true;
      hostName = "host-age-key-test";
      instanceName = "host-age-key-test";
      registryHost = "example.invalid";
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly nagare-evaluation-fixture"
      ];
      sopsDefaultFile = "/var/lib/nagare-test/secrets.yaml";
    };

    environment.systemPackages = [ pkgs.age pkgs.sops ];
    sops.validateSopsFiles = false;

    systemd.services.tailscaled-autoconnect.serviceConfig = {
      Type = lib.mkForce "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.mkForce
        "${pkgs.writeShellScript "nagare-test-tailscale-autoconnect" ''
          set -eu
          test -s /run/secrets/tailscale/authkey
          touch /run/nagare-test-autoconnected
        ''}";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_fails("systemctl is-active --quiet tailscaled-autoconnect.service")

    missing_status = machine.succeed("nagare-host-age-key status")
    assert "age-key\tmissing\t" in missing_status, missing_status
    journal = machine.succeed("journalctl -u tailscaled-autoconnect.service --no-pager")
    assert "age key missing" in journal, journal
    assert "https://login.tailscale.com" not in journal, journal
    print("missing phase: age key missing at /var/lib/sops-nix/age-key.txt")

    machine.succeed("install -d -m 0700 /var/lib/nagare-test")
    machine.succeed("age-keygen -o /root/nagare-test.agekey 2>/dev/null")
    machine.succeed(
        "recipient=$(age-keygen -y /root/nagare-test.agekey); "
        "head -c 32 /dev/urandom | base64 -w0 > /root/nagare-test-canary; "
        "printf 'tailscale:\\n  authkey: ' > /root/nagare-test-plain.yaml; "
        "cat /root/nagare-test-canary >> /root/nagare-test-plain.yaml; "
        "printf '\\n' >> /root/nagare-test-plain.yaml; "
        "sops --encrypt --age \"$recipient\" /root/nagare-test-plain.yaml > /var/lib/nagare-test/secrets.yaml; "
        "rm /root/nagare-test-plain.yaml"
    )
    machine.succeed(
        "sha256sum /root/nagare-test.agekey | cut -d' ' -f1 > /root/nagare-test.digest; "
        "nagare-host-age-key install --sha256 \"$(cat /root/nagare-test.digest)\" < /root/nagare-test.agekey"
    )

    machine.succeed("test \"$(stat -c '%U:%G:%a' /var/lib/sops-nix/age-key.txt)\" = root:root:400")
    ready_status = machine.succeed("nagare-host-age-key status")
    assert "age-key\tready\t" in ready_status, ready_status
    print("delivery phase: checksum and root:root 0400 verified")
    machine.succeed("cmp /root/nagare-test-canary /run/secrets/tailscale/authkey")
    machine.succeed("test -e /run/nagare-test-autoconnected")
    machine.wait_for_unit("tailscaled-autoconnect.service")
    print("ready phase: /run/secrets/tailscale/authkey present; autoconnect succeeded")

    machine.succeed("touch -d @1 /var/lib/sops-nix/age-key.txt")
    machine.succeed(
        "nagare-host-age-key install --sha256 \"$(cat /root/nagare-test.digest)\" < /root/nagare-test.agekey"
    )
    machine.succeed("test \"$(stat -c '%Y' /var/lib/sops-nix/age-key.txt)\" = 1")
    machine.succeed("age-keygen -o /root/nagare-different.agekey 2>/dev/null")
    machine.fail(
        "nagare-host-age-key install --sha256 \"$(sha256sum /root/nagare-different.agekey | cut -d' ' -f1)\" < /root/nagare-different.agekey"
    )
    machine.succeed(
        "test \"$(sha256sum /var/lib/sops-nix/age-key.txt | cut -d' ' -f1)\" = \"$(cat /root/nagare-test.digest)\""
    )

    journal = machine.succeed("journalctl -u sops-install-secrets.service -u tailscaled-autoconnect.service --no-pager")
    canary = machine.succeed("cat /root/nagare-test-canary").strip()
    serial = machine.get_console_log()
    assert "AGE-" + "SECRET-KEY-1" not in serial, "private identity leaked to the console"
    assert canary not in journal, "canary secret leaked to the journal"
    assert canary not in serial, "canary secret leaked to the console"
  '';
}
