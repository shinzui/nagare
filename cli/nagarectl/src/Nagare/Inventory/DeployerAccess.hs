-- | The Kubernetes authority of a delegated deployer and its builder (EP-248,
-- ADR 35). The rules are what the compilers of the delegated kinds write
-- and read, checked against production-compiled fixtures by the test suite,
-- so a compiler that adds a member fails the fast gate rather than a native
-- run. A revoked delegation keeps every identity object and empties every
-- Role, so revocation takes effect in the one reviewed change that applies
-- it. The read-only ClusterRole (nodes, routes, claims) is left as it is.
module Nagare.Inventory.DeployerAccess
  ( KubernetesRule (..)
  , lifecycleVerbs
  , pluralOf
  , writtenKinds
  , deployerRules
  , systemRules
  , clusterReadRules
  , builderRules
  , deployerAccountName
  , builderAccountName
  , IdentityObject (..)
  , identityObjects
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Nagare.Access.Resolve (backendConfigMapName, backendConfigMapNamespace)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DelegatedKind (DelegatedKind (..))

-- | One RBAC policy rule. Empty 'resourceNames' means every object of the
-- resources.
data KubernetesRule = KubernetesRule
  { apiGroups :: ![Text]
  , resources :: ![Text]
  , verbs :: ![Text]
  , resourceNames :: ![Text]
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | Observe, create, update by server-side apply, wait for and collect.
lifecycleVerbs :: [Text]
lifecycleVerbs = ["create", "delete", "get", "list", "patch", "update", "watch"]

readVerbs :: [Text]
readVerbs = ["get", "list", "watch"]

-- | The REST resource of a lowercase kind, for the kinds rules name.
pluralOf :: Text -> Text
pluralOf = \case
  "service" -> "services"
  "configmap" -> "configmaps"
  "secret" -> "secrets"
  "deployment" -> "deployments"
  "cronjob" -> "cronjobs"
  "job" -> "jobs"
  "domainmapping" -> "domainmappings"
  "serviceaccount" -> "serviceaccounts"
  "networkpolicy" -> "networkpolicies"
  other -> other <> "s"

-- | (API group, resource) pairs a delegated kind's compilers write as
-- members in a delegated namespace.
writtenKinds :: DelegatedKind -> [(Text, Text)]
writtenKinds = \case
  DelegatedWebApp -> [knativeServices, configMaps, ("apps", "deployments"), ("batch", "cronjobs"), ("batch", "jobs")]
  DelegatedWorker -> [("apps", "deployments")]
  DelegatedTask -> [("batch", "jobs")]
  DelegatedStaticSite -> [knativeServices, configMaps]
  DelegatedServerSite -> [knativeServices, configMaps]
  where
    knativeServices = ("serving.knative.dev", "services")
    configMaps = ("", "configmaps")

-- | The Role in each delegated namespace.
deployerRules :: NonEmpty DelegatedKind -> [KubernetesRule]
deployerRules kinds = grouped lifecycleVerbs (nub (concatMap writtenKinds (NE.toList kinds)))

grouped :: [Text] -> [(Text, Text)] -> [KubernetesRule]
grouped verbs' pairs =
  [ KubernetesRule {apiGroups = [group], resources = sort (nub resources'), verbs = verbs', resourceNames = []}
  | (group, resources') <- Map.toList (Map.fromListWith (<>) [(group, [resource]) | (group, resource) <- pairs])
  ]

-- | The Role in @nagare-system@: the access backend map that a protected
-- deploy regenerates, and the protected routes themselves. RBAC cannot bound
-- a route's hostname or target; the delegation bounds do (EP-247 D4).
systemRules :: [KubernetesRule]
systemRules =
  [ KubernetesRule [""] ["configmaps"] ["get", "patch", "update"] [backendConfigMapName]
  , KubernetesRule ["serving.knative.dev"] ["domainmappings"] lifecycleVerbs []
  ]

-- | The ClusterRole: the cluster session guard lists nodes; the hostname
-- preflight reads every route and claim (as @nagared@'s RBAC does).
clusterReadRules :: [KubernetesRule]
clusterReadRules =
  [ KubernetesRule [""] ["nodes"] ["get", "list"] []
  , KubernetesRule ["serving.knative.dev"] ["domainmappings"] ["get", "list"] []
  , KubernetesRule ["networking.internal.knative.dev"] ["clusterdomainclaims"] ["get", "list"] []
  ]

-- | The builder's Role in the build namespace: exactly what a one-shot Job
-- renders (a tokenless ServiceAccount, a NetworkPolicy and the Job) and what
-- watching it needs. No Secrets, no exec, nothing outside the namespace.
builderRules :: [KubernetesRule]
builderRules =
  [ KubernetesRule [""] ["serviceaccounts"] builderVerbs []
  , KubernetesRule ["networking.k8s.io"] ["networkpolicies"] builderVerbs []
  , KubernetesRule ["batch"] ["jobs"] builderVerbs []
  , KubernetesRule [""] ["pods", "pods/log"] readVerbs []
  ]
  where
    builderVerbs = ["create", "delete", "get", "list", "watch"]

deployerAccountName :: Text -> Text
deployerAccountName deployer = "nagare-deployer-" <> deployer

builderAccountName :: Text -> Text
builderAccountName deployer = "nagare-builder-" <> deployer

-- | One identity object of a delegation scope, with the role name its member
-- id is minted from and the namespace it orders after ('Nothing' for a
-- cluster-scoped object, which orders after the deployer's ServiceAccount).
data IdentityObject = IdentityObject
  { role :: !Text
  , namespace :: !(Maybe Text)
  , value :: !Value
  , after :: ![Text]
  -- ^ Roles of the other identity objects it orders after.
  }
  deriving stock (Eq, Show, Generic)

-- | The deployer's and builder's identities. @active@ false empties every
-- Role and keeps every object, so a token issued earlier can deploy nothing.
identityObjects :: Text -> Bool -> NonEmpty DelegatedKind -> NonEmpty Text -> Maybe Text -> [IdentityObject]
identityObjects deployer active kinds namespaces build =
  [IdentityObject "deployer-account" (Just system) (account deployerAccount system) []]
    <> concat [binding ("deployer-" <> ns) ns (deployerRules kinds) | ns <- NE.toList namespaces]
    <> binding "deployer-system" system systemRules
    <> [ IdentityObject "deployer-cluster-role" Nothing (clusterRole clusterReadRules) ["deployer-account"]
       , IdentityObject "deployer-cluster-binding" Nothing clusterBinding ["deployer-account", "deployer-cluster-role"]
       ]
    <> concat
      [ [IdentityObject "builder-account" (Just ns) (account builderAccount ns) []]
          <> [ IdentityObject "builder-role" (Just ns) (roleObject builderAccount ns (rulesIf builderRules)) []
             , IdentityObject "builder-binding" (Just ns) (bindingObject builderAccount ns builderAccount ns) ["builder-account", "builder-role"]
             ]
      | Just ns <- [build]
      ]
  where
    system = backendConfigMapNamespace
    deployerAccount = deployerAccountName deployer
    builderAccount = builderAccountName deployer
    rulesIf rules = if active then rules else []
    binding prefix ns rules =
      [ IdentityObject (prefix <> "-role") (Just ns) (roleObject deployerAccount ns (rulesIf rules)) []
      , IdentityObject (prefix <> "-binding") (Just ns) (bindingObject deployerAccount ns deployerAccount system) ["deployer-account", prefix <> "-role"]
      ]
    labels = object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/delegation" .= deployer]
    metadata name ns = object (["name" .= name, "labels" .= labels] <> ["namespace" .= n | Just n <- [ns]])
    account name ns =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ServiceAccount" :: Text)
        , "metadata" .= metadata name (Just ns)
        , "automountServiceAccountToken" .= False
        ]
    -- A revoked Role omits its rules: server-side apply then removes the
    -- field this manager owned, and the API server stores no rules as null,
    -- which an empty list in the reviewed object would never match.
    roleObject name ns rules =
      object
        ( [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
          , "kind" .= ("Role" :: Text)
          , "metadata" .= metadata name (Just ns)
          ]
            <> ["rules" .= map ruleValue rules | not (null rules)]
        )
    bindingObject name ns subject subjectNamespace =
      object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("RoleBinding" :: Text)
        , "metadata" .= metadata name (Just ns)
        , "roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text), "kind" .= ("Role" :: Text), "name" .= name]
        , "subjects" .= [object ["kind" .= ("ServiceAccount" :: Text), "name" .= subject, "namespace" .= subjectNamespace]]
        ]
    clusterRole rules =
      object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("ClusterRole" :: Text)
        , "metadata" .= metadata deployerAccount Nothing
        , "rules" .= map ruleValue rules
        ]
    clusterBinding =
      object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("ClusterRoleBinding" :: Text)
        , "metadata" .= metadata deployerAccount Nothing
        , "roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text), "kind" .= ("ClusterRole" :: Text), "name" .= deployerAccount]
        , "subjects" .= [object ["kind" .= ("ServiceAccount" :: Text), "name" .= deployerAccount, "namespace" .= system]]
        ]

ruleValue :: KubernetesRule -> Value
ruleValue rule =
  object
    ( [ "apiGroups" .= (rule ^. #apiGroups)
      , "resources" .= (rule ^. #resources)
      , "verbs" .= (rule ^. #verbs)
      ]
        <> ["resourceNames" .= (rule ^. #resourceNames) | not (null (rule ^. #resourceNames))]
    )
