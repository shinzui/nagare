-- EP-246 D4: every stored passkey, as one JSON array of rows. Read-only.
SELECT coalesce(json_agg(row_to_json(c) ORDER BY c.passkey_id), '[]'::json)::text
FROM shomei.shomei_webauthn_credentials c;
