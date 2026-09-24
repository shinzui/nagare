module InventoryMigrationSpec (inventoryMigrationTests) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.IORef
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Control.Monad (forM_)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import InventoryTransactionSpec (recordingRegistryWith)
import Test.Tasty
import Test.Tasty.HUnit

inventoryMigrationTests :: TestTree
inventoryMigrationTests = testGroup "inventory migration"
  [ testCase "reviewed migration retains the old incarnation after an ordered recording run" $ do
      store <- acceptedStore
      history <- loadInventoryHistory store >>= either (assertFailure . show) pure
      let destinationFacts = ok (observationSet [(resourceId, ConfirmedAbsent absence)])
      decisions <- either (assertFailure . show . NE.toList) pure
        (decideMigration candidate input history destinationFacts observations)
      let proposal = ok (planChanges candidate decisions history destinationFacts)
          registry = recordingRegistryWith (\_ _ -> pure (Right ()))
            (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry)
      before <- readStoreSnapshot store >>= either (assertFailure . show) pure
      bundle <- prepareReview registry before proposal >>= either (assertFailure . show . NE.toList) pure
      _ <- publishReview store bundle >>= either (assertFailure . show) pure
      published <- readStoreSnapshot store >>= either (assertFailure . show) pure
      reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
      result <- applyReviewed store registry reviewed >>= either (assertFailure . show . NE.toList) pure
      case result of
        Converged _ -> pure ()
        other -> assertFailure ("migration did not converge: " <> show other)
      after <- loadInventoryHistory store >>= either (assertFailure . show) pure
      case Map.lookup resourceId (historyRetained after) of
        Just (retained, source) -> do
          source @?= oldResource
          retainedPhysical retained @?= physical
          retainedMigrationReview retained @?= Just (reviewDigest bundle)
        Nothing -> assertFailure "source incarnation disappeared from retained history"
      let active = [resource | (_, scopeValue) <- Map.elems (historyAccepted after),
            bundleValue <- scopeBundles scopeValue, Managed resource <- declarations bundleValue]
      newResource `elem` active @?= True
      headActiveTransaction (historyHead after) @?= Nothing
      let sourceFacts = ok (observationSet [(resourceId, ObservedPresent physical)])
          collection = Status.assessCollections after (candidateInventory candidate) sourceFacts
      assertBool "active destination failed to block source collection"
        (any (elem "active-incarnation" . Status.collectionReasons) collection)
      let acceptedHead = historyHead after
          unproved = acceptedHead
            { headGeneration = headGeneration acceptedHead + 1
            , headRetained = Map.adjust
                (\entry -> entry {retainedMigrationReview = Nothing})
                resourceId (headRetained acceptedHead)
            }
      _ <- replaceHeadIfGenerationMatches store (Just (headGeneration acceptedHead)) unproved
        >>= either (assertFailure . show) pure
      corrupted <- loadInventoryHistory store
      assertBool "unproved active/retained overlap was accepted" (isLeft corrupted)
  , testCase "each interrupted migration stage resumes from adapter proof without replay" $ do
      forM_ [PrepareDestination, BackUpSource, FenceWriters, TransferState,
          VerifyDestination, SwitchConsumers, AdmitWrites, RetainSource] $ \interrupted -> do
        store <- acceptedStore
        history <- loadInventoryHistory store >>= either (assertFailure . show) pure
        let destinationFacts = ok (observationSet [(resourceId, ConfirmedAbsent absence)])
            decisions = ok (decideMigration candidate input history destinationFacts observations)
            proposal = ok (planChanges candidate decisions history destinationFacts)
        calls <- newIORef ([] :: [MigrationStage])
        let execution operation _ = case plannedAction operation of
              MigrateResource stage -> do
                modifyIORef' calls (<> [stage])
                pure (if stage == interrupted then AdapterEffectAmbiguous "lost stage acknowledgement"
                  else AdapterEffectCompleted)
              _ -> pure AdapterEffectCompleted
            recovery operation _ = pure (RecoveryProvedComplete
              (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
            registry = recordingRegistryWith (\_ _ -> pure (Right ())) execution recovery
        before <- readStoreSnapshot store >>= either (assertFailure . show) pure
        bundle <- prepareReview registry before proposal >>= either (assertFailure . show . NE.toList) pure
        _ <- publishReview store bundle >>= either (assertFailure . show) pure
        published <- readStoreSnapshot store >>= either (assertFailure . show) pure
        reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
        stopped <- applyReviewed store registry reviewed >>= either (assertFailure . show . NE.toList) pure
        transaction <- case stopped of
          StoppedAmbiguous value _ -> pure value
          other -> assertFailure ("stage did not stop ambiguously: " <> show (interrupted, other)) >> undefined
        resumeTransaction store registry transaction >>= either (assertFailure . show . NE.toList) pure
          >>= (@?= Converged transaction)
        executed <- readIORef calls
        executed @?= take (length executed) [PrepareDestination, BackUpSource, FenceWriters,
          TransferState, VerifyDestination, SwitchConsumers, AdmitWrites, RetainSource]
        length (filter (== interrupted) executed) @?= 1
  , testCase "changed source incarnation refuses admission before advancing history" $ do
      store <- acceptedStore
      history <- loadInventoryHistory store >>= either (assertFailure . show) pure
      let destinationFacts = ok (observationSet [(resourceId, ConfirmedAbsent absence)])
          decisions = ok (decideMigration candidate input history destinationFacts observations)
          proposal = ok (planChanges candidate decisions history destinationFacts)
          registry = recordingRegistryWith preflight
            (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure RecoverySafeToRetry)
          preflight operation _ = pure $ case plannedAction operation of
            MigrateResource BackUpSource -> Left "source UID changed"
            _ -> Right ()
      before <- readStoreSnapshot store >>= either (assertFailure . show) pure
      bundle <- prepareReview registry before proposal >>= either (assertFailure . show . NE.toList) pure
      _ <- publishReview store bundle >>= either (assertFailure . show) pure
      published <- readStoreSnapshot store >>= either (assertFailure . show) pure
      reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
      refused <- applyReviewed store registry reviewed
      assertBool "changed source was admitted" (isLeft refused)
      current <- readHead store >>= either (assertFailure . show) pure
      fmap headAccepted current @?= Just (headAccepted (storeSnapshotHead published))
      fmap headRetained current @?= Just (headRetained (storeSnapshotHead published))
  , testCase "dependent update completes between destination verification and consumer switch" $ do
      store <- acceptedStoreFor snapshotWithConsumer
      history <- loadInventoryHistory store >>= either (assertFailure . show) pure
      let destinationFacts = ok (observationSet
            [(resourceId, ConfirmedAbsent absence),
             (consumerId, ObservedDrifted physical (contentDigest "consumer-old"))])
          decisions = ok (decideMigration candidateWithConsumer input history destinationFacts observations)
          operations = proposalOperations (ok
            (planChanges candidateWithConsumer decisions history destinationFacts))
          stage name = case [operation | operation <- operations,
              plannedAction operation == MigrateResource name] of
            [operation] -> operation
            _ -> error "missing migration stage"
          consumerUpdate = case [operation | operation <- operations,
              plannedAction operation == UpdateResource,
              consumerId `elem` NE.toList (plannedResources operation)] of
            [operation] -> operation
            _ -> error "missing dependent update"
      plannedOperationId (stage VerifyDestination) `elem`
        plannedDependencies consumerUpdate @?= True
      plannedOperationId consumerUpdate `elem`
        plannedDependencies (stage SwitchConsumers) @?= True
  , testCase "versioned proposal binds old and new declarations and exact observations" $ do
      history <- acceptedHistory
      let validated = ok (validateMigrationInput candidate history observations input)
      case Map.lookup resourceId validated of
        Nothing -> assertFailure "migration was not validated"
        Just proof -> do
          snd (validatedSource proof) @?= oldResource
          validatedDestination proof @?= newResource
          validatedSourcePhysical proof @?= physical
          validatedDestinationAbsence proof @?= absence
          validatedContract proof @?= StatelessMigration
      let destinationFacts = ok (observationSet [(resourceId, ConfirmedAbsent absence)])
      reviewed <- either (assertFailure . show . NE.toList) pure
        (decideMigration candidate input history destinationFacts observations)
      let operations = proposalOperations (ok (planChanges candidate reviewed history destinationFacts))
          stages = [PrepareDestination, BackUpSource, FenceWriters, TransferState,
            VerifyDestination, SwitchConsumers, AdmitWrites, RetainSource]
          operationFor stage = case [operation | operation <- operations,
              plannedAction operation == MigrateResource stage] of
            [operation] -> operation
            _ -> error "missing or duplicate migration stage"
      length operations @?= length stages
      map (plannedDependencies . operationFor) (tail stages)
        @?= map (\stage -> [plannedOperationId (operationFor stage)]) (init stages)
      map (plannedRecovery . operationFor) [FenceWriters, SwitchConsumers, AdmitWrites]
        @?= replicate 3 OperatorRecovery
      assertCode "invalid-migration" (planChanges candidate reviewed history
        (ok (observationSet [(resourceId, ConfirmedAbsent (contentDigest "changed"))])))
      assertCode "invalid-migration" (validateMigrationInput candidate history observations
        (input {migrationTargets = [target {migrationSourcePhysical = ok (mkPhysicalIdentity "changed")}] }))
      assertCode "invalid-migration" (validateMigrationInput candidate history observations
        (input {migrationTargets = [target {migrationDestinationAbsence = contentDigest "changed"}] }))
      assertCode "invalid-migration" (validateMigrationInput candidate history observations
        (input {migrationTargets = [target {migrationContract = durableContract}] }))
      assertCode "migration-binding" (validateMigrationInput candidate history observations
        (input {migrationBinding = ContextBinding (ok (mkContextId "other")) (ok (mkName "project"))}))
      assertCode "duplicate-migration" (validateMigrationInput candidate history observations
        (input {migrationTargets = [target, target]}))
      let wrongOwner = (newResource :: ManagedResource) {owner = otherScope}
          wrongScope = ok (mkScopeDeclaration otherScope [ResourceBundle [Managed wrongOwner] [] [] [] [] []])
          changed = ok (composeInventory snapshot
            (RetireScope scope RetainResources :| [ReplaceScope wrongScope]))
      assertCode "invalid-migration" (validateMigrationInput changed history observations input)
  , testCase "proposal decoder rejects unknown fields and incomplete recovery contracts" $ do
      let valid = object
            [ "version" .= (1 :: Int), "candidate" .= ("compiled" :: Text)
            , "binding" .= binding
            , "resources" .= [object
                [ "resource" .= resourceId
                , "sourceAddress" .= address oldResource
                , "sourcePhysicalIdentity" .= physical
                , "destinationAddress" .= address newResource
                , "destinationAbsence" .= absence
                , "contract" .= object ["mode" .= ("stateless" :: Text)]
                ]]
            ]
          encode = ok . canonicalValue
      decodeMigrationInput (encode valid) @?= Right input
      assertBool "unknown proposal version accepted" (isLeft (decodeMigrationInput
        (encode (object ["version" .= (2 :: Int), "candidate" .= ("compiled" :: Text),
          "binding" .= binding, "resources" .= ([] :: [Text])]))))
      assertBool "incomplete durable contract accepted" (isLeft (decodeMigrationInput
        (encode (object ["version" .= (1 :: Int), "candidate" .= ("compiled" :: Text),
          "binding" .= binding, "resources" .= [object
            ["resource" .= resourceId, "sourceAddress" .= address oldResource,
             "sourcePhysicalIdentity" .= physical, "destinationAddress" .= address newResource,
             "destinationAbsence" .= absence,
             "contract" .= object ["mode" .= ("durable" :: Text)]]]]))))
  ]
  where
    ok :: Show e => Either e a -> a
    ok = either (error . show) id
    assertCode code result = case result of
      Left failures -> assertBool ("missing " <> show code)
        (code `elem` map planErrorCode (NE.toList failures))
      Right _ -> assertFailure ("accepted " <> show code)
    binding = ContextBinding (ok (mkContextId "migration")) (ok (mkName "project"))
    scope = ok (mkScopeId Platform "migration-source")
    otherScope = ok (mkScopeId Platform "migration-destination")
    dummyScope = ok (mkScopeId Platform "migration-seed")
    cluster = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    resourceId = mintResourceId scope (ok (mkLogicalKey "config")) (ok (mkName "resource"))
    consumerId = mintResourceId scope (ok (mkLogicalKey "consumer")) (ok (mkName "resource"))
    oldResource = ManagedResource resourceId scope KubernetesExecutor
      (Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "default")))
        (ok (mkName "old"))) []
      (NativeObject (contentDigest "old-native")) Retain Stateless Public [] []
      (SourceLocation "fixture" "old")
    newResource = oldResource
      { address = Kubernetes cluster "" (ok (mkName "configmap"))
          (Just (ok (mkName "default"))) (ok (mkName "new"))
      , spec = NativeObject (contentDigest "new-native")
      , source = SourceLocation "fixture" "new"
      }
    oldConsumer = ManagedResource consumerId scope KubernetesExecutor
      (Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "default")))
        (ok (mkName "consumer"))) []
      (NativeObject (contentDigest "consumer-old")) Retain Stateless Public
      [OrderedAfter resourceId] [] (SourceLocation "fixture" "consumer-old")
    newConsumer = oldConsumer
      {spec = NativeObject (contentDigest "consumer-new"), source = SourceLocation "fixture" "consumer-new"}
    oldScope = ok (mkScopeDeclaration scope [ResourceBundle [Managed oldResource] [] [] [] [] []])
    newScope = ok (mkScopeDeclaration scope [ResourceBundle [Managed newResource] [] [] [] [] []])
    snapshot = ok (mkScopeSnapshot binding
      (Map.singleton scope (ok (mkScopeGeneration 1), oldScope)) Map.empty)
    oldScopeWithConsumer = ok (mkScopeDeclaration scope
      [ResourceBundle [Managed oldResource, Managed oldConsumer] [] [] [] [] []])
    newScopeWithConsumer = ok (mkScopeDeclaration scope
      [ResourceBundle [Managed newResource, Managed newConsumer] [] [] [] [] []])
    snapshotWithConsumer = ok (mkScopeSnapshot binding
      (Map.singleton scope (ok (mkScopeGeneration 1), oldScopeWithConsumer)) Map.empty)
    candidateWithConsumer = ok (composeInventory snapshotWithConsumer
      (ReplaceScope newScopeWithConsumer :| []))
    candidate = ok (composeInventory snapshot (ReplaceScope newScope :| []))
    physical = ok (mkPhysicalIdentity "source-uid")
    absence = contentDigest "destination-absent"
    observations = ok (migrationObservationSet (Set.singleton resourceId)
      (ok (observationSet [(resourceId, ObservedPresent physical)]))
      (ok (observationSet [(resourceId, ConfirmedAbsent absence)])))
    target = MigrationTarget resourceId (address oldResource) physical
      (address newResource) absence StatelessMigration
    input = MigrationInput "compiled" binding [target]
    durableContract = DurableMigration (contentDigest "backup")
      (contentDigest "compatibility") (contentDigest "fence") (contentDigest "recovery")
    acceptedStore = acceptedStoreFor snapshot
    acceptedStoreFor sourceSnapshot = do
      store <- newMemoryStore
      _ <- initializeStore store binding "migration-test" >>= either (assertFailure . show) pure
      let seed = ok (composeInventory sourceSnapshot
            (ReplaceScope (ok (mkScopeDeclaration dummyScope [])) :| []))
      _ <- seedInventoryHistory store seed >>= either (assertFailure . show) pure
      pure store
    acceptedHistory = do
      store <- acceptedStore
      loadInventoryHistory store >>= either (assertFailure . show) pure
