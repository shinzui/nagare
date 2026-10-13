---
type: Bug Report
title: Static-site directory redirects expose the internal HTTP port
description: Generated Nginx directory redirects send HTTPS readers to HTTP port 8080 instead of preserving the public URL.
generated:
  by: process:openai-codex
  at: "2026-10-13T13:08:02Z"
bugId: BUG-5
status: confirmed
severity: degraded
origin: mori://shinzui/keiro-runtime-docs/plans/49-deploy-the-docs-to-the-labs-intranet-with-local-bun-builds
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: 0.6.2
environment: Nginx on internal port 8080 behind Nagare HTTPS ingress
observed: >-
  GET /guide with Host docs.example.test and X-Forwarded-Proto https returns
  301 Location http://docs.example.test:8080/guide/.
expected: >-
  Directory navigation on a published HTTPS static site preserves the public
  scheme, hostname, and port, as required by the static-hosting guide's HTTPS URL provision.
reproduction:
  - Run Docker with the pinned Nginx image named in the audit script available locally.
  - From the Nagare checkout run python3 docs/audits/static-runtime-defaults-2026-10-13/reproduce.py.
  - Inspect the directory response generated from the released static-site Nginx golden fixture.
  - Observe the HTTP scheme and internal port 8080 in Location.
workaround: Use relative automatic redirects with absolute_redirect off in a custom Nginx runtime.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-10-13T13:08:02Z"
    document_timestamp: "2026-10-13T13:08:02Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Author review of classification, source evidence, reproduction or acceptance,
      and safety boundaries; no independent verification attestation is claimed.
---

# Static-site directory redirects expose the internal HTTP port

The published [static-hosting guide](../user/static-hosting.md) promises an HTTPS
site with working redirects. In v0.6.2,
`cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs` renders `listen 8080` and
`try_files $uri $uri/ $uri.html ...`, without configuring automatic directory
redirects for a TLS-terminating ingress. Nginx uses its internal HTTP listener
when it appends a missing directory slash. The omission is also present in the
current source inspected at `f684df2efdba78ce673ac9cee2d8a8bc38852b34`.

The original consumer symptom occurred in a custom protected Deployment in
`mori://shinzui/keiro-runtime-docs`, rather than a dedicated StaticSite.
This report is independently grounded in the owning repository's released
golden configuration: [the reproduction](../audits/static-runtime-defaults-2026-10-13/reproduce.py)
runs its exact bytes with a pinned Nginx image and records
[HTTP evidence](../audits/static-runtime-defaults-2026-10-13/results.json).
This is a runtime-config reproduction, not a claim that a new cloud StaticSite
was deployed during this audit.

```text
GET /guide
Host: docs.example.test
X-Forwarded-Proto: https
301 Location: http://docs.example.test:8080/guide/
```

Configure generated directory redirects to preserve the public URL, preferably
with a relative Location. Keep explicitly configured external redirect
destinations working. Acceptance should run the generated config against a real
Nginx container, request a directory without its slash through the public-host
headers, and follow the response through an ingress-shaped proxy. It must reach
the page without a scheme downgrade, internal port, redirect loop, or origin bypass.
