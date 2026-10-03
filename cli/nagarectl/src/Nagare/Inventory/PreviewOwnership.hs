-- | Shared exact ownership proof for preview retirement and stopped creation.
module Nagare.Inventory.PreviewOwnership
  ( sitePreviewRetirementScope
  , previewScopeMembers
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..))
import Nagare.Resource.Types

sitePreviewRetirementScope ::
  ScopeSnapshot ->
  ResourceId ->
  T.Text ->
  T.Text ->
  T.Text ->
  [T.Text] ->
  Either T.Text ScopeId
sitePreviewRetirementScope snapshot cluster serviceName ns host volumeNames = do
  owner <- mkScopeId Standalone ("site-preview-" <> serviceName)
  (_, scope) <-
    maybe
      (Left "accepted site preview scope is absent")
      Right
      (Map.lookup owner (snapshotScopes snapshot))
  validatePreviewAddresses scope cluster serviceName ns host volumeNames

validatePreviewAddresses :: ScopeDeclaration -> ResourceId -> T.Text -> T.Text -> T.Text -> [T.Text] -> Either T.Text ScopeId
validatePreviewAddresses scope cluster serviceName ns host volumeNames = do
  owner <- mkScopeId Standalone ("site-preview-" <> serviceName)
  unless (scopeId scope == owner) (Left "preview owner differs from its Service name")
  serviceAddress <-
    kubernetesAddress
      cluster
      "serving.knative.dev/v1"
      "Service"
      (Just ns)
      serviceName
  domainAddress <-
    kubernetesAddress
      cluster
      "serving.knative.dev/v1beta1"
      "DomainMapping"
      (Just ns)
      host
  volumeAddresses <-
    traverse
      ( \volumeName ->
          kubernetesAddress
            cluster
            "v1"
            "PersistentVolumeClaim"
            (Just ns)
            (pvcName serviceName volumeName)
      )
      volumeNames
  unless
    (Set.size (Set.fromList volumeAddresses) == length volumeNames)
    (Left "preview volume names are not distinct")
  let members =
        [ member
        | bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        ]
      declarationsCount = sum [length (declarations bundle) | bundle <- scopeBundles scope]
      expected = Set.fromList ([serviceAddress, domainAddress] <> volumeAddresses)
      volumeSet = Set.fromList volumeAddresses
      validMember member =
        member ^. #owner == owner
          && ( if (member ^. #address) `Set.member` volumeSet
                 then case (member ^. #lifecycle, member ^. #dataPolicy) of
                   (Retain, Durable _) -> True
                   (DeleteWhenUnreferenced, Stateless) -> True
                   _ -> False
                 else
                   member ^. #lifecycle == DeleteWhenUnreferenced
                     && member ^. #dataPolicy == Stateless
             )
  unless
    ( length members == Set.size expected
        && declarationsCount == Set.size expected
        && Set.fromList (map (^. #address) members) == expected
        && all validMember members
    )
    (Left "accepted site preview has unexpected owned members or native addresses")
  pure owner

-- The full member set must match the established preview compiler contract;
-- a name prefix alone never grants recovery or collection authority.
previewScopeMembers :: ScopeDeclaration -> Either T.Text (ManagedResource, ManagedResource)
previewScopeMembers scope = do
  (service, cluster, namespace, serviceName) <- case [ (member, cluster, ns, native)
                                                     | member <- members
                                                     , Kubernetes cluster "serving.knative.dev" kind (Just ns) native <- [member ^. #address]
                                                     , nameText kind == "service"
                                                     ] of
    [one] -> Right one
    _ -> Left "preview requires exactly one Service"
  (route, host) <- case [ (member, host)
                        | member <- members
                        , Kubernetes _ "serving.knative.dev" kind _ host <- [member ^. #address]
                        , nameText kind == "domainmapping"
                        ] of
    [one] -> Right one
    _ -> Left "preview requires exactly one DomainMapping"
  volumes <-
    traverse
      (maybe (Left "preview volume differs from its Service") Right . T.stripPrefix ("nagare-vol-" <> nameText serviceName <> "-"))
      [ nameText claim
      | member <- members
      , Kubernetes _ "" kind _ claim <- [member ^. #address]
      , nameText kind == "persistentvolumeclaim"
      ]
  _ <- validatePreviewAddresses scope cluster (nameText serviceName) (nameText namespace) (nameText host) volumes
  pure (service, route)
  where
    members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
