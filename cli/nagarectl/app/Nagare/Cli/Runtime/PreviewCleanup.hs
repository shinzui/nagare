module Nagare.Cli.Runtime.PreviewCleanup (saveReviewedPreviewCleanup) where

import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Inventory.Planning (inventoryControllerCollectionRegistry, inventoryPlanRegistry)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (..), PlannedOperation (..), withPreparationGuard)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Inventory.PreviewCleanup
import Nagare.Inventory.Store (readObject, revisionDigest, scopeKey)
import Nagare.Ops.Cleanup (CleanupOpts)
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)
import Nagare.Target (contextNameText)
import System.Exit (ExitCode (..))

saveReviewedPreviewCleanup :: Maybe String -> CleanupOpts -> FilePath -> IO ()
saveReviewedPreviewCleanup selected options output = do
  unless
    (options ^. #doPreviews && not (options ^. #doImages || options ^. #doReleases || options ^. #confirm))
    (dieT "this preview cleanup review requires --previews alone; apply the saved review separately")
  unless (options ^. #previewTtlDays >= 0) (dieT "--preview-ttl-days must not be negative")
  active <- activeTarget selected
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  history <- Plan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (Resource.composeSnapshot snapshot)
  let namespace = fromMaybe "default" (options ^. #namespace)
      registry candidate previous = withPreparationGuard verifyOnly <$> inventoryPlanRegistry active workspace candidate previous
  originals <- forM (previewCleanupRevisions namespace history) $ \key@(_, revision) -> do
    bytes <- readObject store (scopeKey (revisionDigest revision)) >>= either (dieT . T.pack . show) pure >>= maybe (dieT "retained preview scope bytes are missing") pure
    unless (contentDigest bytes == revisionDigest revision) (dieT "retained preview scope digest mismatch")
    scope <- either (dieT . T.pack . show) pure (decodeScope bytes)
    pure (key, scope)
  collectible <- either dieT pure (eligiblePreviewCollections namespace history inventory (Map.fromList originals))
  -- Collection is deliberately a later review; retirement never deletes.
  case collectible of
    resource : _ -> do
      let member = snd (Plan.historyRetained history Map.! resource)
          controller = case member ^. #address of
            Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
            _ -> False
          collectionRegistry candidate previous =
            withPreparationGuard (collectOnly resource)
              <$> (if controller then inventoryControllerCollectionRegistry else inventoryPlanRegistry) active workspace candidate previous
      Inventory.planInventoryCollectionWith collectionRegistry active resource output
      TIO.putStrLn "Saved exact retained preview collection; dependent and durable members remain retained"
    [] -> do
      services <- either dieT pure (previewCleanupServices namespace snapshot)
      context <- either dieT pure (mkContextId (contextNameText (active ^. #contextName)))
      let guard = fmap (fmap (const ())) (guardKubernetesContext active)
          runtime = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) guard
      unless (null services) (guard >>= either dieT pure)
      now <- getCurrentTime
      observed <- forM services $ \service -> case service ^. #address of
        Kubernetes _ _ _ (Just ns) name -> do
          result <- invokeKubectl runtime ["get", "services.serving.knative.dev", T.unpack (nameText name), "-n", T.unpack (nameText ns), "-o", "json"] ""
          bytes <- case result of
            Right (ExitSuccess, body, _) -> pure (TE.encodeUtf8 (T.pack body))
            _ -> dieT "preview age observation unavailable; no retirement review saved"
          (uid, stale) <- either dieT pure (parsePreviewAge now (options ^. #previewTtlDays) service bytes)
          pure (service, uid, stale)
        _ -> dieT "preview ownership has no namespaced Service"
      let stale = [(service, uid) | (service, uid, True) <- observed]
          expected = Map.fromList [(service ^. #identity, uid) | (service, uid) <- stale]
      case NE.nonEmpty [service ^. #owner | (service, _) <- stale] of
        Nothing -> TIO.putStrLn "No stale accepted previews or eligible retained preview members; no cleanup review created"
        Just owners -> do
          Inventory.planInventoryRetirementsWith registry (validatePreviewIncarnations expected) active owners output
          TIO.putStrLn "Saved stale preview retirement; apply it, then review cleanup again for exact collection"
  where
    verifyOnly operation =
      unless
        (plannedAction operation == VerifyResource)
        (Left "preview retirement cannot repair or execute other resources")
    collectOnly resource operation =
      unless
        ( plannedAction operation == VerifyResource
            || (plannedAction operation == RetireResource && NE.toList (plannedResources operation) == [resource])
        )
        (Left "preview collection cannot mutate beyond its exact selected retained member")
