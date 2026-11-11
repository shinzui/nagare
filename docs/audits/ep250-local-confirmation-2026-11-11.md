# EP-250: the local confirmation of delegation-wide access

Date: 2026-11-11. One disposable local context (`mode=local`, context `ep248`) confirms EP-250 D6. Scripts and
transcripts are in [`ep250-local-confirmation-2026-11-11/`](ep250-local-confirmation-2026-11-11/), with home
paths shortened to `~`. The D1 prototype is in [`ep250-prototype-2026-11-11/`](ep250-prototype-2026-11-11/).

Verdict: every phase passed at `88190b0b958e7c6148e69117c3a130d04a737758`, which had a green fast gate. The
cluster was freshly bootstrapped from that revision's packaged `nagarectl`. Its auth plane ran this revision's
enforcer (`nagare-access`, built for arm64 from the tree) beside the unchanged En and Shōmei images. The deployer
Pod ran the same revision's `aarch64-linux` package with only its bundle, as in
[EP-248's confirmation](ep248-local-confirmation-2026-11-11.md).

## Phases

[`run.sh`](ep250-local-confirmation-2026-11-11/scripts/run.sh) bootstraps with the images tagged `ep250`, runs
EP-248's P1 to P4, then [`p8.sh`](ep250-local-confirmation-2026-11-11/scripts/p8.sh). P1 to P4 move the store to
MinIO, apply delegation `ci` for `team-a` with team `engineering`, issue the bundle, and have the deployer Pod
deploy the protected site `docs` and app `hello` into `team-a`.

## Results

| Deliverable | Observed | Transcript |
|-------------|----------|------------|
| D3 | `nagare-access-backends` gives both deployed hosts the object form `{"upstream", "role": "protected", "delegation": "ci"}`. The deployer wrote it with its own credentials, so the deployer's bounds and RBAC admitted the delegated entry. | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |
| D2, D5 | The grant planned, which the runtime refuses unless the active En schema declares `object delegation`. A member was added to `engineering` (`access team add-member`), and `access grant --delegation ci --team engineering --save-plan` then `inventory apply` converged. | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |
| D4, D6 | `docs.team-a.127-0-0-1.sslip.io`, which has no grant of its own: an anonymous request got `302` (sent to sign in), the member's session got `200` with the site's page, and a signed-in outsider got `403`. | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |
| D5 | `access check --json` for the member answers `allowed` with `inheritedFrom: {"delegation": "ci"}`, and for the outsider `denied`. `access list --host` lists `engineering` under "teams inherited through delegation ci". | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |
| D6 (revocation) | After `access revoke --delegation ci --team engineering` was applied, the member's session got `403` within 26 seconds, inside the 30-second decision cache TTL. | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |
| D6 (direct grants) | `access grant --host … --user OUTSIDER` admitted the outsider (`200`) beside the inherited grant. | [p8](ep250-local-confirmation-2026-11-11/evidence/p8.log) |

## Found while preparing the run

- Changing `cluster/bootstrap/en/configmap.yaml` needs its pinned digest in `Nagare.Inventory.Components.Auth`
  updated. The fast gate's auth and transition tests refused the stale pin; fixed in the EP-250 commit.
- `access list` reads En directly and needs `--en-url` through a forward, as before EP-250. The run opens one.
