{ ... }:

{
  nagare.host = {
    hostName = "prod-host";
    instanceName = "prod-instance";
    registryHost = "us-west1-docker.pkg.dev";
    registryCredentialOwner = "platform:host/nixos-system/system";
    registryServingControllerOwner = "platform:serving/serving/object-cb13aaa7348f14c3bc1ee1cf94987eb1803ad266";
    deployUser = "deploy";
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example"
    ];
    sopsDefaultFile = ./secrets.yaml;
    ageKeyFile = "/var/lib/sops-nix/age-key.txt";
  };
}
