-- | ADR 26 obligations checked directly: the driver never executes a
-- verification (O6).
module InventorySettleSpec (inventorySettleTests) where

import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Test.Tasty
import Test.Tasty.HUnit

inventorySettleTests :: TestTree
inventorySettleTests =
  testGroup
    "settlement obligations (ADR 26)"
    [ testCase "the driver never executes a verification (O6)" $ do
        executed <- newIORef []
        store <- newMemoryStore
        _ <- initializeStore store fixtureBinding "verify-never-executes" >>= expectRight
        let owner = ok (mkScopeId Platform "verified")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            resource = member owner cluster "settings"
            changing = member owner cluster "release"
            scopeOf members = ok (mkScopeDeclaration owner [ResourceBundle members [] [] [] [] []])
            registry =
              recordingRegistryWith
                (\_ _ -> pure (Right ()))
                (\operation _ -> modifyIORef' executed (plannedAction operation :) >> pure AdapterEffectCompleted)
                (\_ _ -> pure RecoverySafeToRetry)
            review members facts = do
              history <- loadInventoryHistory store >>= expectRight
              let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
                  candidate = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (ReplaceScope (scopeOf members) :| []))
              planning <- loadInventoryPlanningHistory store candidate >>= expectRight
              snapshot <- readStoreSnapshot store >>= expectRight
              bundle <- prepareReview registry snapshot (ok (planChanges candidate noLifecycleDecisions planning (ok (observationSet facts)))) >>= expectRight
              _ <- publishReview store bundle >>= expectRight
              published <- readStoreSnapshot store >>= expectRight
              reviewed <- expectRight (verifyReview published bundle)
              _ <- applyReviewed store registry reviewed >>= expectRight
              pure [plannedAction (reviewPlannedOperation entry) | entry <- reviewOperations (reviewedDocument reviewed)]
        _ <- review [resource, changing] [(declarationId member', ConfirmedAbsent (contentDigest "absent")) | member' <- [resource, changing]]
        -- The scope is left accepted but not converged, as a stopped review
        -- leaves it, so an unchanged review verifies its members.
        accepted <- readHead store >>= expectRight >>= maybe (assertFailure "head missing" >> pure (error "unreachable")) pure
        _ <- replaceHeadIfGenerationMatches store (Just (headGeneration accepted)) (accepted {headConverged = Map.empty, headGeneration = headGeneration accepted + 1}) >>= expectRight
        writeIORef executed []
        actions <- review [resource, changing] [(declarationId member', ObservedPresent (ok (mkPhysicalIdentity "uid"))) | member' <- [resource, changing]]
        assertBool ("the review does not verify: " <> show actions) (not (null actions) && all (== VerifyResource) actions)
        readIORef executed >>= (@?= [])
    ]

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
expectRight = either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
