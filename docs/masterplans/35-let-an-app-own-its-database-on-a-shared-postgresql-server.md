---
id: 35
slug: let-an-app-own-its-database-on-a-shared-postgresql-server
title: "Let an app own its database on a shared PostgreSQL server"
kind: master-plan
created_at: 2026-11-11T15:15:38Z
intention: "intention_01m75kmah1emw9d4qqaveqxnx2"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-11T15:15:38Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-11T15:28:32Z
      mode: "update"
      note: "Require PostgreSQL 18 or later and link the intention."
---

# Let an app own its database on a shared PostgreSQL server

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. If durable project context changes, update or create ADRs in
`docs/adr/` in the same change.


## Vision & Scope

Today Nagare manages the inside of every app database: it creates two fixed users, grants a fixed
set of privileges, and refuses any other role, membership or grant as drift. An app that manages
its own roles and privileges in its own migrations cannot deploy without rewriting them. The
first such app is Kotei, whose `kotei-migrations/privileges/apply.sql`
(`mori://shinzui/kotei`, project-relative path; artifact-level URI pending) creates five roles,
grants memberships among them, moves ownership of its schemas and objects, and grants privileges
per role.

After this initiative an app database on a shared PostgreSQL server can be declared **app-owned**.
Nagare then provisions one login for it, the **owner credential**, which has `CREATEROLE` and
owns the database (directly, or through one declared owning role). The app's own SQL does
everything else: roles, logins, memberships, ownership and grants. Nagare stops judging what
happens inside that database and checks only that nothing the app created reaches beyond it.
Backups, restores, quiesce, resume and retirement keep working and now carry the roles the app
created. A task or an Application's pre-deploy hook can bind the owner credential under a
connection-URL variable name of its choosing.

This implements [IR-43](../improvement-requests/let-an-app-own-its-database.md), requested for
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.

Three constraints hold throughout:

- **An app database that does not opt in is untouched.** Its declaration, rendered SQL, backup
  schedule and review bytes are identical before and after. The fixed runtime and migration
  model stays the default.
- **Backups and maintenance do not depend on what the app did.** For an app-owned database,
  Nagare's backup, restore and drain run as the server administrator, so no revoked grant,
  row-level security policy or dropped membership can make a backup incomplete.
- **Apps stay apart.** The owner credential and every role it creates cannot reach another app's
  roles or database, Nagare's users, or a server-wide privilege.

Excluded: ClickHouse (it can follow under the same rule later); converting an existing app
database between the two models (ownership is fixed when the app database is created; moving is
a data migration, as [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md)
already says of direct databases); per-app resource limits for app-created logins; and creating
or supplying the passwords of the app's own logins, which the app and its operator own.


## Decomposition Strategy

Four children, by concern.

EP-257 makes ownership exist and makes it safe in the same plan: the declaration, the owner
credential, the end of drift judgement inside the database, and the boundary checks between
apps. They are one plan because they change the same observation and classification code, and
because allowing an app to create roles without the boundary checks is not a state the main
branch should ever be in.

EP-258 carries the app's roles through every operation that today assumes Nagare knows all the
users: scheduled and on-demand backup, scratch and rebuilt-server restore, quiesce, resume and
retirement. It is separate because it changes a different part of the code (backup Jobs, restore
Jobs, session drains) and has its own acceptance, AC-4.

EP-259 adds the binding: a task or pre-deploy hook binds an app database, and any binding may
name its URL variable. Most of it is independent of ownership and can proceed in parallel.

