# Kourier (EP-4 Milestone 2)

Kourier is the Knative-specific ingress controller (a thin controller in front
of Envoy). Knative programs Kourier from its routing model; Kourier's gateway
Service `kourier` in namespace `kourier-system` is `type: LoadBalancer`. On the
single-node k3s cluster, k3s's built-in ServiceLB (Klipper) — kept enabled by
EP-3 — binds host ports 80/443 to that Service, giving it the VM's public IP as
its external address.

## Install

Version matches the Knative Serving line: **knative-v1.22.0**. Bootstrap binds
the packaged manifest digest into the review.

```bash
review_dir="$(mktemp -d)"
nagarectl platform bootstrap plan --out "$review_dir"
nagarectl platform bootstrap apply "$review_dir" --yes
```

Knative is told to use Kourier as its ingress by the `config-network` patch in
`../knative-serving/config-network.yaml`
(`ingress-class: kourier.ingress.networking.knative.dev`).

There are no Nagare-authored manifests for Kourier itself; the upstream release
manifest is retained as an exact reviewed input and the ingress class is
selected in the compiled Knative ConfigMap.
