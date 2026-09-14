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
  , validatePlatformAdoption
  , validatePlatformRepin
  , clusterMarkerValue
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Ops.Probe (Probe (..), ProbeStatus (..))
import Nagare.Platform.Deployment (DeploymentState (..), deploymentStateToken)
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
  { version :: !(Maybe Text)
  , revision :: !(Maybe Text)
  , payloadSchema :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

data PlatformStatus = PlatformStatus
  { cli :: !ReleaseIdentity
  , payload :: !ReleaseIdentity
  , context :: !ReleaseIdentity
  , host :: !ReleaseIdentity
  , hostDeployment :: !DeploymentState
  , cluster :: !ReleaseIdentity
  , clusterDeployment :: !DeploymentState
  , compatibility :: !Compatibility
  }
  deriving stock (Generic, Eq, Show)

identityFromBuild :: BuildVersion -> ReleaseIdentity
identityFromBuild build = ReleaseIdentity (Just (build ^. #version)) (build ^. #revision) Nothing

identityFromPayload :: PayloadManifest -> ReleaseIdentity
identityFromPayload manifest =
  ReleaseIdentity
    (Just (manifest ^. #platformVersion))
    (manifest ^. #sourceRevision)
    (Just (manifest ^. #assetSchemaVersion))

identityFromContext :: TargetProfile -> ReleaseIdentity
identityFromContext profile = ReleaseIdentity (profile ^. #platformVersion) Nothing Nothing

parseHostIdentity :: Text -> ReleaseIdentity
parseHostIdentity contents =
  ReleaseIdentity
    (commentValue "# Nagare platform version: ")
    (commentValue "# Nagare source revision: ")
    Nothing
  where
    -- EP-121: the generated flake indents these comments, so compare each line
    -- without its leading whitespace.
    commentValue prefix = do
      line <- find (T.isPrefixOf prefix) (map T.stripStart (T.lines contents))
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

assessPlatformStatus :: ReleaseIdentity -> ReleaseIdentity -> ReleaseIdentity -> ReleaseIdentity -> DeploymentState -> ReleaseIdentity -> DeploymentState -> PlatformStatus
assessPlatformStatus cli payload context host hostDeployment cluster clusterDeployment =
  PlatformStatus cli payload context host hostDeployment cluster clusterDeployment aggregate
  where
    expected = payload ^. #version >>= either (const Nothing) Just . parsePlatformVersion
    compareOne identity = case expected of
      Nothing -> LegacyUnknown
      Just expectedVersion -> comparePlatformVersions expectedVersion (identity ^. #version >>= either (const Nothing) Just . parsePlatformVersion)
    comparisons =
      map compareOne [cli, context]
        <> [compareOne host | hostDeployment /= NotDeployed]
        <> [compareOne cluster | clusterDeployment /= NotDeployed]
    aggregate
      | MajorIncompatible `elem` comparisons = MajorIncompatible
      | MinorUpgradeRequired `elem` comparisons = MinorUpgradeRequired
      | LegacyUnknown `elem` comparisons = LegacyUnknown
      | PatchSkew `elem` comparisons = PatchSkew
      | otherwise = Exact

platformStatusValue :: PlatformStatus -> Aeson.Value
platformStatusValue status =
  Aeson.object
    [ "cli" Aeson..= (status ^. #cli . #version)
    , "payload" Aeson..= (status ^. #payload . #version)
    , "context" Aeson..= (status ^. #context . #version)
    , "host" Aeson..= (status ^. #host . #version)
    , "cluster" Aeson..= (status ^. #cluster . #version)
    , "compatibility" Aeson..= compatibilityToken (status ^. #compatibility)
    , "deployment"
        Aeson..= Aeson.object
          [ "host" Aeson..= deploymentValue (status ^. #hostDeployment)
          , "cluster" Aeson..= deploymentValue (status ^. #clusterDeployment)
          ]
    , "identities"
        Aeson..= Aeson.object
          [ "cli" Aeson..= identityValue (status ^. #cli)
          , "payload" Aeson..= identityValue (status ^. #payload)
          , "context" Aeson..= identityValue (status ^. #context)
          , "host" Aeson..= identityValue (status ^. #host)
          , "cluster" Aeson..= identityValue (status ^. #cluster)
          ]
    ]
  where
    identityValue identity =
      Aeson.object
        [ "version" Aeson..= (identity ^. #version)
        , "revision" Aeson..= (identity ^. #revision)
        , "payloadSchema" Aeson..= (identity ^. #payloadSchema)
        ]
    deploymentValue deployment =
      Aeson.object
        [ "state" Aeson..= deploymentStateToken deployment
        , "error" Aeson..= deploymentError deployment
        ]
    deploymentError (DeploymentUnknown err) = Just err
    deploymentError _ = Nothing

renderPlatformStatus :: Text -> PlatformStatus -> Text
renderPlatformStatus contextName status =
  T.unlines
    [ "Nagare platform status (context " <> contextName <> ")"
    , renderLine "CLI" (status ^. #cli)
    , renderLine "Payload" (status ^. #payload)
    , renderLine "Context" (status ^. #context)
    , renderResourceLine "Host" (status ^. #host) (status ^. #hostDeployment)
    , renderResourceLine "Cluster" (status ^. #cluster) (status ^. #clusterDeployment)
    , "Compatibility: " <> compatibilityToken (status ^. #compatibility)
    ]
  where
    renderLine label identity = pad 12 (label <> ":") <> maybe "legacy / unknown" (\value -> value) (identity ^. #version)
    renderResourceLine label _ NotDeployed = pad 12 (label <> ":") <> "not deployed"
    renderResourceLine label identity _ = renderLine label identity
    pad width value = value <> T.replicate (max 1 (width - T.length value)) " "

platformProbe :: PlatformStatus -> Probe
platformProbe status = case status ^. #compatibility of
  Exact -> Probe "platform version" StatusOk "CLI, payload, context, host, and cluster agree"
  PatchSkew -> Probe "platform version" StatusWarn "patch release skew; inspection and compatible mutation remain available"
  MinorUpgradeRequired -> Probe "platform version" StatusFail "minor release skew requires `nagarectl platform upgrade`"
  MajorIncompatible -> Probe "platform version" StatusFail "major release mismatch blocks platform mutation"
  LegacyUnknown -> Probe "platform version" StatusWarn "one or more release identities are legacy, absent, or unreachable"

guardPlatformMutation :: PlatformStatus -> Either Text ()
guardPlatformMutation status = case status ^. #compatibility of
  MajorIncompatible -> Left "major platform-version mismatch; inspect `nagarectl platform status` and run an explicit upgrade"
  MinorUpgradeRequired -> Left "minor platform-version skew requires `nagarectl platform upgrade` before platform mutation"
  _ -> Right ()

-- | Validate the observations shown before a legacy context is assigned its
-- first explicit release. Unknown host or cluster identities are permitted:
-- adoption stamps the cluster marker, while a legacy host may not carry
-- generated release comments yet. Any identity that is present must agree
-- exactly so adoption cannot disguise real release skew as missing metadata.
validatePlatformAdoption :: Text -> PlatformStatus -> Either Text ()
validatePlatformAdoption target status
  | status ^. #context . #version /= Nothing =
      Left "the selected context already has a platform version; use `nagarectl platform upgrade`"
  | status ^. #payload . #version /= Just target =
      Left ("the active payload reports " <> observed (status ^. #payload) <> ", not requested version " <> target)
  | otherwise = mapM_ requireMatch observations
  where
    observations =
      [ ("CLI", status ^. #cli)
      , ("host", status ^. #host)
      , ("cluster", status ^. #cluster)
      ]
    requireMatch (_, ReleaseIdentity Nothing _ _) = Right ()
    requireMatch (label, identity)
      | identity ^. #version == Just target = Right ()
      | otherwise = Left ("observed " <> label <> " version " <> observed identity <> " does not match requested adoption " <> target)
    observed identity = maybe "legacy / unknown" (\value -> value) (identity ^. #version)

-- | A release pin may be rewritten only while authoritative cloud evidence says
-- the context's single host, and therefore its cluster, have never been deployed.
validatePlatformRepin :: Text -> PlatformStatus -> Either Text ()
validatePlatformRepin target status
  | status ^. #context . #version == Nothing =
      Left "the selected context is legacy and has no release pin; use `nagarectl platform adopt`"
  | status ^. #payload . #version /= Just target =
      Left ("the active payload does not match requested re-pin " <> target)
  | status ^. #hostDeployment /= NotDeployed =
      Left "refusing to re-pin: the context's GCE instance exists or its absence could not be proven"
  | status ^. #clusterDeployment /= NotDeployed =
      Left "refusing to re-pin: cluster absence could not be proven"
  | status ^. #cluster . #version /= Nothing =
      Left "refusing to re-pin: a cluster release identity was observed"
  | otherwise = Right ()

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
          ( [ "version" Aeson..= maybe "" (\value -> value) (identity ^. #version)
            , "revision" Aeson..= maybe "" (\value -> value) (identity ^. #revision)
            , "payloadSchema" Aeson..= maybe "" (T.pack . show) (identity ^. #payloadSchema)
            , "installedAt" Aeson..= installedAt
            ]
          )
    ]
