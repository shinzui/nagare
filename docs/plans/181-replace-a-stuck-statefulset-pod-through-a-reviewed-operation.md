---
id: 181
slug: replace-a-stuck-statefulset-pod-through-a-reviewed-operation
title: "Replace a stuck StatefulSet pod through a reviewed operation"
kind: exec-plan
created_at: 2026-10-06T22:01:40Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-06T22:01:40Z
---

# Replace a stuck StatefulSet pod through a reviewed operation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Explain in a few sentences what someone gains after this change and how they can see it
working. State the user-visible behavior you will enable.


## Progress

Use checkboxes for verifiable milestones or substantial deliverables, not individual
edits, commands, tests, commits, or session activity. Update this section when a milestone
is accepted, a material blocker or change of course arises, or work is handed off. For a
handoff during a milestone, add a short prose note stating the remaining outcome.

- [ ] <First verifiable milestone or deliverable and its acceptance condition.>


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record decisions that change scope, architecture, interfaces, acceptance, or the path a
future contributor should follow. Omit routine implementation choices.

- Decision: ...
  Rationale: ...
  Date: ...


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Describe the current state relevant to this task as if the reader knows nothing. Name the
key files and modules by full path. Define any non-obvious term you will use. Do not refer
to prior plans unless they are checked into the repository, in which case reference them by
path. Follow the skill's ADR.md workflow: scan local filenames and headings, read only ADRs
relevant to this work, and summarize them here with repository-relative links. Cite a
cross-repository ADR only with the exact canonical handle returned by Mori. If no relevant
ADR exists, say so.


## Plan of Work

Describe the sequence of meaningful changes in prose. Name key files and locations
(functions or modules) and the intended result, leaving routine edit choices open.

Break into milestones if the work spans multiple independent phases. Each milestone must be
independently verifiable. Introduce each milestone with a brief paragraph: scope, what will
exist at the end, commands to run, acceptance criteria.


## Concrete Steps

State the exact commands to run and where to run them (working directory). When a command
generates output, show a short expected transcript so the reader can compare. This section
should be revised when the implementation approach changes.


## Validation and Acceptance

Describe how to exercise the system and what to observe. Phrase acceptance as behavior with
specific inputs and outputs. If tests are involved, name the exact test commands and expected
results. Show that the change is effective beyond compilation.
If an uncertain interface connects independently developed pieces, identify an early
representative interaction check appropriate to the project and authorized environment.
Distinguish required acceptance from proposals for additional scope.


## Idempotence and Recovery

If steps can be repeated safely, say so. If a step is risky, provide a safe retry or
rollback path.


## Interfaces and Dependencies

Name the libraries, modules, and services whose choice matters. Specify key types or
interfaces that other work depends on, using full module paths.
For a child plan, identify prerequisite artifacts or behavior and the parent-declared
plan or milestone that must be accepted before this work begins.
