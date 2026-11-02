-- | F40: a scope that owns a composed contribution target (here the access
-- backend map granted by 'BackendMapGrant') retires with that target retained,
-- and the retained member reloads from history although no raw bundle lists it.
-- BUG-9: a migration Job named after its image is retained, without a
-- decision, when a new image replaces it. EP-237: so is a release image.
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
import Nagare.Contract.ReleaseImages
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Artifact
import Nagare.Inventory.Components.ReleaseImage (compileReleaseImages, releaseImagesOwner)
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
    , testGroup
        "superseded release images (EP-237)"
        [ testCase "a new digest moves the one image member and publishes it, with nothing retained" imageMoves
        , testCase "an unchanged digest plans no fetch and no publication" unchangedImage
        , testCase "an artifact in another scope still needs a migration review to move" unrelatedArtifact
        , testCase "a release may return to a digest it moved away from" returnedImage
        , testCase "an image change back refuses at its retained migration Job, before any mutation" returnedMigrationJob
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

-- * release images

releaseWith :: Char -> ReleaseImages
releaseWith c =
  ReleaseImages
    releaseImagesSchemaVersion
    (Map.fromList [(key, ReleaseImage releaseImagePlatform ("sha256:" <> T.replicate 64 (T.singleton c)) ("/nix/store/" <> T.replicate 32 "a" <> "-nagare-oci") Map.empty) | key <- releaseImageKeys])

imageScope :: Char -> ScopeDeclaration
imageScope c = fst (either (error . show) id (compileReleaseImages "registry.example.test/nagare" [EnImage] (releaseWith c)))

enImage :: ResourceId
enImage = mintResourceId releaseImagesOwner (ok (mkLogicalKey "en")) (ok (mkName "image"))

physicalOf :: Char -> PhysicalIdentity
physicalOf c = ok (mkPhysicalIdentity ("oci://registry.example.test/nagare/en:sha256-" <> T.replicate 64 (T.singleton c)))

-- | A store whose release image scope has published this digest.
acceptedImage :: ScopeDeclaration -> IO InventoryStore
acceptedImage scope = acceptedScope scope enImage

acceptedScope :: ScopeDeclaration -> ResourceId -> IO InventoryStore
acceptedScope scope resource = do
  store <- newMemoryStore
  _ <- initializeStore store fixtureBinding "release-images" >>= expectRight
  emptyHistory <- loadInventoryHistory store >>= expectRight
  let initial = ok (composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| []))
      absent = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent"))])
  acceptWith (observingRegistry ArtifactExecutor (physicalOf 'a')) store (ok (planChanges initial noLifecycleDecisions emptyHistory absent))
  pure store

replacing :: InventoryHistory -> ScopeDeclaration -> CompositionCandidate
replacing history scope =
  let accepted = Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)
   in ok (composeInventory (ok (mkScopeSnapshot fixtureBinding accepted Map.empty)) (ReplaceScope scope :| []))

