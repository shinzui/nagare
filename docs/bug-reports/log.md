# Bundle Update Log

## 2026-10-28
* **Update**: Mark BUG-9 `fixed` in `unreleased` by commit `1db2be79`: a completed migration Job that a scope replacement no longer declares is retained without a lifecycle decision, and any other removed member still needs one.
* **Addition**: Record BUG-9 from `mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option` on the 0.11.0 candidate: a new Shomei image pin renames the auth migration Job, so the accepted `shomei-migrate-<old>` member drops out of the desired scope and every platform plan refuses with `retirement-required`, stopping the intranet transition after the host activation.

## 2026-10-22
* **Update**: Plan BUG-8 in `docs/masterplans/29-make-a-reviewed-change-cost-seconds-by-opening-the-inventory-once-and-reading-it-concurrently.md` (ExecPlans 212 to 215). The review corrected the diagnosis: the digest cache already makes warm scope reads local; the cost is one store open per phase, one head read per consumer, one whole-prefix listing per plan, one port-forward and cluster guard per En call, and two round trips per cold read.
* **Addition**: Record BUG-8 from the `mori://tan/tan-ng-labs` intranet on 0.9.0: one reviewed team membership or site grant takes about 100 seconds because `loadInventoryHistory` reads every accepted scope with sequential GCS GETs, twice per plan and again during apply, and every access relationship adds another scope.

## 2026-10-20
* **Update**: BUG-7 is `fixed` in 0.9.0: the intranet's labs-clickhouse took the setting, its quiesced app databases resumed, and a reviewed restart left the migration grants write-only with both configs re-planning to no operations.
* **Update**: Mark BUG-7 `fixed` in `unreleased` by commit `9e6ace41` (ExecPlan 209): ClickHouse servers turn on `enable_read_write_grants`, and the reloaded `READ ON FILE` on a migration user is revoked by the next plan instead of refused as drift.
* **Addition**: Record BUG-7 from `mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps` on 0.8.0: ClickHouse 26.8 persists an app database migration user's `WRITE ON FILE` as `FILE ON *.*`, so after a server restart the catalog sees an undeclared server-wide `READ` and refuses resume, plan, rotate and retire for every ClickHouse app database.

## 2026-10-13
* **Update**: Mark BUG-5 and BUG-6 `fixed` in `unreleased` by commit `dff31cf5` (ExecPlan 189): the generated Nginx configuration issues relative redirects and serves text as UTF-8, proved by the `static-nginx-runtime` flake check.
* **Update**: Revalidate BUG-1 through BUG-4 against master `1532a447` and close them as `fixed` in 0.4.0 (ExecPlans 140 to 143). Plan BUG-5 and BUG-6 in `docs/plans/189-serve-static-sites-with-relative-redirects-and-a-utf-8-charset.md`.
* **Addition**: Record BUG-5 and BUG-6 from the protected runtime-docs deployment and an owning-repository reproduction of the released static Nginx golden configuration: directory redirects expose HTTP port 8080, and UTF-8 text is served without a charset. Retain the local container reproduction and HTTP results under `docs/audits/static-runtime-defaults-2026-10-13/`.

## 2026-09-15
* **Addition**: Create the Bug Report bundle on the `coordination.bugReports` profile from okf-profiles v0.15.0 and record BUG-1 through BUG-4 from the live 0.2.2 to 0.3.0 upgrade at `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.
