-- | The active context's accepted artifact publications for @nagarectl
-- inventory publications@ (EP-192): one read-only store open, one checked
-- head and the scopes it accepts. It contacts no provider.
module Nagare.Inventory.Publications
  ( readPublications
  , renderPublicationTable
  )
where

import Data.Generics.Labels ()
import Data.List (intercalate, transpose)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Problem (ProblemSpec, unclassified)
import Nagare.Contract.Project (publicationList, storeRefusal)
import Nagare.Contract.V1 (PublicationList)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Recorded (readRecordedState, recordedAccepted)
import Nagare.Inventory.Store (revisionGeneration)
import Nagare.Inventory.Store.Target (openTargetStoreReadOnly)
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import Nagare.Target (ActiveTarget, contextNameText)

-- | The publication list, or a coded refusal.
readPublications :: ActiveTarget -> IO (Either (ProblemSpec, Text) PublicationList)
readPublications target = case binding of
  Left reason -> pure (Left (unclassified, reason))
  Right expected -> do
    opened <- openTargetStoreReadOnly target
    case opened of
      Left failure -> pure (Left (storeRefusal failure))
      Right store -> do
        recorded <- readRecordedState store expected
        pure $ do
          state <- first storeRefusal recorded
          first (unclassified,) (publicationList (Map.map (first revisionGeneration) (recordedAccepted state)))
  where
    binding = ContextBinding <$> mkContextId (contextNameText (target ^. #contextName)) <*> mkName (target ^. #profile . #project)

-- | An aligned table of scope, key, destination, generation and the
-- application scopes that use each publication.
renderPublicationTable :: PublicationList -> Text
renderPublicationTable listing =
  T.unlines (map (T.stripEnd . T.pack) (aligned (header : rows)))
  where
    header = ["SCOPE", "KEY", "DESTINATION", "GENERATION", "USED BY"]
    rows =
      [ [ T.unpack (publication ^. #scope)
        , T.unpack (publication ^. #key)
        , T.unpack (publication ^. #destination)
        , show (publication ^. #generation)
        , intercalate "," (map T.unpack (publication ^. #usedBy))
        ]
      | publication <- listing ^. #publications
      ]
    aligned table =
      let widths = map (maximum . map length) (transpose table)
       in [intercalate "  " (zipWith pad widths cells) | cells <- table]
    pad width cell = cell <> replicate (width - length cell) ' '
