---
title: "Use Case 004 — Engineers Deploy Sites by Pushing Through a Delegated Deployer"
type: Use Case
description: "On an installation one operator administers, any engineer on the team starts a new site or app from a repository and has every push to its release branch deployed automatically, through a CI/CD deployer the operator delegated a bounded part of the installation to, without the engineer holding platform credentials."
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-11-07T16:49:54Z"
useCaseId: UC-4
status: planned
origin: mori://shinzui/nagare
themes:
  - team-operation
jobs:
  - name: start-a-new-site
    actor: application engineer on the team, holding no platform credentials
    situation: the engineer has a new repository for a static site or a small web app and wants it served on the team's installation
    motivation: get an HTTPS URL that colleagues can open without asking the operator to run commands, hand over credentials or review each new site
    outcome: after the repository is admitted, its first push is built and served at a hostname inside the delegated bounds, protected by login and open to the team the operator chose
  - name: ship-by-pushing
    actor: application engineer on the team, holding no platform credentials
    situation: a change is pushed to the repository's release branch
    motivation: publish the change without rebuilding, publishing an image or applying a review by hand
    outcome: the pushed commit is built in isolation, deployed once, and its build and deployment results appear on the commit in the forge; a failure is visible there and leaves the previous release serving
  - name: delegate-without-giving-away-the-platform
    actor: Nagare operator (the single administrator)
    situation: engineers should be able to deploy on their own, but the installation holds work data and the operator remains its only administrator
    motivation: grant self-service deployment once, inside bounds the operator reviewed, instead of either doing every deployment or sharing operator credentials
    outcome: one reviewed delegation names a deployer, the namespaces and hostnames it may use, what it may create and who may open what it creates; nothing the deployer is given can change the platform, another namespace, access policy or managed data, and the operator can revoke it with one reviewed change
  - name: know-who-changed-what
    actor: Nagare operator (the single administrator)
    situation: the operator reads the installation's history after a deployment or an incident
    motivation: tell an engineer's automated deployment apart from the operator's own changes and trace it to its source
    outcome: every change the deployer applies is recorded in the inventory journal under the deployer's name, with the repository, commit and CI run that produced it
