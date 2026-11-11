{ rev }:
let
  flake = builtins.getFlake "git+file:///work/nagare?rev=${rev}";
  pkgs = flake.inputs.nixpkgs.legacyPackages.aarch64-linux;
  nagarectl = flake.packages.aarch64-linux.nagarectl;
in
pkgs.dockerTools.buildLayeredImage {
  name = "nagarectl-linux";
  tag = builtins.substring 0 8 rev;
  contents = [ nagarectl pkgs.kubectl pkgs.bashInteractive pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gnutar pkgs.gzip pkgs.cacert ];
  maxLayers = 60;
  config = {
    User = "65532:65532";
    Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" "PATH=/bin" "HOME=/work/home" "TMPDIR=/work/tmp" ];
    WorkingDir = "/work";
    Entrypoint = [ "/bin/bash" ];
  };
}
