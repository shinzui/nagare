-- | The read-only report of @nagarectl inventory store status@, built from the
-- raw head bytes. A head inside the supported schema range is decoded and
-- reported in full; only a newer head is reported as @unsupported-schema@.
module Nagare.Inventory.StoreStatus
  ( StoreStatus (..)
  , storeStatus
  , storeStatusReport
  , storeStatusLine
  , publicDataFence
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.Store qualified as InventoryStore

-- | What a head's bytes say about the store.
data StoreStatus
  = -- | A canonical head at a schema version this CLI does not decode.
    StoreStatusUnsupported !Int
  | StoreStatusHead !InventoryStore.HeadManifest
  deriving stock (Eq, Show, Generic)

storeStatus :: ByteString -> Either InventoryStore.StoreError StoreStatus
storeStatus rawHead = do
  schema <- InventoryStore.inspectHeadSchema rawHead
  if InventoryStore.supportedHeadSchemaVersion schema
    then StoreStatusHead <$> InventoryStore.decodeHead rawHead
    else pure (StoreStatusUnsupported schema)

-- | The JSON report, from the store kind token, the store URL and the head bytes.
storeStatusReport :: Text -> Text -> ByteString -> Either InventoryStore.StoreError Aeson.Value
storeStatusReport kind url rawHead =
  storeStatus rawHead <&> \case
    StoreStatusUnsupported schema ->
      Aeson.object
        [ "kind" Aeson..= kind
        , "url" Aeson..= url
        , "headDigest" Aeson..= InventoryDigest.contentDigest rawHead
        , "schemaVersion" Aeson..= schema
        , "state" Aeson..= ("unsupported-schema" :: Text)
        ]
    StoreStatusHead headValue ->
      Aeson.object
        [ "kind" Aeson..= kind
        , "url" Aeson..= url
        , "binding" Aeson..= InventoryStore.headBinding headValue
        , "headDigest" Aeson..= InventoryDigest.contentDigest rawHead
        , "generation" Aeson..= InventoryStore.headGeneration headValue
        , "activeTransaction" Aeson..= InventoryStore.headActiveTransaction headValue
        , "dataFence" Aeson..= fmap publicDataFence (InventoryStore.headDataFence headValue)
        , "executorClaim" Aeson..= InventoryStore.headExecutorClaim headValue
        , "migration" Aeson..= InventoryStore.headMigration headValue
        , "transition" Aeson..= InventoryStore.headTransition headValue
        , "accepted" Aeson..= revisions (InventoryStore.headAccepted headValue)
        , "converged" Aeson..= revisions (InventoryStore.headConverged headValue)
        ]
  where
    revisions values =
      [ Aeson.object ["scope" Aeson..= scope, "revision" Aeson..= revision]
      | (scope, revision) <- Map.toAscList values
      ]

-- | The one-line text report, from the same inputs as 'storeStatusReport'.
storeStatusLine :: Text -> Text -> ByteString -> Either InventoryStore.StoreError Text
storeStatusLine kind url rawHead =
  storeStatus rawHead <&> \case
    StoreStatusUnsupported schema ->
      "Inventory store "
        <> kind
        <> " at "
        <> url
        <> " uses unsupported head schema "
        <> T.pack (show schema)
        <> "; use a newer operator payload"
    StoreStatusHead headValue ->
      "Inventory store "
        <> kind
        <> " at "
        <> url
        <> ", generation "
        <> T.pack (show (InventoryStore.headGeneration headValue))
        <> ", active transaction: "
        <> fromMaybe "none" (InventoryStore.headActiveTransaction headValue)
        <> ", executor claim: "
        <> maybe "none" InventoryStore.claimTransaction (InventoryStore.headExecutorClaim headValue)
        <> ", data fence: "
        <> maybe
          "none"
          (T.pack . show . InventoryStore.fencePhase)
          (InventoryStore.headDataFence headValue)

publicDataFence :: InventoryStore.DataFenceRecord -> Aeson.Value
publicDataFence fence =
  Aeson.object
    [ "session" Aeson..= InventoryStore.fenceSession fence
    , "phase" Aeson..= InventoryStore.fencePhase fence
    , "affected" Aeson..= Set.toAscList (InventoryStore.fenceAffected fence)
    , "targets"
        Aeson..= [ Aeson.object ["resource" Aeson..= resource, "physical" Aeson..= physical]
                 | (resource, physical) <- Map.toAscList (InventoryStore.fencePhysical fence)
                 ]
    , "recoveryDigest" Aeson..= InventoryStore.fenceRecoveryDigest fence
    ]
