module InventoryTransactionSpec (inventoryTransactionTests, exerciseStore, fixtureBinding, preparedFixtureWith, preparedFixtureWithRegistry, recordingRegistryWith, runInventoryLockHoldProbe, runInventoryLockProbe) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode, object, toJSON, (.=))
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
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.BootstrapRegistryRecovery
import Nagare.Inventory.BootstrapRegistryTransport
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (AdoptionInput (..), AdoptionTarget (..), decideAdoption, decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.OperationStep
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.Store
import Nagare.Resource.Cache (LogicalCacheInput (..), compileLogicalCache)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..), OutputConstraint (NonEmptyOutput), SomeRef (..), Witness (NixCachePublicKeyW), outputRef)
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory (doesFileExist, findExecutable, listDirectory, removeFile)
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
    [ testCase "a saved scheduled prune refuses admission before adapter effects" $ do
        calls <- newIORef ([] :: [OperationId])
        let owner = ok (mkScopeId Standalone "deferred-prune-test")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster"))
              (ok (mkName "cluster"))
            managed = member owner cluster "prune-job"
            resource = declarationId managed
            operation = DeclaredOperation
              (mintResourceId owner (ok (mkLogicalKey "prune"))
                (ok (mkName "operation")))
              (resource :| []) [ContentInput (contentDigest "prune-intent")]
              OperatorRecovery PruneData
            scope = withScopeOverrides
              (Map.singleton "scheduled.prune.backup.scope" "accepted-backup")
              (ok (mkScopeDeclaration owner
                [ResourceBundle [managed] [] [] [] [operation] []]))
            candidate = ok (composeInventory
              (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope scope :| []))
            registry = recordingRegistry
              (\planned _ -> modifyIORef' calls (<> [plannedOperationId planned])
                >> pure AdapterEffectCompleted)
              (\_ _ -> pure (RecoveryUnresolved "no recovery"))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "deferred-prune-test"
          >>= expectRight
        _ <- seedInventoryHistory store candidate >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let observations = ok (observationSet
              [(resource, ConfirmedAbsent (contentDigest "absent"))])
            proposal = ok (planChanges candidate noLifecycleDecisions
              history observations)
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        publishedSnapshot <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure
          (verifyReview publishedSnapshot bundle)
        refused <- applyReviewed store registry reviewed
        case refused of
          Left errors -> map admissionErrorCode (NE.toList errors)
            @?= ["deferred-operation"]
          Right _ -> assertFailure "deferred scheduled prune was admitted"
        readIORef calls >>= (@?= [])
    , testCase "interactive maintenance review requires a captured data fence" $ do
        let owner = ok (mkScopeId Standalone "maintenance-guard-test")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster"))
              (ok (mkName "cluster"))
            managed = member owner cluster "database"
            resource = declarationId managed
            operation = DeclaredOperation
              (mintResourceId owner (ok (mkLogicalKey "session"))
                (ok (mkName "operation")))
              (resource :| []) [ContentInput (contentDigest "maintenance-intent")]
              OperatorRecovery MaintainData
            scope = ok (mkScopeDeclaration owner
              [ResourceBundle [managed] [] [] [] [operation] []])
            candidate = ok (composeInventory
              (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope scope :| []))
            observations = ok (observationSet
              [(resource, ConfirmedAbsent (contentDigest "absent"))])
            adapter = Adapter
              { adapterExecutor = KubernetesExecutor
              , adapterIdentity = "maintenance-test"
              , adapterVersion = "1"
              , adapterObserve = \_ -> pure (Right observations)
              , adapterPrepare = \_ -> pure (Right
                  (PreparedNative "maintenance-private" "maintenance session"))
              , adapterPreflight = \_ _ -> pure (Right ())
              , adapterExecute = \_ _ -> pure AdapterEffectCompleted
              , adapterVerify = \_ _ -> pure (Right (contentDigest "complete"))
              , adapterRecover = \_ _ -> pure
                  (RecoveryUnresolved "terminal outcome unknown")
              }
            registry = ok (mkAdapterRegistry [adapter])
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "maintenance-fence-required"
          >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let proposal = ok (planChanges candidate noLifecycleDecisions history observations)
        assertBool "maintenance operation was omitted"
          (any ((== OpenMaintenanceSession) . plannedAction)
            (proposalOperations proposal))
        snapshot <- readStoreSnapshot store >>= expectRight
        prepared <- prepareReview registry snapshot proposal
        assertBool "unfenced maintenance review was saved" (isLeft prepared)
    , testCase "published bootstrap review retains its selected payload identity" $ do
        let owner = ok (mkScopeId Platform "bootstrap-foundation")
            scope = ok (mkScopeDeclaration owner [])
            snapshot = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
            registry = ok (mkAdapterRegistry [])
            observations = ok (observationSet [])
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "bootstrap-payload-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history observations)
        before <- readStoreSnapshot store >>= expectRight
        review <- prepareReviewWithPayloadIdentity "nagare-bootstrap:payload-a"
          registry before proposal >>= expectRight
        reviewPayloadIdentity (reviewBundleDocument review) @?= "nagare-bootstrap:payload-a"
        digest <- publishReview store review >>= expectRight
        retained <- loadPublishedReview store digest >>= expectRight
        reviewPayloadIdentity (reviewBundleDocument retained) @?= "nagare-bootstrap:payload-a"
    , testCase "conditional store contract is identical in memory and on disk" $ do
        memory <- newMemoryStore
        exerciseStore memory
        withSystemTempDirectory "inventory-store" $ \root -> do
          filesystem <- openFilesystemStore root >>= expectRight
          exerciseStore filesystem
    , testCase "active head permits retiring a converged scope during handoff" $ do
        store <- newMemoryStore
        initial <- initializeStore store fixtureBinding "handoff-test" >>= expectRight
        let oldOwner = ok (mkScopeId Platform "old")
            newOwner = ok (mkScopeId Platform "new")
            revision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest "scope")
            handoff = initial
              { headAccepted = Map.singleton newOwner revision
              , headConverged = Map.singleton oldOwner revision
              , headActiveTransaction = Just "tx-handoff"
              }
        eitherDecode (encode handoff) @?= Right handoff
        case (eitherDecode (encode (handoff {headActiveTransaction = Nothing})) :: Either String HeadManifest) of
          Left _ -> pure ()
          Right _ -> assertFailure "inactive head accepted a retired converged scope"
    , testCase "adoption decision binds the observed incarnation and context" $ do
        let owner = ok (mkScopeId Platform "adoption")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            resource = member owner cluster "legacy"
            resourceId = declarationId resource
            scope = ok (mkScopeDeclaration owner [ResourceBundle [resource] [] [] [] [] []])
            candidate = ok (composeInventory
              (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope scope :| []))
            fact = ObservedUnowned (ok (mkPhysicalIdentity "legacy-uid"))
            observations = ok (observationSet [(resourceId, fact)])
            decision = LifecycleProposal resourceId ApproveAdoption
              (lifecycleObservationDigest fixtureBinding resourceId fact)
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "adoption-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        decisions <- expectRight (validateLifecycleDecisions candidate history observations [decision])
        let proposal = ok (planChanges candidate decisions history observations)
        map plannedAction (proposalOperations proposal) @?= [AdoptResource]
        let changed = decision {lifecycleEvidence = contentDigest "another-incarnation"}
        case validateLifecycleDecisions candidate history observations [changed] of
          Left failures -> map planErrorCode (NE.toList failures) @?= ["stale-lifecycle-evidence"]
          Right _ -> assertFailure "stale adoption evidence accepted"
        let absent = ok (observationSet [(resourceId, ConfirmedAbsent (contentDigest "absent"))])
        case validateLifecycleDecisions candidate history absent [decision] of
          Left failures -> assertBool "absence is not adoptable"
            ("invalid-adoption" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "absent resource accepted for adoption"
        forM_ [ObservedPresent (ok (mkPhysicalIdentity "legacy-uid")),
               ObservedDrifted (ok (mkPhysicalIdentity "legacy-uid")) (contentDigest "drifted")] $ \stamped -> do
          let stampedFacts = ok (observationSet [(resourceId, stamped)])
              stampedDecision = decision
                { lifecycleEvidence = lifecycleObservationDigest fixtureBinding resourceId stamped }
          case validateLifecycleDecisions candidate history stampedFacts [stampedDecision] of
            Left failures -> assertBool "stamped object without history is not adoptable"
              ("invalid-adoption" `elem` map planErrorCode (NE.toList failures))
            Right _ -> assertFailure "stamped object without history accepted for adoption"
          case planChanges candidate noLifecycleDecisions history stampedFacts of
            Left failures -> assertBool "stamped object has no verified owner"
              ("unverified-owner" `elem` map planErrorCode (NE.toList failures))
            Right _ -> assertFailure "stamped object without history planned for mutation"
    , testCase "reviewed scope retirement retains the exact incarnation and reserves its address" $ do
        observedPhysical <- newIORef (ok (mkPhysicalIdentity "legacy-uid"))
        let owner = ok (mkScopeId Platform "retired")
            otherOwner = ok (mkScopeId Application "competing")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            oldResource = member owner cluster "legacy"
            resourceId = declarationId oldResource
            dependent = case member owner cluster "dependent" of
              Managed value -> Managed (value {dependencies = [OrderedAfter resourceId]})
              declaration -> declaration
            dependentId = declarationId dependent
            oldScope = ok (mkScopeDeclaration owner [ResourceBundle [oldResource, dependent] [] [] [] [] []])
            initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope oldScope :| []))
            physical = ok (mkPhysicalIdentity "legacy-uid")
            registry = ok (mkAdapterRegistry [Adapter
              { adapterExecutor = KubernetesExecutor
              , adapterIdentity = "recording"
              , adapterVersion = "1"
              , adapterObserve = \resources -> do
                  current <- readIORef observedPhysical
                  pure (observationSet
                    [(resource, ObservedPresent current) | resource <- resources])
              , adapterPrepare = \operation -> pure (Right (PreparedNative
                  (ok (canonicalValue (toJSON operation))) "recording adapter"))
              , adapterPreflight = \_ _ -> pure (Right ())
              , adapterExecute = \_ _ -> pure AdapterEffectCompleted
              , adapterVerify = \operation _ -> pure (Right (proof operation))
              , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (proof operation))
              }])
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "retention-test" >>= expectRight
        emptyHistory <- loadInventoryHistory store >>= expectRight
        let absent = ok (observationSet
              [(resourceId, ConfirmedAbsent (contentDigest "absent")),
               (dependentId, ConfirmedAbsent (contentDigest "absent"))])
            initialProposal = ok (planChanges initial noLifecycleDecisions emptyHistory absent)
        before <- readStoreSnapshot store >>= expectRight
        initialReview <- prepareReview registry before initialProposal >>= expectRight
        _ <- publishReview store initialReview >>= expectRight
        initialSnapshot <- readStoreSnapshot store >>= expectRight
        initialReviewed <- expectRight (verifyReview initialSnapshot initialReview)
        _ <- applyReviewed store registry initialReviewed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let accepted = Map.map (\(revision, scope) -> (revisionGeneration revision, scope))
              (historyAccepted history)
            candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty))
              (RetireScope owner RetainResources :| []))
            fact = ObservedPresent physical
            observed = ok (observationSet [(resourceId, fact), (dependentId, fact)])
            decisions = ok (decideRetirement candidate history observed)
            proposal = ok (planChanges candidate decisions history observed)
        proposalOperations proposal @?= []
        retirementSnapshot <- readStoreSnapshot store >>= expectRight
        retirementReview <- prepareReview registry retirementSnapshot proposal >>= expectRight
        _ <- publishReview store retirementReview >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published retirementReview)
        writeIORef observedPhysical (ok (mkPhysicalIdentity "replacement-uid"))
        stale <- applyReviewed store registry reviewed
        case stale of
          Left failures -> assertBool "replacement incarnation refused at admission"
            ("retention-observation" `elem` map admissionErrorCode (NE.toList failures))
          Right _ -> assertFailure "replacement incarnation retired under stale review"
        unchanged <- readHead store >>= expectRight
        fmap headAccepted unchanged @?= Just (headAccepted (storeSnapshotHead published))
        writeIORef observedPhysical physical
        _ <- applyReviewed store registry reviewed >>= expectRight
        retainedHistory <- loadInventoryHistory store >>= expectRight
        Map.null (historyAccepted retainedHistory) @?= True
        case Map.lookup resourceId (historyRetained retainedHistory) of
          Just (incarnation, declaration) -> do
            retainedPhysical incarnation @?= physical
            declaration ^. #identity @?= resourceId
          Nothing -> assertFailure "retired resource was absent from durable history"
        let retainedCategory currentFact =
              [InventoryStatus.retainedObservation finding
              | finding <- InventoryStatus.retainedFindings retainedHistory
                  (ok (observationSet [(resourceId, currentFact)])),
                InventoryStatus.retainedResource finding == resourceId]
        retainedCategory (ObservedPresent physical) @?= ["present"]
        retainedCategory (ObservedReplacementRequired physical (contentDigest "immutable-change"))
          @?= ["replacement-required"]
        retainedCategory (ObservedPresent (ok (mkPhysicalIdentity "replacement-uid"))) @?= ["replaced-incarnation"]
        retainedCategory (ConfirmedAbsent (contentDigest "absent")) @?= ["confirmed-absent"]
        let retainedHealth currentFact =
              [InventoryStatus.retainedHealth finding
              | finding <- InventoryStatus.retainedFindings retainedHistory
                  (ok (observationSet [(resourceId, currentFact)])),
                InventoryStatus.retainedResource finding == resourceId]
        retainedHealth (ObservedPresent physical) @?= [InventoryStatus.HealthUnknown]
        retainedHealth (ConfirmedAbsent (contentDigest "absent")) @?= [InventoryStatus.HealthUnavailable]
        let healthTargets currentFact = InventoryStatus.retainedHealthTargets retainedHistory
              (ok (observationSet [(resourceId, currentFact)]))
        healthTargets (ObservedPresent physical) @?=
          [(resourceId, case oldResource of Managed value -> value ^. #address; _ -> error "expected managed resource", physical)]
        healthTargets (ObservedDrifted physical (contentDigest "changed")) @?=
          healthTargets (ObservedPresent physical)
        healthTargets (ObservedPresent (ok (mkPhysicalIdentity "replacement-uid"))) @?= []
        healthTargets (ConfirmedAbsent (contentDigest "absent")) @?= []
        let retainedSnapshot = ok (mkScopeSnapshot fixtureBinding Map.empty
              (historyReservations retainedHistory))
            emptyInventory = ok (composeSnapshot retainedSnapshot)
        InventoryStatus.consumersOf retainedHistory emptyInventory resourceId @?= [dependentId]
        map InventoryStatus.traceResource
          (InventoryStatus.traceRetainedDependencies retainedHistory emptyInventory dependentId)
          @?= [resourceId]
        let collection = InventoryStatus.assessCollections retainedHistory emptyInventory observed
        case [entry | entry <- collection, InventoryStatus.collectionResource entry == resourceId] of
          [entry] -> do
            InventoryStatus.collectionCandidate entry @?= False
            assertBool "retained dependent is a collection blocker"
              ("dependent-consumers" `elem` InventoryStatus.collectionReasons entry)
            assertBool "GC screening reports the conditional executor boundary"
              ("unsupported-collection-transport" `elem` InventoryStatus.collectionReasons entry)
          _ -> assertFailure "retained resource lacks a collection assessment"
        let competing = member otherOwner cluster "legacy"
            competingScope = ok (mkScopeDeclaration otherOwner
              [ResourceBundle [competing] [] [] [] [] []])
        case composeInventory retainedSnapshot (ReplaceScope competingScope :| []) of
          Left _ -> pure ()
          Right _ -> assertFailure "retained physical address became claimable"
        let reactivation = ok (composeInventory retainedSnapshot (ReplaceScope oldScope :| []))
        case planChanges reactivation noLifecycleDecisions retainedHistory observed of
          Left failures -> assertBool ("retained identity needs explicit recovery: " <> show failures)
            ("retained-reactivation" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "retained identity was silently reactivated"
        let forged = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope competingScope :| []))
            forgedObservation = ok (observationSet
              [(declarationId competing, ConfirmedAbsent (contentDigest "absent"))])
        case planChanges forged noLifecycleDecisions retainedHistory forgedObservation of
          Left failures -> assertBool "candidate omitted authoritative reservations"
            ("reservation-history" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "candidate without retained reservations was planned"
    , testCase "retirement cannot lose controller child claims" $ do
        let owner = ok (mkScopeId Platform "controller")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            parentAddress = Kubernetes cluster "serving.knative.dev" (ok (mkName "service"))
              (Just (ok (mkName "system"))) (ok (mkName "web"))
            childAddress = Kubernetes cluster "" (ok (mkName "service"))
              (Just (ok (mkName "system"))) (ok (mkName "web"))
            parent = case member owner cluster "web" of
              Managed resource -> Managed (resource {address = parentAddress, spec = KnativeService (contentDigest "web")})
              declaration -> declaration
            childId = mintResourceId owner (ok (mkLogicalKey "child")) (ok (mkName "web"))
            child = ObservedChild childId (declarationId parent) childAddress
              (ok (mkPhysicalIdentity "child-uid")) (SourceLocation "test" "child")
            scope = ok (mkScopeDeclaration owner [ResourceBundle [parent, child] [] [] [] [] []])
            bytes = encodeCanonicalScope scope
            revision = ScopeRevision (ok (mkScopeGeneration 1)) (contentDigest bytes)
        store <- newMemoryStore
        initialHead <- initializeStore store fixtureBinding "child-test" >>= expectRight
        _ <- publishIfAbsent store (scopeKey (revisionDigest revision)) bytes >>= expectRight
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration initialHead))
          (initialHead {headGeneration = headGeneration initialHead + 1,
            headAccepted = Map.singleton owner revision,
            headConverged = Map.singleton owner revision}) >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let snapshot = ok (mkScopeSnapshot fixtureBinding (Map.singleton owner (revisionGeneration revision, scope)) Map.empty)
            candidate = ok (composeInventory snapshot (RetireScope owner RetainResources :| []))
            parentFact = ObservedPresent (ok (mkPhysicalIdentity "parent-uid"))
            observed = ok (observationSet [(declarationId parent, parentFact)])
            decision = LifecycleProposal (declarationId parent) ApproveRetirement
              (lifecycleObservationDigest fixtureBinding (declarationId parent) parentFact)
            decisions = ok (validateLifecycleDecisions candidate history observed [decision])
        case planChanges candidate decisions history observed of
          Left failures -> assertBool ("controller child claim would disappear: " <> show failures)
            ("retained-child-history" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "controller child claim was silently discarded"
    , testCase "moving a known resource to another scope cannot become an ordinary update" $ do
        let oldOwner = ok (mkScopeId Platform "transfer-source")
            newOwner = ok (mkScopeId Platform "transfer-destination")
            dummyOwner = ok (mkScopeId Platform "transfer-seed")
            cluster = mintResourceId oldOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            oldDeclaration = member oldOwner cluster "config"
            moved = case oldDeclaration of
              Managed value -> Managed (value {owner = newOwner})
              _ -> error "fixture resource must be managed"
            movedAddress = case moved of
              Managed value -> value ^. #address
              _ -> error "fixture resource must be managed"
            resourceId = declarationId oldDeclaration
            oldScope = ok (mkScopeDeclaration oldOwner [ResourceBundle [oldDeclaration] [] [] [] [] []])
            newScope = ok (mkScopeDeclaration newOwner [ResourceBundle [moved] [] [] [] [] []])
            changed = case moved of
              Managed value -> Managed (value {spec = NativeObject (contentDigest "changed-during-transfer")})
              _ -> error "fixture resource must be managed"
            changedScope = ok (mkScopeDeclaration newOwner [ResourceBundle [changed] [] [] [] [] []])
            renamed = case oldDeclaration of
              Managed value -> Managed (value {address = Kubernetes cluster ""
                (ok (mkName "configmap")) (Just (ok (mkName "default")))
                (ok (mkName "renamed-config"))})
              _ -> error "fixture resource must be managed"
            renamedScope = ok (mkScopeDeclaration oldOwner [ResourceBundle [renamed] [] [] [] [] []])
            movedToHelm = case oldDeclaration of
              Managed value -> Managed (value
                { executor = HelmExecutor
                , address = Helm cluster (ok (mkName "system")) (ok (mkName "config"))
                , spec = HelmRelease (value ^. #address :| []) (contentDigest "chart")
                })
              _ -> error "fixture resource must be managed"
            helmScope = ok (mkScopeDeclaration oldOwner [ResourceBundle [movedToHelm] [] [] [] [] []])
            dummyScope = ok (mkScopeDeclaration dummyOwner [])
            generation = ok (mkScopeGeneration 1)
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.singleton oldOwner (generation, oldScope)) Map.empty)
            seedCandidate = ok (composeInventory snapshot (ReplaceScope dummyScope :| []))
            transfer = ok (composeInventory snapshot
              (RetireScope oldOwner RetainResources :| [ReplaceScope newScope]))
            changedTransfer = ok (composeInventory snapshot
              (RetireScope oldOwner RetainResources :| [ReplaceScope changedScope]))
            rename = ok (composeInventory snapshot (ReplaceScope renamedScope :| []))
            changeExecutor = ok (composeInventory snapshot (ReplaceScope helmScope :| []))
            observations = ok (observationSet
              [(resourceId, ObservedPresent (ok (mkPhysicalIdentity "same-uid")))])
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "transfer-test" >>= expectRight
        _ <- seedInventoryHistory store seedCandidate >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        case (oldDeclaration, renamed) of
          (Managed source, Managed destination) ->
            Map.lookup resourceId (migrationIncarnations (observationRequirements rename history))
              @?= Just (source, destination)
          _ -> assertFailure "migration fixture has no managed declarations"
        let requirements = observationRequirements changeExecutor history
        Map.lookup resourceId (migrationIncarnations requirements)
          @?= case (oldDeclaration, movedToHelm) of
            (Managed source, Managed destination) -> Just (source, destination)
            _ -> Nothing
        Map.lookup KubernetesExecutor (requirementsByExecutor requirements) @?= Nothing
        Map.lookup HelmExecutor (requirementsByExecutor requirements) @?= Just [resourceId]
        Map.lookup KubernetesExecutor (migrationSourcesByExecutor requirements) @?= Just [resourceId]
        Map.lookup HelmExecutor (migrationSourcesByExecutor requirements) @?= Nothing
        migrationFacts <- observeMigrationIncarnations
          (observingRegistry KubernetesExecutor (ObservedPresent (ok (mkPhysicalIdentity "source-uid"))))
          (observingRegistry HelmExecutor (ConfirmedAbsent (contentDigest "destination-absent")))
          requirements >>= expectRight
        Map.lookup resourceId (migrationObservationMap migrationFacts) @?=
          Just (ObservedPresent (ok (mkPhysicalIdentity "source-uid")),
            ConfirmedAbsent (contentDigest "destination-absent"))
        case planChanges transfer noLifecycleDecisions history observations of
          Left errors -> assertBool "implicit scope transfer was accepted"
            ("owner-transfer-required" `elem` map planErrorCode (NE.toList errors))
          Right _ -> assertFailure "implicit scope transfer was accepted"
        let newAddressAbsent = ok (observationSet
              [(resourceId, ConfirmedAbsent (contentDigest "new-address-absent"))])
        case planChanges rename noLifecycleDecisions history newAddressAbsent of
          Left failures -> assertBool "an address rename became a fresh create"
            ("migration-review-required" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "an address rename became a fresh create"
        case planChanges rename noLifecycleDecisions history observations of
          Left failures -> assertBool "an address rename became an ordinary update"
            ("migration-review-required" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "an address rename became an ordinary update"
        case planChanges changeExecutor noLifecycleDecisions history newAddressAbsent of
          Left failures -> assertBool "an executor change skipped migration review"
            ("migration-review-required" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "an executor change became an ordinary create"
        let decision = LifecycleProposal resourceId ApproveTransfer
              (lifecycleObservationDigest fixtureBinding resourceId
                (ObservedPresent (ok (mkPhysicalIdentity "same-uid"))))
        approved <- expectRight (validateLifecycleDecisions transfer history observations [decision])
        map plannedAction (proposalOperations (ok (planChanges transfer approved history observations)))
          @?= [VerifyResource]
        case validateLifecycleDecisions changedTransfer history observations [decision] of
          Left failures -> assertBool "transfer silently changed native content"
            ("invalid-transfer" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "transfer silently changed native content"
        let transferInput = AdoptionInput "compiled" fixtureBinding
              [AdoptionTarget resourceId movedAddress
                (ok (mkPhysicalIdentity "same-uid")) (Just oldOwner)]
        reviewedTransfer <- expectRight (decideAdoption transfer history observations transferInput)
        map plannedAction (proposalOperations
          (ok (planChanges transfer reviewedTransfer history observations))) @?= [VerifyResource]
    , testCase "Helm scope transfer verifies one unchanged stamped release" $ do
        let oldOwner = ok (mkScopeId Platform "helm-transfer-source")
            newOwner = ok (mkScopeId Platform "helm-transfer-destination")
            seedOwner = ok (mkScopeId Platform "helm-transfer-seed")
            cluster = mintResourceId oldOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            resourceId = mintResourceId oldOwner (ok (mkLogicalKey "release")) (ok (mkName "release"))
            contract = contentDigest "reviewed-helm-contract"
            rendered = Kubernetes cluster "" (ok (mkName "configmap"))
              (Just (ok (mkName "default"))) (ok (mkName "rendered-release")) :| []
            old :: ManagedResource
            old = ManagedResource resourceId oldOwner HelmExecutor
              (Helm cluster (ok (mkName "default")) (ok (mkName "release"))) []
              (HelmRelease rendered contract) Retain Stateless Public [] []
              (SourceLocation "fixture" "release")
            oldScope = ok (mkScopeDeclaration oldOwner [ResourceBundle [Managed old] [] [] [] [] []])
            next = ManagedResource resourceId newOwner HelmExecutor
              (Helm cluster (ok (mkName "default")) (ok (mkName "release"))) []
              (HelmRelease rendered contract) Retain Stateless Public [] []
              (SourceLocation "fixture" "release")
            nextScope = ok (mkScopeDeclaration newOwner [ResourceBundle [Managed next] [] [] [] [] []])
            changedScope = ok (mkScopeDeclaration newOwner [ResourceBundle
              [Managed (next {spec = HelmRelease rendered (contentDigest "changed")})] [] [] [] [] []])
            generation = ok (mkScopeGeneration 1)
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.singleton oldOwner (generation, oldScope)) Map.empty)
            seed = ok (composeInventory snapshot (ReplaceScope (ok (mkScopeDeclaration seedOwner [])) :| []))
            transfer = ok (composeInventory snapshot
              (RetireScope oldOwner RetainResources :| [ReplaceScope nextScope]))
            changed = ok (composeInventory snapshot
              (RetireScope oldOwner RetainResources :| [ReplaceScope changedScope]))
            physical = ok (mkPhysicalIdentity "helm-release-secret-uid")
            observed = ok (observationSet [(resourceId, ObservedPresent physical)])
            decision = LifecycleProposal resourceId ApproveTransfer
              (lifecycleObservationDigest fixtureBinding resourceId (ObservedPresent physical))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "helm-transfer-test" >>= expectRight
        _ <- seedInventoryHistory store seed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        case planChanges transfer noLifecycleDecisions history observed of
          Left failures -> assertBool "unreviewed Helm transfer was accepted"
            ("owner-transfer-required" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "unreviewed Helm transfer was accepted"
        approved <- expectRight (validateLifecycleDecisions transfer history observed [decision])
        let transferInput = AdoptionInput "compiled" fixtureBinding
              [AdoptionTarget resourceId (next ^. #address) physical (Just oldOwner)]
        _ <- expectRight (decideAdoption transfer history observed transferInput)
        case decideAdoption transfer history observed
          (transferInput {adoptionTargets = [AdoptionTarget resourceId
            (next ^. #address) (ok (mkPhysicalIdentity "other-release-uid")) (Just oldOwner)]}) of
          Left failures -> assertBool "Helm transfer ignored a changed physical identity"
            ("adoption-incarnation" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "Helm transfer accepted another release incarnation"
        let operations = proposalOperations (ok (planChanges transfer approved history observed))
        map plannedAction operations @?= [VerifyResource]
        case operations of
          [operation] -> do
            state <- newIORef (HelmPresent physical "1" resourceId contract)
            mutations <- newIORef (0 :: Int)
            let adapter = mkHelmAdapter (Map.singleton resourceId (next, "reviewed-helm-contract"))
                  HelmAdapterOps
                    { helmObserve = \_ -> readIORef state
                    , helmMutateConditional = \_ -> do
                        modifyIORef' mutations (+ 1)
                        pure AdapterEffectCompleted
                    }
            prepared <- adapterPrepare adapter operation >>= expectRight
            adapterPreflight adapter operation prepared >>= (@?= Right ())
            adapterExecute adapter operation prepared >>= (@?= AdapterEffectCompleted)
            verified <- adapterVerify adapter operation prepared
            assertBool "Helm handoff did not verify the release" (either (const False) (const True) verified)
            readIORef mutations >>= (@?= 0)
            writeIORef state (HelmPresent physical "2" resourceId contract)
            changedRevision <- adapterPreflight adapter operation prepared
            assertBool "Helm release revision changed after review" (isLeft changedRevision)
          _ -> assertFailure "Helm transfer should plan exactly one verification"
        case validateLifecycleDecisions changed history observed [decision] of
          Left failures -> assertBool "Helm transfer changed its native contract"
            ("invalid-transfer" `elem` map planErrorCode (NE.toList failures))
          Right _ -> assertFailure "changed Helm contract was accepted for transfer"
    , testCase "reviewed Helm retirement retains the stamped release without mutation" $ do
        let owner = ok (mkScopeId Platform "helm-retirement")
            seedOwner = ok (mkScopeId Platform "helm-retirement-seed")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            resourceId = mintResourceId owner (ok (mkLogicalKey "release")) (ok (mkName "release"))
            native = "reviewed-helm-contract"
            address = Helm cluster (ok (mkName "default")) (ok (mkName "release"))
            rendered = Kubernetes cluster "" (ok (mkName "configmap"))
              (Just (ok (mkName "default"))) (ok (mkName "rendered-release")) :| []
            managed = ManagedResource resourceId owner HelmExecutor address []
              (HelmRelease rendered (contentDigest native)) Retain Stateless Public [] []
              (SourceLocation "fixture" "release")
            scope = ok (mkScopeDeclaration owner [ResourceBundle [Managed managed] [] [] [] [] []])
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.singleton owner (ok (mkScopeGeneration 1), scope)) Map.empty)
            seed = ok (composeInventory snapshot
              (ReplaceScope (ok (mkScopeDeclaration seedOwner [])) :| []))
            candidate = ok (composeInventory snapshot (RetireScope owner RetainResources :| []))
            physical = ok (mkPhysicalIdentity "helm-release-secret-uid")
        state <- newIORef (HelmPresent physical "1" resourceId (contentDigest native))
        mutations <- newIORef (0 :: Int)
        let adapter = mkHelmAdapter (Map.singleton resourceId (managed, native))
              HelmAdapterOps
                { helmObserve = \_ -> readIORef state
                , helmMutateConditional = \_ -> do
                    modifyIORef' mutations (+ 1)
                    pure AdapterEffectCompleted
                }
            registry = ok (mkAdapterRegistry [adapter])
            observed = ok (observationSet [(resourceId, ObservedPresent physical)])
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "helm-retirement-test" >>= expectRight
        _ <- seedInventoryHistory store seed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        decisions <- expectRight (decideRetirement candidate history observed)
        let proposal = ok (planChanges candidate decisions history observed)
        proposalOperations proposal @?= []
        before <- readStoreSnapshot store >>= expectRight
        review <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store review >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- expectRight (verifyReview published review)
        writeIORef state (HelmPresent (ok (mkPhysicalIdentity "replacement-uid")) "2"
          resourceId (contentDigest native))
        stale <- applyReviewed store registry reviewed
        case stale of
          Left failures -> assertBool "replaced Helm release passed retirement admission"
            ("retention-observation" `elem` map admissionErrorCode (NE.toList failures))
          Right _ -> assertFailure "replaced Helm release was retained"
        writeIORef state (HelmPresent physical "1" resourceId (contentDigest native))
        _ <- applyReviewed store registry reviewed >>= expectRight
        retained <- loadInventoryHistory store >>= expectRight
        case Map.lookup resourceId (historyRetained retained) of
          Just (incarnation, declaration) -> do
            retainedOwner incarnation @?= owner
            retainedPhysical incarnation @?= physical
            declaration @?= managed
          Nothing -> assertFailure "Helm release was absent from retained history"
        readIORef mutations >>= (@?= 0)
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
            third = ok (mkScopeId Application "third")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            request = RegisterNamespace owner cluster (ok (mkName "shared")) (ok (mkLogicalKey "shared"))
            grant = ResourceBundle [] [] [] [] []
              [NamespaceGrant firstContributor cluster, NamespaceGrant second cluster, NamespaceGrant third cluster]
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
        let competing = ok (composeInventory snapshot (ReplaceScope (contributor third) :| []))
            competingProposal = ok (planChanges competing noLifecycleDecisions history observations)
        proposalOperations competingProposal @?= []
        reviewBase <- readStoreSnapshot store >>= expectRight
        secondBundle <- prepareReview registry reviewBase proposal >>= expectRight
        thirdBundle <- prepareReview registry reviewBase competingProposal >>= expectRight
        _ <- publishReview store secondBundle >>= expectRight
        _ <- publishReview store thirdBundle >>= expectRight
        issued <- readStoreSnapshot store >>= expectRight
        secondReview <- either (assertFailure . show . NE.toList) pure (verifyReview issued secondBundle)
        thirdReview <- either (assertFailure . show . NE.toList) pure (verifyReview issued thirdBundle)
        acceptedSecond <- applyReviewed store registry secondReview >>= expectRight
        case acceptedSecond of Converged _ -> pure (); other -> assertFailure (show other)
        refusedThird <- applyReviewed store registry thirdReview
        case refusedThird of
          Left failures -> assertBool "stale contribution vector was accepted"
            ("stale-head" `elem` map admissionErrorCode (NE.toList failures))
          Right _ -> assertFailure "stale contribution review was accepted"
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
    , testCase "backend map changes only when a contribution changes content" $ do
        let owner = ok (mkScopeId Platform "auth")
            app = ok (mkScopeId Application "backend-app")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            platform = ok (mkScopeDeclaration owner
              [ResourceBundle [] [] [] [] [] [BackendMapGrant cluster]])
            contributor upstream = ok (mkScopeDeclaration app [ResourceBundle [] [] []
              [RegisterBackend owner cluster (ok (mkName "app.example.test")) upstream
                ProtectedBackend (ok (mkLogicalKey "route"))] [] []])
            registry = recordingRegistry (\_ _ -> pure AdapterEffectCompleted)
              (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
            absent = ConfirmedAbsent (contentDigest "absent")
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "backend-map-test" >>= expectRight
        initialHistory <- loadInventoryHistory store >>= expectRight
        let initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope platform :| [ReplaceScope (contributor "http://first.example.test")]))
            initialRequired = requiredResources (observationRequirements initial initialHistory)
            initialProposal = ok (planChanges initial noLifecycleDecisions initialHistory
              (ok (observationSet [(resource, absent) | resource <- Set.toAscList initialRequired])))
        length (proposalOperations initialProposal) @?= 1
        snapshot <- readStoreSnapshot store >>= expectRight
        review <- prepareReview registry snapshot initialProposal >>= expectRight
        _ <- publishReview store review >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        admitted <- expectRight (verifyReview published review)
        _ <- applyReviewed store registry admitted >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let accepted = Map.map (\(revision, value) -> (revisionGeneration revision, value))
              (historyAccepted history)
            replay upstream = ok (composeInventory
              (ok (mkScopeSnapshot fixtureBinding accepted Map.empty))
              (ReplaceScope (contributor upstream) :| []))
            observed candidate = ok (observationSet
              [(resource, ObservedPresent (ok (mkPhysicalIdentity (resourceIdText resource))))
              | resource <- Set.toAscList (requiredResources (observationRequirements candidate history))])
            unchanged = replay "http://first.example.test"
            changed = replay "https://second.example.test"
        proposalOperations (ok (planChanges unchanged noLifecycleDecisions history (observed unchanged))) @?= []
        case proposalOperations (ok (planChanges changed noLifecycleDecisions history (observed changed))) of
          [operation] -> plannedAction operation @?= UpdateResource
          other -> assertFailure ("backend content change did not update the owner map: " <> show other)
    , testCase "application update observes only its changed scope" $ do
        let platformOwner = ok (mkScopeId Platform "unrelated-cloud")
            appOwner = ok (mkScopeId Application "selected-app")
            otherOwner = ok (mkScopeId Application "other-app")
            seedOwner = ok (mkScopeId Platform "seed")
            cluster = mintResourceId platformOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            cloud = case member platformOwner cluster "cloud" of
              Managed resource -> Managed (resource
                { executor = PulumiExecutor
                , address = GlobalBucket (ok (mkName "unrelated-bucket"))
                })
              _ -> error "cloud fixture is not managed"
            appResource = member appOwner cluster "selected"
            otherResource = member otherOwner cluster "other"
            changedApp = case appResource of
              Managed resource -> Managed (resource {spec = NativeObject (contentDigest "changed")})
              _ -> error "app fixture is not managed"
            oldAppScope = ok (mkScopeDeclaration appOwner
              [ResourceBundle [appResource] [] [] [] [] []])
            newAppScope = ok (mkScopeDeclaration appOwner
              [ResourceBundle [changedApp] [] [] [] [] []])
            platformScope = ok (mkScopeDeclaration platformOwner
              [ResourceBundle [cloud] [] [] [] [] []])
            unrelatedOperation = DeclaredOperation
              { identity = mintResourceId otherOwner (ok (mkLogicalKey "other-op")) (ok (mkName "operation"))
              , affects = declarationId otherResource :| []
              , inputs = []
              , recovery = Idempotent
              , operationKind = PublishRelease
              }
            otherScope = ok (mkScopeDeclaration otherOwner
              [ResourceBundle [otherResource] [] [] [] [unrelatedOperation] []])
            original = ok (mkScopeSnapshot fixtureBinding (Map.fromList
              [(platformOwner, (ok (mkScopeGeneration 1), platformScope))
              , (appOwner, (ok (mkScopeGeneration 1), oldAppScope))
              , (otherOwner, (ok (mkScopeGeneration 1), otherScope))]) Map.empty)
            seed = ok (composeInventory original
              (ReplaceScope (ok (mkScopeDeclaration seedOwner [])) :| []))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "scope-isolation-test" >>= expectRight
        _ <- seedInventoryHistory store seed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let candidate = ok (composeInventory original (ReplaceScope newAppScope :| []))
            selectedId = declarationId appResource
            required = requiredResources (observationRequirements candidate history)
        required @?= Set.singleton selectedId
        let observations = ok (observationSet
              [(selectedId, ObservedPresent (ok (mkPhysicalIdentity "selected-uid")))])
            operations = proposalOperations
              (ok (planChanges candidate noLifecycleDecisions history observations))
        case operations of
          [operation] -> do
            plannedAction operation @?= UpdateResource
            NE.toList (plannedResources operation) @?= [selectedId]
          other -> assertFailure ("unrelated scopes joined application update: " <> show other)
        effects <- newIORef ([] :: [ResourceId])
        let registry = ok (mkAdapterRegistry [Adapter
              { adapterExecutor = KubernetesExecutor
              , adapterIdentity = "selected-cluster-only"
              , adapterVersion = "1"
              , adapterObserve = \resources -> pure (observationSet
                  [(resource, ObservedPresent (ok (mkPhysicalIdentity "selected-uid")))
                  | resource <- resources])
              , adapterPrepare = \operation -> pure (Right (PreparedNative
                  (ok (canonicalValue (toJSON operation))) "selected application update"))
              , adapterPreflight = \_ _ -> pure (Right ())
              , adapterExecute = \operation _ -> do
                  modifyIORef' effects (<> NE.toList (plannedResources operation))
                  pure AdapterEffectCompleted
              , adapterVerify = \operation _ -> pure (Right (proof operation))
              , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (proof operation))
              }])
        observed <- observeWithRegistry registry (requirementsByExecutor
          (observationRequirements candidate history)) >>= expectRight
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history observed)
        before <- readStoreSnapshot store >>= expectRight
        review <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store review >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        verified <- expectRight (verifyReview published review)
        _ <- applyReviewed store registry verified >>= expectRight
        readIORef effects >>= (@?= [selectedId])
        after <- loadInventoryHistory store >>= expectRight
        forM_ [platformOwner, otherOwner] $ \owner ->
          Map.lookup owner (historyAccepted after) @?= Map.lookup owner (historyAccepted history)
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
    , testCase "new workload verifies its accepted broker topic before creation" $ do
        let brokerOwner = ok (mkScopeId Standalone "broker-events")
            consumerOwner = ok (mkScopeId Application "topic-consumer")
            seedOwner = ok (mkScopeId Platform "topic-seed")
            cluster = mintResourceId brokerOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            stateful = case member brokerOwner cluster "events" of
              Managed resource -> Managed (resource
                { address = Kubernetes cluster "apps" (ok (mkName "statefulset"))
                    (Just (ok (mkName "personal"))) (ok (mkName "events"))
                , spec = StatefulSet 1 [] (contentDigest "broker-stateful")
                })
              _ -> error "broker fixture is not managed"
            statefulId = declarationId stateful
            recovery = RecoveryIntent (ok (mkName "restore"))
              (mkSecretRef (ok (mkName "credential")) (ok (mkName "v1")) :| [])
            topic = case member brokerOwner cluster "jobs" of
              Managed resource -> Managed (resource
                { executor = BrokerExecutor
                , address = BrokerTopic statefulId (ok (mkName "jobs"))
                , spec = LogicalBrokerTopic 1 1 Nothing
                , dataPolicy = Durable recovery
                , dependencies = [OrderedAfter statefulId]
                })
              _ -> error "topic fixture is not managed"
            topicId = declarationId topic
            consumer = case member consumerOwner cluster "worker" of
              Managed resource -> Managed (resource {dependencies = [OrderedAfter topicId]})
              _ -> error "consumer fixture is not managed"
            brokerScope = ok (mkScopeDeclaration brokerOwner
              [ResourceBundle [stateful, topic] [] [] [] [] []])
            consumerScope = ok (mkScopeDeclaration consumerOwner
              [ResourceBundle [consumer] [] [] [] [] []])
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.singleton brokerOwner (ok (mkScopeGeneration 1), brokerScope)) Map.empty)
            seed = ok (composeInventory snapshot
              (ReplaceScope (ok (mkScopeDeclaration seedOwner [])) :| []))
            candidate = ok (composeInventory snapshot (ReplaceScope consumerScope :| []))
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "topic-dependency-test" >>= expectRight
        _ <- seedInventoryHistory store seed >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let required = requiredResources (observationRequirements candidate history)
            observed resource
              | resource == declarationId consumer = ConfirmedAbsent (contentDigest "absent")
              | otherwise = ObservedPresent (ok (mkPhysicalIdentity (resourceIdText resource)))
            observations = ok (observationSet
              [(resource, observed resource) | resource <- Set.toAscList required])
            operations = proposalOperations
              (ok (planChanges candidate noLifecycleDecisions history observations))
            verifications = [operation | operation <- operations
              , plannedAction operation == VerifyResource
              , topicId `elem` NE.toList (plannedResources operation)]
            creations = [operation | operation <- operations
              , plannedAction operation == CreateResource
              , declarationId consumer `elem` NE.toList (plannedResources operation)]
        case (verifications, creations) of
          ([verification], [creation]) -> do
            plannedExecutor verification @?= BrokerExecutor
            assertBool "workload does not wait for topic verification"
              (plannedOperationId verification `elem` plannedDependencies creation)
          other -> assertFailure ("expected topic verification and workload creation, got " <> show other)
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
    , testCase "pre-deploy hook Job waits for affected data and gates its workload" $ do
        let owner = ok (mkScopeId Application "hook-order")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            database = member owner cluster "database"
            databaseId = declarationId database
            job = case member owner cluster "migration" of
              Managed resource -> Managed (resource
                { address = Kubernetes cluster "batch" (ok (mkName "job"))
                    (Just (ok (mkName "system"))) (ok (mkName "migration"))
                , dependencies = [OrderedAfter databaseId] })
              _ -> error "hook fixture is not managed"
            jobId = declarationId job
            proofId = mintResourceId owner (ok (mkLogicalKey "migration"))
              (ok (mkName "hook-proof"))
            proof = DeclaredOperation proofId (jobId :| [databaseId])
              [ContentInput (contentDigest "job")] VerifyBeforeRetry PreDeployHook
            workload = case member owner cluster "workload" of
              Managed resource -> Managed (resource {dependencies = [OrderedAfter proofId]})
              _ -> error "workload fixture is not managed"
            scope = ok (mkScopeDeclaration owner
              [ResourceBundle [database, job, workload] [] [] [] [proof] []])
            binding = ContextBinding (ok (mkContextId "hook-order")) (ok (mkName "project"))
            candidate = ok (composeInventory
              (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope scope :| []))
        store <- newMemoryStore
        _ <- initializeStore store binding "hook-order-test" >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let requirements = observationRequirements candidate history
            observations = ok (observationSet
              [(resource, ConfirmedAbsent (contentDigest "absent"))
              | resource <- Set.toAscList (requiredResources requirements)])
            allOperations = proposalOperations
              (ok (planChanges candidate noLifecycleDecisions history observations))
            operationFor resource action =
              [operation | operation <- allOperations
              , plannedAction operation == action
              , resource `elem` NE.toList (plannedResources operation)]
        case (operationFor databaseId CreateResource, operationFor jobId CreateResource,
            operationFor jobId RunDeclaredOperation,
            operationFor (declarationId workload) CreateResource) of
          ([databaseCreate], [jobCreate], [hookProof], [workloadCreate]) -> do
            assertBool "Job starts before its database"
              (plannedOperationId databaseCreate `elem` plannedDependencies jobCreate)
            assertBool "proof does not wait for Job completion"
              (plannedOperationId jobCreate `elem` plannedDependencies hookProof)
            assertBool "workload starts before hook proof"
              (plannedOperationId hookProof `elem` plannedDependencies workloadCreate)
          other -> assertFailure ("unexpected hook operation graph: " <> show other)
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
    , testCase "bounded registry recovery journals intent and requires actual workload readiness" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        prerequisite <- newIORef False
        ready <- newIORef False
        loseAcknowledgement <- newIORef True
        let executeOnce _ _ = pure (AdapterEffectAmbiguous "image pull pending")
            recover operation _ = do
              complete <- readIORef ready
              pure (if complete then RecoveryProvedComplete (proof operation)
                else RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "deployment-uid")))
            native = "saved bounded host recovery"
            receipt = contentDigest "unit recovery receipt"
            capability = AdapterRecovery "bootstrap-registry-credentials"
              (\_ _ -> pure (Right native))
              (\_ _ bytes -> pure (if bytes == native then Right () else Left "foreign proof"))
              (\_ _ _ -> do
                headValue <- readHead store >>= expectRight >>= maybe
                  (assertFailure "head missing") pure
                assertBool "effect lacks a durable executor claim" (isJust (headExecutorClaim headValue))
                events <- readJournalPrefix store (headSequence headValue) >>= expectRight
                event <- either (assertFailure . T.unpack) pure (decodeJournalEvent (last events))
                eventState event @?= OperatorResolved
                  ("bootstrap-registry-intent:" <> digestText (contentDigest native))
                landed <- readIORef prerequisite
                unless landed (modifyIORef' effects (+ 1) >> writeIORef prerequisite True)
                lost <- atomicModifyIORef' loseAcknowledgement (\old -> (False, old))
                pure (if lost then Left "lost acknowledgement" else Right receipt))
        (reviewed, original) <- preparedFixtureWith store executeOnce recover
        registry <- either (assertFailure . T.unpack) pure (withAdapterRecovery original capability)
        (transaction, operation) <- applyReviewed store registry reviewed >>= expectRight >>= \case
          StoppedAmbiguous tx selected -> pure (tx, selected)
          other -> assertFailure (show other) >> undefined
        input <- prepareBootstrapRegistryRecovery store registry transaction operation
          >>= either (assertFailure . T.unpack) pure
        let originalDigest = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
        recoveryReview input @?= originalDigest
        firstAttempt <- recordOperatorRecovery store registry input False
        assertBool "lost acknowledgement unexpectedly proved completion" (isLeft firstAttempt)
        before <- readHead store >>= expectRight
        assertBool "claim was not released" (isNothing (before >>= headExecutorClaim))
        blocked <- resumeTransaction store registry transaction >>= expectRight
        case blocked of
          StoppedFailed tx selected (PartialOrUnknown _) ->
            (tx, selected) @?= (transaction, operation)
          other -> assertFailure ("unresolved registry intent was not blocked: " <> show other)
        -- Another capsule cannot overwrite the unresolved intent.
        _ <- publishIfAbsent store (objectKeyFor "native" (contentDigest "foreign")) "foreign" >>= expectRight
        changedProof <- recordOperatorRecovery store registry
          (input {recoveryAction = RecoverBootstrapRegistry (contentDigest "foreign")}) False
        assertBool "a different capsule replaced unresolved intent" (isLeft changedProof)
        -- A ready Deployment alone cannot clear possibly pending host effects.
        writeIORef ready True
        ordinaryProof <- recordOperatorRecovery store registry
          (input {recoveryAction = AcceptAdapterProof}) False
        assertBool "ordinary workload proof bypassed the unsettled host intent" (isLeft ordinaryProof)
        recordOperatorRecovery store registry input False >>= expectRight
        readIORef effects >>= (@?= 1)
        -- The explicit same-proof route settles host intent even after readiness.
        current <- readHead store >>= expectRight >>= maybe (assertFailure "head missing") pure
        events <- readJournalPrefix store (headSequence current) >>= expectRight
          >>= either (assertFailure . T.unpack) pure . traverse decodeJournalEvent
        Map.lookup operation (operationStates transaction events) @?= Just
          (OperatorResolved ("bootstrap-registry-proved:" <> digestText (contentDigest native)
            <> ":" <> digestText receipt))
        writeIORef ready True
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        readIORef effects >>= (@?= 1)
    , testCase "registry recovery binds completed host history and original private Deployment" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        hostDrift <- newIORef False
        deploymentDrift <- newIORef False
        lostUnitReceipt <- newIORef True
        unitState <- newIORef (RegistryUnitSnapshot 10 "original" "node" False True "boot" False)
        (bundle, reviewed, registry) <- preparedRegistryFixture store
        let physical = ok (mkPhysicalIdentity "deployment-uid")
            recover operation _ = do
              changed <- readIORef deploymentDrift
              current <- readIORef unitState
              pure (if registryDeploymentReady current && not changed
                then RecoveryProvedComplete (proof operation)
                else RecoveryAwaitingReadiness
                  (if changed then ok (mkPhysicalIdentity "replacement-uid") else physical))
            inspect plan = do
              changed <- readIORef hostDrift
              pure (HostCommitted (hostPlanInstance plan)
                (if changed then "changed-closure" else hostPlanNewClosure plan)
                (contentDigest "fresh-login"))
            units _ uid saved = do
              uid @?= physical
              case saved of
                Nothing -> Right <$> readIORef unitState
                Just original -> do
                  current <- readIORef unitState
                  case registryReplayRequired original current of
                    Left reason -> pure (Left reason)
                    Right (False, False) -> pure (Right current)
                    Right _ -> do
                      modifyIORef' effects (+ 1)
                      let completed = original {registryUnitStart = 20,
                            registryK3sInvocation = "restarted", registryTokenFresh = True}
                      writeIORef unitState completed
                      lost <- atomicModifyIORef' lostUnitReceipt (\old -> (False, old))
                      pure (if lost then Left "lost unit receipt" else Right completed)
            capability = mkBootstrapRegistryRecovery store bundle "registry.example.test"
              inspect units recover
        liveRegistry <- either (assertFailure . T.unpack) pure (mkAdapterRegistry
          [ok (lookupAdapter registry HostExecutor),
           (ok (lookupAdapter registry KubernetesExecutor)) {adapterRecover = recover}])
        withRecovery <- either (assertFailure . T.unpack) pure (withAdapterRecovery liveRegistry capability)
        (transaction, operation) <- applyReviewed store withRecovery reviewed >>= expectRight >>= \case
          StoppedAmbiguous tx selected -> pure (tx, selected)
          other -> assertFailure (show other) >> undefined
        input <- prepareBootstrapRegistryRecovery store withRecovery transaction operation
          >>= either (assertFailure . T.unpack) pure
        writeIORef hostDrift True
        recordOperatorRecovery store withRecovery input False >>= \value ->
          assertBool "changed committed host authorized registry effects" (isLeft value)
        readIORef effects >>= (@?= 0)
        writeIORef hostDrift False
        writeIORef deploymentDrift True
        recordOperatorRecovery store withRecovery input False >>= \value ->
          assertBool "replacement Deployment authorized registry effects" (isLeft value)
        writeIORef deploymentDrift False
        original <- readIORef unitState
        writeIORef unitState (original {registryNodeUid = "replacement-node"})
        recordOperatorRecovery store withRecovery input False >>= \value ->
          assertBool "replacement node authorized registry effects" (isLeft value)
        readIORef effects >>= (@?= 0)
        writeIORef unitState original
        firstEffect <- recordOperatorRecovery store withRecovery input False
        assertBool "lost unit receipt unexpectedly cleared intent" (isLeft firstEffect)
        readIORef effects >>= (@?= 1)
        -- Even after reboot/readiness, the exact saved capsule can settle the
        -- now-unnecessary prerequisite without repeating either host phase.
        modifyIORef' unitState (\current -> current {registryDeploymentReady = True,
          registryTokenFresh = False, registryPullFailure = False, registryBootId = "new-boot"})
        recordOperatorRecovery store withRecovery input False >>= expectRight
        readIORef effects >>= (@?= 1)
        resumeTransaction store withRecovery transaction >>= expectRight >>= (@?= Converged transaction)
    , testCase "registry unit recovery preserves landed phases across expiry and settles ready workloads" $ do
        let saved = RegistryUnitSnapshot 10 "original" "node" False True "boot" False
        registryReplayRequired saved saved @?= Right (True, True)
        let refreshed = saved {registryUnitStart = 20, registryTokenFresh = True}
        registryReplayRequired saved refreshed @?= Right (False, True)
        let completed = refreshed {registryK3sInvocation = "new"}
        registryReplayRequired saved completed @?= Right (False, False)
        registryReplayRequired saved (completed {registryTokenFresh = False}) @?= Right (False, False)
        registryReplayRequired saved (refreshed {registryTokenFresh = False}) @?= Right (True, True)
        registryReplayRequired saved (saved {registryDeploymentReady = True, registryBootId = "new-boot"})
          @?= Right (False, False)
        forM_ [ saved {registryNodeUid = "other"}
          , saved {registryBootId = "other"}
          , saved {registryK3sInvocation = "new"}
          , saved {registryDeploymentReady = True, registryNodeUid = "replacement"}
          , saved {registryUnitStart = 0} ] $ \current ->
            assertBool "unproved phase combination authorized a unit action"
              (isLeft (registryReplayRequired saved current))
    , testCase "registry host inspection accepts empty systemd Job and refuses pending or failed lookup" $
        withSystemTempDirectory "registry-transport" $ \root -> do
          jq <- findExecutable "jq" >>= maybe (assertFailure "jq missing" >> pure "") pure
          let helper = root </> "ssh-fixture.sh"
              prefix = root </> "host-fixture.sh"
              plan = HostActivationPlan 1 (ok (mkOperationId "op-transport-test"))
                (contentDigest "host") (fixtureBinding ^. #identity) (ok (mkName "host"))
                (ok (mkPhysicalIdentity "gce://projects/project/zones/zone/instances/123"))
                "deploy@host" (contentDigest "config") (contentDigest "lock") Nothing Nothing False
                "/nix/store/old-test-closure" "/nix/store/accepted-test-closure" "activation"
              inspect job = runRegistryUnitTransport helper
                [("NAGARE_TEST_PREFIX", prefix), ("NAGARE_TEST_JQ", jq),
                 ("NAGARE_TEST_JOB", job)] "host" "registry.example.test" plan
                (ok (mkPhysicalIdentity "deployment-uid")) Nothing
          writeFile helper (unlines
            [ "set -euo pipefail"
            , "test \"$1\" = ssh && test \"$2\" = host && test \"$3\" = --"
            , "arguments=\"${4#sudo /run/current-system/sw/bin/bash -s -- }\""
            , "{ /bin/cat \"$NAGARE_TEST_PREFIX\"; /bin/cat; } | eval \"/bin/bash -s -- $arguments\""
            ])
          writeFile prefix registryHostFixture
          result <- inspect "" >>= either (assertFailure . T.unpack) pure
          result @?= RegistryUnitSnapshot 10 "original" "node" False True "boot" False
          forM_ ["47", "lookup-failure"] $ \job -> do
            refused <- inspect job
            assertBool "pending or failed Job lookup admitted host recovery" (isLeft refused)
    , testCase "registry intent and receipt markers accept only exact digests" $ do
        let native = contentDigest "native"
            receipt = contentDigest "receipt"
        bootstrapRecoveryMarker ("bootstrap-registry-intent:" <> digestText native)
          @?= Just (native, Nothing)
        bootstrapRecoveryMarker ("bootstrap-registry-proved:" <> digestText native
          <> ":" <> digestText receipt) @?= Just (native, Just receipt)
        forM_ ["bootstrap-registry-proved:any:any", "bootstrap-registry-intent:",
          "bootstrap-registry-proved:" <> digestText native <> ":" <> digestText receipt <> ":extra"] $ \marker ->
            bootstrapRecoveryMarker marker @?= Nothing
    , testCase "operator recovery records only the adapter-proved action" $ do
        store <- newMemoryStore
        calls <- newIORef (0 :: Int)
        let executeOnce _ _ = modifyIORef' calls (+ 1) >> pure (AdapterEffectAmbiguous "lost acknowledgement")
            recover operation _ = pure (RecoveryProvedComplete (proof operation))
        (reviewed, registry) <- preparedFixtureWith store executeOnce recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        let operation = plannedOperationId (reviewPlannedOperation (head (reviewOperations (reviewedDocument reviewed))))
            digest = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
            input action = OperatorRecoveryInput transaction operation digest action
        refused <- recordOperatorRecovery store registry (input RetryAfterAdapterProof) False
        assertBool "safe retry cannot be inferred from a completion proof" (isLeft refused)
        recordOperatorRecovery store registry (input AcceptAdapterProof) False >>= expectRight
        replayed <- recordOperatorRecovery store registry (input AcceptAdapterProof) False
        assertBool "recorded proof cannot be replayed" (isLeft replayed)
        resumed <- resumeTransaction store registry transaction >>= expectRight
        resumed @?= Converged transaction
        readIORef calls >>= (@?= 1)
    , testCase "operator recovery refuses unresolved effects and retries only after adapter proof" $ do
        store <- newMemoryStore
        attempts <- newIORef (0 :: Int)
        safe <- newIORef False
        let executeOnce _ _ = do
              count <- atomicModifyIORef' attempts (\value -> (value + 1, value))
              pure (if count == 0 then AdapterEffectAmbiguous "lost acknowledgement" else AdapterEffectCompleted)
            recover _ _ = do
              proved <- readIORef safe
              pure (if proved then RecoverySafeToRetry else RecoveryUnresolved "provider state is uncertain")
        (reviewed, registry) <- preparedFixtureWith store executeOnce recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        let operation = plannedOperationId (reviewPlannedOperation (head (reviewOperations (reviewedDocument reviewed))))
            digest = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
            input = OperatorRecoveryInput transaction operation digest RetryAfterAdapterProof
        refused <- recordOperatorRecovery store registry input False
        assertBool "unresolved provider state became retry authority" (isLeft refused)
        readIORef attempts >>= (@?= 1)
        writeIORef safe True
        recordOperatorRecovery store registry input False >>= expectRight
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        readIORef attempts >>= (@?= 2)
    , testCase "stopping incomplete application retains admitted ownership without convergence or effects" $ do
        store <- newMemoryStore
        effects <- newIORef (0 :: Int)
        let effect _ _ = modifyIORef' effects (+ 1) >> pure (AdapterEffectAmbiguous "capacity exhausted")
            recover _ _ = pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-service-uid")))
        (reviewed, registry) <- preparedApplicationStopFixture store Application Stateless effect recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        (transaction, selected) <- case stopped of
          StoppedAmbiguous tx op -> pure (tx, op)
          other -> assertFailure (show other) >> undefined
        before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        let decision = OperatorRecoveryInput transaction selected (reviewDigestFor reviewed) StopIncompleteApplication
        recordOperatorRecovery store registry decision False >>= expectRight
        after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        headAccepted after @?= headAccepted before
        headConverged after @?= headConverged before
        headActiveTransaction after @?= Nothing
        headExecutorClaim after @?= Nothing
        readIORef effects >>= (@?= 1)
        events <- readJournalPrefix store (headSequence after) >>= expectRight
        let decoded = map (ok . decodeJournalEvent) events
        assertBool "stop claimed workload completion" (not (any (\event -> eventOperation event == Just selected && case eventState event of Completed _ -> True; _ -> False) decoded))
        assertBool "stop selection missing" (any (\event -> case eventState event of
          OperatorResolved marker -> "stopped-incomplete-application:" `T.isPrefixOf` marker
          _ -> False) decoded)
        -- Recreate the boundary after the immutable stop event but before its
        -- head CAS. Settlement must use this same decision without provider IO.
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration after))
          after {headGeneration = headGeneration after + 1,
            headActiveTransaction = Just (transactionIdText transaction)} >>= expectRight
        let noProbe = recordingRegistry effect (\_ _ -> assertFailure "saved stop probed provider" >> undefined)
        bypass <- recordOperatorRecovery store noProbe
          decision {recoveryAction = AcceptAdapterProof} False
        assertBool "ordinary proof bypassed stop intent" (isLeft bypass)
        recordOperatorRecovery store noProbe decision False >>= expectRight
        settled <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        headAccepted settled @?= headAccepted before
        headConverged settled @?= headConverged before
        headActiveTransaction settled @?= Nothing
        headSequence settled @?= headSequence after
        resumed <- resumeTransaction store registry transaction
        assertBool "stopped original transaction resumed" (case resumed of Right (Converged _) -> False; _ -> True)
        readIORef effects >>= (@?= 1)
    , testCase "incomplete application stop refuses foreign scope, durable workload and uncertain provider" $ do
        let durable = Durable (RecoveryIntent (ok (mkName "backup"))
              (mkSecretRef (ok (mkName "password")) (ok (mkName "v1")) :| []))
        forM_ [(Platform, Stateless, RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "uid"))),
          (Application, durable, RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "uid"))),
          (Application, Stateless, RecoveryUnresolved "changed UID or digest"),
          (Application, Stateless, RecoverySafeToRetry),
          (Application, Stateless, RecoveryTerminalFailure (ok (mkPhysicalIdentity "failed-job")))] $ \(kind, policy, recovery) -> do
            store <- newMemoryStore
            effects <- newIORef (0 :: Int)
            (reviewed, registry) <- preparedApplicationStopFixture store kind policy
              (\_ _ -> modifyIORef' effects (+ 1) >> pure (AdapterEffectAmbiguous "pending"))
              (\_ _ -> pure recovery)
            stopped <- applyReviewed store registry reviewed >>= expectRight
            (tx, op) <- case stopped of StoppedAmbiguous tx op -> pure (tx, op); other -> assertFailure (show other) >> undefined
            refused <- recordOperatorRecovery store registry (OperatorRecoveryInput tx op (reviewDigestFor reviewed) StopIncompleteApplication) False
            assertBool "unsafe stop accepted" (isLeft refused)
            after <- readHead store >>= expectRight >>= maybe (assertFailure "missing head" >> undefined) pure
            headActiveTransaction after @?= Just (transactionIdText tx)
            readIORef effects >>= (@?= 1)
    , testCase "corrected stopped application creates only its never-started durable member" $ do
        store <- newMemoryStore
        (reviewed, registry) <- preparedApplicationStopFixture store Application Stateless
          (\_ _ -> pure (AdapterEffectAmbiguous "capacity exhausted"))
          (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-service-uid"))))
        (tx, selected) <- applyReviewed store registry reviewed >>= expectRight >>= \case
          StoppedAmbiguous tx op -> pure (tx, op)
          other -> assertFailure (show other) >> undefined
        recordOperatorRecovery store registry
          (OperatorRecoveryInput tx selected (reviewDigestFor reviewed) StopIncompleteApplication) False >>= expectRight
        baseHistory <- loadInventoryHistory store >>= expectRight
        let accepted = historyAccepted baseHistory
            [(owner, (_, scope))] = Map.toList accepted
            uncreated = [mintResourceId owner (ok (mkLogicalKey "uncreated")) (ok (mkName "resource"))]
            retained = [mintResourceId owner (ok (mkLogicalKey "untouched")) (ok (mkName "resource"))]
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) accepted) Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
            observations missing = ok (observationSet
              [(resource, if resource `elem` missing then ConfirmedAbsent (contentDigest "absent")
                else ObservedPresent (ok (mkPhysicalIdentity "original-uid")))
              | resource <- Set.toList (requiredResources (observationRequirements candidate baseHistory))])
        history <- loadInventoryPlanningHistory store candidate >>= expectRight
        length uncreated @?= 1
        length retained @?= 1
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history (observations uncreated))
        [(plannedAction operation, NE.toList (plannedResources operation))
          | operation <- proposalOperations proposal, plannedAction operation == CreateResource]
          @?= [(CreateResource, uncreated)]
        let [waitingResources] = [NE.toList (plannedResources (reviewPlannedOperation entry))
              | entry <- reviewOperations (reviewedDocument reviewed),
                plannedOperationId (reviewPlannedOperation entry) == selected]
        assertBool "unchanged stopped workload lacks fresh readiness proof"
          (any (\operation -> plannedAction operation == VerifyResource
            && NE.toList (plannedResources operation) == waitingResources) (proposalOperations proposal))
        case planChanges candidate noLifecycleDecisions history (observations (uncreated <> retained)) of
          Left errors -> [planErrorResources err | err <- NE.toList errors,
            planErrorCode err == "durable-resource-missing"] @?= [retained]
          Right _ -> assertFailure "completed retained data was authorized for recreation"
        let foreignObservation = ok (observationSet [(resource,
              if resource `elem` uncreated then ObservedUnowned (ok (mkPhysicalIdentity "foreign-key"))
                else ObservedPresent (ok (mkPhysicalIdentity "original-uid")))
              | resource <- Set.toList (requiredResources (observationRequirements candidate baseHistory))])
        assertBool "unstarted proof authorized foreign adoption"
          (isLeft (planChanges candidate noLifecycleDecisions history foreignObservation))
        let changeKey (Managed managed) | managed ^. #identity `elem` uncreated =
              Managed (managed {spec = NativeObject (contentDigest "different-backup-key")})
            changeKey declaration = declaration
            changedScope = ok (mkScopeDeclaration owner
              [bundle {declarations = map changeKey (declarations bundle)} | bundle <- scopeBundles scope])
            changedCandidate = ok (composeInventory snapshot (ReplaceScope changedScope :| []))
        assertBool "unstarted proof authorized a changed durable declaration"
          (isLeft (planChanges changedCandidate noLifecycleDecisions history (observations uncreated)))
        -- A later committed intent makes effect state uncertain. Absence must
        -- not authorize repeating that durable create, even after this stop.
        stoppedHead <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        journal <- readJournalPrefix store (headSequence stoppedHead) >>= expectRight
        let previous = journalEventDigest (ok (decodeJournalEvent (last journal)))
            [unstartedOperation] = [reviewPlannedOperation entry | entry <- reviewOperations (reviewedDocument reviewed),
              NE.toList (plannedResources (reviewPlannedOperation entry)) == uncreated]
            intent = JournalEvent 1 (headSequence stoppedHead) (Just previous) tx
              (Just (plannedOperationId unstartedOperation)) IntentRecorded "test" "uncertain late effect"
        _ <- appendAtSequence store (headSequence stoppedHead) (encodeJournalEvent intent) >>= expectRight
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration stoppedHead))
          stoppedHead {headGeneration = headGeneration stoppedHead + 1,
            headSequence = headSequence stoppedHead + 1} >>= expectRight
        uncertainHistory <- loadInventoryPlanningHistory store candidate >>= expectRight
        assertBool "durable intent was treated as never-started"
          (isLeft (planChanges candidate noLifecycleDecisions uncertainHistory (observations uncreated)))
        -- The proof must not survive a new accepted revision, even if its
        -- declaration bytes are the same. It also grants no foreign adoption.
        headValue <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        let oldRevision = headAccepted headValue Map.! owner
            replacement = oldRevision {revisionGeneration = ok (mkScopeGeneration 2)}
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration headValue))
          headValue {headGeneration = headGeneration headValue + 1,
            headAccepted = Map.insert owner replacement (headAccepted headValue)} >>= expectRight
        staleBase <- loadInventoryHistory store >>= expectRight
        let staleSnapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.map (\(revision, declared) -> (revisionGeneration revision, declared))
                (historyAccepted staleBase)) Map.empty)
            staleCandidate = ok (composeInventory staleSnapshot (ReplaceScope scope :| []))
        staleHistory <- loadInventoryPlanningHistory store staleCandidate >>= expectRight
        assertBool "stop proof survived a different accepted revision"
          (isLeft (planChanges staleCandidate noLifecycleDecisions staleHistory (observations uncreated)))
        changedHead <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration changedHead))
          changedHead {headGeneration = headGeneration changedHead + 1,
            headSequence = headSequence changedHead + 1} >>= expectRight
        broken <- loadInventoryPlanningHistory store staleCandidate
        assertBool "missing committed journal member granted planning authority" (isLeft broken)
        -- Ordinary inspection remains a selected declaration read. Historical
        -- execution evidence is an explicit planning requirement only.
        loadInventoryHistory store >>= expectRight >>= \inspected ->
          historyAccepted inspected @?= historyAccepted staleHistory
        let unrelatedScope = ok (mkScopeDeclaration (ok (mkScopeId Platform "unrelated")) [])
            unrelatedCandidate = ok (composeInventory staleSnapshot (ReplaceScope unrelatedScope :| []))
        _ <- loadInventoryPlanningHistory store unrelatedCandidate >>= expectRight
        pure ()
    , testCase "another application convergence preserves stopped application ownership and unready status" $ do
        store <- newMemoryStore
        (initialReview, initialRegistry) <- preparedApplicationStopFixture store Application Stateless
          (\_ _ -> pure (AdapterEffectAmbiguous "capacity exhausted"))
          (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "original-service-uid"))))
        (tx, selected) <- applyReviewed store initialRegistry initialReview >>= expectRight >>= \case
          StoppedAmbiguous tx op -> pure (tx, op)
          other -> assertFailure (show other) >> undefined
        recordOperatorRecovery store initialRegistry
          (OperatorRecoveryInput tx selected (reviewDigestFor initialReview) StopIncompleteApplication) False >>= expectRight
        history <- loadInventoryHistory store >>= expectRight
        let [(stoppedOwner, _)] = Map.toList (historyAccepted history)
            otherOwner = ok (mkScopeId Application "other-app")
            cluster = mintResourceId otherOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            otherMember = member otherOwner cluster "settings"
            otherScope = ok (mkScopeDeclaration otherOwner [ResourceBundle [otherMember] [] [] [] [] []])
            snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.map (\(revision, declared) -> (revisionGeneration revision, declared))
                (historyAccepted history)) Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope otherScope :| []))
            observations = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent"))
              | resource <- Set.toList (requiredResources (observationRequirements candidate history))])
        effects <- newIORef ([] :: [ResourceId])
        let registry = recordingRegistry
              (\operation _ -> modifyIORef' effects (<> NE.toList (plannedResources operation))
                >> pure AdapterEffectCompleted)
              (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
        proposal <- expectRight (planChanges candidate noLifecycleDecisions history observations)
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReview registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        published <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
        applyReviewed store registry reviewed >>= expectRight >>= \case
          Converged _ -> pure ()
          other -> assertFailure (show other)
        after <- loadInventoryHistory store >>= expectRight
        Map.lookup stoppedOwner (historyAccepted after) @?= Map.lookup stoppedOwner (historyAccepted history)
        Map.lookup stoppedOwner (historyConverged after) @?= Map.lookup stoppedOwner (historyConverged history)
        Map.lookup otherOwner (historyConverged after) @?= fmap fst (Map.lookup otherOwner (historyAccepted after))
        readIORef effects >>= (@?= [declarationId otherMember])
    , testCase "fixed-seed in-memory driver model recovers every operation boundary" $ do
        forM_ [(17, 1), (29, 2), (43, 3), (71, 4)]
          (uncurry runFixedSeedDriverModel)
        modelAssertStoppedScopePreserved
    , testCase "terminal isolated abandonment refuses an unrelated review" $ do
        store <- newMemoryStore
        let failed = ok (mkPhysicalIdentity "failed-job")
            executeOnce _ _ = pure (AdapterEffectAmbiguous "job failed")
            recover _ _ = pure (RecoveryTerminalFailure failed)
        (reviewed, registry) <- preparedFixtureWith store executeOnce recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        (transaction, operation) <- case stopped of
          StoppedAmbiguous value selected -> pure (value, selected)
          other -> assertFailure (show other) >> undefined
        let digest = contentDigest (encodeReviewDocument (reviewedDocument reviewed))
        forM_ [AbandonPartialVolumeRestore, AbandonPartialDatabaseRestore] $ \action -> do
          let decision = OperatorRecoveryInput transaction operation digest action
          refused <- recordOperatorRecovery store registry decision False
          assertBool "terminal result alone authorized an unrelated abandonment" (isLeft refused)
        readHead store >>= expectRight >>= maybe
          (assertFailure "head missing")
          (\headValue -> headActiveTransaction headValue @?= Just (transactionIdText transaction))
    , testCase "operator recovery decision DTO is strict" $ do
        let good = "{\"version\":1,\"transaction\":\"tx-abc\",\"operation\":\"op-def\",\"review\":\""
              <> TE.encodeUtf8 (digestText (contentDigest "sample"))
              <> "\",\"action\":\"accept-adapter-proof\"}"
            volume = "{\"version\":1,\"transaction\":\"tx-abc\",\"operation\":\"op-def\",\"review\":\""
              <> TE.encodeUtf8 (digestText (contentDigest "sample"))
              <> "\",\"action\":\"abandon-partial-volume-restore\"}"
            database = "{\"version\":1,\"transaction\":\"tx-abc\",\"operation\":\"op-def\",\"review\":\""
              <> TE.encodeUtf8 (digestText (contentDigest "sample"))
              <> "\",\"action\":\"abandon-partial-database-restore\"}"
        assertBool "valid decision decodes" (either (const False) (const True) (decodeOperatorRecoveryInput good))
        assertBool "unknown field rejected" (isLeft (decodeOperatorRecoveryInput (BS.init good <> ",\"override\":true}")))
        assertBool "terminal volume action decodes" (either (const False)
          ((== AbandonPartialVolumeRestore) . recoveryAction)
          (decodeOperatorRecoveryInput volume))
        assertBool "terminal database action decodes" (either (const False)
          ((== AbandonPartialDatabaseRestore) . recoveryAction)
          (decodeOperatorRecoveryInput database))
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
    , testCase "shared driver admits dependent work and recovers its predecessor before live preflight" $ do
        store <- newMemoryStore
        ready <- newIORef False
        trace <- newIORef ([] :: [Text])
        let preflight operation _ = do
              modifyIORef' trace (<> ["preflight:" <> action operation])
              completed <- readIORef ready
              pure $
                if plannedAction operation == RunDeclaredOperation && not completed
                  then Left "predecessor has not completed"
                  else Right ()
            effect operation _ = do
              modifyIORef' trace (<> ["effect:" <> action operation])
              pure $
                if plannedAction operation == CreateResource
                  then AdapterEffectAmbiguous "acknowledgement lost"
                  else AdapterEffectCompleted
            recover operation _ = do
              modifyIORef' trace (<> ["recover:" <> action operation])
              writeIORef ready True
              pure (RecoveryProvedComplete (proof operation))
            action = T.pack . show . plannedAction
        (reviewed, registry) <- preparedDependentFixture store preflight effect recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of
          StoppedAmbiguous value _ -> pure value
          other -> assertFailure (show other) >> undefined
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        -- Reopening the command after convergence must not observe or mutate.
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        readIORef trace
          >>= ( @?=
                  [ "preflight:CreateResource"
                  , "effect:CreateResource"
                  , "recover:CreateResource"
                  , "preflight:RunDeclaredOperation"
                  , "effect:RunDeclaredOperation"
                  ]
              )
    , testCase "resume creates an independent Deployment while exact predecessor waits for readiness" $ do
        store <- newMemoryStore
        effects <- newIORef ([] :: [OperationId])
        ready <- newIORef False
        let effect operation _ = do
              previous <- readIORef effects
              modifyIORef' effects (<> [plannedOperationId operation])
              if null previous then pure (AdapterEffectAmbiguous "readiness pending")
                else writeIORef ready True >> pure AdapterEffectCompleted
            recover operation _ = do
              available <- readIORef ready
              pure $ if available then RecoveryProvedComplete (proof operation)
                else RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "created-deployment"))
        (reviewed, registry) <- preparedReadinessFixture store False Stateless "deployment" effect recover
        stopped <- applyReviewed store registry reviewed >>= expectRight
        transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        resumeTransaction store registry transaction >>= expectRight >>= (@?= Converged transaction)
        calls <- readIORef effects
        length calls @?= 2
        Set.size (Set.fromList calls) @?= 2
        transactionIdText transaction @?= T.pack (transactionToken reviewed)
    , testCase "readiness continuation refuses dependent, durable and non-Deployment creates" $ do
        let durable = Durable (RecoveryIntent (ok (mkName "restore"))
              (mkSecretRef (ok (mkName "password")) (ok (mkName "v1")) :| []))
        forM_ [(True, Stateless, "deployment"), (False, durable, "deployment"),
          (False, Stateless, "configmap")] $ \(dependent, policy, kind) -> do
          store <- newMemoryStore
          effects <- newIORef (0 :: Int)
          let effect _ _ = modifyIORef' effects (+ 1) >> pure (AdapterEffectAmbiguous "readiness pending")
              recover _ _ = pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "created-deployment")))
          (reviewed, registry) <- preparedReadinessFixture store dependent policy kind effect recover
          stopped <- applyReviewed store registry reviewed >>= expectRight
          transaction <- case stopped of StoppedAmbiguous value _ -> pure value; other -> assertFailure (show other) >> undefined
          resumeTransaction store registry transaction >>= expectRight >>= (@?= stopped)
          readIORef effects >>= (@?= 1)
    , testCase "shared driver stops every unresolved or terminal recovery before dependent work" $ do
        forM_
          [ RecoveryTerminalFailure (ok (mkPhysicalIdentity "failed-job"))
          , RecoveryUnresolved "provider unavailable"
          , RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "unready-deployment"))
          ]
          $ \decision -> do
            store <- newMemoryStore
            effects <- newIORef (0 :: Int)
            preflights <- newIORef (0 :: Int)
            recoveries <- newIORef (0 :: Int)
            let preflight _ _ = modifyIORef' preflights (+ 1) >> pure (Right ())
                effect _ _ = modifyIORef' effects (+ 1) >> pure (AdapterEffectAmbiguous "interrupted")
                recover _ _ = modifyIORef' recoveries (+ 1) >> pure decision
            (reviewed, registry) <- preparedDependentFixture store preflight effect recover
            stopped <- applyReviewed store registry reviewed >>= expectRight
            transaction <- case stopped of
              StoppedAmbiguous value _ -> pure value
              other -> assertFailure (show other) >> undefined
            resumeTransaction store registry transaction >>= expectRight >>= (@?= stopped)
            readIORef effects >>= (@?= 1)
            readIORef preflights >>= (@?= 1)
            readIORef recoveries >>= (@?= 1)
    , testCase "shared driver rejects invalid graphs and unknown legacy resolutions" $ do
        store <- newMemoryStore
        (reviewed, _) <-
          preparedDependentFixture
            store
            (\_ _ -> pure (Right ()))
            (\_ _ -> pure AdapterEffectCompleted)
            (\_ _ -> pure RecoverySafeToRetry)
        let operations = reviewOperations (reviewedDocument reviewed)
            creation = head [o | o <- operations, plannedAction (reviewPlannedOperation o) == CreateResource]
            completion = head [o | o <- operations, plannedAction (reviewPlannedOperation o) == RunDeclaredOperation]
            createId = plannedOperationId (reviewPlannedOperation creation)
            completionId = plannedOperationId (reviewPlannedOperation completion)
            cycleCreation =
              creation
                { reviewPlannedOperation =
                    (reviewPlannedOperation creation)
                      { plannedDependencies = [completionId]
                      }
                }
        dependenciesComplete Map.empty completion @?= False
        dependenciesComplete (Map.singleton createId Ambiguous) completion @?= False
        dependenciesComplete (Map.singleton createId (Completed (proofOperation createId))) completion @?= True
        assertBool "cycle accepted" (isLeft (validateOperationGraph [cycleCreation, completion]))
        assertBool "duplicate accepted" (isLeft (validateOperationGraph [creation, creation]))
        assertBool "missing dependency accepted" (isLeft (validateOperationGraph [completion]))
        forM_
          [ "unknown-future-marker"
          , "abandoned-terminal-scheduled-prune"
          , "fenced-recovery-proved:invalid"
          ]
          $ \marker ->
            case nextOperation operations (Map.singleton createId (OperatorResolved marker)) of
              OperationBlocked selected _ -> selected @?= createId
              other -> assertFailure (show other)
        forM_ [IntentRecorded, Ambiguous, Failed (PartialOrUnknown "partial")] $ \state ->
          nextOperation operations (Map.singleton createId state) @?= RecoverOperation creation
        forM_
          [ Pending
          , Failed (KnownNoEffect "none")
          , OperatorResolved "adapter-proved-safe-retry"
          , OperatorResolved "fence-not-reserved-safe-retry"
          ]
          $ \state ->
            nextOperation operations (Map.singleton createId state) @?= ExecuteOperation creation
        nextOperation operations (Map.singleton createId (Completed (proofOperation createId)))
          @?= ExecuteOperation completion
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
          let wrongBinding = ContextBinding (ok (mkContextId "different")) (ok (mkName "project"))
          refusedBinding <- restoreStoreFor restored backup wrongBinding
          assertBool "restore wrote a different context" (isLeft refusedBinding)
          readHead restored >>= (@?= Right Nothing)
          _ <- restoreStoreFor restored backup fixtureBinding >>= expectRight
          readHead restored >>= expectRight >>= (@?= Just (HeadManifest 1 0 0 fixtureBinding "client-test" Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing Nothing))
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