features:
  - name: bounded-namespace-delegation
    description: An operator-reviewed delegation authorizes a named deployer to admit apps and sites in named namespaces, under hostname, resource-kind, protection and quota bounds, without a per-site operator review.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: With a delegation applied, the deployer's review of a new site in a delegated namespace is accepted; the same review with a namespace, hostname, resource kind or quota outside the bounds is refused before any mutation, naming the bound it breaks; after the delegation is revoked, every deployer review is refused.
    jobs:
      - start-a-new-site
      - delegate-without-giving-away-the-platform
  - name: least-privilege-deployer-credentials
    description: Nagare issues the deployer a credential bundle whose cluster and registry permissions reach only the delegated namespaces and image repository, and which passes the context guard without cluster-admin.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: Using only the issued bundle, the deployer plans and applies a delegated site; the same bundle cannot read or write a Secret, Deployment or Namespace outside the delegated namespaces, cannot push to another image repository, and stops working after a reviewed revocation.
    jobs:
      - delegate-without-giving-away-the-platform
  - name: deploy-without-running-repository-code
    description: A repository's configuration is rendered inside the isolated build and the deployer deploys the rendered document, so the process holding deployer credentials never executes repository code.
    status: planned
    owners:
      - mori://shinzui/nagare
      - mori://shinzui/kotei
    acceptance: A deployer context refuses `-f Config.hs` and deploys an app or static site from a rendered document; a repository whose configuration program tries to read the deployer's credentials can only do so inside the credential-free build, where there are none.
    jobs:
      - ship-by-pushing
      - delegate-without-giving-away-the-platform
  - name: default-access-for-delegated-sites
    description: Sites created under a delegation are protected and opened to the team the delegation names, without the deployer holding the access service's write key or a per-site grant.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: A new site deployed through the delegation redirects an anonymous visitor to sign in, admits a member of the delegation's team, refuses a signed-in user outside it, and needed no access review of its own.
    jobs:
      - start-a-new-site
  - name: deployer-attribution-in-the-journal
    description: Inventory reviews and journal events record the actor that applied them and the source it names, so a deployer's changes are distinguishable from the operator's.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: Reading the inventory journal shows the deployer's name, repository, commit and run reference on a delegated deployment, and the operator on an operator change.
    jobs:
      - know-who-changed-what
  - name: deployer-hosted-on-the-installation
    description: The CI/CD deployer (Kotei) runs as an ordinary application on the installation it deploys to, with its database, workers, deploy runner and a public webhook endpoint.
    status: planned
    owners:
      - mori://shinzui/kotei
    acceptance: Kotei deploys from a release image to a Nagare context through `nagarectl app deploy`, receives a signed forge webhook on its public host, and passes its readiness checks after migrations.
    jobs:
      - ship-by-pushing
    improvementRequests:
      - mori://shinzui/kotei/okf/improvement-requests/concepts/IR-9
  - name: isolated-builds-of-engineer-code
    description: Builds of engineers' repositories run in credential-free, resource-bounded build jobs, never inside the deployer's own process or pod.
    status: planned
    owners:
      - mori://shinzui/kotei
    acceptance: A forge build of an admitted repository runs in a Kubernetes Job that holds no Kotei database, forge App, registry or Nagare credential, and publishes the image archive and rendered configuration the deployment consumes.
    jobs:
      - ship-by-pushing
  - name: self-service-repository-admission
    description: An engineer's repository is admitted at runtime when it matches an operator-declared onboarding template, and declares its own branch and tag promotion within the template's bounds, with no restart of the deployer.
    status: planned
    owners:
      - mori://shinzui/kotei
    acceptance: A new repository in an allowed forge owner that carries the declaration file is admitted, built and deployed on its first push without any configuration change or restart; a repository outside the template, or declaring a target the template does not allow, is refused with a visible reason.
    jobs:
      - start-a-new-site
      - ship-by-pushing
relatedUseCases:
  - UC-3
---

# Use Case 004: engineers deploy sites by pushing through a delegated deployer

A team runs a Nagare installation with one operator, as in [UC-3](003-operate-nagare-as-a-team-run-intranet-paas.md).
Today that operator deploys every application: deploying needs the inventory store, a cluster-admin kubeconfig and
registry credentials, and the operator alone holds them. As the team grows, every new site and every change waits for
the operator.

This use case keeps one administrator and adds one delegated machine actor. The operator reviews a **delegation** once:
it names a deployer, the namespaces and hostnames the deployer may use, what kinds of resources it may create, which
team may open what it creates, and its quotas. The deployer is a CI/CD system the operator runs, for example Kotei
(`mori://shinzui/kotei`), whose existing push-to-deploy path is described in
`mori://shinzui/kotei/okf/use-cases/concepts/UC-5`. Engineers never receive platform credentials. They push to a
repository; the deployer builds the exact commit in an isolated job and deploys it within the delegation.

The trust boundary is deliberate. The deployer is trusted software run by the operator and holds credentials that are
bounded where Nagare can bound them: cluster permissions reach only the delegated namespaces and the registry push
reaches only the delegated repository. Repository content is untrusted: a configuration program, an image or a
declared hostname from an engineer's repository must never run with the deployer's credentials and must never reach
outside the delegation. Nagare enforces the bounds on the rendered configuration it is handed, and Kotei renders that
configuration in the build, where no credential exists.

The use case is generic. It names no installation, project or domain, and it must work on a local context as well as a
cloud context. It does not ask for multiple operators, second-person approval or shared operator material; those
remain excluded by UC-3. A delegated deployer is not an operator: it cannot change the platform, access policy,
databases or another namespace.
