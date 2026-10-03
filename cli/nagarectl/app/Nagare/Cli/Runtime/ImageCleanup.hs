-- | Exact cache selection is read-only; each saved deletion is a one-shot intent.
module Nagare.Cli.Runtime.ImageCleanup (saveReviewedImageCleanup) where

import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.ImagePrune
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.ImagePrune
import Nagare.Ops.Cleanup (CleanupOpts)
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types (resourceIdText, scopeIdText)
import Nagare.Resource.Wire (canonicalValue)

saveReviewedImageCleanup :: Maybe String -> CleanupOpts -> FilePath -> IO ()
saveReviewedImageCleanup selected options output = do
  unless
    (options ^. #doImages && not (options ^. #doPreviews || options ^. #doReleases || options ^. #confirm))
    (dieT "this cleanup review requires --images alone; apply the saved review separately with inventory apply")
  when (isJust (options ^. #namespace)) (dieT "host image cleanup is not namespace-scoped")
  requestId <- maybe (dieT "image cleanup requires --id REQUEST_ID") pure (options ^. #imageRequestId)
  active <- activeTarget selected
  address <- either dieT pure (selectedImageCacheAddress active)
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  prior <- either dieT pure (imagePruneRequestTargets snapshot address requestId)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  images <- case prior of
    Just originals -> pure originals
    Nothing ->
      imagePruneObserve (imageCacheOps store active workspace) address
        >>= either dieT (either dieT pure . unusedCacheImages)
  if null images
    then TIO.putStrLn "No unused unpinned images on the accepted host; no cleanup review created"
    else do
      scope <- either dieT pure (compileImagePrune snapshot address requestId images)
      let prefix = scopeIdText (Resource.scopeId scope) <> "/image-prune-" <> requestId <> "/"
          selectedIntents = [intent | bundle <- Resource.scopeBundles scope, intent <- Resource.operations bundle, prefix `T.isPrefixOf` resourceIdText (intent ^. #identity)]
      selectedDigests <- Set.fromList <$> traverse (either dieT (pure . contentDigest) . canonicalValue . toJSON) selectedIntents
      candidate <- either (dieT . T.pack . show) pure (Resource.composeInventory snapshot (Resource.ReplaceScope scope NE.:| []))
      let guard operation
            | plannedAction operation == VerifyResource = Right ()
            | plannedAction operation == RunDeclaredOperation && Set.member (plannedInputDigest operation) selectedDigests = Right ()
            | otherwise = Left "image cleanup cannot repair or mutate neighboring resources"
          registry desired history = withPreparationGuard guard <$> inventoryPlanRegistry active workspace desired history
      Inventory.planInventoryCandidateWith registry active candidate output
      TIO.putStrLn "Saved exact host cache image cleanup; running/stopped container images and pinned images remain protected"
