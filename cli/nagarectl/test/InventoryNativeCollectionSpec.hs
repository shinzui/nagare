-- | Recorded metadata through the existing request interpreter and real journal.
module InventoryNativeCollectionSpec (nativeCollectionTests) where

import Control.Exception (SomeException, try)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict, encode, fromJSON, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import InventoryControllerCollectionSpec (selected)
import InventoryEffectfulCollectionSpec (assertUnresolved, freshProcess, prepareChange, preparedCollection, requireHead, transactionOf)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Collection.Authority qualified as C
import Nagare.Inventory.Execute (applyReviewed)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (ScopeChange (CollectRetained))
import Nagare.Test.Effectful.CollectionFixture
import Nagare.Test.Effectful.CollectionModel
import Nagare.Test.Effectful.Fixture (checked, must)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty hiding (after)
import Test.Tasty.HUnit

nativeCollectionTests :: TestTree
nativeCollectionTests =
  testGroup
    "effectful recorded native collection"
    [ testCase "16 recorded descendants and 75 APIs survive review, partial GC and fresh-process recovery within budgets" nativeRecovery
    , testCase "shared owner refuses authority" (refusePlan (ownersChange (\refs -> refs <> [object ["uid" .= ("foreign" :: Text), "controller" .= False]])))
    , testCase "non-controller owner refuses authority" (refusePlan (ownersChange (map (setField "controller" (Bool False)))))
    , testCase "independently inventoried descendant refuses authority" (refusePlan (changeChild (metaChange (setField "annotations" (object ["nagare.dev/resource-id" .= ("standalone:other/service" :: Text)])))))
    , testCase "unsupported descendant refuses authority" (refusePlan (changeChild (setField "kind" (String "ConfigMap") . setField "apiVersion" (String "v1"))))
    , testCase "foreign namespace refuses authority" (refusePlan (changeChild (metaChange (setField "namespace" (String "foreign")))))
    , testCase "missing persisted UID is incomplete evidence, not a projection" (refusePlan missingIdentity)
    , testCase "partial API discovery refuses authority" (refuseFault DiscoveryFailure)
    , testCase "one forbidden list among 75 APIs refuses authority" (refuseFault ListFailure)
    , testCase "continuation token refuses authority" (refuseFault IncompleteList)
    , testCase "malformed list refuses authority" (refuseFault MalformedList)
    , testCase "API set shrink after review refuses DELETE" (refuseApply (\w -> w {discoveredApis = filter (/= "pods.metrics.k8s.io") (discoveredApis w)}) Cascade)
    , testCase "unavailable list after review refuses DELETE" (refuseApply id ListFailure)
    , testCase "changed recorded owner before apply refuses DELETE" (refuseApply (ownersChange (map (setField "uid" (String "foreign")))) Cascade)
    , testCase "unexpected descendant before apply refuses DELETE" (refuseApply addUnexpected Cascade)
    , testCase "incomplete recovery cannot tombstone after parent absence" incompleteRecovery
    , testCase "unexpected transitive descendant after parent absence cannot tombstone" unexpectedRecovery
    , testCase "protected ownership drift after parent absence cannot tombstone" protectedRecovery
    ]

-- Frozen recording omits resourceVersion and full object bodies. Supply only
-- synthetic versions/envelopes; retain recorded kinds, names, UIDs and edges.
-- Rebase the two root edges onto the existing isolated fixture's web-uid.
seedRecorded :: FilePath -> IO ()
seedRecorded root = do
  bytes <- BS.readFile "test/fixtures/inventory/knative-collection-native.json"
  let evidence = checked (eitherDecodeStrict bytes)
      decodeValue value = case fromJSON value of Success result -> result; Error reason -> error reason
      apis = decodeValue (field "apis" evidence) :: [Text]
      recorded = decodeValue (field "descendants" evidence) :: [Value]
      parentUid = field "parentUid" evidence
      rebase ref = if field "uid" ref == parentUid then setField "name" (String "web") (setField "uid" (String "web-uid") ref) else ref
      wrap value =
        object
          [ "apiVersion" .= field "apiVersion" value
          , "kind" .= field "kind" value
          , "metadata"
              .= object
                [ "name" .= field "name" value
                , "namespace" .= field "namespace" value
                , "uid" .= field "uid" value
                , "resourceVersion" .= ("recorded-fixture-version" :: Text)
                , "ownerReferences" .= map rebase (decodeValue (field "ownerReferences" value) :: [Value])
                ]
          ]
      projection =
        object
          [ "apiVersion" .= ("metrics.k8s.io/v1beta1" :: Text)
          , "kind" .= ("PodMetrics" :: Text)
          , "metadata" .= object ["name" .= ("metrics-only" :: Text), "namespace" .= ("personal" :: Text), "creationTimestamp" .= ("2026-10-02T00:00:00Z" :: Text)]
          , "timestamp" .= ("2026-10-02T00:00:00Z" :: Text)
          , "window" .= ("30s" :: Text)
          , "containers" .= ([] :: [Value])
          ]
  length apis @?= 75
  length recorded @?= 16
  world <- readCollectionWorld root
  writeCollectionWorld
    root
    world
      { discoveredApis = apis
      , descendants = Map.fromList [(name, wrap value) | value <- recorded, let name = decodeValue (field "uid" value)]
      , resources = Map.insert "projection" projection (resources world)
      , requests = []
      }