-- This is deliberately a small, fixed model rather than an unbounded property:
-- it runs the planner, review publisher, driver, and recovery path on the
-- in-memory conditional store.  The four cases interrupt each of the four
-- effect boundaries (create alpha, create beta, update alpha, verify alpha).
-- The final retirement is a reviewed, effect-free ownership transition.
runFixedSeedDriverModel :: Int -> Int -> Assertion
runFixedSeedDriverModel seed interruptionBoundary = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "fixed-seed-driver" >>= expectRight
  effects <- newIORef (Map.empty :: Map.Map OperationId Int)
  attempted <- newIORef (0 :: Int)
  let execution operation _ = do
        attempt <- atomicModifyIORef' attempted (\count -> (count + 1, count + 1))
        modifyIORef' effects (Map.insertWith (+) (plannedOperationId operation) 1)
        pure $ if attempt == interruptionBoundary
          then AdapterEffectAmbiguous "fixed-seed interruption"
          else AdapterEffectCompleted
      registry = modelRecordingRegistry execution
        (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
      seedTag = T.pack (show seed)
      alphaOwner = ok (mkScopeId Application ("model-alpha-" <> seedTag))
      betaOwner = ok (mkScopeId Application ("model-beta-" <> seedTag))
      alpha = modelScope alphaOwner "alpha" ("alpha-v1-" <> seedTag)
      alphaUpdated = modelScope alphaOwner "alpha" ("alpha-v2-" <> seedTag)
      beta = modelScope betaOwner "beta" ("beta-v1-" <> seedTag)

  history0 <- loadInventoryHistory store >>= expectRight
  candidate1 <- modelCandidate history0 (ReplaceScope alpha :| [])
  reviewed1 <- modelReview store registry candidate1 noLifecycleDecisions
  modelApplyAndRecover store registry reviewed1
  history1 <- modelAssertInvariants store Nothing
  modelAssertStaleConditionalWrite store

  candidate2 <- modelCandidate history1 (ReplaceScope beta :| [])
  reviewed2 <- modelReview store registry candidate2 noLifecycleDecisions
  modelApplyAndRecover store registry reviewed2
  history2 <- modelAssertInvariants store (Just (historyHead history1))
  modelAssertStaleConditionalWrite store
  let betaRevision = Map.lookup betaOwner (historyAccepted history2)

  candidate3 <- modelCandidate history2 (ReplaceScope alphaUpdated :| [])
  reviewed3 <- modelReview store registry candidate3 noLifecycleDecisions
  modelApplyAndRecover store registry reviewed3
  history3 <- modelAssertInvariants store (Just (historyHead history2))
  modelAssertStaleConditionalWrite store
  Map.lookup betaOwner (historyAccepted history3) @?= betaRevision
  Map.lookup betaOwner (historyConverged history3) @?= fmap fst betaRevision

  -- Losing only alpha's convergence proof must yield a readiness verification
  -- for the unchanged alpha resource.  This is the planner regression fixed by
  -- 7c957c02, exercised through a real reviewed execution.
  headBeforeVerify <- readHead store >>= expectRight >>= maybe
    (assertFailure "model store has no head" >> pure (error "unreachable")) pure
  _ <- replaceHeadIfGenerationMatches store (Just (headGeneration headBeforeVerify))
    headBeforeVerify
      { headGeneration = headGeneration headBeforeVerify + 1
      , headConverged = Map.delete alphaOwner (headConverged headBeforeVerify)
      } >>= expectRight
  historyBeforeVerify <- loadInventoryHistory store >>= expectRight
  candidate4 <- modelCandidate historyBeforeVerify (ReplaceScope alphaUpdated :| [])
  verification <- modelReview store registry candidate4 noLifecycleDecisions
  assertBool "unconverged selected scope did not receive a verification"
    (any ((== VerifyResource) . plannedAction)
      (reviewOperations (reviewedDocument verification) <&> reviewPlannedOperation))
  modelApplyAndRecover store registry verification
  history4 <- modelAssertInvariants store (Just (historyHead historyBeforeVerify))
  modelAssertStaleConditionalWrite store

  -- A retirement is still a review decision even when RetainResources means
  -- the executor has no provider effect to run.
  retirement <- modelCandidate history4 (RetireScope betaOwner RetainResources :| [])
  retirementObservations <- modelObservations retirement history4
  let betaResource = declarationId (modelMember betaOwner "beta" ("beta-v1-" <> seedTag))
      decision = LifecycleProposal betaResource ApproveRetirement
        (lifecycleObservationDigest fixtureBinding betaResource
          (observationMap retirementObservations Map.! betaResource))
  decisions <- expectRight (validateLifecycleDecisions retirement history4
    retirementObservations [decision])
  reviewedRetirement <- modelReview store registry retirement decisions
  modelApplyAndRecover store registry reviewedRetirement
  _ <- modelAssertInvariants store (Just (historyHead history4))

  recorded <- readIORef effects
  assertBool "recovery repeated a recorded provider effect"
    (all (<= 1) (Map.elems recorded))

modelMember :: ScopeId -> Text -> Text -> Declaration
modelMember owner role version = case member owner cluster role of
  Managed resource -> Managed (resource
    { spec = NativeObject (contentDigest (TE.encodeUtf8 version)) })
  declaration -> declaration
  where
    cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

modelScope :: ScopeId -> Text -> Text -> ScopeDeclaration
modelScope owner role version = ok (mkScopeDeclaration owner
  [ResourceBundle [modelMember owner role version] [] [] [] [] []])

modelCandidate :: InventoryHistory -> NonEmpty ScopeChange -> IO CompositionCandidate
modelCandidate history changes = pure (ok (composeInventory snapshot changes))
  where
    snapshot = ok (mkScopeSnapshot fixtureBinding
      (Map.map (\(revision, scope) -> (revisionGeneration revision, scope))
        (historyAccepted history)) (historyReservations history))

modelRecordingRegistry
  :: (PlannedOperation -> PreparedNative -> IO AdapterExecution)
  -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision)
  -> AdapterRegistry
