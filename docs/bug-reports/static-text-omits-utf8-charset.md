---
type: Bug Report
title: Static-site text responses omit their UTF-8 charset
description: Generated Nginx serves UTF-8 Markdown as text/plain without a charset, allowing browsers to render non-ASCII punctuation incorrectly.
generated:
  by: process:openai-codex
  at: "2026-10-13T13:08:02Z"
bugId: BUG-6
status: confirmed
severity: cosmetic
origin: mori://shinzui/keiro-runtime-docs/plans/49-deploy-the-docs-to-the-labs-intranet-with-local-bun-builds
affects: mori://shinzui/nagare/packages/nagarectl
affectedVersion: 0.6.2
environment: Browser viewing UTF-8 text exports served by generated Nginx
observed: >-
  The released generated configuration returns HTTP 200 Content-Type text/plain
  for UTF-8 example.txt without a charset. The consumer's equivalent custom
  configuration displayed em dashes as mojibake in Chrome.
expected: >-
  Nagare's static runtime serves built UTF-8 text with an explicit compatible
  charset so the browser displays the original document characters correctly.
reproduction:
  - Run Docker with the pinned Nginx image named in the audit script available locally.
  - From the Nagare checkout run python3 docs/audits/static-runtime-defaults-2026-10-13/reproduce.py.
  - Inspect the markdown response for UTF-8 example.txt served by the released golden configuration.
  - Observe that Content-Type is text/plain with no charset despite the non-ASCII UTF-8 body.
workaround: Declare charset utf-8 in the custom Nginx server configuration.
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

# Static-site text responses omit their UTF-8 charset

The static runtime packages and serves the application's built files. Its
renderer in `cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs` emits no charset
declaration, in v0.6.2 and the current source inspected at
`f684df2efdba78ce673ac9cee2d8a8bc38852b34`. Nginx therefore serves text without
telling the browser that its non-ASCII bytes are UTF-8.

The browser symptom was observed while deploying the docs in
`mori://shinzui/keiro-runtime-docs`, using a custom protected Deployment with
the same omission. The Markdown body was served, but punctuation such as em
dashes displayed as mojibake. Adding `charset utf-8` corrected the HTTP
header, and the consumer's final container smoke test requires it. A later
Chrome raw-text reload was blocked by the client, so final browser decoding was
not independently confirmed.

The owning-repository [reproduction](../audits/static-runtime-defaults-2026-10-13/reproduce.py)
runs the exact v0.6.2 golden config with a pinned Nginx image. Its
[results](../audits/static-runtime-defaults-2026-10-13/results.json) confirm
HTTP 200, a correct UTF-8 body containing an em dash and an accented word, and
`Content-Type: text/plain` without charset. No full cloud StaticSite deployment
or second browser session was performed during this audit.

Declare UTF-8 for supported text output, or provide an explicit encoding option
with a documented UTF-8 default. Preserve binary assets without transcoding.
Acceptance should assert the generated runtime's text response header and
browser-visible Unicode characters, while checking that binary asset bytes
remain unchanged. [Nginx's charset reference](https://nginx.org/en/docs/http/ngx_http_charset_module.html)
describes the response-header directive; adding it alone need not convert bytes.
