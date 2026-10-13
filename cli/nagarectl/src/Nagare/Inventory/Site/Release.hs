-- | Site release history: the accepted log, the source root a rollback
-- reuses, and the byte-stable import of a legacy release ConfigMap.
module Nagare.Inventory.Site.Release
  ( SiteReleaseAction (..)
  , acceptedSiteReleaseLog
  , acceptedSiteSource
  , legacyServerSiteReleaseImport
  , legacyStaticSiteReleaseImport
  , siteReleaseHistory
  , validLog
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite (..))
import Nagare.Dsl.Static.Types (StaticSite (..), siteNameText)
import Nagare.Dsl.Types (imageRefText, namespaceText)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), addRelease, emptyReleaseLog, extractReleaseLog, findRelease)

data SiteReleaseAction = RecordRelease | SelectRelease

siteReleaseHistory ::
  SiteReleaseAction ->
  StaticReleaseLog ->
  StaticRelease ->
  Either T.Text StaticReleaseLog
siteReleaseHistory RecordRelease prior release = Right (addRelease release prior)
siteReleaseHistory SelectRelease prior release = do
  unless
    (findRelease (release ^. #releaseId) prior == Just release)
    (Left "selected site release is absent or differs from accepted history")
  pure (prior {current = Just (release ^. #releaseId)})

acceptedSiteReleaseLog ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  T.Text ->
  T.Text ->
  ResourceId ->
  Either T.Text StaticReleaseLog
acceptedSiteReleaseLog snapshot native name ns cluster = do
  owner <- first id (mkScopeId Standalone ("site-" <> name))
  key <- first id (mkLogicalKey "release-history")
  role <- first id (mkName "configmap")
  let historyId = mintResourceId owner key role
  expected <-
    kubernetesAddress
      cluster
      "v1"
      "ConfigMap"
      (Just ns)
      ("nagare-static-releases-" <> name)
  case Map.lookup owner (snapshotScopes snapshot) of
    Nothing -> Right emptyReleaseLog
    Just (_, scope) -> case [ resource
                            | bundle <- scopeBundles scope
                            , Managed resource <- declarations bundle
                            , resource ^. #identity == historyId
                            ] of
      [resource] -> do
        unless
          (resource ^. #address == expected)
          (Left "accepted site release has a different address")
        (bound, bytes) <-
          maybe
            (Left "accepted site release lacks private native bytes")
            Right
            (Map.lookup historyId native)
        unless
          (bound == resource)
          (Left "accepted site release differs from private binding")
        logv <- extractReleaseLog bytes
        unless
          (validLog name ns logv)
          (Left "accepted site release history is inconsistent")
        pure logv
      [] -> Left "accepted site scope lacks release history"
      _ -> Left "accepted site scope has duplicate release history"

-- | Reuse the accepted source root when reviewing a rollback. Recompilation
-- should only change the selected workload image and history pointer.
acceptedSiteSource ::
  ScopeSnapshot ->
  T.Text ->
  T.Text ->
  ResourceId ->
  Either T.Text SourceLocation
acceptedSiteSource snapshot name ns cluster = do
  owner <- mkScopeId Standalone ("site-" <> name)
  key <- mkLogicalKey name
  role <- mkName "service"
  expected <-
    kubernetesAddress
      cluster
      "serving.knative.dev/v1"
      "Service"
      (Just ns)
      name
  let serviceId = mintResourceId owner key role
  (_, scope) <-
    maybe
      (Left "accepted site scope is absent")
      Right
      (Map.lookup owner (snapshotScopes snapshot))
  resource <- case [ member
                   | bundle <- scopeBundles scope
                   , Managed member <- declarations bundle
                   , member ^. #identity == serviceId
                   ] of
    [member] -> Right member
    _ -> Left "accepted site scope lacks one Service member"
  unless
    (resource ^. #address == expected)
    (Left "accepted site Service has a different address")
  basePath <-
    maybe
      (Left "accepted site Service lacks its source root")
      Right
      (T.stripSuffix "/service" (path (resource ^. #source)))
  pure ((resource ^. #source) {path = basePath})

-- | Keep the old site's log byte-for-byte stable in the candidate before
-- submitting its live ConfigMap to the exact-incarnation adoption decision.
legacyStaticSiteReleaseImport ::
  StaticSite ->
  T.Text ->
  ByteString ->
  Either T.Text (StaticReleaseLog, StaticRelease)
legacyStaticSiteReleaseImport site =
  legacySiteReleaseImport
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))

legacyServerSiteReleaseImport ::
  ServerSite ->
  T.Text ->
  ByteString ->
  Either T.Text (StaticReleaseLog, StaticRelease)
legacyServerSiteReleaseImport site =
  legacySiteReleaseImport
    (siteNameText (site ^. #name))
    (namespaceText (site ^. #namespace))
    (imageRefText (site ^. #image))

legacySiteReleaseImport ::
  T.Text ->
  T.Text ->
  T.Text ->
  T.Text ->
  ByteString ->
  Either T.Text (StaticReleaseLog, StaticRelease)
legacySiteReleaseImport name ns expectedImage tag bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  metadata <- case value of
    Object fields
      | KM.lookup "apiVersion" fields == Just (String "v1")
      , KM.lookup "kind" fields == Just (String "ConfigMap")
      , Just (Object meta) <- KM.lookup "metadata" fields ->
          Right meta
    _ -> Left "legacy site release is not a v1 ConfigMap"
  unless
    ( KM.lookup "name" metadata == Just (String ("nagare-static-releases-" <> name))
        && KM.lookup "namespace" metadata == Just (String ns)
    )
    (Left "legacy site release has a different name or namespace")
  logv <- extractReleaseLog bytes
  unless
    (validLog name ns logv)
    (Left "legacy site release history is inconsistent")
  currentId <-
    maybe
      (Left "legacy site release has no current tag")
      Right
      (logv ^. #current)
  currentRelease <-
    maybe
      (Left "legacy site release has no current record")
      Right
      (findRelease currentId logv)
  unless
    ( currentRelease ^. #releaseId == tag
        && currentRelease ^. #imageTag == tag
        && currentRelease ^. #image == expectedImage
    )
    (Left "legacy site release differs from the selected image or tag")
  unless
    (addRelease currentRelease logv == logv)
    (Left "legacy site release history would change during import")
  pure (logv, currentRelease)

validLog :: T.Text -> T.Text -> StaticReleaseLog -> Bool
validLog name ns logv =
  let entries = logv ^. #releases
      ids = map (^. #releaseId) entries
   in length ids == Set.size (Set.fromList ids)
        && all (\entry -> entry ^. #siteName == name && entry ^. #namespace == ns) entries
        && maybe (null entries) (`elem` ids) (logv ^. #current)