modelRecordingRegistry execution recovery = ok (mkAdapterRegistry [adapter])
  where
    adapter = (ok (lookupAdapter (recordingRegistry execution recovery) KubernetesExecutor))
      { adapterObserve = \resources -> pure (observationSet
          [ (resource, ObservedPresent (ok (mkPhysicalIdentity
              ("model:" <> resourceIdText resource))))
          | resource <- resources
          ])
      }

modelObservations :: CompositionCandidate -> InventoryHistory -> IO ObservationSet
modelObservations candidate history = pure (ok (observationSet
  [ (resource, if Set.member resource accepted
      then ObservedPresent (ok (mkPhysicalIdentity ("model:" <> resourceIdText resource)))
      else ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource))))
  | resource <- Set.toAscList (requiredResources (observationRequirements candidate history))
  ]))
  where
    accepted = Set.fromList
      [ declarationId declaration
      | (_, (_, scope)) <- Map.toAscList (historyAccepted history)
      , bundle <- scopeBundles scope
      , declaration <- declarations bundle
      ]

modelReview :: InventoryStore -> AdapterRegistry -> CompositionCandidate -> LifecycleDecisions
  -> IO ReviewedPlan
modelReview store registry candidate decisions = do
  history <- loadInventoryHistory store >>= expectRight
  observations <- modelObservations candidate history
  proposal <- expectRight (planChanges candidate decisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  either (assertFailure . show . NE.toList) pure (verifyReview published bundle)

modelApplyAndRecover :: InventoryStore -> AdapterRegistry -> ReviewedPlan -> Assertion
modelApplyAndRecover store registry reviewed = do
  result <- applyReviewed store registry reviewed >>= expectRight
  case result of
    Converged _ -> pure ()
    StoppedAmbiguous transaction _ -> do
      -- Model the second executor at the claim boundary.  It must not resume
      -- the first executor's transaction until an explicit takeover is chosen.
      current <- readHead store >>= expectRight >>= maybe
        (assertFailure "ambiguous model run has no head" >> pure (error "unreachable")) pure
      _ <- replaceHeadIfGenerationMatches store (Just (headGeneration current)) current
        { headGeneration = headGeneration current + 1
        , headExecutorClaim = Just (ExecutorClaim (transactionIdText transaction)
            "second-model-executor" 1 "2026-09-30T00:00:00Z")
        } >>= expectRight
      refused <- resumeTransaction store registry transaction
      case refused of
        Left errors -> assertBool "second executor was not refused before takeover"
          (any ((== "executor-claim") . admissionErrorCode) (NE.toList errors))
        Right value -> assertFailure ("second executor resumed without takeover: " <> show value)
      resumed <- resumeTransactionWithTakeover store registry transaction True >>= expectRight
      case resumed of
        Converged value -> value @?= transaction
        other -> assertFailure ("takeover did not converge recovered model run: " <> show other)
    other -> assertFailure ("model run stopped outside ambiguous recovery: " <> show other)

modelAssertInvariants :: InventoryStore -> Maybe HeadManifest -> IO InventoryHistory
modelAssertInvariants store previous = do
  history <- loadInventoryHistory store >>= expectRight
  let headValue = historyHead history
  assertBool "converged revision is not an accepted revision"
    (all (\(scope, revision) -> fmap fst (Map.lookup scope (historyAccepted history)) == Just revision)
      (Map.toAscList (historyConverged history)))
  case previous of
    Nothing -> pure ()
    Just old -> do
      assertBool "head generation did not advance monotonically"
        (headGeneration headValue > headGeneration old)
      assertBool "journal sequence did not advance monotonically"
        (headSequence headValue >= headSequence old)
  headActiveTransaction headValue @?= Nothing
  pure history

modelAssertStaleConditionalWrite :: InventoryStore -> Assertion
modelAssertStaleConditionalWrite store = do
  before <- readHead store >>= expectRight >>= maybe
    (assertFailure "conditional-write model has no head" >> pure (error "unreachable")) pure
  stale <- replaceHeadIfGenerationMatches store (Just (headGeneration before - 1)) before
  assertBool "stale conditional write unexpectedly succeeded" (isLeft stale)
  after <- readHead store >>= expectRight
  after @?= Just before

-- Keep the eb582eb0 assertion inside the model checkpoint as well as in its
-- focused regression: a later, unrelated completed review must not promote a
-- stopped scope to converged merely because both scopes are accepted.
modelAssertStoppedScopePreserved :: Assertion
modelAssertStoppedScopePreserved = do
  store <- newMemoryStore
  (stoppedReview, stoppedRegistry) <- preparedApplicationStopFixture store Application Stateless
    (\_ _ -> pure (AdapterEffectAmbiguous "model stopped scope"))
    (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "model-service-uid"))))
  (transaction, selected) <- applyReviewed store stoppedRegistry stoppedReview >>= expectRight >>= \case
    StoppedAmbiguous value operation -> pure (value, operation)
    other -> assertFailure ("model did not stop its selected scope: " <> show other) >> pure (error "unreachable")
  recordOperatorRecovery store stoppedRegistry
    (OperatorRecoveryInput transaction selected (reviewDigestFor stoppedReview) StopIncompleteApplication) False
      >>= expectRight
  stoppedHistory <- loadInventoryHistory store >>= expectRight
  let [(stoppedOwner, _)] = Map.toAscList (historyAccepted stoppedHistory)
      otherOwner = ok (mkScopeId Application "model-unrelated")
      otherScope = modelScope otherOwner "settings" "model-unrelated-v1"
      registry = modelRecordingRegistry
        (\_ _ -> pure AdapterEffectCompleted)
        (\operation _ -> pure (RecoveryProvedComplete (proof operation)))
  candidate <- modelCandidate stoppedHistory (ReplaceScope otherScope :| [])
  reviewed <- modelReview store registry candidate noLifecycleDecisions
  modelApplyAndRecover store registry reviewed
  after <- loadInventoryHistory store >>= expectRight
  Map.lookup stoppedOwner (historyAccepted after) @?= Map.lookup stoppedOwner (historyAccepted stoppedHistory)
  Map.lookup stoppedOwner (historyConverged after) @?= Map.lookup stoppedOwner (historyConverged stoppedHistory)

