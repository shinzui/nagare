-- | SiteInventory responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.SiteInventory.Server
  ( serverSiteInventoryTests
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Dsl.Cdn.Types (cloudflareCdn)
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
import Nagare.Dsl.Static.Types (mkSiteName)
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , EnvScope (Build, Preview, Runtime)
  , EnvVar (EnvSecretRef)
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
  , mkDomains
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
import Nagare.Inventory.Application
  ( CloudflareCdnBinding (CloudflareCdnBinding)
  )
import Nagare.Inventory.Site
  ( compileServerSiteRollbackScope
  , compileServerSiteRollbackScopeWithBuild
  , compileServerSiteRollbackScopeWithCloudflare
  , compileServerSiteScope
  , compileServerSiteScopeWithBuild
  , compileServerSiteScopeWithCloudflare
  , legacyServerSiteReleaseImport
  , siteVolumeRecoveryBindings
  )
import Nagare.Resource.Inventory
  ( Declaration (External, Managed)
  , ResourceBundle (contributions, declarations)
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Inventory qualified as InventoryModel
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Server.Deploy qualified as ServerDeploy
import Nagare.Static.Release
  ( StaticRelease (StaticRelease, createdAt, imageTag, releaseId)
  , addRelease
  , emptyReleaseLog
  , extractReleaseLog
  , renderReleaseConfigMap
  )
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures

serverSiteInventoryTests :: [TestTree]
serverSiteInventoryTests =
  [ testCase "server site review binds its release and refuses untyped Secrets" $ do
      let site =
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
              , domains = unsafe (mkDomains [("demo.example.com", True)])
              , volumes = []
              , cdn = Nothing
              }
          inputs = ServerDeploy.ServerDeployInputs site "v1" "example.com" "." True initProfile
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
          release =
            StaticRelease
              "v1"
              "demo"
              "personal"
              "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo"
              "v1"
              (ServerDeploy.serverUrl site "example.com")
              Nothing
              (UTCTime (fromGregorian 2026 9 24) 0)
          source = Resource.SourceLocation "fixture" "server-site"
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileServerSiteScope inputs cluster namespaceId imageId Map.empty Map.empty Map.empty emptyReleaseLog release source)
      Map.size native @?= 3
      length [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
        @?= 3
      let cloudflareOwner = unsafe (Resource.mkScopeId Resource.Platform "cdn")
          cloudflareBinding =
            CloudflareCdnBinding
              (unsafe (Resource.mkName "zone-id"))
              cloudflareOwner
              "203.0.113.5"
          cloudflareInputs = inputs & #site . #cdn .~ Just cloudflareCdn
      (cloudflareScope, _) <-
        either
          (fail . show)
          pure
          ( compileServerSiteScopeWithCloudflare
              cloudflareBinding
              cloudflareInputs
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              emptyReleaseLog
              release
              source
          )
      length
        [ member
        | bundle <- scopeBundles cloudflareScope
        , Managed member <- declarations bundle
        , member ^. #spec == InventoryModel.CloudflareProxiedARecord "203.0.113.5"
        ]
        @?= 1
      length
        [ request
        | bundle <- scopeBundles cloudflareScope
        , request@InventoryModel.RegisterCloudflareCache {} <- contributions bundle
        ]
        @?= 1
      let older =
            release
              { releaseId = "v0"
              , imageTag = "v0"
              , createdAt = UTCTime (fromGregorian 2026 9 23) 0
              }
          oldLog = addRelease release (addRelease older emptyReleaseLog)
          historyId =
            Resource.mintResourceId
              (scopeId scope)
              (unsafe (Resource.mkLogicalKey "release-history"))
              (unsafe (Resource.mkName "configmap"))
      (_, rollbackNative) <-
        either
          (fail . show)
          pure
          ( compileServerSiteRollbackScope
              (inputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              oldLog
              older
              source
          )
      Map.keysSet rollbackNative @?= Map.keysSet native
      (_, rollbackHistoryBytes) <-
        maybe
          (fail "missing server rollback history")
          pure
          (Map.lookup historyId rollbackNative)
      extractReleaseLog rollbackHistoryBytes @?= Right (oldLog & #current .~ Just "v0")
      (cloudflareRollback, _) <-
        either
          (fail . show)
          pure
          ( compileServerSiteRollbackScopeWithCloudflare
              cloudflareBinding
              (cloudflareInputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              oldLog
              older
              source
          )
      length
        [ member
        | bundle <- scopeBundles cloudflareRollback
        , Managed member <- declarations bundle
        , member ^. #spec == InventoryModel.CloudflareProxiedARecord "203.0.113.5"
        ]
        @?= 1
      legacyServerSiteReleaseImport
        site
        "v1"
        (renderReleaseConfigMap "demo" "personal" (addRelease release emptyReleaseLog))
        @?= Right (addRelease release emptyReleaseLog, release)
      let secretSite =
            site
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "API_KEY"))
                (runtimeScoped (EnvSecretRef (unsafe (mkSecretName "external"))))
      assertBool
        "server-site Secret bypassed typed dependency check"
        ( isLeft
            ( compileServerSiteScope
                (inputs {ServerDeploy.site = secretSite})
                cluster
                namespaceId
                imageId
                Map.empty
                Map.empty
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
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
          secretBinding = External secretId secretAddress [] source
          secretBindings = Map.singleton secretName secretBinding
          buildSecretSite =
            site
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "BUILD_TOKEN"))
                (unsafe (scopedEnv (Set.singleton Build) (EnvSecretRef secretName)))
          buildInputs = inputs {ServerDeploy.site = buildSecretSite}
      (_, buildNative) <-
        either
          (fail . show)
          pure
          ( compileServerSiteScopeWithBuild
              (Set.singleton secretName)
              Nothing
              buildInputs
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              emptyReleaseLog
              release
              source
          )
      assertBool
        "Build Secret leaked into production native manifests"
        (all (not . BC.isInfixOf "BUILD_TOKEN" . snd) (Map.elems buildNative))
      assertBool
        "production accepted a Build Secret absent from image inputs"
        ( isLeft
            ( compileServerSiteScopeWithBuild
                Set.empty
                Nothing
                buildInputs
                cluster
                namespaceId
                imageId
                Map.empty
                Map.empty
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      let mixedBuildSite =
            site
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "BUILD_TOKEN"))
                ( unsafe
                    ( scopedEnv
                        (Set.fromList [Build, Runtime])
                        (EnvSecretRef secretName)
                    )
                )
      assertBool
        "production accepted a mixed Build/Runtime Secret"
        ( isLeft
            ( compileServerSiteScopeWithBuild
                (Set.singleton secretName)
                Nothing
                (inputs {ServerDeploy.site = mixedBuildSite})
                cluster
                namespaceId
                imageId
                Map.empty
                secretBindings
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      (_, buildRollbackNative) <-
        either
          (fail . show)
          pure
          ( compileServerSiteRollbackScopeWithBuild
              (Set.singleton secretName)
              Nothing
              (buildInputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              oldLog
              older
              source
          )
      assertBool
        "Build Secret leaked into rollback native manifests"
        ( all
            (not . BC.isInfixOf "BUILD_TOKEN" . snd)
            (Map.elems buildRollbackNative)
        )
      (secretScope, _) <-
        either
          (fail . show)
          pure
          ( compileServerSiteScope
              (inputs {ServerDeploy.site = secretSite})
              cluster
              namespaceId
              imageId
              Map.empty
              secretBindings
              Map.empty
              emptyReleaseLog
              release
              source
          )
      assertBool
        "server-site Service lacks accepted Secret ordering"
        ( any
            (elem (OrderedAfter secretId) . (^. #dependencies))
            [member | bundle <- scopeBundles secretScope, Managed member <- declarations bundle]
        )
      let wrongAddress =
            unsafe
              ( Resource.kubernetesAddress
                  cluster
                  "v1"
                  "Secret"
                  (Just "another-namespace")
                  "external"
              )
      assertBool
        "server-site accepted a Secret from another namespace"
        ( isLeft
            ( compileServerSiteScope
                (inputs {ServerDeploy.site = secretSite})
                cluster
                namespaceId
                imageId
                Map.empty
                (Map.singleton secretName (External secretId wrongAddress [] source))
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      let previewSecretSite =
            site
              & #env
              .~ Map.singleton
                (unsafe (mkEnvName "API_KEY"))
                (unsafe (scopedEnv (Set.singleton Preview) (EnvSecretRef secretName)))
      _ <-
        either
          (fail . show)
          pure
          ( compileServerSiteScope
              (inputs {ServerDeploy.site = previewSecretSite})
              cluster
              namespaceId
              imageId
              Map.empty
              Map.empty
              Map.empty
              emptyReleaseLog
              release
              source
          )
      assertBool
        "production accepted an irrelevant Preview Secret binding"
        ( isLeft
            ( compileServerSiteScope
                (inputs {ServerDeploy.site = previewSecretSite})
                cluster
                namespaceId
                imageId
                Map.empty
                secretBindings
                Map.empty
                emptyReleaseLog
                release
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
          volumeSite = site & #volumes .~ [volume]
      assertBool
        "retained server volume accepted without recovery"
        ( isLeft
            ( compileServerSiteScope
                (inputs {ServerDeploy.site = volumeSite})
                cluster
                namespaceId
                imageId
                Map.empty
                Map.empty
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      recovery <-
        either
          (fail . T.unpack)
          pure
          (siteVolumeRecoveryBindings volumeSite ["data=backup:key:v1"])
      (_, volumeNative) <-
        either
          (fail . show)
          pure
          ( compileServerSiteScope
              (inputs {ServerDeploy.site = volumeSite})
              cluster
              namespaceId
              imageId
              recovery
              Map.empty
              Map.empty
              emptyReleaseLog
              release
              source
          )
      Map.size volumeNative @?= 4
  ]
