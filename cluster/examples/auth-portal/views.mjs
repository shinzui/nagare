export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function safeJson(value) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

function layout(config, heading, body) {
  const logo = config.logoUrl
    ? `<img class="logo" src="${escapeHtml(config.logoUrl)}" alt="">`
    : "";
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(heading)} · ${escapeHtml(config.title)}</title>
  <link rel="stylesheet" href="/public/portal.css">
</head>
<body><main class="card">${logo}<p class="brand">${escapeHtml(config.title)}</p><h1>${escapeHtml(heading)}</h1>${body}</main></body>
</html>`;
}

function csrfField(csrf) {
  return `<input type="hidden" name="csrf" value="${escapeHtml(csrf)}">`;
}

function notice(text, kind = "notice") {
  return text ? `<p class="${escapeHtml(kind)}">${escapeHtml(text)}</p>` : "";
}

export function loginPage(config, { csrf, returnTo = "", message = "", noticeText = "" }) {
  return layout(config, "Sign in", `${notice(noticeText)}${notice(message, "error")}
<form method="post" action="/login">
  ${csrfField(csrf)}
  <input type="hidden" name="return_to" value="${escapeHtml(returnTo)}">
  <label>Login or email<input name="loginId" autocomplete="username" required></label>
  <label>Password<input name="password" type="password" autocomplete="current-password" required></label>
  <button type="submit">Sign in</button>
</form>
<meta name="portal-csrf" content="${escapeHtml(csrf)}">
<button class="secondary" type="button" data-passkey-action="login" data-return-to="${escapeHtml(returnTo)}">Sign in with a passkey</button>
<p><a href="/password/forgot">Forgot your password?</a>${config.allowSignup ? ' · <a href="/signup">Create an account</a>' : ""}</p>
<script type="module" src="/public/passkey.js"></script>`);
}

export function mfaPage(config, { csrf, ceremonyId, options, returnTo = "" }) {
  const payload = safeJson({ kind: "mfa", csrf, ceremonyId, options, returnTo });
  return layout(config, "Use your passkey", `<p>Finish signing in with your passkey.</p>
<script id="passkey-data" type="application/json">${payload}</script>
<button type="button" data-passkey-action="embedded">Continue</button>
<script type="module" src="/public/passkey.js"></script>`);
}

export function signupPage(config, { csrf, message = "" }) {
  return layout(config, "Create an account", `${notice(message, "error")}
<form method="post" action="/signup">${csrfField(csrf)}
  <label>Login<input name="loginId" autocomplete="username" required></label>
  <label>Display name<input name="displayName" autocomplete="name" required></label>
  <label>Email<input name="email" type="email" autocomplete="email"></label>
  <label>Password<input name="password" type="password" autocomplete="new-password" required></label>
  <button type="submit">Create account</button>
</form><p><a href="/login">Back to sign in</a></p>`);
}

export function forgotPage(config, { csrf, sent = false }) {
  return layout(config, "Reset your password", `${sent ? notice("If that address exists, we sent a link.") : ""}
<form method="post" action="/password/forgot">${csrfField(csrf)}
  <label>Email<input name="email" type="email" autocomplete="email" required></label>
  <button type="submit">Send reset link</button>
</form><p><a href="/login">Back to sign in</a></p>`);
}

export function resetPage(config, { csrf, token, message = "" }) {
  return layout(config, "Choose a new password", `${notice(message, "error")}
<form method="post" action="/v1/auth/password-reset/confirm">${csrfField(csrf)}
  <input type="hidden" name="token" value="${escapeHtml(token)}">
  <label>New password<input name="newPassword" type="password" autocomplete="new-password" required></label>
  <button type="submit">Reset password</button>
</form>`);
}

export function verificationPage(config, { ok }) {
  return layout(config, "Email verification", ok
    ? '<p class="notice">Your email address is verified.</p><p><a href="/account">Continue to your account</a></p>'
    : '<p class="error">That verification link is invalid or expired.</p><p><a href="/login">Return to sign in</a></p>');
}

export function accountPage(config, { csrf, user, passkeys, message = "" }) {
  const rows = passkeys.length === 0
    ? "<li>No passkeys registered.</li>"
    : passkeys.map((key) => `<li><span>${escapeHtml(key.label || "Passkey")}</span>
      <form method="post" action="/account/passkeys/${escapeHtml(key.passkeyId)}/delete">${csrfField(csrf)}<button class="link" type="submit">Delete</button></form></li>`).join("");
  return layout(config, "Your account", `${notice(message)}
<dl><dt>Login</dt><dd>${escapeHtml(user.loginId)}</dd><dt>Display name</dt><dd>${escapeHtml(user.displayName)}</dd><dt>Email</dt><dd>${escapeHtml(user.email || "Not set")}</dd></dl>
<h2>Change password</h2>
<form method="post" action="/account/password">${csrfField(csrf)}
  <label>Current password<input name="currentPassword" type="password" autocomplete="current-password" required></label>
  <label>New password<input name="newPassword" type="password" autocomplete="new-password" required></label>
  <button type="submit">Change password</button>
</form>
<h2>Passkeys</h2><ul class="passkeys">${rows}</ul>
<meta name="portal-csrf" content="${escapeHtml(csrf)}">
<button class="secondary" type="button" data-passkey-action="register">Add a passkey</button>
<p><a href="/_nagare/logout">Sign out</a></p><script type="module" src="/public/passkey.js"></script>`);
}

export function error403Page(config, { host, user, returnTo }) {
  const who = user ? `<p>Signed in as <strong>${escapeHtml(user)}</strong>.</p>` : "";
  const back = returnTo ? `<a href="${escapeHtml(returnTo)}">Try again</a> · ` : "";
  return layout(config, "Access denied", `<p>You don't have access to <strong>${escapeHtml(host)}</strong>.</p>${who}<p>${back}<a href="/_nagare/logout">Switch account</a></p>`);
}

export function error503Page(config, { returnTo }) {
  const retry = returnTo || "/";
  return layout(config, "Sign-in is temporarily unavailable", `<p>Please wait a moment and try again.</p><p><a href="${escapeHtml(retry)}">Retry</a></p>`);
}
