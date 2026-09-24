module InventoryLifecycleSpec (inventoryLifecycleTests) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Lifecycle
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryLifecycleTests :: TestTree
inventoryLifecycleTests = testGroup "inventory lifecycle"
  [ testCase "migration observations retain both incarnations of one logical resource" $ do
      let source = ObservedPresent physical
          destination = ConfirmedAbsent (contentDigest "destination-absent")
          sources = ok (observationSet [(resourceId, source)])
          destinations = ok (observationSet [(resourceId, destination)])
          paired = ok (migrationObservationSet (Set.singleton resourceId) sources destinations)
      Map.lookup resourceId (migrationObservationMap paired) @?= Just (source, destination)
      assertBool "missing source was accepted" (isLeft (migrationObservationSet
        (Set.singleton resourceId) (ok (observationSet [])) destinations))
      assertBool "missing destination was accepted" (isLeft (migrationObservationSet
        (Set.singleton resourceId) sources (ok (observationSet []))))
      assertBool "unexpected source was accepted" (isLeft (migrationObservationSet
        Set.empty sources (ok (observationSet []))))
  , testCase "adoption DTO is versioned and rejects unknown authority fields" $ do
      let valid = object
            [ "version" .= (1 :: Int)
            , "candidate" .= ("compiled" :: Text)
            , "binding" .= binding
            , "resources" .= [object
                ["resource" .= resourceId, "address" .= address resource,
                 "physicalIdentity" .= physical]]
            ]
          encode value = ok (canonicalValue value)
      decodeAdoptionInput (encode valid) @?= Right input
      let invalid = object
            [ "version" .= (2 :: Int)
            , "candidate" .= ("compiled" :: Text)
            , "binding" .= binding
            , "resources" .= ([] :: [Text])
            ]
      assertBool "unknown version accepted" (isLeft (decodeAdoptionInput (encode invalid)))
      assertBool "unknown field accepted" (isLeft (decodeAdoptionInput
        (encode (object ["version" .= (1 :: Int), "candidate" .= ("compiled" :: Text),
          "binding" .= binding, "resources" .= ([] :: [Text]), "owner" .= ("forged" :: Text)]))))
  , testCase "adoption binds declaration, context, and fresh physical incarnation" $ do
      store <- newMemoryStore
      _ <- initializeStore store binding "lifecycle-test" >>= expectRight
      history <- loadInventoryHistory store >>= expectRight
      let fact = ObservedUnowned physical
          observations = ok (observationSet [(resourceId, fact)])
          decisions = decideAdoption candidate history observations input
      approved <- expectRight decisions
      map plannedAction (proposalOperations (ok (planChanges candidate approved history observations)))
        @?= [AdoptResource]
      assertCode "stale-lifecycle-evidence" (planChanges candidate approved history
        (ok (observationSet [(resourceId, ObservedUnowned (ok (mkPhysicalIdentity "uid-2")))])))
      let changedResource = resource {address = otherAddress}
          changedDeclaration = ok (mkScopeDeclaration scope
            [ResourceBundle [Managed changedResource] [] [] [] [] []])
          changedCandidate = ok (composeInventory
            (ok (mkScopeSnapshot binding Map.empty Map.empty))
            (ReplaceScope changedDeclaration :| []))
      assertCode "stale-lifecycle-candidate"
        (planChanges changedCandidate approved history observations)
      assertCode "duplicate-lifecycle-decision" (combineDecisions approved approved)
      separatelyReviewed <- expectRight (validateLifecycleDecisions
        changedCandidate history observations [])
      assertCode "stale-lifecycle-context" (combineDecisions approved separatelyReviewed)
      otherStore <- newMemoryStore
      _ <- initializeStore otherStore binding "other-lifecycle-test" >>= expectRight
      otherHistory <- loadInventoryHistory otherStore >>= expectRight
      assertCode "stale-lifecycle-history"
        (planChanges candidate approved otherHistory observations)
      otherReviewed <- expectRight (validateLifecycleDecisions
        candidate otherHistory observations [])
      assertCode "stale-lifecycle-context" (combineDecisions approved otherReviewed)
      assertCode "adoption-incarnation" (decideAdoption candidate history observations
        (input {adoptionTargets = [target {adoptionPhysical = ok (mkPhysicalIdentity "other")}] }))
      assertCode "adoption-declaration" (decideAdoption candidate history observations
        (input {adoptionTargets = [target {adoptionAddress = otherAddress}] }))
      assertCode "adoption-binding" (decideAdoption candidate history observations
        (input {adoptionBinding = ContextBinding (ok (mkContextId "other")) (ok (mkName "project"))}))
      assertCode "duplicate-adoption" (decideAdoption candidate history observations
        (input {adoptionTargets = [target, target]}))
  , testCase "disjoint adoption decisions combine into one reviewed change" $ do
      store <- newMemoryStore
      _ <- initializeStore store binding "combined-lifecycle-test" >>= expectRight
      history <- loadInventoryHistory store >>= expectRight
      let anotherId = mintResourceId scope (ok (mkLogicalKey "other")) (ok (mkName "resource"))
          another = resource {identity = anotherId, address = otherAddress}
          combinedDeclaration = ok (mkScopeDeclaration scope
            [ResourceBundle [Managed resource, Managed another] [] [] [] [] []])
          combinedCandidate = ok (composeInventory
            (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope combinedDeclaration :| []))
          anotherPhysical = ok (mkPhysicalIdentity "uid-other")
          observed = ok (observationSet
            [(resourceId, ObservedUnowned physical), (anotherId, ObservedUnowned anotherPhysical)])
      firstDecision <- expectRight (decideAdoption combinedCandidate history observed input)
      secondDecision <- expectRight (decideAdoption combinedCandidate history observed
        (input {adoptionTargets = [AdoptionTarget anotherId otherAddress anotherPhysical Nothing]}))
      combined <- expectRight (combineDecisions firstDecision secondDecision)
      map plannedAction (proposalOperations (ok
        (planChanges combinedCandidate combined history observed)))
        @?= [AdoptResource, AdoptResource]
  ]
  where
    ok :: Show e => Either e a -> a
    ok = either (error . show) id
    expectRight :: Show e => Either e a -> IO a
    expectRight = either (assertFailure . show) pure
    assertCode code result = case result of
      Left errors -> assertBool ("missing " <> show code)
        (code `elem` map planErrorCode (NE.toList errors))
      Right _ -> assertFailure ("accepted " <> show code)
    binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))
    scope = ok (mkScopeId Platform "adoption")
    cluster = mintResourceId scope (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
    resourceId = mintResourceId scope (ok (mkLogicalKey "config")) (ok (mkName "resource"))
    resource = ManagedResource resourceId scope KubernetesExecutor
      (Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "default")))
        (ok (mkName "legacy"))) []
      (NativeObject (contentDigest "desired")) Retain Stateless Public [] []
      (SourceLocation "fixture" "legacy")
    otherAddress = Kubernetes cluster "" (ok (mkName "configmap"))
      (Just (ok (mkName "default"))) (ok (mkName "other"))
    declaration = ok (mkScopeDeclaration scope [ResourceBundle [Managed resource] [] [] [] [] []])
    candidate = ok (composeInventory
      (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope declaration :| []))
    physical = ok (mkPhysicalIdentity "uid-1")
    target = AdoptionTarget resourceId (address resource) physical Nothing
    input = AdoptionInput "compiled" binding [target]
