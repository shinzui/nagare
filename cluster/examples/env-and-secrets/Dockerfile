FROM node:22-slim

# BUILD_STAMP is a Build-scoped variable (EP-23/EP-27): Nagare passes it to
# `docker build` as --build-arg BUILD_STAMP=<value>. Read it here; it is baked
# into the image at build time and is NOT present in the running container's
# inline env. SECURITY: --build-arg values are visible via `docker history`;
# do not use them for secrets (see docs/user/env-and-secrets.md).
ARG BUILD_STAMP=unset
ENV BUILD_STAMP=${BUILD_STAMP}

WORKDIR /app
COPY app.js ./
EXPOSE 8080
CMD ["node", "app.js"]
