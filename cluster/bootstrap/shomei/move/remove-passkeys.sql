-- EP-246 D4: remove exactly the exported passkeys, :'rows' being the export. A passkey registered after
-- the export is bound to the new domain and stays.
DELETE FROM shomei.shomei_webauthn_credentials
WHERE passkey_id IN (
  SELECT passkey_id FROM json_populate_recordset(NULL::shomei.shomei_webauthn_credentials, :'rows'::json)
);
