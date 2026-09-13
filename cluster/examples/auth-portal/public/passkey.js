const csrf = document.querySelector('meta[name="portal-csrf"]')?.content;

function fromBase64url(value) {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

function toBase64url(value) {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeOptions(options) {
  const copy = structuredClone(options);
  copy.challenge = fromBase64url(copy.challenge);
  if (copy.user?.id) copy.user.id = fromBase64url(copy.user.id);
  for (const credential of copy.allowCredentials || []) credential.id = fromBase64url(credential.id);
  for (const credential of copy.excludeCredentials || []) credential.id = fromBase64url(credential.id);
  return copy;
}

function encodeCredential(credential) {
  const response = {};
  for (const key of ["clientDataJSON", "attestationObject", "authenticatorData", "signature", "userHandle"]) {
    if (credential.response[key]) response[key] = toBase64url(credential.response[key]);
  }
  return {
    id: credential.id,
    rawId: toBase64url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    response,
    clientExtensionResults: credential.getClientExtensionResults(),
  };
}

async function jsonRequest(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-Portal-CSRF": csrf || body.csrf || "" },
    body: JSON.stringify(body),
  });
  const data = response.status === 204 ? {} : await response.json();
  if (!response.ok) throw new Error(data.error || "Passkey request failed");
  return data;
}

async function finishLogin(path, ceremonyId, options, returnTo, csrfValue = csrf) {
  const assertion = encodeCredential(await navigator.credentials.get({ publicKey: decodeOptions(options) }));
  const result = await jsonRequest(path, { csrf: csrfValue, ceremonyId, assertion, return_to: returnTo });
  window.location.assign(result.redirect || returnTo || "/account");
}

async function act(button) {
  button.disabled = true;
  try {
    if (button.dataset.passkeyAction === "embedded") {
      const data = JSON.parse(document.querySelector("#passkey-data").textContent);
      await finishLogin("/login/mfa", data.ceremonyId, data.options, data.returnTo, data.csrf);
    } else if (button.dataset.passkeyAction === "login") {
      const begun = await jsonRequest("/login/passkey/begin", { csrf });
      await finishLogin("/login/passkey/complete", begun.ceremonyId, begun.options, button.dataset.returnTo || "");
    } else if (button.dataset.passkeyAction === "register") {
      const begun = await jsonRequest("/account/passkeys/begin", { csrf });
      const credential = encodeCredential(await navigator.credentials.create({ publicKey: decodeOptions(begun.options) }));
      await jsonRequest("/account/passkeys/complete", { csrf, ceremonyId: begun.ceremonyId, credential, label: "Browser passkey" });
      window.location.reload();
    }
  } catch (error) {
    window.alert(error instanceof Error ? error.message : "Passkey request failed");
    button.disabled = false;
  }
}

for (const button of document.querySelectorAll("[data-passkey-action]")) button.addEventListener("click", () => act(button));
