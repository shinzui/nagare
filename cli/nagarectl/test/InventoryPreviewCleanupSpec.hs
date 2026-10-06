module InventoryPreviewCleanupSpec (inventoryPreviewCleanupTests) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan
import Nagare.Inventory.PreviewCleanup
import Nagare.Inventory.Store
import Nagare.Resource.Inventory hiding (RetainedIncarnation)
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)
import Test.Tasty
import Test.Tasty.HUnit

inventoryPreviewCleanupTests :: TestTree
inventoryPreviewCleanupTests =
  testGroup
    "reviewed preview cleanup"
    [ testCase "accepted full preview shape selects only the requested namespace" $ do
        previewCleanupServices "personal" (snapshot [service, previewRoute, volume]) @?= Right [service]
        previewCleanupServices "other" (snapshot [service, previewRoute, volume]) @?= Right []
        assertBool "unknown companion refuses" (isLeft (previewCleanupServices "personal" (snapshot [service, previewRoute, volume, alien])))
        assertBool "missing previewRoute refuses" (isLeft (previewCleanupServices "personal" (snapshot [service, volume])))
    , testCase "native age binds address and UID and keeps the exact TTL boundary" $ do
        let observed created nativeName =
              BL.toStrict
                ( encode
                    ( object
                        [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                        , "kind" .= ("Service" :: Text)
                        , "metadata" .= object ["name" .= nativeName, "namespace" .= ("personal" :: Text), "uid" .= ("service-uid" :: Text), "creationTimestamp" .= created]
                        ]
                    )
                )
            now = UTCTime (fromGregorian 2026 10 2) 0
            before = UTCTime (fromGregorian 2026 9 24) 0
            boundary = UTCTime (fromGregorian 2026 9 25) 0
            future = UTCTime (fromGregorian 2026 10 3) 0
        parsePreviewAge now 7 service (observed before ("notes-pr-review" :: Text)) @?= Right (uid, True)
        parsePreviewAge now 7 service (observed boundary ("notes-pr-review" :: Text)) @?= Right (uid, False)
        assertBool "wrong address" (isLeft (parsePreviewAge now 7 service (observed before ("other" :: Text))))
        assertBool "future" (isLeft (parsePreviewAge now 7 service (observed future ("notes-pr-review" :: Text))))
        assertBool "negative TTL" (isLeft (parsePreviewAge now (-1) service (observed before ("notes-pr-review" :: Text))))
        assertBool "unavailable age" (isLeft (parsePreviewAge now 7 service "{}"))
    , testCase "replacement, absence, drift and missing observation invalidate age authority" $ do
        let expected = Map.singleton (service ^. #identity) uid
            fact value = ok (observationSet [(service ^. #identity, value)])
        validatePreviewIncarnations expected (fact (ObservedPresent uid)) @?= Right ()
        for_ [ObservedPresent (ok (mkPhysicalIdentity "replacement")), ConfirmedAbsent (contentDigest "absent"), ObservedDrifted uid (contentDigest "drift"), ObservationUnavailable "denied"] $ \value ->
          assertBool "changed incarnation refuses" (isLeft (validatePreviewIncarnations expected (fact value)))
        assertBool "missing observation refuses" (isLeft (validatePreviewIncarnations expected (ok (observationSet []))))
    , testCase "collection follows retained dependency order and preserves durable volumes" $ do
        store <- newMemoryStore
        _ <- initializeStore store binding "preview-test" >>= right
        original <- loadInventoryHistory store >>= right
        inventory <- right (composeSnapshot (ok (mkScopeSnapshot binding Map.empty Map.empty)))
        let originalScope = snd (snapshotScopes (snapshot [service, previewRoute, volume]) Map.! fixtureOwner)
            revision = ScopeRevision generation (contentDigest (encodeCanonicalScope originalScope))
            originals = Map.singleton (fixtureOwner, revision) originalScope
            retained member = (RetainedIncarnation fixtureOwner revision uid "fixture" Nothing Nothing, member)
            history = original {historyRetained = Map.fromList [(member ^. #identity, retained member) | member <- [service, previewRoute, volume]]}
        eligiblePreviewCollections "personal" history inventory originals @?= Right [previewRoute ^. #identity]
        let withoutRoute = history {historyRetained = Map.delete (previewRoute ^. #identity) (historyRetained history)}
        eligiblePreviewCollections "personal" withoutRoute inventory originals @?= Right [service ^. #identity]
        let withoutService = withoutRoute {historyRetained = Map.delete (service ^. #identity) (historyRetained withoutRoute)}
        eligiblePreviewCollections "personal" withoutService inventory originals @?= Right []
        eligiblePreviewCollections "other" history inventory originals @?= Right []
        assertBool "missing original" (isLeft (eligiblePreviewCollections "personal" history inventory Map.empty))
        let unrelated = snd (snapshotScopes (snapshot [alien]) Map.! fixtureOwner)
            unrelatedRevision = ScopeRevision generation (contentDigest (encodeCanonicalScope unrelated))
            unrelatedHistory = original {historyRetained = Map.singleton (alien ^. #identity) (RetainedIncarnation fixtureOwner unrelatedRevision uid "fixture" Nothing Nothing, alien)}
        assertBool
          "prefix-only owner is not preview authority"
          (isLeft (eligiblePreviewCollections "personal" unrelatedHistory inventory (Map.singleton (fixtureOwner, unrelatedRevision) unrelated)))
        assertBool
          "changed original digest"
          (isLeft (eligiblePreviewCollections "personal" history inventory (Map.singleton (fixtureOwner, revision) unrelated)))
    ]

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Standalone "site-preview-notes-pr-review")

binding :: ContextBinding
binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))

generation :: ScopeGeneration
generation = ok (mkScopeGeneration 1)

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

uid :: PhysicalIdentity
uid = ok (mkPhysicalIdentity "service-uid")

service, previewRoute, volume, alien :: ManagedResource
service =
  resource "service" "serving.knative.dev/v1" "Service" "notes-pr-review" [OrderedAfter (volume ^. #identity)]
    & #spec
    .~ KnativeService (contentDigest "service")
previewRoute = resource "route" "serving.knative.dev/v1beta1" "DomainMapping" "notes-review.example.test" [OrderedAfter (service ^. #identity)]
volume =
  resource "volume" "v1" "PersistentVolumeClaim" "nagare-vol-notes-pr-review-data" []
    & #lifecycle
    .~ Retain
    & #dataPolicy
    .~ Durable (RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "credential")) (ok (mkName "v1")) :| []))
alien = resource "alien" "v1" "ConfigMap" "settings" []

resource :: Text -> Text -> Text -> Text -> [Dependency] -> ManagedResource
resource key api kind name dependencies =
  ManagedResource
    (mintResourceId fixtureOwner (ok (mkLogicalKey key)) (ok (mkName key)))
    fixtureOwner
    KubernetesExecutor
    (ok (kubernetesAddress fixtureCluster api kind (Just "personal") name))
    []
    (NativeObject (contentDigest (TE.encodeUtf8 key)))
    DeleteWhenUnreferenced
    Stateless
    Private
    dependencies
    []
    (SourceLocation "fixture" key)

snapshot :: [ManagedResource] -> ScopeSnapshot
snapshot members = ok (mkScopeSnapshot binding (Map.singleton fixtureOwner (generation, ok (mkScopeDeclaration fixtureOwner [ResourceBundle (map Managed members) [] [] [] [] []]))) Map.empty)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
