module InventoryTransactionSpec (inventoryTransactionTests, exerciseStore, fixtureBinding, preparedFixtureWith, recordingRegistryWith, runInventoryLockHoldProbe, runInventoryLockProbe) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode, toJSON)
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
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute hiding (withProcessLock)
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle (AdoptionInput (..), AdoptionTarget (..), decideAdoption, decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as InventoryStatus
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
    , testCase "operator recovery decision DTO is strict" $ do
        let good = "{\"version\":1,\"transaction\":\"tx-abc\",\"operation\":\"op-def\",\"review\":\""
              <> TE.encodeUtf8 (digestText (contentDigest "sample"))
              <> "\",\"action\":\"accept-adapter-proof\"}"
        assertBool "valid decision decodes" (either (const False) (const True) (decodeOperatorRecoveryInput good))
        assertBool "unknown field rejected" (isLeft (decodeOperatorRecoveryInput (BS.init good <> ",\"override\":true}")))
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
          readHead restored >>= expectRight >>= (@?= Just (HeadManifest 1 0 0 fixtureBinding "client-test" Map.empty Map.empty Map.empty Map.empty Nothing Nothing Nothing))
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
