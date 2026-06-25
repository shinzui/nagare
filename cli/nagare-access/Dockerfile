# syntax=docker/dockerfile:1.7
# Build from the repository root:
#   docker build --platform linux/amd64 -f cli/nagare-access/Dockerfile -t IMAGE .
#
# This intentionally uses the standalone nagare-access Cabal workspace so the
# deploy CLI does not inherit the shomei/en dependency closure.
FROM haskell:9.12.2 AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    libpq-dev \
    pkg-config \
    zlib1g-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY cli/nagare-dsl/ cli/nagare-dsl/
COPY cli/nagare-access/ cli/nagare-access/

WORKDIR /src/cli/nagare-access
RUN --mount=type=secret,id=github_token,required=false \
  set -eu; \
  if [ -s /run/secrets/github_token ]; then \
    token="$(cat /run/secrets/github_token)"; \
    git config --global "url.https://${token}@github.com/.insteadOf" "https://github.com/"; \
  fi; \
  cabal update; \
  cabal build exe:nagare-access; \
  mkdir -p /out/bin; \
  cp "$(cabal list-bin exe:nagare-access)" /out/bin/nagare-access; \
  if [ -n "${token:-}" ]; then \
    git config --global --unset-all "url.https://${token}@github.com/.insteadOf" || true; \
  fi

FROM debian:stable-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libffi8 \
    libgmp10 \
    libpq5 \
    zlib1g \
  && groupadd --system nagare \
  && useradd --system --gid nagare --home-dir /nonexistent --shell /usr/sbin/nologin nagare \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/bin/nagare-access /usr/local/bin/nagare-access

USER nagare
EXPOSE 8080
ENTRYPOINT ["nagare-access"]
