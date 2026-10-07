-- | Real retirement, collection, immutable review and recovery under F20 faults.
module InventoryEffectfulCollectionSpec (inventoryEffectfulCollectionTests, runCollectionResumeProbe, preparedCollection, prepareChange, freshProcess, requireHead, assertUnresolved, transactionOf, registry) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), toJSON)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOps)
import Nagare.Inventory.Collection.Adapter (controllerCollectionAdapter, controllerCollectionIdentity)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (AdmissionError (..), TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (TransactionId, mkTransactionId, transactionIdText)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Lifecycle (decideCollection, decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RetirementIntent (RetainResources))
import Nagare.Resource.Types hiding (resources)
import Nagare.Resource.Wire (decodeScope)
import Nagare.Test.Effectful.CollectionFixture
import Nagare.Test.Effectful.CollectionModel
import Nagare.Test.Effectful.Fixture (checked, must, seedAccepted)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

inventoryEffectfulCollectionTests :: TestTree
inventoryEffectfulCollectionTests =
  testGroup
    "effectful collection"
    [ testCase "orphan finalizer stays pending across process loss; original transaction resumes" (recoverCollection Normal)
    , testCase "lost DELETE acknowledgement never repeats accepted deletion" (recoverCollection LostDeleteAck)
    , testCase "failure before DELETE safely retries once" (recoverCollection BeforeDelete)
    , testCase "successful wait cannot conceal a still-present parent" (recoverCollection LyingWait)
    , testCase "replacement parent after interruption stays untouched" replacement
    , testCase "a parent replaced after review is refused at admission (ADR 27, N8)" admittedReplacement
    , testCase "UID race is rejected at the conditional write" (writeRace RaceUid)
    , testCase "a resourceVersion race is refused at the conditional write, and resume deletes with the fresh resourceVersion (G6)" versionRace
    , testCase "pending invariant rejects the old immediate-deletion model" counterfactual
    ]

registry :: FilePath -> CollectionFault -> Map.Map ResourceId (ManagedResource, ByteString) -> AdapterRegistry
registry root fault native =
  checked
    ( mkAdapterRegistry
        [mkKubernetesAdapter native (mkKubernetesRuntimeOps config native)]
    )
  where
    config =
      withKubectlInterpreter
        (runKubectlWith (collectionRequest root fault))
        (KubernetesRuntimeConfig (collectionBinding ^. #identity) "effectful-local" (pure (Right ())))

-- Retire through the production path first, preserving data in that same scope.
-- Scope seeding represents the already accepted checkpoint, not a creation proof.
preparedCollection :: FilePath -> IO (InventoryStore, ReviewBundle, ReviewedPlan)
preparedCollection root = do
  store <- must (openFilesystemStore (root </> "history"))
  seedAccepted store collectionBinding collectionScopes collectionNative
  seedCollectionWorld root
  let selected = registry root Normal collectionNative
  (_, retirement) <- prepareChange store selected (RetireScope collectionOwner RetainResources)
  retired <- must (applyReviewed store selected retirement)
  case retired of Converged _ -> pure (); other -> assertFailure (show other)
  headBefore <- requireHead store
  Map.size (headRetained headBefore) @?= 4
  deleteBodies <$> readCollectionWorld root >>= (@?= [])
  (bundle, reviewed) <- prepareChange store selected (CollectRetained parentId)
  Map.keys (reviewCollections (reviewBundleDocument bundle)) @?= [parentId]
  let parent = fst (collectionNative Map.! parentId)
  parent ^. #delegations @?= []
  pure (store, bundle, reviewed)

prepareChange :: InventoryStore -> AdapterRegistry -> ScopeChange -> IO (ReviewBundle, ReviewedPlan)
prepareChange store selected change = do
  history <- must (loadInventoryHistory store)
  let snapshot =
        checked
          ( mkScopeSnapshot
              collectionBinding
              (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) (historyAccepted history))
              (historyReservations history)
          )
      candidate = checked (composeInventory snapshot (change :| []))
  observations <- must (observeWithRegistry selected (requirementsByExecutor (observationRequirements candidate history)))
  let decisions =
        checked
          ( case change of
              CollectRetained _ -> decideCollection candidate history observations
              _ -> decideRetirement candidate history observations
          )
      proposal = checked (planChanges candidate decisions history observations)
  snapshotBefore <- must (readStoreSnapshot store)
  bundle <- must (prepareReview selected snapshotBefore proposal)
  _ <- must (publishReview store bundle)
  published <- must (readStoreSnapshot store)
  pure (bundle, checked (verifyReview published bundle))

transactionOf :: TransactionResult -> TransactionId
transactionOf = \case
  Converged transaction -> transaction
  StoppedAmbiguous transaction _ -> transaction
  StoppedFailed transaction _ _ -> transaction
  other -> error ("unexpected result " <> show other)

assertUnresolved :: TransactionResult -> Assertion
assertUnresolved result = case result of
  StoppedAmbiguous _ _ -> pure ()
  StoppedFailed _ _ _ -> pure ()
  _ -> assertFailure ("pending deletion falsely converged: " <> show result)

recoverCollection :: CollectionFault -> IO ()
recoverCollection fault = withSystemTempDirectory "nagare-effectful-collection" $ \root -> do
  (store, bundle, reviewed) <- preparedCollection root
  before <- requireHead store
  worldBefore <- readCollectionWorld root
  result <- must (applyReviewed store (registry root fault collectionNative) reviewed)
  assertUnresolved result
  let transaction = transactionOf result
  world <- readCollectionWorld root
  length (deleteBodies world) @?= if fault == BeforeDelete then 0 else 1
  when (fault `elem` [Normal, LyingWait]) (virtualSeconds world @?= 30)
  -- Only persisted provider state, review and journal cross this OS boundary.
  freshProcess root bundle transaction "pending"
  pending <- readCollectionWorld root
  length (deleteBodies pending) @?= 1
  let expectedAttempts = if fault == BeforeDelete then 2 else 1
  length (filter (elem "--raw") (requests pending)) @?= expectedAttempts
  Map.delete parentKey (resources pending) @?= Map.delete parentKey (resources worldBefore)
  descendants pending @?= descendants worldBefore
  let metadata = field "metadata" (resources pending Map.! parentKey)
  field "finalizers" metadata @?= toJSON ["orphan" :: Text]
  field "deletionTimestamp" metadata @?= String "2026-10-02T00:00:00Z"
  headPending <- requireHead store
  headRetained headPending @?= headRetained before
  headCollected headPending @?= headCollected before
  headAccepted headPending @?= headAccepted before
  headActiveTransaction headPending @?= Just (transactionIdText transaction)
  freshProcess root bundle transaction "pending"
  deleteBodies <$> readCollectionWorld root >>= (@?= deleteBodies pending)
  -- This external event models eventual lawful orphan completion, not cascade.
  finishOrphan root
  orphaned <- readCollectionWorld root
  Map.keys (descendants orphaned) @?= Map.keys (descendants worldBefore)
  let detached name value
        | name `elem` ["route", "configuration"] =
            setField
              "metadata"
              (setField "ownerReferences" (toJSON ([] :: [Value])) (field "metadata" value))
              value
        | otherwise = value
  descendants orphaned @?= Map.mapWithKey detached (descendants worldBefore)
  freshProcess root bundle transaction "converged"
  final <- requireHead store
  headActiveTransaction final @?= Nothing
  headAccepted final @?= headAccepted before
  headRetained final @?= Map.delete parentId (headRetained before)
  case Map.lookup parentId (headCollected final) of
    Just tombstone -> do
      tombstonePhysical tombstone @?= checked (mkPhysicalIdentity "web-uid")
      tombstoneReview tombstone @?= reviewDigest bundle
    Nothing -> assertFailure "no original-identity collection tombstone"
  freshProcess root bundle transaction "converged"
  finalWorld <- readCollectionWorld root
  resources finalWorld @?= Map.delete parentKey (resources worldBefore)
  descendants finalWorld @?= descendants orphaned
  deleteBodies finalWorld @?= deleteBodies pending
  length (filter (elem "--raw") (requests finalWorld)) @?= expectedAttempts

replacement :: IO ()
replacement = withSystemTempDirectory "nagare-effectful-replacement" $ \root -> do
  (store, bundle, reviewed) <- preparedCollection root
  result <- must (applyReviewed store (registry root LostDeleteAck collectionNative) reviewed)
  assertUnresolved result
  replaceParent root "replacement-uid" "12"
  before <- readCollectionWorld root
  freshProcess root bundle (transactionOf result) "pending"
  afterWorld <- readCollectionWorld root
  resources afterWorld @?= resources before
  descendants afterWorld @?= descendants before
  deleteBodies afterWorld @?= deleteBodies before
  length (filter (elem "--raw") (requests afterWorld)) @?= 1
  Map.member parentId . headCollected <$> requireHead store >>= (@?= False)

admittedReplacement :: IO ()
admittedReplacement = withSystemTempDirectory "nagare-effectful-admitted-replacement" $ \root -> do
  (store, _, reviewed) <- preparedCollection root
  replaceParent root "replacement-uid" "12"
  before <- readCollectionWorld root
  admitted <- applyReviewed store (registry root Normal collectionNative) reviewed
  assertBool ("a replaced parent was admitted: " <> show admitted) (either (any ((== "retention-observation") . admissionErrorCode)) (const False) admitted)
  afterWorld <- readCollectionWorld root
  deleteBodies afterWorld @?= deleteBodies before

writeRace :: CollectionFault -> IO ()
writeRace fault = withSystemTempDirectory "nagare-effectful-delete-race" $ \root -> do
  (store, bundle, reviewed) <- preparedCollection root
  result <- must (applyReviewed store (registry root fault collectionNative) reviewed)
  assertUnresolved result
  before <- readCollectionWorld root
  deleteBodies before @?= []
  freshProcess root bundle (transactionOf result) "pending"
  afterWorld <- readCollectionWorld root
  resources afterWorld @?= resources before
  deleteBodies afterWorld @?= []
  length (filter (elem "--raw") (requests afterWorld)) @?= 1

-- | G6 (RES-4 U10): a write that moved only resourceVersion leaves the
-- reviewed object as it was. The raced delete is refused by its precondition;
-- resume re-reads the object and deletes it with the fresh resourceVersion,
-- once, and the accepted delete is then pending.
versionRace :: IO ()
versionRace = withSystemTempDirectory "nagare-effectful-version-race" $ \root -> do
  (store, bundle, reviewed) <- preparedCollection root
  result <- must (applyReviewed store (registry root RaceVersion collectionNative) reviewed)
  assertUnresolved result
  readCollectionWorld root >>= (@?= []) . deleteBodies
  freshProcess root bundle (transactionOf result) "pending"
  afterWorld <- readCollectionWorld root
  map (\body -> field "resourceVersion" (field "preconditions" body)) (deleteBodies afterWorld) @?= [String "11"]
  length (filter (elem "--raw") (requests afterWorld)) @?= 2

counterfactual :: IO ()
counterfactual = withSystemTempDirectory "nagare-effectful-counterfactual" $ \root -> do
  (store, _, reviewed) <- preparedCollection root
  result <- must (applyReviewed store (registry root ImmediateDeletion collectionNative) reviewed)
  case result of Converged _ -> pure (); other -> assertFailure (show other)
  rejected <- try @SomeException (assertUnresolved result)
  case rejected of
    Left failure -> assertBool "wrong assertion rejected mutant" ("pending deletion falsely converged" `T.isInfixOf` T.pack (show failure))
    Right () -> assertFailure "immediate-success model escaped pending invariant"

-- Reconstruct the collected member from the review's exact historical scope
-- and content-addressed native bytes, including after it becomes a tombstone.
loadRegistry :: FilePath -> InventoryStore -> ReviewBundle -> IO AdapterRegistry
loadRegistry root store bundle = do
  proof <- maybe (fail "missing collection proof") pure (Map.lookup parentId (reviewCollections (reviewBundleDocument bundle)))
  let digest = revisionDigest (retentionRevision proof)
  scopeBytes <- must (readObject store (scopeKey digest)) >>= maybe (fail "missing retained scope") pure
  contentDigest scopeBytes @?= digest
  let scope = checked (decodeScope scopeBytes)
      matches = [member | b <- scopeBundles scope, Managed member <- b ^. #declarations, member ^. #identity == parentId]
  member <- case matches of [one] -> pure one; _ -> fail "missing historical parent"
  nativeDigest <- case member ^. #spec of KnativeService value -> pure value; _ -> fail "not Knative"
  bytes <- must (readObject store (objectKeyFor "native" nativeDigest)) >>= maybe (fail "missing retained native") pure
  contentDigest bytes @?= nativeDigest
  let native = Map.singleton parentId (member, bytes)
      config =
        withKubectlInterpreter
          (runKubectlWith (collectionRequest root Cascade))
          (KubernetesRuntimeConfig (collectionBinding ^. #identity) "effectful-local" (pure (Right ())))
      cascade = any ((== controllerCollectionIdentity) . reviewAdapterIdentity) (reviewOperations (reviewBundleDocument bundle))
  pure (if cascade then checked (mkAdapterRegistry [controllerCollectionAdapter config native]) else registry root Normal native)

freshProcess :: FilePath -> ReviewBundle -> TransactionId -> String -> IO ()
freshProcess root bundle transaction expected = do
  executable <- getExecutablePath
  environment <- getEnvironment
  let selected =
        [ ("NAGARE_COLLECTION_ROOT", root)
        , ("NAGARE_COLLECTION_REVIEW", T.unpack (digestText (reviewDigest bundle)))
        , ("NAGARE_COLLECTION_TRANSACTION", T.unpack (transactionIdText transaction))
        , ("NAGARE_COLLECTION_EXPECT", expected)
        ]
  (code, output, errors) <-
    readCreateProcessWithExitCode
      ((proc executable []) {env = Just (selected <> filter (\(key, _) -> key `notElem` map fst selected) environment)})
      ""
  assertEqual (output <> errors) ExitSuccess code

runCollectionResumeProbe :: FilePath -> String -> String -> String -> IO ExitCode
runCollectionResumeProbe root digest transactionText expected = do
  store <- must (openFilesystemStore (root </> "history"))
  saved <- must (loadPublishedReview store (checked (mkContentDigest (T.pack digest))))
  selected <- loadRegistry root store saved
  let transaction = checked (mkTransactionId (T.pack transactionText))
  result <- must (resumeTransaction store selected transaction)
  if expected == "converged"
    then result @?= Converged transaction
    else do
      assertUnresolved result
      transactionOf result @?= transaction
      headActiveTransaction <$> requireHead store >>= (@?= Just (transactionIdText transaction))
  pure ExitSuccess

requireHead :: InventoryStore -> IO HeadManifest
requireHead store = must (readHead store) >>= maybe (fail "missing head") pure
