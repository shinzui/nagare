-- | F35: an admitted transaction stopped by a later operation's refused
-- preflight gets a reviewed exit that does not require deleting the object
-- that caused the refusal. An operation the adapter journalled as failed with
-- no effect at execute time is abandoned on that journal proof, even while its
-- preflight passes.
module InventoryRefusedPreflightRecoverySpec (inventoryRefusedPreflightRecoveryTests) where

import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

data Variant = ForeignStillPresent | ForeignRemoved | CompletedOperation | EarlierUncertain | ExecuteRefusal
  deriving stock (Eq, Show)

inventoryRefusedPreflightRecoveryTests :: TestTree
inventoryRefusedPreflightRecoveryTests =
  testGroup
    "refused preflight after admission (F35)"
    [ testCase (show variant) (scenario variant)
    | variant <- [ForeignStillPresent, ForeignRemoved, CompletedOperation, EarlierUncertain, ExecuteRefusal]
    ]

scenario :: Variant -> IO ()
scenario variant = do
  store <- newMemoryStore
  foreignPresent <- newIORef True
  let owner = ok (mkScopeId Standalone "restore")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      first' = member owner cluster "service" []
      second = member owner cluster "volume" [OrderedAfter (declarationId first')]
      secondId = declarationId second
      touches resource operation = resource `elem` NE.toList (plannedResources operation)
      base = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)
      seed = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])) :| []))
      candidate = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration owner [ResourceBundle [first', second] [] [] [] [] []])) :| []))
      registry =
        recordingRegistryWith
          ( \operation _ -> do
              present <- readIORef foreignPresent
              pure
                ( if touches secondId operation && present && variant /= ExecuteRefusal
                    then Left "object changed since review"
                    else Right ()
                )
          )
          ( \operation _ ->
              pure
                ( if variant == EarlierUncertain && not (touches secondId operation)
                    then AdapterEffectAmbiguous "lost acknowledgement"
                    else
                      if variant == ExecuteRefusal && touches secondId operation
                        then AdapterEffectFailed (KnownNoEffect "fields managed by another writer")
                        else AdapterEffectCompleted
                )
          )
          (\_ _ -> pure (RecoveryUnresolved "no proof"))
  _ <- initializeStore store fixtureBinding "refused-preflight" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let observations =
        ok
          ( observationSet
              [ (declarationId first', ConfirmedAbsent (contentDigest "absent"))
              , (secondId, ConfirmedAbsent (contentDigest "absent"))
              ]
          )
      proposal = ok (planChanges candidate noLifecycleDecisions history observations)
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
  let operations = map reviewPlannedOperation (reviewOperations (reviewedDocument reviewed))
      secondOperation = maybe (error "fixture") plannedOperationId (find (touches secondId) operations)
      firstOperation = maybe (error "fixture") plannedOperationId (find (not . touches secondId) operations)
  result <- applyReviewed store registry reviewed >>= expectRight
  transaction <- case (variant, result) of
    (EarlierUncertain, StoppedAmbiguous tx op) -> (op @?= firstOperation) >> pure tx
    (EarlierUncertain, other) -> assertFailure (show other) >> undefined
    (_, StoppedFailed tx op (KnownNoEffect _)) -> (op @?= secondOperation) >> pure tx
    (_, other) -> assertFailure (show other) >> undefined
  before <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  headActiveTransaction before @?= Just (transactionIdText transaction)
  when (variant == ForeignRemoved) (writeIORef foreignPresent False)
  let selected = if variant == CompletedOperation then firstOperation else secondOperation
      decision = OperatorRecoveryInput transaction selected (reviewDigestFor reviewed) AbandonRefusedOperation
  recovered <- recordOperatorRecovery store registry decision False
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  headConverged after @?= headConverged before
  case variant of
    _ | variant `elem` [ForeignStillPresent, ExecuteRefusal] -> do
      void (expectRight recovered)
      -- Like other abandonments, the never-converged review loses acceptance.
      headAccepted after @?= headConverged before
      headActiveTransaction after @?= Nothing
      headExecutorClaim after @?= Nothing
      raw <- readJournalPrefix store (headSequence after) >>= expectRight
      events <- either (assertFailure . show) pure (traverse decodeJournalEvent raw)
      let states = operationStates transaction events
      Map.lookup firstOperation states @?= Just (Completed (proofFor firstOperation))
      Map.lookup secondOperation states @?= Just (OperatorResolved "abandoned-refused-operation")
      -- The store accepts a new review again without removing the object.
      void (loadInventoryPlanningHistory store candidate >>= expectRight)
    ForeignRemoved -> do
      assertBool "abandonment accepted although the preflight passes now" (isLeft recovered)
      headAccepted after @?= headAccepted before
      headActiveTransaction after @?= Just (transactionIdText transaction)
      resumed <- resumeTransaction store registry transaction >>= expectRight
      resumed @?= Converged transaction
    _ -> do
      assertBool "unsafe abandonment accepted" (isLeft recovered)
      headAccepted after @?= headAccepted before
      headActiveTransaction after @?= Just (transactionIdText transaction)

member :: ScopeId -> ResourceId -> Text -> [Dependency] -> Declaration
member owner cluster role dependencies =
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
      , dependencies = dependencies
      , delegations = []
      , source = SourceLocation "test" role
      }

proofFor :: OperationId -> ContentDigest
proofFor = contentDigest . TE.encodeUtf8 . operationIdText

expectRight :: (Show e) => Either e a -> IO a
expectRight result = case result of
  Left err -> assertFailure (show err) >> pure (error "unreachable")
  Right value -> pure value

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

reviewDigestFor :: ReviewedPlan -> ContentDigest
reviewDigestFor = contentDigest . encodeReviewDocument . reviewedDocument
