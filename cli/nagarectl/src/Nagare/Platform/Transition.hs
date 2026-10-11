-- | The reviewed release transition of an admitted inventory context (EP-172,
-- ADR 6): whether the running CLI's payload may move a context pinned to
-- another release. Planning refuses an unsupported pair before any write.
module Nagare.Platform.Transition
  ( TransitionPair (..)
  , TransitionRefusal (..)
  , inventorySchemaVersion
  , checkTransition
  , platformReviewExpectation
  , renderTransitionRefusal
  , sameDeclarationsModuloSource
  , transitionOwnerRefusal
  )
where

import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store (TransitionMarker (..), parseTransitionReviewIdentity)
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Resource.Inventory (ScopeDeclaration)
import Nagare.Resource.Wire (encodeCanonicalScope)

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

-- | While a transition is open, only the target payload's CLI may mutate the
-- context: any other refuses and names the payload that finishes the move.
transitionOwnerRefusal :: TransitionMarker -> Text -> Maybe Text
transitionOwnerRefusal marker payload
  | payload == transitionTarget marker = Nothing
  | otherwise =
      Just
        ( "a release transition from "
            <> transitionSource marker
            <> " to payload "
            <> transitionTarget marker
            <> " is open since "
            <> transitionStartedAt marker
            <> "; this nagarectl carries payload "
            <> payload
            <> ", so only the target release's nagarectl applies, resumes, recovers or closes until platform transition commit ends it"
        )

-- | What a platform review's payload identity requires at apply: the payload
-- that planned it and the context pin it expects. A bootstrap review was
-- planned by this payload against a context pinned to its release; a
-- transition review (EP-172) by the target payload against the source release.
platformReviewExpectation :: PayloadManifest -> Text -> Maybe (Text, Text)
platformReviewExpectation manifest identity = case T.stripPrefix "nagare-bootstrap:" identity of
  Just payload -> Just (payload, manifest ^. #platformVersion)
  Nothing -> (\(source, payload) -> (payload, source)) <$> parseTransitionReviewIdentity identity

-- | Whether two declarations of a scope differ only in where their members
-- were declared from. Declarations embed the payload workspace path as each
-- member's source, so a transition sees every scope change there; the planner
-- judges members the same way, so such a scope is re-accepted with no
-- operation. The judgement is on the scope wire with every source removed.
sameDeclarationsModuloSource :: ScopeDeclaration -> ScopeDeclaration -> Bool
sameDeclarationsModuloSource left right = case (wire left, wire right) of
  (Right a, Right b) -> a == b
  _ -> False
  where
    wire = fmap unsourced . Aeson.eitherDecodeStrict' . encodeCanonicalScope
    unsourced :: Aeson.Value -> Aeson.Value
    unsourced = \case
      Aeson.Object fields -> Aeson.Object (KM.mapWithKey (\key value -> if key == "source" then Aeson.Null else unsourced value) fields)
      Aeson.Array items -> Aeson.Array (fmap unsourced items)
      other -> other

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