nativePrepared :: FilePath -> IO InventoryStore
nativePrepared root = do
  (store, _, _) <- preparedCollection root
  seedRecorded root
  pure store

reviewNative :: FilePath -> InventoryStore -> IO (ReviewBundle, ReviewedPlan)
reviewNative root store = prepareChange store (selected root Cascade) (CollectRetained parentId)

clearCalls :: FilePath -> IO ()
clearCalls root = do
  world <- readCollectionWorld root
  writeCollectionWorld root world {requests = []}

-- Exact API multiset forbids selectors, skipped empty APIs, per-child GETs,
-- unbounded polling, extra scans, child DELETEs and other mutations.
budget :: FilePath -> Int -> Int -> Int -> Int -> Assertion
budget root scans gets deletes waits = do
  world <- readCollectionWorld root
  let calls = requests world
      discovery = [args | args@("api-resources" : _) <- calls]
      lists = [T.pack api | ["get", api, "--namespace", "personal", "-o", "json"] <- calls]
      direct = [args | args@["get", _, _, "--namespace", "personal", "-o", "json", "--ignore-not-found"] <- calls]
      writes = [args | args@("delete" : _) <- calls]
      waiting = [args | args@("wait" : _) <- calls]
  length discovery @?= scans
  sort lists @?= sort (concat (replicate scans (discoveredApis world)))
  length direct @?= gets
  length writes @?= deletes
  length waiting @?= waits
  length calls @?= scans * 76 + gets + deletes + waits

nativeRecovery :: IO ()
nativeRecovery = withSystemTempDirectory "nagare-native-collection" $ \root -> do
  store <- nativePrepared root
  (bundle, reviewed) <- reviewNative root store
  before <- requireHead store
  worldBefore <- readCollectionWorld root
  let native = map (checked . eitherDecodeStrict) (Map.elems (reviewBundleNative bundle)) :: [Value]
      authorities = [value | value <- native, field "controllerCollection" value /= Null]
  authority <- case authorities of
    [value] -> case fromJSON (field "controllerCollection" value) of Success a -> pure a; Error reason -> fail reason
    _ -> fail "expected one saved controller authority"
  length (C.descendants authority) @?= 16
  C.apiResources authority @?= sort (discoveredApis worldBefore)
  sort (map C.uid (C.descendants authority)) @?= sort (Map.keys (descendants worldBefore))
  length (C.protected authority) @?= 4
  assertBool "projection leaked into immutable authority" (not ("metrics-only" `BS.isInfixOf` BL.toStrict (encode authority)))
  budget root 1 2 0 0
  clearCalls root
  result <- must (applyReviewed store (selected root Cascade) reviewed)
  assertUnresolved result
  budget root 3 3 1 1
  let transaction = transactionOf result
  clearCalls root
  freshProcess root bundle transaction "pending"
  budget root 1 2 0 0
  headRetained <$> requireHead store >>= (@?= headRetained before)
  world <- readCollectionWorld root
  -- Leave a deep EndpointSlice after all its intermediate owners disappeared.
  let slices = Map.filter ((== String "EndpointSlice") . field "kind") (descendants world)
  Map.size slices @?= 2
  writeCollectionWorld root world {descendants = slices, requests = []}
  freshProcess root bundle transaction "pending"
  budget root 1 2 0 0
  pending <- readCollectionWorld root
  writeCollectionWorld root pending {descendants = Map.empty, requests = []}
  freshProcess root bundle transaction "converged"
  budget root 1 2 0 0
  clearCalls root
  freshProcess root bundle transaction "converged"
  budget root 0 0 0 0
  final <- requireHead store
  headRetained final @?= Map.delete parentId (headRetained before)
  headAccepted final @?= headAccepted before
  tombstone <- maybe (fail "missing original tombstone") pure (Map.lookup parentId (headCollected final))
  tombstoneReview tombstone @?= reviewDigest bundle
  finalWorld <- readCollectionWorld root
  resources finalWorld @?= Map.delete parentKey (resources worldBefore)
  length (deleteBodies finalWorld) @?= 1

metaChange :: (Value -> Value) -> Value -> Value
metaChange change value = setField "metadata" (change (field "metadata" value)) value

-- The Configuration directly owned by the Knative Service in the recording.
childUid :: Text
childUid = "aa2ab3af-ffd7-44dd-bd60-6397b29bf270"

changeChild :: (Value -> Value) -> CollectionWorld -> CollectionWorld
changeChild change world = world {descendants = Map.adjust change childUid (descendants world)}

