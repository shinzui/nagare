-- | Ownership responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Ownership
  ( applicationNativeOwned
  , applicationRetirementScope
  , hostnameClaimOwned
  , nativeWorkloadOwned
  , workerRetirementScope
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.App.Deployments (appConfigMapName)
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Database (Engine (ClickHouse), dbSecretName)
import Nagare.Dsl.Database.Render (dbConfigMapName, dbPvcName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Task (taskResourceName)
import Nagare.Dsl.Types
  ( databaseNameText
  , domainText
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application.Release (releaseSubject)
import Nagare.Resource.Inventory
  ( Declaration (Managed)
  , ManagedResource
  , ResourceBundle (declarations)
  , ScopeSnapshot
  , claimsOf
  , scopeBundles
  , snapshotScopes
  )
import Nagare.Resource.Types
  ( ProviderAddress (Hostname, Kubernetes)
  , ScopeId
  , canonicalClaim
  , logicalKeyText
  , mkLogicalKey
  , mkName
  , nameText
  , scopeKind
  , scopeName
  )
import Nagare.Resource.Types qualified as Resource

-- | Match every native object that the legacy aggregate deploy can write.
-- The check uses provider addresses so a renamed logical key cannot bypass
-- accepted or retained ownership. Cluster context is checked by the store.
applicationNativeOwned :: Application -> [ManagedResource] -> Bool
applicationNativeOwned app = any matches
  where
    namespaceName = namespaceText (app ^. #namespace)
    objects =
      [ ("serving.knative.dev", "service", serviceNameText (service ^. #name))
      | service <- maybe [] pure (app ^. #service)
      ]
        <> [("", "configmap", appConfigMapName (releaseSubject app))]
        <> [ ( ""
             , "persistentvolumeclaim"
             , pvcName
                 (serviceNameText (service ^. #name))
                 (volumeNameText (volume ^. #name))
             )
           | service <- maybe [] pure (app ^. #service)
           , volume <- service ^. #volumes
           ]
        <> [ ("serving.knative.dev", "domainmapping", domainText (domain ^. #domain))
           | service <- maybe [] pure (app ^. #service)
           , domain <- service ^. #domains
           ]
        <> [ ("apps", "deployment", serviceNameText (worker ^. #name))
           | worker <- app ^. #workers
           ]
        <> [ ( ""
             , "persistentvolumeclaim"
             , pvcName
                 (serviceNameText (worker ^. #name))
                 (volumeNameText (volume ^. #name))
             )
           | worker <- app ^. #workers
           , volume <- worker ^. #volumes
           ]
        <> [ ("apps", "statefulset", databaseNameText (database ^. #name))
           | database <- app ^. #databases
           ]
        <> [ ("", "secret", dbSecretName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases
           ]
        <> [ ("", "persistentvolumeclaim", dbPvcName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases
           ]
        <> [ ("", "service", databaseNameText (database ^. #name))
           | database <- app ^. #databases
           ]
        <> [ ("", "configmap", dbConfigMapName (databaseNameText (database ^. #name)))
           | database <- app ^. #databases
           , database ^. #engine == ClickHouse
           ]
        <> [ ("batch", "cronjob", "nagare-dbbackup-" <> databaseNameText (database ^. #name))
           | database <- app ^. #databases
           , database ^. #retention /= Dsl.Delete
           ]
        <> [ ("batch", "cronjob", taskResourceName (serviceNameText (task ^. #name)))
           | task <-
               app ^. #tasks
                 <> maybe [] (^. #tasks) (app ^. #service)
           ]
    matches resource = case resource ^. #address of
      Kubernetes _ group kind (Just namespace) name ->
        nameText namespace == namespaceName
          && (group, nameText kind, nameText name) `elem` objects
      _ -> False

-- | A direct single-workload command's native identity, including resources
-- retained after their original scope retired.
nativeWorkloadOwned :: T.Text -> T.Text -> T.Text -> T.Text -> [ManagedResource] -> Bool
nativeWorkloadOwned group kind name namespaceName = any matches
  where
    matches resource = case resource ^. #address of
      Kubernetes _ nativeGroup nativeKind (Just nativeNamespace) nativeName ->
        nativeGroup == group
          && nameText nativeKind == kind
          && nameText nativeName == name
          && nameText nativeNamespace == namespaceName
      _ -> False

-- | Direct DNS/CDN commands must respect all global hostname claims,
-- including external platform declarations and aliases on managed resources.
hostnameClaimOwned :: T.Text -> [Declaration] -> Bool
hostnameClaimOwned host declarations = case mkName host of
  Left _ -> False
  Right name ->
    let claim = canonicalClaim (Hostname name)
     in any (any ((== claim) . snd) . NE.toList . claimsOf) declarations

-- | Select retirement from accepted application or standalone web-Service
-- history and the exact native address. A display name or key alone carries
-- no authority.
applicationRetirementScope ::
  T.Text -> T.Text -> Maybe T.Text -> ScopeSnapshot -> Either T.Text ScopeId
applicationRetirementScope name namespaceName pinnedKey snapshot = do
  pinned <- traverse mkLogicalKey pinnedKey
  case [ owner
       | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
       , scopeKind owner `elem` [Resource.Application, Resource.Standalone]
       , case scopeKind owner of
           Resource.Application -> maybe True ((== nameText (scopeName owner)) . logicalKeyText) pinned
           Resource.Standalone ->
             maybe
               True
               ((== nameText (scopeName owner)) . ("service-" <>) . logicalKeyText)
               pinned
           _ -> False
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , case resource ^. #address of
           Kubernetes _ "serving.knative.dev" kind (Just namespace) serviceName ->
             nameText kind == "service"
               && nameText namespace == namespaceName
               && nameText serviceName == name
           _ -> False
       ] of
    [owner] -> Right owner
    _ -> Left "accepted application or standalone history has no unique Knative Service for that name, namespace, and scope key"

-- | Retire only the standalone scope that owns the exact accepted Deployment.
-- The retirement planner preserves its retained PVC declarations.
workerRetirementScope ::
  T.Text -> T.Text -> Maybe T.Text -> ScopeSnapshot -> Either T.Text ScopeId
workerRetirementScope name namespaceName pinnedKey snapshot = do
  pinned <- traverse mkLogicalKey pinnedKey
  case [ owner
       | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
       , scopeKind owner == Resource.Standalone
       , maybe
           True
           ((== nameText (scopeName owner)) . ("worker-" <>) . logicalKeyText)
           pinned
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , case resource ^. #address of
           Kubernetes _ "apps" kind (Just namespace) deploymentName ->
             nameText kind == "deployment"
               && nameText namespace == namespaceName
               && nameText deploymentName == name
           _ -> False
       ] of
    [owner] -> Right owner
    _ -> Left "accepted standalone history has no unique worker Deployment for that name, namespace, and scope key"
