-- | F40: a scope that owns a composed contribution target (here the access
-- backend map granted by 'BackendMapGrant') retires with that target retained,
-- and the retained member reloads from history although no raw bundle lists it.
-- BUG-9: a migration Job named after its image is retained, without a
-- decision, when a new image replaces it.
module InventoryContributionRetirementSpec (inventoryContributionRetirementTests) where

import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), RecoveryClass (VerifyBeforeRetry), RetirementIntent (..), Sensitivity (Public))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryContributionRetirementTests :: TestTree
inventoryContributionRetirementTests =
  testGroup
    "scope retirement of composed and host members (F40)"
    [ testCase "scope retirement retains its composed contribution target and reloads it (F40)" contributionTarget
    , testCase "scope retirement retains a host system as history (F40)" hostSystem
    , testGroup
        "superseded migration Jobs (BUG-9)"
        [ testCase "a new migration Job image retains the previous Job without a decision" supersededJob
        , testCase "any other removed member still needs a lifecycle decision" unrelatedRemoval
        ]
    ]

supersededJob :: Assertion
supersededJob = do
  store <- acceptedAuth [authJob "shomei-migrate-old"] [authMigration "shomei-migrate-old"]
  history <- loadInventoryHistory store >>= expectRight
  let next = authReplacement history [authJob "shomei-migrate-new"] [authMigration "shomei-migrate-new"]
      observed =
        ok
          ( observationSet
              [ (authJobId "shomei-migrate-old", ObservedPresent oldJobPhysical)
              , (authJobId "shomei-migrate-new", ConfirmedAbsent (contentDigest "absent"))
              ]
          )
  proposal <- expectRight (planChanges next noLifecycleDecisions history observed)
  assertBool
    "the previous Job is retained, never deleted"
    (RetireResource `notElem` map plannedAction (proposalOperations proposal))
  acceptWith (observingRegistry KubernetesExecutor oldJobPhysical) store proposal
  retained <- loadInventoryHistory store >>= expectRight
  fmap (retainedPhysical . fst) (Map.lookup (authJobId "shomei-migrate-old") (historyRetained retained))
    @?= Just oldJobPhysical

unrelatedRemoval :: Assertion
unrelatedRemoval = do
  store <- acceptedAuth [authJob "shomei-migrate-old", authJob "settings"] [authMigration "shomei-migrate-old"]
  history <- loadInventoryHistory store >>= expectRight
  let next = authReplacement history [authJob "shomei-migrate-old"] [authMigration "shomei-migrate-old"]
      observed = ok (observationSet [(authJobId name, ObservedPresent oldJobPhysical) | name <- ["shomei-migrate-old", "settings"]])
  case planChanges next noLifecycleDecisions history observed of
    Left errors -> map planErrorCode (NE.toList errors) @?= ["retirement-required"]
    Right _ -> assertFailure "a removed Job no migration ran on was retained without a decision"

authOwner :: ScopeId
authOwner = ok (mkScopeId Platform "auth")

authJobId :: Text -> ResourceId
authJobId name = mintResourceId authOwner (ok (mkLogicalKey "auth")) (ok (mkName name))

authJob :: Text -> Declaration
authJob name =
  Managed
    ManagedResource
      { identity = authJobId name
      , owner = authOwner
      , executor = KubernetesExecutor
      , address =
          Kubernetes
            (mintResourceId authOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster")))
            "batch"
            (ok (mkName "job"))
            (Just (ok (mkName "nagare-system")))
            (ok (mkName name))
      , aliases = []
      , spec = NativeObject (contentDigest (TE.encodeUtf8 name))
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = []
      , delegations = []
      , source = SourceLocation "test" name
      }

authMigration :: Text -> DeclaredOperation
authMigration name =
  DeclaredOperation
    (mintResourceId authOwner (ok (mkLogicalKey "auth")) (ok (mkName ("proof-" <> name))))
    (authJobId name :| [])
    [ContentInput (contentDigest (TE.encodeUtf8 name))]
    VerifyBeforeRetry
    SchemaMigration

authDeclaration :: [Declaration] -> [DeclaredOperation] -> ScopeDeclaration
authDeclaration declarations operations = ok (mkScopeDeclaration authOwner [ResourceBundle declarations [] [] [] operations []])

-- | A store whose auth scope declares these members, created and converged.
acceptedAuth :: [Declaration] -> [DeclaredOperation] -> IO InventoryStore
acceptedAuth declarations operations = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "migration-supersession" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  let initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope (authDeclaration declarations operations) :| []))
      absent = ok (observationSet [(declarationId declaration, ConfirmedAbsent (contentDigest "absent")) | declaration <- declarations])
  acceptWith (observingRegistry KubernetesExecutor oldJobPhysical) store (ok (planChanges initial noLifecycleDecisions emptyHistory absent))
  pure store

authReplacement :: InventoryHistory -> [Declaration] -> [DeclaredOperation] -> CompositionCandidate
authReplacement history declarations operations =
  let accepted = Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)
   in ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (ReplaceScope (authDeclaration declarations operations) :| []))

oldJobPhysical :: PhysicalIdentity
oldJobPhysical = ok (mkPhysicalIdentity "job-uid-old")

