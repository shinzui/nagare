{ lib, ... }:

{
  # Break-glass (ExecPlan 115, ADR 11): expose GRUB on the GCE serial console with a real timeout
  # so an operator can boot an earlier generation when SSH access is lost. Costs ten seconds per
  # boot. Reach it with `gcloud compute connect-to-serial-port` (runbook: docs/user/accessing-the-host.md).
  # google-compute-config.nix sets the timeout and configuration limit to 0, hence mkForce.
  boot.loader.timeout = lib.mkForce 10;
  boot.loader.grub.extraConfig = ''
    serial --unit=0 --speed=38400
    terminal_input serial console
    terminal_output serial console
  '';
  # Keep older generations in the menu (the evaluated value was 0 on 2026-09-12).
  boot.loader.grub.configurationLimit = lib.mkForce 20;
}
