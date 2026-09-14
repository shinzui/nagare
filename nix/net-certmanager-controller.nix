{ pkgs }:

let
  # net-certmanager v1.14.0 (source tag v0.41.0) is the project's final and
  # latest release. The upstream repository is archived, so Nagare carries the
  # narrowly scoped fix needed by EP-138 and builds it from the exact release
  # commit instead of relying on a mutable registry image.
  version = "1.14.0";
  revision = "dcff3644e7037215a084af52905fb0e9e78bab52";
  imageReference = pkgs.lib.trim (builtins.readFile ../cluster/bootstrap/net-certmanager/image-reference);
  imageParts = pkgs.lib.splitString ":" imageReference;
  imageName = builtins.elemAt imageParts 0;
  imageTag = builtins.elemAt imageParts 1;

  linuxPkgs =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux"
    then pkgs
    else pkgs.pkgsCross.gnu64;

  controller = linuxPkgs.buildGoModule {
    pname = "net-certmanager-controller";
    inherit version;

    src = linuxPkgs.fetchFromGitHub {
      owner = "knative-extensions";
      repo = "net-certmanager";
      rev = revision;
      hash = "sha256-C8BuL5eB/qiv79jUjPr920meBUJZqYq79dzW1Q1ZoRo=";
    };

    patches = [ ../cluster/bootstrap/net-certmanager/patches/0001-use-distinct-default-issuer-references.patch ];
    vendorHash = null;
    subPackages = [ "cmd/controller" ];
    tags = [ "netgo" "osusergo" ];
    ldflags = [ "-s" "-w" ];

    # Cross-compiled test executables cannot run on a Darwin evaluator. The
    # native x86_64-linux release job runs the focused upstream regression test.
    doCheck = linuxPkgs.stdenv.buildPlatform.canExecute linuxPkgs.stdenv.hostPlatform;
    checkPhase = ''
      runHook preCheck
      go test ./pkg/reconciler/certificate/config
      runHook postCheck
    '';

    meta = {
      description = "Nagare-patched Knative net-certmanager controller";
      homepage = "https://github.com/knative-extensions/net-certmanager";
      license = linuxPkgs.lib.licenses.asl20;
      mainProgram = "controller";
      platforms = [ "x86_64-linux" ];
    };
  };

  imageRoot = pkgs.buildEnv {
    name = "net-certmanager-controller-image-root";
    paths = [ controller ];
    pathsToLink = [ "/bin" ];
  };

  image = pkgs.dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    architecture = "amd64";
    copyToRoot = imageRoot;
    config = {
      Entrypoint = [ "/bin/controller" ];
      User = "65532:65532";
    };
  };
in
{
  inherit controller image imageReference revision version;
}
