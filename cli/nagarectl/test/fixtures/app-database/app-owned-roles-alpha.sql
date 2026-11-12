WITH RECURSIVE app(oid) AS (
  SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'alpha_owner'
  UNION
  SELECT m.roleid FROM pg_catalog.pg_auth_members AS m JOIN app ON m.member = app.oid WHERE m.admin_option
)
SELECT json_build_object(
  'version', 1,
  'owner', 'alpha_owner',
  'database', 'alpha',
  'roles', (SELECT coalesce(json_agg(json_build_object('name', a.rolname, 'login', a.rolcanlogin, 'createrole', a.rolcreaterole, 'inherit', a.rolinherit, 'elevated', a.rolsuper OR a.rolcreatedb OR a.rolreplication OR a.rolbypassrls, 'connectionLimit', a.rolconnlimit, 'validUntil', a.rolvaliduntil::text, 'verifier', CASE WHEN a.rolcanlogin THEN a.rolpassword END, 'settings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s WHERE s.setrole = a.oid AND s.setdatabase = 0), '[]')) ORDER BY a.rolname), '[]') FROM pg_authid a WHERE a.oid IN (SELECT oid FROM app) AND a.rolname <> 'alpha_owner'),
  'memberships', (SELECT coalesce(json_agg(json_build_object('role', r.rolname, 'member', m.rolname, 'grantor', g.rolname, 'admin', x.admin_option, 'inherit', x.inherit_option, 'set', x.set_option) ORDER BY r.rolname, m.rolname, g.rolname), '[]') FROM pg_auth_members x JOIN pg_roles r ON r.oid = x.roleid JOIN pg_roles m ON m.oid = x.member JOIN pg_roles g ON g.oid = x.grantor WHERE x.roleid IN (SELECT oid FROM app) AND x.member IN (SELECT oid FROM app)),
  'databaseOwner', (SELECT pg_get_userbyid(d.datdba) FROM pg_database d WHERE d.datname = 'alpha'),
  'databaseGrants', (SELECT coalesce(json_agg(json_build_object('grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, 'grantor', pg_get_userbyid(a.grantor), 'privilege', a.privilege_type, 'grantable', a.is_grantable) ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END, a.privilege_type), '[]') FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname = 'alpha'),
  'databaseSettings', coalesce((SELECT array_to_json(s.setconfig) FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE d.datname = 'alpha' AND s.setrole = 0), '[]'),
  'roleDatabaseSettings', (SELECT coalesce(json_agg(json_build_object('role', pg_get_userbyid(s.setrole), 'settings', array_to_json(s.setconfig)) ORDER BY pg_get_userbyid(s.setrole)), '[]') FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase WHERE d.datname = 'alpha' AND s.setrole IN (SELECT oid FROM app))
);
