{ pkgs, atticClient }:

let
  sourceCommit = "12cbeca141f46e1ade76728bce8adc447f2166c6";
  sourceDate = "2025-09-24T06:59:48-04:00";
  manifestDigest = "sha256:18574aba70fc89d2b695273fbe2e7b2f8ad7e8e786b4cc535124fbe14bada1d0";
  linuxAmd64Digest = "sha256:317924e10e70416e69d401880bb71b3aae69b413ecafcfc54018f61929464526";
  pin = {
    inherit sourceCommit sourceDate manifestDigest linuxAmd64Digest;
    source = "https://github.com/zhaofengli/attic";
    image = "ghcr.io/zhaofengli/attic";
  };
in
{
  client = atticClient;
  inherit pin;
  pinFile = pkgs.writeText "attic-pin.json" (builtins.toJSON pin + "\n");
  serverImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/zhaofengli/attic";
    imageDigest = linuxAmd64Digest;
    finalImageName = "ghcr.io/zhaofengli/attic";
    finalImageTag = sourceCommit;
    hash = "sha256-ixVQtSElokYr45VTuMO/Z8hMPwUkVKsalQH2cjg7T6s=";
  };
}
