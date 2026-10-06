# Verbatim results of the terminal-only experiments

Copied from the session transcript of 2026-10-06. Each line is one snapshot of the object:
`uid` (first 8 characters), `rv` resourceVersion, `gen` metadata.generation, `og`
status.observedGeneration, `conds` condition `type=status(reason)`. `null` means the field
is absent.

## E0

Status subresources in k3s 1.34 (API discovery):

```text
configmaps namespaces namespaces/finalize namespaces/status persistentvolumeclaims persistentvolumeclaims/status resourcequotas resourcequotas/status secrets serviceaccounts serviceaccounts/token services services/proxy services/status
deployments deployments/status statefulsets statefulsets/status cronjobs cronjobs/status jobs jobs/status networkpolicies rolebindings roles services services/status domainmappings domainmappings/status
```

`networkpolicies/status` does not exist. Against a k3s **v1.32.5** server, kubectl v1.37.0
`wait --for=condition=established crd/services.serving.knative.dev` timed out even though
the condition was `True` (also with `--for=jsonpath`). Against v1.34.6 the same command
returned in 0.25 s. Knative 1.22 refused to start on v1.32.5: `kubernetes version
"1.32.5+k3s1" is not compatible, need at least "1.34.0-0"`.

## E1

```text
== configmap
{"l":"create","uid":"a17b849f","rv":"979","gen":null}
{"l":"settled-8s","uid":"a17b849f","rv":"979","gen":null}
{"l":"noop-apply","uid":"a17b849f","rv":"979","gen":null}
{"l":"annotate","uid":"a17b849f","rv":"1002","gen":null}
{"l":"label","uid":"a17b849f","rv":"1003","gen":null}
{"l":"spec-v2","uid":"a17b849f","rv":"1004","gen":null}
== secret, serviceaccount, role, rolebinding: identical pattern, gen null throughout
== networkpolicy
{"l":"create","rv":"1179","gen":1}
{"l":"noop-apply","rv":"1179","gen":1}
{"l":"annotate","rv":"1199","gen":1}
{"l":"label","rv":"1200","gen":1}
{"l":"spec-v2","rv":"1201","gen":2}
== service
{"l":"create","rv":"1222","gen":null}
{"l":"spec-v2","rv":"1248","gen":null}
{"l":"status-patch:service/e1 patched","rv":"1249","gen":null,"conds":["ExpProbe=True(R)"]}
== resourcequota
{"l":"spec-v2","rv":"1276","gen":null}
{"l":"status-patch:resourcequota/e1 patched","rv":"1277","gen":null}
== namespace
{"l":"spec-v2","rv":"1318","gen":null,"phase":"Active"}
{"l":"status-patch:namespace/exp-e1 patched","rv":"1319","gen":null}
== persistentvolumeclaim
{"l":"create","rv":"1337","gen":null,"fin":["kubernetes.io/pvc-protection"],"phase":"Pending"}
The PersistentVolumeClaim "e1" is invalid: spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims
{"l":"status-patch:persistentvolumeclaim/e1 patched","rv":"1362","gen":null,"conds":["Resizing=True"]}
== deployment
{"l":"create","rv":"1415","gen":1,"og":1,"conds":["Progressing=True(NewReplicaSetCreated)","Available=False(MinimumReplicasUnavailable)"]}
{"l":"settled-8s","rv":"1442","gen":1,"og":1,"conds":["Available=True(MinimumReplicasAvailable)","Progressing=True(NewReplicaSetAvailable)"]}
{"l":"noop-apply","rv":"1442","gen":1,"og":1}
{"l":"annotate","rv":"1450","gen":2,"og":2}
{"l":"label","rv":"1451","gen":2,"og":2}
{"l":"spec-v2","rv":"1465","gen":3,"og":3,"conds":["Available=True(MinimumReplicasAvailable)","Progressing=True(ReplicaSetUpdated)"]}
{"l":"status-patch:deployment.apps/e1 patched","rv":"1466","gen":3,"og":3}
== statefulset
{"l":"create","rv":"1512","gen":1,"og":1,"conds":[]}
{"l":"annotate","rv":"1537","gen":1,"og":1}
{"l":"label","rv":"1538","gen":1,"og":1}
{"l":"spec-v2","rv":"1543","gen":2,"og":2}
{"l":"status-patch:statefulset.apps/e1 patched","rv":"1549","gen":2,"og":2}
== cronjob
{"l":"create","rv":"1934","gen":1,"og":null}
{"l":"annotate","rv":"1952","gen":1,"og":null}
{"l":"spec-v2","rv":"1954","gen":2,"og":null}
{"l":"status-patch:cronjob.batch/e1 patched","rv":"1955","gen":2,"og":null}
== job
{"l":"create","rv":"2014","gen":1,"og":null,"conds":["Suspended=True(JobSuspended)"]}
{"l":"annotate","rv":"2056","gen":1,"og":null}
{"l":"spec-v2","rv":"2059","gen":2,"og":null}
{"l":"settled-8s","rv":"2081","gen":2,"og":null,"conds":["Suspended=False(JobResumed)","SuccessCriteriaMet=True(CompletionsReached)","Complete=True(CompletionsReached)"]}
== ksvc (an unowned core Service "e1" existed in the namespace)
{"l":"create","rv":"1654","gen":1,"og":1,"conds":["ConfigurationsReady=Unknown","Ready=Unknown(OutOfDate)","RoutesReady=Unknown(OutOfDate)"]}
{"l":"settled-8s","rv":"1740","gen":1,"og":1,"conds":["ConfigurationsReady=True","Ready=False(NotOwned)","RoutesReady=False(NotOwned)"]}
{"l":"noop-apply","rv":"1740","gen":1}
{"l":"annotate","rv":"1755","gen":1}
{"l":"label","rv":"1761","gen":1}
{"l":"spec-v2","rv":"1775","gen":2,"og":2,"conds":["ConfigurationsReady=Unknown","Ready=False(NotOwned)","RoutesReady=False(NotOwned)"]}
{"l":"status-patch:service.serving.knative.dev/e1 patched","rv":"1776","gen":2,"og":2}
-- after deleting the core Service "e1": Ready=True (after the next reconcile)
```