preparedFixture :: InventoryStore -> IORef [OperationId] -> (PlannedOperation -> IO AdapterExecution) -> (PlannedOperation -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixture store calls execution recovery =
  preparedFixtureWith store (\operation _ -> modifyIORef' calls (<> [plannedOperationId operation]) >> execution operation) (\operation _ -> recovery operation)

preparedFixtureWith :: InventoryStore -> (PlannedOperation -> PreparedNative -> IO AdapterExecution) -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision) -> IO (ReviewedPlan, AdapterRegistry)
preparedFixtureWith store execution recovery =
  preparedFixtureWithRegistry store execution recovery (\_ registry -> registry)

preparedFixtureWithRegistry :: InventoryStore
  -> (PlannedOperation -> PreparedNative -> IO AdapterExecution)
  -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision)
  -> (Map.Map ScopeId ScopeRevision -> AdapterRegistry -> AdapterRegistry)
  -> IO (ReviewedPlan, AdapterRegistry)
preparedFixtureWithRegistry store execution recovery customize = do
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
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
      registry = customize (proposalDesired proposal) (recordingRegistry execution recovery)
  snapshotBefore <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshotBefore proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  snapshotAfter <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshotAfter bundle)
  pure (reviewed, registry)
  where
    physical resource = ok (mkPhysicalIdentity ("accepted:" <> resourceIdText resource))
    absence resource = contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource))

