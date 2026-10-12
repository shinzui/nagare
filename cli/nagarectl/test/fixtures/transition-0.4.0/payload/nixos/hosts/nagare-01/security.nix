{ lib, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # Disable OpenSSH 9.8+/10.x per-source penalties. On this host they
      # were observed dropping connections at the start of userauth (after
      # KEX), making the box effectively unreachable over SSH after a couple
      # of connections — including over the IAP tunnel, whose connections all
      # share a source. We control access via the IAP firewall + key auth, so
      # the penalty heuristic only gets in the way here. See EP-3 Surprises.
      PerSourcePenalties = "no";
    };
  };

  # Disable Google OS Login. The GCE image module enables it by default, which
  # makes sshd authenticate via an AuthorizedKeysCommand (the OS Login helper)
  # instead of the deploy user's declarative authorized_keys. That helper is a
  # second possible cause of the userauth-time connection close observed in
  # EP-3. We authenticate as the `deploy` user with the operator's key
  # (users.nix), so OS Login is unnecessary; turning it off makes sshd use the
  # plain authorized_keys path. mkForce overrides the GCE module's default.
  security.googleOsLogin.enable = lib.mkForce false;

  # Passwordless sudo for the wheel group enables the unattended
  # `nixos-rebuild switch --target-host nagare-01 --sudo` activation.
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };
}
