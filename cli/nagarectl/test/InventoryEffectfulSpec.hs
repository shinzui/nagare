-- | The real restore compiler, runtime and transaction driver with interpreted IO.
module InventoryEffectfulSpec (inventoryEffectfulTests, runEffectfulResumeProbe) where

import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (TransactionId, mkTransactionId, transactionIdText)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope)
import Nagare.Test.Effectful.Fixture
import Nagare.Test.Effectful.Model
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryEffectfulTests :: TestTree
inventoryEffectfulTests =
  testGroup
    "effectful restore pilot"
    [ testCase "lost write acknowledgement resumes saved review without creating twice" (recoverScenario AfterWrite)
    , testCase "failure before write retries once after reopening history" (recoverScenario BeforeWrite)
    , testCase "readiness timeout uses virtual time and resumes the original Job" (recoverScenario WaitTimeout)
    , testCase "changed source identity after interruption refuses recovery" changedSource
    , testCase "actual rendered download rejects missing generations and corrupt bytes" downloadFailures
    , testCase "unmodeled effects fail instead of reporting synthetic success" $
        withSystemTempDirectory "nagare-effectful-unknown" $ \root -> do
          seedWorld root restoreFixture
          -- Test this through the interpreter rather than bypassing its request program.
          result <-
            try @SomeException
              ( runKubectlWith
                  (modelRequest root NoFault)
                  (kubectl (KubectlRequest "effectful-local" ["delete", "everything"] ""))
              )
          assertBool "unsupported command succeeded" (isLeft result)
    ]

