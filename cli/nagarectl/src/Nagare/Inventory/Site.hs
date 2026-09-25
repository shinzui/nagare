-- | Bind production site renders and release history to independent scopes.
-- Image publication is an accepted dependency; building the image remains a
-- separate publication operation.
module Nagare.Inventory.Site
  ( compileStaticSiteScope
  , compileServerSiteScope
  , acceptedSiteReleaseLog
  , legacyServerSiteReleaseImport
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
import Nagare.Dsl.Server.Types (ServerSite (..))
import Nagare.Dsl.Static.Types (StaticSite (..), siteNameText)
import Nagare.Dsl.Types (DomainSpec (..), DomainTls (..), EnvVar (..), ScopedEnvVar (..), domainText, imageRefText, namespaceText)
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
import Nagare.Server.Deploy qualified as Server
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
  compileSiteRenderedScope name ns (site ^. #domains)
    (rendered ^. #service) (rendered ^. #domainMappings)
    cluster namespaceId imageId prior release source

-- | Server sites share the site ownership and release protocol. The initial
-- supported subset excludes durable volumes and Secret references until their
-- typed recovery and credential dependencies join this scope.
compileServerSiteScope
  :: Server.ServerDeployInputs -> ResourceId -> ResourceId -> ResourceId
  -> StaticReleaseLog -> StaticRelease -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteScope inputs cluster namespaceId imageId prior release source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      tag = inputs ^. #imageTag
      rendered = Server.serverManifests inputs
      invalid message = inventoryError "invalid-server-site-scope" message
        & #sources .~ [source] & (:| [])
  unless (null (site ^. #volumes))
    (Left (invalid "server-site volumes require typed recovery bindings"))
  unless (site ^. #cdn == Nothing)
    (Left (invalid "server-site CDN requires a typed owner"))
  unless (all ((== AutomaticTls) . (^. #tls)) (site ^. #domains))
    (Left (invalid "supplied TLS requires an accepted Secret dependency"))
  unless (all (\entry -> case entry ^. #value of
      EnvSecretRef _ -> False
      _ -> True) (Map.elems (site ^. #env)))
    (Left (invalid "server-site Secret environment requires typed dependencies"))
  unless (release ^. #releaseId == tag && release ^. #imageTag == tag
      && release ^. #image == imageRefText (site ^. #image)
      && release ^. #siteName == name && release ^. #namespace == ns
      && release ^. #url == rendered ^. #url)
    (Left (invalid "server-site release differs from its selected image or render"))
  unless (validLog name ns prior)
    (Left (invalid "server-site prior release history is inconsistent"))
  compileSiteRenderedScope name ns (site ^. #domains)
    (rendered ^. #service) (rendered ^. #domainMappings)
    cluster namespaceId imageId prior release source

compileSiteRenderedScope
  :: T.Text -> T.Text -> [DomainSpec] -> ByteString -> [ByteString]
  -> ResourceId -> ResourceId -> ResourceId
  -> StaticReleaseLog -> StaticRelease -> SourceLocation
  -> Either (NonEmpty InventoryError)
       (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileSiteRenderedScope name ns domains serviceBytes domainBytes
    cluster namespaceId imageId prior release source = do
  let invalid message = inventoryError "invalid-site-scope" message
        & #sources .~ [source] & (:| [])
  owner <- first invalid (mkScopeId Standalone ("site-" <> name))
  serviceKey <- first invalid (mkLogicalKey name)
  serviceRole <- first invalid (mkName "service")
  releaseKey <- first invalid (mkLogicalKey "release-history")
  releaseRole <- first invalid (mkName "configmap")
  let serviceId = mintResourceId owner serviceKey serviceRole
      historyId = mintResourceId owner releaseKey releaseRole
      serviceSource = source {path = path source <> "/service"}
  serviceMember <- bindOne owner cluster serviceId DeleteWhenUnreferenced
    [OrderedAfter namespaceId, OrderedAfter imageId] serviceSource
    serviceBytes
  checkAddress invalid cluster "serving.knative.dev/v1" "Service" ns name serviceMember
  unless (length domains == length domainBytes)
    (Left (invalid "site domain renderer changed membership"))
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
    (Left (invalid "site members share a resource identity"))
  scope <- mkScopeDeclaration owner
    [ResourceBundle (map (Managed . fst) members) [] [] [] [] []]
  pure (scope, native)

acceptedSiteReleaseLog
  :: ScopeSnapshot -> Map ResourceId (ManagedResource, ByteString)
  -> T.Text -> T.Text -> ResourceId -> Either T.Text StaticReleaseLog
acceptedSiteReleaseLog snapshot native name ns cluster = do
  owner <- first id (mkScopeId Standalone ("site-" <> name))
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
          (Left "accepted site release has a different address")
        (bound, bytes) <- maybe (Left "accepted site release lacks private native bytes")
          Right (Map.lookup historyId native)
        unless (bound == resource)
          (Left "accepted site release differs from private binding")
        logv <- extractReleaseLog bytes
        unless (validLog name ns logv)
          (Left "accepted site release history is inconsistent")
        pure logv
      [] -> Left "accepted site scope lacks release history"
      _ -> Left "accepted site scope has duplicate release history"

-- | Keep the old site's log byte-for-byte stable in the candidate before
-- submitting its live ConfigMap to the exact-incarnation adoption decision.
legacyStaticSiteReleaseImport
  :: StaticSite -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacyStaticSiteReleaseImport site =
  legacySiteReleaseImport (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace)) (imageRefText (site ^. #image))

legacyServerSiteReleaseImport
  :: ServerSite -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacyServerSiteReleaseImport site =
  legacySiteReleaseImport (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace)) (imageRefText (site ^. #image))

legacySiteReleaseImport
  :: T.Text -> T.Text -> T.Text -> T.Text -> ByteString
  -> Either T.Text (StaticReleaseLog, StaticRelease)
legacySiteReleaseImport name ns expectedImage tag bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  metadata <- case value of
    Object fields
      | KM.lookup "apiVersion" fields == Just (String "v1")
      , KM.lookup "kind" fields == Just (String "ConfigMap")
      , Just (Object meta) <- KM.lookup "metadata" fields -> Right meta
    _ -> Left "legacy site release is not a v1 ConfigMap"
  unless (KM.lookup "name" metadata == Just (String ("nagare-static-releases-" <> name))
      && KM.lookup "namespace" metadata == Just (String ns))
    (Left "legacy site release has a different name or namespace")
  logv <- extractReleaseLog bytes
  unless (validLog name ns logv)
    (Left "legacy site release history is inconsistent")
  currentId <- maybe (Left "legacy site release has no current tag") Right
    (logv ^. #current)
  currentRelease <- maybe (Left "legacy site release has no current record") Right
    (findRelease currentId logv)
  unless (currentRelease ^. #releaseId == tag
      && currentRelease ^. #imageTag == tag
      && currentRelease ^. #image == expectedImage)
    (Left "legacy site release differs from the selected image or tag")
  unless (addRelease currentRelease logv == logv)
    (Left "legacy site release history would change during import")
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
  let invalid message = inventoryError "invalid-site-member" message
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
    (Left (invalid "site render has an unexpected native address"))