-- A real planner-produced create/declared-operation dependency pair. Its
-- dependent live precondition is deliberately false until recovery proves the
-- original effect. No journal or review constructor bypass is used here.
preparedDependentFixture ::
  InventoryStore ->
  (PlannedOperation -> PreparedNative -> IO (Either Text ())) ->
  (PlannedOperation -> PreparedNative -> IO AdapterExecution) ->
  (PlannedOperation -> PreparedNative -> IO RecoveryDecision) ->
  IO (ReviewedPlan, AdapterRegistry)
preparedDependentFixture store preflight effect recovery = do
  let owner = ok (mkScopeId Standalone "dependent-driver")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      managed = member owner cluster "job"
      resource = declarationId managed
      operation =
        DeclaredOperation
          (mintResourceId owner (ok (mkLogicalKey "prune")) (ok (mkName "operation")))
          (resource :| [])
          [ContentInput (contentDigest "prune-intent")]
          OperatorRecovery
          PruneData
      scope = ok (mkScopeDeclaration owner [ResourceBundle [managed] [] [] [] [operation] []])
      candidate =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope scope :| [])
          )
      registry = recordingRegistryWith preflight effect recovery
  _ <- initializeStore store fixtureBinding "dependent-driver" >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent"))])
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  snapshot <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show) pure (verifyReview snapshot bundle)
  length (reviewOperations (reviewedDocument reviewed)) @?= 2
  pure (reviewed, registry)

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument

