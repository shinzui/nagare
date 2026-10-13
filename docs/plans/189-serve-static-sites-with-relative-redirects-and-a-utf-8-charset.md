---
id: 189
slug: serve-static-sites-with-relative-redirects-and-a-utf-8-charset
title: "Serve static sites with relative redirects and a UTF-8 charset"
kind: exec-plan
created_at: 2026-10-13T13:18:14Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:18:14Z
---

# Serve static sites with relative redirects and a UTF-8 charset

This ExecPlan fixes [BUG-5](../bug-reports/static-directory-redirect-exposes-internal-port.md) and
[BUG-6](../bug-reports/static-text-omits-utf8-charset.md) for the next release. Both are in the
Nginx configuration that `nagarectl` generates for every StaticSite.


## Purpose / Big Picture

A developer publishes a static site on the intranet over HTTPS. Today, following a link to a
directory without its trailing slash (`https://docs.example/guide`) redirects the browser to
`http://docs.example:8080/guide/`. That is the container's internal port, which the reader cannot
reach. Configured redirects (`mkRedirectRule "/old" "/new" 301`) leak the same way. Text files are
also served as `text/plain` with no charset, so a browser can show UTF-8 punctuation such as an em
dash as mojibake.

After this change, every redirect the generated server issues is relative (`Location: /guide/`),
so the browser keeps the public scheme, host and port. Text responses carry `charset=utf-8`.
Binary assets are served byte for byte as before. Existing sites pick up the fix the next time they
run `nagarectl site deploy`, because the Nginx configuration is baked into each site image when it
is built.


## Progress

- [ ] M1: The renderer emits `absolute_redirect off;`, `charset utf-8;` and an explicit
  `charset_types` list. The golden `cli/nagare-dsl/test/golden/static-site.nginx.conf` is updated.
  Pass: `nagare-dsl-test -p '/renderNginxConfig/'` is green and the golden diff is exactly the new
  directives.
- [ ] M2: The flake check `static-nginx-runtime` runs the golden configuration in a real Nginx and
  asserts the HTTP results listed under Validation. Pass: the check fails on the current golden
  configuration and passes after M1.
- [ ] M3: A CHANGELOG `[Unreleased]` entry and a sentence in `docs/user/static-hosting.md` say that
  redirects are relative and text is UTF-8. BUG-5 and BUG-6 are marked `fixed` with
  `fixedVersion: unreleased` and a `resolution` naming the fixing commit. Pass: `just gate-fast` is
  green, then `just land`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Use `absolute_redirect off` rather than `port_in_redirect off` plus a
  forwarded-scheme map. A relative `Location` is resolved by the client against the URL it requested
  (RFC 9110 §10.2.2), so it keeps the public scheme, host and port whatever proxies sit in front.
  It also fixes configured redirects such as `return 301 /new;`, which Nginx otherwise expands with
  the internal port too. Redirect targets written as full URLs (`https://…`) are unaffected.
  Because of that resolution rule, acceptance needs no ingress-shaped proxy: asserting the exact
  relative `Location` value, then requesting it, proves the browser lands on the page.
- Decision (2026-10-13): Declare UTF-8 unconditionally with no encoding option. Static sites are
  built output, and every supported generator writes UTF-8. `charset` only adds the header; with no
  `source_charset` set, Nginx does not transcode bytes.
- Decision (2026-10-13): Do not add a MIME mapping for `.md` in this plan. The bug was observed on
  `text/plain` content. Whether Markdown exports need their own type is a separate request.
- Decision (2026-10-13): BUG-1 to BUG-4 were revalidated against master `1532a447` and need no
  plan. ExecPlans 140 to 143 fixed them, and the fixes shipped in v0.4.0. Their reports are now
  marked `fixed`.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

A StaticSite is a typed site definition (`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs`). On
`nagarectl site deploy`, `cli/nagarectl/src/Nagare/Static/Image.hs` builds an image from
`nginx:1.27-alpine`. It copies the generated server block to `/etc/nginx/conf.d/default.conf` and
the built files to `/usr/share/nginx/html`. Knative routes HTTPS traffic, after TLS termination at
the ingress, to that container on port 8080. The image's stock `/etc/nginx/nginx.conf` wraps the
server block in an `http {}` block that includes `mime.types` and sets
`default_type application/octet-stream`.

The server block comes from `renderNginxConfig` in
`cli/nagare-dsl/src/Nagare/Dsl/Static/Render.hs`. Its header lines are `listen 8080;`,
`server_name _;`, `root …;` and `index index.html;`. Redirect, header, cache, catch-all and 404
blocks follow. The catch-all `try_files $uri $uri/ $uri.html …` makes Nginx answer a directory
request without a trailing slash with a 301. Because `absolute_redirect` defaults to `on`, Nginx
builds that redirect from its own listener: `http://<host>:8080/guide/`. Configured redirects
(`redirectBlock`, `return <status> /to;`) are expanded the same way. No `charset` directive is
emitted, so `text/plain` goes out without a charset.

The same function also feeds `scripts/lib/render-static-nginx.hs`, which
`scripts/site-access-drill.sh` uses, so the drill inherits the fix with no extra change.

