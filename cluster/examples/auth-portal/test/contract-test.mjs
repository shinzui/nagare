import test, { after, before } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createPortal } from "../server.mjs";

let shomei;
let portal;
let portalUrl;
let shomeiUrl;
const calls = [];

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

function close(server) {
  return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

async function bodyOf(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? JSON.parse(text) : null;
}

function json(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(value));
}

before(async () => {
  shomei = createServer(async (request, response) => {
    const body = await bodyOf(request);
    calls.push({ path: request.url, authorization: request.headers.authorization, body });
    if (request.url === "/v1/auth/login" && body.loginId === "mfa") {
      return json(response, 200, { status: "mfa_required", ceremonyId: "ceremony-1", options: { challenge: "Y2hhbGxlbmdl" }, methods: ["passkey"] });
    }
    if (request.url === "/v1/auth/login") {
      return json(response, 200, { status: "complete", user: { loginId: "eve" }, token: { accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 300 } });
    }
    if (request.url === "/v1/auth/mfa/complete" || request.url === "/v1/auth/login/passkey/complete") {
      return json(response, 200, { accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 300, remembered: body.remember === true });
    }
    if (request.url === "/v1/auth/me") {
      return json(response, 200, { userId: "user-1", loginId: "<b>eve</b>", displayName: "Eve", email: "eve@example.test", status: "active" });
    }
    if (request.url === "/v1/auth/passkeys") return json(response, 200, []);
    return json(response, 404, { error: "not found" });
  });
  shomeiUrl = `http://127.0.0.1:${await listen(shomei)}`;
  portal = createPortal({ shomeiUrl });
  portalUrl = `http://127.0.0.1:${await listen(portal)}`;
});

after(async () => {
  await close(portal);
  await close(shomei);
});

async function loginForm(path = "/login") {
  const response = await fetch(portalUrl + path);
  const html = await response.text();
  const csrf = html.match(/name="csrf" value="([^"]+)"/)?.[1];
  const cookie = response.headers.get("set-cookie")?.split(";", 1)[0];
  assert.ok(csrf);
  assert.ok(cookie);
  return { csrf, cookie, html };
}

async function postForm(path, values, cookie) {
  return fetch(portalUrl + path, {
    method: "POST",
    redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookie },
    body: new URLSearchParams(values),
  });
}

test("complete login emits a decodable session handoff with returnTo", async () => {
  const { csrf, cookie } = await loginForm("/login?return_to=https%3A%2F%2Fapp.example.test%2Fx");
  const response = await postForm("/login", { csrf, loginId: "eve", password: "secret", return_to: "https://app.example.test/x" }, cookie);
  assert.equal(response.status, 204);
  const handoff = JSON.parse(Buffer.from(response.headers.get("nagare-session-establish"), "base64url").toString("utf8"));
  assert.deepEqual(handoff, { accessToken: "access-1", refreshToken: "refresh-1", returnTo: "https://app.example.test/x" });
});

test("mfa_required renders a passkey page", async () => {
  const { csrf, cookie } = await loginForm();
  const response = await postForm("/login", { csrf, loginId: "mfa", password: "secret", return_to: "" }, cookie);
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Use your passkey/);
  assert.match(html, /ceremony-1/);
});

test("missing or mismatched CSRF is rejected before Shomei", async () => {
  const { csrf, cookie } = await loginForm();
  const beforeCalls = calls.length;
  const missing = await postForm("/login", { loginId: "eve", password: "secret" }, cookie);
  assert.equal(missing.status, 403);
  const mismatched = await postForm("/login", { csrf: csrf + "x", loginId: "eve", password: "secret" }, cookie);
  assert.equal(mismatched.status, 403);
  assert.equal(calls.length, beforeCalls);
});

test("anonymous account request redirects to login", async () => {
  const response = await fetch(portalUrl + "/account", { redirect: "manual", headers: { "X-Forwarded-Host": "auth.example.test" } });
  assert.equal(response.status, 302);
  assert.match(response.headers.get("location"), /^\/login\?return_to=/);
});

test("authenticated account calls Shomei with bearer and escapes login id", async () => {
  const response = await fetch(portalUrl + "/account", { headers: { Authorization: "Bearer access-1" } });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /&lt;b&gt;eve&lt;\/b&gt;/);
  assert.doesNotMatch(html, /<b>eve<\/b>/);
  const meCall = calls.findLast((call) => call.path === "/v1/auth/me");
  assert.equal(meCall.authorization, "Bearer access-1");
});

test("403 page escapes the protected host", async () => {
  const response = await fetch(portalUrl + "/errors/403", { headers: { "X-Nagare-Error-Host": "<script>alert(1)</script>" } });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.doesNotMatch(html, /<script>alert/);
});

test("signup is disabled by default", async () => {
  const response = await fetch(portalUrl + "/signup");
  assert.equal(response.status, 404);
});

async function postJson(path, values, cookie, csrf) {
  return fetch(portalUrl + path, {
    method: "POST",
    redirect: "manual",
    headers: { "Content-Type": "application/json", Accept: "application/json", Cookie: cookie, "X-Portal-CSRF": csrf },
    body: JSON.stringify({ ...values, csrf }),
  });
}

const lastBody = (path) => calls.findLast((call) => call.path === path)?.body;

test("the sign-in form offers Keep me signed in, checked", async () => {
  const { html } = await loginForm();
  assert.match(html, /<input name="remember" type="checkbox" checked> Keep me signed in/);
});

test("a native sign-in forwards remember: true when checked and false when not", async () => {
  const { csrf, cookie } = await loginForm();
  assert.equal((await postForm("/login", { csrf, loginId: "eve", password: "secret", remember: "on" }, cookie)).status, 204);
  assert.deepEqual(lastBody("/v1/auth/login"), { loginId: "eve", password: "secret", remember: true });
  assert.equal((await postForm("/login", { csrf, loginId: "eve", password: "secret" }, cookie)).status, 204);
  assert.deepEqual(lastBody("/v1/auth/login"), { loginId: "eve", password: "secret", remember: false });
});

test("the passkey second step carries remember from the password step", async () => {
  const { csrf, cookie } = await loginForm();
  const page = await postForm("/login", { csrf, loginId: "mfa", password: "secret", remember: "on" }, cookie);
  assert.match(await page.text(), /"remember":true/);
  for (const remember of [true, false]) {
    const done = await postJson("/login/mfa", { ceremonyId: "ceremony-1", assertion: { id: "x" }, remember }, cookie, csrf);
    assert.equal(done.status, 204);
    assert.equal(lastBody("/v1/auth/mfa/complete").remember, remember);
  }
});

test("passkey sign-in forwards remember", async () => {
  const { csrf, cookie } = await loginForm();
  for (const remember of [true, false]) {
    const done = await postJson("/login/passkey/complete", { ceremonyId: "ceremony-2", assertion: { id: "x" }, remember }, cookie, csrf);
    assert.equal(done.status, 204);
    assert.deepEqual(lastBody("/v1/auth/login/passkey/complete"), { ceremonyId: "ceremony-2", assertion: { id: "x" }, remember });
  }
});
