-- EP-246 D4: rolling a move back restores the table to the export exactly, :'rows' being the export.
-- Passkeys registered after the flip are bound to the new domain and are removed. One statement, so it
-- applies whole or not at all; the two halves touch disjoint rows.
WITH exported AS (
  SELECT * FROM json_populate_recordset(NULL::shomei.shomei_webauthn_credentials, :'rows'::json)
), newer AS (
  DELETE FROM shomei.shomei_webauthn_credentials
  WHERE passkey_id NOT IN (SELECT passkey_id FROM exported)
)
INSERT INTO shomei.shomei_webauthn_credentials
SELECT * FROM exported
ON CONFLICT (passkey_id) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  credential_id = EXCLUDED.credential_id,
  user_handle = EXCLUDED.user_handle,
  public_key = EXCLUDED.public_key,
  sign_counter = EXCLUDED.sign_counter,
  transports = EXCLUDED.transports,
  label = EXCLUDED.label,
  created_at = EXCLUDED.created_at,
  last_used_at = EXCLUDED.last_used_at;
