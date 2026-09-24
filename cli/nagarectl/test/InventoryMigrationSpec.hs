module InventoryMigrationSpec (inventoryMigrationTests) where

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
import Nagare.Inventory.Migration
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryMigrationTests :: TestTree
inventoryMigrationTests = testGroup "inventory migration"
  [ testCase "versioned proposal binds old and new declarations and exact observations" $ do
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
    oldScope = ok (mkScopeDeclaration scope [ResourceBundle [Managed oldResource] [] [] [] [] []])
    newScope = ok (mkScopeDeclaration scope [ResourceBundle [Managed newResource] [] [] [] [] []])
    snapshot = ok (mkScopeSnapshot binding
      (Map.singleton scope (ok (mkScopeGeneration 1), oldScope)) Map.empty)
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
    acceptedHistory = do
      store <- newMemoryStore
      _ <- initializeStore store binding "migration-test" >>= either (assertFailure . show) pure
      let seed = ok (composeInventory snapshot
            (ReplaceScope (ok (mkScopeDeclaration dummyScope [])) :| []))
      _ <- seedInventoryHistory store seed >>= either (assertFailure . show) pure
      loadInventoryHistory store >>= either (assertFailure . show) pure