## E3 (ConfigMap; the Knative Service run gave the same codes and the same "no effect")

```text
start uid=ae593ab3 rv=2156
a create-existing             | POST 409 Conflict  | AlreadyExists                                   | after: rv 2156
b ssa current uid+rv (control)| PATCH 200 OK       |                                                 | after: rv 2162
c ssa stale rv                | PATCH 409 Conflict | the object has been modified                    | after: rv 2162
d ssa wrong uid, current rv   | PATCH 422          | metadata.uid: Invalid value ...: field is immutable | after: rv 2162
e put stale rv                | PUT 409 Conflict   | the object has been modified                    | after: rv 2162
f jsonpatch test rv fails     | PATCH 422          | the server rejected our request due to an error in our request | after: rv 2162
g delete precond wrong uid    | DELETE 409 Conflict| the UID in the precondition ... does not match  | after: rv 2162
h delete precond stale rv     | DELETE 409 Conflict| the ResourceVersion in the precondition (2156) does not match | after: rv 2162
-- deleted out of band
i ssa uid+rv on absent        | PATCH 409 Conflict | uid mismatch: the provided object specified uid ..., and no existing object | after: absent
j ssa rv only on absent       | PATCH 201 Created  |                                                 | after: NEW uid 10f2818f
k ssa uid only on absent      | PATCH 409 Conflict | uid mismatch                                    | after: absent
l delete precond on absent    | DELETE 404         | not found                                       | after: absent
```

## E4

