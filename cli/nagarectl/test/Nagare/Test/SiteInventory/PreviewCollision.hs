-- | EP-195 M1: the four site and preview identity collisions, measured against
-- the planner before the name refusals exist. M2 and M3 delete this module.
module Nagare.Test.SiteInventory.PreviewCollision
  ( previewCollisionTests
  )
where

import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Server.Types
  ( ServerSite
      ( ServerSite
      , access
      , build
      , cdn
      , domains
      , env
      , image
      , name
      , namespace
      , port
      , resources
      , runtime
      , scale
      , volumes
      )
  , defaultServerRuntime
  , tanstackStartBuild
  )
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , RetentionPolicy (Retain)
  , Volume
    ( Volume
    , accessMode
    , logicalKey
    , mountPath
    , name
    , readOnly
    , retention
    , size
    )
  , defaultPort
  , mkImageRef
  , mkMountPath
  , mkNamespace
  , mkQuantity
  , mkVolumeName
  )
import Nagare.Inventory.Adapter (PlannedOperation (..), ResourceObservation (..), observationSet)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Environment
  ( compilePreviewEnvChannel
  , compilePreviewSecretChannel
  , compileRuntimeEnvChannel
  , compileRuntimeSecretChannel
  )
import Nagare.Inventory.Plan
  ( ObservationRequirements (requiredResources)
  , PlanError (planErrorCode, planErrorResources)
  , loadInventoryHistory
  , noLifecycleDecisions
  , observationRequirements
  , planChanges
  , proposalOperations
  )
import Nagare.Inventory.Site
  ( acceptedSitePreviewDependencies
  , compileServerSitePreviewScope
  , compileServerSiteScope
  , siteVolumeRecoveryBindings
  )