ownersChange :: ([Value] -> [Value]) -> CollectionWorld -> CollectionWorld
ownersChange change = changeChild (metaChange update)
  where
    update meta = case fromJSON (field "ownerReferences" meta) of
      Success refs -> setField "ownerReferences" (toJSON (change refs)) meta
      Error reason -> error reason

missingIdentity :: CollectionWorld -> CollectionWorld
missingIdentity world = world {resources = Map.adjust (metaChange remove) "persistentvolumeclaim/pg-main-data" (resources world)}
  where
    remove (Object fields) = Object (KM.delete "uid" fields); remove value = value

addUnexpected :: CollectionWorld -> CollectionWorld
addUnexpected world = world {descendants = Map.insert "unexpected" extra (descendants world)}
  where
    extra = metaChange (setField "uid" (String "unexpected") . setField "name" (String "unexpected")) (descendants world Map.! childUid)

assertPrepareRefused :: Either SomeException a -> Assertion
assertPrepareRefused result = case result of
  Left reason -> assertBool (show reason) ("PrepareRefused" `T.isInfixOf` T.pack (show reason))
  Right _ -> assertFailure "unsafe native evidence published authority"

refusePlan :: (CollectionWorld -> CollectionWorld) -> IO ()
refusePlan change = withSystemTempDirectory "nagare-native-refuse" $ \root -> do
  store <- nativePrepared root
  before <- must (readStoreSnapshot store)
  world <- readCollectionWorld root
  writeCollectionWorld root (change world)
  result <- try @SomeException (reviewNative root store)
  assertPrepareRefused result
  must (readStoreSnapshot store) >>= (@?= before)
  deleteBodies <$> readCollectionWorld root >>= (@?= [])

refuseFault :: CollectionFault -> IO ()
refuseFault fault = withSystemTempDirectory "nagare-native-incomplete" $ \root -> do
  store <- nativePrepared root
  before <- must (readStoreSnapshot store)
  result <- try @SomeException (prepareChange store (selected root fault) (CollectRetained parentId))
  assertPrepareRefused result
  must (readStoreSnapshot store) >>= (@?= before)
  world <- readCollectionWorld root
  deleteBodies world @?= []
  if fault == DiscoveryFailure
    then length (requests world) @?= 3 -- two parent GETs, one failed discovery
    else budget root 1 2 0 0

refuseApply :: (CollectionWorld -> CollectionWorld) -> CollectionFault -> IO ()
refuseApply change fault = withSystemTempDirectory "nagare-native-preflight" $ \root -> do
  store <- nativePrepared root
  (_, reviewed) <- reviewNative root store
  before <- requireHead store
  world <- readCollectionWorld root
  writeCollectionWorld root (change world) {requests = []}
  result <- applyReviewed store (selected root fault) reviewed
  case result of Left _ -> pure (); Right stopped -> assertUnresolved stopped
  after <- requireHead store
  headRetained after @?= headRetained before
  headCollected after @?= headCollected before
  worldAfter <- readCollectionWorld root
  resources worldAfter @?= resources (change world)
  deleteBodies worldAfter @?= []
  assertBool "unbounded refused preflight" (length (requests worldAfter) <= 78)

recoveryChange :: (CollectionWorld -> CollectionWorld) -> IO ()
recoveryChange change = withSystemTempDirectory "nagare-native-recovery" $ \root -> do
  store <- nativePrepared root
  (bundle, reviewed) <- reviewNative root store
  before <- requireHead store
  result <- must (applyReviewed store (selected root Cascade) reviewed)
  assertUnresolved result
  world <- readCollectionWorld root
  writeCollectionWorld root (change world) {requests = []}
  freshProcess root bundle (transactionOf result) "pending"
  after <- requireHead store
  headRetained after @?= headRetained before
  headCollected after @?= headCollected before
  final <- readCollectionWorld root
  resources final @?= resources (change world)
  length (deleteBodies final) @?= 1
  assertBool "recovery repeated DELETE" (not (any (elem "--raw") (requests final)))
  assertBool "unbounded recovery" (length (requests final) <= 78)

incompleteRecovery :: IO ()
incompleteRecovery = recoveryChange (\w -> w {descendants = Map.empty, discoveredApis = filter (/= "pods.metrics.k8s.io") (discoveredApis w)})

unexpectedRecovery :: IO ()
unexpectedRecovery = recoveryChange $ \w ->
  let added = descendants (addUnexpected w) Map.! "unexpected"
      transitive = metaChange (setField "ownerReferences" (toJSON [object ["uid" .= ("d8405887-f616-4c1f-ae06-bb06e08b429a" :: Text), "controller" .= True]])) added
   in w {descendants = Map.singleton "unexpected" transitive}

protectedRecovery :: IO ()
protectedRecovery = recoveryChange $ \w ->
  w
    { descendants = Map.empty
    , resources = Map.adjust (metaChange (setField "ownerReferences" (toJSON [object ["uid" .= ("foreign" :: Text), "controller" .= True]]))) "persistentvolumeclaim/pg-main-data" (resources w)
    }
