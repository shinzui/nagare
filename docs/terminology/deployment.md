---
type: Term
title: deployment
description: A Nagare declaration of an HTTP application that renders to a Knative Service.
generated:
  by: process:codex
  at: "2026-09-24T05:19:47Z"
termId: TERM-13
status: current
tags: [applications-delivery]
related:
  - TERM-14
  - TERM-15
  - TERM-22
anchors:
  - kind: doc
    resource: docs/user/deploying-apps.md
---

# deployment

A Nagare declaration of an HTTP application that renders to a Knative Service. A `Deployment` describes the image, domain, port, environment, scaling, and optional volumes. In this vocabulary it is the Nagare DSL value, distinct from a Kubernetes `apps/v1` Deployment used for workers.

See [Deploying apps](../../docs/user/deploying-apps.md) for the full contract and operating procedure.
