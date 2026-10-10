-- | EP-183 M4 (ADR 27 amendment): a reviewed rebuild recreates one accepted
-- durable member whose object is confirmed absent, as a new incarnation. The
-- decision names the predecessor incarnation it succeeds (none when no
-- incarnation was ever recorded) and where the new incarnation's data comes
-- from: one exact recovery point of the predecessor, or nothing (a Secret
-- Nagare generates gets new values; a volume starts empty). A backup still
-- restores only into the incarnation it was taken from, unless a rebuild names
-- that exact recovery point for the incarnation the rebuild created.
module Nagare.Inventory.Lineage
  ( RecoveryPointKind (..)
  , RecoveryPoint (..)
  , RebuildSource (..)
  , RebuildProof (..)
  , renderRebuild
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Types (ContentDigest, PhysicalIdentity, ResourceId, digestText, physicalIdentityText, resourceIdText)
import Nagare.Resource.Wire ()

-- | Which receipt family the recovery point belongs to.
data RecoveryPointKind
  = -- | A scheduled backup, verified with the escrowed signing key.
    ScheduledRecoveryPoint
  | -- | A reviewed manual backup.
    ManualRecoveryPoint
  deriving stock (Eq, Ord, Show, Generic)

-- | One exact recovery point: its receipt object and the digest of the
-- receipt bytes the operator verified.
data RecoveryPoint = RecoveryPoint
  { kind :: !RecoveryPointKind
  , receipt :: !Text
  , receiptDigest :: !ContentDigest
  }
  deriving stock (Eq, Ord, Show, Generic)

data RebuildSource
  = -- | Restore this recovery point of the predecessor into the new incarnation.
    FromRecoveryPoint !RecoveryPoint
  | -- | Nothing of the predecessor's: a generated Secret gets new values, a
    -- volume starts empty.
    Fresh
  deriving stock (Eq, Ord, Show, Generic)

-- | What a reviewed rebuild approves for one member.
data RebuildProof = RebuildProof
  { predecessor :: !(Maybe PhysicalIdentity)
  -- ^ The recorded incarnation it succeeds; 'Nothing' when none was recorded.
  , source :: !RebuildSource
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | What an operator approves with a rebuild: the predecessor, and the data
-- the new incarnation receives.
renderRebuild :: ResourceId -> RebuildProof -> Text
renderRebuild resource proof =
  "rebuild "
    <> resourceIdText resource
    <> ": creates a new incarnation in place of "
    <> maybe "a member with no recorded incarnation" physicalIdentityText (proof ^. #predecessor)
    <> case proof ^. #source of
      FromRecoveryPoint point ->
        "; only recovery point "
          <> point ^. #receipt
          <> " ("
          <> digestText (point ^. #receiptDigest)
          <> ") may restore into it; later recovery points need another decision"
      Fresh -> "; none of the predecessor's data is recovered: a generated Secret gets new values and a volume starts empty"

instance ToJSON RecoveryPointKind where
  toJSON = \case
    ScheduledRecoveryPoint -> "scheduled"
    ManualRecoveryPoint -> "manual"

instance FromJSON RecoveryPointKind where
  parseJSON = withText "RecoveryPointKind" $ \case
    "scheduled" -> pure ScheduledRecoveryPoint
    "manual" -> pure ManualRecoveryPoint
    other -> fail ("unknown recovery point kind " <> T.unpack other)

instance ToJSON RecoveryPoint where
  toJSON point = object ["kind" .= (point ^. #kind), "receipt" .= (point ^. #receipt), "receiptDigest" .= (point ^. #receiptDigest)]

instance FromJSON RecoveryPoint where
  parseJSON = withObject "RecoveryPoint" $ \o -> do
    unless (all (`elem` ["kind", "receipt", "receiptDigest"]) (KM.keys o)) (fail "recovery point has an unknown field")
    point <- RecoveryPoint <$> o .: "kind" <*> o .: "receipt" <*> o .: "receiptDigest"
    when (T.null (point ^. #receipt)) (fail "recovery point needs its receipt object")
    pure point

-- | @{"predecessor": UID?, "recoveryPoint": ...}@ or
-- @{"predecessor": UID?, "fresh": true}@: exactly one source.
instance ToJSON RebuildProof where
  toJSON proof =
    object
      ( ["predecessor" .= predecessor' | Just predecessor' <- [proof ^. #predecessor]]
          <> case proof ^. #source of
            FromRecoveryPoint point -> ["recoveryPoint" .= point]
            Fresh -> ["fresh" .= True]
      )

instance FromJSON RebuildProof where
  parseJSON = withObject "RebuildProof" $ \o ->
    RebuildProof <$> o .:? "predecessor" <*> rebuildSourceFrom (KM.delete "predecessor" o)

rebuildSourceFrom :: Object -> Parser RebuildSource
rebuildSourceFrom o = case (KM.lookup "recoveryPoint" o, KM.lookup "fresh" o, KM.size o) of
  (Just point, Nothing, 1) -> FromRecoveryPoint <$> parseJSON point
  (Nothing, Just (Bool True), 1) -> pure Fresh
  _ -> fail "a rebuild names exactly one of a recovery point or fresh: true, and nothing else"
