-- | SiteInventory responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.SiteInventory.Preview
  ( previewSiteInventoryTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Server.Types
  ( ServerSite
      ( ServerSite
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
import Nagare.Dsl.Static.Types
  ( StaticBuild (NoBuild)
  , mkFilePathText
  , mkSiteName
  )
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , EnvScope (Build, Preview)
  , EnvVar (EnvSecretRef)
  , RetentionPolicy (Delete, Retain)
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
  , mkEnvName
  , mkImageRef
  , mkMountPath
  , mkNamespace
  , mkQuantity
  , mkSecretName
  , mkVolumeName
  , runtimeScoped
  , scopedEnv
  )
import Nagare.Inventory.Environment
  ( compilePreviewEnvChannel
  , compilePreviewSecretChannel
  , compileRuntimeEnvChannel
  , compileRuntimeSecretChannel
  )
import Nagare.Inventory.Site
  ( acceptedSitePreviewDependencies
  , acceptedSitePreviewStoreIds
  , compileServerSitePreviewScope
  , compileServerSitePreviewScopeWithBuild
  , compileStaticSitePreviewScope
  , sitePreviewRetirementScope
  , siteVolumeRecoveryBindings
  )
import Nagare.Resource.Inventory
  ( Declaration (External, Managed)
  , ResourceBundle (..)
  , declarationId
  , mkScopeSnapshot
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Policy
  ( DataPolicy (Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Server.Deploy qualified as ServerDeploy
import Nagare.Static.Deploy (DeployInputs (DeployInputs))
import Nagare.Static.Preview (previewDomain, previewServiceName)
import Nagare.Storage.Discover (pvcName)
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures

previewSiteInventoryTests :: [TestTree]
previewSiteInventoryTests =
  [ testCase "site preview review binds accepted overlay and runtime stores" $ do
      let site = baseSite (NoBuild (unsafe (mkFilePathText "dist")))
          inputs = DeployInputs site "v1" "example.com" "." True initProfile
          foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster =
            Resource.mintResourceId
              foundation
              (unsafe (Resource.mkLogicalKey "cluster"))
              (unsafe (Resource.mkName "resource"))
          namespaceId =
            Resource.mintResourceId
              foundation
              (unsafe (Resource.mkLogicalKey "namespace"))
              (unsafe (Resource.mkName "resource"))
          imageId =
            Resource.mintResourceId
              foundation
              (unsafe (Resource.mkLogicalKey "image"))
              (unsafe (Resource.mkName "publication"))
          source = Resource.SourceLocation "fixture" "preview"
          version = unsafe (Resource.mkName "v1")
      stores <-
        traverse
          (either (fail . show) pure)
          [ compileRuntimeEnvChannel "demo" "personal" cluster namespaceId Map.empty source
          , compileRuntimeSecretChannel "demo" "personal" cluster namespaceId version Map.empty source
          , compilePreviewEnvChannel "demo" "personal" cluster namespaceId Map.empty source
          , compilePreviewSecretChannel "demo" "personal" cluster namespaceId version Map.empty source
          ]
      let binding =
            Resource.ContextBinding
              (unsafe (Resource.mkContextId "test"))
              (unsafe (Resource.mkName "project"))
          accepted =
            Map.fromList
              [ ( scopeId scope
                , (unsafe (Resource.mkScopeGeneration 1), scope)
                )
              | (scope, _) <- stores
              ]
          storeIds = concatMap (Map.keys . snd) stores
      snapshot <-
        either
          (fail . show)
          pure
          (mkScopeSnapshot binding accepted Map.empty)
      deps <-
        either
          (fail . T.unpack)
          pure
          (acceptedSitePreviewDependencies snapshot cluster "demo" "personal" storeIds)
      length deps @?= 4
      selectedIds <-
        either
          (fail . T.unpack)
          pure
          (acceptedSitePreviewStoreIds snapshot cluster "demo" "personal")
      Set.fromList selectedIds @?= Set.fromList storeIds
      assertBool
        "webhook selected another site's preview stores"
        (isLeft (acceptedSitePreviewStoreIds snapshot cluster "other" "personal"))
      assertBool
        "preview accepted a missing store"
        ( isLeft
            ( acceptedSitePreviewDependencies
                snapshot
                cluster
                "demo"
                "personal"
                (take 3 storeIds)
            )
        )
      assertBool
        "preview accepted another site's stores"
        (isLeft (acceptedSitePreviewDependencies snapshot cluster "other" "personal" storeIds))
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileStaticSitePreviewScope inputs "branch" cluster namespaceId imageId deps source)
      assertBool
        "preview compiler accepted incomplete stores"
        ( isLeft
            ( compileStaticSitePreviewScope
                inputs
                "branch"
                cluster
                namespaceId
                imageId
                (take 3 deps)
                source
            )
        )
      Resource.scopeKind (scopeId scope) @?= Resource.Standalone
      Map.size native @?= 2
      let members =
            [ member
            | bundle <- scopeBundles scope
            , Managed member <- declarations bundle
            ]
      assertBool
        "preview Service lacks accepted environment ordering"
        ( any
            ( \member ->
                all
                  ( \resourceId ->
                      OrderedAfter resourceId
                        `elem` member ^. #dependencies
                  )
                  (map declarationId deps)
            )
            members
        )
      previewSnapshot <-
        either
          (fail . show)
          pure
          ( mkScopeSnapshot
              binding
              (Map.singleton (scopeId scope) (unsafe (Resource.mkScopeGeneration 1), scope))
              Map.empty
          )
      svcName <- either (fail . T.unpack) pure (previewServiceName "demo" "branch")
      host <-
        either
          (fail . T.unpack)
          pure
          (previewDomain "demo" "branch" "example.com")
      sitePreviewRetirementScope previewSnapshot cluster svcName "personal" host []
        @?= Right (scopeId scope)
      assertBool
        "preview retirement selected a different domain"
        ( isLeft
            ( sitePreviewRetirementScope
                previewSnapshot
                cluster
                svcName
                "personal"
                "other.example.com"
                []
            )
        )
      let serverSite =
            ServerSite
              { name = unsafe (mkSiteName "demo")
              , namespace = unsafe (mkNamespace "personal")
              , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo")
              , build = tanstackStartBuild
              , runtime = defaultServerRuntime
              , port = defaultPort
              , env = Map.empty
              , resources = Nothing
              , scale = Nothing
              , domains = []
              , volumes = []
              , cdn = Nothing
              }
          serverInputs =
            ServerDeploy.ServerDeployInputs
              serverSite
              "v1"
              "example.com"
              "."
              True
              initProfile
      serverRendered <-
        either
          (fail . T.unpack)
          pure
          (ServerDeploy.serverPreviewManifests serverInputs "branch")
      serverRendered ^. #serviceName @?= svcName
      assertBool
        "server preview omitted its Preview overlay"
        ( BC.isInfixOf "nagare-env-demo-preview" (serverRendered ^. #service)
            && BC.isInfixOf "nagare-secret-demo-preview" (serverRendered ^. #service)
        )
      (serverScope, serverNative) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScope
              serverInputs
              "branch"
              cluster
              namespaceId
              imageId
              deps
              Map.empty
              Map.empty
              source
          )
      scopeId serverScope @?= scopeId scope
      Map.size serverNative @?= 2
      let secretName = unsafe (mkSecretName "external")
          secretId =
            Resource.mintResourceId
              foundation
              (unsafe (Resource.mkLogicalKey "external"))
              (unsafe (Resource.mkName "secret"))
          secretAddress =
            unsafe
              ( Resource.kubernetesAddress
                  cluster
                  "v1"
                  "Secret"
                  (Just "personal")
                  "external"
              )
          secretSite =
            serverSite
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "API_KEY"))
                (runtimeScoped (EnvSecretRef secretName))
          secretBindings = Map.singleton secretName (External secretId secretAddress [] source)
      (secretScope, _) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScope
              (serverInputs {ServerDeploy.site = secretSite})
              "branch"
              cluster
              namespaceId
              imageId
              deps
              Map.empty
              secretBindings
              source
          )
      assertBool
        "server preview Service lacks Runtime Secret ordering"
        ( any
            (elem (OrderedAfter secretId) . (^. #dependencies))
            [member | bundle <- scopeBundles secretScope, Managed member <- declarations bundle]
        )
      assertBool
        "server preview accepted an unbound Runtime Secret"
        ( isLeft
            ( compileServerSitePreviewScope
                (serverInputs {ServerDeploy.site = secretSite})
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                Map.empty
                source
            )
        )
      let previewSecretSite =
            serverSite
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "API_KEY"))
                (unsafe (scopedEnv (Set.singleton Preview) (EnvSecretRef secretName)))
      (previewSecretScope, _) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScope
              (serverInputs {ServerDeploy.site = previewSecretSite})
              "branch"
              cluster
              namespaceId
              imageId
              deps
              Map.empty
              secretBindings
              source
          )
      assertBool
        "server preview Service lacks Preview Secret ordering"
        ( any
            (elem (OrderedAfter secretId) . (^. #dependencies))
            [member | bundle <- scopeBundles previewSecretScope, Managed member <- declarations bundle]
        )
      assertBool
        "server preview accepted an unbound Preview Secret"
        ( isLeft
            ( compileServerSitePreviewScope
                (serverInputs {ServerDeploy.site = previewSecretSite})
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                Map.empty
                source
            )
        )
      let buildSecretSite =
            serverSite
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "API_KEY"))
                ( unsafe
                    ( scopedEnv
                        (Set.fromList [Build, Preview])
                        (EnvSecretRef secretName)
                    )
                )
      assertBool
        "server preview accepted a Build Secret without publication"
        ( isLeft
            ( compileServerSitePreviewScope
                (serverInputs {ServerDeploy.site = buildSecretSite})
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                secretBindings
                source
            )
        )
      let pinnedBuildSite =
            serverSite
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "BUILD_TOKEN"))
                (unsafe (scopedEnv (Set.singleton Build) (EnvSecretRef secretName)))
          pinnedBuildInputs = serverInputs {ServerDeploy.site = pinnedBuildSite}
      (_, pinnedBuildNative) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScopeWithBuild
              (Set.singleton secretName)
              pinnedBuildInputs
              "branch"
              cluster
              namespaceId
              imageId
              deps
              Map.empty
              Map.empty
              source
          )
      assertBool
        "Build Secret leaked into preview native manifests"
        (all (not . BC.isInfixOf "BUILD_TOKEN" . snd) (Map.elems pinnedBuildNative))
      assertBool
        "preview accepted a Build Secret absent from image inputs"
        ( isLeft
            ( compileServerSitePreviewScopeWithBuild
                Set.empty
                pinnedBuildInputs
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                Map.empty
                source
            )
        )
      assertBool
        "preview accepted a mixed Build/Preview Secret"
        ( isLeft
            ( compileServerSitePreviewScopeWithBuild
                (Set.singleton secretName)
                (serverInputs {ServerDeploy.site = buildSecretSite})
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                secretBindings
                source
            )
        )
      let volume =
            Volume
              { name = unsafe (mkVolumeName "data")
              , logicalKey = Nothing
              , size = unsafe (mkQuantity "1Gi")
              , mountPath = unsafe (mkMountPath "/data")
              , accessMode = ReadWriteOnce
              , readOnly = False
              , retention = Retain
              }
          volumeSite = serverSite & #volumes .~ [volume]
      assertBool
        "server preview accepted a retained volume without recovery"
        ( isLeft
            ( compileServerSitePreviewScope
                (serverInputs {ServerDeploy.site = volumeSite})
                "branch"
                cluster
                namespaceId
                imageId
                deps
                Map.empty
                Map.empty
                source
            )
        )
      recovery <-
        either
          (fail . T.unpack)
          pure
          (siteVolumeRecoveryBindings volumeSite ["data=backup:key:v1"])
      (volumeScope, volumeNative) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScope
              (serverInputs {ServerDeploy.site = volumeSite})
              "branch"
              cluster
              namespaceId
              imageId
              deps
              recovery
              Map.empty
              source
          )
      Map.size volumeNative @?= 3
      let volumeMembers =
            [ member
            | bundle <- scopeBundles volumeScope
            , Managed member <- declarations bundle
            ]
          pvcAddress =
            unsafe
              ( Resource.kubernetesAddress
                  cluster
                  "v1"
                  "PersistentVolumeClaim"
                  (Just "personal")
                  (pvcName svcName "data")
              )
          pvcMembers = filter ((== pvcAddress) . (^. #address)) volumeMembers
      pvcId <- case pvcMembers of
        [pvc] -> pure (pvc ^. #identity)
        _ -> fail "preview PVC membership differs from its rendered claim"
      assertBool
        "preview Service lacks its exact volume dependency"
        ( any
            ( elem (OrderedAfter pvcId)
                . (^. #dependencies)
            )
            volumeMembers
        )
      volumeSnapshot <-
        either
          (fail . show)
          pure
          ( mkScopeSnapshot
              binding
              ( Map.singleton
                  (scopeId volumeScope)
                  (unsafe (Resource.mkScopeGeneration 1), volumeScope)
              )
              Map.empty
          )
      sitePreviewRetirementScope volumeSnapshot cluster svcName "personal" host ["data"]
        @?= Right (scopeId volumeScope)
      assertBool
        "preview retirement accepted missing volume membership"
        ( isLeft
            ( sitePreviewRetirementScope
                volumeSnapshot
                cluster
                svcName
                "personal"
                host
                []
            )
        )
      let deletableSite = serverSite & #volumes .~ [volume & #retention .~ Delete]
      (deletableScope, _) <-
        either
          (fail . show)
          pure
          ( compileServerSitePreviewScope
              (serverInputs {ServerDeploy.site = deletableSite})
              "branch"
              cluster
              namespaceId
              imageId
              deps
              Map.empty
              Map.empty
              source
          )
      let deletableClaims =
            [ member
            | bundle <- scopeBundles deletableScope
            , Managed member <- declarations bundle
            , member ^. #address == pvcAddress
            ]
      assertBool
        "deletable preview claim has the wrong lifecycle"
        ( case deletableClaims of
            [claim] ->
              claim ^. #lifecycle == DeleteWhenUnreferenced
                && claim ^. #dataPolicy == Stateless
            _ -> False
        )
  ]
