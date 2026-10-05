-- | Whether a revision may be used for native work: it needs a green, clean
-- gate record for its exact tree that realised every supported system.
module Nagare.Harness.Verify
  ( VerifyTarget (..)
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
