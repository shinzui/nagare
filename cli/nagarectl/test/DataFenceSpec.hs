module DataFenceSpec (dataFenceTests) where

import Data.Aeson (eitherDecode, encode, object)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (mkAdapterRegistry, observationSet)
import Nagare.Inventory.DataFence
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (AdmissionError (..), admit)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

dataFenceTests :: TestTree
dataFenceTests = testGroup "data fence"
  [ testCase "reservation survives a new process and blocks planning until verified release" $
      withSystemTempDirectory "nagare-data-fence" $ \root -> do
        store <- openFilesystemStore root >>= right
        _ <- initializeStore store binding "operator-a" >>= right
        let scope = known (mkScopeDeclaration fenceOwner [])
            snapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = known (composeInventory snapshot (ReplaceScope scope :| []))
            registry = known (mkAdapterRegistry [])
        initialHistory <- loadInventoryHistory store >>= right
        proposal <- right (planChanges candidate noLifecycleDecisions initialHistory
          (known (observationSet [])))
        storeSnapshot <- readStoreSnapshot store >>= right
        review <- prepareReview registry storeSnapshot proposal >>= right
        _ <- publishReview store review >>= right
        issued <- readStoreSnapshot store >>= right
        reviewed <- right (verifyReview issued review)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        token <- withProcessLock store (\locked -> acquireDataFence locked controls request)
          >>= right >>= right
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceExcluded
        eitherDecode (encode active) @?= Right active
        reopened <- openFilesystemStore root >>= right
        history <- loadInventoryHistory reopened >>= right
        case planChanges candidate noLifecycleDecisions history (known (observationSet [])) of
          Left failures -> assertBool "active fence must block planning"
            (any ((== "active-data-fence") . planErrorCode) failures)
          Right _ -> assertFailure "active fence admitted a competing review"
        admission <- withProcessLock reopened (\locked ->
          fmap (fmap (const ())) (admit locked registry reviewed))
          >>= right
        case admission of
          Left errors -> assertBool "active fence must block saved review admission"
            (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "active fence admitted a saved review"
        _ <- withProcessLock reopened (\locked -> beginDataChange locked controls token)
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> markDataFenceUnresolved locked token)
          >>= right >>= right
        resumed <- withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> recoverDataFence locked controls resumed)
          >>= right >>= right
        _ <- withProcessLock reopened (\locked -> releaseDataFence locked controls resumed)
          >>= right >>= right
        final <- readHead reopened >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headDataFence final @?= Nothing
        readIORef restored >>= (@?= 1)
        readIORef released >>= (@?= True)
    , testCase "lost release acknowledgement is observed without replaying writer restoration" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            uncertain = original {restoreFenceWriters = \_ -> do
              modifyIORef' restored (+ 1)
              writeIORef released True
              pure (Left "release acknowledgement lost")}
        token <- withProcessLock store (\locked -> acquireDataFence locked uncertain request)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> beginDataChange locked uncertain token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> verifyDataChange locked uncertain token)
          >>= right >>= right
        outcome <- withProcessLock store (\locked -> releaseDataFence locked uncertain token)
          >>= right
        case outcome of
          Left _ -> pure ()
          Right () -> assertFailure "lost acknowledgement should remain unresolved"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
        _ <- withProcessLock store (\locked -> releaseDataFence locked uncertain token)
          >>= right >>= right
        readIORef restored >>= (@?= 1)
        final <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headDataFence final @?= Nothing
    , testCase "changed target identity leaves a durable unresolved fence" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let changed = Map.insert target (known (mkPhysicalIdentity "replacement-uid")) physical
            controls = fixtureControls released restored (pure (Right changed))
        outcome <- withProcessLock store (\locked -> acquireDataFence locked controls request)
          >>= right
        case outcome of
          Left _ -> pure ()
          Right _ -> assertFailure "changed target identity acquired fence"
        active <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceUnresolved
  ]

fixtureControls :: IORef Bool -> IORef Int
  -> IO (Either Text (Map.Map ResourceId PhysicalIdentity)) -> DataFenceControls
fixtureControls released restored observe = DataFenceControls
  { validateFenceInputs = \_ -> pure (Right ())
  , stopFenceWriters = \_ -> pure (Right ())
  , observeFencePhysical = \_ -> observe
  , observeWritersExcluded = \_ -> pure (Right True)
  , verifyRecoveredData = \_ -> pure (Right True)
  , restoreFenceWriters = \_ -> do
      modifyIORef' restored (+ 1)
      writeIORef released True
      pure (Right ())
  , observeWritersReleased = \_ -> Right <$> readIORef released
  }

request :: DataFenceRecord
request = DataFenceRecord binding "restore-session" Map.empty physical
  (Set.singleton target) (Set.singleton writer) "gs://fixture/recovery"
  (contentDigest "recovery") (Map.singleton writer (object [])) FenceAcquiring ""

physical :: Map.Map ResourceId PhysicalIdentity
physical = Map.fromList
  [ (target, known (mkPhysicalIdentity "target-uid"))
  , (writer, known (mkPhysicalIdentity "writer-uid"))
  ]

binding :: ContextBinding
binding = ContextBinding (known (mkContextId "fence-fixture")) (known (mkName "project"))

fenceOwner :: ScopeId
fenceOwner = known (mkScopeId Standalone "fence-fixture")

target :: ResourceId
target = mintResourceId fenceOwner (known (mkLogicalKey "target")) (known (mkName "pvc"))

writer :: ResourceId
writer = mintResourceId fenceOwner (known (mkLogicalKey "writer")) (known (mkName "deployment"))

known :: Show e => Either e a -> a
known = either (error . show) id

right :: Show e => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure
