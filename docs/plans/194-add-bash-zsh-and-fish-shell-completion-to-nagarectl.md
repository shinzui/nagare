---
id: 194
slug: add-bash-zsh-and-fish-shell-completion-to-nagarectl
title: "Add Bash Zsh and Fish shell completion to nagarectl"
kind: exec-plan
created_at: 2026-10-14T15:07:52Z
intention: "intention_01m4xf7tn8e9h9ef5rsr2hkjqq"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-14T15:07:52Z
---

# Add Bash Zsh and Fish shell completion to nagarectl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Operators and app developers will be able to press Tab in Bash, Zsh, and Fish to complete `nagarectl` commands, nested subcommands, and option names. `nagarectl completions bash`, `nagarectl completions zsh`, and `nagarectl completions fish` will print installable scripts. Zsh and Fish will show descriptions from the CLI's existing help text. Completion will work on a fresh workstation without a target context, credentials, or a running cluster.

Follow the shell-completion recipe at `mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`: generated scripts ask the running executable for candidates from its actual parser. A new parser command therefore becomes completable without maintaining a second command catalogue. The shipped Nix packages will include the scripts, and the installation guide will explain activation and manual installation.


## Progress

- [ ] Milestone 1: `nagarectl completions bash|zsh|fish` emits usable scripts; parser completion returns top-level commands, nested commands, and flags without resolving a context.
- [ ] Milestone 2: automated checks exercise the real executable and generated scripts in Bash, Zsh, and Fish, including descriptions, cursor indices, and token preservation.
- [ ] Milestone 3: both Nix distributions carry completion scripts, their completion check passes, and documented installation and activation work outside the checkout.


## Surprises & Discoveries

(None yet.)


## Decision Log

Decision (2026-10-14): Use parser-derived completion, with the plain protocol for Bash and the enriched protocol for Zsh and Fish. Keep rendering and dispatch in executable-private CLI modules. This follows the requested recipe and avoids a manually maintained completion command tree.

Decision (2026-10-14): Complete parser-defined commands and option names in this change. Dynamic context, resource, app, and secret names would require additional data access and are outside this plan. Do not promise automatic path completion for every argument: the existing parsers need explicit file completers to supply path candidates, and Bash's `-o filenames` controls filename handling rather than providing fallback candidates by itself. Preserve the recipe's shell registration settings and test their actual behavior.

Decision (2026-10-14): Ship generated scripts in the existing Nix packages as well as exposing the generation command. This makes the feature available to the installed users described by the installation guide. Completion activation belongs to shell configuration; generation itself only writes stdout.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The executable is `nagarectl`, under `cli/nagarectl/`. `cli/nagarectl/app/Main.hs` sets UTF-8 encoding and calls `execParser opts >>= dispatch`. `cli/nagarectl/app/Nagare/Cli/Parser.hs` owns `opts :: ParserInfo (Maybe String, Command)` and `commandParser`. The optional first value selects a target context, meaning a named configuration for a Nagare installation. The second value is the typed command defined in `cli/nagarectl/app/Nagare/Cli/Options.hs`. `cli/nagarectl/app/Nagare/Cli/Dispatch.hs` routes commands to handlers. No completion generation subcommand currently exists.

A parser is the definition of accepted command-line syntax. `optparse-applicative` already intercepts its hidden completion flags before normal command dispatch. A completion query supplies the executable name and argument tokens through repeated `--bash-completion-word` options, plus a zero-based `--bash-completion-index` identifying the token being completed. Plain results are one candidate per line. Adding `--bash-completion-enriched` includes a tab followed by a help description when available. A completion script is shell code that converts the shell's cursor and tokens into this query and renders the returned candidates.

