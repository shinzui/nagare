-- | EP-183 M4: rebuild the service after losing the VM. `inventory
-- rebuild-decisions` reads, for every accepted durable member whose object is
-- gone, the decision a rebuild needs and prints it; `inventory rebuild` saves
-- the review that recreates those members, and their scopes, from the
-- accepted declarations and native evidence. Executable-private CLI boundary.
module Nagare.Cli.Inventory.Rebuild
  ( runInventoryRebuildDecisions
  , runInventoryRebuild
  , offlineStore
  )
where

import Control.Monad (forM)
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
import Nagare.Cli.Data.SigningKeyEscrow (withRecoveryStore)
import Nagare.Cli.Data.VolumeRebuildRestore (recordedVolumeRun, recordedVolumeSnapshot)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter qualified as InventoryAdapter
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Lineage (RebuildSource (..), RecoveryPoint (..), RecoveryPointKind (ScheduledRecoveryPoint, ScheduledVolumeRecoveryPoint, VolumeSnapshotRecoveryPoint), renderRebuild)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Rebuild (RebuildInput (..), decideRebuild, decodeRebuildInput, rebuildTargets)
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.VolumeRestoreSource (verifyIngestedVolumeRun, verifyRecordedVolumeSnapshot)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (DataPolicy (Durable))
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, contextNameText)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Both offline object-store options, or neither (F41).
offlineStore :: Maybe String -> Maybe FilePath -> IO (Maybe (String, FilePath))
offlineStore store credentials = case (store, credentials) of
  (Nothing, Nothing) -> pure Nothing
  (Just endpoint, Just file) -> pure (Just (endpoint, file))
  _ -> dieT "--offline-object-store and --offline-credentials are required together"

-- | Read-only: observe every accepted durable member, and print one rebuild
-- decision for each whose object is confirmed absent. A database volume names
-- the scheduled recovery point given for it; an application volume names an
-- accepted manual snapshot, verified here from the object store (or an
-- offline copy); a volume starts fresh only when the operator says so.
runInventoryRebuildDecisions :: Maybe String -> [String] -> [String] -> [String] -> [String] -> Maybe String -> Maybe (String, FilePath) -> FilePath -> IO ()
runInventoryRebuildDecisions mctx pointArgs snapshotArgs runArgs freshArgs bucketArg offline output = do
  active <- activeTarget mctx
  scheduled <- either dieT pure (traverse parsePoint pointArgs)
  fresh <- either dieT pure (traverse (Resource.mkResourceId . T.pack) freshArgs)
  (snapshot, history, candidate, registry) <- acceptedRebuild active (const True)
  snapshots <- case snapshotArgs of
    [] -> pure []
    _ -> do
      backend <- resolveStoreBackend mctx bucketArg
      forM snapshotArgs $ \argument -> do
        (member, snapshotId) <- either dieT pure (parseSnapshot argument)
        scope <- either dieT pure (recordedVolumeSnapshot snapshot member ((== Just snapshotId) . Map.lookup "volume-backup.id"))
        recovery <-
          withRecoveryStore (contextNameText (active ^. #contextName)) backend offline (\reader -> verifyRecordedVolumeSnapshot reader scope)
            >>= either dieT pure
        pure (member, (RecoveryPoint VolumeSnapshotRecoveryPoint (recovery ^. #receiptUrl) (recovery ^. #receiptDigest), Just (recovery ^. #sourcePvcUid)))
  -- EP-183 M3: an application volume may also name an accepted scheduled run.
  runs <- case runArgs of
    [] -> pure []
    _ -> do
      backend <- resolveStoreBackend mctx bucketArg
      forM runArgs $ \argument -> do
        (member, runId) <- either dieT pure (parseMemberValue "--volume-run" "RUN_ID" argument)
        scope <- either dieT pure (recordedVolumeRun snapshot member ((== Just runId) . Map.lookup "scheduled.backup.id"))
        recovery <-
          withRecoveryStore (contextNameText (active ^. #contextName)) backend offline (\reader -> verifyIngestedVolumeRun reader scope)
            >>= either dieT pure
        pure (member, (RecoveryPoint ScheduledVolumeRecoveryPoint (recovery ^. #receiptUrl) (recovery ^. #receiptDigest), Just (recovery ^. #sourcePvcUid)))
  let points = [(member, (point, Nothing)) | (member, point) <- scheduled] <> snapshots <> runs
  observed <-
    InventoryAdapter.observeWithRegistry registry (InventoryPlan.requirementsByExecutor (InventoryPlan.observationRequirements candidate history))
      >>= either dieT pure
  let pointFor member predecessor
        | member `elem` fresh = Right Fresh
        | Just (point, source') <- lookup member points
        , Just _ <- predecessor
        , maybe True ((== predecessor) . Just) source' =
            Right (FromRecoveryPoint point)
        | Just (_, Just _) <- lookup member points =
            Left (InventoryPlan.PlanError "rebuild-recovery-point" "the snapshot was taken from another incarnation than the volume's recorded predecessor" [member])
        | otherwise =
            Left
              ( InventoryPlan.PlanError
                  "rebuild-recovery-point"
                  ( "name the predecessor's newest verified recovery point with --recovery-point (db verify-escrowed-backup prints it)"
                      <> ", --volume-snapshot or --volume-run, or start the volume empty with --fresh"
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

-- | RESOURCE_ID=SNAPSHOT_ID: an accepted manual snapshot of that claim.
parseSnapshot :: String -> Either Text (Resource.ResourceId, Text)
parseSnapshot = parseMemberValue "--volume-snapshot" "SNAPSHOT_ID"

-- | RESOURCE_ID=VALUE for the named option.
parseMemberValue :: Text -> Text -> String -> Either Text (Resource.ResourceId, Text)
parseMemberValue option valueName argument = case T.breakOn "=" (T.pack argument) of
  (member, rest)
    | Just value <- T.stripPrefix "=" rest
    , not (T.null value) ->
        (,value) <$> Resource.mkResourceId member
  _ -> Left (option <> " is RESOURCE_ID=" <> valueName)

renderError :: InventoryPlan.PlanError -> Text
renderError err =
  InventoryPlan.planErrorCode err
    <> ": "
    <> InventoryPlan.planErrorMessage err
    <> " ("
    <> T.intercalate ", " (map Resource.resourceIdText (InventoryPlan.planErrorResources err))
    <> ")"
