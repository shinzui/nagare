# EP-276 M6: the new lifecycle events on a disposable local context

Run on 2026-11-22 with the packaged `nagarectl` 0.26.0 of `6d75f57c` and then `577a6a1a` (the
admin API's feed mount), on Colima profile `nagare-ep276` (arm64, Rosetta), local context `ep276`,
bootstrapped by `scripts/site-access-drill.sh` with `NAGARE_DRILL_LIFECYCLE=1
NAGARE_DRILL_ADMIN_API=1 NAGARE_DRILL_BOOTSTRAP_ONLY=1`. The worker and the admin API ran this
tree's `nagare-admin-api` image (`nix build .#packages.x86_64-linux.release-image-admin-api`,
`sha256:469237da…08efc`); En, Shomei and nagare-access ran the release layouts. A webhook
subscription naming twelve types sent every event to the example receiver
(`cluster/examples/lifecycle-webhook-receiver/Receiver.hs`) on the workstation, which verified
each signature. [`feed.txt`](feed.txt) is the final feed (position, type, scope, a few data
members); [`cost.tsv`](cost.tsv) the timed applies. The profile and the drill root are deleted.

| Scenario | Published (feed, `GET /v1/events?type=…`, receiver) |
| --- | --- |
| A deploy of a new release | `app.deployed` and `change.applied` about `standalone:service-notes` |
| An env change | only `change.applied`, about the app's env channel `application:env-notes-runtime` |
| `app stop notes`, `app restart notes` | `app.stopped`, `app.restarted` (with its stamp), each beside `change.applied` |
| A release whose pod listens after 240 s (readiness waits 180 s) | `change.failed` (`ambiguous`, operation, resource, `next: resume-or-close`); a resume before it was ready journaled nothing and published nothing; the resume after it converged published `app.deployed` and `change.applied` |
| A release whose pod exits at once, then `inventory close` | `change.failed`, then `change.closed` with the scope `kept` and `attested: false` |
| `app delete gone --source-repository … --source-revision …` | `app.deleted` (2 members retained) and `change.applied` carrying the source |
| `db restore pg1 local-001` into a scratch database | `database.restored` (`backup`, `database`, `namespace`, `targetDatabase`, `targetKind: scratch`) and `change.applied` |
| pg1's last receipt re-uploaded with a changed HMAC | one `database.backup.failed` (`bad-signature`) |
| pg1's CronJob suspended after its 19:15 run, resumed at 20:15 | `fresh→deteriorating` at 19:45:29 (age 1826 s), `deteriorating→breached` at 20:15:29 (3626 s), `breached→fresh` at 20:20:30 after the 20:16 run |
| The worker restarted | no event (71 before and after) |
| A deploy rerun with nothing to change | one `change.applied` with no scope, about `platform:context` |

Cost, on the same context, base packaged CLI (`0b5ae0d8`) against the candidate, three applies
each: a deploy wrote 8 store objects with either; an env change wrote 4 with the base and 6 with
the candidate (the facts object and its convergence event). Median apply wall times: deploy
2.349 s base (spread 0.189 s), 2.147 s candidate; env change 0.577 s base (spread 0.095 s),
0.573 s candidate. Head reads, history loads and store opens were equal. The local store is a
directory, so the trace counts no object requests; the written objects were counted in it.

Found on the way and fixed, each with a test: the local admin API did not mount the lifecycle
feed, so `GET /v1/events` answered `events_not_enabled` while the worker published (`577a6a1a`);
the site-access drill encrypted its Grafana secret as sops binary data (`a7643244`).

`platform.upgraded` was confirmed by the 0.27.0 candidate's rehearsal (`5ebd6f05`,
`NAGARE_REHEARSAL_LIFECYCLE=1`): one event from `0.26.0` to `nagare-0.27.0-5ebd6f0528c3` after the
commit, beside the seeded row read back unchanged. Not covered here: `database.backup.accepted` (no
ingestion was reviewed) and a cloud context.
