-- | The Kubernetes kinds the adapter admits for each capability, as lists so
-- the recovery model's kind table (ADR 25) can be checked against them;
-- internal implementation behind Nagare.Inventory.Adapters.KubernetesRuntime.
module Nagare.Inventory.Adapters.KubernetesKinds
  ( readinessKinds
  , supportedUpdateKinds
  )
where

import Nagare.Dsl.Prelude

-- | The (API group, kind) pairs with a proved conditional update form.
supportedUpdateKinds :: [(Text, Text)]
supportedUpdateKinds =
  [ ("", "namespace")
  , ("", "configmap")
  , ("", "service")
  , ("", "secret")
  , ("", "persistentvolumeclaim")
  , ("", "resourcequota")
  , ("apps", "deployment")
  , ("apps", "statefulset")
  , ("serving.knative.dev", "service")
  , ("batch", "cronjob")
  , ("networking.k8s.io", "networkpolicy")
  ]

-- | The (API group, kind) pairs whose readiness the adapter waits for; a Job
-- can also fail terminally.
readinessKinds :: [(Text, Text)]
readinessKinds =
  [ ("batch", "job")
  , ("apiextensions.k8s.io", "customresourcedefinition")
  , ("cert-manager.io", "certificate")
  , ("cert-manager.io", "clusterissuer")
  , ("serving.knative.dev", "service")
  , ("serving.knative.dev", "domainmapping")
  , ("apps", "deployment")
  , ("apps", "statefulset")
  ]