import Nagare.Inventory.Site.Release (acceptedSiteReleaseLog)
import Nagare.Inventory.Store (newMemoryStore)
import Nagare.Resource.Inventory
  ( Declaration (External, Managed)
  , ManagedResource
  , ResourceBundle (ResourceBundle, declarations)
  , ScopeChange (ReplaceScope)
  , ScopeDeclaration
  , candidateInventory
  , composeInventory
  , declarationId
  , inventoryDeclarations
  , mkScopeDeclaration
  , mkScopeSnapshot
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Types qualified as Resource
import Nagare.Server.Deploy qualified as ServerDeploy
import Nagare.Static.Preview (previewServiceName)
import Nagare.Static.Release (StaticRelease (StaticRelease), emptyReleaseLog)
import Nagare.Test.Effectful.Fixture (checked, must, seedAccepted)
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

previewCollisionTests :: [TestTree]
previewCollisionTests =
  [ testGroup
      "site preview identity collisions (EP-195 M1)"
      [ testCase "collision 1: a preview and a site named preview-<site>-pr-<preview>" $ do
          (previewDeclaration, previewNative) <- previewScope "blog" "x"
          (site, siteNative) <- siteScope "preview-blog-pr-x"
          scopeId site @?= scopeId previewDeclaration
          let accepted = checked (mkScopeSnapshot binding (Map.singleton (scopeId previewDeclaration) (generation, previewDeclaration)) Map.empty)
          acceptedSiteReleaseLog accepted previewNative "preview-blog-pr-x" "personal" cluster
            @?= Left "accepted site scope lacks release history"
          stores <- storesFor "blog"
          refusal <- planOver ((site, siteNative) : stores) previewDeclaration
          refusal
            @?= [ ("migration-review-required", ["standalone:site-preview-blog-pr-x/data/site-pvc"])
                , ("retirement-required", ["standalone:site-preview-blog-pr-x/preview-blog-pr-x/service"])
                , ("retirement-required", ["standalone:site-preview-blog-pr-x/release-history/configmap"])
                ]
      , testCase "collision 2: previews of two sites split at a different -pr-" $ do
          (first', native) <- previewScope "a-pr-b" "c"
          (second', _) <- previewScope "a" "b-pr-c"
          previewServiceName "a-pr-b" "c" @?= previewServiceName "a" "b-pr-c"
          scopeId second' @?= scopeId first'
          stores <- (<>) <$> storesFor "a-pr-b" <*> storesFor "a"
          refusal <- planOver ((first', native) : stores) second'
          refusal @?= [("retirement-required", ["standalone:site-preview-a-pr-b-pr-c/c.a-pr-b.preview.example.com/domain-mapping"])]
      , testCase "collision 3: two previews of a 55-character site cut to one name" $ do
          let site = T.replicate 55 "s"
          previewServiceName site "feature-login" @?= previewServiceName site "feature-logout"
          (first', native) <- previewScope site "feature-login"
          (second', _) <- previewScope site "feature-logout"
          scopeId second' @?= scopeId first'
          stores <- storesFor site
          refusal <- planOver ((first', native) : stores) second'
          refusal
            @?= [
                  ( "retirement-required"
                  , ["standalone:site-preview-" <> site <> "-pr-feat/feature-login." <> site <> ".preview.example.com/domain-mapping"]
                  )
                ]
      , testCase "collision 4: a 63-character site's preview is cut to the site's own Service" $ do
          let siteName = T.replicate 63 "s"
          previewServiceName siteName "x" @?= Right siteName
          (site, _) <- siteScope siteName
          (previewDeclaration, _) <- previewScope siteName "x"
          stores <- storesFor siteName
          let accepted = checked (mkScopeSnapshot binding (Map.fromList [(scopeId scope, (generation, scope)) | scope <- foundationScope : site : map fst stores]) Map.empty)
          case composeInventory accepted (ReplaceScope previewDeclaration :| []) of
            Left errors -> toList (fmap (^. #code) errors) @?= ["claim-conflict", "claim-conflict", "claim-conflict"]
            Right _ -> assertFailure "collision 4: composition accepted the preview beside its site"
      ]
  ]

-- Seed the first owners as accepted and converged, then plan the colliding
-- scope over them, as a preview deploy does (no lifecycle decisions), with a
-- provider that observes exactly the accepted addresses as present. The result
-- is the planner's refusal, as (code, resources) pairs.
planOver :: [(ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))] -> ScopeDeclaration -> IO [(Text, [Text])]
planOver seeded colliding = do
  let accepted = foundationScope : map fst seeded
  store <- newMemoryStore
  seedAccepted store binding accepted (foldMap snd seeded)
  history <- must (loadInventoryHistory store)
  let snapshot = checked (mkScopeSnapshot binding (Map.fromList [(scopeId scope, (generation, scope)) | scope <- accepted]) Map.empty)
      candidate = checked (composeInventory snapshot (ReplaceScope colliding :| []))
      acceptedAddresses = Set.fromList [(member ^. #identity, member ^. #address) | scope <- accepted, member <- managed scope]
      desired = Map.fromList [(declarationId declaration, declaration) | declaration <- inventoryDeclarations (candidateInventory candidate)]
      observe resource = case Map.lookup resource desired of
        Just (Managed member)
          | Set.notMember (resource, member ^. #address) acceptedAddresses -> ConfirmedAbsent (contentDigest "absent")
        _ -> ObservedPresent (unsafe (Resource.mkPhysicalIdentity "uid"))
      required = Set.toList (requiredResources (observationRequirements candidate history))
      observations = checked (observationSet [(resource, observe resource) | resource <- required])
  case planChanges candidate noLifecycleDecisions history observations of
    Left errors -> pure [(planErrorCode e, map Resource.resourceIdText (planErrorResources e)) | e <- toList errors]
    Right proposal ->
      assertFailure ("the colliding scope was planned: " <> show [(plannedAction operation, toList (plannedResources operation)) | operation <- proposalOperations proposal])

managed :: ScopeDeclaration -> [ManagedResource]
managed scope = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]

serverSite :: Text -> ServerSite
serverSite siteName =
  ServerSite
    { name = unsafe (mkSiteName siteName)
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
    , build = tanstackStartBuild
    , runtime = defaultServerRuntime
    , port = defaultPort
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , domains = []
    , volumes =
        [ Volume
            { name = unsafe (mkVolumeName "data")
            , logicalKey = Nothing
            , size = unsafe (mkQuantity "1Gi")
            , mountPath = unsafe (mkMountPath "/data")
            , accessMode = ReadWriteOnce
            , readOnly = False
            , retention = Retain
            }
        ]
    , cdn = Nothing
    , access = Nothing
    }

inputsFor :: Text -> ServerDeploy.ServerDeployInputs
inputsFor siteName = ServerDeploy.ServerDeployInputs (serverSite siteName) "v1" "example.com" "." True initProfile

previewScope :: Text -> Text -> IO (ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))
previewScope siteName previewName = do
  recovery <- either (fail . T.unpack) pure (siteVolumeRecoveryBindings (serverSite siteName) ["data=backup:key:v1"])
  stores <- storesFor siteName
  let snapshot = checked (mkScopeSnapshot binding (Map.fromList [(scopeId scope, (generation, scope)) | (scope, _) <- stores]) Map.empty)
  dependencies <- either (fail . T.unpack) pure (acceptedSitePreviewDependencies snapshot cluster siteName "personal" (concatMap (Map.keys . snd) stores))
  either (fail . showErrors) pure (compileServerSitePreviewScope Nothing (inputsFor siteName) previewName cluster namespaceId imageId dependencies recovery Map.empty source)

-- The four environment stores every site preview depends on.
storesFor :: Text -> IO [(ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))]
storesFor siteName =
  traverse
    (either (fail . showErrors) pure)
    [ compileRuntimeEnvChannel siteName "personal" cluster namespaceId Map.empty source
    , compileRuntimeSecretChannel siteName "personal" cluster namespaceId version Map.empty source
    , compilePreviewEnvChannel siteName "personal" cluster namespaceId Map.empty source
    , compilePreviewSecretChannel siteName "personal" cluster namespaceId version Map.empty source
    ]
  where
    version = unsafe (Resource.mkName "v1")

siteScope :: Text -> IO (ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))
siteScope siteName = do
  recovery <- either (fail . T.unpack) pure (siteVolumeRecoveryBindings (serverSite siteName) ["data=backup:key:v1"])
  let release =
        StaticRelease
          "v1"
          siteName
          "personal"
          "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo"
          "v1"
          (ServerDeploy.serverUrl (serverSite siteName) "example.com")
          Nothing
          (UTCTime (fromGregorian 2026 9 24) 0)
  either (fail . showErrors) pure (compileServerSiteScope (inputsFor siteName) cluster namespaceId imageId recovery Map.empty Map.empty emptyReleaseLog release source)

showErrors :: NonEmpty Resource.InventoryError -> String
showErrors = show

foundation :: Resource.ScopeId
foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")

cluster, namespaceId, imageId :: Resource.ResourceId
cluster = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
namespaceId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "namespace")) (unsafe (Resource.mkName "resource"))
imageId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))

foundationScope :: ScopeDeclaration
foundationScope =
  checked
    ( mkScopeDeclaration
        foundation
        [ ResourceBundle
            [ External cluster (Resource.Artifact (unsafe (Resource.mkName "local-cluster")) (contentDigest "cluster")) [] source
            , External namespaceId (unsafe (Resource.kubernetesAddress cluster "v1" "Namespace" Nothing "personal")) [] source
            , External imageId (Resource.Artifact (unsafe (Resource.mkName "image")) (contentDigest "image")) [] source
            ]
            []
            []
            []
            []
            []
        ]
    )

binding :: Resource.ContextBinding
binding = Resource.ContextBinding (unsafe (Resource.mkContextId "test")) (unsafe (Resource.mkName "project"))

generation :: Resource.ScopeGeneration
generation = unsafe (Resource.mkScopeGeneration 1)

source :: Resource.SourceLocation
source = Resource.SourceLocation "fixture" "collision"
