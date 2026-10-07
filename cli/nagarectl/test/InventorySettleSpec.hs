-- | ADR 26 obligations checked directly: the driver never executes a
-- verification (O6), and the Kubernetes proof classes a model run found
-- unproved (F66).
module InventorySettleSpec (inventorySettleTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (Object), decode, encode, toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding, recordingRegistryWith)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (KubernetesMutation (..), KubernetesState (..), settleMutation)
import Nagare.Inventory.Adapters.KubernetesProof (kubectlRefusal)
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal (mkOperationId)
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
    , testCase "a create that finds an object not stamped as its own settles as target gone (F66)" $ do
        let owner = ok (mkScopeId Platform "created")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            created = mintResourceId owner (ok (mkLogicalKey "service")) (ok (mkName "resource"))
            other = mintResourceId owner (ok (mkLogicalKey "history")) (ok (mkName "resource"))
            address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName "service"))
            digest = contentDigest "reviewed"
            mutation = KubernetesMutation 1 (ok (mkOperationId "op-created")) digest CreateResource created address "{}" digest (KubernetesAbsent (contentDigest "absent")) Nothing Nothing
            -- What recovery answers for a create whose address is now filled.
            settle current = settleMutation mutation current current Nothing (RecoveryUnresolved "Kubernetes object changed since review; replan before mutation")
            found = ok (mkPhysicalIdentity "found-uid")
        -- A create is conditional on an empty address and stamps what it
        -- writes as its own, so an unstamped object, or one stamped for
        -- another member, proves the create's write is not live there.
        settle (KubernetesPresent found "1" Nothing (contentDigest "foreign")) @?= SettledTargetGone (Just found)
        settle (KubernetesNotReady found "1" (Just other) digest) @?= SettledTargetGone (Just found)
        -- An object with the create's own stamp may be its write, edited.
        case settle (KubernetesPresent found "2" (Just created) (contentDigest "edited")) of
          SettledUnknown _ _ -> pure ()
          settled -> assertFailure ("an object stamped as the create's own settled as " <> show settled)
    , testCase "an update settles by the stamp on the reviewed object, whatever its resourceVersion (F67)" $ do
        let owner = ok (mkScopeId Platform "updated")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            updated = mintResourceId owner (ok (mkLogicalKey "workload")) (ok (mkName "resource"))
            address = Kubernetes cluster "apps" (ok (mkName "statefulset")) (Just (ok (mkName "system"))) (ok (mkName "workload"))
            reviewed = ok (mkPhysicalIdentity "reviewed-uid")
            stampBefore = contentDigest "before"
            stampNew = contentDigest "reviewed"
            update stamp = KubernetesMutation 1 (ok (mkOperationId "op-updated")) stampNew UpdateResource updated address "{}" stampNew (KubernetesPresent reviewed "4" (Just updated) (contentDigest "whole-object-before")) Nothing (Just stamp)
            -- A status write moved resourceVersion, and with it the whole-object digest.
            churned = KubernetesNotReady reviewed "5" (Just updated) (contentDigest "whole-object-after")
            settle mutation current stamp = settleMutation mutation current current stamp (RecoveryUnresolved "Kubernetes object changed since review; replan before mutation")
            unknown mutation current stamp = case settle mutation current stamp of
              SettledUnknown _ _ -> pure ()
              settled -> assertFailure ("settled as " <> show settled <> " under stamp " <> show stamp)
        -- RES-4 U3: the stamp is written with the spec, so it says which write is live.
        settle (update stampBefore) churned (Just stampBefore) @?= SettledNoEffect "the reviewed object still carries its before-state stamp"
        settle (update stampBefore) churned (Just stampNew) @?= SettledLanded reviewed
        unknown (update stampBefore) churned (Just (contentDigest "another"))
        unknown (update stampBefore) churned Nothing
        -- A stamp rolled back to the before digest is the before-state now (ADR 26 §1).
        settle (update stampBefore) (KubernetesPresent reviewed "7" (Just updated) (contentDigest "whole-object-after")) (Just stampBefore) @?= SettledNoEffect "the reviewed object still carries its before-state stamp"
        -- A drift repair (before stamp already the reviewed one) proves nothing by stamp.
        unknown (update stampNew) churned (Just stampNew)
        -- Another, unstamped object is still target gone (F68).
        settle (update stampBefore) (KubernetesPresent (ok (mkPhysicalIdentity "other-uid")) "1" Nothing (contentDigest "x")) Nothing @?= SettledTargetGone (Just (ok (mkPhysicalIdentity "other-uid")))
        -- An update must record its before stamp.
        case toJSON (update stampBefore) of
          Object root -> assertBool "an update without its before stamp decoded" (isNothing (decode (encode (Object (KM.delete "beforeStamp" root))) :: Maybe KubernetesMutation))
          other -> assertFailure (show other)
    , testCase "a write the API server refused with a 4xx answer had no effect; only a missing answer is ambiguous (G4)" $ do
        -- RES-4 U4 (E1, E3, E8, E13): every 4xx refusal left the object unchanged.
        forM_
          [ "Error from server (Conflict): Operation cannot be fulfilled on configmaps \"x\": the object has been modified"
          , "Error from server (Invalid): ConfigMap \"x\" is invalid: metadata.uid: field is immutable"
          , "Error from server (AlreadyExists): configmaps \"x\" already exists"
          , "Error from server (NotFound): configmaps \"x\" not found"
          , "Error from server (Forbidden): configmaps \"x\" is forbidden"
          , "Error from server (BadRequest): the server rejected our request"
          , "error: Operation cannot be fulfilled on deployments.apps \"x\": the object has been modified"
          , "error: Apply failed with 2 conflicts: conflicts with \"kubectl-edit\" using v1: .data.k"
          ]
          $ \answer -> assertBool (T.unpack answer) (isJust (kubectlRefusal ("Warning: noise\n" <> answer <> "\n")))
        -- Transport failures, timeouts and 5xx can hide a committed write.
        forM_
          [ "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout"
          , "Error from server (InternalError): an error on the server has prevented the request from succeeding"
          , "Error from server (ServiceUnavailable): the server is currently unable to handle the request"
          , "Error from server (Timeout): the server was unable to return a response in the time allotted"
          ]
          $ \answer -> kubectlRefusal answer @?= Nothing
    , testCase "an update whose target is replaced by an object not stamped as its own settles as target gone (F68)" $ do
        let owner = ok (mkScopeId Platform "updated")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            updated = mintResourceId owner (ok (mkLogicalKey "service")) (ok (mkName "resource"))
            other = mintResourceId owner (ok (mkLogicalKey "history")) (ok (mkName "resource"))
            address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName "service"))
            reviewed = ok (mkPhysicalIdentity "reviewed-uid")
            found = ok (mkPhysicalIdentity "found-uid")
            digest = contentDigest "reviewed"
            mutation = KubernetesMutation 1 (ok (mkOperationId "op-updated")) digest UpdateResource updated address "{}" digest (KubernetesPresent reviewed "4" (Just updated) (contentDigest "before")) Nothing Nothing
            settle current = settleMutation mutation current current Nothing (RecoveryUnresolved "Kubernetes object changed since review; replan before mutation")
            unknown current = case settle current of
              SettledUnknown _ _ -> pure ()
              settled -> assertFailure ("settled as " <> show settled <> ": " <> show current)
        -- The write is conditional on the reviewed UID, so another object
        -- that is not stamped as this member proves the write is not live.
        settle (KubernetesPresent found "1" Nothing (contentDigest "foreign")) @?= SettledTargetGone (Just found)
        settle (KubernetesNotReady found "1" (Just other) digest) @?= SettledTargetGone (Just found)
        -- Another UID stamped as this member is the F56 replacement path.
        settle (KubernetesPresent found "1" (Just updated) digest) @?= SettledTargetGone (Just found)
        -- The reviewed UID, whatever its stamp now, is never gone.
        unknown (KubernetesPresent reviewed "5" Nothing (contentDigest "edited"))
        unknown (KubernetesPresent reviewed "5" (Just updated) (contentDigest "edited"))
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
