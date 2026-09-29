# MP-23 active transaction and host recovery checkpoint

This checkpoint measures complete claim/append/finalization and repairs two
host failures reproduced locally. It preserves the accepted
[GCS replay measurements](mp23-gcs-scale-proof.md). It is not native GCP
convergence or independent closure of the findings tracker.

## Active transaction evidence

`scripts/test-inventory-active-command-cost.py` previously stopped at an
ambiguous operation without appending anything. Its new `MP23_COMPLETE=1` mode
runs the actual CLI against the conditional loopback GCS server, reporting the
already-created prune Job complete. Native mutations remain forbidden. All
twelve combinations of 50/500 journal events, 0/50/500 unrelated reviews, and
cold/warm local caches converge the **original** transaction in 1.397–2.202
seconds. Every case has three initialization processes and 24 Kubernetes
observation processes, independent of history size. These are local fixture
times, not cloud latency.

Each completion appends four events: recovered operation completion, the next
operation's intent and verified completion, then transaction convergence. The
harness validates each sequence, transaction and previous digest; accepted and
converged revisions match; active transaction and executor claim are cleared;
all pre-existing immutable objects are byte/generation-identical.

Four further cold/warm cases at both sizes return HTTP 500 **after every write
has landed**. Exact read-back resolves the lost acknowledgements and the
original transaction still converges, without duplicate events or native
effects. Two claim-race cases instead refuse before provider observation and
preserve the original logical head. Their reports explicitly distinguish
refusal from convergence.

`GcsActiveTiming.hs` wraps the production `ObjectOps` interface with timings and
runs production `Execute.resumeTransaction` over real GCS. The Kubernetes
adapter and review are real; its eight provider observations are synthetic and
its mutation callback fails immediately. Building the observer from the local
fixture happens before the timed interval. This isolates store/driver cost; it
does **not** measure public CLI registry construction, real kubectl, IAP or VM
activation. One fresh-cache sample at each size gives:

| Measured boundary | 50 events | 500 events |
|---|---:|---:|
| Auth and ownership setup | 2.920 s | 3.173 s |
| Store opening | 0.232 s | 0.345 s |
| Complete transaction driver | 5.911 s | 11.063 s |
| Setup + opening + driver | **9.063 s** | **14.582 s** |
| Journal replay, inside driver | 0.937 s | 6.893 s |
| Claim acquisition conditional write | 0.092 s | 0.086 s |
| Four journal publications, total | 0.340 s | 0.340 s |
| Four conditional head advances, total | 0.565 s | 0.474 s |
| Finalization conditional write | 0.102 s | 0.196 s |

The write rows exclude the authority/previous-event reads required around each
write. The raw trace includes those reads and one final verification read after
the measured driver interval. Each size performs one journal batch, four tail
reads, four journal writes and six head writes. No additional dependency or
weaker publication protocol is justified by these measurements. Replay is the
main cost that grows with history, consistent with the earlier scaling proof.

Cloud setup uses create-only objects in two unique `mp23-active-bench` prefixes
of the existing disposable state bucket. The driver has a 90-second diagnostic
deadline; every completed conditional write records its returned generation
immediately for cleanup. All **598 recorded object generations** were removed
by exact version URL; both prefixes were verified empty. Retained inventory
head generation `1790656456769847` is unchanged. No real native executor ran,
and no global GCP or Kubernetes context changed.

## Fresh-login repair (F05)

The existing test checked that the argv *contained* `ControlMaster=no` and
`ControlPath=none`. It missed precedence: `nagare-safe-switch-client.sh` put
`NIX_SSHOPTS` first, and OpenSSH takes the first value for each option.

`scripts/test-host-fresh-login.py` starts a real unprivileged loopback sshd and
authenticated control master using temporary keys. It revokes the key while
leaving the master alive. A control request still succeeds through that master,
whereas a new connection fails. Before the repair, production safe-switch
returned success and committed after revocation. After placing mandatory fresh
options before `NIX_SSHOPTS`, it returns 4 and never commits. The same fixture
also verifies that both inventory transport fresh-login paths reject revocation
and succeed after restoring authorization. The server's temporary configuration
disables source penalties so repeated negative tests do not obscure successful
re-authentication. It changes no system SSH configuration.

