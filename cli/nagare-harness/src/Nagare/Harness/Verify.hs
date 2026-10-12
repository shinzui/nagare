-- | Whether a revision may be used for native work or a release: it needs a
-- green, clean gate record for its exact tree that realised every supported
-- system. Landing needs less: a green fast record, and no red full gate on a
-- landed commit.
module Nagare.Harness.Verify
  ( VerifyTarget (..)
  , landedGateBlock
  , verifyFastRecord
  , verifyRecord
  )
where

import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Harness.Prelude
import Nagare.Harness.Record

-- | The revision being checked: its commit, its tree, and the systems its
-- @release.json@ supports.
data VerifyTarget = VerifyTarget
  { commit :: !Text
  , tree :: !Text
  , supportedSystems :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

verifyRecord :: VerifyTarget -> Maybe GateRecord -> Either Text ()
verifyRecord target = \case
  Nothing -> Left ("no gate record for " <> target ^. #commit <> "; run `just gate` on a clean checkout of it")
  Just record
    | record ^. #commit /= target ^. #commit -> Left "the record names a different commit"
    | not (record ^. #green) -> Left "the gate record is red"
    | not (record ^. #clean) -> Left "the gate ran on a dirty tree"
    | record ^. #tree /= target ^. #tree ->
        Left ("the record's tree " <> record ^. #tree <> " is not the commit's tree " <> target ^. #tree)
    | not (record ^. #builderProbe . #ok) -> Left "the builder probe failed"
    | otherwise -> case [system | system <- target ^. #supportedSystems, not (realisedFor system record)] of
        [] -> Right ()
        missing -> Left ("not every check is realised for: " <> T.intercalate ", " missing)
  where
    realisedFor system record = case Map.lookup system (record ^. #systems) of
      Nothing -> False
      Just realisation ->
        realisation ^. #checks > 0
          && realisation ^. #realised == realisation ^. #checks
          && null (realisation ^. #remaining)

-- | Whether a fast record lets @just land@ push the commit: green, for the
-- commit's exact tree.
verifyFastRecord :: Text -> Text -> Maybe FastRecord -> Either Text ()
verifyFastRecord commitId treeId = \case
  Nothing -> Left ("no fast gate record for " <> commitId <> "; run `just gate-fast` on a checkout of it with no uncommitted changes")
  Just record
    | record ^. #commit /= commitId -> Left "the fast record names a different commit"
    | not (record ^. #green) -> Left "the fast gate record is red"
    | record ^. #tree /= treeId ->
        Left ("the fast record's tree " <> record ^. #tree <> " is not the commit's tree " <> treeId)
    | otherwise -> Right ()

-- | The finished full gates of landed commits, newest first, as (commit,
-- green). The newest one being red blocks the next landing until a fix lands
-- and its own full gate is green.
landedGateBlock :: [(Text, Bool)] -> Maybe Text
landedGateBlock = \case
  (commitId, False) : _ -> Just ("the full gate of landed commit " <> commitId <> " is red; land a fix with `just gate` first")
  _ -> Nothing
