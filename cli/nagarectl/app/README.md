# nagarectl executable boundaries

`Main.hs` sets process encoding and hands parsed arguments to `Nagare.Cli.Dispatch`.
The dispatcher only routes typed commands. These executable-private modules are
listed in the executable's `other-modules`; they do not expand the public library
API or change the inventory wire format.

| Responsibility | Location |
| --- | --- |
| Command and option values | `Nagare/Cli/Options.hs` |
| Pure option parsing and command help | `Nagare/Cli/Parser.hs` and `Parser/` |
| Public command workflows | `Nagare/Cli/Commands/` |
| Foundation, local, cloud, image, host and platform bootstrap stages | `Nagare/Cli/Bootstrap/` |
| Reviewed inventory workflows, adapter construction and source evidence | `Nagare/Cli/Inventory/` |
| Application configuration, input validation and CDN bindings | `Nagare/Cli/Application/` |
| Backup receipts, restore, pruning recovery and data lifecycle workflows | `Nagare/Cli/Data/` |
| Legacy platform upgrade and native saved-plan validation | `Nagare/Cli/Platform/` |
| Context, workspace, process, ownership and provider guards | `Nagare/Cli/Runtime/` |

Add a command's behavior to its domain handler. Handlers must not import other
handlers: move genuinely shared behavior to its specific application, data,
inventory or runtime owner. Avoid an all-purpose `Common` module for policy.
`Parser.Common` contains only reusable pure option fragments. All modules have
explicit exports; helpers used only by their owner remain private.

Planning and execution have separate factories in `Inventory/Planning.hs` and
`Inventory/Execution.hs`. Execution reconstructs the saved review and wires
callbacks; the existing library `Nagare.Inventory.Execute` remains the sole
apply/resume operation driver. Source-evidence and pruning checks retain their
original timing and exact identity requirements. Moving a check between factory
construction, preflight and recovery is a behavior change, not a routine refactor.

The deferred maintenance and scheduled-pruning *new-plan* helpers had no callers
and were removed. Their admitted-history recovery remains in the inventory
factory, evidence loaders and library adapters. Do not restore a new-admission
path merely because a recovery capability exists.

`scripts/check-cli-architecture.py` checks explicit exports, an acyclic import
graph, pure parser dependencies, handler isolation, Cabal registration and module
size. `Main` is limited to 30 lines, dispatch to 200, and other CLI modules to
1,000; crossing a limit requires separating responsibilities rather than raising
it to accommodate more policy. The check and its negative fixtures run through
the existing managed-command audit Nix check.

From the repository root, validate structure and command registration with:

```bash
bash scripts/test-managed-command-audit.sh
bash scripts/check-haskell-style.sh
```

Build and run the existing library regression suite from `cli/nagarectl`:

```bash
cabal build exe:nagarectl --offline
cabal test nagarectl-test --offline --test-show-details=failures
```

For a command refactor, preserve the baseline executable before changing it and
compare help and parser refusals with `scripts/test-cli-refactor-parity.py
BASELINE CANDIDATE`. Then run the public command fixtures appropriate to the
changed workflow. Bootstrap, access, operation-driver and entrypoint-guard
fixtures exercise the actual executable with isolated state and bounded fake
providers; they do not require a cloud deployment.

Bootstrap fixtures bind the source workspace, including `scripts/`, into their
payload digest. Finish edits before starting them and keep those inputs fixed
until they exit. Editing a script mid-run changes the workspace identity and
correctly makes a later replay refuse; it does not provide a valid regression
result. Run the bootstrap fixtures sequentially because they share a temporary
controller-archive location in the checkout.
