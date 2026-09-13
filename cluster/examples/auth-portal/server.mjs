import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  accountPage,
  error403Page,
  error503Page,
  forgotPage,
  loginPage,
  mfaPage,
  resetPage,
  signupPage,
  verificationPage,
} from "./views.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const bodyLimit = 256 * 1024;

function portalConfig(overrides = {}) {
  return {
    shomeiUrl: overrides.shomeiUrl || process.env.SHOMEI_URL || "http://shomei.nagare-system.svc.cluster.local",
    title: overrides.title || process.env.PORTAL_TITLE || "Nagare",
    logoUrl: overrides.logoUrl ?? process.env.PORTAL_LOGO_URL ?? "",
    allowSignup: overrides.allowSignup ?? process.env.PORTAL_ALLOW_SIGNUP === "true",
  };
}

function parseCookies(header = "") {
  return Object.fromEntries(header.split(";").map((part) => part.trim()).filter(Boolean).map((part) => {
    const separator = part.indexOf("=");
    return separator < 0 ? [part, ""] : [part.slice(0, separator), decodeURIComponent(part.slice(separator + 1))];
  }));
}

function csrfToken() {
  return randomBytes(24).toString("base64url");
}

function csrfCookie(token) {
  return `portal_csrf=${encodeURIComponent(token)}; HttpOnly; Secure; SameSite=Lax; Path=/`;
}

function equalSecret(left = "", right = "") {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length > 0 && a.length === b.length && timingSafeEqual(a, b);
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > bodyLimit) throw Object.assign(new Error("request body too large"), { status: 413 });
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if ((request.headers["content-type"] || "").startsWith("application/json")) return raw ? JSON.parse(raw) : {};
  return Object.fromEntries(new URLSearchParams(raw));
}

function suppliedCsrf(request, body) {
  return String(body.csrf || request.headers["x-portal-csrf"] || "");
}

function requireCsrf(request, body) {
  const cookie = parseCookies(request.headers.cookie).portal_csrf;
  if (!equalSecret(cookie, suppliedCsrf(request, body))) throw Object.assign(new Error("CSRF check failed"), { status: 403 });
}

function send(response, status, body = "", headers = {}) {
  response.writeHead(status, { "Cache-Control": "no-store", ...headers });
  response.end(body);
}

function sendHtml(response, status, html, csrf) {
  const headers = { "Content-Type": "text/html; charset=utf-8" };
  if (csrf) headers["Set-Cookie"] = csrfCookie(csrf);
  send(response, status, html, headers);
}

function sendJson(response, status, value) {
  send(response, status, JSON.stringify(value), { "Content-Type": "application/json; charset=utf-8" });
}

function redirect(response, location, status = 303) {
  send(response, status, "", { Location: location });
}

function forwardedHost(request) {
  return String(request.headers["x-forwarded-host"] || request.headers.host || "").split(",", 1)[0].trim();
}

function bearer(request) {
  const value = String(request.headers.authorization || "");
  return value.startsWith("Bearer ") ? value : null;
}

function accountLoginUrl(request) {
  return `/login?return_to=${encodeURIComponent(`https://${forwardedHost(request)}/account`)}`;
}

