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