imageMoves :: Assertion
imageMoves = do
  store <- acceptedImage (imageScope 'a')
  history <- loadInventoryHistory store >>= expectRight
  let observed = ok (observationSet [(enImage, ConfirmedAbsent (contentDigest "absent"))])
  proposal <- expectRight (planChanges (replacing history (imageScope 'b')) noLifecycleDecisions history observed)
  let actions = map plannedAction (proposalOperations proposal)
  assertBool ("the new image is not created and published: " <> show actions) (CreateResource `elem` actions && RunDeclaredOperation `elem` actions)
  assertBool "the previous image was retired" (RetireResource `notElem` actions)
  acceptWith (observingRegistry ArtifactExecutor (physicalOf 'b')) store proposal
  moved <- loadInventoryHistory store >>= expectRight
  historyRetained moved @?= Map.empty
  [resource ^. #address | Managed resource <- historyDeclarations moved]
    @?= [Artifact (ok (mkName "en")) (ok (mkContentDigest (T.replicate 64 "b")))]

unchangedImage :: Assertion
unchangedImage = do
  store <- acceptedImage (imageScope 'a')
  history <- loadInventoryHistory store >>= expectRight
  let observed = ok (observationSet [(enImage, ObservedPresent (physicalOf 'a'))])
  proposal <- expectRight (planChanges (replacing history (imageScope 'a')) noLifecycleDecisions history observed)
  [plannedAction operation | operation <- proposalOperations proposal, plannedAction operation /= VerifyResource] @?= []

unrelatedArtifact :: Assertion
unrelatedArtifact = do
  let other = ok (mkScopeId Platform "other-images")
      artifactIn c =
        ArtifactResourceSpec
          { artifactLogicalKey = ok (mkLogicalKey "en")
          , artifactRole = ok (mkName "image")
          , artifactName = ok (mkName "en")
          , artifactDestination = "registry.example.test/nagare/en:" <> T.singleton c
          , artifactContentDigest = contentDigest (TE.encodeUtf8 (T.singleton c))
          , artifactSpecDigest = contentDigest (TE.encodeUtf8 (T.singleton c))
          , artifactKind = OciImageArtifact
          , artifactOwnership = OwnedArtifact
          , artifactLifecycle = Retain
          , artifactDataPolicy = Stateless
          , artifactSensitivity = Public
          , artifactDependencies = []
          , artifactConsumers = ConsumerCompletenessUnknown
          , artifactPublishOperation = True
          , artifactSource = SourceLocation "test" "image"
          }
      scopeOf c = either (error . show) id (compileArtifactScope (ArtifactDeclarationBundle 1 other (artifactIn c :| [])))
      identity' = mintResourceId other (artifactLogicalKey (artifactIn 'a')) (artifactRole (artifactIn 'a'))
  store <- acceptedScope (scopeOf 'a') identity'
  history <- loadInventoryHistory store >>= expectRight
  let observed = ok (observationSet [(identity', ConfirmedAbsent (contentDigest "absent"))])
  case planChanges (replacing history (scopeOf 'b')) noLifecycleDecisions history observed of
    Left errors -> map planErrorCode (NE.toList errors) @?= ["migration-review-required"]
    Right _ -> assertFailure "another scope's artifact moved its address without a migration review"

returnedImage :: Assertion
returnedImage = do
  store <- acceptedImage (imageScope 'a')
  history <- loadInventoryHistory store >>= expectRight
  let toB = ok (observationSet [(enImage, ConfirmedAbsent (contentDigest "absent"))])
  proposal <- expectRight (planChanges (replacing history (imageScope 'b')) noLifecycleDecisions history toB)
  acceptWith (observingRegistry ArtifactExecutor (physicalOf 'b')) store proposal
  moved <- loadInventoryHistory store >>= expectRight
  -- The registry still holds the first image, so nothing is copied; the
  -- transaction moves back and records it.
  let back = ok (observationSet [(enImage, ObservedPresent (physicalOf 'a'))])
  returned <- expectRight (planChanges (replacing moved (imageScope 'a')) noLifecycleDecisions moved back)
  acceptWith (observingRegistry ArtifactExecutor (physicalOf 'a')) store returned
  finished <- loadInventoryHistory store >>= expectRight
  historyRetained finished @?= Map.empty
  [resource ^. #address | Managed resource <- historyDeclarations finished]
    @?= [Artifact (ok (mkName "en")) (ok (mkContentDigest (T.replicate 64 "a")))]

-- | What an image change back does to a migration Job: its name holds the
-- image, so the first image's Job is the retained one.
returnedMigrationJob :: Assertion
returnedMigrationJob = do
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
  acceptWith (observingRegistry KubernetesExecutor oldJobPhysical) store proposal
  moved <- loadInventoryHistory store >>= expectRight
  let back = authReplacement moved [authJob "shomei-migrate-old"] [authMigration "shomei-migrate-old"]
      seen =
        ok
          ( observationSet
              [ (authJobId "shomei-migrate-new", ObservedPresent oldJobPhysical)
              , (authJobId "shomei-migrate-old", ObservedPresent oldJobPhysical)
              ]
          )
  case planChanges back noLifecycleDecisions moved seen of
    Left errors -> assertBool (show (NE.toList errors)) ("retained-reactivation" `elem` map planErrorCode (NE.toList errors))
    Right _ -> assertFailure "an image change back now plans; update this record of the refusal and the plan's rollback text"

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
