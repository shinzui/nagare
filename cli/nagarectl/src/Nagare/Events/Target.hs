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
  , readOnlyFeedOps
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Events.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Inventory.Store.ObjectTarget (objectInventoryStoreUrl, objectStoreOps)
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Inventory.Store.Target (remoteInventoryUrl)
import Nagare.Resource.Types
import Nagare.Target
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
openTargetFeedReadOnly target = do
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
  traverse (newFeedStore . readOnlyFeedOps) opened

-- | Refuse every write before it reaches the transport.
readOnlyFeedOps :: ObjectOps -> ObjectOps
readOnlyFeedOps ops = ops {putObject = \_ _ _ -> pure (PutNoEffect "the lifecycle feed is open read-only")}
