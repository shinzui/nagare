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
import Nagare.Inventory.Execute (AdmissionError (..), TransactionResult (..), admit, execute, resumeTransaction)
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
    , testCase "release resumes after interruption before any writer control" $
        withSystemTempDirectory "nagare-fence-release" $ \root -> do
          store <- openFilesystemStore root >>= right
          _ <- initializeStore store binding "operator-a" >>= right
          released <- newIORef False
          restored <- newIORef (0 :: Int)
          let original = fixtureControls released restored (pure (Right physical))
              interrupted = original {restoreFenceWriters = \_ ->
                pure (Left "interrupted before writer release")}
          token <- withProcessLock store (\locked -> acquireDataFence locked original request)
            >>= right >>= right
          _ <- withProcessLock store (\locked -> beginDataChange locked original token)
            >>= right >>= right
          _ <- withProcessLock store (\locked -> verifyDataChange locked original token)
            >>= right >>= right
          outcome <- withProcessLock store (\locked -> releaseDataFence locked interrupted token)
            >>= right
          case outcome of
            Left _ -> pure ()
            Right () -> assertFailure "interrupted release appeared complete"
          readIORef restored >>= (@?= 0)
          reopened <- openFilesystemStore root >>= right
          resumed <- withProcessLock reopened (\locked -> resumeDataFence locked "restore-session")
            >>= right >>= right
          _ <- withProcessLock reopened (\locked -> recoverDataFence locked original resumed)
            >>= right >>= right
          readIORef restored >>= (@?= 1)
          final <- readHead reopened >>= right >>= maybe
            (assertFailure "head missing" >> error "head") pure
          headDataFence final @?= Nothing
    , testCase "partial writer release is not replayed" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let original = fixtureControls released restored (pure (Right physical))
            partial = original
              { restoreFenceWriters = \_ -> do
                  modifyIORef' restored (+ 1)
                  pure (Left "one writer changed before interruption")
              , observeWritersReleased = \_ -> pure (Right WritersPartlyReleased)
              }
        token <- withProcessLock store (\locked -> acquireDataFence locked partial request)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> beginDataChange locked partial token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> verifyDataChange locked partial token)
          >>= right >>= right
        _ <- withProcessLock store (\locked -> releaseDataFence locked partial token)
          >>= right
        repeated <- withProcessLock store (\locked -> releaseDataFence locked partial token)
          >>= right
        case repeated of
          Left _ -> pure ()
          Right () -> assertFailure "partial writer release was accepted"
        readIORef restored >>= (@?= 1)
        active <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        fmap fencePhase (headDataFence active) @?= Just FenceReleasing
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
    , testCase "reviewed transaction may own only its matching fence" $ do
        store <- newMemoryStore
        initial <- initializeStore store binding "operator-a" >>= right
        let transaction = "tx-reviewed-restore"
            active = initial
              { headGeneration = 1
              , headActiveTransaction = Just transaction
              , headExecutorClaim = Just (ExecutorClaim transaction "operator-a" 1 "time")
              }
        _ <- replaceHeadIfGenerationMatches store (Just 0) active >>= right
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        wrong <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just "tx-other"}) >>= right
        case wrong of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign transaction acquired the fence"
        _ <- replaceHeadIfGenerationMatches store (Just 1)
          active {headGeneration = 2, headExecutorClaim =
            Just (ExecutorClaim transaction "operator-b" 2 "time")} >>= right
        foreignClaim <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just transaction}) >>= right
        case foreignClaim of
          Left _ -> pure ()
          Right _ -> assertFailure "a foreign executor acquired the fence"
        _ <- replaceHeadIfGenerationMatches store (Just 2)
          active {headGeneration = 3} >>= right
        _ <- withProcessLock store (\locked -> acquireDataFence locked controls
          request {fenceTransaction = Just transaction}) >>= right >>= right
        fenced <- readHead store >>= right >>= maybe (assertFailure "head missing" >> error "head") pure
        headActiveTransaction fenced @?= Just transaction
        fmap fenceTransaction (headDataFence fenced) @?= Just (Just transaction)
    , testCase "reviewed transaction cannot journal convergence while fenced" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "operator-a" >>= right
        let scope = known (mkScopeDeclaration fenceOwner [])
            snapshot = known (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = known (composeInventory snapshot (ReplaceScope scope :| []))
            registry = known (mkAdapterRegistry [])
        history <- loadInventoryHistory store >>= right
        proposal <- right (planChanges candidate noLifecycleDecisions history
          (known (observationSet [])))
        storeSnapshot <- readStoreSnapshot store >>= right
        review <- prepareReview registry storeSnapshot proposal >>= right
        _ <- publishReview store review >>= right
        issued <- readStoreSnapshot store >>= right
        reviewed <- right (verifyReview issued review)
        released <- newIORef False
        restored <- newIORef (0 :: Int)
        let controls = fixtureControls released restored (pure (Right physical))
        result <- withProcessLock store $ \locked -> do
          executable <- admit locked registry reviewed >>= right
          admitted <- readHead store >>= right >>= maybe
            (assertFailure "head missing" >> error "head") pure
          let transaction = maybe (error "transaction missing") id
                (headActiveTransaction admitted)
          _ <- acquireDataFence locked controls request
            { fenceTransaction = Just transaction
            , fenceAccepted = headAccepted admitted
            } >>= right
          execute locked registry executable
        outcome <- right result
        case outcome of
          Converged _ -> assertFailure "fenced transaction converged"
          _ -> pure ()
        transaction <- case outcome of
          StoppedAmbiguous value _ -> pure value
          _ -> assertFailure "fenced transaction did not stop unresolved" >> error "transaction"
        resumed <- resumeTransaction store registry transaction
        case resumed of
          Left errors -> assertBool "resume must defer to explicit fence recovery"
            (any ((== "active-data-fence") . admissionErrorCode) errors)
          Right _ -> assertFailure "resumed an actively fenced restore"
        fenced <- readHead store >>= right >>= maybe
          (assertFailure "head missing" >> error "head") pure
        headSequence fenced @?= 1
        assertBool "transaction remains active" (isJust (headActiveTransaction fenced))
        assertBool "fence remains active" (isJust (headDataFence fenced))
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
  , observeWritersReleased = \_ -> do
      wasReleased <- readIORef released
      pure (Right (if wasReleased then WritersFullyReleased else WritersStillExcluded))
  }

request :: DataFenceRecord
request = DataFenceRecord binding "restore-session" Nothing Map.empty physical
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
