# Kourier (EP-4 Milestone 2)

Kourier is the Knative-specific ingress controller (a thin controller in front
of Envoy). Knative programs Kourier from its routing model; Kourier's gateway
Service `kourier` in namespace `kourier-system` is `type: LoadBalancer`. On the
single-node k3s cluster, k3s's built-in ServiceLB (Klipper) — kept enabled by
EP-3 — binds host ports 80/443 to that Service, giving it the VM's public IP as
its external address.

## Install

Version matches the Knative Serving line: **knative-v1.22.0**. To find the
latest: `gh release list -R knative-extensions/net-kourier`.

```bash
kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.22.0/kourier.yaml
kubectl -n kourier-system get pods
kubectl -n kourier-system get svc kourier   # EXTERNAL-IP should equal the publicIp stack output
```

Knative is told to use Kourier as its ingress by the `config-network` patch in
`../knative-serving/config-network.yaml`
(`ingress-class: kourier.ingress.networking.knative.dev`).

There are no Nagare-authored manifests for Kourier itself; the upstream release
manifest is applied as-is and the ingress class is selected via the Knative
ConfigMap patch.
