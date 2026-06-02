{ ... }:

{
  users.mutableUsers = false;

  users.users.deploy = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Operator workstation key (~/.ssh/id_ed25519.pub on sungkyung).
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFr90yzWnHzUraT2owYt2MR9snqFNhVcP33l4agGJZ7R shinzui@sungkyung"
    ];
  };
}
