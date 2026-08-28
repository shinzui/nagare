---
type: Guide
title: "Bounded one-shot jobs"
description: "Define, run, observe, and safely constrain deadline-bounded one-shot jobs on Nagare."
docId: DOC-25
tags: [jobs, kubernetes, workloads, operations]
generated:
  by: human:nadeem
  at: 2026-08-23T20:57:05Z
---

# Bounded one-shot jobs

> **Status:** 🟢 Complete. The typed `Job` model, loader, hardened renderer, two-slot
> namespace quota, example, and local-cluster acceptance test are complete.
> There is not yet a `nagarectl job` command: today this is a library contract
> for schedulers and platform integrations, not a standalone app-deployment
> workflow.

Use `Nagare.Dsl.Job` for one finite execution that must finish within a deadline.
It is distinct from:

- a [`Task`](scheduled-tasks.md), which owns a recurring schedule and can also
  be fired manually;
- a [`Worker`](workers.md), which is continuously reconciled at a fixed replica
  count; and
- an application pre-deploy hook, which is a Task run as part of
  `nagarectl app deploy`.

The first consumer is the agent-content execution path: each run has an
immutable source revision, a unique run id, bounded resources, temporary
scratch space, and no network unless an operator adds a narrow allow policy.

## What the renderer creates

`renderJob` returns three Kubernetes resources in apply order:

1. a tokenless `ServiceAccount`;
2. a default-deny ingress-and-egress `NetworkPolicy`; and
3. one `batch/v1` Job with `parallelism: 1` and `completions: 1`.

The Pod runs as UID 65532 with `RuntimeDefault` seccomp, a read-only root
filesystem, no privilege escalation, and all Linux capabilities dropped. It
does not receive a Kubernetes API token. Its only writable space is the
size-limited `/scratch` `emptyDir`, which disappears with the Pod.

`oneShotJob` supplies these defaults:

| Setting | Default |
| --- | --- |
| Retry count | `backoffLimit = 0` |
| Wall-clock deadline | `activeDeadlineSeconds = 1800` |
| Finished-Job cleanup | `ttlSecondsAfterFinished = 3600` |
| Scratch limit | `2Gi` |
| CPU request / limit | `250m` / `1` |
| Memory request / limit | `512Mi` / `1Gi` |
| Network | deny ingress and egress |

Keep a positive deadline for capacity-controlled runs. A Job without one is a
valid general Kubernetes Job, but it does not participate in Nagare's
deadline-bounded concurrency quota.

## Define a run

The complete example is
[`cluster/examples/agent-run-job`](../../cluster/examples/agent-run-job). Its
core shape is:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Data.Bifunctor (first)
import Data.Map qualified as Map
import Nagare.Dsl.Build (BuildSpec (PrebuiltImage), mkTag)
import Nagare.Dsl.Command (mkCommand)
import Nagare.Dsl.Config (emitJob)
import Nagare.Dsl.Job
import Nagare.Dsl.Types (EnvVar (EnvLiteral), mkEnvName, runtimeScoped)

job :: Either String Job
job = do
  base <- oneShotJob "agent-run-example" "busybox"
  tag <- first show (mkTag "1.37.0")
  command <- first show (mkCommand ["sh", "-c", "echo ok > /scratch/result"])
  runId <- first show (mkEnvName "NAGARE_RUN_ID")
  pure
    base
      { jobBuild = PrebuiltImage tag
      , jobCommand = Just command
      , jobEnv = Map.singleton runId (runtimeScoped (EnvLiteral "run-change-me"))
      }

main :: IO ()
main = either (ioError . userError) emitJob job
```

Each execution needs a unique `jobName` and run id. Kubernetes Job Pod
templates are immutable, so changing the work and reapplying it under an old
name fails. Pin the input to a full commit SHA and use a unique,
repository-enforced immutable image tag in production. The current `BuildSpec`
is tag-based rather than digest-based. The renderer does not qualify an image
through the active Nagare context and it does not build or push an image for you.

Compile the example contract from the repository root:

```bash
cd cli/nagarectl
cabal exec -v0 -- runghc -XGHC2024 \
  ../../cluster/examples/agent-run-job/nagare/Config.hs
```

This prints a validated `kind: Job` JSON envelope. An integration loads it with
`Nagare.Dsl.Load.loadJob`, calls `Nagare.Dsl.Job.Render.renderJob`, and applies
the three returned manifests in order. Until `nagarectl job` exists, the JSON
output is not itself accepted by `kubectl`, and the checked-in golden bundle is
test evidence rather than a per-run deployment interface.

## Install and observe the concurrency limit

After verifying the active Kubernetes context, install the quota once:

```bash
kubectl config current-context
just job-runs-bootstrap
just job-runs-status
```

The `personal` namespace admits at most two deadline-bounded Pods at the
renderer defaults. When two are active, Kubernetes accepts a third Job object
but its controller cannot create a Pod. `just job-runs-status` shows a
`FailedCreate` event containing `exceeded quota: nagare-terminating-jobs`.

This is backpressure, not an indefinitely Pending Pod. A scheduler must inspect
Job conditions and events, then retry after an admitted run finishes. The
quota's Kubernetes scope is named `Terminating`; here that means a Pod with
`activeDeadlineSeconds`, not a Pod that is already shutting down. Unrelated
deadline-bounded Pods in `personal` share the same two slots.

## Network and durable output

The base NetworkPolicy allows no DNS or other ingress/egress. Add separate,
narrow policies for the exact forge, cache, or result-sink destinations a run
needs. Do not broaden the generated base policy.

NetworkPolicy enforcement is asynchronous on the current local k3s
kube-router dataplane. Testing found that a process connecting immediately at
Pod startup could send traffic before the new Pod IP's rules were installed,
while the same connection was denied after reconciliation. Treat this as
steady-state isolation, not a fail-closed sandbox for untrusted code, until the
target CNI or an admission-time mechanism proves pre-start enforcement.

`/scratch` is ephemeral. Copy results to an explicitly allowed durable sink
before the process exits. The Job TTL later deletes the Job and its Pods, but it
cannot delete the separately applied ServiceAccount and NetworkPolicy. Clean
those after the run by exact name:

```bash
kubectl -n personal delete serviceaccount,networkpolicy \
  nagare-job-<run-name> --ignore-not-found
```

## Related docs

- [Config reference](config-reference.md#one-shot-jobs) — every `Job` field and
  validation rule.
- [Scheduled tasks](scheduled-tasks.md) — recurring work and manual runs of an
  existing CronJob.
- [Running workers](workers.md) — continuous background processes.
- [Reference](reference.md#bounded-job-run-operations) — the operator recipes.
