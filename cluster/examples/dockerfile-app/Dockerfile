# A tiny Dockerfile-built app that serves a single page on port 8080.
# The SITE_MESSAGE build argument (passed via the config's buildArgs) is baked
# into the page at build time, demonstrating --build-arg.
FROM python:3.12-alpine

ARG SITE_MESSAGE="default message (no build arg passed)"

WORKDIR /site
RUN printf '%s\n' "$SITE_MESSAGE" > index.html

EXPOSE 8080
CMD ["python", "-m", "http.server", "8080"]
