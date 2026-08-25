{-# LANGUAGE OverloadedStrings #-}

-- | Observe and compare every release identity involved in platform operations.
module Nagare.Platform.Status
  ( ReleaseIdentity (..)
  , PlatformStatus (..)
  , identityFromBuild
  , identityFromPayload
  , identityFromContext
  , parseHostIdentity
  , parseClusterIdentity
  , assessPlatformStatus
  , platformStatusValue
  , renderPlatformStatus
  , platformProbe
  , guardPlatformMutation
  , clusterMarkerValue
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))
import Nagare.Platform.Workspace (PayloadManifest (..))
import Nagare.Target (TargetProfile (..))
import Nagare.Version
  ( BuildVersion (..)
  , Compatibility (..)
  , comparePlatformVersions
  , compatibilityToken
  , parsePlatformVersion
  )

data ReleaseIdentity = ReleaseIdentity
  { identityVersion :: !(Maybe Text)
  , identityRevision :: !(Maybe Text)
  , identityPayloadSchema :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data PlatformStatus = PlatformStatus
  { statusCli :: !ReleaseIdentity
  , statusPayload :: !ReleaseIdentity
  , statusContext :: !ReleaseIdentity
  , statusHost :: !ReleaseIdentity
  , statusCluster :: !ReleaseIdentity
  , statusCompatibility :: !Compatibility
  }
  deriving stock (Eq, Show)

identityFromBuild :: BuildVersion -> ReleaseIdentity
identityFromBuild build = ReleaseIdentity (Just (versionText build)) (revisionText build) Nothing

identityFromPayload :: PayloadManifest -> ReleaseIdentity
identityFromPayload manifest =
  ReleaseIdentity
    (Just (pmPlatformVersion manifest))
    (pmSourceRevision manifest)
    (Just (pmAssetSchemaVersion manifest))

identityFromContext :: TargetProfile -> ReleaseIdentity
identityFromContext profile = ReleaseIdentity (tpPlatformVersion profile) Nothing Nothing

parseHostIdentity :: Text -> ReleaseIdentity
parseHostIdentity contents =
  ReleaseIdentity
    (commentValue "# Nagare platform version: ")
    (commentValue "# Nagare source revision: ")
    Nothing
  where
    commentValue prefix = do
      line <- find (T.isPrefixOf prefix) (T.lines contents)
      let value = T.strip (T.drop (T.length prefix) line)
      if T.null value || value == "unknown" then Nothing else Just value

parseClusterIdentity :: ByteString -> Maybe ReleaseIdentity
parseClusterIdentity bytes = do
  Aeson.Object root <- Aeson.decodeStrict' bytes
  Aeson.Object dat <- KeyMap.lookup "data" root
  let textValue key = case KeyMap.lookup key dat of
        Just (Aeson.String value) | not (T.null (T.strip value)) -> Just value
        _ -> Nothing
      intValue key = textValue key >>= readInt
  pure (ReleaseIdentity (textValue "version") (textValue "revision") (intValue "payloadSchema"))
  where
    readInt value = case reads (T.unpack value) of
      [(number, "")] -> Just number
      _ -> Nothing

assessPlatformStatus :: ReleaseIdentity -> ReleaseIdentity -> ReleaseIdentity -> ReleaseIdentity -> ReleaseIdentity -> PlatformStatus
assessPlatformStatus cli payload context host cluster =
  PlatformStatus cli payload context host cluster aggregate
  where
    expected = identityVersion payload >>= either (const Nothing) Just . parsePlatformVersion
    compareOne identity = case expected of
      Nothing -> LegacyUnknown
      Just version -> comparePlatformVersions version (identityVersion identity >>= either (const Nothing) Just . parsePlatformVersion)
    comparisons = map compareOne [cli, context, host, cluster]
    aggregate
      | MajorIncompatible `elem` comparisons = MajorIncompatible
      | MinorUpgradeRequired `elem` comparisons = MinorUpgradeRequired
      | LegacyUnknown `elem` comparisons = LegacyUnknown
      | PatchSkew `elem` comparisons = PatchSkew
      | otherwise = Exact

platformStatusValue :: PlatformStatus -> Aeson.Value
platformStatusValue status =
  Aeson.object
    [ "cli" Aeson..= identityVersion (statusCli status)
    , "payload" Aeson..= identityVersion (statusPayload status)
    , "context" Aeson..= identityVersion (statusContext status)
    , "host" Aeson..= identityVersion (statusHost status)
    , "cluster" Aeson..= identityVersion (statusCluster status)
    , "compatibility" Aeson..= compatibilityToken (statusCompatibility status)
    , "identities"
        Aeson..= Aeson.object
          [ "cli" Aeson..= identityValue (statusCli status)
          , "payload" Aeson..= identityValue (statusPayload status)
          , "context" Aeson..= identityValue (statusContext status)
          , "host" Aeson..= identityValue (statusHost status)
          , "cluster" Aeson..= identityValue (statusCluster status)
          ]
    ]
  where
    identityValue identity =
      Aeson.object
        [ "version" Aeson..= identityVersion identity
        , "revision" Aeson..= identityRevision identity
        , "payloadSchema" Aeson..= identityPayloadSchema identity
        ]

renderPlatformStatus :: Text -> PlatformStatus -> Text
renderPlatformStatus contextName status =
  T.unlines
    [ "Nagare platform status (context " <> contextName <> ")"
    , renderLine "CLI" (statusCli status)
    , renderLine "Payload" (statusPayload status)
    , renderLine "Context" (statusContext status)
    , renderLine "Host" (statusHost status)
    , renderLine "Cluster" (statusCluster status)
    , "Compatibility: " <> compatibilityToken (statusCompatibility status)
    ]
  where
    renderLine label identity = pad 12 (label <> ":") <> maybe "legacy / unknown" id (identityVersion identity)
    pad width value = value <> T.replicate (max 1 (width - T.length value)) " "

platformProbe :: PlatformStatus -> Probe
platformProbe status = case statusCompatibility status of
  Exact -> Probe "platform version" StatusOk "CLI, payload, context, host, and cluster agree"
  PatchSkew -> Probe "platform version" StatusWarn "patch release skew; inspection and compatible mutation remain available"
  MinorUpgradeRequired -> Probe "platform version" StatusFail "minor release skew requires `nagarectl platform upgrade`"
  MajorIncompatible -> Probe "platform version" StatusFail "major release mismatch blocks platform mutation"
  LegacyUnknown -> Probe "platform version" StatusWarn "one or more release identities are legacy, absent, or unreachable"

guardPlatformMutation :: PlatformStatus -> Either Text ()
guardPlatformMutation status = case statusCompatibility status of
  MajorIncompatible -> Left "major platform-version mismatch; inspect `nagarectl platform status` and run an explicit upgrade"
  MinorUpgradeRequired -> Left "minor platform-version skew requires `nagarectl platform upgrade` before platform mutation"
  _ -> Right ()

clusterMarkerValue :: ReleaseIdentity -> Text -> Aeson.Value
clusterMarkerValue identity installedAt =
  Aeson.object
    [ "apiVersion" Aeson..= ("v1" :: Text)
    , "kind" Aeson..= ("ConfigMap" :: Text)
    , "metadata"
        Aeson..= Aeson.object
          [ "name" Aeson..= ("nagare-platform-version" :: Text)
          , "namespace" Aeson..= ("nagare-system" :: Text)
          , "labels" Aeson..= Aeson.object ["app.kubernetes.io/managed-by" Aeson..= ("nagarectl" :: Text)]
          ]
    , "data"
        Aeson..= Aeson.object
          ( [ "version" Aeson..= maybe "" id (identityVersion identity)
            , "revision" Aeson..= maybe "" id (identityRevision identity)
            , "payloadSchema" Aeson..= maybe "" (T.pack . show) (identityPayloadSchema identity)
            , "installedAt" Aeson..= installedAt
            ]
          )
    ]
