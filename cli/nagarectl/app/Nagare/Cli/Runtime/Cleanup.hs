-- | Cleanup reviews select ownership before loading private native evidence.
module Nagare.Cli.Runtime.Cleanup (saveReviewedReleaseCleanup) where

import Control.Monad (foldM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (withPreparationGuard)
import Nagare.Inventory.Cleanup (compileReleaseHistoryPrune, releaseHistoryMembers, validateReleaseCleanupOperation)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Ops.Cleanup (CleanupOpts)
import Nagare.Resource.Inventory qualified as Resource

saveReviewedReleaseCleanup :: Maybe String -> CleanupOpts -> FilePath -> IO ()
saveReviewedReleaseCleanup selected options output = do
  unless (options ^. #doReleases && not (options ^. #doImages || options ^. #doPreviews || options ^. #confirm)) $
    dieT "this cleanup review requires --releases alone; apply the saved review separately with inventory apply"
  unless (options ^. #keepReleases >= 1) (dieT "--keep-releases must be positive")
  active <- activeTarget selected
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  let members = releaseHistoryMembers (fromMaybe "default" (options ^. #namespace)) snapshot
      owners = Map.fromList [(member ^. #owner, ()) | member <- Map.elems members]
      scopes = Map.restrictKeys (Resource.snapshotScopes snapshot) (Map.keysSet owners)
  case NE.nonEmpty (Map.toAscList scopes) of
    Nothing -> TIO.putStrLn "No accepted application/site release-history members in the selected namespace; no cleanup review created"
    Just selectedScopes -> do
      history <- Plan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      inventory <- either (dieT . T.pack . show) pure (Resource.composeSnapshot snapshot)
      (native, _) <- Status.loadAcceptedNativeSelected (Map.keysSet members) store history inventory >>= either dieT pure
      (revised, updatedNative) <-
        foldM
          ( \(accumulated, previousNative) (owner, (_, accepted)) -> do
              let selectedMembers = filter ((== owner) . (^. #owner)) (Map.elems members)
              (scope, nextNative) <-
                foldM
                  ( \(current, evidence) member ->
                      either
                        (dieT . T.pack . show)
                        pure
                        (compileReleaseHistoryPrune (options ^. #keepReleases) member current evidence)
                  )
                  (accepted, previousNative)
                  selectedMembers
              pure (accumulated <> [scope], nextNative)
          )
          ([], native)
          (NE.toList selectedScopes)
      changes <- maybe (dieT "release cleanup selected no scopes") pure (NE.nonEmpty (map Resource.ReplaceScope revised))
      candidate <- either (dieT . T.pack . show) pure (Resource.composeInventory snapshot changes)
      let registryFor desired accepted =
            withPreparationGuard (validateReleaseCleanupOperation (Map.keysSet members))
              <$> inventoryPlanRegistryWithNative active workspace updatedNative desired accepted
      Inventory.planInventoryCandidateWith registryFor active candidate output
      TIO.putStrLn "Saved exact accepted release-history pruning; current releases remain retained"
