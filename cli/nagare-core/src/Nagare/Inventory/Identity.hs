-- | ADR 27 §2: the one checked reading of a member's accepted incarnation.
-- Every consumer that moves, certifies or compares data reads a member's
-- identity here, so a missing record is never read as a match.
module Nagare.Inventory.Identity
  ( IdentityCheck (..)
  , checkedPhysical
  , requireAccepted
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude
import Nagare.Resource.Types (PhysicalIdentity, ResourceId, physicalIdentityText)

data IdentityCheck
  = -- | The live object is the recorded incarnation.
    IdentityMatches !PhysicalIdentity
  | -- | The recorded incarnation, and the different live object that replaced it.
    IdentityReplaced !PhysicalIdentity !PhysicalIdentity
  | -- | No incarnation is recorded for the member; the live object is unproved.
    IdentityUnrecorded !PhysicalIdentity
  | -- | No object of Nagare's is observed: absent, foreign, unowned or unread.
    IdentityAbsent
  deriving stock (Eq, Show)

-- | Compare a live identity with the member's record.
checkedPhysical :: Map ResourceId PhysicalIdentity -> ResourceId -> PhysicalIdentity -> IdentityCheck
checkedPhysical recorded resource live = case Map.lookup resource recorded of
  Nothing -> IdentityUnrecorded live
  Just accepted
    | accepted == live -> IdentityMatches live
    | otherwise -> IdentityReplaced accepted live

-- | For a consumer where data is at stake: only the recorded incarnation
-- passes. The text names what was checked, for example "the backup source".
requireAccepted :: Text -> IdentityCheck -> Either Text PhysicalIdentity
requireAccepted what = \case
  IdentityMatches live -> Right live
  IdentityReplaced accepted live ->
    Left (what <> " " <> physicalIdentityText live <> " is not the accepted incarnation " <> physicalIdentityText accepted <> "; it was replaced outside Nagare")
  IdentityUnrecorded live ->
    Left (what <> " " <> physicalIdentityText live <> " has no recorded incarnation; a reviewed rebind records it before its data is used")
  IdentityAbsent -> Left (what <> " is not observed as Nagare's object")
