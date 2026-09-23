module InventoryTransactionSpec (inventoryTransactionTests, runInventoryLockHoldProbe, runInventoryLockProbe) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (toJSON)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Cache (LogicalCacheInput (..), compileLogicalCache)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..), OutputConstraint (NonEmptyOutput), SomeRef (..), Witness (NixCachePublicKeyW), outputRef)
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory (doesFileExist, listDirectory, removeFile)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp
import System.Process (CreateProcess (env), createProcess, proc, terminateProcess, waitForProcess)
import Test.Tasty
import Test.Tasty.HUnit

inventoryTransactionTests :: TestTree
inventoryTransactionTests =
  testGroup
    "inventory transactions"
    [ testCase "conditional store contract is identical in memory and on disk" $ do
        memory <- newMemoryStore
        exerciseStore memory
        withSystemTempDirectory "inventory-store" $ \root -> do
          filesystem <- openFilesystemStore root >>= expectRight
          exerciseStore filesystem
    , testCase "dependency order does not turn an accepted resource into an update" $ do
        let owner = ok (mkScopeId Platform "dependency-order")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            first = member owner cluster "first"
            second = member owner cluster "second"
            dependent = case member owner cluster "dependent" of
              Managed value -> value
              _ -> error "test member must be managed"
            firstId = declarationId first
            secondId = declarationId second
            original =
              ok
                ( mkScopeDeclaration
                    owner
                    [ ResourceBundle
                        [ first
                        , second
                        , Managed
                            ( dependent
                                { dependencies =
                                    [OrderedAfter firstId, OrderedAfter secondId]
                                }
                            )
                        ]
                        []
                        []
                        []
                        []
                        []
                    ]
                )
            reordered =
              ok
                ( mkScopeDeclaration
                    owner
                    [ ResourceBundle
                        [ first
                        , second
                        , Managed
                            ( dependent
                                { dependencies =
                                    [OrderedAfter secondId, OrderedAfter firstId]
                                }
                            )
                        ]
                        []
                        []
                        []
                        []
                        []
                    ]
                )
            absent = contentDigest "absent"
            registry =
              recordingRegistry
                (\_ _ -> pure AdapterEffectCompleted)
                (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "dependency-order-test" >>= expectRight
        initialHistory <- loadInventoryHistory store >>= expectRight
        let initial =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
                    (ReplaceScope original :| [])
                )
            initialProposal =
              ok
                ( planChanges
                    initial
                    noLifecycleDecisions
                    initialHistory
                    ( ok
                        ( observationSet
                            [ (resource, ConfirmedAbsent absent)
                            | resource <- Set.toAscList (requiredResources (observationRequirements initial initialHistory))
                            ]
                        )
                    )
                )
        snapshot <- readStoreSnapshot store >>= expectRight
        review <- prepareReview registry snapshot initialProposal >>= expectRight
        _ <- publishReview store review >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        admitted <- expectRight (verifyReview published review)
        _ <- applyReviewed store registry admitted >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let accepted =
              Map.map
                (\(revision, value) -> (revisionGeneration revision, value))
                (historyAccepted history)
            replay =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot fixtureBinding accepted Map.empty))
                    (ReplaceScope reordered :| [])
                )
            observed =
              ok
                ( observationSet
                    [ (resource, ObservedPresent (ok (mkPhysicalIdentity (resourceIdText resource))))
                    | resource <- Set.toAscList (requiredResources (observationRequirements replay history))
                    ]
                )
            proposal = ok (planChanges replay noLifecycleDecisions history observed)
        proposalOperations proposal @?= []
    , testCase "a changed payload source path does not update identical resources" $ do
        let owner = ok (mkScopeId Platform "source-path")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            originalMember = member owner cluster "config"
            changedMember = case originalMember of
              Managed resource -> Managed (resource {source = SourceLocation "payload/new-release/config.yaml" "source-path"})
              _ -> error "test member must be managed"
            original = ok (mkScopeDeclaration owner [ResourceBundle [originalMember] [] [] [] [] []])
            changed = ok (mkScopeDeclaration owner [ResourceBundle [changedMember] [] [] [] [] []])
            registry =
              recordingRegistry
                (\_ _ -> pure AdapterEffectCompleted)
                (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "source-path-test" >>= expectRight
        initialHistory <- loadInventoryHistory store >>= expectRight
        let initial =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
                    (ReplaceScope original :| [])
                )
            required = requiredResources (observationRequirements initial initialHistory)
            initialObservations =
              ok
                ( observationSet
                    [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- Set.toAscList required]
                )
            initialProposal = ok (planChanges initial noLifecycleDecisions initialHistory initialObservations)
        snapshot <- readStoreSnapshot store >>= expectRight
        review <- prepareReview registry snapshot initialProposal >>= expectRight
        _ <- publishReview store review >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        admitted <- expectRight (verifyReview published review)
        _ <- applyReviewed store registry admitted >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let accepted =
              Map.map
                (\(revision, value) -> (revisionGeneration revision, value))
                (historyAccepted history)
            replay =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot fixtureBinding accepted Map.empty))
                    (ReplaceScope changed :| [])
                )
            observed =
              ok
                ( observationSet
                    [ (resource, ObservedPresent (ok (mkPhysicalIdentity (resourceIdText resource))))
                    | resource <- Set.toAscList (requiredResources (observationRequirements replay history))
                    ]
                )
            proposal = ok (planChanges replay noLifecycleDecisions history observed)
        proposalOperations proposal @?= []
    , testCase "a second namespace contributor does not recreate the accepted shared resource" $ do
        let owner = ok (mkScopeId Platform "foundation")
            firstContributor = ok (mkScopeId Application "first")
            second = ok (mkScopeId Application "second")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            request = RegisterNamespace owner cluster (ok (mkName "shared")) (ok (mkLogicalKey "shared"))
            grant = ResourceBundle [] [] [] [] [] [NamespaceGrant firstContributor cluster, NamespaceGrant second cluster]
            platform = ok (mkScopeDeclaration owner [grant])
            contributor who = ok (mkScopeDeclaration who [ResourceBundle [] [] [] [request] [] []])
            binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
            candidate =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot binding Map.empty Map.empty))
                    (ReplaceScope platform :| [ReplaceScope (contributor firstContributor)])
                )
            absent = ConfirmedAbsent (contentDigest "absent")
            registry =
              recordingRegistry
                (\_ _ -> pure AdapterEffectCompleted)
                (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        store <- newMemoryStore
        _ <- initializeStore store binding "contribution-test" >>= expectRight
        initialHistory <- loadInventoryHistory store >>= expectRight
        let initialRequired = requiredResources (observationRequirements candidate initialHistory)
            initialObservations = ok (observationSet [(resource, absent) | resource <- Set.toAscList initialRequired])
            initialProposal = ok (planChanges candidate noLifecycleDecisions initialHistory initialObservations)
        length (proposalOperations initialProposal) @?= 1
        storeBefore <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry storeBefore initialProposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        storeAfter <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview storeAfter bundle)
        applied <- applyReviewed store registry reviewed >>= expectRight
        case applied of Converged _ -> pure (); other -> assertFailure (show other)
        history <- loadInventoryHistory store >>= expectRight
        let snapshot =
              ok
                ( mkScopeSnapshot
                    binding
                    (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history))
                    Map.empty
                )
            next = ok (composeInventory snapshot (ReplaceScope (contributor second) :| []))
            required = requiredResources (observationRequirements next history)
            present resource = ObservedPresent (ok (mkPhysicalIdentity ("accepted:" <> resourceIdText resource)))
            observations = ok (observationSet [(resource, present resource) | resource <- Set.toAscList required])
            proposal = ok (planChanges next noLifecycleDecisions history observations)
        length (Set.toAscList required) @?= 1
        proposalOperations proposal @?= []
        let missingObservations =
              ok
                ( observationSet
                    [ (resource, absent)
                    | resource <- Set.toAscList required
                    ]
                )
            repair = ok (planChanges next noLifecycleDecisions history missingObservations)
        case proposalOperations repair of
          [operation] -> plannedAction operation @?= CreateResource
          other -> assertFailure ("missing accepted Namespace was not recreated, got " <> show other)
    , testCase "missing accepted durable resource refuses automatic recreation" $ do
        let owner = ok (mkScopeId Platform "durable")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            recovery =
              RecoveryIntent
                (ok (mkName "backup"))
                (mkSecretRef (ok (mkName "credential")) (ok (mkName "v1")) :| [])
            protected = case member owner cluster "data" of
              Managed resource -> Managed (resource {dataPolicy = Durable recovery})
              _ -> error "expected a managed resource"
            scope = ok (mkScopeDeclaration owner [ResourceBundle [protected] [] [] [] [] []])
            binding = ContextBinding (ok (mkContextId "durable-test")) (ok (mkName "project"))
            candidate =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot binding Map.empty Map.empty))
                    (ReplaceScope scope :| [])
                )
            registry =
              recordingRegistry
                (\_ _ -> pure AdapterEffectCompleted)
                (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
            absent = ConfirmedAbsent (contentDigest "absent")
        store <- newMemoryStore
        _ <- initializeStore store binding "durable-test" >>= expectRight
        initialHistory <- loadInventoryHistory store >>= expectRight
        let required = requiredResources (observationRequirements candidate initialHistory)
            observations = ok (observationSet [(resource, absent) | resource <- Set.toAscList required])
            proposal = ok (planChanges candidate noLifecycleDecisions initialHistory observations)
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        snapshotAfter <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshotAfter bundle)
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        history <- loadInventoryHistory store >>= expectRight
        let accepted =
              ok
                ( mkScopeSnapshot
                    binding
                    ( Map.map
                        (\(revision, declared) -> (revisionGeneration revision, declared))
                        (historyAccepted history)
                    )
                    Map.empty
                )
            again = ok (composeInventory accepted (ReplaceScope scope :| []))
            missing =
              ok
                ( observationSet
                    [ (resource, absent)
                    | resource <- Set.toAscList (requiredResources (observationRequirements again history))
                    ]
                )
        case planChanges again noLifecycleDecisions history missing of
          Left errors ->
            assertBool
              "missing durable resource lacked a recovery refusal"
              (any ((== "durable-resource-missing") . planErrorCode) (NE.toList errors))
          Right _ -> assertFailure "missing durable resource was silently recreated"
    , testCase "declared cache operation waits for its resource, database, and workload" $ do
        let owner = ok (mkScopeId Platform "cache")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            database = member owner cluster "database"
            workload = member owner cluster "workload"
            cacheId = mintResourceId owner (ok (mkLogicalKey "cache")) (ok (mkName "logical-cache"))
            publicKey = outputRef NixCachePublicKeyW cacheId (ok (mkName "public-key")) [NonEmptyOutput] Public
            client = case member owner cluster "client" of
              Managed resource -> Managed (resource {dependencies = [Consumes (SomeRef publicKey)]})
              _ -> error "client fixture is not managed"
            cache =
              compileLogicalCache
                ( LogicalCacheInput
                    owner
                    cluster
                    (ok (mkLogicalKey "cache"))
                    (ok (mkName "cache"))
                    (contentDigest "config")
                    (declarationId database)
                    (declarationId workload)
                    (SourceLocation "test" "cache")
                )
            scope = ok (mkScopeDeclaration owner [ResourceBundle [database, workload, client] [] [] [] [] [], cache])
            binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
            snapshot = ok (mkScopeSnapshot binding Map.empty Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
        store <- newMemoryStore
        _ <- initializeStore store binding "cache-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let requirements = observationRequirements candidate history
            observations = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- Set.toAscList (requiredResources requirements)])
            proposal = ok (planChanges candidate noLifecycleDecisions history observations)
            allOperations = proposalOperations proposal
            creates =
              [ plannedOperationId operation
              | operation <- allOperations
              , plannedAction operation == CreateResource
              , declarationId client `notElem` NE.toList (plannedResources operation)
              ]
        case [operation | operation <- allOperations, plannedAction operation == RunDeclaredOperation] of
          [operation] -> do
            Set.fromList (plannedDependencies operation) @?= Set.fromList creates
            case [ clientCreate
                 | clientCreate <- allOperations
                 , plannedAction clientCreate == CreateResource
                 , declarationId client `elem` NE.toList (plannedResources clientCreate)
                 ] of
              [clientCreate] -> plannedDependencies clientCreate @?= [plannedOperationId operation]
              other -> assertFailure ("expected one client creation, got " <> show other)
          other -> assertFailure ("expected one declared cache operation, got " <> show other)
    , testCase "workload creation waits for its declared migration operation" $ do
        let owner = ok (mkScopeId Platform "migration")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            database = member owner cluster "database"
            workload = member owner cluster "workload"
            migrationId = mintResourceId owner (ok (mkLogicalKey "migration")) (ok (mkName "operation"))
            migration = DeclaredOperation migrationId (declarationId database :| []) [] VerifyBeforeRetry SchemaMigration
            waiting = case workload of
              Managed resource -> Managed (resource {dependencies = [OrderedAfter migrationId]})
              _ -> error "workload fixture is not managed"
            scope = ok (mkScopeDeclaration owner [ResourceBundle [database, waiting] [] [] [] [migration] []])
            binding = ContextBinding (ok (mkContextId "test")) (ok (mkName "project"))
            candidate = ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope scope :| []))
        store <- newMemoryStore
        _ <- initializeStore store binding "migration-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let requirements = observationRequirements candidate history
            observations = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- Set.toAscList (requiredResources requirements)])
            allOperations = proposalOperations (ok (planChanges candidate noLifecycleDecisions history observations))
        case ( [op | op <- allOperations, plannedAction op == RunDeclaredOperation]
             , [op | op <- allOperations, plannedAction op == CreateResource, declarationId waiting `elem` NE.toList (plannedResources op)]
             ) of
          ([migrationOperation], [workloadOperation]) ->
            assertBool "workload does not wait for migration" (plannedOperationId migrationOperation `elem` plannedDependencies workloadOperation)
          other -> assertFailure ("expected migration and workload operations, got " <> show other)
    , testCase "proved migration survives TTL removal of its Job" $ do
        let owner = ok (mkScopeId Platform "ttl-migration")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            job = case member owner cluster "migration" of
              Managed resource ->
                Managed
                  ( resource
                      { address =
                          Kubernetes
                            cluster
                            "batch"
                            (ok (mkName "job"))
                            (Just (ok (mkName "system")))
                            (ok (mkName "migration"))
                      }
                  )
              _ -> error "expected a managed Job"
            jobId = declarationId job
            migrationId = mintResourceId owner (ok (mkLogicalKey "migration")) (ok (mkName "proof"))
            migration digest =
              DeclaredOperation
                migrationId
                (jobId :| [])
                [ContentInput digest]
                VerifyBeforeRetry
                SchemaMigration
            scope =
              ok
                ( mkScopeDeclaration
                    owner
                    [ResourceBundle [job] [] [] [] [migration (contentDigest "v1")] []]
                )
            binding = ContextBinding (ok (mkContextId "ttl-migration")) (ok (mkName "project"))
            candidate =
              ok
                ( composeInventory
                    (ok (mkScopeSnapshot binding Map.empty Map.empty))
                    (ReplaceScope scope :| [])
                )
            registry =
              recordingRegistry
                (\_ _ -> pure AdapterEffectCompleted)
                (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
            absent = ConfirmedAbsent (contentDigest "absent")
        store <- newMemoryStore
        _ <- initializeStore store binding "ttl-migration" >>= expectRight
        historyBefore <- loadInventoryHistory store >>= expectRight
        let observations =
              ok
                ( observationSet
                    [ (resource, absent)
                    | resource <-
                        Set.toAscList
                          (requiredResources (observationRequirements candidate historyBefore))
                    ]
                )
            proposal = ok (planChanges candidate noLifecycleDecisions historyBefore observations)
        length (proposalOperations proposal) @?= 2
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        snapshotAfter <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshotAfter bundle)
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        history <- loadInventoryHistory store >>= expectRight
        let accepted =
              ok
                ( mkScopeSnapshot
                    binding
                    ( Map.map
                        (\(revision, declared) -> (revisionGeneration revision, declared))
                        (historyAccepted history)
                    )
                    Map.empty
                )
            again = ok (composeInventory accepted (ReplaceScope scope :| []))
            missing =
              ok
                ( observationSet
                    [ (resource, absent)
                    | resource <- Set.toAscList (requiredResources (observationRequirements again history))
                    ]
                )
            noReplay = ok (planChanges again noLifecycleDecisions history missing)
        proposalOperations noReplay @?= []
        let updatedScope =
              ok
                ( mkScopeDeclaration
                    owner
                    [ResourceBundle [job] [] [] [] [migration (contentDigest "v2")] []]
                )
            updated = ok (composeInventory accepted (ReplaceScope updatedScope :| []))
            replay = ok (planChanges updated noLifecycleDecisions history missing)
        assertBool
          "changed migration inputs were treated as proven"
          (any ((== RunDeclaredOperation) . plannedAction) (proposalOperations replay))
    , testCase "reviewed execution converges and skips no completed operation" $ do
        store <- newMemoryStore
        calls <- newIORef ([] :: [OperationId])
        (reviewed, registry) <- preparedFixture store calls (const (pure AdapterEffectCompleted)) (\operation -> pure (RecoveryProvedComplete (proof operation)))
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        length <$> readIORef calls >>= (@?= 1)
        headValue <- readHead store >>= expectRight >>= maybe (assertFailure "missing head" >> undefined) pure
        headActiveTransaction headValue @?= Nothing
        headAccepted headValue @?= headConverged headValue
    , testCase "ambiguous execution resumes from adapter proof without repeating the effect" $ do
        store <- newMemoryStore
        calls <- newIORef ([] :: [OperationId])
        firstAttempt <- newIORef True
        let executeOnce operation _ = do
              modifyIORef' calls (<> [plannedOperationId operation])
              wasFirst <- atomicModifyIORef' firstAttempt (\value -> (False, value))
              pure (if wasFirst then AdapterEffectAmbiguous "simulated process loss" else AdapterEffectCompleted)
        (reviewed, registry) <- preparedFixtureWith store executeOnce (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        history <- loadInventoryHistory store >>= expectRight
        bytes <- BS.readFile "test/fixtures/inventory/valid.json"
        let CandidateInput snapshot changes = ok (decodeCandidateInput bytes)
            candidate = ok (composeInventory snapshot changes)
            observations = ok (observationSet [])
        case planChanges candidate noLifecycleDecisions history observations of
          Left errors ->
            assertBool
              "new planning did not refuse the unresolved transaction"
              (any ((== "active-transaction") . planErrorCode) (NE.toList errors))
          Right _ -> assertFailure "new planning admitted an unresolved transaction"
        resumed <- resumeTransaction store registry transaction >>= expectRight
        case resumed of Converged value -> value @?= transaction; other -> assertFailure (show other)
        length <$> readIORef calls >>= (@?= 1)
    , testCase "resume recovers an ambiguous effect before checking its old precondition" $ do
        store <- newMemoryStore
        effected <- newIORef False
        calls <- newIORef (0 :: Int)
        let preflight _ _ = do
              changed <- readIORef effected
              pure (if changed then Left "old absent precondition changed" else Right ())
            executeOnce _ _ = do
              modifyIORef' calls (+ 1)
              writeIORef effected True
              pure (AdapterEffectAmbiguous "lost acknowledgement after effect")
            recover operation _ = do
              changed <- readIORef effected
              pure (if changed then RecoveryProvedComplete (proof operation) else RecoveryUnresolved "effect missing")
        (reviewed, _) <- preparedFixtureWith store executeOnce recover
        let registry = recordingRegistryWith preflight executeOnce recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        resumed <- resumeTransaction store registry transaction >>= expectRight
        resumed @?= Converged transaction
        readIORef calls >>= (@?= 1)
    , testCase "known no-effect failure retries the same reviewed operation" $ do
        store <- newMemoryStore
        attempts <- newIORef (0 :: Int)
        let executeRetry _ _ = do
              attempt <- atomicModifyIORef' attempts (\value -> (value + 1, value))
              pure (if attempt == 0 then AdapterEffectFailed (KnownNoEffect "simulated refusal") else AdapterEffectCompleted)
        (reviewed, registry) <- preparedFixtureWith store executeRetry (\_ _ -> pure RecoverySafeToRetry)
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedFailed value _ _ -> pure value; other -> assertFailure (show other) >> undefined
        resumed <- resumeTransaction store registry transaction >>= expectRight
        case resumed of Converged _ -> pure (); other -> assertFailure (show other)
        readIORef attempts >>= (@?= 2)
    , testCase "stale review is refused before adapter preflight" $ do
        store <- newMemoryStore
        calls <- newIORef (0 :: Int)
        (reviewed, _) <- preparedFixtureWith store (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        current <- readHead store >>= expectRight >>= maybe (assertFailure "missing head" >> undefined) pure
        let advanced = current {headGeneration = headGeneration current + 1}
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration current)) advanced >>= expectRight
        let registry = recordingRegistryWith (\_ _ -> modifyIORef' calls (+ 1) >> pure (Right ())) (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        refused <- applyReviewed store registry reviewed
        assertBool "stale review refused" (isLeft refused)
        readIORef calls >>= (@?= 0)
    , testCase "operator-facing review excludes private native evidence" $
        withSystemTempDirectory "inventory-review" $ \root -> do
          store <- newMemoryStore
          (reviewed, _) <- preparedFixtureWith store (\_ _ -> pure AdapterEffectCompleted) (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
          let document = reviewedDocument reviewed
              transactionDigest = contentDigest (encodeReviewDocument document)
          fullBundle <- loadPublishedReview store transactionDigest >>= expectRight
          _ <- writeReviewBundle (root </> "review") fullBundle >>= expectRight
          entries <- listDirectory (root </> "review")
          assertBool "native directory is absent" ("native" `notElem` entries)
          publicBundle <- loadReviewBundle (root </> "review") >>= expectRight
          reviewBundleDocument publicBundle @?= reviewBundleDocument fullBundle
          reviewBundleScopes publicBundle @?= reviewBundleScopes fullBundle
          assertBool "store-backed bundle carries native evidence for adapter construction" (not (Map.null (reviewBundleNative fullBundle)))
          assertBool "public bundle carries no native evidence" (Map.null (reviewBundleNative publicBundle))
          snapshot <- readStoreSnapshot store >>= expectRight
          assertBool "public bundle alone is not executable" (isLeft (verifyReview snapshot publicBundle))
    , testCase "adapter execution cannot re-enter the inventory lock" $ do
        store <- newMemoryStore
        let reenter _ _ = do
              result <- withProcessLock store (\_ -> pure ())
              pure $ case result of
                Left StoreReentry -> AdapterEffectCompleted
                _ -> AdapterEffectFailed (PartialOrUnknown "inventory re-entry was not rejected")
        (reviewed, registry) <- preparedFixtureWith store reenter (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
    , testCase "adapter children receive scoped transaction and executor markers" $ do
        store <- newMemoryStore
        observed <- newIORef Nothing
        let inspect operation _ = do
              transaction <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
              child <- lookupEnv "NAGARE_INVENTORY_ADAPTER_CHILD"
              writeIORef observed (Just (plannedExecutor operation, transaction, child))
              pure AdapterEffectCompleted
        transactionBefore <- lookupEnv "NAGARE_INVENTORY_TRANSACTION"
        childBefore <- lookupEnv "NAGARE_INVENTORY_ADAPTER_CHILD"
        (reviewed, registry) <- preparedFixtureWith store inspect (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        result <- applyReviewed store registry reviewed >>= expectRight
        case result of Converged _ -> pure (); other -> assertFailure (show other)
        readIORef observed >>= (@?= Just (KubernetesExecutor, Just (transactionToken reviewed), Just "kubernetes"))
        lookupEnv "NAGARE_INVENTORY_TRANSACTION" >>= (@?= transactionBefore)
        lookupEnv "NAGARE_INVENTORY_ADAPTER_CHILD" >>= (@?= childBefore)
    , testCase "complete backup restores and incomplete backup is refused" $
        withSystemTempDirectory "inventory-backup" $ \root -> do
          source <- openFilesystemStore (root </> "source") >>= expectRight
          _ <- initializeStore source fixtureBinding "client-test" >>= expectRight
          _ <- publishIfAbsent source (objectKeyFor "objects" (contentDigest "retained")) "retained" >>= expectRight
          let backup = root </> "backup"
          exported <- withProcessLock source (\locked -> exportStore locked backup) >>= expectRight
          _ <- expectRight exported
          restored <- newMemoryStore
          readHead restored >>= (@?= Right Nothing)
          _ <- restoreStore restored backup >>= expectRight
          readHead restored >>= expectRight >>= (@?= Just (HeadManifest 1 0 0 fixtureBinding "client-test" Map.empty Map.empty Nothing Nothing))
          removeFile (backup </> "head.json")
          incomplete <- newMemoryStore
          refused <- restoreStore incomplete backup
          assertBool "missing backup member refused" (isLeft refused)
    , testCase "a second process is refused while the filesystem process lock is held" $
        withSystemTempDirectory "inventory-lock" $ \root -> do
          store <- openFilesystemStore root >>= expectRight
          held <- withProcessLock store $ \_ -> do
            executable <- getExecutablePath
            environment <- getEnvironment
            let childEnvironment = ("NAGARE_INVENTORY_LOCK_PROBE", root) : filter ((/= "NAGARE_INVENTORY_LOCK_PROBE") . fst) environment
            (_, _, _, process) <- createProcess (proc executable []) {env = Just childEnvironment}
            status <- waitForProcess process
            status @?= ExitSuccess
          case held of Right () -> pure (); other -> assertFailure (show other)
    , testCase "filesystem process lock is released when its holder dies" $
        withSystemTempDirectory "inventory-lock-death" $ \root -> do
          store <- openFilesystemStore root >>= expectRight
          executable <- getExecutablePath
          environment <- getEnvironment
          let ready = root </> "child-ready"
              childEnvironment =
                ("NAGARE_INVENTORY_LOCK_HOLD", root)
                  : ("NAGARE_INVENTORY_LOCK_READY", ready)
                  : filter (\(name, _) -> name /= "NAGARE_INVENTORY_LOCK_HOLD" && name /= "NAGARE_INVENTORY_LOCK_READY") environment
          (_, _, _, process) <- createProcess (proc executable []) {env = Just childEnvironment}
          waitUntilReady ready 100
          withProcessLock store (\_ -> pure ()) >>= (@?= Left StoreBusy)
          terminateProcess process
          _ <- waitForProcess process
          withProcessLock store (\_ -> pure ()) >>= (@?= Right ())
    , testCase "journal validation rejects a missing or reordered event" $ do
        let transaction = ok (mkTransactionId ("tx-" <> T.replicate 64 "a"))
            operation = ok (mkOperationId "op-one")
            firstEvent = JournalEvent 1 0 Nothing transaction (Just operation) IntentRecorded "2026-09-22T00:00:00Z" "intent"
            secondEvent = JournalEvent 1 1 (Just (journalEventDigest firstEvent)) transaction (Just operation) (Completed (proofOperation operation)) "2026-09-22T00:00:01Z" "done"
        validateJournal [firstEvent, secondEvent] @?= Right [firstEvent, secondEvent]
        assertBool "missing event refused" (isLeft (validateJournal [secondEvent]))
    ]

exerciseStore :: InventoryStore -> Assertion
exerciseStore store = do
  let binding = fixtureBinding
  initial <- initializeStore store binding "client-test" >>= expectRight
  headGeneration initial @?= 0
  let bytes = "immutable"
      key = objectKeyFor "objects" (contentDigest bytes)
  _ <- publishIfAbsent store key bytes >>= expectRight
  _ <- publishIfAbsent store key bytes >>= expectRight
  conflicting <- publishIfAbsent store key "different"
  assertBool "different bytes at an immutable key are refused" (isLeft conflicting)
  let replacement = initial {headGeneration = 1}
  _ <- replaceHeadIfGenerationMatches store (Just 0) replacement >>= expectRight
  stale <- replaceHeadIfGenerationMatches store (Just 0) replacement
  assertBool "stale head generation is refused" (isLeft stale)

preparedFixture :: InventoryStore -> IORef [OperationId] -> (PlannedOperation -> IO AdapterExecution) -> (PlannedOperation -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixture store calls execution recovery =
  preparedFixtureWith store (\operation _ -> modifyIORef' calls (<> [plannedOperationId operation]) >> execution operation) (\operation _ -> recovery operation)

preparedFixtureWith :: InventoryStore -> (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixtureWith store execution recovery = do
  bytes <- BS.readFile "test/fixtures/inventory/valid.json"
  let CandidateInput snapshot changes = ok (decodeCandidateInput bytes)
      candidate = ok (composeInventory snapshot changes)
      binding = inventoryBinding (candidateInventory candidate)
  _ <- initializeStore store binding "client-test" >>= expectRight
  _ <- seedInventoryHistory store candidate >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let acceptedIds = Set.fromList [declarationId declaration | (_, (_, scope)) <- Map.toAscList (historyAccepted history), bundle <- scopeBundles scope, declaration <- bundle ^. #declarations]
      requirements = observationRequirements candidate history
      observations =
        ok $
          observationSet
            [ (resource, if Set.member resource acceptedIds then ObservedPresent (physical resource) else ConfirmedAbsent (absence resource))
            | resource <- Set.toAscList (requiredResources requirements)
            ]
      registry = recordingRegistry execution recovery
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  snapshotBefore <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshotBefore proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  snapshotAfter <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshotAfter bundle)
  pure (reviewed, registry)
  where
    physical resource = ok (mkPhysicalIdentity ("accepted:" <> resourceIdText resource))
    absence resource = contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource))

recordingRegistry :: (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> AdapterRegistry
recordingRegistry execution recovery =
  recordingRegistryWith (\_ _ -> pure (Right ())) execution recovery

recordingRegistryWith :: (PlannedOperation -> PreparedNative -> IO (Either T.Text ())) -> (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> AdapterRegistry
recordingRegistryWith preflight execution recovery =
  ok (mkAdapterRegistry (map adapter [KubernetesExecutor, PulumiExecutor, HostExecutor, ArtifactExecutor, CacheExecutor]))
  where
    adapter executor =
      Adapter
        { adapterExecutor = executor
        , adapterIdentity = "recording"
        , adapterVersion = "1"
        , adapterObserve = \_ -> pure (Left "tests inject observations")
        , adapterPrepare = \operation -> pure (Right (PreparedNative (canonical operation) "recording adapter"))
        , adapterPreflight = preflight
        , adapterExecute = execution
        , adapterVerify = \operation _ -> pure (Right (proof operation))
        , adapterRecover = recovery
        }
    canonical = either (error . T.unpack) id . canonicalValue . toJSON

proof :: PlannedOperation -> ContentDigest
proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

proofOperation :: OperationId -> ContentDigest
proofOperation = contentDigest . TE.encodeUtf8 . operationIdText

transactionToken :: ReviewedPlan -> String
transactionToken reviewed = "tx-" <> T.unpack (digestText (contentDigest (encodeReviewDocument (reviewedDocument reviewed))))

fixtureBinding :: ContextBinding
fixtureBinding = ContextBinding (ok (mkContextId "context-1")) (ok (mkName "project"))

member :: ScopeId -> ResourceId -> Text -> Declaration
member owner cluster role =
  Managed
    ManagedResource
      { identity = mintResourceId owner (ok (mkLogicalKey role)) (ok (mkName "resource"))
      , owner = owner
      , executor = KubernetesExecutor
      , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName role))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 role))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "test" role
      }

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

runInventoryLockProbe :: FilePath -> IO ExitCode
runInventoryLockProbe root = do
  storeResult <- openFilesystemStore root
  case storeResult of
    Left _ -> pure (ExitFailure 2)
    Right store -> do
      result <- withProcessLock store (\_ -> pure ())
      pure $ case result of Left StoreBusy -> ExitSuccess; _ -> ExitFailure 1

runInventoryLockHoldProbe :: FilePath -> FilePath -> IO ExitCode
runInventoryLockHoldProbe root ready = do
  storeResult <- openFilesystemStore root
  case storeResult of
    Left _ -> pure (ExitFailure 2)
    Right store -> do
      result <- withProcessLock store $ \_ -> do
        writeFile ready "ready"
        threadDelay 30000000
      pure $ case result of Right () -> ExitSuccess; Left _ -> ExitFailure 1

waitUntilReady :: FilePath -> Int -> Assertion
waitUntilReady path attempts
  | attempts <= 0 = assertFailure "child did not acquire the inventory process lock"
  | otherwise = do
      ready <- doesFileExist path
      unless ready (threadDelay 10000 >> waitUntilReady path (attempts - 1))