The dependency was located through Mori at `mori://pcapriotti/optparse-applicative/packages/optparse-applicative`. Its implementation is `src/Options/Applicative/BashCompletion.hs` and `src/Options/Applicative/Extra.hs` relative to `mori://pcapriotti/optparse-applicative/repos/optparse-applicative`. The local Cabal build plan resolves 0.19.0.0. On 2026-10-14, [Hackage's preferred versions](https://hackage.haskell.org/package/optparse-applicative/preferred.json) reported 0.19.0.0 as the latest normal version and the [upstream tags](https://github.com/pcapriotti/optparse-applicative/tags) included tag `0.19.0`. No dependency upgrade or compatibility workaround is needed. Before relying on a different API or changing bounds, rediscover the source with Mori and verify current registry and upstream releases.

The requested recipe resolves through `mori path mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`. It describes pure shell script generators and a typed `completions` command. Apply its architecture while correcting quoting and registration details where execution tests require it. In particular, a Zsh script must register its function before Tab invokes it; it must also be safe to load through the documented activation command without immediately running a completion outside a completion context.

[ADR 16](docs/adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) requires the shared Prelude, postpositive qualified imports, explicit exports, and executable-private parsing and command modules. `cli/nagarectl/app/README.md` documents those boundaries. Parsers stay pure, handlers do not import other handlers, `Main.hs` is limited to 30 lines, and dispatch is limited to 200. [ADR 3](docs/adr/0003-package-the-typed-config-runtime-with-nagarectl.md) says the installed CLI includes its typed-config runtime; preserve that wrapper while adding completion assets. [ADR 25](docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) supports deterministic local checks and the existing candidate gates. Shell processes with isolated state are sufficient for this feature; cluster or cloud execution adds no acceptance evidence. No existing ADR specifically decides shell completion. Distill any durable completion decision into the ADR corpus at implementation completion, following `agents/skills/exec-plan/ADR.md` and the repository's then-current ADR convention.

`cli/nagarectl/nagarectl.cabal` lists executable modules in `other-modules`; these modules are not part of the public library used by `cli/nagarectl/test/`. Use a public executable fixture for this feature rather than expanding the library API to expose CLI internals. `scripts/audit-managed-commands.py` requires every `Command` constructor to have a classification and visible dispatch. Its `--update-catalogue` option regenerates the registry in `docs/architecture/managed-resource-coverage.md`.

`nix/haskell-packages.nix` builds the checked executable, wraps it as `nagarectl`, and nests that in the operator package `nagare`. Both package environments link `/share`, so completion files added to the CLI package can be carried through to the operator package. `nix/checks/scripts.nix` defines executable fixtures; `nix/checks/haskell.nix` defines compilation and style checks. `docs/user/installation.md` is the reader-facing installation guide. `nix/source.nix` selects check sources, including new scripts under `scripts/`.


## Plan of Work

### Milestone 1 — Expose the generation command


Add `CompletionsCommand = CompletionsBash | CompletionsZsh | CompletionsFish` and `Completions CompletionsCommand` to `cli/nagarectl/app/Nagare/Cli/Options.hs`, exporting the new type. Add pure `completionsCmd :: ParserInfo Command` in `cli/nagarectl/app/Nagare/Cli/Parser/Completions.hs`; accept exactly the three shell names as nested subcommands with useful `progDesc` text and normal help. Register `command "completions" completionsCmd` in `commandParser`.

Add `cli/nagarectl/app/Nagare/Cli/Completions/Bash.hs`, `cli/nagarectl/app/Nagare/Cli/Completions/Zsh.hs`, and `cli/nagarectl/app/Nagare/Cli/Completions/Fish.hs`, each exporting a pure `Text` generator for the fixed program name `nagarectl`. Add `cli/nagarectl/app/Nagare/Cli/Commands/Completions.hs` exporting `runCompletions :: CompletionsCommand -> IO ()`; it selects the generator and writes its text once to stdout. Add the dispatch arm without resolving `mctx`, loading configuration, or calling provider processes. Keep `Main.hs` unchanged and register all new executable modules in Cabal. Classify `Command.Completions` as `read` in the audit and regenerate its catalogue; the shell constructors are pure rendering choices rather than managed-resource mutations.

Use the recipe's conversion algorithms with explicit preservation of tokens. Bash passes `COMP_CWORD` and quoted elements of `COMP_WORDS`, and fills `COMPREPLY` from plain lines. Zsh passes `CURRENT - 1`, reads `words` without splitting tokens on spaces, requests enriched output, separates each line at the first tab, and escapes colons before `_describe` receives a word/description pair. Handle lines without descriptions. Fish passes committed tokens from `commandline -cop` plus the current token from `commandline -ct`, preserving the empty token at a trailing space; the index is the number of committed tokens including the program. Preserve tab-separated descriptions in its output. All three call `nagarectl` on the caller's PATH and suppress callback diagnostics, so scripts remain portable between installations.

First prove one generated Bash script completes `nagarectl app ` through the actual binary before expanding shell variants. This exercises the complete path from shell tokens through the production parser. Milestone acceptance is successful generation for all shells, discoverable help, nested parser candidates, and a clean failure for an unsupported shell or missing shell argument.

### Milestone 2 — Verify shell behavior and isolation


Create `scripts/test-cli-completions.py`, accepting exactly one executable path. Use Python's standard library to invoke the binary and shells with argument arrays, captured stdout/stderr, bounded process timeouts, and temporary HOME, XDG_CONFIG_HOME, and XDG_STATE_HOME directories. Resolve the binary to an absolute path before changing the working directory. Give each shell a temporary PATH entry named `nagarectl` pointing to that binary. No third-party Python package is needed.

Check generation, help, and refusals; then query the hidden protocol for top-level `app`, `context`, `inventory`, and `completions`, nested `app` and `completions` commands, `--context`, and `app deploy --file`. Check prefix filtering (`ap` offers `app`; `completions f` offers `fish`) and enriched descriptions. Supply a nonexistent context via the global option and environment, use an unrelated working directory, and verify no context files or state appear. Completion of an effectful command's options must return candidates without invoking its handler. Fake provider executables may record and refuse invocations; their logs must stay empty.

Exercise emitted shell code rather than only checking its text. In Bash load the generated script, set `COMP_WORDS` and `COMP_CWORD`, invoke its function, and inspect `COMPREPLY`. In Fish source its generated script and call `complete -C 'nagarectl app '` and `complete -C 'nagarectl completions f'`. In Zsh initialize `compinit` without writing a persistent dump, source the script, verify registration, and call the registered function with controlled `words` and `CURRENT`; capture `_describe` arguments with a fixture function. This deterministically proves Zsh's callback conversion and descriptions without a terminal. Manually confirm its visible menu once as well.

For the shell conversion checks also place a recording fake `nagarectl` on PATH that returns tab-separated and plain candidates. Verify the received token array and cursor index for a token containing spaces, an empty current token, and completion in the middle of an argument list where supported by that shell. Verify Zsh handles a colon in a candidate and Fish preserves a multiword description. The fake checks token conversion; the real-binary cases separately prove parser integration. Require Bash, Zsh, and Fish when this test is run; missing shells are a failure, not a skipped success.

Add a `nagarectl-completions` derivation to `nix/checks/scripts.nix` with the packaged CLI, Python, Bash, Zsh, and Fish as inputs. It runs this fixture against the wrapped CLI in its sandbox and creates `$out` only after all assertions pass. The same fixture is runnable against a local Cabal binary. Acceptance is a passing executable fixture and passing architecture, audit, and style checks without relaxing their rules.

### Milestone 3 — Distribute and document activation


In the `nagarectl` wrapper's `postBuild` in `nix/haskell-packages.nix`, generate the three scripts after wrapping the executable. Create `$out/share/bash-completion/completions/nagarectl`, `$out/share/zsh/site-functions/_nagarectl`, and `$out/share/fish/vendor_completions.d/nagarectl.fish`. Use the new public commands as the generators and ensure the writable output directories exist. Scripts must reference the portable command name, never a contributor's binary path. Preserve wrapper environment settings and operator PATH precedence. Ensure both `nagarectl` and `nagare` carry these assets through their existing share links; extend the completion check to verify package assets match generated output for both packages and parse under their shells. Keep this verification inside the Nix check; do not search or traverse the Nix store to discover implementation sources.

Update `docs/user/installation.md` with the three generation commands, manual install paths, shell activation, and upgrade/removal guidance. Bash may source the generated script for the current session. Zsh must place its directory in `fpath` before `compinit`, or explicitly load and register the generated function after `compinit` for a current-session activation. Fish loads the generated file from its normal per-user completion directory. Explain that Nix supplies files under the standard share directories but actual discovery depends on the user's shell setup. State the command/option scope and that `nagarectl` must remain on PATH. Update `cli/nagarectl/app/README.md` to describe the new modules and fixture. Run the documentation bundle validation when changing user-facing metadata, following existing guide conventions. Acceptance is a green Nix completion check for both distributions plus a successful outside-checkout activation demonstration for each shell.


## Concrete Steps

Run implementation commands from the repository root. Enter `nix develop` if the contributor toolchain is not already loaded. These steps do not provision a target or change an existing shell startup file.

```bash
nix develop
cabal build exe:nagarectl --project-dir=cli/nagarectl --offline
completion_cli=$(cabal list-bin exe:nagarectl --project-dir=cli/nagarectl)
"$completion_cli" completions --help
"$completion_cli" completions bash
"$completion_cli" completions zsh
"$completion_cli" completions fish
"$completion_cli" --bash-completion-index 2 \
  --bash-completion-word nagarectl --bash-completion-word app \
  --bash-completion-word ''
```

Generation exits zero and emits only the chosen shell script. The help lists `bash`, `zsh`, and `fish`. The nested query includes `deploy` and `check`, among the current `app` subcommands; it does not deploy anything. Unsupported `completions powershell` and bare `completions` exit nonzero with useful usage information.

After wiring the new constructor, regenerate and validate the managed command catalogue. Use the established formatting tools for changed Haskell and Cabal files.

```bash
python3 scripts/audit-managed-commands.py --update-catalogue
bash scripts/test-managed-command-audit.sh
bash scripts/check-haskell-style.sh
python3 scripts/test-cli-completions.py "$completion_cli"
just user-documentation-validate
```

The audit reports no errors and its injected mutation is still refused. The completion fixture reports all three shells passed. If Fish is unavailable in the contributor shell, run the fixture in an explicit shell environment rather than treating it as skipped:

```bash
nix shell nixpkgs#bash nixpkgs#zsh nixpkgs#fish nixpkgs#python3 \
  -c python3 scripts/test-cli-completions.py "$completion_cli"
```

The authoritative automated result uses the repository's pinned Nix package set. Make new Nix source files visible to Git before building; stage only this plan's implementation files, preserving unrelated work. Run the named checks and packages from the repository root:

```bash
nix build .#nagarectl .#nagare --no-link --print-build-logs
nix build .#checks.aarch64-darwin.nagarectl-completions \
  .#checks.aarch64-darwin.managed-command-audit \
  .#checks.aarch64-darwin.haskell-style --no-link --print-build-logs
```

Use `x86_64-linux` instead of `aarch64-darwin` for the Linux builder. The completion check is new in Milestone 2; it will not resolve before that change. Build the checks on both release systems through the existing gate before implementation is accepted. Retain the existing CLI regression suite in the package check and run `just gate-fast` and `just gate` at the repository's required implementation boundary. This plan-creation task does not run implementation gates or claim they have passed.


## Validation and Acceptance

After installing the candidate, from a temporary directory outside the checkout run `nagarectl completions bash|zsh|fish` with fresh HOME and XDG directories. Each valid invocation succeeds with script-only stdout and empty stderr, including with `--context missing` and `NAGARE_CONTEXT=missing`. Unknown shell names and missing shell arguments fail without creating configuration or state. The hidden protocol emits candidates for effectful commands without provider calls. Existing commands and help remain unchanged except for the added completion entry.

The executable fixture must demonstrate root, nested, flag, and prefix completion against the real parser. An enriched root query must include a command and its existing `progDesc`, separated by a tab; an enriched option query must include the option's `help` text. Bash results contain words without appended descriptions. Zsh and Fish consume enriched lines and also accept undescribed words. Spaces inside a token survive the callback; trailing whitespace represents an empty current token; each shell supplies the correct zero-based index. No second command registry supplies candidates.

For an interactive demonstration after installation, start a fresh shell with the appropriate generated script loaded. In Bash, source a temporary generated file. In Zsh, run `autoload -Uz compinit; compinit -D`, then load the generated registration. In Fish, source a temporary generated file. In each shell type `nagarectl ap` then Tab, `nagarectl app ` then Tab, `nagarectl app deploy --fi` then Tab, and `nagarectl completions f` then Tab. Observe `app`, the app subcommand choices, `--file`, and `fish`; observe descriptions in Zsh and Fish. These observations must work without a selected context. Record concise actual evidence in Progress when each milestone passes.

The package acceptance check verifies all three standard share paths in both distributions, compares their contents with the candidate's generation commands, and exercises the scripts with that package's `nagarectl`. Documentation validation succeeds. Provider lookups for dynamic names, universal filename completion, completion for the separate `nagare` recipe launcher, and release publication are outside this plan.


## Idempotence and Recovery

Generation writes stdout only and can be repeated. Tests use temporary shell configuration and recording providers, leave real contexts and credentials alone, and clean their own temporary directories on exit. Nix package generation writes only into the derivation's output. Run a failed fixture again after correcting the source; never weaken a token-preservation assertion to accommodate a broken script.

Manual installation replaces only the user's explicitly chosen completion file. Keep an existing file before replacing it and restore it if activation fails. Do not edit startup files as part of automated validation. Removing a manually installed file and starting a fresh shell removes its activation; package removal removes the packaged assets. An installed shell function may persist until that shell exits. If rollback is needed during implementation, revert only this feature's changes and regenerate the managed command catalogue, preserving unrelated edits.


## Interfaces and Dependencies

This is a standalone plan with no parent milestone prerequisite. `optparse-applicative`, already used by the executable, owns candidate discovery and the plain/enriched protocols. The fixed executable name is `nagarectl`. The new public syntax is exactly `nagarectl completions bash`, `nagarectl completions zsh`, and `nagarectl completions fish`; normal `--help` remains available. No output-directory or automatic startup-file mutation flag is introduced.

The new modules expose `generateBashCompletion :: Text`, `generateZshCompletion :: Text`, `generateFishCompletion :: Text`, `completionsCmd :: ParserInfo Command`, and `runCompletions :: CompletionsCommand -> IO ()`. They remain executable-private and explicitly listed in `cli/nagarectl/nagarectl.cabal`. Parser modules depend only on pure option/type definitions. The completion handler depends on the generators, not other handlers or context runtime policy.

The completion fixture needs Python's standard library and installed Bash, Zsh, and Fish; the Nix check supplies pinned shell implementations. It must fail when an expected shell or completion is missing. Nix packaging reuses the existing checked CLI and its wrapper. No new Haskell dependency, cloud service, credentials, persistent state format, or inventory behavior is required.

Implementation commits use Conventional Commits and include both `ExecPlan: docs/plans/194-add-bash-zsh-and-fish-shell-completion-to-nagarectl.md` and `Intention: intention_01m4xf7tn8e9h9ef5rsr2hkjqq` trailers. Record implementation provenance with the bundled script when first making a substantive later edit to this plan; preserve the generated authorship metadata.
