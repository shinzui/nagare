# EP-237: the four linux/amd64 service images a Nagare release publishes
# (IR-39): En, Shōmei, nagare-access and the admin API. They are built only
# for x86_64-linux and are never inputs of the platform payload; the payload
# carries their committed distribution digests in release.json's
# `releaseImages` member instead (Decision Log, 2026-10-31 review).
#
# The three auth images share one GHC 9.12.4 package set whose versions are
# the cabal solve of cli/nagare-access/cabal.project (ADR 1): the reviewed
# source pins below, and in release-images/hackage-pins.json every Hackage
# package whose pinned-nixpkgs version differs from that solve. The admin API
# image is the nagare-api-server the platform package set already builds.
#
# Each image is converted to an OCI image layout whose layers are compressed
# here, deterministically, so `skopeo copy --preserve-digests` uploads the
# exact manifest whose digest this derivation reports. That digest is the
# image's identity; the archive and Nix output hashes are not.
{ pkgs, platformHaskellPackages, releaseVersion }:

let
  inherit (pkgs) lib;
  hl = pkgs.haskell.lib.compose;

  # Reviewed upstream pins. They must equal cli/nagare-access/cabal.project's
  # source-repository-package tags (checked below at evaluation).
  # mori://shinzui/shomei mori://shinzui/en
  sourcePins = {
    shomei = {
      location = "https://github.com/shinzui/shomei.git";
      owner = "shinzui";
      repo = "shomei";
      rev = "6179d5678747aeb8ee3c45423c2bf59385dbda88";
      hash = "sha256-J6Zelww6jerTB8Hws7udwiOFE1YkqxanbPNNER9H6gA=";
    };
    en = {
      location = "https://github.com/shinzui/en.git";
      owner = "shinzui";
      repo = "en";
      rev = "c3ee100a0b2cc63a50a9473ef590de7086dca4d0";
      hash = "sha256-IXqCunqpGjzWKp9jWGuRLE56yso46Lhne57BuHd1p5U=";
    };
    webauthn = {
      location = "https://github.com/shinzui/webauthn.git";
      owner = "shinzui";
      repo = "webauthn";
      rev = "c274e23a5e31aac8932bac6398b65e8bca584a99";
      hash = "sha256-ODP0Jnug7NAWQrJ3x11Qz5d4tQpSqUK48EPX+2VitHA=";
    };
    biscuit-haskell = {
      location = "https://github.com/shinzui/biscuit-haskell.git";
      owner = "shinzui";
      repo = "biscuit-haskell";
      rev = "8c0b3c5a13ce4a310737c0336f2ae167a1597588";
      hash = "sha256-BtqFq5O48892O2y4M+FyC4npA0mxRo9Zv2jJrWjfCIY=";
    };
    hs-opentelemetry-instrumentation-servant = {
      location = "https://github.com/shinzui/hs-opentelemetry-instrumentation-servant.git";
      owner = "shinzui";
      repo = "hs-opentelemetry-instrumentation-servant";
      rev = "7a6f692e85295f965cd1827f9354c28af9e62742";
      hash = "sha256-oi3E1KjZLdI7Ezahz/3khwS5uxoLNwrPCzRIO1m7/80=";
    };
  };

  accessProject = builtins.readFile ../cli/nagare-access/cabal.project;
  unpinned = lib.filter
    (name:
      let pin = sourcePins.${name}; in
      !(lib.hasInfix "location: ${pin.location}\n  tag: ${pin.rev}\n" accessProject))
    (builtins.attrNames sourcePins);
  sources = lib.mapAttrs
    (_name: pin: pkgs.fetchFromGitHub { inherit (pin) owner repo rev hash; })
    (if unpinned == [ ] then sourcePins
    else throw "release images: source pins differ from cli/nagare-access/cabal.project: ${toString unpinned}");

  hackagePins = builtins.fromJSON (builtins.readFile ./release-images/hackage-pins.json);
  # Test and benchmark dependencies the set lacks; the tests do not run.
  absentArguments = builtins.fromJSON (builtins.readFile ./release-images/absent-arguments.json);
  argumentsFor = name: lib.genAttrs (absentArguments.${name} or [ ]) (_: null);

  # Released Hackage tarballs carry their original .cabal file; the cabal solve
  # used Hackage's revised bounds, so the jailbreak only restores those.
  hackagePackage = hfinal: name: pin:
    hl.dontHaddock (hl.dontCheck (hl.doJailbreak (hfinal.callCabal2nix name
      (builtins.fetchTarball {
        url = "https://hackage.haskell.org/package/${name}-${pin.version}/${name}-${pin.version}.tar.gz";
        inherit (pin) sha256;
      })
      (argumentsFor name))));

  sourcePackage = hfinal: name: src:
    hl.dontHaddock (hl.dontCheck (hfinal.callCabal2nix name src (argumentsFor name)));

  shomeiPackages = [ "shomei-core" "shomei-jwt" "shomei-webauthn" "shomei-postgres" "shomei-migrations" "shomei-servant" "shomei-server" "shomei-client" ];
  enPackages = [ "en-core" "en-biscuit" "en-migrations" "en-postgres" "en-servant" "en-server" "en-client" ];

  # The cabal solve read Hackage's latest revisions, whose bounds admit the
  # pinned versions; the set's packages carry older revisions or none, so
  # every Haskell package here builds without its declared bounds. Their own
  # suites and documentation are not part of an image.
  jailbreakAll = _hfinal: hprev: lib.mapAttrs
    (_name: value:
      let haskell = builtins.tryEval (lib.isDerivation value && value ? isHaskellLibrary); in
      if haskell.success && haskell.value
      then hl.dontHaddock (hl.dontCheck (hl.doJailbreak value))
      else value)
    hprev;

  authHaskellPackages = pkgs.haskell.packages.ghc9124.override {
    overrides = lib.composeExtensions jailbreakAll (hfinal: _hprev:
      lib.mapAttrs (hackagePackage hfinal) hackagePins
      // lib.genAttrs shomeiPackages (name: sourcePackage hfinal name "${sources.shomei}/${name}")
      // lib.genAttrs enPackages (name: sourcePackage hfinal name "${sources.en}/${name}")
      // {
        # cabal.project: allow-newer en-migrations:pg-migrate{,-cli,-embed}.
        en-migrations = hl.doJailbreak (sourcePackage hfinal "en-migrations" "${sources.en}/en-migrations");
        webauthn = hl.doJailbreak (sourcePackage hfinal "webauthn" sources.webauthn);
        biscuit-haskell = hl.doJailbreak (sourcePackage hfinal "biscuit-haskell" "${sources.biscuit-haskell}/biscuit");
        hs-opentelemetry-instrumentation-servant =
          hl.doJailbreak (sourcePackage hfinal "hs-opentelemetry-instrumentation-servant" sources.hs-opentelemetry-instrumentation-servant);
        nagare-contract = sourcePackage hfinal "nagare-contract" ../cli/nagare-contract;
        nagare-dsl = sourcePackage hfinal "nagare-dsl" ../cli/nagare-dsl;
        nagare-access = sourcePackage hfinal "nagare-access" ../cli/nagare-access;
      });
  };

  # The cabal.project `constraints:` the images must honour.
  constrained = {
    pg-migrate = "1.2.0.0";
    pg-migrate-cli = "1.2.0.0";
    pg-migrate-embed = "1.2.0.0";
    ephemeral-pg = "0.3.1.0";
  };
  violated = lib.filterAttrs (name: version: authHaskellPackages.${name}.version != version) constrained;
  checkedAuthPackages =
    if violated == { } then authHaskellPackages
    else throw "release images: cabal.project constraints violated: ${toString (builtins.attrNames violated)}";

  executables = package: hl.justStaticExecutables package;

  passwd = pkgs.runCommand "nagare-image-passwd" { } ''
    mkdir -p "$out/etc"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'nagare:x:10001:10001:nagare:/nonexistent:/sbin/nologin' > "$out/etc/passwd"
    printf '%s\n' 'root:x:0:' 'nagare:x:10001:' > "$out/etc/group"
  '';

  # /usr/local/bin holds the commands the workloads name: the server, the
  # migration executable Jobs override the command with, and auth-entrypoint.
  binRoot = name: { binaries, entrypoint, script }:
    pkgs.runCommand "nagare-${name}-image-bin" { } ''
      mkdir -p "$out/usr/local/bin"
      ${lib.concatMapStrings (binary: ''
        ln -s ${binary} "$out/usr/local/bin/${baseNameOf binary}"
      '') binaries}
      ${if script then ''
        # The image has busybox's sh at /bin and no /usr/bin/env.
        sed '1s|^#!/usr/bin/env sh$|#!/bin/sh|' ${entrypoint} > "$out/usr/local/bin/auth-entrypoint"
        chmod 0555 "$out/usr/local/bin/auth-entrypoint"
        test "$(head -n 1 "$out/usr/local/bin/auth-entrypoint")" = '#!/bin/sh'
      '' else ''
        ln -s ${entrypoint} "$out/usr/local/bin/auth-entrypoint"
      ''}
    '';

  mkImage = name: { binaries, entrypoint, script ? false, contents ? [ ], labels }:
    pkgs.dockerTools.buildLayeredImage {
      name = "nagare-${name}";
      tag = releaseVersion;
      architecture = "amd64";
      contents = [ (binRoot name { inherit binaries entrypoint script; }) passwd pkgs.cacert ] ++ contents;
      extraCommands = ''
        mkdir -m 1777 tmp
      '';
      config = {
        Entrypoint = [ "/usr/local/bin/auth-entrypoint" ];
        User = "10001:10001";
        ExposedPorts = { "8080/tcp" = { }; };
        Env = [
          "LANG=C.UTF-8"
          "PATH=/usr/local/bin:/bin:/usr/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        Labels = {
          "io.nagare.release-version" = releaseVersion;
          "org.opencontainers.image.title" = "nagare-${name}";
        } // labels;
      };
    };

  # Convert a docker-archive to an OCI layout with gzip -n layers and write the
  # manifest digest to `digest`. Nothing here reads the clock or the host.
  ociLayout = key: image:
    let repository = repositories.${key}; name = key; in
    pkgs.runCommand "nagare-${name}-oci"
      {
        nativeBuildInputs = [ pkgs.jq pkgs.gzip pkgs.gnutar pkgs.coreutils ];
        passthru = { inherit image; };
      } ''
      work="$TMPDIR/archive"
      mkdir -p "$work" "$out/blobs/sha256"
      tar -xzf ${image} -C "$work"
      blob() {
        local digest
        digest="$(sha256sum "$1" | cut -d' ' -f1)"
        mv "$1" "$out/blobs/sha256/$digest"
        # A trailing newline: `read` fails at an unterminated line under set -e.
        printf '%s %s\n' "$digest" "$(stat -c %s "$out/blobs/sha256/$digest")"
      }
      config_file="$(jq -r '.[0].Config' "$work/manifest.json")"
      cp "$work/$config_file" "$TMPDIR/config"
      read -r config_digest config_size < <(blob "$TMPDIR/config")
      layers='[]'
      while read -r layer; do
        gzip -n -9 -c "$work/$layer" > "$TMPDIR/layer"
        read -r layer_digest layer_size < <(blob "$TMPDIR/layer")
        layers="$(jq -c --arg d "sha256:$layer_digest" --argjson s "$layer_size" \
          '. + [{mediaType: "application/vnd.oci.image.layer.v1.tar+gzip", digest: $d, size: $s}]' <<<"$layers")"
      done < <(jq -r '.[0].Layers[]' "$work/manifest.json")
      jq -cnj --arg d "sha256:$config_digest" --argjson s "$config_size" --argjson layers "$layers" \
        '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
          config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $d, size: $s},
          layers: $layers}' > "$TMPDIR/manifest"
      read -r manifest_digest manifest_size < <(blob "$TMPDIR/manifest")
      jq -cnj --arg d "sha256:$manifest_digest" --argjson s "$manifest_size" \
        '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json",
          manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d, size: $s,
                       platform: {architecture: "amd64", os: "linux"},
                       annotations: {"io.containerd.image.name": $ref, "org.opencontainers.image.ref.name": $tag}}]}' \
        --arg ref "${repository}:${releaseVersion}" --arg tag "${releaseVersion}" > "$out/index.json"
      printf '{"imageLayoutVersion":"1.0.0"}' > "$out/oci-layout"
      printf 'sha256:%s' "$manifest_digest" > "$out/digest"
    '';

  shomeiServer = executables checkedAuthPackages.shomei-server;
  shomeiMigrations = executables checkedAuthPackages.shomei-migrations;
  enServer = executables checkedAuthPackages.en-server;
  enMigrations = executables checkedAuthPackages.en-migrations;
  accessServer = executables checkedAuthPackages.nagare-access;
  # The admin API's suite runs in the platform package set's own build.
  adminApiServer = executables (hl.dontCheck platformHaskellPackages.nagare-api-server);

  upstreamLabels = names: lib.listToAttrs (map
    (name: lib.nameValuePair "io.nagare.source.${name}" "${sourcePins.${name}.location}@${sourcePins.${name}.rev}")
    names);

  images = {
    en = mkImage "en" {
      binaries = [ "${enServer}/bin/en-server" "${enMigrations}/bin/en-migrate" ];
      entrypoint = "${enServer}/bin/en-server";
      labels = upstreamLabels [ "en" ];
    };
    shomei = mkImage "shomei" {
      binaries = [
        "${shomeiServer}/bin/shomei-server"
        "${shomeiServer}/bin/shomei-admin"
        "${shomeiMigrations}/bin/shomei-migrate"
      ];
      # Shōmei's pinned entrypoint: migrations, signing-key initialisation,
      # container-aware RTS options. It needs sh, grep, sed and nproc, and the
      # server renders Dhall configuration with dhall-to-json.
      entrypoint = "${sources.shomei}/deploy/entrypoint.sh";
      script = true;
      contents = [ pkgs.busybox pkgs.dhall-json ];
      labels = upstreamLabels [ "shomei" ];
    };
    nagare-access = mkImage "access" {
      binaries = [ "${accessServer}/bin/nagare-access" ];
      entrypoint = "${accessServer}/bin/nagare-access";
      labels = upstreamLabels [ "shomei" "en" ];
    };
    nagare-admin-api = mkImage "admin-api" {
      binaries = [ "${adminApiServer}/bin/nagare-api-server" ];
      entrypoint = "${adminApiServer}/bin/nagare-api-server";
      labels = { };
    };
  };

  layouts = lib.mapAttrs ociLayout images;

  # The `releaseImages` member of root release.json, from the layouts.
  repositories = {
    en = "ghcr.io/shinzui/nagare-en";
    shomei = "ghcr.io/shinzui/nagare-shomei";
    nagare-access = "ghcr.io/shinzui/nagare-access";
    nagare-admin-api = "ghcr.io/shinzui/nagare-admin-api";
  };
  sourceRevisions = {
    en = { en = sourcePins.en.rev; };
    shomei = { shomei = sourcePins.shomei.rev; };
    nagare-access = { shomei = sourcePins.shomei.rev; en = sourcePins.en.rev; };
    nagare-admin-api = { };
  };
  manifest = pkgs.runCommand "nagare-release-images-manifest"
    { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p "$TMPDIR/entries"
    ${lib.concatStrings (lib.mapAttrsToList (key: layout: ''
      jq -n --arg key ${key} --arg repository ${repositories.${key}} \
        --arg digest "$(cat ${layout}/digest)" \
        --argjson sources ${lib.escapeShellArg (builtins.toJSON sourceRevisions.${key})} \
        '{($key): {repository: $repository, platform: "linux/amd64", digest: $digest,
                   reference: ($repository + "@" + $digest), sources: $sources}}' \
        > "$TMPDIR/entries/${key}.json"
    '') layouts)}
    jq -S -s '{schemaVersion: 1, images: add}' "$TMPDIR"/entries/*.json > "$out"
  '';

  # Fails unless the committed release.json carries exactly this manifest.
  check = pkgs.runCommand "nagare-release-images-check"
    { nativeBuildInputs = [ pkgs.jq ]; } ''
    expected="$(jq -S . ${manifest})"
    committed="$(jq -S '.releaseImages // null' ${../release.json})"
    if [ "$expected" != "$committed" ]; then
      echo "release.json releaseImages differs from the built images:" >&2
      diff <(printf '%s\n' "$committed") <(printf '%s\n' "$expected") >&2 || true
      exit 1
    fi
    cp ${manifest} "$out"
  '';
in
{
  inherit authHaskellPackages check images layouts manifest sourcePins;
}
