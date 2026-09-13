{ ... }:

{
  nagare.host = {
    hostName = "prod-host";
    instanceName = "prod-instance";
    registryHost = "us-west1-docker.pkg.dev";
    deployUser = "deploy";
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly operator@example"
    ];
    sopsDefaultFile = ./secrets.yaml;
    ageKeyFile = "/var/lib/sops-nix/age-key.txt";
  };
}
