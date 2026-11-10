{ pkgs, nagarePackages }:

{
  # EP-253: an isolated ARM64 Linux consumer of the packaged CLI and SDK. The
  # script refuses to pass with network access, so run it in a Nix sandbox or a
  # container with no route out.
  nagare-config-sdk-consumer = pkgs.runCommand "nagare-config-sdk-consumer"
    {
      nativeBuildInputs = [ pkgs.jq ];
      fixture = ../../cli/nagarectl/test/fixtures/sdk-consumer;
      sdk = nagarePackages.typedConfigRuntime;
      cli = nagarePackages.nagarectl;
    }
    ''
      bash ${./scripts/nagare-config-sdk-consumer.sh}
    '';
}
