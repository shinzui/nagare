# Bundle Update Log

## 2026-10-07

* **Update**: RES-4 rule U6 records experiment E16: a PVC held by `pvc-protection` cannot be mounted by a new pod, goes as soon as its pod is deleted, and keeps its data only if its volume was set to `Retain` first (F77's runbook).

## 2026-10-06

* **Update**: RES-4 adds rules U11–U14 (deletion moves generation and stops reconciliation; ownership of admission versus defaulting; DomainMapping and PVC finalizers; kubectl message formats), found while making EP-182's fake API server reproduce the recorded traces.
* **Update**: RES-4 adds rule U10 (server-side apply field ownership, experiment E13) and refines §5.2's execute guard for G6 accordingly.
* **Update**: RES-4 §5.1 records the adopted before-state rule for the F67 stamp proof (the stamp observed at prepare, as the required `beforeStamp`) and drops old-journal compatibility; Nagare has no deployed users.
* **Add**: Record RES-4, the experiment-validated Kubernetes API semantics of MP-23 release line (b) kinds on k3s 1.34.6 and Knative 1.22, the ADR 26 decision tables they imply, and a gap analysis of the Kubernetes adapter and world model.

## 2026-09-28

* **Add**: Record RES-3, a first-pass assessment of MasterPlan 23's scope against established infrastructure, Kubernetes, backup, and database tooling after Nagare gained a workplace intranet use. Candidate tools are identified but not yet evaluated.

## 2026-09-25

* **Migration**: Register the research bundle under the OKF research-documents profile and assign the existing OpenBao assessment RES-1.
* **Add**: Record RES-2, an evidence-based comparison of Cloud Armor, Cloudflare WAF, and Coraza for Nagare's current ingress design.
