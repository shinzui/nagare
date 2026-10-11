-- | The reviewed release transition of an admitted inventory context (EP-172,
-- ADR 6): whether the running CLI's payload may move a context pinned to
-- another release. Planning refuses an unsupported pair before any write.
module Nagare.Platform.Transition
  ( TransitionPair (..)
  , TransitionRefusal (..)
  , inventorySchemaVersion
  , checkTransition
  , renderTransitionRefusal
  )
where

import Control.Monad (unless, when)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Platform.Workspace (PayloadManifest)

-- | An accepted move: the context's pinned release and this payload's.
data TransitionPair = TransitionPair
  { source :: !Text
  , target :: !Text
  }
  deriving stock (Eq, Show, Generic)

data TransitionRefusal
  = -- | The context has no release pin, so there is nothing to move from.
    UnpinnedContext
  | -- | The context already runs this payload's release.
    AlreadyAtTarget !Text
  | -- | This payload does not list the pinned release as a source.
    UnsupportedSource !Text !Text ![Text]
  | -- | The store head's wire version is outside what this payload reads.
    UnsupportedStoreVersion !Int !Int !Int
  deriving stock (Eq, Show)

-- | The inventory store's current head wire version (`version` in head.json).
inventorySchemaVersion :: Int
inventorySchemaVersion = 1

-- | Refuse or accept moving a context pinned to @pin@, whose store head has
-- wire version @headVersion@, to this payload. Pure: the caller reads the pin
-- and the head, and nothing is written.
checkTransition :: PayloadManifest -> Maybe Text -> Int -> Either TransitionRefusal TransitionPair
checkTransition manifest pin headVersion = do
  source <- maybe (Left UnpinnedContext) Right pin
  let target = manifest ^. #platformVersion
      accepted = manifest ^. #transitionsFrom
      oldest = manifest ^. #minimumInventorySchemaVersion
  when (source == target) (Left (AlreadyAtTarget target))
  unless (source `elem` accepted) (Left (UnsupportedSource source target accepted))
  unless (headVersion >= oldest && headVersion <= inventorySchemaVersion) (Left (UnsupportedStoreVersion headVersion oldest inventorySchemaVersion))
  pure (TransitionPair source target)

renderTransitionRefusal :: TransitionRefusal -> Text
renderTransitionRefusal = \case
  UnpinnedContext -> "the context has no platform version pin; a transition moves an admitted, pinned context"
  AlreadyAtTarget target -> "the context is already pinned to " <> target <> "; nothing to move"
  UnsupportedSource source target accepted ->
    "this payload (" <> target <> ") accepts transitions from " <> listed accepted <> ", not from the pinned " <> source
  UnsupportedStoreVersion found oldest newest ->
    "the inventory head has wire version " <> showText found <> "; this payload reads versions " <> showText oldest <> " to " <> showText newest
  where
    listed [] = "no release"
    listed versions = T.intercalate ", " versions
    showText = T.pack . show
