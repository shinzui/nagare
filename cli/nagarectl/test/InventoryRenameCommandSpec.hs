-- | The rename's operator commands driven through their command path on the
-- target's store and the modelled API: the reviewed rebind (F80) and
-- abandon-migration (F81).
module InventoryRenameCommandSpec (inventoryPostgresRenameTests, inventoryRenameCommandTests) where

import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM)
import Data.Aeson (Value (..), eitherDecodeStrict, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import InventoryApplicationRetireSpec (inventoryApplicationRetireTests)
import InventoryDatabaseEngineSpec (inventoryDatabaseEngineTests)
import InventoryPostgresRenameSpec
import InventoryRecoveryPointScanSpec (inventoryRecoveryPointScanTests)
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Secret (b64decode, b64encode)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesState (..), mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesMigration (MigrationPlanning (..), kubernetesMigrationAdapter, kubernetesMigrationExit, renameProposal)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps, parseObserved)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.Command (compileInput, openTargetStore, planInventoryAdoptionWith)
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (AbandonInput (..), AdmissionError (..), CloseInput (..), MigrationExit, TransactionResult (..), abandonMigration, applyReviewed, closeTransaction, resumeTransaction)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId, mkOperationId, transactionIdText)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Lifecycle (AdoptionInput (..), AdoptionTarget (..), decideAdoption)
import Nagare.Inventory.Migration (decideMigration)
import Nagare.Inventory.Migration.PostgresRename
import Nagare.Inventory.Migration.Types (migrationPoliciesCompatible)
import Nagare.Inventory.ObservationNative (loadObservationNative, observationKubernetes)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (DriftCategory (ReplacedIncarnation), DriftFinding (..), classifyDriftWith, loadKubernetesMembers, loadRebindNative, statusIncarnations)
import Nagare.Inventory.Store
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types hiding (resources)
import Nagare.Resource.Wire (CandidateInput (..), candidateInputValue, canonicalValue, encodeCanonicalScope)
import Nagare.Target (ActiveTarget (..), mkContextName, profileFromContextMap)
import Nagare.Test.Effectful.Fixture (checked, must, seedAccepted)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryRenameCommandTests :: TestTree
inventoryRenameCommandTests =
  testGroup
    "inventory PostgreSQL rename commands"
    [ inventoryDatabaseEngineTests
    , inventoryApplicationRetireTests
    , inventoryRecoveryPointScanTests
    , testCase "the adopt command issues a reviewed rebind for a database's replaced and unrecorded members (F80)" $
        withSystemTempDirectory "postgres-rename-rebind" $ \root -> withStateRoot root $ do
          store <- openTargetStore renameTarget
          probe <- newIORef Nothing
          (world, reviewed, executionRegistry') <- plannedRenameOn store recordOldIncarnations id probe
          renamed <- must (applyReviewed store executionRegistry' reviewed)
          case renamed of
            Converged _ -> pure ()
            other -> assertFailure ("rename did not converge: " <> describe reviewed other)
          -- Outside review, the claim is replaced; the Service is unrecorded, as
          -- a lost create response leaves it (ADR 27).
          let roleId role = fromJust (listToMaybe [identity | (identity, (declaration, _)) <- Map.toList newNative, roleOf declaration == role])
              pvc = roleId "pvc"
              service = roleId "service"
          modifyIORef' world (#objects %~ Map.adjust (setPath ["metadata", "uid"] (String "replacement-uid")) ("persistentvolumeclaim", "default", "nagare-db-pg-new-data"))
          dropped <- must (readHead store) >>= maybe (fail "missing head") pure
          _ <- must (replaceHeadIfGenerationMatches store (Just (headGeneration dropped)) dropped {headGeneration = headGeneration dropped + 1, headIncarnations = Map.delete service (headIncarnations dropped)})
          replacedMembers store world >>= (@?= [pvc])
          -- The documented path: an unchanged compiled candidate and a rebind
          -- proposal naming each member's live object.
          history <- must (loadInventoryHistory store)
          let snapshot = checked (mkScopeSnapshot binding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
              files = checked (compileInput (checked (canonicalValue (candidateInputValue (CandidateInput snapshot (ReplaceScope newScope :| []))))))
          createDirectoryIfMissing True (root </> "candidate" </> "scopes")
          mapM_ (\(path, bytes) -> BS.writeFile (root </> "candidate" </> path) bytes) files
          live <- newObjectUids <$> readIORef world
          let target identity = object ["resource" .= identity, "address" .= (fst (newNative Map.! identity) ^. #address), "physicalIdentity" .= (live Map.! identity), "rebind" .= True]
          BS.writeFile (root </> "rebind.json") (checked (canonicalValue (object ["version" .= (1 :: Int), "candidate" .= ("candidate" :: Text), "binding" .= binding, "resources" .= map target [pvc, service]])))
          planInventoryAdoptionWith (adoptionRegistry root store world probe) renameTarget (root </> "rebind.json") (root </> "review")
          bundle <- loadReviewBundle (root </> "review") >>= either (assertFailure . show) pure
          Map.keysSet (reviewRebinds (reviewBundleDocument bundle)) @?= Set.fromList [pvc, service]
          -- Apply it as `inventory apply` does: the review's own bytes, and the
          -- rebound members' accepted bytes, for admission's reverification.
          reviewedSpecs <- expectRight (kubernetesSpecsFromReview bundle)
          rebound <- must (loadRebindNative store (reviewBundleDocument bundle))
          Map.keysSet rebound @?= Set.fromList [pvc, service]
          let specs = Map.union reviewedSpecs rebound
              runtime = probed world probe
              execution = checked (mkAdapterRegistry [mkKubernetesAdapter specs (mkKubernetesRuntimeOps runtime specs)])
          published <- must (readReviewSnapshot store (reviewDigest bundle))
          rebind <- expectRight (verifyReview published bundle)
          applied <- must (applyReviewed store execution rebind)
          case applied of
            Converged _ -> pure ()
            other -> assertFailure ("the rebind did not converge: " <> describe rebind other)
          recorded <- headIncarnations <$> (must (readHead store) >>= maybe (fail "missing head") pure)
          final <- readIORef world
          Map.map physicalIdentityText recorded @?= newObjectUids final
          replacedMembers store world >>= (@?= [])
    , testCase "abandon-migration releases a rename's fence after its copy is refused, and accepts and deletes nothing (F81)" $
        withSystemTempDirectory "postgres-rename-abandon" $ \root -> withStateRoot root $ do
          store <- openTargetStore renameTarget
          probe <- newIORef Nothing
          (world, reviewed, executionRegistry') <- plannedRenameOn store recordOldIncarnations id probe
          -- The source volume is empty, so the copy script refuses it: a
          -- definite failure after the writer was fenced.
          modifyIORef' world (#volumes %~ Map.insert "nagare-db-pg-old-data" "")
          result <- must (applyReviewed store executionRegistry' reviewed)
          transaction <- case result of
            StoppedFailed stopped _ _ -> pure stopped
            other -> assertFailure ("the refused copy did not stop the rename: " <> describe reviewed other) >> fail "unreachable"
          fenced <- readIORef world
          assertBool ("the writer is not fenced before the exit: " <> describe reviewed result) (sourceWriterFenced fenced)
          let review = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
          closed <- closeTransaction store executionRegistry' (CloseInput transaction review False Nothing)
          assertBool ("close ended a fenced migration: " <> show closed) (either (any ((== "migration-fenced") . admissionErrorCode)) (const False) closed)
          _ <- must (abandonMigration store (renameRelease world id probe) (AbandonInput transaction review False))
          headAfter <- must (readHead store) >>= maybe (fail "missing head") pure
          headActiveTransaction headAfter @?= Nothing
          (revisionDigest <$> Map.lookup databaseOwner (headAccepted headAfter)) @?= Just (contentDigest (encodeCanonicalScope oldScope))
          headIncarnations headAfter @?= headIncarnations (recordOldIncarnations headAfter)
          final <- readIORef world
          assertBool "the writer is still fenced" (not (sourceWriterFenced final))
          assertBool "the backup schedule is still suspended" (not (sourceScheduleSuspended final))
          (jsonPath ["spec", "replicas"] =<< Map.lookup ("statefulset.apps", "default", "pg-old") (final ^. #objects)) @?= Just (Number 1)
          -- Nothing the rename created is deleted.
          assertBool "a destination object was deleted" (all (`Map.member` (final ^. #objects)) [key | (kind, namespace, name) <- map (fromJust . keyOf . checked . eitherDecodeStrict . snd) (Map.elems newNative), let key = (kind, namespace, name), Map.member key (fenced ^. #objects)])
          Map.lookup "nagare-db-pg-old-data" (final ^. #volumes) @?= Just ""
    , testCase "abandon-migration leaves a writer it did not fence as it is, so a replacement is never released (F81)" $
        withSystemTempDirectory "postgres-rename-abandon-replaced" $ \root -> withStateRoot root $ do
          store <- openTargetStore renameTarget
          probe <- newIORef Nothing
          (world, reviewed, executionRegistry') <- plannedRenameOn store recordOldIncarnations id probe
          modifyIORef' world (#volumes %~ Map.insert "nagare-db-pg-old-data" "")
          result <- must (applyReviewed store executionRegistry' reviewed)
          transaction <- case result of
            StoppedFailed stopped _ _ -> pure stopped
            other -> assertFailure ("the refused copy did not stop the rename: " <> describe reviewed other) >> fail "unreachable"
          -- Outside review, the fenced writer is recreated from its live
          -- manifest: a new UID, still scaled to zero under the fence.
          replaceOutOfBand world "" ("statefulset.apps", "default", "pg-old")
          let review = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
          _ <- must (abandonMigration store (renameRelease world id probe) (AbandonInput transaction review False))
          final <- readIORef world
          let writer = Map.lookup ("statefulset.apps", "default", "pg-old") (final ^. #objects)
          (jsonPath ["spec", "replicas"] =<< writer) @?= Just (Number 0)
          assertBool "the replacement's fence was released" (sourceWriterFenced final)
    , testCase "a stage write the API server refuses with a 4xx stops the rename with no effect, not ambiguous (F81, G4)" $
        withSystemTempDirectory "postgres-rename-refused-stage" $ \root -> do
          probe <- newIORef Nothing
          refused <- newIORef False
          -- The fence's conditional patch meets an object that moved since
          -- its read: the API server answers 409 and changes nothing.
          let conflict next request = case request ^. #arguments of
                "patch" : "statefulset.apps" : "pg-old" : _ -> do
                  already <- atomicModifyIORef' refused (True,)
                  if already
                    then next request
                    else pure (Right (ExitFailure 1, "", "Error from server (Conflict): Operation cannot be fulfilled on statefulsets.apps \"pg-old\": the object has been modified; please apply your changes to the latest version and try again"))
                _ -> next request
          (store, _, reviewed, registry) <- plannedRenameThrough recordOldIncarnations conflict probe root
          result <- must (applyReviewed store registry reviewed)
          case result of
            StoppedFailed _ _ (KnownNoEffect _) -> pure ()
            other -> assertFailure ("the refused stage write did not stop with no effect: " <> describe reviewed other)
    ]

-- | The context the command-path tests run in; its store is the target's.
renameTarget :: ActiveTarget
renameTarget = ActiveTarget (checked (mkContextName "rename-test")) (profileFromContextMap (Map.singleton "CLOUDSDK_CORE_PROJECT" "project"))

withStateRoot :: FilePath -> IO a -> IO a
withStateRoot root action =
  bracket
    (lookupEnv "XDG_STATE_HOME" <* setEnv "XDG_STATE_HOME" root)
    (maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME"))
    (const action)

-- | The planning registry `inventory adopt` builds: Kubernetes members' native
-- bytes resolved as the command resolves them (F80), observed in the world.
adoptionRegistry :: FilePath -> InventoryStore -> RenameWorld -> IORef (Maybe (IO ())) -> CompositionCandidate -> InventoryHistory -> IO AdapterRegistry
adoptionRegistry workspace store world probe candidate history = do
  let members = [member | Managed member <- inventoryDeclarations (candidateInventory candidate), member ^. #executor == KubernetesExecutor]
  native <- loadKubernetesMembers workspace store history members >>= either (assertFailure . T.unpack) pure
  pure (checked (mkAdapterRegistry [mkKubernetesAdapter native (mkKubernetesRuntimeOps (probed world probe) native)]))