EP-260 confirms the whole on a local context with Kotei's real script, checks the user guide,
and releases. Under [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
the earlier plans find defects with interpreter tests and a real-PostgreSQL fixture; this plan
only confirms.

A single plan was rejected: the backup and binding work have separate acceptance and separate
code, and a single plan would be hard to resume. Splitting the boundary checks from the
declaration was rejected for the reason above.

Relevant decisions, all local:

- [ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) makes the
  declaration the authority for users and grants, treats access Nagare never granted as drift,
  dumps with the migration credential, and keeps roles and password hashes out of backups. This
  initiative contradicts each of those for app-owned databases only.
- [ADR 31](../adr/0031-own-database-privileges-are-declarable-server-wide-access-is-not.md)
  draws the boundary at the app's own databases and lets privileges inside it be declared case
  by case. Its boundary is kept and becomes the only thing Nagare enforces for an app-owned
  database. Its rule that the app database, not the workload, decides who binds the owning
  credential is kept and extended to tasks.
- [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md),
  [ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md) and
  [ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md)
  govern scopes, reviewed operations and recorded identity; nothing here changes them.
- [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
  sets the rebuild objective that a restore returning unusable logins would miss.

EP-257 writes a new ADR 37, "An app may own its database; Nagare keeps apps apart", and adds a
one-line amendment note to ADR 30 and ADR 31. No cross-repository ADR applies.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-257 | Declare an app-owned PostgreSQL app database and keep apps apart | [docs/plans/257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md](../plans/257-declare-an-app-owned-postgresql-app-database-and-keep-apps-apart.md) | None | None | In Progress |
| EP-258 | Carry an app's roles through backups, restores, quiesce and retirement | [docs/plans/258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md](../plans/258-carry-an-app-s-roles-through-backups-restores-quiesce-and-retirement.md) | EP-257 | None | Not Started |
| EP-259 | Let tasks and pre-deploy hooks bind an app database under a named URL variable | [docs/plans/259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md](../plans/259-let-tasks-and-pre-deploy-hooks-bind-an-app-database-under-a-named-url-variable.md) | EP-257 M2 (for its M2 only) | None | Not Started |
| EP-260 | Confirm an app-owned database with Kotei's unchanged privilege script and release it | [docs/plans/260-confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it.md](../plans/260-confirm-an-app-owned-database-with-kotei-s-unchanged-privilege-script-and-release-it.md) | EP-257, EP-258, EP-259 | None | Not Started |


## Dependency Graph

EP-257 comes first. Its M1 proves the PostgreSQL rules the design rests on against a real server
before any Haskell changes; if a rule does not hold, the design changes there and this
MasterPlan is updated before other work starts.

EP-258 needs all of EP-257: the declaration, the owner user, and the reading of an app's roles
that the boundary checks finish in M3.

EP-259 M1 (tasks bind app databases; any binding may name its URL variable) needs nothing from
the other plans and may start at once. Its M2 (a task binds the owner credential of an app-owned
database) needs EP-257 M2, which is where the owner Secret and the `owner` role token exist in
an accepted scope.

EP-260 needs all three complete.

No release is cut between EP-257 and EP-260. An app-owned database declared from an unreleased
build is for local contexts only.


## Integration Points

- **The ownership declaration.** `AppDatabase.ownership` in
  `cli/nagare-dsl/src/Nagare/Dsl/AppDatabase.hs`, with values `NagareManaged` (the default, never
  written to JSON) and `AppOwned` carrying an optional `databaseOwner` role name. The owner user
  is `AppDatabaseRole`'s new `OwnerRole`, role token `owner`, user `<name>_owner`, Secret
  `<name>-owner`. Owned by EP-257. EP-258 and EP-259 read them and add no ownership fields.
- **Who binds the owner credential.** The existing `access.owners` list on the app database.
  EP-257 allows it on an app-owned database and restricts it there to tasks; EP-259 M2 makes a
  task named in it receive `<name>-owner`. No workload field requests a credential (ADR 31).
- **The app's roles.** One function, owned by EP-257 in
  `cli/nagarectl/src/Nagare/Database/AppDatabase/Catalog.hs`, reads the set of roles an app-owned
  database's owner administers, directly or through roles it created. EP-257's boundary checks,
  EP-258's backup role file and EP-258's quiesce and retirement all use that one reading. No
  second definition of "the app's roles" is written.
- **Quoting of app-chosen names.** Role names an app creates are not Nagare-validated
  identifiers, and `pgIdent` in `cli/nagarectl/src/Nagare/Database/AppDatabase/Sql.hs` does not
  escape. EP-257 adds the escaping identifier and literal renderers; EP-258 uses them for every
  statement built from the role file.
- **The backup credential.** EP-257 renders an app-owned database's backup schedule to dump as
  the server administrator from the first accepted review, so no app-owned database ever has a
  schedule that depends on app-managed grants. EP-258 changes what that Job writes (it adds the
  role file) and bumps the backup format token; it does not change the credential.
- **The task binding type.** `AppDatabaseBinding` in `cli/nagare-dsl`, owned by EP-259 and used
  by `Deployment`, `Worker` and `Task`.
- **`docs/user/managed-databases.md`.** Each plan writes the part of a new "App-owned
  databases" section that documents its own behavior; EP-260 reviews the section against AC-6.
- **Compatibility with several operators.**
  [MasterPlan 33](33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
  states the rules that work done now must follow so that
  [MasterPlan 24](24-operate-nagare-as-a-team-run-workplace-intranet-paas.md)'s multi-operator
  streams stay possible: authority is read from the accepted head; authorization checks are
  pure functions run when a review is prepared and at admission; approvals cover the review
  digest; each identity has its own credential; store writes go only through `ObjectOps`. Every
  child plan here follows them, and a change that would break one is recorded in this
  MasterPlan's Decision Log and MasterPlan 33's. Applied here:
  - Who receives the owner credential is decided by `access.owners` in the accepted app
    database scope, and ownership is read from that scope. No task, workload or command-line
    field can request it.
  - The new refusals (server below major version 18, a change of ownership, a long-running
    workload binding an app-owned database, a task not named in `owners`) need only the
    declaration and the accepted snapshot, and run both when a review is prepared and at
    admission. Drift found by observing the server is a separate, existing check.
  - The logins a quiesce or retirement closes are in the saved review. A rebuilt restore's
    review pins the backup object by its signed SHA-256, which covers the role file.
  - The owner credential belongs to an app database, not to a person. Backup, restore and drain
    use the server administrator, as restore and catalog commands already do. No credential
    shared between operators is added.
  - A delegated deployer (MasterPlan 33) may deploy a hook that binds the owner credential only
    because `owners` names that task, and `owners` is matched within the app database's
    namespace, which is also the bound of a delegation. The app database itself is declared by
    the operator; app databases are not a delegable scope kind.
  - Out of scope and left to MasterPlan 24's stream on team access to deployment material: the
    passwords of the logins an app creates are supplied by the operator as ordinary app
    Secrets.
- **Representative check.** EP-257 M1's fixture, a Kotei-shaped script run against PostgreSQL 18,
  is the early producer/consumer check for the whole initiative. EP-260 repeats it with the real
  script on a local context.


## Progress

EP-257 in progress: M1 proved every PostgreSQL rule the design rests on, on PostgreSQL 18, with no
design change. Cross-plan gate, checked in EP-260:

- [ ] On one local context, IR-43 AC-1 to AC-5 pass together with Kotei's script unchanged, an
  app database that did not opt in re-plans with no operations, and the release is running on
  the intranet.


## Surprises & Discoveries

- Kotei's script runs `ALTER DATABASE ... OWNER TO kotei_maintenance`, and PostgreSQL requires
  `CREATEDB` for that statement. IR-43 AC-2 forbids `CREATEDB`, so AC-1's verification ("runs
  unchanged") and AC-2 cannot both hold as the IR is written. Resolved by the first decision
  below. Evidence: lines 34 to 47 of the script, and the `ALTER DATABASE` reference page.
- `pg_dump` in custom format without `--create` does not carry database-level grants or
  `ALTER DATABASE ... SET`, and it never carries roles. AC-4's "grants match" therefore needs a
  role file beside the dump that also holds the database's own grants and settings (EP-258).


## Decision Log

- Decision: An app-owned declaration may name one owning role. Nagare creates it without login,
  makes it the database's owner, and gives the owner credential membership in it with the admin
  option. Rationale: it lets Kotei's script run unchanged (the role and the ownership it asks
  for already exist, so its guarded statements are skipped) without giving any app `CREATEDB`
  (operator, 2026-11-11). Date: 2026-11-11.
- Decision: An app-owned database's backup carries the SCRAM-SHA-256 verifiers of the logins the
  app created; Nagare's own users stay excluded. Rationale: those passwords are set by the app,
  not from a Nagare Secret, so without the verifiers a rebuilt-server restore returns logins
  that cannot connect. This amends ADR 30's "never roles or password hashes" for app-owned
  databases only (operator, 2026-11-11). Date: 2026-11-11.
- Decision: Backup, restore and drain of an app-owned database run as the server administrator.
  Rationale: the operator's requirement that backups and maintenance are not affected. The
  owner credential cannot be relied on to read everything once the app manages its own grants.
  Date: 2026-11-11.
- Decision: An app-owned database has one Nagare user, the owner. It has no runtime or migration
  user, and its long-running workloads use logins the app creates, supplied as ordinary app
  Secrets. Rationale: IR-43's stated model; two more users nobody uses would only be more to
  rotate and observe. Date: 2026-11-11.
- Decision: Ownership is chosen when the app database is created and planning refuses to change
  it afterwards. Rationale: changing it in place would have to re-own every object and drop or
  adopt users; a new app database and a data copy is the existing answer. Date: 2026-11-11.
- Decision: PostgreSQL only, and only on a server at major version 18 or later. Rationale: the
  rule that a `CREATEROLE` role administers only the roles it created exists from 16, 18 is
  Nagare's default, and no older version needs to be supported or tested (operator,
  2026-11-11). Date: 2026-11-11.
- Decision: Two apps on one server cannot both create a role of the same name; the second fails
  in its own SQL. Nagare documents this and does not rename or prefix. Rationale: roles are
  server-wide in PostgreSQL, and prefixing would mean changing the app's migrations. Date:
  2026-11-11.


## Outcomes & Retrospective

(To be filled at completion.)
