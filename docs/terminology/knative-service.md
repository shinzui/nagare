---
type: Term
title: Knative Service
description: The request-serving Kubernetes resource Nagare creates for an HTTP app or site.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-14
status: current
tags: [applications-delivery]
related:
  - TERM-13
  - TERM-22
anchors:
  - kind: doc
    resource: docs/user/deploying-apps.md
---

# Knative Service

The request-serving Kubernetes resource Nagare creates for an HTTP app or site. A Knative Service manages revisions and request-driven scaling, including scale to zero when the workload permits it. Workers instead use a Kubernetes Deployment.

See [Deploying apps](../../docs/user/deploying-apps.md) for the full contract and operating procedure.
