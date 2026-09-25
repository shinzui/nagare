-- | Bind the production static-site render and release history to one scope.
-- Image publication is an accepted dependency; building the image remains a
-- separate publication operation.
module Nagare.Inventory.Site
  ( compileStaticSiteScope
  , acceptedStaticSiteReleaseLog
  , legacyStaticSiteReleaseImport
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticSite (..), siteNameText)
import Nagare.Dsl.Types (DomainSpec (..), DomainTls (..), domainText, imageRefText, namespaceText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (domainMappingResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (..), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Deploy (DeployInputs (..), StaticManifests (..), productionManifests)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), addRelease, emptyReleaseLog, extractReleaseLog, findRelease, renderReleaseConfigMap)

compileStaticSiteScope
  :: DeployInputs -> ResourceId -> ResourceId -> ResourceId
  -> StaticReleaseLog -> StaticRelease -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteScope inputs cluster namespaceId imageId prior release source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      tag = inputs ^. #imageTag
      rendered = productionManifests inputs
      invalid message = inventoryError "invalid-static-site-scope" message
        & #sources .~ [source] & (:| [])
  unless (site ^. #cdn == Nothing)
    (Left (invalid "static-site CDN requires a typed owner"))
  unless (all ((== AutomaticTls) . (^. #tls)) (site ^. #domains))
    (Left (invalid "supplied TLS requires an accepted Secret dependency"))
  unless (release ^. #releaseId == tag && release ^. #imageTag == tag
      && release ^. #image == imageRefText (site ^. #image)
      && release ^. #siteName == name && release ^. #namespace == ns
      && release ^. #url == rendered ^. #url)
    (Left (invalid "static-site release differs from its selected image or render"))
  unless (validLog name ns prior)
    (Left (invalid "static-site prior release history is inconsistent"))
  owner <- first invalid (mkScopeId Application ("site-" <> name))
  serviceKey <- first invalid (mkLogicalKey name)
  serviceRole <- first invalid (mkName "service")
  releaseKey <- first invalid (mkLogicalKey "release-history")
  releaseRole <- first invalid (mkName "configmap")
  let serviceId = mintResourceId owner serviceKey serviceRole
      historyId = mintResourceId owner releaseKey releaseRole
      serviceSource = source {path = path source <> "/service"}
  serviceMember <- bindOne owner cluster serviceId DeleteWhenUnreferenced
    [OrderedAfter namespaceId, OrderedAfter imageId] serviceSource
    (rendered ^. #service)
  checkAddress invalid cluster "serving.knative.dev/v1" "Service" ns name serviceMember
  let domains = site ^. #domains
      domainBytes = rendered ^. #domainMappings
  unless (length domains == length domainBytes)
    (Left (invalid "static-site domain renderer changed membership"))
  domainMembers <- traverse (\(domain, bytes) -> do
      domainId <- first invalid (domainMappingResourceId owner domain)
      host <- first invalid (mkName (domainText (domain ^. #domain)))
      let domainSource = source {path = path source <> "/domain/" <> domainText (domain ^. #domain)}
      member <- bindOne owner cluster domainId DeleteWhenUnreferenced
        [OrderedAfter namespaceId, OrderedAfter serviceId] domainSource bytes
      checkAddress invalid cluster "serving.knative.dev/v1beta1" "DomainMapping"
        ns (domainText (domain ^. #domain)) member
      pure (first (\resource -> resource {aliases = [Hostname host]}) member))
    (zip domains domainBytes)
  let historyBytes = renderReleaseConfigMap name ns (addRelease release prior)
      historySource = source {path = path source <> "/release-history"}
      workloadIds = serviceId : map ((^. #identity) . fst) domainMembers
  historyMember <- bindOne owner cluster historyId Retain
    (map OrderedAfter (namespaceId : imageId : workloadIds))
    historySource historyBytes
  checkAddress invalid cluster "v1" "ConfigMap" ns
    ("nagare-static-releases-" <> name) historyMember
  let members = serviceMember : domainMembers <> [historyMember]
      ids = map ((^. #identity) . fst) members
      native = Map.fromList [(resource ^. #identity, (resource, bytes))
        | (resource, bytes) <- members]
  unless (length ids == Set.size (Set.fromList ids))
    (Left (invalid "static-site members share a resource identity"))
  scope <- mkScopeDeclaration owner
    [ResourceBundle (map (Managed . fst) members) [] [] [] [] []]
  pure (scope, native)

acceptedStaticSiteReleaseLog
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> T.Text -> T.Text -> ResourceId -> Either T.Text StaticReleaseLog
acceptedStaticSiteReleaseLog snapshot native name ns cluster = do
  owner <- first id (mkScopeId Application ("site-" <> name))
  key <- first id (mkLogicalKey "release-history")
  role <- first id (mkName "configmap")
  let historyId = mintResourceId owner key role
  expected <- kubernetesAddress cluster "v1" "ConfigMap"
    (Just ns) ("nagare-static-releases-" <> name)
  case Map.lookup owner (snapshotScopes snapshot) of
    Nothing -> Right emptyReleaseLog
    Just (_, scope) -> case [resource | bundle <- scopeBundles scope,
        Managed resource <- declarations bundle,
        resource ^. #identity == historyId] of
      [resource] -> do
        unless (resource ^. #address == expected)
          (Left "accepted static-site release has a different address")
        (bound, bytes) <- maybe (Left "accepted static-site release lacks private native bytes")
          Right (Map.lookup historyId native)
        unless (bound == resource)
          (Left "accepted static-site release differs from private binding")
        logv <- extractReleaseLog bytes
        unless (validLog name ns logv)
          (Left "accepted static-site release history is inconsistent")
        pure logv
      [] -> Left "accepted static-site scope lacks release history"
      _ -> Left "accepted static-site scope has duplicate release history"

-- | Keep the old site's log byte-for-byte stable in the candidate before
-- submitting its live ConfigMap to the exact-incarnation adoption decision.
legacyStaticSiteReleaseImport
  :: StaticSite -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacyStaticSiteReleaseImport site tag bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  let name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
  metadata <- case value of
    Object fields
      | KM.lookup "apiVersion" fields == Just (String "v1")
      , KM.lookup "kind" fields == Just (String "ConfigMap")
      , Just (Object meta) <- KM.lookup "metadata" fields -> Right meta
    _ -> Left "legacy static-site release is not a v1 ConfigMap"
  unless (KM.lookup "name" metadata == Just (String ("nagare-static-releases-" <> name))
      && KM.lookup "namespace" metadata == Just (String ns))
    (Left "legacy static-site release has a different name or namespace")
  logv <- extractReleaseLog bytes
  unless (validLog name ns logv)
    (Left "legacy static-site release history is inconsistent")
  currentId <- maybe (Left "legacy static-site release has no current tag") Right
    (logv ^. #current)
  currentRelease <- maybe (Left "legacy static-site release has no current record") Right
    (findRelease currentId logv)
  unless (currentRelease ^. #releaseId == tag
      && currentRelease ^. #imageTag == tag
      && currentRelease ^. #image == imageRefText (site ^. #image))
    (Left "legacy static-site release differs from the selected image or tag")
  unless (addRelease currentRelease logv == logv)
    (Left "legacy static-site release history would change during import")
  pure (logv, currentRelease)

validLog :: T.Text -> T.Text -> StaticReleaseLog -> Bool
validLog name ns logv =
  let entries = logv ^. #releases
      ids = map (^. #releaseId) entries
  in length ids == Set.size (Set.fromList ids)
      && all (\entry -> entry ^. #siteName == name && entry ^. #namespace == ns) entries
      && maybe (null entries) (`elem` ids) (logv ^. #current)

bindOne
  :: ScopeId -> ResourceId -> ResourceId -> LifecyclePolicy -> [Dependency]
  -> SourceLocation -> ByteString
  -> Either (NonEmpty InventoryError) (ManagedResource, ByteString)
bindOne owner cluster resourceId lifecycle prerequisites source bytes = do
  let invalid message = inventoryError "invalid-static-site-member" message
        & #sources .~ [source] & (:| [])
  value <- first (invalid . T.pack . show)
    (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
  canonical <- first invalid (canonicalValue value)
  (resource, native) <- first (:| []) (bindKubernetesObject KubernetesInput
    { resourceId = resourceId
    , ownerScope = owner
    , clusterId = cluster
    , inputObject = value
    , objectDigest = contentDigest canonical
    , lifecyclePolicy = lifecycle
    , inputDataPolicy = Stateless
    , inputSensitivity = Private
    , sourceLocation = source
    })
  pure (resource {dependencies = prerequisites}, native)

checkAddress
  :: (T.Text -> NonEmpty InventoryError) -> ResourceId
  -> T.Text -> T.Text -> T.Text -> T.Text
  -> (ManagedResource, ByteString) -> Either (NonEmpty InventoryError) ()
checkAddress invalid cluster version kind ns name (resource, _) = do
  expected <- first invalid (kubernetesAddress cluster version kind (Just ns) name)
  unless (resource ^. #address == expected)
    (Left (invalid "static-site render has an unexpected native address"))
