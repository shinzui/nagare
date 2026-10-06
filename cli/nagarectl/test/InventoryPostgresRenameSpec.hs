-- | The bounded retained PostgreSQL rename (IR-24 case 3): pure contract
-- checks and a full reviewed run through the production planner, admission
-- and serial driver against a modelled Kubernetes API.
module InventoryPostgresRenameSpec
  ( inventoryPostgresRenameTests
  , RenameWorld
  , databaseOwner
  , newScope
  , plannedRenameThrough
  , recordOldIncarnations
  , renameVolumes
  , replacedMembers
  , transferJobs
  , destinationCopies
  , armPartialCopy
  , verifyRenamedWorld
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.Aeson (Value (..), eitherDecodeStrict, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.IORef
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Secret (b64decode, b64encode)
import Nagare.Dsl.Database (Database (Database), Engine (..), defaultEngineVersion, mkDatabaseName, mkEngineVersion)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesState (..), mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesMigration (MigrationPlanning (..), kubernetesMigrationAdapter, renameProposal)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps, parseObserved)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (OperationId, mkOperationId)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Migration (decideMigration)
import Nagare.Inventory.Migration.PostgresRename
import Nagare.Inventory.Migration.Types (migrationPoliciesCompatible)
import Nagare.Inventory.ObservationNative (loadObservationNative, observationKubernetes)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (DriftCategory (ReplacedIncarnation), DriftFinding (..), classifyDriftWith, statusIncarnations)
import Nagare.Inventory.Store
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types hiding (resources)
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import Nagare.Test.Effectful.Fixture (checked, must, seedAccepted)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryPostgresRenameTests :: TestTree
inventoryPostgresRenameTests =
  testGroup
    "inventory PostgreSQL rename"
    [ testCase "every compiled PostgreSQL member has a bounded rename role" $ do
        let roles = sortOn fst [(roleOf declaration, renameMember declaration) | (declaration, _) <- Map.elems oldNative]
        map snd roles
          @?= map
            Right
            [ RenameSchedule
            , RenameObject
            , RenameObject
            , RenameObject
            , RenameSigningKey
            , RenameCredential
            , RenameVolume
            , RenameObject
            , RenameWorkload
            ]
        facts <- expectRight (renameScope oldNative newNative databaseOwner)
        nameText (facts ^. #sourceDatabase) @?= "pg-old"
        nameText (facts ^. #destinationDatabase) @?= "pg-new"
        Map.keysSet oldNative @?= Map.keysSet newNative
    , testCase "rename refuses an image change and a non-PostgreSQL engine" $ do
        let upgraded = snd (compiled "pg-new" (database "pg-new" & #version .~ checked (mkEngineVersion Postgres "17")))
            redisOld = snd (compiled "pg-old" (database "pg-old" & #engine .~ Redis & #version .~ defaultEngineVersion Redis))
            redisNew = snd (compiled "pg-new" (database "pg-new" & #engine .~ Redis & #version .~ defaultEngineVersion Redis))
        assertLeft (renameScope oldNative upgraded databaseOwner)
        assertLeft (renameScope redisOld redisNew databaseOwner)
    , testCase "credential copy rewrites only the connection host" $ do
        facts <- expectRight (renameScope oldNative newNative databaseOwner)
        let fields = credentialData "pg-old"
        rewritten <- expectRight (rewriteCredentialData facts fields)
        KM.delete "DATABASE_URL" rewritten @?= KM.delete "DATABASE_URL" fields
        decoded "DATABASE_URL" rewritten @?= "postgresql://nagare:secret-password@pg-new.default.svc.cluster.local:5432/pg_old"
        assertLeft (rewriteCredentialData facts (credentialData "other"))
    , testCase "a renamed recovery credential keeps the data policies compatible" $ do
        let pairs = [(old, fst (newNative Map.! identity)) | (identity, (old, _)) <- Map.toList oldNative]
        assertBool "every member keeps a compatible policy" (all (\(old, new) -> migrationPoliciesCompatible pairs old new) pairs)
        let credentialless = [pair | pair@(old, _) <- pairs, roleOf old /= "credential"]
        (pvcOld, pvcNew) <- case [pair | pair@(old, _) <- pairs, roleOf old == "pvc"] of
          [pair] -> pure pair
          _ -> assertFailure "fixture lacks one PVC member" >> fail "unreachable"
        let otherBackup = pvcNew & #dataPolicy .~ Durable (RecoveryIntent (checked (mkName "other")) (mkSecretRef (checked (mkName "nagare-db-pg-new")) (checked (mkName "v1")) :| []))
        migrationPoliciesCompatible credentialless pvcOld pvcNew @?= False
        migrationPoliciesCompatible pairs pvcOld otherBackup @?= False
    , testCase "transfer accepts only equal manifests and never writes its source" $ do
        let digest = T.replicate 64 "a"
            other = T.replicate 64 "b"
            message source destination = TE.encodeUtf8 ("{\"source\":\"" <> source <> "\",\"destination\":\"" <> destination <> "\"}")
        parseTransferManifest (message digest digest) @?= Right (TransferManifest digest digest)
        assertLeft (parseTransferManifest (message digest other))
        assertLeft (parseTransferManifest "{\"error\":\"destination volume is not empty and differs from the source\"}")
        facts <- expectRight (renameScope oldNative newNative databaseOwner)
        let job = transferJob facts "tx-test op-000000000000000000000001" (checked (mkOperationIdText "op-000000000000000000000001")) TransferCopy (checked (mkName "src")) (checked (mkName "dst"))
            volumes = jsonPath ["spec", "template", "spec", "volumes"] job
        assertBool
          "source claim is mounted read-only"
          (Just (Bool True) == (volumes >>= firstVolume >>= jsonPath ["persistentVolumeClaim", "readOnly"]))
    , testCase "a fenced StatefulSet or suspended schedule is its retained incarnation, not drift" $ do
        (declaration, native) <- case [entry | entry@(member, _) <- Map.elems oldNative, roleOf member == "statefulset"] of
          [entry] -> pure entry
          _ -> assertFailure "fixture lacks one StatefulSet" >> fail "unreachable"
        let live = stamped (declaration ^. #identity) native "sts-uid"
            fenced = setPath ["spec", "replicas"] (Number 0) (setPath ["metadata", "annotations", "nagare.dev/migration-fence"] (String "op-x") live)
            scaled = setPath ["spec", "replicas"] (Number 0) live
            observe value = parseObserved config (declaration ^. #identity) native (TE.decodeUtf8 (checked (canonicalValue value)))
        case observe fenced of
          Right (KubernetesNotReady _ _ _ digest) -> digest @?= contentDigest native
          other -> assertFailure ("fenced StatefulSet was not its retained incarnation: " <> show other)
        case observe scaled of
          Right state -> assertBool "unmarked scale-down must remain drift" (stateDigest state /= Just (contentDigest native))
          Left reason -> assertFailure (T.unpack reason)
        (schedule, scheduleNative) <- case [entry | entry@(member, _) <- Map.elems oldNative, roleOf member == "backup"] of
          [entry] -> pure entry
          _ -> assertFailure "fixture lacks one backup schedule" >> fail "unreachable"
        let suspended = setPath ["spec", "suspend"] (Bool True) (setPath ["metadata", "annotations", "nagare.dev/migration-fence"] (String "op-x") (stamped (schedule ^. #identity) scheduleNative "cron-uid"))
        case parseObserved config (schedule ^. #identity) scheduleNative (TE.decodeUtf8 (checked (canonicalValue suspended))) of
          Right (KubernetesNotReady _ _ _ digest) -> digest @?= contentDigest scheduleNative
          other -> assertFailure ("suspended schedule was not its retained incarnation: " <> show other)
    , testCase "reviewed rename converges and retains every old incarnation" $
        withSystemTempDirectory "postgres-rename" $ \root -> do
          (store, world, reviewed, executionRegistry') <- plannedRename root
          result <- must (applyReviewed store executionRegistry' reviewed)
          case result of
            Converged _ -> pure ()
            other -> assertFailure ("rename did not converge: " <> describe reviewed other)
          final <- readIORef world
          verifyRenamedWorld final
          headAfter <- must (readHead store) >>= maybe (fail "missing head") pure
          Map.keysSet (headRetained headAfter) @?= Map.keysSet oldNative
          assertBool
            "retained incarnations keep their reviewed physical identities"
            (all (\(identity, incarnation) -> physicalIdentityText (retainedPhysical incarnation) == uidFor identity) (Map.toList (headRetained headAfter)))
          assertBool "every retained incarnation names its migration review" (all (isJust . retainedMigrationReview) (Map.elems (headRetained headAfter)))
          -- Status and later planning read accepted members from observation
          -- evidence published with the review, not from the private bundle.
          observed <- loadObservationNative store (map fst (Map.elems newNative))
          case observed of
            Right native -> Map.map snd (observationKubernetes native) @?= Map.map snd newNative
            Left reason -> assertFailure ("renamed members lack observation evidence: " <> T.unpack reason)
    , testCase "a rename refuses a source replaced outside Nagare, at planning (F62)" $
        withSystemTempDirectory "postgres-rename-replaced" $ \root -> do
          probe <- newIORef Nothing
          let replacedSources headValue = headValue {headIncarnations = Map.fromList [(identity, checked (mkPhysicalIdentity ("replaced-" <> uidFor identity))) | identity <- Map.keys oldNative]}
          planned <- try @SomeException (plannedRenameWith replacedSources probe root)
          case planned of
            Left err -> assertBool (show err) ("migration-source-incarnation" `T.isInfixOf` T.pack (show err))
            Right _ -> assertFailure "a rename planned from a replaced source"
    , testCase "a rename refuses a writer replaced between planning's reads (ADR 27, A52)" $ do
        -- The k-th and later reads of the writer StatefulSet return a replacement;
        -- some k leaves the planner's checks on the accepted object and only
        -- prepare's writer read on the replacement.
        outcomes <- forM [1 .. 6 :: Int] $ \k -> withSystemTempDirectory "postgres-rename-writer" $ \root -> do
          reads <- newIORef (0 :: Int)
          probe <- newIORef Nothing
          planned <- try @SomeException (plannedRenameThrough recordOldIncarnations (swapWriterAfter k reads) probe root)
          pure (either (T.pack . show) (const "planned") planned)
        assertBool (show outcomes) (any ("the rename writer" `T.isInfixOf`) outcomes)
    , testCase "status never reports a renamed member as replaced, at any step (F52)" $
        withSystemTempDirectory "postgres-rename-status" $ \root -> do
          probe <- newIORef Nothing
          (store, world, reviewed, executionRegistry') <- plannedRenameWith recordOldIncarnations probe root
          replaced <- newIORef []
          let check = replacedMembers store world >>= \found -> modifyIORef' replaced (<> found)
          writeIORef probe (Just check)
          result <- must (applyReviewed store executionRegistry' reviewed)
          writeIORef probe Nothing
          check
          case result of
            Converged _ -> pure ()
            other -> assertFailure ("rename did not converge: " <> describe reviewed other)
          readIORef replaced >>= (@?= [])
          -- Convergence records the renamed data-bearing members' new objects.
          recorded <- headIncarnations <$> (must (readHead store) >>= maybe (fail "missing head") pure)
          assertBool "the renamed members' new objects are not recorded" (not (Map.null recorded))
          assertBool "a record still names an old object" (all (\(identity, physical) -> physicalIdentityText physical /= uidFor identity) (Map.toList recorded))
    , testCase "a lost transfer acknowledgement resumes without a second copy" $
        withSystemTempDirectory "postgres-rename-loss" $ \root -> do
          (store, world, reviewed, executionRegistry') <- plannedRename root
          modifyIORef' world (#loseJobAck .~ True)
          stopped <- must (applyReviewed store executionRegistry' reviewed)
          transaction <- case stopped of
            StoppedAmbiguous transaction _ -> pure transaction
            other -> assertFailure ("lost acknowledgement did not stop the run: " <> show other) >> fail "unreachable"
          resumed <- must (resumeTransaction store executionRegistry' transaction)
          case resumed of
            Converged _ -> pure ()
            other -> assertFailure ("resume did not converge: " <> describe reviewed other)
          final <- readIORef world
          verifyRenamedWorld final
          length (filter (T.isPrefixOf "job.batch/nagare-migrate-") (final ^. #created))
            @?= 2
    , testCase "a transfer refuses while another pod mounts the destination (F61)" $
        withSystemTempDirectory "postgres-rename-mounted" $ \root -> do
          (store, world, reviewed, executionRegistry') <- plannedRename root
          let intruder = object ["metadata" .= object ["name" .= ("intruder" :: Text)], "spec" .= object ["volumes" .= [object ["persistentVolumeClaim" .= object ["claimName" .= ("nagare-db-pg-new-data" :: Text)]]]]]
          modifyIORef' world (#objects %~ Map.insert ("pod", "default", "intruder") intruder)
          result <- must (applyReviewed store executionRegistry' reviewed)
          case result of
            Converged _ -> assertFailure "the rename copied into a destination another pod mounts"
            _ -> pure ()
          final <- readIORef world
          destinationCopies final @?= 0
    , testCase "a changed source incarnation refuses admission before any effect" $
        withSystemTempDirectory "postgres-rename-race" $ \root -> do
          (store, world, reviewed, executionRegistry') <- plannedRename root
          modifyIORef' world (#objects %~ Map.adjust (setPath ["metadata", "uid"] (String "replacement-uid")) ("statefulset.apps", "default", "pg-old"))
          before <- readIORef world
          result <- applyReviewed store executionRegistry' reviewed
          case result of
            Left _ -> pure ()
            Right (StoppedFailed _ _ _) -> pure ()
            Right other -> assertFailure ("changed source was admitted: " <> show other)
          final <- readIORef world
          final ^. #created @?= before ^. #created
    ]

-- Fixture -----------------------------------------------------------------

binding :: ContextBinding
binding = ContextBinding (checked (mkContextId "rename-test")) (checked (mkName "project"))

databaseOwner :: ScopeId
databaseOwner = checked (mkScopeId Standalone "database-pg-old")

clusterId :: ResourceId
clusterId = mintResourceId (checked (mkScopeId Platform "cluster")) (checked (mkLogicalKey "cluster")) (checked (mkName "cluster"))

database :: Text -> Database
database name =
  Database
    (checked (mkDatabaseName name))
    (Just (checked (mkLogicalKey "pg-old")))
    Postgres
    (defaultEngineVersion Postgres)
    (checked (Dsl.mkNamespace "default"))
    (checked (Dsl.mkQuantity "1Gi"))
    Nothing
    Dsl.Retain

compiled :: Text -> Database -> (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compiled name value =
  checked
    ( compileStandaloneDatabase
        (DatabaseDirectInput value databaseOwner clusterId Nothing recovery (SourceLocation "rename-test" name))
        (DatabaseBackupTarget (GcsBackend "project" "bucket") HourlyRecoveryPoint)
    )
  where
    recovery = RecoveryIntent (checked (mkName "backup")) (mkSecretRef (checked (mkName ("nagare-db-" <> name))) (checked (mkName "v1")) :| [])

oldScope :: ScopeDeclaration
oldNative :: Map ResourceId (ManagedResource, ByteString)
(oldScope, oldNative) = compiled "pg-old" (database "pg-old")

newScope :: ScopeDeclaration
newNative :: Map ResourceId (ManagedResource, ByteString)
(newScope, newNative) = compiled "pg-new" (database "pg-new")

roleOf :: ManagedResource -> Text
roleOf declaration = last (T.splitOn "/" (resourceIdText (declaration ^. #identity)))

uidFor :: ResourceId -> Text
uidFor identity = "old-" <> roleOf (fst (oldNative Map.! identity)) <> "-uid"

credentialData :: Text -> KM.KeyMap Value
credentialData host =
  KM.fromList
    [ ("POSTGRES_PASSWORD", String (b64encode "secret-password"))
    , ("POSTGRES_USER", String (b64encode "nagare"))
    , ("POSTGRES_DB", String (b64encode "pg_old"))
    , ("DATABASE_URL", String (b64encode ("postgresql://nagare:secret-password@" <> host <> ".default.svc.cluster.local:5432/pg_old")))
    ]

signingData :: KM.KeyMap Value
signingData = KM.fromList [("HMAC_KEY", String (b64encode (T.replicate 64 "c")))]

decoded :: Key.Key -> KM.KeyMap Value -> Text
decoded key fields = case KM.lookup key fields of
  Just (String value) -> either id id (b64decode value)
  _ -> ""

config :: KubernetesRuntimeConfig
config = KubernetesRuntimeConfig (binding ^. #identity) "rename-test" (pure (Right ()))

-- Modelled Kubernetes API ---------------------------------------------------

data World = World
  { objects :: !(Map (Text, Text, Text) Value)
  , volumes :: !(Map Text Text)
  , counter :: !Int
  , created :: ![Text]
  , loseJobAck :: !Bool
  , destinationWrites :: !Int
  -- ^ Copies into an empty destination volume; a retried copy only compares.
  , partialCopyOnce :: !Bool
  -- ^ The next copy into an empty destination dies part way (an evicted pod,
  -- a full disk): it leaves partial data and fails.
  }
  deriving stock (Generic)

modelled :: IORef World -> KubernetesRuntimeConfig
modelled world = withKubectlInterpreter (runKubectlWith (handle world)) config

-- | The modelled API, running a probe after every request; the probe's own
-- requests do not run it again.
probed :: IORef World -> IORef (Maybe (IO ())) -> KubernetesRuntimeConfig
probed world = probedThrough world id

-- | 'probed' with the API's transport wrapped (the rename recovery model's
-- adversary).
probedThrough :: IORef World -> Transport -> IORef (Maybe (IO ())) -> KubernetesRuntimeConfig
probedThrough world transport probe = withKubectlInterpreter (runKubectlWith answer) config
  where
    answer request = do
      result <- transport (handle world) request
      pending <- readIORef probe
      mapM_ (\check -> writeIORef probe Nothing >> check >> writeIORef probe (Just check)) pending
      pure result

-- | The members status reports `replaced-incarnation`, computed as `inventory
-- status` computes them.
replacedMembers :: InventoryStore -> IORef World -> IO [ResourceId]
replacedMembers store world = do
  history <- must (loadInventoryHistory store)
  let accepted = historyAccepted history
      inventory = checked (composeSnapshot (checked (mkScopeSnapshot binding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) (historyReservations history))))
      renamed = (revisionDigest . fst <$> Map.lookup databaseOwner accepted) == Just (contentDigest (encodeCanonicalScope newScope))
      native = if renamed then newNative else oldNative
      registry = checked (mkAdapterRegistry [mkKubernetesAdapter native (mkKubernetesRuntimeOps (modelled world) native)])
      members = [resource ^. #identity | Managed resource <- inventoryDeclarations inventory]
  observed <- must (observeWithRegistry registry (Map.singleton KubernetesExecutor members))
  incarnations <- must (statusIncarnations store (historyHead history))
  pure [findingResource finding | finding <- classifyDriftWith incarnations inventory observed, findingCategory finding == ReplacedIncarnation]

-- | The accepted old database's members, recorded as converged (F49).
recordOldIncarnations :: HeadManifest -> HeadManifest
recordOldIncarnations headValue =
  headValue {headIncarnations = Map.fromList [(identity, checked (mkPhysicalIdentity (uidFor identity))) | identity <- Map.keys oldNative]}

handle :: IORef World -> KubectlRequest -> IO KubectlResult
handle world request = atomicModifyIORef' world (respond (request ^. #arguments) (request ^. #input))

respond :: [String] -> String -> World -> (World, KubectlResult)
respond arguments body state = case arguments of
  ("get" : "pods" : rest)
    | Just selector <- flag "-l" rest
    , Just job <- T.stripPrefix "batch.kubernetes.io/job-name=" (T.pack selector) ->
        ok state (object ["items" .= [pod | ((kind, _, _), pod) <- Map.toList (state ^. #objects), kind == "pod", jsonPath ["metadata", "labels", "batch.kubernetes.io/job-name"] pod == Just (String job)]])
  ("get" : "pods" : rest)
    | Just namespace <- flag "--namespace" rest ->
        ok state (object ["items" .= [pod | ((kind, podNamespace, _), pod) <- Map.toList (state ^. #objects), kind == "pod", podNamespace == T.pack namespace]])
  ("get" : kind : name : rest) ->
    let key = (T.pack kind, maybe "" T.pack (flag "--namespace" rest), T.pack name)
     in (state, Right (ExitSuccess, maybe "" encodeText (Map.lookup key (state ^. #objects)), ""))
  ("create" : _) -> case eitherDecodeStrict (TE.encodeUtf8 (T.pack body)) of
    Right value
      | Just key <- keyOf value
      , Map.notMember key (state ^. #objects) ->
          let next = createObject key value state
              lost = (state ^. #loseJobAck) && fst3 key == "job.batch"
           in if lost
                then (next & #loseJobAck .~ False, Right (ExitFailure 1, "", "lost acknowledgement"))
                else (next, Right (ExitSuccess, maybe "" encodeText (Map.lookup key (next ^. #objects)), ""))
    _ -> (state, Right (ExitFailure 1, "", "create refused"))
  ("patch" : kind : name : rest)
    | Just patch <- flag "-p" rest
    , Right value <- eitherDecodeStrict (TE.encodeUtf8 (T.pack patch)) ->
        let key = (T.pack kind, maybe "" T.pack (flag "--namespace" rest), T.pack name)
         in case Map.lookup key (state ^. #objects) of
              Just current
                | jsonPath ["metadata", "uid"] value == jsonPath ["metadata", "uid"] current
                , jsonPath ["metadata", "resourceVersion"] value == jsonPath ["metadata", "resourceVersion"] current ->
                    (patchObject key current value state, Right (ExitSuccess, "", ""))
              _ -> (state, Right (ExitFailure 1, "", "conflict"))
  ["delete", "--raw", path, "-f", "-"]
    | ["", "apis", "batch", "v1", "namespaces", namespace, "jobs", name] <- T.splitOn "/" (T.pack path)
    , Right options <- eitherDecodeStrict (TE.encodeUtf8 (T.pack body)) ->
        let key = ("job.batch", namespace, name)
         in case Map.lookup key (state ^. #objects) of
              Just current
                | jsonPath ["preconditions", "uid"] options == jsonPath ["metadata", "uid"] current ->
                    ( state & #objects %~ Map.filterWithKey (\(kind, _, _) value -> not (kind == "pod" && jsonPath ["metadata", "labels", "batch.kubernetes.io/job-name"] value == Just (String name))) . Map.delete key
                    , Right (ExitSuccess, "", "")
                    )
              _ -> (state, Right (ExitFailure 1, "", "precondition failed"))
  ("wait" : _) -> (state, Right (ExitSuccess, "", ""))
  ("rollout" : "status" : _) -> (state, Right (ExitSuccess, "", ""))
  _ -> (state, Right (ExitFailure 1, "", "unmodelled request: " <> unwords arguments))
  where
    ok next value = (next, Right (ExitSuccess, encodeText value, ""))
    fst3 (value, _, _) = value

createObject :: (Text, Text, Text) -> Value -> World -> World
createObject key@(kind, namespace, name) value state =
  let uid = "new-" <> T.pack (show (state ^. #counter))
      base = setPath ["metadata", "resourceVersion"] (String "1") (setPath ["metadata", "uid"] (String uid) value)
      recorded = state & #counter %~ (+ 1) & #created %~ (<> [kind <> "/" <> name])
   in case kind of
        "statefulset.apps" ->
          recorded
            & #objects
            %~ Map.insert key (runningStatefulSet base)
            & #objects
            %~ Map.insert ("pod", namespace, name <> "-0") (object ["metadata" .= object ["name" .= (name <> "-0")]])
        "persistentvolumeclaim" ->
          recorded
            & #objects
            %~ Map.insert key (setPath ["status", "phase"] (String "Bound") base)
            & #volumes
            %~ Map.insertWith (\_ existing -> existing) name ""
        "job.batch" -> runJob key base recorded
        _ -> recorded & #objects %~ Map.insert key base

runJob :: (Text, Text, Text) -> Value -> World -> World
runJob key@(_, namespace, name) job state =
  let container = jsonPath ["spec", "template", "spec", "containers"] job >>= firstVolume
      mode = case container >>= jsonPath ["env"] >>= firstVolume >>= jsonPath ["value"] of
        Just (String value) -> value
        _ -> ""
      -- The mark the script writes: this Job's transaction and operation.
      jobMark = case container >>= jsonPath ["env"] of
        Just (Array entries) -> fromMaybe "" (listToMaybe [value | entry <- V.toList entries, jsonPath ["name"] entry == Just (String "TRANSFER_MARK"), Just (String value) <- [jsonPath ["value"] entry]])
        _ -> ""
      marked = incompleteMark <> jobMark <> ":"
      redoable content = T.null content || marked `T.isPrefixOf` content
      claims = case jsonPath ["spec", "template", "spec", "volumes"] job of
        Just (Array entries) -> [claim | Just (String claim) <- map (jsonPath ["persistentVolumeClaim", "claimName"]) (V.toList entries)]
        _ -> []
      (outcome, nextVolumes) = case claims of
        [source, destination]
          | mode == "copy"
          , state ^. #partialCopyOnce
          , T.null (Map.findWithDefault "" destination (state ^. #volumes)) ->
              (Left ("copy failed" :: Text), Map.insert destination (marked <> "pgdata:partial") (state ^. #volumes))
        [source, destination] ->
          let sourceContent = Map.findWithDefault "" source (state ^. #volumes)
              destinationContent = Map.findWithDefault "" destination (state ^. #volumes)
              -- F61: a copy redoes an empty or incompletely copied destination.
              copied = if mode == "copy" && redoable destinationContent then sourceContent else destinationContent
           in if not (T.null sourceContent) && copied == sourceContent
                then (Right (digestText (contentDigest (TE.encodeUtf8 sourceContent))), Map.insert destination copied (state ^. #volumes))
                else (Left ("destination volume is not empty and differs from the source" :: Text), state ^. #volumes)
        _ -> (Left "transfer Job needs two claims", state ^. #volumes)
      uid = fromMaybe "" (jsonText ["metadata", "uid"] job)
      message = either (\reason -> "{\"error\":\"" <> reason <> "\"}") (\digest -> "{\"source\":\"" <> digest <> "\",\"destination\":\"" <> digest <> "\"}") outcome
      podValue =
        object
          [ "metadata"
              .= object
                [ "name" .= (name <> "-pod")
                , "labels" .= object ["batch.kubernetes.io/job-name" .= name]
                , "ownerReferences" .= [object ["kind" .= ("Job" :: Text), "uid" .= uid, "controller" .= True]]
                ]
          , "status"
              .= object
                [ "phase" .= either (const ("Failed" :: Text)) (const "Succeeded") outcome
                , "containerStatuses"
                    .= [object ["name" .= ("transfer" :: Text), "state" .= object ["terminated" .= object ["exitCode" .= either (const (1 :: Int)) (const 0) outcome, "message" .= message]]]]
                ]
          ]
      status = either (const (object ["failed" .= (1 :: Int)])) (const (object ["succeeded" .= (1 :: Int)])) outcome
      wrote =
        mode == "copy"
          && redoable (Map.findWithDefault "" (fromMaybe "" (listToMaybe (drop 1 claims))) (state ^. #volumes))
          && isRight outcome
   in state
        & #partialCopyOnce
        .~ (state ^. #partialCopyOnce && mode /= "copy")
        & #destinationWrites
        %~ (if wrote then (+ 1) else id)
        & #volumes
        .~ nextVolumes
        & #objects
        %~ Map.insert key (setPath ["status"] status job)
        & #objects
        %~ Map.insert ("pod", namespace, name <> "-pod") podValue

patchObject :: (Text, Text, Text) -> Value -> Value -> World -> World
patchObject key@(kind, namespace, name) current patch state =
  let merged = setPath ["metadata", "resourceVersion"] (String "2") (merge current patch)
      scaledDown = kind == "statefulset.apps" && jsonPath ["spec", "replicas"] merged == Just (Number 0)
      settled = if scaledDown then setPath ["status", "replicas"] (Number 0) (setPath ["status", "readyReplicas"] (Number 0) merged) else merged
   in state
        & #objects
        %~ Map.insert key settled
        & #objects
        %~ (if scaledDown then Map.delete ("pod", namespace, name <> "-0") else id)
  where
    merge (Object left) (Object right) = Object (KM.unionWith merge left right)
    merge _ right = right

runningStatefulSet :: Value -> Value
runningStatefulSet value =
  let replicas = fromMaybe (Number 1) (jsonPath ["spec", "replicas"] value)
   in setPath ["metadata", "generation"] (Number 1) $
        setPath
          ["status"]
          (object ["replicas" .= replicas, "readyReplicas" .= replicas, "updatedReplicas" .= replicas, "observedGeneration" .= (1 :: Int)])
          value

keyOf :: Value -> Maybe (Text, Text, Text)
keyOf value = do
  String apiVersion <- jsonPath ["apiVersion"] value
  String kind <- jsonPath ["kind"] value
  name <- jsonText ["metadata", "name"] value
  let group = if "/" `T.isInfixOf` apiVersion then T.takeWhile (/= '/') apiVersion else ""
      token = T.toLower kind <> if T.null group then "" else "." <> group
  pure (token, fromMaybe "" (jsonText ["metadata", "namespace"] value), name)

-- The accepted old database as the API server holds it.
seededWorld :: World
seededWorld =
  World
    { objects =
        Map.fromList
          ( [ (fromJust (keyOf value), value)
            | (identity, (declaration, native)) <- Map.toList oldNative
            , let base = stamped identity native (uidFor identity)
                  value = case roleOf declaration of
                    "credential" -> setPath ["data"] (Object (credentialData "pg-old")) base
                    "backup-signing-key" -> setPath ["data"] (Object signingData) base
                    "statefulset" -> runningStatefulSet base
                    "pvc" -> setPath ["status", "phase"] (String "Bound") base
                    _ -> base
            ]
              <> [(("pod", "default", "pg-old-0"), object ["metadata" .= object ["name" .= ("pg-old-0" :: Text)]])]
          )
    , volumes = Map.fromList [("nagare-db-pg-old-data", "pgdata:known-row-1")]
    , counter = 0
    , created = []
    , loseJobAck = False
    , destinationWrites = 0
    , partialCopyOnce = False
    }

stamped :: ResourceId -> ByteString -> Text -> Value
stamped identity native uid =
  foldr
    (\(path, value) acc -> setPath path value acc)
    (checked (eitherDecodeStrict native))
    [ (["metadata", "annotations", "nagare.dev/context-id"], String (contextIdText (binding ^. #identity)))
    , (["metadata", "annotations", "nagare.dev/resource-id"], String (resourceIdText identity))
    , (["metadata", "annotations", "nagare.dev/spec-digest"], String (digestText (contentDigest native)))
    , (["metadata", "uid"], String uid)
    , (["metadata", "resourceVersion"], String "1")
    ]

-- Planning and execution ----------------------------------------------------

plannedRename :: FilePath -> IO (InventoryStore, IORef World, ReviewedPlan, AdapterRegistry)
plannedRename root = do
  probe <- newIORef Nothing
  plannedRenameWith recordOldIncarnations probe root

plannedRenameWith :: (HeadManifest -> HeadManifest) -> IORef (Maybe (IO ())) -> FilePath -> IO (InventoryStore, IORef World, ReviewedPlan, AdapterRegistry)
plannedRenameWith seed = plannedRenameThrough seed id

-- | A wrapper around the modelled API's request handler.
type Transport = (KubectlRequest -> IO KubectlResult) -> KubectlRequest -> IO KubectlResult

type RenameWorld = IORef World

-- | Plan and publish the reviewed rename with the API reached through a
-- transport wrapper; planning issues no writes.
plannedRenameThrough :: (HeadManifest -> HeadManifest) -> Transport -> IORef (Maybe (IO ())) -> FilePath -> IO (InventoryStore, IORef World, ReviewedPlan, AdapterRegistry)
plannedRenameThrough seed transport probe root = do
  world <- newIORef seededWorld
  store <- must (openFilesystemStore (root </> "history"))
  seedAccepted store binding [oldScope] oldNative
  seeded <- must (readHead store) >>= maybe (fail "missing head") pure
  _ <- must (replaceHeadIfGenerationMatches store (Just (headGeneration seeded)) ((seed seeded) {headGeneration = headGeneration seeded + 1}))
  history <- must (loadInventoryHistory store)
  let snapshot =
        checked
          ( mkScopeSnapshot
              binding
              (Map.map (\(accepted, scope) -> (revisionGeneration accepted, scope)) (historyAccepted history))
              (historyReservations history)
          )
      candidate = checked (composeInventory snapshot (ReplaceScope newScope :| []))
      revision = fst (historyAccepted history Map.! databaseOwner)
      -- Planning reads the accepted declarations from history, exactly as
      -- the command loads them, never the freshly compiled ones.
      acceptedDeclarations =
        Map.fromList
          [ (declaration ^. #identity, declaration)
          | Managed declaration <- checked (composedDeclarations (fmap snd (historyAccepted history)))
          ]
      planning = MigrationPlanning (Map.mapWithKey (\identity (_, bytes) -> (revision, acceptedDeclarations Map.! identity, bytes)) oldNative) newNative (headIncarnations (historyHead history))
      runtime = probedThrough world transport probe
      sourceRegistry = checked (mkAdapterRegistry [mkKubernetesAdapter oldNative (mkKubernetesRuntimeOps runtime oldNative)])
      destinationRegistry = checked (mkAdapterRegistry [kubernetesMigrationAdapter runtime (Just planning) (mkKubernetesAdapter newNative (mkKubernetesRuntimeOps runtime newNative))])
      requirements = observationRequirements candidate history
  destinations <- must (observeWithRegistry destinationRegistry (requirementsByExecutor requirements))
  facts <- must (observeMigrationIncarnations sourceRegistry destinationRegistry requirements)
  input <- expectRight (renameProposal candidate planning databaseOwner facts)
  decisions <- expectRight (decideMigration candidate input history destinations facts)
  proposal <- expectRight (planChanges candidate decisions history destinations)
  length [() | operation <- proposalOperations proposal, case plannedAction operation of MigrateResource _ -> True; _ -> False]
    @?= 8 * Map.size newNative
  snapshotBefore <- must (readStoreSnapshot store)
  bundle <- expectRight' =<< prepareReview destinationRegistry snapshotBefore proposal
  -- The CLI execution factory rebuilds native bindings from the saved review.
  rebuilt <- expectRight (kubernetesSpecsFromReview bundle)
  Map.map snd rebuilt @?= Map.map snd newNative
  _ <- must (publishReview store bundle)
  published <- must (readStoreSnapshot store)
  reviewed <- expectRight (verifyReview published bundle)
  -- Execution reconstructs everything from the saved bundle; it has no
  -- planning context and no access to the accepted source bytes.
  let execution = checked (mkAdapterRegistry [kubernetesMigrationAdapter runtime Nothing (mkKubernetesAdapter newNative (mkKubernetesRuntimeOps runtime newNative))])
  pure (store, world, reviewed, execution)
  where
    expectRight' = either (\errors -> assertFailure (show errors) >> fail "unreachable") pure

-- | The volumes' contents, by claim name.
renameVolumes :: World -> Map Text Text
renameVolumes = volumes

-- | Transfer Jobs the API server created, in order.
transferJobs :: World -> [Text]
transferJobs final = filter (T.isPrefixOf "job.batch/nagare-migrate-") (final ^. #created)

-- | The transfer script's incomplete-copy mark, in the modelled volume's
-- content.
incompleteMark :: Text
incompleteMark = "incomplete:"

-- | Arm the partial-copy fault for the next copy.
armPartialCopy :: IORef World -> IO ()
armPartialCopy world = modifyIORef' world (#partialCopyOnce .~ True)

-- | How many times a copy wrote into an empty destination volume.
destinationCopies :: World -> Int
destinationCopies = destinationWrites

verifyRenamedWorld :: World -> Assertion
verifyRenamedWorld final = do
  let objectAt key = Map.lookup key (final ^. #objects)
      credential = objectAt ("secret", "default", "nagare-db-pg-new")
      signing = objectAt ("secret", "default", "nagare-dbbackup-pg-new-signing")
      oldWriter = objectAt ("statefulset.apps", "default", "pg-old")
      fieldsOf value = case value >>= jsonPath ["data"] of
        Just (Object fields) -> fields
        _ -> KM.empty
  decoded "DATABASE_URL" (fieldsOf credential) @?= "postgresql://nagare:secret-password@pg-new.default.svc.cluster.local:5432/pg_old"
  decoded "POSTGRES_PASSWORD" (fieldsOf credential) @?= "secret-password"
  fieldsOf signing @?= signingData
  Map.lookup "nagare-db-pg-new-data" (final ^. #volumes) @?= Just "pgdata:known-row-1"
  Map.lookup "nagare-db-pg-old-data" (final ^. #volumes) @?= Just "pgdata:known-row-1"
  (oldWriter >>= jsonPath ["spec", "replicas"]) @?= Just (Number 0)
  (objectAt ("cronjob.batch", "default", "nagare-dbbackup-pg-old") >>= jsonPath ["spec", "suspend"]) @?= Just (Bool True)
  assertBool "renamed backup schedule runs" (isNothing (objectAt ("cronjob.batch", "default", "nagare-dbbackup-pg-new") >>= jsonPath ["spec", "suspend"]))
  assertBool "old writer carries the reviewed fence" (isJust (oldWriter >>= jsonPath ["metadata", "annotations", "nagare.dev/migration-fence"]))
  assertBool "old writer Pod is stopped" (isNothing (objectAt ("pod", "default", "pg-old-0")))
  assertBool "new writer Pod runs" (isJust (objectAt ("pod", "default", "pg-new-0")))
  assertBool "transfer Jobs are removed" (null [() | (kind, _, _) <- Map.keys (final ^. #objects), kind == "job.batch"])
  assertBool
    "every old member is still present"
    (all (\identity -> any (\value -> jsonText ["metadata", "uid"] value == Just (uidFor identity)) (Map.elems (final ^. #objects))) (Map.keys oldNative))

-- JSON helpers ----------------------------------------------------------------

jsonPath :: [Text] -> Value -> Maybe Value
jsonPath [] value = Just value
jsonPath (key : rest) (Object fields) = KM.lookup (Key.fromText key) fields >>= jsonPath rest
jsonPath _ _ = Nothing

jsonText :: [Text] -> Value -> Maybe Text
jsonText path value = case jsonPath path value of
  Just (String text) -> Just text
  _ -> Nothing

-- | A transport whose k-th and later reads of the old writer StatefulSet
-- return an object with another UID, as after an out-of-band replacement.
swapWriterAfter :: Int -> IORef Int -> Transport
swapWriterAfter k reads next request = do
  result <- next request
  case request ^. #arguments of
    ("get" : "statefulset.apps" : "pg-old" : _) -> do
      n <- atomicModifyIORef' reads (\count -> (count + 1, count + 1))
      pure (if n < k then result else fmap (\(code, out, err) -> (code, swapped out, err)) result)
    _ -> pure result
  where
    swapped out = either (const out) (encodeText . setPath ["metadata", "uid"] (String "replacement-uid")) (eitherDecodeStrict (TE.encodeUtf8 (T.pack out)))

setPath :: [Text] -> Value -> Value -> Value
setPath [] replacement _ = replacement
setPath (key : rest) replacement (Object fields) =
  Object (KM.insert (Key.fromText key) (setPath rest replacement (fromMaybe (object []) (KM.lookup (Key.fromText key) fields))) fields)
setPath path replacement _ = setPath path replacement (object [])

firstVolume :: Value -> Maybe Value
firstVolume (Array entries) = entries V.!? 0
firstVolume _ = Nothing

flag :: String -> [String] -> Maybe String
flag name (key : value : rest)
  | key == name = Just value
  | otherwise = flag name (value : rest)
flag _ _ = Nothing

encodeText :: Value -> String
encodeText = T.unpack . TE.decodeUtf8 . checked . canonicalValue

stateDigest :: KubernetesState -> Maybe ContentDigest
stateDigest = \case
  KubernetesPresent _ _ _ digest -> Just digest
  KubernetesNotReady _ _ _ digest -> Just digest
  _ -> Nothing

assertLeft :: (Show a) => Either e a -> Assertion
assertLeft = either (const (pure ())) (\value -> assertFailure ("expected a refusal, got " <> show value))

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\reason -> assertFailure (show reason) >> fail "unreachable") pure

mkOperationIdText :: Text -> Either Text OperationId
mkOperationIdText = mkOperationId

-- Name the stopped stage so a failure explains itself.
describe :: ReviewedPlan -> TransactionResult -> String
describe reviewed result = case result of
  StoppedAmbiguous _ operation -> named operation
  StoppedFailed _ operation reason -> named operation <> " " <> show reason
  other -> show other
  where
    named operation =
      show
        [ (plannedAction planned, plannedResources planned)
        | entry <- reviewOperations (reviewedDocument reviewed)
        , let planned = reviewPlannedOperation entry
        , plannedOperationId planned == operation
        ]
