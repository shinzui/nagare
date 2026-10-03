module InventoryCleanupSpec (inventoryCleanupTests) where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (..), PlannedOperation (..))
import Nagare.Inventory.Cleanup
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Static.Release
import Test.Tasty
import Test.Tasty.HUnit

inventoryCleanupTests :: TestTree
inventoryCleanupTests =
  testGroup
    "reviewed release cleanup"
    [ testCase "pruning preserves current release, adjacent bytes and all other scope metadata" $ do
        (revised, evidence) <- right (compileReleaseHistoryPrune 2 member accepted native)
        let (_, bytes) = evidence Map.! (member ^. #identity)
        pruned <- right (extractReleaseLog bytes)
        map (^. #releaseId) (pruned ^. #releases) @?= ["r4", "r3", "r1"]
        pruned ^. #current @?= Just "r1"
        Map.lookup (neighbor ^. #identity) evidence @?= Map.lookup (neighbor ^. #identity) native
        scopeConfigDigest revised @?= scopeConfigDigest accepted
        scopeOverrides revised @?= scopeOverrides accepted
        [r | b <- scopeBundles revised, Managed r <- declarations b, r ^. #identity == neighbor ^. #identity] @?= [neighbor]
        let updated = fst (evidence Map.! (member ^. #identity))
        (again, againNative) <- right (compileReleaseHistoryPrune 2 updated revised evidence)
        again @?= revised
        againNative @?= evidence
    , testCase "application deployment history retains the current and most recent deployment" $ do
        let bytes = renderReleaseConfigMapWith "nagare-app-deployments-" "notes" "personal" logValue
            application = resource "app-history" "nagare-app-deployments-notes" bytes
            scope = scopeWith [application, neighbor]
        (_, evidence) <- right (compileReleaseHistoryPrune 1 application scope (Map.singleton (application ^. #identity) (application, bytes)))
        pruned <- right (extractReleaseLog (snd (evidence Map.! (application ^. #identity))))
        map (^. #releaseId) (pruned ^. #releases) @?= ["r4", "r1"]
        pruned ^. #current @?= Just "r1"
        let binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))
        snapshot <- right (mkScopeSnapshot binding (Map.singleton fixtureOwner (ok (mkScopeGeneration 1), scope)) Map.empty)
        Map.keys (releaseHistoryMembers "personal" snapshot) @?= [application ^. #identity]
    , testCase "stale bytes, missing ownership, inconsistent current and invalid retention refuse" $ do
        assertBool "changed bytes" (isLeft (compileReleaseHistoryPrune 2 member accepted (Map.insert (member ^. #identity) (member, "{}") native)))
        assertBool "unowned" (isLeft (compileReleaseHistoryPrune 2 member accepted Map.empty))
        assertBool "invalid keep" (isLeft (compileReleaseHistoryPrune 0 member accepted native))
        let badBytes = renderReleaseConfigMap "notes" "personal" logValue {current = Just "missing"}
            badMember = member & #spec .~ NativeObject (contentDigest badBytes)
            badScope = scopeWith [badMember, neighbor]
        assertBool "missing current" (isLeft (compileReleaseHistoryPrune 2 badMember badScope (Map.singleton (badMember ^. #identity) (badMember, badBytes))))
    , testCase "cleanup review refuses repairs, fresh objects and hooks beyond exact history updates" $ do
        let selected = Set.singleton (member ^. #identity)
            operation =
              PlannedOperation
                (ok (mkOperationId "op-cleanup"))
                UpdateResource
                KubernetesExecutor
                ((member ^. #identity) :| [])
                (contentDigest "cleanup")
                []
                VerifyBeforeRetry
        validateReleaseCleanupOperation selected operation @?= Right ()
        validateReleaseCleanupOperation selected operation {plannedAction = VerifyResource, plannedResources = (neighbor ^. #identity) :| []} @?= Right ()
        assertBool "neighbor repair" (isLeft (validateReleaseCleanupOperation selected operation {plannedResources = (neighbor ^. #identity) :| []}))
        assertBool "fresh create" (isLeft (validateReleaseCleanupOperation selected operation {plannedAction = CreateResource}))
        assertBool "hook replay" (isLeft (validateReleaseCleanupOperation selected operation {plannedAction = RunDeclaredOperation}))
    , testCase "selection confines cleanup to accepted release records and namespace" $ do
        let binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))
            generation = ok (mkScopeGeneration 1)
        snapshot <- right (mkScopeSnapshot binding (Map.singleton fixtureOwner (generation, accepted)) Map.empty)
        Map.keys (releaseHistoryMembers "personal" snapshot) @?= [member ^. #identity]
        releaseHistoryMembers "other" snapshot @?= Map.empty
    ]

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Standalone "site-notes")

fixtureCluster :: ResourceId
fixtureCluster = mintResourceId fixtureOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

member, neighbor :: ManagedResource
member = resource "history" "nagare-static-releases-notes" originalBytes
neighbor = resource "unrelated" "application-settings" "{}"

resource :: Text -> Text -> ByteString -> ManagedResource
resource key nativeName bytes =
  ManagedResource
    (mintResourceId fixtureOwner (ok (mkLogicalKey key)) (ok (mkName key)))
    fixtureOwner
    KubernetesExecutor
    (ok (kubernetesAddress fixtureCluster "v1" "ConfigMap" (Just "personal") nativeName))
    []
    (NativeObject (contentDigest bytes))
    DeleteWhenUnreferenced
    Stateless
    Private
    []
    []
    (SourceLocation "fixture" key)

scopeWith :: [ManagedResource] -> ScopeDeclaration
scopeWith members =
  withScopeConfigDigest (contentDigest "config") $
    withScopeOverrides (Map.singleton "operational.fixture" "preserved") $
      ok (mkScopeDeclaration fixtureOwner [ResourceBundle (map Managed members) [] [] [] [] []])

accepted :: ScopeDeclaration
accepted = scopeWith [member, neighbor]

native :: Map.Map ResourceId (ManagedResource, ByteString)
native = Map.fromList [(member ^. #identity, (member, originalBytes)), (neighbor ^. #identity, (neighbor, "{}"))]

originalBytes :: ByteString
originalBytes = renderReleaseConfigMap "notes" "personal" logValue

logValue :: StaticReleaseLog
logValue = StaticReleaseLog (Just "r1") [entry n | n <- [4, 3, 2, 1 :: Int]]
  where
    entry n = StaticRelease ("r" <> T.pack (show n)) "notes" "personal" "image" "tag" "url" Nothing (UTCTime (fromGregorian 2026 10 2) 0)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure
