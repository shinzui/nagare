-- EP-246 D4: the passkey table's columns, so a move refuses a Shomei whose table differs from the one
-- its export and restore name.
SELECT coalesce(string_agg(column_name || ' ' || data_type, ',' ORDER BY ordinal_position), '')
FROM information_schema.columns
WHERE table_schema = 'shomei' AND table_name = 'shomei_webauthn_credentials';
