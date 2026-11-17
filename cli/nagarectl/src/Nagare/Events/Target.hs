{-# LANGUAGE OverloadedStrings #-}

-- | The active context's lifecycle feed (EP-231 M3). The feed lives beside
-- the inventory store, in the same backend: a location ending in
-- @/inventory@ becomes @/lifecycle/v1@, any other gets @-lifecycle/v1@
-- appended. Inventory listings cover @root/@ only, so they never reach it.
-- Readers open it read-only: a put is refused before any request.
module Nagare.Events.Target
  ( feedLocation
  , targetBinding
  , openTargetFeedReadOnly
  , openTargetFeed
  , openTargetLifecycle
  , readOnlyFeedOps
  , targetBackupReader
  , targetSigningKey
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Dsl.Prelude
import Nagare.Events.Backup (SigningRef (..))
import Nagare.Events.Store
import Nagare.Inventory.ScheduledStore (VersionedReader, readSecretField, readSecretFieldWithUid)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.ObjectTarget (forwardedReach, kubectlForward, objectInventoryStoreUrl, objectStoreOps)
import Nagare.Inventory.Store.Remote (remoteBackupReader, remoteObjectOps)
import Nagare.Inventory.Store.S3 (S3Credentials (..), s3HttpTransport, s3VersionedReader)
import Nagare.Inventory.Store.Target (remoteInventoryUrl)
import Nagare.Resource.Types
import Nagare.Target
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | The feed's location beside an inventory location (a path or URL).
feedLocation :: Text -> Text
feedLocation inventory = case T.stripSuffix "/inventory" trimmed of
  Just parent -> parent <> "/lifecycle/v1"
  Nothing -> trimmed <> "-lifecycle/v1"
  where
    trimmed = T.dropWhileEnd (== '/') inventory

-- | The context binding a target's stores carry.
targetBinding :: ActiveTarget -> Either Text ContextBinding
targetBinding target =
  ContextBinding
    <$> mkContextId (contextNameText (target ^. #contextName))
    <*> mkName (target ^. #profile . #project)

-- | The active context's feed, through its inventory backend, read-only.
openTargetFeedReadOnly :: ActiveTarget -> IO (Either Text FeedStore)
openTargetFeedReadOnly target = openFeedOps target >>= traverse (newFeedStore . readOnlyFeedOps)

-- | The active context's feed, writable: only a command that publishes
-- lifecycle state (@events collect-backups@) opens it so.
openTargetFeed :: ActiveTarget -> IO (Either Text FeedStore)
openTargetFeed target = openFeedOps target >>= traverse newFeedStore

-- | The context's lifecycle location as plain object operations, which
-- list: only an export or restore of lifecycle state uses them (EP-235).
openTargetLifecycle :: ActiveTarget -> IO (Either Text ObjectOps)
openTargetLifecycle = openFeedOps

openFeedOps :: ActiveTarget -> IO (Either Text ObjectOps)
openFeedOps target = do
  stateRoot <- nagareStateDir
  let contextText = contextNameText (target ^. #contextName)
      profile = target ^. #profile
  opened <- case effectiveInventoryStore profile of
    InventoryStoreLocal ->
      Right <$> filesystemObjectOps (T.unpack (feedLocation (T.pack (stateRoot </> T.unpack contextText </> "inventory"))))
    InventoryStoreGcs -> remoteObjectOps (profile ^. #project) (feedLocation (remoteInventoryUrl target))
    InventoryStoreObject -> case objectInventoryStoreUrl contextText profile of
      Nothing -> pure (Left "the context has no object inventory store URL, so its lifecycle feed has no location")
      Just url -> objectStoreOps False (target & #profile . #inventoryStoreUrl .~ feedLocation url)
  pure opened

-- | In-process reads of the context's backup bucket (EP-233): gogol after
-- the bucket's ownership proof for GCS; for MinIO, signed requests through
-- the context's port-forward, or directly from inside the cluster, with the
-- store's credentials read once through kubectl.
targetBackupReader :: ActiveTarget -> StoreBackend -> IO (Either Text VersionedReader)
targetBackupReader target = \case
  GcsBackend project bucket -> remoteBackupReader project bucket
  MinioBackend ref -> do
    let context = contextNameText (target ^. #contextName)
    access <- readSecretField context "nagare-system" (ref ^. #secretName) "AWS_ACCESS_KEY_ID"
    secret <- readSecretField context "nagare-system" (ref ^. #secretName) "AWS_SECRET_ACCESS_KEY"
    inCluster <- isJust <$> lookupEnv "KUBERNETES_SERVICE_HOST"
    case S3Credentials <$> access <*> secret of
      Left reason -> pure (Left reason)
      Right credentials -> do
        reach <-
          if inCluster
            then pure (pure (Right (ref ^. #endpoint, T.drop 7 (ref ^. #endpoint))))
            else forwardedReach (kubectlForward context "nagare-system" "minio" "9000")
        transport <- s3HttpTransport reach credentials
        pure (Right (s3VersionedReader transport (ref ^. #bucket)))

-- | A schedule's HMAC key and its Secret's live UID, read through kubectl.
targetSigningKey :: ActiveTarget -> SigningRef -> IO (Either Text (Text, PhysicalIdentity))
targetSigningKey target ref = do
  read' <- readSecretFieldWithUid (contextNameText (target ^. #contextName)) (ref ^. #namespace) (ref ^. #secret) "HMAC_KEY"
  pure $ case read' of
    Left reason -> Left reason
    Right (Nothing, _) -> Left "the signing Secret has no UID"
    Right (Just uid, key) -> (,) key <$> mkPhysicalIdentity uid

-- | Refuse every write before it reaches the transport.
readOnlyFeedOps :: ObjectOps -> ObjectOps
readOnlyFeedOps ops = ops {putObject = \_ _ _ -> pure (PutNoEffect "the lifecycle feed is open read-only")}
