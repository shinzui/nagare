---
type: Improvement Request
title: Add hardened cross-cluster diagnostics deployment profiles to Nagare
description: Package broker and production-probe profiles with identity, RBAC, network policy, and upgrade checks.
timestamp: "2026-07-30T00:30:00Z"
generated:
  by: process:kikan
  at: "2026-07-30T00:30:00Z"
requestId: IR-1
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: add hardened cross-cluster diagnostics deployment profiles to Nagare

**Authored by:** `shinzui/kikan` agents while validating
`mori://shinzui/kikan/okf/use-cases/concepts/UC-5`.
**Addressed to:** `shinzui/nagare` agents, with Shikigami supplying broker/probe images and contract
fixtures.
**Status:** proposed; required for the supported “Kikan on Nagare” installation.
**Contracts:** C11, C13, and the proposed cross-cluster diagnostics contract.
**Created:** 2026-07-24.


## Why

Small companies may run Kikan on Nagare while production applications run in a separate Kubernetes
cluster. Nagare already installs VictoriaMetrics, VictoriaLogs, VictoriaTraces, the OpenTelemetry
Collector, and Grafana, and it can protect browser-facing observability UIs. It does not provide:

- a Kikan-side diagnostic broker deployment;
- a production-side diagnostic probe profile;
- machine-to-machine identity bootstrap between them;
- least-privilege RBAC and network policy for the probe;
- configured adapter endpoints for Nagare's own Victoria stack;
- an end-to-end installation and upgrade check.

Browser forward-auth and a tailnet-reachable Grafana UI are not substitutes for the diagnostic
protocol. The probe needs its own service identity and narrowly scoped backend credentials.


## Requested Kikan-side profile

Add a supported Nagare deployment profile for the Shikigami diagnostic broker. It must include:

- the broker workload and service;
- durable storage or connection to Shikigami's existing durable store;
- Shomei service identity and Kikan-En client configuration;
- public TLS only if target probes must connect over the Internet;
- probe authentication and certificate/key rotation;
- request/result size, rate, expiry, and retention defaults;
- resource requests and limits appropriate to Nagare's single-node profile;
- readiness, liveness, metrics, traces, and a dashboard for connected probes, queue depth, latency,
  denials, expiry, errors, and bytes;
- backup and recovery behavior for non-expired request state;
- an upgrade policy that supports at least the current and immediately previous protocol version.

The broker endpoint accepts authenticated probe sessions only. It is not an agent API, Kubernetes
proxy, Prometheus proxy, Grafana proxy, or generic Internet ingress.


## Requested target-cluster profile

Provide a reusable, values-driven Kubernetes profile for the production diagnostic probe. A target
cluster need not itself run Nagare. The profile should configure:

- stable cluster id and broker address;
- Shomei identity and trust roots;
- En Biscuit verification keys and accepted audiences;
- namespace and service-label allow-lists;
- enabled operation set;
- hard time, item, series, sample, trace, log-line, byte, rate, and concurrency limits;
- backend endpoints and Secret references;
- redaction rules and result-retention policy;
- protocol version and upgrade settings.

The rendered workload must use:

- a dedicated ServiceAccount;
- namespace-scoped Role and RoleBinding;
- non-root execution;
- read-only root filesystem;
- no privilege escalation;
- all Linux capabilities dropped;
- a runtime-default seccomp profile;
- no host network, PID, IPC, paths, container-runtime sockets, or control-plane credentials;
- bounded CPU, memory, and ephemeral storage;
- default-deny ingress and egress policy;
- egress only to DNS, the Kubernetes API, configured local telemetry backends, identity endpoints
  needed for bootstrap/rotation, and the broker.

The Role may include `get`/`list` for approved workload and pod state, `get`/`list` for events, and
`get` for `pods/log` only when that capability is enabled. It must not use wildcard resources or
verbs and must not grant Secrets, exec, attach, port-forward, impersonation, mutation, or node proxy.

Where namespace-wide pod visibility is too broad, the installation guide must require separate
namespaces or separate probe identities. A NetworkPolicy or application label filter must not be
described as stronger Kubernetes API authorization than it is.


## Nagare observability mappings

For a target cluster using Nagare's observability stack, ship tested adapter defaults:

| Evidence | Target |
|---|---|
| Metrics | VictoriaMetrics Prometheus-compatible query API |
| Logs | VictoriaLogs query API |
| Traces | VictoriaTraces Jaeger-compatible query API |
| Grafana metadata | Grafana HTTP API with a dedicated least-privilege service account |
| Kubernetes state | in-cluster Kubernetes API via projected ServiceAccount token |

The OpenTelemetry Collector endpoints `4317` and `4318` receive telemetry and are not query
endpoints. The profile must not point diagnostic trace tools at them.

Credentials must be independent per backend when the backend supports it. The probe Secret may
reference credentials but values must not appear in generated manifests, CLI output, logs, or
diagnostic evidence.


## Installation and operations

Add documented commands that:

1. install or upgrade the broker with Kikan on Nagare;
2. register a target cluster id and probe identity;
3. render the target profile for review without Secrets;
4. install the probe into an explicitly named namespace;
5. confirm the effective ServiceAccount permissions;
6. confirm default-deny networking and outbound broker connectivity;
7. run an allow/deny diagnostic smoke test;
8. rotate probe credentials and trust roots;
9. drain and upgrade a probe without losing terminal request state;
10. uninstall the probe without deleting unrelated namespace resources.

The workflow must be idempotent and must display the exact resources it owns.


## Required verification

Add an automated fixture deployment or local-cluster test that proves:

- the probe reaches the broker by initiating an outbound connection;
- no inbound Service or Ingress is created for the probe;
- the ServiceAccount can read the permitted workload state and cannot read Secrets, exec, mutate a
  Deployment, or access another unbound namespace;
- NetworkPolicy blocks an unapproved endpoint;
- an allowed Victoria metrics/logs/traces query returns a schema-valid evidence bundle;
- query and result limits are enforced;
- broker/probe identities and decision-proof audiences are distinct and verified;
- no credential appears in rendered public configuration or logs;
- disconnecting the probe marks the target unavailable without affecting the Alert path.


## Acceptance

A Nagare operator can follow one documented workflow to run the broker beside Kikan and install a
reviewable probe in a separate Kubernetes cluster. The use case 005 demonstration completes against
Nagare's Victoria stack, while explicit negative checks prove that the probe cannot mutate workloads,
read Secrets, exec into pods, query another namespace, or accept inbound production traffic.


## Non-goals

This request does not make production clusters Nagare-managed, publicly expose Grafana or telemetry
stores, reuse browser sessions for machine access, or give `nagare-access` responsibility for
diagnostic authorization. It packages and operates the contract implemented by Shikigami and
Kikan-En.