hostSystem :: Assertion
hostSystem = do
  let owner = ok (mkScopeId Platform "host")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      system =
        ManagedResource
          { identity = mintResourceId owner (ok (mkLogicalKey "nixos-system")) (ok (mkName "system"))
          , owner = owner
          , executor = HostExecutor
          , address = Host cluster (ok (mkName "system"))
          , aliases = []
          , spec = NativeObject (contentDigest "closure")
          , lifecycle = Retain
          , dataPolicy = Stateless
          , sensitivity = Public
          , dependencies = []
          , delegations = []
          , source = SourceLocation "test" "host"
          }
      target = system ^. #identity
      scope = ok (mkScopeDeclaration owner [ResourceBundle [Managed system] [] [] [] [] []])
      physical = ok (mkPhysicalIdentity ("accepted:" <> resourceIdText target))
  retained <- retireOwner HostExecutor scope owner target physical
  fmap (retainedPhysical . fst) (Map.lookup target (historyRetained retained)) @?= Just physical

retireOwner :: Executor -> ScopeDeclaration -> ScopeId -> ResourceId -> PhysicalIdentity -> IO InventoryHistory
retireOwner executor scope owner target physical = do
  let initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
      registry = observingRegistry executor physical
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "host-retirement" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  acceptWith registry store (ok (planChanges initial noLifecycleDecisions emptyHistory (ok (observationSet [(target, ConfirmedAbsent (contentDigest "absent"))]))))
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)
      candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (RetireScope owner RetainResources :| []))
      observed = ok (observationSet [(target, ObservedPresent physical)])
  decisions <- expectRight (decideRetirement candidate history observed)
  acceptWith registry store =<< expectRight (planChanges candidate decisions history observed)
  loadInventoryHistory store >>= expectRight

acceptWith :: AdapterRegistry -> InventoryStore -> ChangeProposal -> IO ()
acceptWith registry store proposal = do
  snapshot <- readStoreSnapshot store >>= expectRight
  review <- prepareReview registry snapshot proposal >>= expectRight
  _ <- publishReview store review >>= expectRight
  published <- readStoreSnapshot store >>= expectRight
  reviewed <- expectRight (verifyReview published review)
  _ <- applyReviewed store registry reviewed >>= expectRight
  pure ()

observingRegistry :: Executor -> PhysicalIdentity -> AdapterRegistry
observingRegistry executor physical =
  ok
    ( mkAdapterRegistry
        [ Adapter
            { adapterExecutor = executor
            , adapterIdentity = "recording"
            , adapterVersion = "1"
            , adapterObserve = \resources -> pure (observationSet [(resource, ObservedPresent physical) | resource <- resources])
            , adapterPrepare = \operation -> pure (Right (PreparedNative (either (error . T.unpack) id (canonicalValue (toJSON operation))) "recording adapter"))
            , adapterPreflight = \_ _ -> pure (Right ())
            , adapterExecute = \_ _ -> pure AdapterEffectCompleted
            , adapterVerify = \operation _ -> pure (Right (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
            , adapterSettle = Nothing
            , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (contentDigest (TE.encodeUtf8 (operationIdText (plannedOperationId operation)))))
            }
        ]
    )

contributionTarget :: Assertion
contributionTarget = do
  let owner = ok (mkScopeId Platform "auth")
      cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      target = backendMapResourceId owner
      scope = ok (mkScopeDeclaration owner [ResourceBundle [] [] [] [] [] [BackendMapGrant cluster]])
      physical = ok (mkPhysicalIdentity "backend-map-uid")
      initial =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty))
              (ReplaceScope scope :| [])
          )
  assertBool
    "the backend map is a composed target, not a raw bundle member"
    ( target `elem` map declarationId (inventoryDeclarations (candidateInventory initial))
        && target `notElem` [declarationId declaration | bundle <- scopeBundles scope, declaration <- bundle ^. #declarations]
    )
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "contribution-retirement" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  let absent = ok (observationSet [(target, ConfirmedAbsent (contentDigest "absent"))])
  accept store (ok (planChanges initial noLifecycleDecisions emptyHistory absent))
  history <- loadInventoryHistory store >>= expectRight
  let accepted = Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)
      candidate =
        ok
          ( composeInventory
              (ok (mkScopeSnapshot fixtureBinding accepted Map.empty))
              (RetireScope owner RetainResources :| [])
          )
      observed = ok (observationSet [(target, ObservedPresent physical)])
  decisions <- expectRight (decideRetirement candidate history observed)
  proposal <- expectRight (planChanges candidate decisions history observed)
  accept store proposal
  retained <- loadInventoryHistory store >>= expectRight
  fmap (retainedPhysical . fst) (Map.lookup target (historyRetained retained)) @?= Just physical
  fmap (declarationId . Managed . snd) (Map.lookup target (historyRetained retained)) @?= Just target
  where
    accept store proposal = do
      snapshot <- readStoreSnapshot store >>= expectRight
      review <- prepareReview registry snapshot proposal >>= expectRight
      _ <- publishReview store review >>= expectRight
      published <- readStoreSnapshot store >>= expectRight
      reviewed <- expectRight (verifyReview published review)
      _ <- applyReviewed store registry reviewed >>= expectRight
      pure ()
    registry =
      ok
        ( mkAdapterRegistry
            [ Adapter
                { adapterExecutor = KubernetesExecutor
                , adapterIdentity = "recording"
                , adapterVersion = "1"
                , adapterObserve = \resources ->
                    pure (observationSet [(resource, ObservedPresent (ok (mkPhysicalIdentity "backend-map-uid"))) | resource <- resources])
                , adapterPrepare = \operation -> pure (Right (PreparedNative (either (error . T.unpack) id (canonicalValue (toJSON operation))) "recording adapter"))
                , adapterPreflight = \_ _ -> pure (Right ())
                , adapterExecute = \_ _ -> pure AdapterEffectCompleted
                , adapterVerify = \operation _ -> pure (Right (proof operation))
                , adapterSettle = Nothing
                , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (proof operation))
                }
            ]
        )
    proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
