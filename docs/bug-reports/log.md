# Bundle Update Log

## 2026-10-13
* **Update**: Mark BUG-5 and BUG-6 `fixed` in `unreleased` by commit `dff31cf5` (ExecPlan 189): the generated Nginx configuration issues relative redirects and serves text as UTF-8, proved by the `static-nginx-runtime` flake check.
* **Update**: Revalidate BUG-1 through BUG-4 against master `1532a447` and close them as `fixed` in 0.4.0 (ExecPlans 140 to 143). Plan BUG-5 and BUG-6 in `docs/plans/189-serve-static-sites-with-relative-redirects-and-a-utf-8-charset.md`.
* **Addition**: Record BUG-5 and BUG-6 from the protected runtime-docs deployment and an owning-repository reproduction of the released static Nginx golden configuration: directory redirects expose HTTP port 8080, and UTF-8 text is served without a charset. Retain the local container reproduction and HTTP results under `docs/audits/static-runtime-defaults-2026-10-13/`.

## 2026-09-15
* **Addition**: Create the Bug Report bundle on the `coordination.bugReports` profile from okf-profiles v0.15.0 and record BUG-1 through BUG-4 from the live 0.2.2 to 0.3.0 upgrade at `mori://tan/tan-ng-labs/docs/validate-the-labs-nagare-cluster-before-real-use`.
