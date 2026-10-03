# GCS authentication failure and retained replay proof

Date: 2026-09-29. This checkpoint fixes a reproduced refresh amplification bug
and establishes complete read-only replay of the retained 61-event GCS history.
It does not close MP-23's native mutation, 500-event real-GCS, or release gates.

## Authentication failure

The [before-fix regression](mp23-auth-replay-results-2026-09-29/refresh-before.txt)
forced token expiry and failed refresh with 16 concurrent callers. It observed
17 helper calls: one acquisition and 16 failed refreshes, rather than two total.
Throwing inside `modifyMVar` restored the expired snapshot after every failure.

`GcloudAuth` now commits a failed cache state before throwing a redacted error.
Both an unsuccessful helper result and an IO exception invalidate the session;
waiting and later callers refuse without reacquiring or returning the old token,
even after clock rollback. A new command can acquire credentials again. Successful
refresh still pins identity and is shared by concurrent requests.

Actual SDK HTTP tests add provider 401 cases: a rejected read never establishes
absence; a rejected write receives one readback but no write retry; and a landed
write followed by revoked read access remains unknown until later reconciliation.
The [test result](mp23-auth-replay-results-2026-09-29/tests.txt) records all 975
passing tests, including these cases and the existing successful expiry test.

The [public CLI timeout experiment](mp23-auth-replay-results-2026-09-29/timeout.json)
substitutes a credential helper that emits synthetic private output and sleeps
for 60 seconds. The command refused in 18.092 seconds, the child was reaped, and
its output was absent from stdout/stderr. The helper timeout is 15 seconds;
process startup and cleanup contribute to the complete measured command time.
No real credentials or network were used in this experiment.

These tests do not establish live impersonation or a real Google token expiring
during a command. The internal gcloud helper interface and short-lived private
token-file bridge remain documented compatibility constraints. Forced process
death during the token-file window is not a proved cleanup path. Provider 401s
refuse; they do not transparently refresh and retry writes.

## Complete retained replay

The [real GCS results](mp23-auth-replay-results-2026-09-29/replay.json) use the
original converged host transaction, not a synthetic replacement. Each round
starts from a new local config/state/cache root containing only the context
profile; no journal or cache is copied. Both the cold and warm commands execute
the public `inventory resume <original-transaction> --yes` path.

| Round | Cold, limit 30 s | Warm, limit 5 s |
| --- | ---: | ---: |
| 1 | 7.397 s | 3.905 s |
| 2 | 4.345 s | 4.256 s |
| 3 | 4.320 s | 4.708 s |

All six commands converge. The head is checked inactive before starting and its
provider generation remains `1790656456769847`, size 1773 bytes, before and after
every command. Native executors are blocked and none is invoked. An initial
recorder also blocked gcloud's local `ssh -V` capability check; one isolated
storage metadata probe identified that exact call. The final recorder permits
only that local version check and still refuses SSH connections. No global
gcloud/kubectl context or real cloud resource changed.

This replaces the historical 41.04-second warm replay failure for this retained
fixture with measured complete-command evidence. It does not establish the
500-event real-GCS gate, active append latency, or native effect recovery.

## Reproduction and candidate

From `cli/nagarectl`:

```bash
cabal build exe:nagarectl test:nagarectl-test --enable-tests
cabal test nagarectl-test --enable-tests --test-show-details=direct
```

From the repository root:

```bash
python3 scripts/test-inventory-auth-timeout.py
python3 scripts/test-inventory-sdk-retained-replay.py
nix build .#nagarectl --no-link --json -L
```

The replay script intentionally refuses a changed retained provider generation
or sequence; diagnose fixture changes before modifying its pins. Results bind
the Cabal binary SHA-256 and [source hashes](mp23-auth-replay-results-2026-09-29/source-hashes.json).
The [full Nix package build](mp23-auth-replay-results-2026-09-29/nix-build.json)
passes on `aarch64-darwin`, including the pinned Gogol dependencies. This is a
working-tree build; the [installed wrapper launch](mp23-auth-replay-results-2026-09-29/installed-version.json)
also passes and reports version `0.4.0`. Final committed-candidate and native Linux
release checks remain separate gates.
