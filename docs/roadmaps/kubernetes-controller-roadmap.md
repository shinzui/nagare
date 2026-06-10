# Kubernetes Controller Roadmap for Nagare

Created: 2026-06-09

This page asks a single question: would Nagare benefit from a Kubernetes controller — custom
resources (CRDs) plus an in-cluster reconcile loop — and if so, when? It is a companion to
`docs/roadmaps/paas-gap-roadmap.md` and reuses that roadmap's phases as the timeline. Like that
roadmap, this is an analysis and a set of decision triggers, not an implementation plan.

The short version: **not yet.** Today an operator would add a controller on top of controllers
Nagare already relies on, without solving a current pain. But several planned phases move Nagare
toward a point where event-driven, no-human-in-the-loop reconciliation becomes genuinely useful.
This page names that point precisely so the decision can be made on evidence rather than fashion.


## What "operator" means here

Two things often get conflated. Keep them separate, because Nagare wants one long before the other:

- **Client-side reconcile** — convergence logic that runs *when you invoke the CLI*. `nagarectl
  reconcile APP` would render desired state from the typed config, diff it against live cluster
  state, converge, and report drift. There is no long-running daemon. It is operator *logic* without
  the operator *deployment*.
- **In-cluster controller (the operator)** — one or more CRDs (e.g. `App`, `Database`, `Preview`)
  plus a controller process running inside k3s that *watches* those resources and continuously
  reconciles desired into actual, with no human triggering each pass.

The distinction matters because most of the value people attribute to "an operator" is really the
value of *declarative desired state plus convergence*, which the client-side form delivers without a
new always-on failure mode.


## Why an operator is the wrong move today

1. **Knative already reconciles the workload.** Nagare apps run as Knative Services — themselves
   declarative, controller-managed resources. The running workload is already kept alive. A
   `nagare.App` CRD that renders down to a Knative Service is a controller on top of a controller;
   its headline job is already done by Knative.

2. **Half the deploy flow cannot live in a controller.** `nagarectl deploy` is build → push → apply
   → wait → record. Build and push need source access and are inherently client-side. An operator
   could only own the post-image half, splitting today's single pipeline into "CLI builds the image"
   plus "controller applies it" — adding a seam rather than removing one.

3. **None of the classic operator payoffs apply at current scale.** Operators earn their keep with
   fleets, multi-tenancy, and team self-service. Nagare is single-node, single-user, single k3s
   (`Multi-server management → out of scope today` in the gap matrix). A controller would be
   machinery sized for problems Nagare does not have.

4. **The stack is Haskell-first; the operator ecosystem is Go-first.** kubebuilder /
   controller-runtime (informers, work queues, leader election, admission webhooks) is Go-centric.
   A Haskell controller means rebuilding that scaffolding by hand — and a buggy controller becomes a
   new way for deploys to break, on a system whose whole pitch is hiding Kubernetes complexity.


## The real gap an operator *would* address

The genuine weakness is not "no controller." It is that **desired state is scattered**: release
history in ConfigMaps, the live Knative Service, env and secrets, cert-manager certificates, Cloud
DNS records, and GCS for static sites. No single object holds "what app X is supposed to be," and
nothing detects or corrects drift if a Service is deleted or mutated out from under Nagare.

Most of that gap closes with the **client-side reconcile** form, which is also the natural extension
of work already on the roadmap:

- Phase 1 (Application model) already moves the DSL toward a single `App`/`Project` object — the
  client-side source of truth.
- Phase 9 (Server and Operations UX) — `nagarectl server status` / `doctor` — is already building
  the "read actual cluster state" half of a reconcile loop.

`nagarectl reconcile` is those two halves joined: render desired from the typed config, read actual
via the Phase 9 probes, diff, converge, report drift. It delivers declarative config, drift
detection, and convergence with **no new in-cluster daemon to operate** — and it is a prerequisite
for a real controller regardless, because a controller needs the same render-and-diff core.

