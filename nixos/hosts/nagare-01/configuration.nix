{ ... }:

{
  # Source-checkout compatibility fixture. Real operators generate this module
  # under their XDG configuration root with `nagarectl host init`.
  nagare.host = {
    hostName = "nagare-01";
    instanceName = "nagare-01";
    registryHost = "us-west1-docker.pkg.dev";
    deployUser = "deploy";
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyForNagareEvaluationOnly nagare-evaluation-fixture"
    ];
    sopsDefaultFile = ./secrets/nagare-01.yaml;
    ageKeyFile = "/var/lib/sops-nix/age-key.txt";
  };
}
