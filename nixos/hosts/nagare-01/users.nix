{ config, ... }:

let
  cfg = config.nagare.host;
in {
  users.mutableUsers = false;

  users.users.${cfg.deployUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = cfg.authorizedKeys;
  };
}
