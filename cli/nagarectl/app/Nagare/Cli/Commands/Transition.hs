-- | Commands / Transition. Executable-private CLI boundary.
--
-- The reviewed release transition of an admitted inventory context (EP-172):
-- this payload's CLI plans the ordinary bootstrap stages against a context
-- pinned to an accepted source release, each stage is applied with inventory
-- apply, and the pin is written last.
module Nagare.Cli.Commands.Transition
  ( runPlatformTransitionCommit
  , runPlatformTransitionPlan
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Bootstrap.Sequence (planNextStage)
import Nagare.Cli.Bootstrap.Stage (StageMode (ReleaseTransition))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.PlatformStatus (gatherPlatformStatus)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Contract.Release (TransitionPlanSummary (..), transitionPlanSummaryVersion)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (PlannedOperation (plannedAction))
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan (ReviewDocument (reviewOperations), ReviewOperation (reviewPlannedOperation), loadReviewBundle, reviewBaseRevisions, reviewBundleDocument, reviewDesiredRevisions)
import Nagare.Inventory.Store
  ( HeadManifest (headGeneration, headSchemaVersion, headTransition)
  , InventoryStore
  , TransitionMarker (transitionFinalizing, transitionSource)
  , readHead
  , transitionReviewIdentity
  )
import Nagare.Inventory.Store.Counters (tracePhase)
import Nagare.Platform.Deployment (DeploymentState (NotDeployed))
import Nagare.Platform.Finalize (PinOps (..), finalizeTransition)
import Nagare.Platform.Status (renderPlatformStatus)
import Nagare.Platform.Transition (checkTransition, renderTransitionRefusal, transitionCommitRefusal, transitionContinueRefusal)
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (Mode (Cloud), contextNameText, readContextProfile, writeContextPlatformVersion)

-- | Review the next stage that moves the context to this payload's release.
-- Planning is read-only apart from the saved review; the first admitted stage
-- opens the head's transition marker.
runPlatformTransitionPlan :: Maybe String -> FilePath -> Maybe FilePath -> IO ()
runPlatformTransitionPlan mctx output summary = do
  active <- activeTarget mctx
  (paths, workspace) <- tracePhase "workspace resolution" (resolvePlatformWorkspace (active ^. #contextName))
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  store <- tracePhase "inventory open" (Inventory.openTargetStoreReadOnly active) >>= either (dieT . T.pack . show) pure
  headValue <- currentHead store
  -- A finalizing transition is only finished by its commit (EP-228 M1).
  for_ (headTransition headValue >>= transitionFinalizing) $ \pin ->
    dieT ("the release transition is finalizing the context pin to " <> pin <> "; run platform transition commit to finish it")
  pair <-
    either
      (dieT . renderTransitionRefusal)
      pure
      (checkTransition manifest (active ^. #profile . #platformVersion) (headSchemaVersion headValue))
  for_ (headTransition headValue) $ \marker -> do
    for_ (transitionContinueRefusal headValue marker (manifest ^. #payloadId)) dieT
    unless (transitionSource marker == pair ^. #source) (dieT ("the open transition moves from " <> transitionSource marker <> ", not the pinned " <> pair ^. #source))
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  foundationOwner <- either dieT pure (Resource.mkScopeId Resource.Platform "cloud-foundation")
  when
    (active ^. #profile . #mode == Cloud && not (Map.member foundationOwner (ResourceInventory.snapshotScopes snapshot)))
    (dieT "a release transition moves an admitted context; this context's cloud foundation is not accepted, so bootstrap it on its pinned release first")
  -- The stages are planned as if the context were already pinned to the
  -- target; the pin itself is written by the commit, last.
  let moved = active & #profile . #platformVersion .~ Just (manifest ^. #platformVersion)
  tracePhase "stage planning" $ planNextStage ReleaseTransition moved paths workspace (transitionReviewIdentity (pair ^. #source) (manifest ^. #payloadId)) output
  for_ summary (writeTransitionSummary output)
  TIO.putStrLn
    ( "Saved the next transition stage ("
        <> pair ^. #source
        <> " -> "
        <> pair ^. #target
        <> "). Apply it with inventory apply, then plan again until the review has no operations; platform transition commit then pins the context."
    )

-- | Pin the context to this release and close the transition. Refuses unless
-- the store is idle, the marker names this payload, and the payload, host and
-- cluster all report the target release.
runPlatformTransitionCommit :: Maybe String -> Bool -> IO ()
runPlatformTransitionCommit mctx yes = do
  (active, status) <- gatherPlatformStatus mctx
  (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
  manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
  store <- Inventory.openTargetStore active
  headValue <- currentHead store
  -- The pin is written last: the marker must be this payload's, the store
  -- idle, and every platform scope converged at its accepted revision. A
  -- marker already finalizing is this commit's own, stopped: finish it.
  for_ (if isJust (headTransition headValue >>= transitionFinalizing) then Nothing else transitionCommitRefusal (manifest ^. #payloadId) ((== Resource.Platform) . Resource.scopeKind) headValue) dieT
  marker <- maybe (dieT "no release transition is open; review one with platform transition plan") pure (headTransition headValue)
  let target = manifest ^. #platformVersion
      reports identity = identity ^. #version == Just target
  TIO.putStr (renderPlatformStatus (contextNameText (active ^. #contextName)) status)
  unless (reports (status ^. #payload)) (dieT ("the running payload does not report " <> target))
  unless
    (active ^. #profile . #mode /= Cloud || status ^. #hostDeployment == NotDeployed || reports (status ^. #host))
    (dieT ("the host flake does not report " <> target <> "; apply the transition's host stage first"))
  unless
    (status ^. #clusterDeployment == NotDeployed || reports (status ^. #cluster))
    (dieT ("the cluster marker does not report " <> target <> "; apply the transition's platform stage first"))
  unless yes (dieT "platform transition commit requires --yes after reviewing the status above")
  -- EP-228 M1: intent under the lock, then the pin, then the conditional
  -- close; a stop anywhere is finished by committing again.
  let pins =
        PinOps
          { readPin = fmap (^. #platformVersion) <$> readContextProfile (active ^. #contextName)
          , writePin = writeContextPlatformVersion (active ^. #contextName)
          }
  _ <- finalizeTransition store pins (const (pure ())) (manifest ^. #payloadId) ((== Resource.Platform) . Resource.scopeKind) target >>= either dieT pure
  TIO.putStrLn
    ( "context "
        <> contextNameText (active ^. #contextName)
        <> " pinned to "
        <> target
        <> "; the transition from "
        <> transitionSource marker
        <> " is closed"
    )

-- | EP-229: the saved review's operation count by action and the scopes it
-- re-accepts at a new revision, the bootstrap stamp aside (every replan
-- re-declares the stamp), for the release runner to decide convergence.
writeTransitionSummary :: FilePath -> FilePath -> IO ()
writeTransitionSummary reviewDirectory path = do
  bundle <- loadReviewBundle reviewDirectory >>= either dieT pure
  let document = reviewBundleDocument bundle
      actions = [actionTag (plannedAction (reviewPlannedOperation operation)) | operation <- reviewOperations document]
      base = reviewBaseRevisions document
      moved =
        [ Resource.scopeIdText scope
        | (scope, revision) <- Map.toAscList (reviewDesiredRevisions document)
        , Resource.nameText (Resource.scopeName scope) /= "bootstrap-stamp"
        , Map.lookup scope base /= Just revision
        ]
  BL.writeFile
    path
    ( encode
        TransitionPlanSummary
          { schemaVersion = transitionPlanSummaryVersion
          , review = T.pack reviewDirectory
          , operations = Map.fromListWith (+) [(action, 1) | action <- actions]
          , operationCount = length actions
          , reaccepted = moved
          }
    )
  where
    actionTag = T.pack . takeWhile (/= ' ') . show

currentHead :: InventoryStore -> IO HeadManifest
currentHead store =
  readHead store
    >>= either (dieT . T.pack . show) pure
    >>= maybe (dieT "inventory store is not initialized") pure
