# Release transition fixture: v0.4.0 (EP-172 M1)

The source side of the release transition from v0.4.0 to this payload, read by
`PlatformTransitionTableSpec`, which holds `Nagare.Platform.Transition.transitionTable` to what
it shows. `scripts/record-transition-fixture.sh` wrote it on 2026-10-11 from the EP-172 M3
rehearsal root (v0.4.0 `831243962c6b` to `37d8d45d`, local context `transition`) and the
v0.4.0 nagarectl built from tag `v0.4.0`.

- `payload/` is the published v0.4.0 payload's `cluster/bootstrap`, `cluster/observability`,
  `cluster/local` and `nixos` trees and its `release.json`. Each file was checked against the
  payload workspace the rehearsal ran from, whose digest `source.json` records.
  `payload.sha256` lists every file's digest, and the suite refuses an extract that differs.
- `store/head-initial.json` is the head v0.4.0 writes when it plans a fresh context.
- `store/head.json` is the rehearsal's final head (generation 2213). v0.4.0's
  `inventory export` and `inventory restore` rewrite it byte for byte, so these are the bytes
  v0.4.0 writes for it.
- `store/journal/` holds events v0.4.0 appended before the first transition review: the first
  ten, and the first of every other state and operation shape.
- `store/revisions.json` pairs each platform scope's last revision under v0.4.0 with the
  revision the rehearsal ended on. `store/scopes/` holds both files wherever the two differ.

Record it again only from a rehearsal whose source is v0.4.0. A different source release is a
new fixture directory.