## Interrupted key activation repair (F07)

`scripts/test-host-key-recovery.py` runs the production helper body extracted
from `nixos/modules/nagare-host.nix` with the production transport `activate`
and `emit_state` functions. Only privileged ownership/uid, systemd, IAP and SSH
boundaries are simulated. File contents, SHA-256, mode, inode/mtime, shell exit
propagation and JSON output are exercised directly.

In separate cases, sops restart or Tailscale activation fails **after** the key
has been persisted and verified. Retrying the identical activation request
resumes services with the same key inode, mtime and contents: one key write,
two deliveries. A subsequent ready-host retry performs only fresh verification;
a different installed key refuses before delivery or activation.

This stronger fixture exposed a second defect: successful key installation
printed a diagnostic to stdout before the transport JSON. `HostRuntime` decodes
all stdout as a single JSON value, so success became an ambiguous response. The
transport now sends the helper's diagnostic to stderr. The test parses the
entire successful stdout as JSON and checks the diagnostic remains on stderr.
This fixture does not run real Linux systemd/sops or resume a saved host
transaction through the public CLI; those remain native acceptance boundaries.

## Validation and reproduction

The 38 focused Haskell host tests, existing transport regression, host-switch
identity regression, real SSH fixture and key-recovery fixture pass. The new
`checks.aarch64-darwin.host-transport-recovery` Nix check also builds successfully,
registering the helper/transport regression for platform checks. The previously
passing 977-test SDK candidate is unchanged in Haskell production code; this
checkpoint does not claim a new full platform-package or Linux VM test.

Run the host checks from the repository root:

```bash
python3 scripts/test-host-fresh-login.py
python3 scripts/test-host-key-recovery.py
bash scripts/test-inventory-host-transport.sh
bash nix/checks/scripts/test-host-switch-identity.sh
nix build .#checks.aarch64-darwin.host-transport-recovery --no-link
```

Generate the local saved review with
`python3 docs/audits/mp23-reproductions/run-operational-cost.py prune-fixture`.
Use its printed artifact root plus `/fixture-prune-fixture` below:

```bash
MP23_SDK=1 MP23_COMPLETE=1 python3 scripts/test-inventory-active-command-cost.py <local-fixture>
MP23_SDK=1 MP23_COMPLETE=1 MP23_LOST_ACK=1 python3 scripts/test-inventory-active-command-cost.py <local-fixture>
MP23_SDK=1 MP23_COMPLETE=1 MP23_CLAIM_RACE=acquire python3 scripts/test-inventory-active-command-cost.py <local-fixture>
```

The runner requires the CLI and test target up to date with `--enable-tests`.
Compile the isolated production-driver probe from `cli/nagarectl`:

```bash
cabal exec -- ghc -threaded -package nagarectl -package nagare-dsl \
  -outputdir /tmp/mp23-gcs-active-build -o /tmp/mp23-gcs-active-timing \
  ../../docs/audits/mp23-reproductions/GcsActiveTiming.hs
```

Run `scripts/test-inventory-gcs-active-cost.py <local-fixture>
/tmp/mp23-gcs-active-timing` for loopback validation. For an intentional repeat
of the cloud checkpoint, generate a separate fixture with
`MP23_PRUNE_PROJECT=tan-ng-labs` and pass that fixture plus `--cloud`. This
creates and deletes disposable inventory objects; it is not necessary to
repeat unchanged accepted measurements before continuing.

Durable [results](mp23-active-host-results-2026-09-29/) retain cloud operation
traces and generations, public CLI summaries with HTTP counts, failure/success
transcripts, binary hashes and source hashes. F05/F07 remain Verifying pending
independent review; F06 remains Partial for the complete public active cloud
command with real provider timing. The next acceptance step is to reconcile
these fixes with the saved host transaction/native fixture, including readiness
and package checks, rather than re-running the already accepted no-op benchmarks
or claiming that synthetic provider observations establish cloud convergence.
