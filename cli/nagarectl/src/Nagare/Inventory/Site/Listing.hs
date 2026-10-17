-- | The active context's recorded sites for @nagarectl site list@ (EP-193):
-- one read-only store open, one checked head, the hydrated scopes it names,
-- and the pure projection. It starts no subprocess and contacts no provider.
module Nagare.Inventory.Site.Listing
  ( SiteSelection (..)
  , readSiteListing
  , selectSites
  , renderSiteTable
  )
where

import Data.Generics.Labels ()
import Data.List (intercalate, transpose)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Recorded (readRecordedState, recordedHeadManifest, recordedStateHead)
import Nagare.Inventory.Site.Recorded (RecordState (..), RecordedSite, SiteKind (..), recordedSites)
import Nagare.Inventory.Store (HeadManifest, StoreError (..))
import Nagare.Inventory.Store.Target (openTargetStoreReadOnly)
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import Nagare.Target (ActiveTarget, contextNameText)

-- | Which sites to list: one origin namespace or all, with or without
-- previews.
data SiteSelection = SiteSelection
  { namespace :: !(Maybe Text)
  , includePreviews :: !Bool
  }
  deriving stock (Eq, Show, Generic)

readSiteListing :: ActiveTarget -> SiteSelection -> IO (Either Text (HeadManifest, [RecordedSite]))
readSiteListing target selection = case binding of
  Left reason -> pure (Left reason)
  Right expected -> do
    opened <- openTargetStoreReadOnly target
    case opened of
      Left failure -> pure (Left (storeText failure))
      Right store -> do
        recorded <- readRecordedState store expected
        pure $ do
          state <- first storeText recorded
          sites <- recordedSites state
          pure (recordedHeadManifest (recordedStateHead state), selectSites selection sites)
  where
    binding = ContextBinding <$> mkContextId (contextNameText (target ^. #contextName)) <*> mkName (target ^. #profile . #project)
    storeText failure = "the inventory store could not be read: " <> T.pack (show failure)

selectSites :: SiteSelection -> [RecordedSite] -> [RecordedSite]
selectSites selection =
  filter
    ( \site ->
        maybe True (== site ^. #acceptedService . #namespace) (selection ^. #namespace)
          && (selection ^. #includePreviews || site ^. #kind /= SiteKindPreview)
    )

-- | An aligned table of namespace, name, recorded state and hostnames,
-- preceded by a notice that health was not checked.
renderSiteTable :: [RecordedSite] -> Text
renderSiteTable sites =
  T.unlines ("Recorded sites (from the inventory store; health was not checked):" : map (T.stripEnd . T.pack) (aligned (header : rows)))
  where
    header = ["NAMESPACE", "NAME", "STATE", "HOSTNAMES"]
    rows =
      [ [ T.unpack (site ^. #acceptedService . #namespace)
        , T.unpack (site ^. #acceptedService . #name)
        , stateText (site ^. #state)
        , intercalate "," (map T.unpack (site ^. #acceptedService . #hostnames))
        ]
      | site <- sites
      ]
    stateText = \case
      RecordConverged -> "converged"
      RecordPending -> "pending"
      RecordNeverConverged -> "never-converged"
    aligned table =
      let widths = map (maximum . map length) (transpose table)
       in [intercalate "  " (zipWith pad widths cells) | cells <- table]
    pad width cell = cell <> replicate (width - length cell) ' '