**Recommendation: build `nagarectl reconcile` first.** Treat a CRD-plus-controller as a later,
conditional step gated on the triggers below.


## When an in-cluster controller becomes worth it

Promote from client-side reconcile to a real operator only when at least one trigger below is true.
Each names something that *must watch continuously* — exactly what a CLI invocation cannot provide.
Each is tied to a phase already in the PaaS gap roadmap.

| Trigger | Roadmap phase | Why a CLI is no longer enough |
|---|---|---|
| Deploys with no human at the keyboard (Git push / webhook triggers deploy or preview) | Static hosting webhooks (`docs/masterplans/3`), Phase 7 (dynamic previews) | A push event must be reconciled with nobody running a command. Something in-cluster has to watch. |
| Automatic drift remediation | Phase 9 (Ops UX), once `reconcile` exists | Closing drift *when next invoked* is client-side; closing it *continuously* needs a watch loop. |
| Stateful resources with lifecycle beyond apply (Postgres/Redis failover, backup scheduling, restore orchestration) | Phase 4 (Managed databases and backups) | Database operators exist precisely because these need ongoing reconciliation; here the build/push objection does not apply. |
| Ephemeral previews with TTL and automatic cleanup | Phase 7 (dynamic app previews) | TTL expiry and stale-preview cleanup are time-driven events no human triggers. |
| A stable control surface for remote clients / dashboard | Phase 8 (Control API), Phase 10 (Dashboard) | A CRD is a clean, Kubernetes-native API boundary once `nagared` and external clients exist. |
| Multi-node or multi-instance Nagare | `Multi-server management` (deferred) | Fleet reconciliation genuinely needs a control plane; this is the textbook operator case. |

Phases 4, 7, and the Phase 3/8 webhook automation are where the pressure first appears. Until one of
them lands and actually bites, an operator is premature.


## Cheaper alternatives to weigh first

Before committing to a custom controller, weigh these — each captures part of the value at lower cost:

- **Client-side `nagarectl reconcile`** (above) — covers declarative state and drift *detection* for
  the largest set of cases, with no daemon.
- **Existing upstream operators for stateful pieces only** — when Phase 4 lands, adopt a
  battle-tested Postgres/Redis operator or Helm chart rather than writing Nagare's own. Let Nagare's
  typed config *render* their CRs; do not reimplement their controllers.
- **GitOps (Flux / Argo CD)** — gives declarative state plus continuous reconciliation without
  writing a controller. The tradeoff: it exposes more raw Kubernetes, which cuts against Nagare's
  "hide Kubernetes, typed-config-first" principle, and it is heavier than a single-node PaaS wants
  early. Consider it mainly if the webhook-deploy trigger arrives before any appetite for a custom
  controller.

A bespoke Nagare CRD-plus-controller is justified only when the workflow is Nagare-specific (an
`App`/`Preview` bundle spanning Knative Service + cert + DNS + env + release record) *and* it must
reconcile continuously *and* no upstream operator covers it.


## Recommendation

1. **Now:** do not build an operator. Continue the gap roadmap as written.
2. **Soon (alongside Phases 1 and 9):** build client-side `nagarectl reconcile` on top of the typed
   `App` model and the `server status`/`doctor` probes. This closes the scattered-desired-state gap
   and is a prerequisite for any future controller.
3. **For Phase 4:** prefer an existing upstream database operator over a homegrown controller.
4. **Revisit a bespoke in-cluster controller** only when a trigger in the table above fires —
   realistically first at the webhook-driven deploy/preview work (MasterPlan 3 / Phase 7) or
   automatic drift remediation (Phase 9). Record that decision in the relevant MasterPlan's Decision
   Log when it happens.

This keeps Nagare on its existing principle: a typed, Kubernetes-native personal PaaS that hides
Kubernetes rather than exposing it — adding a control plane only when continuous, unattended
reconciliation is a real requirement, not before.