async function callShomei(config, path, { method = "GET", body, authorization } = {}) {
  const headers = { Accept: "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (authorization) headers.Authorization = authorization;
  const response = await fetch(`${config.shomeiUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let value = null;
  if (text) {
    try { value = JSON.parse(text); } catch { value = null; }
  }
  if (!response.ok) throw Object.assign(new Error("Shomei request failed"), { status: 502, upstreamStatus: response.status });
  return value;
}

function tokenPair(value) {
  const token = value?.token || value;
  if (!token?.accessToken || !token?.refreshToken) throw Object.assign(new Error("Shomei response did not contain tokens"), { status: 502 });
  return token;
}

function establish(response, value, returnTo) {
  const token = tokenPair(value);
  const payload = Buffer.from(JSON.stringify({
    accessToken: token.accessToken,
    refreshToken: token.refreshToken,
    returnTo: returnTo || null,
  })).toString("base64url");
  send(response, 204, "", { "Nagare-Session-Establish": payload });
}

function noticeFor(url) {
  if (url.searchParams.get("error") === "session") return "Your session could not be established. Please sign in again.";
  if (url.searchParams.get("logged_out") === "1") return "You have signed out.";
  if (url.searchParams.get("reset") === "1") return "Your password was reset. Sign in with the new password.";
  return "";
}

function pageCsrf(response) {
  const csrf = csrfToken();
  response.setHeader("Set-Cookie", csrfCookie(csrf));
  return csrf;
}

async function serveStatic(pathname, response) {
  const files = {
    "/public/portal.css": ["portal.css", "text/css; charset=utf-8"],
    "/public/passkey.js": ["passkey.js", "text/javascript; charset=utf-8"],
  };
  const target = files[pathname];
  if (!target) return false;
  const content = await readFile(join(here, "public", target[0]));
  send(response, 200, content, { "Content-Type": target[1], "Cache-Control": "public, max-age=300" });
  return true;
}

export function createPortal(overrides = {}) {
  const config = portalConfig(overrides);
  return createServer(async (request, response) => {
    const url = new URL(request.url || "/", "http://portal.invalid");
    const method = request.method || "GET";
    try {
      if (await serveStatic(url.pathname, response)) return;
      if (method === "GET" && url.pathname === "/healthz") return send(response, 200, "ok\n", { "Content-Type": "text/plain; charset=utf-8" });
      if (method === "GET" && url.pathname === "/") return redirect(response, "/account", 302);

      if (method === "GET" && url.pathname === "/login") {
        const csrf = pageCsrf(response);
        return sendHtml(response, 200, loginPage(config, { csrf, returnTo: url.searchParams.get("return_to") || "", noticeText: noticeFor(url) }));
      }
      if (method === "POST" && url.pathname === "/login") {
        const body = await readBody(request);
        requireCsrf(request, body);
        try {
          const result = await callShomei(config, "/v1/auth/login", { method: "POST", body: { loginId: body.loginId, password: body.password } });
          if (result?.status === "mfa_required") {
            const csrf = pageCsrf(response);
            return sendHtml(response, 200, mfaPage(config, { csrf, ceremonyId: result.ceremonyId, options: result.options, returnTo: body.return_to || "" }));
          }
          return establish(response, result, body.return_to);
        } catch {
          const csrf = pageCsrf(response);
          return sendHtml(response, 401, loginPage(config, { csrf, returnTo: body.return_to || "", message: "Sign-in failed" }));
        }
      }
      if (method === "POST" && url.pathname === "/login/mfa") {
        const body = await readBody(request);
        requireCsrf(request, body);
        const result = await callShomei(config, "/v1/auth/mfa/complete", { method: "POST", body: { ceremonyId: body.ceremonyId, proof: { type: "passkey", assertion: body.assertion } } });
        return establish(response, result, body.return_to);
      }
      if (method === "POST" && url.pathname === "/login/passkey/begin") {
        const body = await readBody(request);
        requireCsrf(request, body);
        return sendJson(response, 200, await callShomei(config, "/v1/auth/login/passkey/begin", { method: "POST" }));
      }
      if (method === "POST" && url.pathname === "/login/passkey/complete") {
        const body = await readBody(request);
        requireCsrf(request, body);
        const result = await callShomei(config, "/v1/auth/login/passkey/complete", { method: "POST", body: { ceremonyId: body.ceremonyId, assertion: body.assertion } });
        return establish(response, result, body.return_to);
      }

      if (url.pathname === "/signup" && !config.allowSignup) return send(response, 404, "Not Found\n", { "Content-Type": "text/plain; charset=utf-8" });
      if (method === "GET" && url.pathname === "/signup") {
        const csrf = pageCsrf(response);
        return sendHtml(response, 200, signupPage(config, { csrf }));
      }
      if (method === "POST" && url.pathname === "/signup") {
        const body = await readBody(request);
        requireCsrf(request, body);
        try {
          const result = await callShomei(config, "/v1/auth/signup", { method: "POST", body: { loginId: body.loginId, email: body.email || null, password: body.password, displayName: body.displayName } });
          return establish(response, result, "/account");
        } catch {
          const csrf = pageCsrf(response);
          return sendHtml(response, 400, signupPage(config, { csrf, message: "Account creation failed" }));
        }
      }

      if (method === "GET" && url.pathname === "/password/forgot") {
        const csrf = pageCsrf(response);
        return sendHtml(response, 200, forgotPage(config, { csrf }));
      }
      if (method === "POST" && url.pathname === "/password/forgot") {
        const body = await readBody(request);
        requireCsrf(request, body);
        try { await callShomei(config, "/v1/auth/password-reset/request", { method: "POST", body: { email: body.email } }); } catch { /* Deliberately indistinguishable. */ }
        const csrf = pageCsrf(response);
        return sendHtml(response, 202, forgotPage(config, { csrf, sent: true }));
      }
      if (method === "GET" && url.pathname === "/v1/auth/password-reset/confirm") {
        const csrf = pageCsrf(response);
        return sendHtml(response, 200, resetPage(config, { csrf, token: url.searchParams.get("token") || "" }));
      }
      if (method === "POST" && url.pathname === "/v1/auth/password-reset/confirm") {
        const body = await readBody(request);
        requireCsrf(request, body);
        await callShomei(config, "/v1/auth/password-reset/confirm", { method: "POST", body: { token: body.token, newPassword: body.newPassword } });
        return redirect(response, "/login?reset=1");
      }
      if (method === "GET" && url.pathname === "/v1/auth/verify-email/confirm") {
        let ok = true;
        try { await callShomei(config, "/v1/auth/verify-email/confirm", { method: "POST", body: { token: url.searchParams.get("token") || "" } }); } catch { ok = false; }
        return sendHtml(response, ok ? 200 : 400, verificationPage(config, { ok }));
      }

      if (method === "GET" && url.pathname === "/account") {
        const authorization = bearer(request);
        if (!authorization) return redirect(response, accountLoginUrl(request), 302);
        const [user, passkeys] = await Promise.all([
          callShomei(config, "/v1/auth/me", { authorization }),
          callShomei(config, "/v1/auth/passkeys", { authorization }),
        ]);
        const csrf = pageCsrf(response);
        return sendHtml(response, 200, accountPage(config, { csrf, user, passkeys: passkeys || [], message: url.searchParams.get("updated") === "1" ? "Account updated." : "" }));
      }
      if (method === "POST" && url.pathname === "/account/password") {
        const authorization = bearer(request);
        if (!authorization) return redirect(response, accountLoginUrl(request), 302);
        const body = await readBody(request);
        requireCsrf(request, body);
        await callShomei(config, "/v1/auth/password/change", { method: "POST", authorization, body: { currentPassword: body.currentPassword, newPassword: body.newPassword } });
        return redirect(response, "/account?updated=1");
      }
      if (method === "POST" && url.pathname === "/account/passkeys/begin") {
        const authorization = bearer(request);
        if (!authorization) return sendJson(response, 401, { error: "Sign in required" });
        const body = await readBody(request);
        requireCsrf(request, body);
        return sendJson(response, 200, await callShomei(config, "/v1/auth/passkeys/register/begin", { method: "POST", authorization }));
      }
      if (method === "POST" && url.pathname === "/account/passkeys/complete") {
        const authorization = bearer(request);
        if (!authorization) return sendJson(response, 401, { error: "Sign in required" });
        const body = await readBody(request);
        requireCsrf(request, body);
        const result = await callShomei(config, "/v1/auth/passkeys/register/complete", { method: "POST", authorization, body: { ceremonyId: body.ceremonyId, credential: body.credential, label: body.label || null } });
        return sendJson(response, 200, result);
      }
      const deletion = url.pathname.match(/^\/account\/passkeys\/([^/]+)\/delete$/);
      if (method === "POST" && deletion) {
        const authorization = bearer(request);
        if (!authorization) return redirect(response, accountLoginUrl(request), 302);
        const body = await readBody(request);
        requireCsrf(request, body);
        await callShomei(config, `/v1/auth/passkeys/${encodeURIComponent(decodeURIComponent(deletion[1]))}`, { method: "DELETE", authorization });
        return redirect(response, "/account?updated=1");
      }

      if (method === "GET" && url.pathname === "/errors/403") {
        return sendHtml(response, 200, error403Page(config, {
          host: request.headers["x-nagare-error-host"] || "this site",
          user: request.headers["x-forwarded-user"] || "",
          returnTo: request.headers["x-nagare-return-to"] || "",
        }));
      }
      if (method === "GET" && url.pathname === "/errors/503") {
        return sendHtml(response, 200, error503Page(config, { returnTo: request.headers["x-nagare-return-to"] || "" }));
      }
      return send(response, 404, "Not Found\n", { "Content-Type": "text/plain; charset=utf-8" });
    } catch (error) {
      const status = Number(error?.status) || 500;
      if (status >= 500) console.error(`portal request failed: ${error instanceof Error ? error.message : "unknown error"}`);
      if ((request.headers.accept || "").includes("application/json")) return sendJson(response, status, { error: status === 403 ? "CSRF check failed" : "Request failed" });
      return send(response, status, status === 403 ? "Forbidden\n" : "Request failed\n", { "Content-Type": "text/plain; charset=utf-8" });
    }
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const port = Number(process.env.PORT || "8080");
  createPortal().listen(port, "0.0.0.0", () => console.log(`auth portal listening on ${port}`));
}
