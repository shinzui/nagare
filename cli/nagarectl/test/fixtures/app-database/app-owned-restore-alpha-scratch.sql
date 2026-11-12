\set roles `cat /tmp/postgres-app-owned-roles.json`
SELECT set_config('nagare.roles', :'roles', false);
DO $restore$
DECLARE
  doc jsonb := current_setting('nagare.roles')::jsonb;
  expected_owner text := 'alpha_owner';
  database_owner text := 'kotei_maintenance';
  target text := 'alpha_restore_r1';
  create_roles boolean := false;
  names text[];
  app text[];
  r jsonb;
  m jsonb;
  g jsonb;
  setting text;
BEGIN
  IF doc->>'version' IS DISTINCT FROM '1' THEN RAISE EXCEPTION 'the role file has an unknown version'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(doc) k WHERE k NOT IN ('version', 'owner', 'database', 'roles', 'memberships', 'databaseOwner', 'databaseGrants', 'databaseSettings', 'roleDatabaseSettings')) THEN RAISE EXCEPTION 'the role file has an unknown key'; END IF;
  IF doc->>'owner' IS DISTINCT FROM expected_owner THEN RAISE EXCEPTION 'the role file names owner %, not %', doc->>'owner', expected_owner; END IF;
  IF doc->>'databaseOwner' IS DISTINCT FROM database_owner THEN RAISE EXCEPTION 'the role file names database owner %, not %', doc->>'databaseOwner', database_owner; END IF;
  SELECT coalesce(array_agg(x->>'name'), '{}') || expected_owner INTO names FROM jsonb_array_elements(doc->'roles') x;
  FOR r IN SELECT x FROM jsonb_array_elements(doc->'roles') x LOOP
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(r) k WHERE k NOT IN ('name', 'login', 'createrole', 'inherit', 'elevated', 'connectionLimit', 'validUntil', 'verifier', 'settings')) THEN RAISE EXCEPTION 'role % has an unknown key', r->>'name'; END IF;
    IF (r->>'elevated')::boolean THEN RAISE EXCEPTION 'role % holds an elevated attribute', r->>'name'; END IF;
    IF r->>'name' LIKE 'pg\_%' THEN RAISE EXCEPTION 'role % has a predefined role name', r->>'name'; END IF;
    IF r->>'verifier' IS NOT NULL AND r->>'verifier' !~ '^SCRAM-SHA-256[$][0-9]+:[A-Za-z0-9+/=]+[$][A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$' THEN RAISE EXCEPTION 'role % has a verifier that is not SCRAM-SHA-256', r->>'name'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(r->'settings') e WHERE e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') THEN RAISE EXCEPTION 'role % has a setting whose name is not a setting name', r->>'name'; END IF;
  END LOOP;
  FOR m IN SELECT x FROM jsonb_array_elements(doc->'memberships') x LOOP
    IF NOT (m->>'role' = ANY (names) AND m->>'member' = ANY (names)) THEN RAISE EXCEPTION 'membership % > % names a role outside the app', m->>'role', m->>'member'; END IF;
  END LOOP;
  FOR g IN SELECT x FROM jsonb_array_elements(doc->'databaseGrants') x LOOP
    IF g->>'grantee' <> 'PUBLIC' AND NOT (g->>'grantee' = ANY (names) AND g->>'grantor' = ANY (names) AND g->>'privilege' IN ('CONNECT', 'CREATE', 'TEMPORARY')) THEN RAISE EXCEPTION 'database grant to % names a role outside the app', g->>'grantee'; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(doc->'databaseSettings') e WHERE e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') OR EXISTS (SELECT 1 FROM jsonb_array_elements(doc->'roleDatabaseSettings') x, jsonb_array_elements_text(x->'settings') e WHERE NOT (x->>'role' = ANY (names)) OR e !~ '^[A-Za-z_][A-Za-z0-9_.]*=') THEN RAISE EXCEPTION 'the role file has a setting outside the app or a name that is not a setting name'; END IF;
  WITH RECURSIVE a(oid) AS (SELECT oid FROM pg_roles WHERE rolname = expected_owner UNION SELECT x.roleid FROM pg_auth_members x JOIN a ON x.member = a.oid WHERE x.admin_option)
  SELECT array_agg(rolname) INTO app FROM pg_roles WHERE oid IN (SELECT oid FROM a);
  IF app IS NULL THEN RAISE EXCEPTION 'owner % does not exist; apply the app database first', expected_owner; END IF;
  FOR r IN SELECT x FROM jsonb_array_elements(doc->'roles') x LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r->>'name') THEN
      IF NOT (r->>'name' = ANY (app)) THEN RAISE EXCEPTION 'role % exists on this server and is not this app''s', r->>'name'; END IF;
    ELSIF NOT create_roles THEN
      RAISE EXCEPTION 'role % is absent; restore onto a rebuilt server with --rebuilt', r->>'name';
    ELSE
      EXECUTE format('CREATE ROLE %I %s %s %s CONNECTION LIMIT %s', r->>'name', CASE WHEN (r->>'login')::boolean THEN 'LOGIN' ELSE 'NOLOGIN' END, CASE WHEN (r->>'createrole')::boolean THEN 'CREATEROLE' ELSE 'NOCREATEROLE' END, CASE WHEN (r->>'inherit')::boolean THEN 'INHERIT' ELSE 'NOINHERIT' END, (r->>'connectionLimit')::int);
      IF r->>'verifier' IS NOT NULL THEN EXECUTE format('ALTER ROLE %I PASSWORD %L', r->>'name', r->>'verifier'); END IF;
      IF r->>'validUntil' IS NOT NULL THEN EXECUTE format('ALTER ROLE %I VALID UNTIL %L', r->>'name', r->>'validUntil'); END IF;
      FOR setting IN SELECT jsonb_array_elements_text(r->'settings') LOOP
        EXECUTE format('ALTER ROLE %I SET %s TO %L', r->>'name', split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));
      END LOOP;
    END IF;
  END LOOP;
  IF create_roles THEN
    FOR m IN SELECT x FROM jsonb_array_elements(doc->'memberships') x ORDER BY x->>'grantor' = ANY (names), x->>'role', x->>'member' LOOP
      EXECUTE format('GRANT %I TO %I WITH ADMIN %s, INHERIT %s, SET %s GRANTED BY %I', m->>'role', m->>'member', CASE WHEN (m->>'admin')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN (m->>'inherit')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN (m->>'set')::boolean THEN 'TRUE' ELSE 'FALSE' END, CASE WHEN m->>'grantor' = ANY (names) THEN m->>'grantor' ELSE current_user END);
    END LOOP;
    FOR r IN SELECT x FROM jsonb_array_elements(doc->'roleDatabaseSettings') x LOOP
      FOR setting IN SELECT jsonb_array_elements_text(r->'settings') LOOP
        EXECUTE format('ALTER ROLE %I IN DATABASE %I SET %s TO %L', r->>'role', target, split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));
      END LOOP;
    END LOOP;
  END IF;
  FOR g IN SELECT x FROM jsonb_array_elements(doc->'databaseGrants') x WHERE x->>'grantee' <> 'PUBLIC' AND NOT (x->>'grantee' = database_owner AND x->>'grantor' = database_owner) LOOP
    -- An object grant is recorded as its grantor's only when made as it.
    EXECUTE format('SET ROLE %I', g->>'grantor');
    EXECUTE format('GRANT %s ON DATABASE %I TO %I%s', g->>'privilege', target, g->>'grantee', CASE WHEN (g->>'grantable')::boolean THEN ' WITH GRANT OPTION' ELSE '' END);
    RESET ROLE;
  END LOOP;
  FOR setting IN SELECT jsonb_array_elements_text(doc->'databaseSettings') LOOP
    EXECUTE format('ALTER DATABASE %I SET %s TO %L', target, split_part(setting, '=', 1), substr(setting, strpos(setting, '=') + 1));
  END LOOP;
END
$restore$;