Evidence of both bugs is in `docs/audits/static-runtime-defaults-2026-10-13/`. Its `reproduce.py`
runs the v0.6.2 golden configuration in a pinned Nginx container, and `results.json` shows
`Location: http://docs.example.test:8080/guide/` and `Content-Type: text/plain` for a UTF-8 file.
The renderer is unchanged between v0.6.2 and master, apart from an unrelated `access` field on the
type.

The golden test `renderNginxConfig notes` in `cli/nagare-dsl/test/StaticSpec.hs` compares the
renderer's output for the fixture site with `cli/nagare-dsl/test/golden/static-site.nginx.conf`.
That golden file is therefore the exact bytes the renderer produces, which lets a flake check run
real Nginx on it without calling Haskell.

`just gate-fast` runs the style checks and both Haskell suites. The full gate, which `just land`
starts on the landed commit, also builds every flake check on `aarch64-darwin` and `x86_64-linux`.
Flake checks are registered in `nix/checks/scripts.nix`, as `pkgs.runCommand` derivations that run
a script from the source tree.

ADRs: [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
means the defect is proved against a real Nginx locally, not on a cloud deploy. No ADR governs the
static runtime configuration, and this change does not need one.


## Plan of Work

### M1: Renderer

In `renderNginxConfig`, after `index index.html;`, emit:

```text
    absolute_redirect off;
    charset utf-8;
    charset_types text/css text/plain text/xml text/markdown application/javascript application/json application/manifest+json application/rss+xml application/atom+xml image/svg+xml;
```

`text/html` is always in `charset_types` and need not be listed. Update the module's header comment
to say that redirects are relative and text is UTF-8. Regenerate the golden file and check that its
diff is exactly these three lines.

### M2: Real-Nginx check

Add `scripts/test-static-nginx-runtime.sh` and register it in `nix/checks/scripts.nix` as
`static-nginx-runtime`, with `nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.curl pkgs.gnused pkgs.nginx ]`
and `__darwinAllowLocalNetworking = true;`, since the full gate builds it on Darwin too. The script:

1. Creates a document root under `$TMPDIR` containing `guide/index.html`, `new.html`, `404.html`,
   `example.txt` (UTF-8 with an em dash and `café`), `style.css` with a non-ASCII comment, and a
   small binary `assets/logo.png`.
2. Copies `cli/nagare-dsl/test/golden/static-site.nginx.conf`, rewriting only its `root` line to
   that directory.
3. Writes a main configuration that mirrors the image's: `pid`, `error_log stderr` and every
   `*_temp_path` under `$TMPDIR`, then `http { include <pkgs.nginx>/conf/mime.types;
   default_type application/octet-stream; access_log off; include <server block>; }`. It starts
   `nginx -p "$TMPDIR" -c …` and waits for port 8080.
4. Makes the requests under Validation, with `Host: docs.example.test` and
   `X-Forwarded-Proto: https`, and exits non-zero on the first mismatch. It stops Nginx using the PID
   from its own pid file.

Run it once against the unmodified golden file first, and confirm that it fails on the `Location`
and `Content-Type` assertions. That proves the check detects both bugs.

### M3: Docs and bug records

Add a CHANGELOG `[Unreleased]` line under Fixed. In `docs/user/static-hosting.md`, near the
redirects table row, say that generated redirects are relative and text is served as UTF-8. Set
both bug reports to `status: fixed`, `fixedVersion: unreleased`, with a `resolution` that names the
commit and the `static-nginx-runtime` check. Add a `docs/bug-reports/log.md` entry.


## Concrete Steps

From the repository root:

```bash
cd cli/nagare-dsl && cabal test nagare-dsl-test --test-options="-p '/renderNginxConfig/' --accept"
git diff -- cli/nagare-dsl/test/golden/static-site.nginx.conf   # exactly the three new lines
nix build .#checks.aarch64-darwin.static-nginx-runtime -L        # or the x86_64-linux attribute on Linux
just haskell-style-check && just gate-fast
just land
```


## Validation and Acceptance

The `static-nginx-runtime` check passes when all of the following hold:

| Request | Expected |
| --- | --- |
| `GET /guide` | `301`, `Location` exactly `/guide/` (no scheme, host or `:8080`) |
| `GET /guide/` | `200`, body is `guide/index.html` |
| `GET /old` | `301`, `Location` exactly `/new` |
| `GET /example.txt` | `200`, `Content-Type: text/plain; charset=utf-8`, body bytes equal the file |
| `GET /style.css` | `Content-Type: text/css; charset=utf-8` |
| `GET /assets/logo.png` | `Content-Type: image/png` with no charset, body SHA-256 equals the file's |

The check must fail on the pre-M1 golden configuration. No cloud deploy is part of acceptance. The
release's intranet deploy-and-login check confirms it in production.


## Idempotence and Recovery

Every step is local and repeatable. The check uses only `$TMPDIR` and stops its own Nginx by PID.
To revert, revert the commit; sites keep whichever configuration their last deploy baked in.


## Interfaces and Dependencies

No interface changes. `renderNginxConfig :: StaticSite -> ByteString` keeps its signature. The
directives need Nginx 1.11.8 or later; the image is pinned to `nginx:1.27-alpine` and the check uses
nixpkgs' `pkgs.nginx`.
