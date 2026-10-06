# Kubernetes API semantics experiments (2026-10-06)

Raw evidence for [RES-4](../../research/kubernetes-api-semantics-for-inventory-proofs.md). Every
experiment ran once against a disposable k3d cluster that was deleted afterwards:

- k3s `rancher/k3s:v1.34.6-k3s1`, the image local mode pins in
  [`cluster/bootstrap/local-substrate.json`](../../../cluster/bootstrap/local-substrate.json);
- Knative Serving 1.22.0 and net-kourier 1.22.0 from the vendored manifests in
  [`cluster/bootstrap/vendor`](../../../cluster/bootstrap/vendor/README.md), with Kourier selected and
  the stock `autocreate-cluster-domain-claims: "false"`;
- kubectl client v1.37.0 from the dev shell.

Scripts live in [`experiments/`](experiments/). They need `KUBECONFIG` to point at such a
cluster and create everything in namespace `exp`. Outputs written by the scripts are kept
next to them (`*.out`). The output of E0, E1, E3, E4, E7, E8, E9, E11 and E12 went to the
terminal; their verbatim result lines are in [results.md](results.md).

| ID | Script | Question |
| --- | --- | --- |
| E0 | (inline) | Which kinds have a status subresource; does `kubectl wait` work across client/server skew |
| E1 | `e1.sh <kind>` | When `resourceVersion` and `metadata.generation` move: create, settle, no-op apply, annotation, label, spec, status write |
| E3 | `e3.sh configmap\|ksvc` | What each conditional-write refusal returns and whether it had an effect |
| E4 | `e4.sh` | Knative `Ready` against `observedGeneration` with the controller frozen; bad-image update; idle churn |
| E5 | `e5.sh` | Deployment mid-rollout, bad image and crash loop (`e5.out`) |
| E6 | `e6.sh`, `e6d.sh`, `e6e.sh` | StatefulSet broken update, correction, broken create; `Parallel` policy; Pending pods (`e6.out`, `e6e.out`) |
| E7/E8/E11 | `e7.sh` | Deletion with Nagare's propagation policies; Job failure and immutability; quantity canonicalization |
| E9/E12 | `e9.sh` | DomainMapping readiness; how long objects linger after DELETE |
| E10 | `e10.sh` | Steady-state status churn per kind over 3 minutes (`e10.out`) |
| E13 | `e13.sh` | Server-side apply field ownership with Nagare's manager names: no-force apply after `kubectl create`, foreign edits, same-value writes; `resourceVersion: "0"` (`e13.out`; bare k3s v1.34.6, no Knative) |
