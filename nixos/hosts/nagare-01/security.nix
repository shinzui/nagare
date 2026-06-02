{ ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Passwordless sudo for the wheel group enables the unattended
  # `nixos-rebuild switch --target-host nagare-01 --sudo` activation.
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };
}
