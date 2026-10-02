module InventoryControllerCollectionSpec (controllerCollectionTests, selected) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import InventoryEffectfulCollectionSpec (assertUnresolved, freshProcess, prepareChange, preparedCollection, registry, requireHead, transactionOf)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Collection.Adapter
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed)
import Nagare.Inventory.KubernetesTransport
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (ScopeChange (CollectRetained))
import Nagare.Resource.Types hiding (resources)
import Nagare.Test.Effectful.CollectionFixture
import Nagare.Test.Effectful.CollectionModel
import Nagare.Test.Effectful.Fixture (checked, must)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

controllerCollectionTests :: TestTree
controllerCollectionTests =
  testGroup
    "effectful reviewed controller collection"
    [ testCase "parent absence waits for descendants; fresh-process recovery records one deletion" (recoverCascade Cascade)
    , testCase "lost Background acknowledgement resumes without another DELETE" (recoverCascade CascadeLostAck)
    , testCase "changed descendant ownership refuses before DELETE" (refuseChange changeOwner)
    , testCase "new descendant after review refuses before DELETE" (refuseChange addChild)
    , testCase "changed protected UID refuses before DELETE" (refuseChange changeProtected)
    , testCase "incomplete discovery listing cannot publish cascade authority" incomplete
    , testCase "independently managed child cannot receive cascade authority" independentChild
    , testCase "protected identity drift after accepted deletion prevents convergence" protectedAfter
    , testCase "ordinary adapter cannot execute a controller-authority review" ordinaryRefuses
    , testCase "new descendant after accepted delete prevents convergence" newAfter
    , testCase "status-only version changes do not stale descendant authority" statusChanges
    ]

