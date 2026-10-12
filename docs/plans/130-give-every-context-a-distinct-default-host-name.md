---
id: 130
slug: give-every-context-a-distinct-default-host-name
title: "Give every context a distinct default host name"
kind: exec-plan
created_at: 2026-09-14T02:03:09Z
intention: "intention_01m2etae2sekzbr1mthbv4wxpr"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T02:03:09Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T02:53:19Z
      mode: "implement"
      note: "Implemented and validated Milestone 1 host-name derivation"
---

# Give every context a distinct default host name

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [130-give-every-context-a-distinct-default-host-name.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/130-give-every-context-a-distinct-default-host-name.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Before this plan, Nagare gave every generated cloud host the context's GCE instance name, which defaults
to `nagare-01`. When two contexts join the same Tailscale private network (a "tailnet"), both nodes
request the same name. Tailscale renames one of them, and an operator can no longer tell which
cluster `ssh deploy@nagare-01` or a Kubernetes API connection over that name will reach. The defect
and its acceptance criteria are recorded in
[IR-14](../improvement-requests/default-host-name-collides-across-clusters.md).

After this plan, `nagarectl host init --context prod` defaults the NixOS and Tailscale host name to
`prod-nagare`, while the same command for `labs` defaults it to `labs-nagare`. The GCE instance may
remain `nagare-01`; the command and documentation clearly distinguish the tailnet host name from
the project-scoped instance name. Before accepting an implicit default, `host init` also checks the
other generated host flakes under the Nagare configuration directory and refuses if one already
contains that host name. An explicit `--host-name` remains the escape hatch for a context name that
cannot become a valid NixOS host name or for an operator who wants a different stable name.

The observable result is a dry-run transcript in which two contexts with the same instance name
render different `hostName` values, plus a collision scenario that exits non-zero and names the
context already owning the proposed host name. The multi-cluster and host-access guides then show
`ssh deploy@prod-nagare` for Tailscale while retaining `nagare-01` for GCE/IAP commands.

## Progress

- [x] (2026-09-14 02:53Z) Milestone 1: added and unit-tested the deterministic, validated
  `<context>-nagare` default policy in `Nagare.Host.Config`, routed `nagarectl host init` through
  it, updated CLI help, and passed all 471 `nagarectl-test` tests.
- [x] (2026-09-14 03:02Z) Milestone 2: added deterministic sibling-flake collision discovery,
  current-context exclusion, symlink and unreadable-file coverage, and installed-command proof of
  refusal plus explicit recovery. All 472 Haskell tests and both `nagare-clone-free-platform` and
  `host-module-options-agree` passed.
- [x] (2026-09-14 03:06Z) Milestone 3: updated both operator guides, CHANGELOG, and ADR 5; passed
  user-documentation validation, Haskell style, all 472 Haskell tests, both focused Nix checks, and
  the full native flake check; then completed IR-14 and validated all 21 improvement requests.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The improvement-request bundle contains 21 concepts, not the 16 predicted when this plan was
  drafted. IR-17 through IR-21 were added on the same date before implementation began. Evidence:
  the final profile/log enforcement reported `OK: 21 concepts (okf_version 0.2)`.

- On this `aarch64-darwin` workstation, `nix flake check --print-build-logs` passed every buildable
  native check and warned that it omitted incompatible `x86_64-linux` outputs. This is Nix's normal
  host-system behavior rather than a failed gate; the native run included `nagarectl-build-test`,
  `nagare-clone-free-platform`, `host-module-options-agree`, `shellcheck-scripts`, documentation-
  independent packaging checks, and the remaining repository checks.

- The repository style gate requires `import Data.Generics.Labels ()` in every Haskell module that
  uses an overloaded record label. Adding `#name` assertions to `HostSpec` exposed that requirement;
  after the explicit import, `scripts/check-haskell-style.sh` passed.

## Decision Log

- Decision: The ordinary default is `<context>-nagare`, and it is available only when the context
  text is already a lowercase DNS label and the final value is at most 63 characters. Uppercase
  letters, underscores, dots, leading or trailing hyphens, an empty label, or excess length produce
  an actionable error that requires `--host-name`; automatic derivation does not silently
  lowercase, replace characters, or truncate. This stricter rule applies to defaults, not to the
  existing explicit option, whose compatibility remains governed by NixOS evaluation.
  Rationale: `ContextName` is a safe filesystem segment, not a host-name type: it permits uppercase
  letters, `_`, and `.` and does not impose a length limit. Silent normalization would make distinct
  contexts such as `prod_a` and `prod-a` request the same tailnet name, while truncation creates the
  same problem for long names, and lowercasing would alias `Prod` with `prod`. Rejecting every lossy
  conversion keeps the mapping injective and makes the existing explicit option the deliberate
  recovery path.
  Date: 2026-09-14

- Decision: A sibling collision is a hard error only for an implicit default. An explicitly passed,
  valid `--host-name` is treated as deliberate and bypasses this workstation-local ownership check.
  Rationale: The improvement request asks the command to warn or refuse when no explicit host name
  was supplied. Nagare can inspect only host flakes on the current workstation, not the complete
  tailnet, so the check is a defense against accidental reuse rather than a global uniqueness
  authority. The error tells the operator to choose a distinct explicit name after checking the
  tailnet.
  Date: 2026-09-14

- Decision: Collision discovery reads generated `host.nix` files and compares their rendered
  `nagare.host.hostName` assignment; it does not introduce a parallel registry or infer the name
  from the sibling context directory.
  Rationale: Existing flakes already record effective operator intent, including explicit
  overrides, and ADR 5 makes those files durable context-owned sources. Matching the generator's
  exact assignment avoids a general Nix parser; an unreadable generated sibling fails closed because
  uniqueness cannot be established.
  Date: 2026-09-14

- Decision: Implementation amends ADR 5 rather than creating a new ADR.
  Rationale: ADR 5 already owns the context-host-flake boundary, host versus instance identities,
  and generator safety properties. The new default and sibling check refine that contract.
  Date: 2026-09-14

- Decision: Inspect sibling context directories in sorted order and report the first collision.
  Rationale: More than one pre-existing flake can already contain the same host name. Sorting makes
  the owning context named by the refusal stable across filesystems without weakening the hard
  error or inventing a second host registry.
  Date: 2026-09-14

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

All three milestones are complete. Contexts that are already lowercase DNS labels now receive an
injective `<context>-nagare` OS and Tailscale identity without changing their GCE instance name.
The `prod` and `labs` installed-command fixtures both retain `nagare-01` while rendering distinct
host names; a seeded `legacy` owner prevents implicit `prod-nagare`, and explicit
`--host-name prod2-nagare` succeeds. Unit coverage also proves invalid derivations, current-context
exclusion, missing and non-host entries, symlinked roots, exact assignment matching, and unreadable
sibling failure.

The multi-cluster and access guides now distinguish `ssh deploy@prod-nagare` over Tailscale from
IAP commands addressed to project-scoped instance `nagare-01`. ADR 5 holds the durable default,
collision, symlink, fail-closed, explicit-override, and existing-flake contracts; no new ADR was
needed. IR-14 is completed. Validation passed: all 472 Haskell tests, both focused Nix checks,
Haskell style, 37 user documents, 2 guides, 21 improvement requests, and every buildable native
flake check. Nix omitted incompatible `x86_64-linux` outputs on the `aarch64-darwin` host, and no
functional work remains in this plan.

