-- | F35: an admitted transaction stopped by a later operation's refused
-- preflight gets a reviewed exit that does not require deleting the object
-- that caused the refusal. Since ADR 26 the legacy abandon decision is a close:
-- the refused operation never started or was journalled as failed with no
-- effect, an earlier operation completed, so the scope is kept (H2). Close is
-- refused while resume can still progress or an operation is unproved.
module InventoryRefusedPreflightRecoverySpec (inventoryRefusedPreflightRecoveryTests) where

import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
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
    ( [ testCase (show variant) (scenario variant)
      | variant <- [ForeignStillPresent, ForeignRemoved, CompletedOperation, EarlierUncertain, ExecuteRefusal]
      ]
        <> [ testCase "a retry the adapter proved safe that preflight then refuses is journalled as failed with no effect (F57)" retryRefused
           , testCase "a first preflight refusal stops with the adapter's reason (F88)" firstRefused
           ]
    )

-- | The adapter proves a retry safe, and its preflight refuses it: the driver
-- journals the refusal as a no-effect failure, so close by proof settles the
-- operation without asking the adapter again.
firstRefused :: IO ()
firstRefused = do
  store <- newMemoryStore
  let owner = ok (mkScopeId Standalone "refused")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      only = member owner cluster "service" []
      base = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)
      seed = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])) :| []))
      candidate = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration owner [ResourceBundle [only] [] [] [] [] []])) :| []))
      registry =
        recordingRegistryWith
          (\_ _ -> pure (Left "Kubernetes object changed since review; replan before mutation"))
          (\_ _ -> pure AdapterEffectCompleted)
          (\_ _ -> pure RecoverySafeToRetry)
  _ <- initializeStore store fixtureBinding "first-refused" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let proposal = ok (planChanges candidate noLifecycleDecisions history (ok (observationSet [(declarationId only, ConfirmedAbsent (contentDigest "absent"))])))
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
  applyReviewed store registry reviewed >>= expectRight >>= \case
    StoppedFailed _ _ (KnownNoEffect reason) -> reason @?= "adapter preflight refused: Kubernetes object changed since review; replan before mutation"
    other -> assertFailure ("the refused preflight did not stop failed: " <> show other)

retryRefused :: IO ()
retryRefused = do
  store <- newMemoryStore
  refusing <- newIORef False
  let owner = ok (mkScopeId Standalone "retry")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      only = member owner cluster "service" []
      base = ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)
      seed = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])) :| []))
      candidate = ok (composeInventory base (ReplaceScope (ok (mkScopeDeclaration owner [ResourceBundle [only] [] [] [] [] []])) :| []))
      registry =
        recordingRegistryWith
          (\_ _ -> (\refused -> if refused then Left "object changed since review" else Right ()) <$> readIORef refusing)
          (\_ _ -> pure (AdapterEffectAmbiguous "lost acknowledgement"))
          (\_ _ -> pure RecoverySafeToRetry)
  _ <- initializeStore store fixtureBinding "retry-refused" >>= expectRight
  _ <- seedInventoryHistory store seed >>= expectRight
  history <- loadInventoryHistory store >>= expectRight
  let proposal = ok (planChanges candidate noLifecycleDecisions history (ok (observationSet [(declarationId only, ConfirmedAbsent (contentDigest "absent"))])))
  snapshot <- readStoreSnapshot store >>= expectRight
  bundle <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store bundle >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- either (assertFailure . show . NE.toList) pure (verifyReview published bundle)
  (transaction, operation) <-
    applyReviewed store registry reviewed >>= expectRight >>= \case
      StoppedAmbiguous tx op -> pure (tx, op)
      other -> assertFailure (show other) >> undefined
  writeIORef refusing True
  resumeTransaction store registry transaction >>= expectRight >>= (@?= StoppedFailed transaction operation (KnownNoEffect "adapter preflight refused: object changed since review"))
  after <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> undefined) pure
  raw <- readJournalPrefix store (headSequence after) >>= expectRight
  events <- either (assertFailure . show) pure (traverse decodeJournalEvent raw)
  Map.lookup operation (operationStates transaction events) @?= Just (Failed (KnownNoEffect "adapter preflight refused: object changed since review"))

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
    _ | variant `elem` [ForeignStillPresent, ExecuteRefusal, CompletedOperation] -> do
      void (expectRight recovered)
      -- The first operation completed, so the scope keeps the review's
      -- desired revision and its created object stays owned.
      headAccepted after @?= headAccepted before
      headActiveTransaction after @?= Nothing
      headExecutorClaim after @?= Nothing
      raw <- readJournalPrefix store (headSequence after) >>= expectRight
      events <- either (assertFailure . show) pure (traverse decodeJournalEvent raw)
      let states = operationStates transaction events
      Map.lookup firstOperation states @?= Just (Completed (proofFor firstOperation))
      assertBool "the refused operation took effect" (Map.lookup secondOperation states `elem` [Nothing, Just (Failed (KnownNoEffect "fields managed by another writer"))])
      assertBool
        "the transaction has no close event"
        (any (\event -> eventTransaction event == transaction && isNothing (eventOperation event) && closedMarker (eventState event)) events)
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

closedMarker :: OperationState -> Bool
closedMarker = \case
  OperatorResolved marker -> "closed:" `T.isPrefixOf` marker
  _ -> False
