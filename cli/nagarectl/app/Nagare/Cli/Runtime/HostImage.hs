-- | The host-image recipe reviews only image build/publication, never host apply.
module Nagare.Cli.Runtime.HostImage (runHostImageReview) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Image (buildImageBuildStageCandidate, buildImagePublicationStageCandidate)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (Mode (Cloud))

runHostImageReview :: Maybe String -> FilePath -> IO ()
runHostImageReview selected output = do
  active <- activeTarget selected
  unless (active ^. #profile . #mode == Cloud) (dieT "host image publication requires a cloud context")
  (paths, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  cloudOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud")
  unless (Map.member cloudOwner (ResourceInventory.snapshotScopes snapshot)) $
    dieT "host image review requires accepted cloud perimeter ownership; complete its bootstrap review first"
  build <- buildImageBuildStageCandidate active workspace snapshot
  candidate <- case build of
    Just pending -> pure pending
    Nothing -> do
      publication <- buildImagePublicationStageCandidate active workspace snapshot
      case publication of
        Just pending -> pure pending
        Nothing -> do
          owner <- either dieT pure (Resource.mkScopeId Resource.Platform "host-image")
          (_, scope) <- maybe (dieT "host image lacks accepted publication ownership") pure (Map.lookup owner (ResourceInventory.snapshotScopes snapshot))
          either (dieT . T.pack . show) pure $
            ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope :| [])
  Inventory.planInventoryCandidateWithPayloadIdentity
    (inventoryPlanRegistry active workspace)
    ("nagare-bootstrap:" <> manifest ^. #payloadId)
    active
    candidate
    output
  TIO.putStrLn "Saved the next host image stage. Apply with inventory apply, then review again for publication or its no-op verification."