preparedApplicationStopFixture :: InventoryStore -> ScopeKind -> DataPolicy
  -> (PlannedOperation -> PreparedNative -> IO AdapterExecution)
  -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision)
  -> IO (ReviewedPlan, AdapterRegistry)
preparedApplicationStopFixture store kind policy effect recovery = do
  let owner = ok (mkScopeId kind "incomplete-app")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      service = case member owner cluster "service" of
        Managed resource -> Managed (resource
          { address = Kubernetes cluster "serving.knative.dev" (ok (mkName "service"))
              (Just (ok (mkName "personal"))) (ok (mkName "web"))
          , spec = KnativeService (contentDigest "service"), dataPolicy = policy
          , dependencies = [OrderedAfter (declarationId retained)] })
        other -> other
      retained = case member owner cluster "untouched" of
        Managed resource -> Managed (resource
          { address = Kubernetes cluster "" (ok (mkName "persistentvolumeclaim"))
              (Just (ok (mkName "personal"))) (ok (mkName "retained-data"))
          , dataPolicy = Durable (RecoveryIntent (ok (mkName "backup"))
              (mkSecretRef (ok (mkName "password")) (ok (mkName "v1")) :| [])) })
        other -> other
      uncreated = case member owner cluster "uncreated" of
        Managed resource -> Managed (resource
          { address = Kubernetes cluster "" (ok (mkName "secret"))
              (Just (ok (mkName "personal"))) (ok (mkName "backup-key"))
          , dataPolicy = Durable (RecoveryIntent (ok (mkName "backup"))
              (mkSecretRef (ok (mkName "password")) (ok (mkName "v1")) :| []))
          , dependencies = [OrderedAfter (declarationId service)] })
        other -> other
      scope = ok (mkScopeDeclaration owner [ResourceBundle [service, retained, uncreated] [] [] [] [] []])
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
        (ReplaceScope scope :| []))
      registry = recordingRegistry
        (\operation prepared -> if declarationId service `elem` NE.toList (plannedResources operation)
          then effect operation prepared else pure AdapterEffectCompleted) recovery
  _ <- initializeStore store fixtureBinding "stop-app-test" >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations = ok (observationSet [(declarationId resource, ConfirmedAbsent (contentDigest "absent")) | resource <- [service, retained, uncreated]])
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  after <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview after bundle)
  pure (reviewed, registry)