```text
{"l":"before","uid":"b2b92b9b","rv":"2010","gen":2,"og":2,"conds":["ConfigurationsReady=True","Ready=True","RoutesReady=True"]}
-- idle churn: rv over 60s
2010 2010 2010 2010 2010 2010
-- controller scaled to 0, spec updated
{"l":"spec-update, controller frozen","rv":"2709","gen":3,"og":2,"conds":["ConfigurationsReady=True","Ready=True","RoutesReady=True"]}
kubectl wait --for=condition=ready (frozen): rc=1 error: timed out waiting for the condition on services/e1
{"nagare_knativeReady":true,"gen":3,"og":2,"latestReady":"e1-00002","traffic":[{"revisionName":"e1-00002","percent":100}]}
-- controller resumed; sampling
t=0s {"gen":3,"og":2,"ready":"True/","latestReady":"e1-00002","latestCreated":"e1-00002"}
t=2s {"gen":3,"og":3,"ready":"Unknown/","latestReady":"e1-00002","latestCreated":"e1-00003"}
t=3s {"gen":3,"og":3,"ready":"Unknown/IngressNotConfigured","latestReady":"e1-00003"}
t=3s {"gen":3,"og":3,"ready":"True/","latestReady":"e1-00003"}
-- bad image update
t=0s {"gen":4,"og":4,"ready":"Unknown/","cfg":"Unknown/","latestReady":"e1-00003","latestCreated":"e1-00004","traffic":["e1-00003"]}
t=1s {"gen":4,"og":4,"ready":"False/RevisionFailed","cfg":"False/RevisionFailed","latestReady":"e1-00003","latestCreated":"e1-00004","traffic":["e1-00003"]}
kubectl wait (bad image): rc=1 error: timed out waiting for the condition on services/e1
```

## E7, E8, E11

```text
== E7a PVC in use by a pod, Orphan delete with uid+rv preconditions
DELETE response: {"kind":"PersistentVolumeClaim","dt":"2026-10-06T21:40:18Z","fin":["kubernetes.io/pvc-protection","orphan"],"status":{"phase":"Bound",...}}
wait --for=delete 10s: rc=1 error: timed out waiting for the condition on persistentvolumeclaims/e7
{"uid":"e9108774","rv":"4791","dt":"2026-10-06T21:40:18Z","fin":["kubernetes.io/pvc-protection"],"phase":"Bound"}
-- second DELETE with the original rv precondition:
Error from server (Conflict): Operation cannot be fulfilled on PersistentVolumeClaim "e7": the ResourceVersion in the precondition (4779) does not match ...
pvc gone after pod deleted
== E7b Knative Service, Orphan delete (Nagare's policy for serving.knative.dev/service)
DELETE response: {"kind":"Service","dt":"2026-10-06T21:40:32Z","fin":["orphan"],...}
error: timed out waiting for the condition on services/e7k            (30 s)
left behind: configuration.serving.knative.dev/e7k route.serving.knative.dev/e7k revision.serving.knative.dev/e7k-00001 ingress.networking.internal.knative.dev/e7k
-- later: ksvc still {"dt":"2026-10-06T21:40:32Z","fin":["orphan"]}; Configuration, Route and Ingress Ready=True, each still with 1 ownerReference
== E8 Job failure; template immutability
job conditions: ["FailureTarget=True(BackoffLimitExceeded)","Failed=True(BackoffLimitExceeded)"]
The Job "e8" is invalid: spec.template: Invalid value: ...: field is immutable
== E11 quantity canonicalization
Deployment requests {cpu:"1000m",memory:"1024Mi"} limits {memory:"2048Mi",cpu:"1.5","ephemeral-storage":"1000M"}
 -> {"limits":{"cpu":"1500m","ephemeral-storage":"1G","memory":"2Gi"},"requests":{"cpu":"1","memory":"1Gi"}}
PVC requests.storage "1024Mi" -> {"requests":{"storage":"1Gi"}}
Knative Service requests {memory:"1024Mi",cpu:"1000m"} -> {"requests":{"cpu":"1","memory":"1Gi"}}
```

## E9, E12

```text
== E9 DomainMapping to a Ready ksvc (stock config: autocreate-cluster-domain-claims "false")
t=0s {"gen":1,"og":1,"conds":["CertificateProvisioned=Unknown()","DomainClaimed=False(DomainAlreadyClaimed)","IngressReady=Unknown(IngressNotConfigured)","Ready=False(DomainAlreadyClaimed)","ReferenceResolved=Unknown()"]}
   (unchanged for 20 s)
== E12 lingering after DELETE
ConfigMap, Orphan, uid+rv preconditions: response {"dt":"...","fin":["orphan"]}; configmap gone after 88 ms
StatefulSet, Background, uid+rv preconditions: response {"dt":null,"fin":null}; sts gone after 94 ms; pods left: 1 (deleted afterwards by the garbage collector)
Namespace delete: {"phase":"Terminating","dt":"...","fin":["kubernetes"]}, then gone
```