selected :: FilePath -> CollectionFault -> AdapterRegistry
selected root fault = checked (mkAdapterRegistry [controllerCollectionAdapter config collectionNative])
  where
    config =
      withKubectlInterpreter
        (runKubectlWith (collectionRequest root fault))
        (KubernetesRuntimeConfig (collectionBinding ^. #identity) "effectful-local" (pure (Right ())))

prepareCascade :: FilePath -> IO (InventoryStore, ReviewBundle, ReviewedPlan)
prepareCascade root = do
  (store, _, _) <- preparedCollection root
  (bundle, reviewed) <- prepareChange store (selected root Cascade) (CollectRetained parentId)
  map reviewAdapterIdentity (reviewOperations (reviewBundleDocument bundle)) @?= [controllerCollectionIdentity]
  assertBool "review hides Background authority" (all (T.isInfixOf "Background" . reviewPublicSummary) (reviewOperations (reviewBundleDocument bundle)))
  pure (store, bundle, reviewed)

recoverCascade :: CollectionFault -> IO ()
recoverCascade fault = withSystemTempDirectory "nagare-reviewed-cascade" $ \root -> do
  (store, bundle, reviewed) <- prepareCascade root
  before <- requireHead store
  worldBefore <- readCollectionWorld root
  result <- must (applyReviewed store (selected root fault) reviewed)
  assertUnresolved result
  pending <- readCollectionWorld root
  Map.member parentKey (resources pending) @?= False
  descendants pending @?= descendants worldBefore
  map (field "propagationPolicy") (deleteBodies pending) @?= [String "Background"]
  let transaction = transactionOf result
  freshProcess root bundle transaction "pending"
  headRetained <$> requireHead store >>= (@?= headRetained before)
  headCollected <$> requireHead store >>= (@?= headCollected before)
  remaining <- readCollectionWorld root
  writeCollectionWorld root remaining {descendants = Map.delete "route" (descendants remaining)}
  freshProcess root bundle transaction "pending"
  incompleteWorld <- readCollectionWorld root
  writeCollectionWorld root incompleteWorld {descendants = Map.empty}
  freshProcess root bundle transaction "converged"
  freshProcess root bundle transaction "converged"
  final <- requireHead store
  headRetained final @?= Map.delete parentId (headRetained before)
  headAccepted final @?= headAccepted before
  tombstone <- maybe (fail "missing tombstone") pure (Map.lookup parentId (headCollected final))
  tombstonePhysical tombstone @?= checked (mkPhysicalIdentity "web-uid")
  tombstoneReview tombstone @?= reviewDigest bundle
  worldFinal <- readCollectionWorld root
  resources worldFinal @?= Map.delete parentKey (resources worldBefore)
  length (filter (elem "--raw") (requests worldFinal)) @?= 1

refuseChange :: (CollectionWorld -> CollectionWorld) -> IO ()
refuseChange change = withSystemTempDirectory "nagare-cascade-refusal" $ \root -> do
  (store, _, reviewed) <- prepareCascade root
  before <- requireHead store
  world <- readCollectionWorld root
  writeCollectionWorld root (change world)
  result <- applyReviewed store (selected root Cascade) reviewed
  case result of
    Left _ -> pure ()
    Right stopped -> assertUnresolved stopped
  afterHead <- requireHead store
  headRetained afterHead @?= headRetained before
  headAccepted afterHead @?= headAccepted before
  deleteBodies <$> readCollectionWorld root >>= (@?= [])

changeOwner :: CollectionWorld -> CollectionWorld
changeOwner world = world {descendants = Map.adjust change "route" (descendants world)}
  where
    change value =
      setField
        "metadata"
        ( setField
            "ownerReferences"
            (toJSON [object ["uid" .= ("foreign-uid" :: Text), "controller" .= True]])
            (field "metadata" value)
        )
        value

addChild :: CollectionWorld -> CollectionWorld
addChild world = world {descendants = Map.insert "extra" extra (descendants world)}
  where
    original = descendants world Map.! "route"
    extra =
      setField
        "metadata"
        ( setField "name" (String "extra") $
            setField "uid" (String "extra-uid") (field "metadata" original)
        )
        original

changeProtected :: CollectionWorld -> CollectionWorld
changeProtected world = world {resources = Map.adjust change "persistentvolumeclaim/pg-main-data" (resources world)}
  where
    change value = setField "metadata" (setField "uid" (String "replacement-data") (field "metadata" value)) value

incomplete :: IO ()
incomplete = withSystemTempDirectory "nagare-cascade-incomplete" $ \root -> do
  (store, _, _) <- preparedCollection root
  before <- requireHead store
  result <- try @SomeException (prepareChange store (selected root IncompleteList) (CollectRetained parentId))
  assertBool "incomplete list accepted" (isLeft result)
  requireHead store >>= (@?= before)
  deleteBodies <$> readCollectionWorld root >>= (@?= [])

independentChild :: IO ()
independentChild = withSystemTempDirectory "nagare-cascade-owned-child" $ \root -> do
  (store, _, _) <- preparedCollection root
  world <- readCollectionWorld root
  let owned value =
        setField
          "metadata"
          ( setField
              "annotations"
              (object ["nagare.dev/resource-id" .= ("standalone:other/managed/service" :: Text)])
              (field "metadata" value)
          )
          value
  writeCollectionWorld root world {descendants = Map.adjust owned "route" (descendants world)}
  result <- try @SomeException (prepareChange store (selected root Cascade) (CollectRetained parentId))
  assertBool "independent ownership accepted" (isLeft result)
  deleteBodies <$> readCollectionWorld root >>= (@?= [])

protectedAfter :: IO ()
protectedAfter = withSystemTempDirectory "nagare-cascade-protected-after" $ \root -> do
  (store, bundle, reviewed) <- prepareCascade root
  result <- must (applyReviewed store (selected root Cascade) reviewed)
  assertUnresolved result
  world <- readCollectionWorld root
  writeCollectionWorld root (changeProtected world) {descendants = Map.empty}
  freshProcess root bundle (transactionOf result) "pending"
  Map.member parentId . headCollected <$> requireHead store >>= (@?= False)
  length . filter (elem "--raw") . requests <$> readCollectionWorld root >>= (@?= 1)

ordinaryRefuses :: IO ()
ordinaryRefuses = withSystemTempDirectory "nagare-cascade-old-adapter" $ \root -> do
  (store, _, reviewed) <- prepareCascade root
  before <- requireHead store
  result <- applyReviewed store (registry root Normal collectionNative) reviewed
  assertBool "ordinary adapter executed cascade review" (isLeft result)
  requireHead store >>= (@?= before)
  deleteBodies <$> readCollectionWorld root >>= (@?= [])

newAfter :: IO ()
newAfter = withSystemTempDirectory "nagare-cascade-new-child" $ \root -> do
  (store, bundle, reviewed) <- prepareCascade root
  result <- must (applyReviewed store (selected root Cascade) reviewed)
  assertUnresolved result
  world <- readCollectionWorld root
  let extra = descendants (addChild world) Map.! "extra"
  writeCollectionWorld root world {descendants = Map.singleton "extra" extra}
  freshProcess root bundle (transactionOf result) "pending"
  Map.member parentId . headCollected <$> requireHead store >>= (@?= False)
  length . filter (elem "--raw") . requests <$> readCollectionWorld root >>= (@?= 1)

statusChanges :: IO ()
statusChanges = withSystemTempDirectory "nagare-cascade-status" $ \root -> do
  (store, _, reviewed) <- prepareCascade root
  world <- readCollectionWorld root
  let bump value = setField "metadata" (setField "resourceVersion" (String "11") (field "metadata" value)) value
  writeCollectionWorld
    root
    world
      { descendants = Map.map bump (descendants world)
      , resources = Map.adjust bump "persistentvolumeclaim/pg-main-data" (resources world)
      }
  result <- must (applyReviewed store (selected root Cascade) reviewed)
  assertUnresolved result
  length . deleteBodies <$> readCollectionWorld root >>= (@?= 1)