preparedReadinessFixture :: InventoryStore -> Bool -> DataPolicy -> Text
  -> (PlannedOperation -> PreparedNative -> IO AdapterExecution)
  -> (PlannedOperation -> PreparedNative -> IO RecoveryDecision)
  -> IO (ReviewedPlan, AdapterRegistry)
preparedReadinessFixture store dependent policy kind effect recovery = do
  let owner = ok (mkScopeId Platform "readiness-driver")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      workload role after = case member owner cluster role of
        Managed resource -> Managed (resource
          { address = Kubernetes cluster (if kind == "deployment" then "apps" else "")
              (ok (mkName kind)) (Just (ok (mkName "system"))) (ok (mkName role))
          , dataPolicy = policy, dependencies = after })
        other -> other
      first = workload "activator" []
      second = workload "autoscaler" (if dependent then [OrderedAfter (declarationId first)] else [])
      scope = ok (mkScopeDeclaration owner [ResourceBundle [first, second] [] [] [] [] []])
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
        (ReplaceScope scope :| []))
      registry = recordingRegistry effect recovery
  _ <- initializeStore store fixtureBinding "readiness-driver" >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations = ok (observationSet [(declarationId member, ConfirmedAbsent (contentDigest "absent")) | member <- [first, second]])
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  before <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry before proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  snapshot <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview snapshot bundle)
  pure (reviewed, registry)


