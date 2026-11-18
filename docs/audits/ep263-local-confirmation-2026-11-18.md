# EP-263: site deploy contract documents, confirmed on a local context

Date: 2026-11-18. One disposable local context (`mode=local`, context `ep235`, the warm root
`releases/x86-work/ep235-drill6` on the Colima profile `nagare-c4-amd64`) confirms
[ExecPlan 263](../plans/263-print-versioned-preview-and-saved-review-documents-from-site-deploy.md) M4 and
[IR-45](../improvement-requests/expose-versioned-json-for-site-deployment-previews-and-saved-reviews.md).
The script, its validator and the transcripts are in
[`ep263-local-confirmation-2026-11-18/`](ep263-local-confirmation-2026-11-18/); home paths are shortened to `~`.

Verdict: every check passed at `db88471ed368ff104adb17fbbe0e65bb10249bf1` (green fast gate), with that
revision's packaged `nagarectl` 0.23.0 (`/nix/store/sizfb09kk4qq5w5wmjw0kpba9qihn39j-nagarectl-0.23.0`), in run
`r5` of [`confirm.sh`](ep263-local-confirmation-2026-11-18/scripts/confirm.sh)
([run.log](ep263-local-confirmation-2026-11-18/evidence/run.log),
[evidence.tsv](ep263-local-confirmation-2026-11-18/evidence/evidence.tsv)).

## Arrangement

The operator accepted the delegation `ci`: namespace `team-a`, hostnames ending `-docs`, kind `static-site`,
images under `k3d-registry.localhost:5000/tan-nb-exp/nagare/team-a`. The deployer is the same context run with
`NAGARE_DEPLOYER=ci`, against the context's own local file store; the MP-33 confirmation's separate deployer home
only changes where the store credentials come from, and the delegation is enforced at planning and admission either
way. The site is the MP-33 fixture `docs` (protected static site), rendered with its real program after its build
was changed to `sh -c '… exit 97'`. The deployer's checkout then held a `Config.hs` whose `main` is `error …`.
Every stdout document was validated against `docs/api/openapi.json` with `jsonschema` (Draft 2020-12).

## Results

| IR-45 | Observed | Evidence |
|-------|----------|----------|
| AC-3 | The rendered document's build is `BuildCommand "sh -c '… exit 97'"`; the deployer refuses `site deploy -f` with "a deployer context never runs a config program" | [docs.rendered.json](ep263-local-confirmation-2026-11-18/evidence/docs.rendered.json), [program-refusal.log](ep263-local-confirmation-2026-11-18/evidence/program-refusal.log) |
| AC-1 | `site deploy --rendered … --dry-run --contract 1` printed one valid `deploy-preview`: `application.scope` `standalone:site-docs`, `configDigest` `61f979ad…`, overrides `tag` `d1` and `imageResource`, `hooks` empty | [preview.json](ep263-local-confirmation-2026-11-18/evidence/preview.json) |
| AC-2 | `--save-plan DIR --contract 1` printed one valid `saved-review` whose `scopes` are `["standalone:site-docs"]` and whose `directory` is the absolute review path | [saved.json](ep263-local-confirmation-2026-11-18/evidence/saved.json) |
| AC-2 | `inventory apply DIRECTORY --yes --contract 1` on the decoded directory printed a valid `transaction-outcome`, `converged`; the accepted revision of `standalone:site-docs` is that review's scope document, with the preview's `configDigest` and inputs plus `delegation.deployer: ci`; `ksvc/docs` is Ready on the published image | [outcome.json](ep263-local-confirmation-2026-11-18/evidence/outcome.json), [accepted-scope.json](ep263-local-confirmation-2026-11-18/evidence/accepted-scope.json) |
| AC-3 | `inventory history --contract 1` names the transaction's actor `{"kind":"deployer","name":"ci"}` and its source repository, revision `5ca1ab1e` and run | [history.json](ep263-local-confirmation-2026-11-18/evidence/history.json) |
| AC-3, AC-4 | The fixture `rogue` (hostname `rogue.127-0-0-1.sslip.io`) under `--save-plan --contract 1` printed one valid `refused` outcome, code `admission_refused`, detail `delegation-bounds … (hostname)`, exit 2; the last transaction and every accepted scope revision were unchanged and no review was saved | [rogue-outcome.json](ep263-local-confirmation-2026-11-18/evidence/rogue-outcome.json) |
| AC-4 | `site deploy --dry-run` without `--contract` printed the canonical scope (`scope`, `bundles`, `configDigest`, `overrides`, `version`), not a contract document | [plain.json](ep263-local-confirmation-2026-11-18/evidence/plain.json) |

## Findings, not fixed here

- The first run's image publication reached the registry forward while it was down (the `registry-forward`
  container had stopped with the VM) and ended `ambiguous`. Its reviewed exit, `inventory resume`, converged it
  once the forward answered ([r1-image.log](ep263-local-confirmation-2026-11-18/evidence/r1-image.log),
  [r1-resume.log](ep263-local-confirmation-2026-11-18/evidence/r1-resume.log)). Three earlier resumes, run from a
  shell whose first `bash` was macOS's 3.2, each answered "artifact transport returned success but the
  publication is absent" without copying anything: under bash 3.2 the transport exits 0 without publishing, which
  leaves the transaction ambiguous rather than failed.
- `inventory store status` answers "uses unsupported head schema 2; use a newer operator payload" on this store,
  whose head every planning and apply command reads. The check in
  `cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Store.hs` accepts schema 1 only.
