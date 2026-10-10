-- | EP-183 M4: rebuild the service after losing the VM. `inventory
-- rebuild-decisions` reads, for every accepted durable member whose object is
-- gone, the decision a rebuild needs and prints it; `inventory rebuild` saves
-- the review that recreates those members, and their scopes, from the
-- accepted declarations and native evidence. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Rebuild
  ( runInventoryRebuildDecisions
  , runInventoryRebuild
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Lineage (RebuildSource (..), RecoveryPoint (..), RecoveryPointKind (ScheduledRecoveryPoint), renderRebuild)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Rebuild (RebuildInput (..), decideRebuild, decodeRebuildInput, rebuildTargets)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (DataPolicy (Durable))
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Read-only: observe every accepted durable member, and print one rebuild
-- decision for each whose object is confirmed absent. A volume names the
-- recovery point given for it, or starts fresh only when the operator says so.
runInventoryRebuildDecisions :: Maybe String -> [String] -> [String] -> FilePath -> IO ()
runInventoryRebuildDecisions mctx pointArgs freshArgs output = do
  active <- activeTarget mctx
  points <- either dieT pure (traverse parsePoint pointArgs)
  fresh <- either dieT pure (traverse (Resource.mkResourceId . T.pack) freshArgs)
  (snapshot, history, candidate, registry) <- acceptedRebuild active (const True)
  observed <-
    InventoryAdapter.observeWithRegistry registry (InventoryPlan.requirementsByExecutor (InventoryPlan.observationRequirements candidate history))
      >>= either dieT pure
  let pointFor member predecessor
        | member `elem` fresh = Right Fresh
        | Just point <- lookup member points, Just _ <- predecessor = Right (FromRecoveryPoint point)
        | otherwise =
            Left
              ( InventoryPlan.PlanError
                  "rebuild-recovery-point"
                  ( "name the predecessor's newest verified recovery point with --recovery-point (db verify-escrowed-backup prints it)"
                      <> ", or start the volume empty with --fresh"
                  )
                  [member]
              )
  case rebuildTargets candidate history observed pointFor of
    Left errors -> do
      traverse_ (TIO.hPutStrLn stderr . renderError) (NE.toList errors)
      exitFailure
    Right [] -> dieT "no accepted durable member is confirmed absent; there is nothing to rebuild"
    Right targets -> do
      BL.writeFile output (Aeson.encode (RebuildInput (ResourceInventory.snapshotBinding snapshot) targets))
      traverse_ (\target -> TIO.putStrLn (renderRebuild (target ^. #resource) (target ^. #proof))) targets
      TIO.putStrLn ("Wrote " <> T.pack (show (length targets)) <> " rebuild decisions to " <> T.pack output <> "; review them, then run inventory rebuild --input.")

-- | Save the review that recreates the input's members and every absent
-- member of their scopes, from the accepted declarations, unchanged.
runInventoryRebuild :: Maybe String -> FilePath -> FilePath -> IO ()
runInventoryRebuild mctx input output = do
  active <- activeTarget mctx
  bytes <- BS.readFile input
  decisions <- either dieT pure (decodeRebuildInput bytes)
  snapshot <- Inventory.loadTargetSnapshot active
  let owners =
        Set.fromList
          [ member ^. #owner
          | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
          , bundle <- ResourceInventory.scopeBundles scope
          , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
          , (member ^. #identity) `elem` map (^. #resource) (decisions ^. #targets)
          ]
  when (Set.null owners) (dieT "the rebuild names no accepted member")
  (_, _, candidate, _) <- acceptedRebuild active (`Set.member` owners)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  native <- acceptedNative active
  Inventory.planInventoryCandidateWithDecider
    (inventoryPlanRegistryWithNative active workspace native)
    (\history observations -> decideRebuild candidate history observations decisions)
    active
    candidate
    output

-- | The accepted scopes selected (by default, those with a durable member)
-- replaced by themselves, and a registry over their accepted native evidence.
acceptedRebuild ::
  ActiveTarget ->
  (Resource.ScopeId -> Bool) ->
  IO (ResourceInventory.ScopeSnapshot, InventoryPlan.InventoryHistory, ResourceInventory.CompositionCandidate, InventoryAdapter.AdapterRegistry)
acceptedRebuild active selected = do
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let scopes =
        [ scope
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , selected (ResourceInventory.scopeId scope)
        , or
            [ True
            | bundle <- ResourceInventory.scopeBundles scope
            , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
            , Durable _ <- [member ^. #dataPolicy]
            , member ^. #executor == ResourceInventory.KubernetesExecutor
            ]
        ]
  changes <- maybe (dieT "no accepted scope holds a durable Kubernetes member") pure (NE.nonEmpty (map ResourceInventory.ReplaceScope scopes))
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot changes)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  native <- acceptedNative active
  registry <- inventoryPlanRegistryWithNative active workspace native candidate history
  pure (snapshot, history, candidate, registry)

acceptedNative :: ActiveTarget -> IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, BS.ByteString))
acceptedNative active = do
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  fst <$> (InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure)

-- | RESOURCE_ID=RECEIPT_URL@RECEIPT_DIGEST: a scheduled recovery point whose
-- receipt `db verify-escrowed-backup` verified.
parsePoint :: String -> Either Text (Resource.ResourceId, RecoveryPoint)
parsePoint argument = case T.breakOn "=" (T.pack argument) of
  (member, rest)
    | Just located <- T.stripPrefix "=" rest
    , (receipt', digestPart) <- T.breakOnEnd "@" located
    , not (T.null digestPart)
    , Just receipt <- T.stripSuffix "@" receipt' -> do
        resource <- Resource.mkResourceId member
        digest <- Resource.mkContentDigest digestPart
        pure (resource, RecoveryPoint ScheduledRecoveryPoint receipt digest)
  _ -> Left "--recovery-point is RESOURCE_ID=RECEIPT_URL@RECEIPT_SHA256"

renderError :: InventoryPlan.PlanError -> Text
renderError err =
  InventoryPlan.planErrorCode err
    <> ": "
    <> InventoryPlan.planErrorMessage err
    <> " ("
    <> T.intercalate ", " (map Resource.resourceIdText (InventoryPlan.planErrorResources err))
    <> ")"