-- Execute the production transport's actual stdin script against host responses.
-- Host primitives are intercepted; no credential file or provider is accessed.
registryHostFixture :: String
registryHostFixture = unlines
  [ "systemctl() {"
  , "  case \"$*\" in"
  , "    *nagare-switch-rollback.timer*) printf 'inactive\\n' ;;"
  , "    *--property=Environment*) printf 'PATH=/usr/bin\\n' ;;"
  , "    *--property=ActiveState*) printf 'inactive\\n' ;;"
  , "    *--property=ExecMainStatus*) printf '0\\n' ;;"
  , "    *--property=Job*) [ \"$NAGARE_TEST_JOB\" != lookup-failure ] || return 31; printf '%s\\n' \"$NAGARE_TEST_JOB\" ;;"
  , "    *--property=ExecMainStartTimestampMonotonic*) printf '10\\n' ;;"
  , "    *--property=InvocationID*) printf 'original\\n' ;;"
  , "    'is-active --quiet k3s.service') return 0 ;;"
  , "    *) return 32 ;;"
  , "  esac"
  , "}"
  , "curl() { case \"$*\" in */instance/id) printf '123\\n' ;; */default/token) printf '%s\\n' '{\"access_token\":\"fixture-token\",\"expires_in\":1200}' ;; *) return 33 ;; esac; }"
  , "readlink() { printf '/nix/store/accepted-test-closure\\n'; }"
  , "stat() { printf '600:0\\n'; }"
  , "cat() { [ \"$1\" = /proc/sys/kernel/random/boot_id ] || return 34; printf 'boot\\n'; }"
  , "awk() { return 1; }"
  , "flock() { return 0; }"
  , "jq() { \"$NAGARE_TEST_JQ\" \"$@\"; }"
  , "k3s() {"
  , "  case \"$*\" in"
  , "    'kubectl get nodes '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"uid\":\"node\"}}]}' ;;"
  , "    'kubectl get deployment '*) printf '%s\\n' '{\"metadata\":{\"uid\":\"deployment-uid\",\"generation\":1},\"spec\":{\"replicas\":1},\"status\":{\"observedGeneration\":1,\"readyReplicas\":0,\"updatedReplicas\":0,\"conditions\":[{\"type\":\"Available\",\"status\":\"False\"}]}}' ;;"
  , "    'kubectl get replicasets '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"uid\":\"replica-uid\",\"ownerReferences\":[{\"uid\":\"deployment-uid\"}]}}]}' ;;"
  , "    'kubectl get pods '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"ownerReferences\":[{\"uid\":\"replica-uid\"}]},\"status\":{\"containerStatuses\":[{\"state\":{\"waiting\":{\"reason\":\"ImagePullBackOff\"}}}]}}]}' ;;"
  , "    *) return 35 ;;"
  , "  esac"
  , "}"
  ]

preparedRegistryFixture :: InventoryStore -> IO (ReviewBundle, ReviewedPlan, AdapterRegistry)
preparedRegistryFixture store = do
  _ <- initializeStore store fixtureBinding "registry-bootstrap" >>= expectRight
  let hostOwner = ok (mkScopeId Platform "host")
      owner = ok (mkScopeId Platform "net-certmanager")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      hostMember = case member hostOwner cluster "system" of
        Managed resource -> Managed (resource {executor = HostExecutor,
          address = Host cluster (ok (mkName "system"))})
        other -> other
      controllerId = declarationId (member owner cluster "net-certmanager-controller")
      rawObject = object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("Deployment" :: Text),
        "metadata" .= object ["name" .= ("net-certmanager-controller" :: Text),
          "namespace" .= ("knative-serving" :: Text)], "spec" .= object
        ["template" .= object ["spec" .= object ["containers" .=
          [object ["name" .= ("controller" :: Text),
            "image" .= ("registry.example.test/controller@sha256:" <> T.replicate 64 "a")]]]]]]
      (controllerMember, nativeObject) = ok (bindKubernetesObject (KubernetesInput
        controllerId owner cluster rawObject (contentDigest (ok (canonicalValue rawObject)))
        Retain Stateless Public (SourceLocation "test" "registry controller")))
      controller = Managed controllerMember
      hostActivation = DeclaredOperation
        (mintResourceId hostOwner (ok (mkLogicalKey "activation")) (ok (mkName "apply")))
        (declarationId hostMember :| [])
        [ContentInput (contentDigest "configuration"), ContentInput (contentDigest "lock")]
        OperatorRecovery ActivateHost
      hostScope = ok (mkScopeDeclaration hostOwner
        [ResourceBundle [hostMember] [] [] [] [hostActivation] []])
      controllerScope = ok (mkScopeDeclaration owner [ResourceBundle [controller] [] [] [] [] []])
      hostPlan operation = HostActivationPlan 1 (plannedOperationId operation)
        (plannedInputDigest operation) (fixtureBinding ^. #identity)
        (ok (mkName "host")) (ok (mkPhysicalIdentity "gce://projects/project/zones/zone/instances/123"))
        "deploy@host" (contentDigest "configuration") (contentDigest "lock") Nothing Nothing False
        "/nix/store/old-test-closure" "/nix/store/accepted-test-closure" "activation"
      kubernetes = mkKubernetesAdapter (Map.singleton controllerId (controllerMember, nativeObject))
        (KubernetesAdapterOps (fixtureBinding ^. #identity)
          (\_ -> pure (KubernetesAbsent (contentDigest "absent")))
          (\_ -> pure AdapterEffectCompleted))
      base = recordingRegistry
        (\operation _ -> pure (if plannedExecutor operation == HostExecutor
          then AdapterEffectCompleted else AdapterEffectAmbiguous "pull failure"))
        (\_ _ -> pure (RecoveryAwaitingReadiness (ok (mkPhysicalIdentity "deployment-uid"))))
      adapter executor = (ok (lookupAdapter base executor))
        { adapterIdentity = if executor == HostExecutor then "nixos-safe-activation"
            else "kubernetes-conditional-object"
        , adapterPrepare = \operation -> if executor == HostExecutor
            then pure (Right (PreparedNative
              (ok (canonicalValue (toJSON (hostPlan operation)))) "accepted host"))
            else adapterPrepare kubernetes operation }
      registry = ok (mkAdapterRegistry (map adapter [HostExecutor, KubernetesExecutor]))
      save payload scope = do
        history <- loadInventoryHistory store >>= expectRight
        let snapshot = ok (mkScopeSnapshot fixtureBinding
              (Map.map (\(revision, scope) -> (revisionGeneration revision, scope))
                (historyAccepted history)) Map.empty)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
            acceptedIds = Set.fromList [declarationId declaration
              | (_, (_, accepted)) <- Map.toList (historyAccepted history)
              , resourceBundle <- scopeBundles accepted
              , declaration <- declarations resourceBundle]
            required = requiredResources (observationRequirements candidate history)
            observations = ok (observationSet [(resource,
              if Set.member resource acceptedIds then ObservedPresent (ok (mkPhysicalIdentity "accepted"))
              else ConfirmedAbsent (contentDigest "absent")) | resource <- Set.toList required])
            proposal = ok (planChanges candidate noLifecycleDecisions history observations)
        before <- readStoreSnapshot store >>= expectRight
        bundle <- prepareReviewWithPayloadIdentity payload registry before proposal >>= expectRight
        _ <- publishReview store bundle >>= expectRight
        after <- readStoreSnapshot store >>= expectRight
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview after bundle)
        pure (bundle, reviewed)
  (_, hostReview) <- save "host-policy" hostScope
  applyReviewed store registry hostReview >>= expectRight >>= \case
    Converged _ -> pure ()
    other -> assertFailure ("host fixture did not converge: " <> show other)
  (bundle, reviewed) <- save "nagare-bootstrap:original-payload" controllerScope
  pure (bundle, reviewed, registry)

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

observingRegistry :: Executor -> ResourceObservation -> AdapterRegistry
observingRegistry executor fact = ok (mkAdapterRegistry [Adapter
  { adapterExecutor = executor
  , adapterIdentity = "migration-observer"
  , adapterVersion = "1"
  , adapterObserve = \resources -> pure (observationSet [(resource, fact) | resource <- resources])
  , adapterPrepare = \operation -> pure (Left (PrepareRefused (plannedOperationId operation) "read-only observer"))
  , adapterPreflight = \_ _ -> pure (Left "read-only observer")
  , adapterExecute = \_ _ -> pure (AdapterEffectFailed (KnownNoEffect "read-only observer"))
  , adapterVerify = \_ _ -> pure (Left "read-only observer")
  , adapterRecover = \_ _ -> pure (RecoveryUnresolved "read-only observer")
  }])

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
