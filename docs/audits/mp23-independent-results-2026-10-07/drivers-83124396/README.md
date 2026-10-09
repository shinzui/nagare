# Native drivers for the final candidate `83124396` (frozen record, not maintained)

These are the exact shell drivers nagare-verify used for the final MP-23 candidate `83124396` on
2026-10-09. They were copied on 2026-10-09 from session scratch space under `/private/tmp` (which
macOS purges after about three days) and from the `mp23-c3m` operator root. Keys, age files and
credentials in that root were not copied. The passwords that appear in them belong to disposable
drill containers.

They are a reference for exact commands and ordering only. Do not build on them:
[ADR 24](../../../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)
freezes shell-and-Python harness code. [EP-168](../../../plans/168-script-the-local-acceptance-run-as-one-command.md)
ports `c2/` stage for stage into `nagare-harness local-acceptance`, and
[EP-167](../../../plans/167-prove-a-full-gcp-and-local-context-tears-down-to-zero-through-reviews.md)
replaces `disposal/` with reviewed teardown.

| Directory | Run | Result |
|---|---|---|
| `c2/` | C2 on cp3: `setup.sh`, then `chain.sh` (phase1, C1, phase2, phase2b, rebind-check, restores, misc, su, final-a, retire-kept, final-b, assemble) | [16/16](../c2-acceptance-83124396/) |
| `c3/` | C3 on `mp23-c3m`: `bootstrap-loop.sh`, `c3-chain.sh` (`c3-chain-from-*.sh` resume at a stage); the checklist drills `s2-drill.sh`, `s3-drill.sh`/`s3-run.sh`, `s4-drill.sh`/`s4-run.sh`, `su-drill.sh`; `runbook-exec.sh` | [17/17](../c3-acceptance-83124396/), [section 3](../section3-83124396/) |
| `c4/` | Clone-free C4 on x86_64-linux | [11/11](../c4-83124396/) |
| `disposal/` | Exact-name disposal of `mp23-c3m` from its stack export (`dispose-gen.py` generates the delete list) | [disposals](../context-disposals/) |

The C2 set is the one that passed on `3b59bcb7`, re-pointed at `83124396`. The C3 set descends from
the `mp23-c3j` set. Both C1 refusals recorded in the C2 README were scheduling on the verifier's side,
not driver defects.