registryFor :: FilePath -> Fault -> RestoreFixture -> AdapterRegistry
registryFor root fault fixture =
  checked
    ( mkAdapterRegistry
        [mkKubernetesAdapter native (mkKubernetesRuntimeOps config native)]
    )
  where
    native = Map.union (fixtureRestoreNative fixture) (fixtureNative fixture)
    config =
      withKubectlInterpreter
        (runKubectlWith (modelRequest root fault))
        (KubernetesRuntimeConfig (fixtureBinding fixture ^. #identity) "effectful-local" (pure (Right ())))

prepare :: InventoryStore -> AdapterRegistry -> RestoreFixture -> IO (ReviewBundle, ReviewedPlan)
prepare store registry fixture = do
  history <- must (loadInventoryHistory store)
  let snapshot =
        checked
          ( mkScopeSnapshot
              (fixtureBinding fixture)
              (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) (historyAccepted history))
              (historyReservations history)
          )
      candidate = checked (composeInventory snapshot (ReplaceScope (fixtureRestore fixture) :| []))
  observations <-
    must
      ( observeWithRegistry
          registry
          (requirementsByExecutor (observationRequirements candidate history))
      )
  proposal <- either (fail . show) pure (planChanges candidate noLifecycleDecisions history observations)
  before <- must (readStoreSnapshot store)
  bundle <- must (prepareReview registry before proposal)
  _ <- must (publishReview store bundle)
  published <- must (readStoreSnapshot store)
  reviewed <- either (fail . show) pure (verifyReview published bundle)
  pure (bundle, reviewed)

start :: FilePath -> Fault -> IO (RestoreFixture, ReviewBundle, TransactionId)
start root fault = do
  let fixture = restoreFixture
  store <- must (openFilesystemStore (root </> "history"))
  seedFixture store fixture
  seedWorld root fixture
  let registry = registryFor root fault fixture
  (bundle, reviewed) <- prepare store registry fixture
  result <- must (applyReviewed store registry reviewed)
  transaction <- case result of
    StoppedAmbiguous transaction _ -> pure transaction
    StoppedFailed transaction _ _ -> pure transaction
    other -> assertFailure ("expected interruption, got " <> show other) >> fail "not interrupted"
  pure (fixture, bundle, transaction)

recoverScenario :: Fault -> IO ()
recoverScenario fault = withSystemTempDirectory "nagare-effectful-restore" $ \root -> do
  (_, bundle, transaction) <- start root fault
  initial <- readWorld root
  createCount initial @?= if fault == BeforeWrite then 0 else 1
  when (fault == WaitTimeout) (virtualSeconds initial @?= 300)
  let sourceBefore = Map.filterWithKey (\key _ -> not ("job/" `T.isPrefixOf` key)) (objects initial)
  -- Reopen the filesystem store, reload immutable native inputs, and construct
  -- a new handler. Only durable history and the separate external world survive.
  store <- must (openFilesystemStore (root </> "history"))
  saved <- must (loadPublishedReview store (reviewDigest bundle))
  reviewDigest saved @?= reviewDigest bundle
  before <- requireHead store
  freshRegistry <- savedRegistry root store saved
  if fault == BeforeWrite
    then do
      retried <- must (resumeTransaction store freshRegistry transaction)
      assertBool "unready Job was declared converged" (retried /= Converged transaction)
      retriedWorld <- readWorld root
      assertEqual ("before-write recovery: " <> show retried <> "; requests=" <> show (requests retriedWorld)) 1 (createCount retriedWorld)
    else do
      pending <- must (resumeTransaction store freshRegistry transaction)
      assertBool "present but unready Job was declared converged" (pending /= Converged transaction)
  completeDownload root
  fresh <- must (openFilesystemStore (root </> "history"))
  runFreshProcess root bundle transaction >>= (@?= ExitSuccess)
  after <- requireHead fresh
  Map.restrictKeys (headAccepted after) (Map.keysSet (headAccepted before)) @?= headAccepted before
  headActiveTransaction after @?= Nothing
  final <- readWorld root
  createCount final @?= 1
  Map.filterWithKey (\key _ -> not ("job/" `T.isPrefixOf` key)) (objects final) @?= sourceBefore
  -- A converged replay must not re-create the scratch Job.
  runFreshProcess root bundle transaction >>= (@?= ExitSuccess)
  createCount <$> readWorld root >>= (@?= 1)

changedSource :: IO ()
changedSource = withSystemTempDirectory "nagare-effectful-source" $ \root -> do
  (fixture, _, transaction) <- start root AfterWrite
  completeDownload root
  world <- readWorld root
  assertBool "source PVC missing from fixture" (Map.member "persistentvolumeclaim/nagare-db-pg-main-data" (objects world))
  let change (Object value) = case KM.lookup "metadata" value of
        Just (Object metadata) ->
          Object
            ( KM.insert
                "metadata"
                (Object (KM.insert "uid" (String "replacement-pvc") metadata))
                value
            )
        _ -> error "missing source metadata"
      change _ = error "invalid source object"
  writeWorld root world {objects = Map.adjust change "persistentvolumeclaim/nagare-db-pg-main-data" (objects world)}
  store <- must (openFilesystemStore (root </> "history"))
  result <- must (resumeTransaction store (registryFor root NoFault fixture) transaction)
  assertBool "changed source was accepted" (result /= Converged transaction)
  headActiveTransaction <$> requireHead store >>= (@?= Just (transactionIdText transaction))
  createCount <$> readWorld root >>= (@?= 1)

downloadFailures :: IO ()
downloadFailures = withSystemTempDirectory "nagare-effectful-download" $ \root -> do
  let fixture = restoreFixture
      job = case Map.elems (fixtureRestoreNative fixture) of
        [(_, bytes)] -> checked (eitherDecodeStrict bytes)
        _ -> error "one restore Job expected"
      removeVersions (Object values)
        | Just (String name) <- KM.lookup "name" values
        , name `elem` ["OBJECT_VERSION", "RECEIPT_VERSION"] =
            Null
        | otherwise = Object (KM.map removeVersions values)
      removeVersions (Array values) = Array (Vector.filter (/= Null) (Vector.map removeVersions values))
      removeVersions value = value
  seedWorld root fixture
  runDownload root job >>= (@?= ExitSuccess)
  -- Counterfactual for F19: use the same renderer output with the omitted env.
  missing <- runDownload root (removeVersions job)
  assertBool "missing GCS generation variables were invisible" (missing /= ExitSuccess)
  BS.writeFile (root </> "archive.gz") "corrupt backup"
  corrupt <- runDownload root job
  assertBool "changed archive passed actual download verification" (corrupt /= ExitSuccess)

-- A separate OS process has no fixture/compiler values or live adapter closures.
-- It reconstructs operation inputs from the saved review and native source bytes
-- from content-addressed history, then enters the same production resume driver.
savedRegistry :: FilePath -> InventoryStore -> ReviewBundle -> IO AdapterRegistry
savedRegistry root store saved = do
  scopeList <- either (fail . show) pure (traverse decodeScope (Map.elems (reviewBundleScopes saved)))
  members <- either (fail . show) pure (composedDeclarations (Map.fromList [(scopeId scope, scope) | scope <- scopeList]))
  let nativeDigest = \case
        NativeObject digest -> Just digest
        StatefulSet _ _ digest -> Just digest
        _ -> Nothing
  sources <- forM [(member, digest) | Managed member <- members, Just digest <- [nativeDigest (member ^. #spec)]] $ \(member, digest) -> do
    bytes <- must (readObject store (objectKeyFor "native" digest))
    pure $ case bytes of
      Just native | contentDigest native == digest -> Just (member ^. #identity, (member, native))
      _ -> Nothing
  restored <- either (fail . T.unpack) pure (kubernetesSpecsFromReview saved)
  let native = Map.union restored (Map.fromList (catMaybes sources))
      context = reviewContextBinding (reviewBundleDocument saved) ^. #identity
      config =
        withKubectlInterpreter
          (runKubectlWith (modelRequest root NoFault))
          (KubernetesRuntimeConfig context "effectful-local" (pure (Right ())))
  pure (checked (mkAdapterRegistry [mkKubernetesAdapter native (mkKubernetesRuntimeOps config native)]))

runFreshProcess :: FilePath -> ReviewBundle -> TransactionId -> IO ExitCode
runFreshProcess root saved transaction = do
  executable <- getExecutablePath
  parent <- getEnvironment
  let selected =
        [ ("NAGARE_EFFECTFUL_RESUME_ROOT", root)
        , ("NAGARE_EFFECTFUL_REVIEW", T.unpack (digestText (reviewDigest saved)))
        , ("NAGARE_EFFECTFUL_TRANSACTION", T.unpack (transactionIdText transaction))
        ]
  (code, output, errors) <-
    readCreateProcessWithExitCode
      ((proc executable []) {env = Just (selected <> filter (\(key, _) -> key `notElem` map fst selected) parent)})
      ""
  assertBool ("fresh-process recovery failed: " <> output <> errors) (code == ExitSuccess)
  pure code

runEffectfulResumeProbe :: FilePath -> String -> String -> IO ExitCode
runEffectfulResumeProbe root digest transactionText = do
  store <- must (openFilesystemStore (root </> "history"))
  saved <- must (loadPublishedReview store (checked (mkContentDigest (T.pack digest))))
  registry <- savedRegistry root store saved
  let transaction = checked (mkTransactionId (T.pack transactionText))
  result <- must (resumeTransaction store registry transaction)
  pure (if result == Converged transaction then ExitSuccess else ExitFailure 1)

requireHead :: InventoryStore -> IO HeadManifest
requireHead store = must (readHead store) >>= maybe (fail "missing persisted head") pure
