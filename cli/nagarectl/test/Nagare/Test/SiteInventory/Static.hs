-- | SiteInventory responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.SiteInventory.Static
  ( staticSiteInventoryTests
  )
where

import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Cdn.Provision (GcpStackRefs (GcpStackRefs))
import Nagare.Dsl.Cdn.Types (cloudflareCdn, gcpCloudCdn)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Static.Types
  ( StaticBuild (NoBuild)
  , mkFilePathText
  )
import Nagare.Dsl.Types (mkDomains, mkSecretName, withTlsSecret)
import Nagare.Inventory.Application
  ( CloudflareCdnBinding (..)
  , GoogleCdnBinding (..)
  )
import Nagare.Inventory.Site
  ( acceptedSiteSource
  , compileStaticSiteRollbackScope
  , compileStaticSiteRollbackScopeWithCdn
  , compileStaticSiteRollbackScopeWithCloudflare
  , compileStaticSiteScope
  , compileStaticSiteScopeWithCdn
  , compileStaticSiteScopeWithCloudflare
  , legacyStaticSiteReleaseImport
  , siteNativeOwned
  )
import Nagare.Resource.Inventory
  ( Declaration (External, Managed)
  , ResourceBundle (contributions, declarations)
  , mkScopeSnapshot
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Inventory qualified as InventoryModel
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Policy qualified as InventoryPolicy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Static.Deploy (DeployInputs (..), staticUrl)
import Nagare.Static.Release
  ( StaticRelease (StaticRelease, createdAt, imageTag, releaseId)
  , addRelease
  , emptyReleaseLog
  , extractReleaseLog
  , renderReleaseConfigMap
  )
import Nagare.Storage.Discover (pvcName)
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixtures

staticSiteInventoryTests :: [TestTree]
staticSiteInventoryTests =
  [ testCase "static site review binds rendered service, domain, and release" $ do
      let site =
            baseSite (NoBuild (unsafe (mkFilePathText "dist")))
              & #domains
              .~ unsafe (mkDomains [("demo.example.com", True)])
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
          release =
            StaticRelease
              "v1"
              "demo"
              "personal"
              "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo"
              "v1"
              (staticUrl site "example.com")
              Nothing
              (UTCTime (fromGregorian 2026 9 24) 0)
          source = Resource.SourceLocation "fixture" "static-site"
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileStaticSiteScope inputs cluster namespaceId imageId Map.empty emptyReleaseLog release source)
      let binding =
            Resource.ContextBinding
              (unsafe (Resource.mkContextId "test"))
              (unsafe (Resource.mkName "project"))
      snapshot <-
        either
          (fail . show)
          pure
          ( mkScopeSnapshot
              binding
              (Map.singleton (scopeId scope) (unsafe (Resource.mkScopeGeneration 1), scope))
              Map.empty
          )
      acceptedSiteSource snapshot "demo" "personal" cluster @?= Right source
      Resource.scopeKind (scopeId scope) @?= Resource.Standalone
      Map.size native @?= 3
      let cdnOwner = unsafe (Resource.mkScopeId Resource.Platform "cdn")
          cdnBackendId =
            Resource.mintResourceId
              cdnOwner
              (unsafe (Resource.mkLogicalKey "backend"))
              (unsafe (Resource.mkName "backend"))
          cdnBackend =
            InventoryModel.ManagedResource
              cdnBackendId
              cdnOwner
              InventoryModel.PulumiExecutor
              (Resource.PulumiUrn "urn:pulumi:stack::project::gcp:compute/backendService:BackendService::backend")
              []
              (InventoryModel.NativeObject (unsafe (Resource.mkContentDigest (T.replicate 64 "a"))))
              InventoryPolicy.Retain
              Stateless
              InventoryPolicy.Private
              []
              []
              source
          cdnSite = site & #cdn .~ Just gcpCloudCdn
          cdnInputs = inputs & #site .~ cdnSite
          cdnBinding =
            GoogleCdnBinding
              (GcpStackRefs "203.0.113.4" "backend" "urlmap" "zone" "tan-nb-exp")
              (Managed cdnBackend)
      (cdnScope, cdnNative) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteScopeWithCdn
              cdnBinding
              cdnInputs
              cluster
              namespaceId
              imageId
              Map.empty
              emptyReleaseLog
              release
              source
          )
      let dnsMembers =
            [ member
            | bundle <- scopeBundles cdnScope
            , Managed member <- declarations bundle
            , member ^. #executor == InventoryModel.CdnExecutor
            ]
      length dnsMembers @?= 1
      Map.size cdnNative @?= Map.size native
      let cloudflareSite = site & #cdn .~ Just cloudflareCdn
          cloudflareInputs = inputs & #site .~ cloudflareSite
          cloudflareBinding =
            CloudflareCdnBinding
              (unsafe (Resource.mkName "zone-id"))
              cdnOwner
              "203.0.113.5"
      (cloudflareScope, cloudflareNative) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteScopeWithCloudflare
              cloudflareBinding
              cloudflareInputs
              cluster
              namespaceId
              imageId
              Map.empty
              emptyReleaseLog
              release
              source
          )
      let cloudflareDns =
            [ member
            | bundle <- scopeBundles cloudflareScope
            , Managed member <- declarations bundle
            , member ^. #spec == InventoryModel.CloudflareProxiedARecord "203.0.113.5"
            ]
          cloudflareCache =
            [ request
            | bundle <- scopeBundles cloudflareScope
            , request@InventoryModel.RegisterCloudflareCache {} <- contributions bundle
            ]
      length cloudflareDns @?= 1
      length cloudflareCache @?= 1
      Map.keysSet cloudflareNative @?= Map.keysSet native
      assertBool
        "site accepted a Cloudflare binding for Google CDN intent"
        ( isLeft
            ( compileStaticSiteScopeWithCloudflare
                cloudflareBinding
                cdnInputs
                cluster
                namespaceId
                imageId
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      assertBool
        "site CDN without a typed owner must refuse"
        ( isLeft
            ( compileStaticSiteScope
                cdnInputs
                cluster
                namespaceId
                imageId
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      let members =
            [ member
            | bundle <- scopeBundles scope
            , Managed member <- declarations bundle
            ]
      length members @?= 3
      assertBool "domain has no hostname claim" (any (not . null . (^. #aliases)) members)
      let releaseId =
            Resource.mintResourceId
              (scopeId scope)
              (unsafe (Resource.mkLogicalKey "release-history"))
              (unsafe (Resource.mkName "configmap"))
      releaseMember <-
        maybe
          (fail "missing release member")
          (pure . fst)
          (Map.lookup releaseId native)
      assertBool
        "direct site write missed retained release history"
        (siteNativeOwned "demo" "personal" [] [] True [releaseMember])
      assertBool
        "preview falsely writes production release history"
        (not (siteNativeOwned "demo" "personal" [] [] False [releaseMember]))
      let domainMembers = filter (not . null . (^. #aliases)) members
      assertBool
        "direct site write missed owned domain"
        (siteNativeOwned "other" "personal" ["demo.example.com"] [] False domainMembers)
      let retainedClaim =
            releaseMember
              & #address
              .~ unsafe
                ( Resource.kubernetesAddress
                    cluster
                    "v1"
                    "PersistentVolumeClaim"
                    (Just "personal")
                    (pvcName "demo" "data")
                )
      assertBool
        "direct server deploy missed retained PVC after Service collection"
        (siteNativeOwned "demo" "personal" [] ["data"] False [retainedClaim])
      assertBool
        "direct server deploy matched an unrelated retained PVC"
        (not (siteNativeOwned "demo" "personal" [] ["other"] False [retainedClaim]))
      assertBool
        "static release accepted a different image tag"
        ( isLeft
            ( compileStaticSiteScope
                inputs
                cluster
                namespaceId
                imageId
                Map.empty
                emptyReleaseLog
                (release {imageTag = "other"})
                source
            )
        )
      let tlsName = unsafe (mkSecretName "site-tls")
          tlsSite = site & #domains %~ map (withTlsSecret tlsName)
          tlsInputs = inputs & #site .~ tlsSite
          tlsId =
            Resource.mintResourceId
              foundation
              (unsafe (Resource.mkLogicalKey "site-tls"))
              (unsafe (Resource.mkName "secret"))
          tlsAddress =
            unsafe
              ( Resource.kubernetesAddress
                  cluster
                  "v1"
                  "Secret"
                  (Just "personal")
                  "site-tls"
              )
          tlsBindings = Map.singleton tlsName (External tlsId tlsAddress [] source)
      assertBool
        "supplied TLS accepted without an owned Secret"
        ( isLeft
            ( compileStaticSiteScope
                tlsInputs
                cluster
                namespaceId
                imageId
                Map.empty
                emptyReleaseLog
                release
                source
            )
        )
      (tlsScope, _) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteScope
              tlsInputs
              cluster
              namespaceId
              imageId
              tlsBindings
              emptyReleaseLog
              release
              source
          )
      assertBool
        "site DomainMapping lacks supplied TLS Secret ordering"
        ( any
            (elem (OrderedAfter tlsId) . (^. #dependencies))
            [member | bundle <- scopeBundles tlsScope, Managed member <- declarations bundle]
        )
      let wrongTlsAddress =
            unsafe
              ( Resource.kubernetesAddress
                  cluster
                  "v1"
                  "Secret"
                  (Just "other")
                  "site-tls"
              )
      assertBool
        "site accepted supplied TLS from another namespace"
        ( isLeft
            ( compileStaticSiteScope
                tlsInputs
                cluster
                namespaceId
                imageId
                (Map.singleton tlsName (External tlsId wrongTlsAddress [] source))
                emptyReleaseLog
                release
                source
            )
        )
      let older =
            release
              { releaseId = "v0"
              , imageTag = "v0"
              , createdAt = UTCTime (fromGregorian 2026 9 23) 0
              }
          oldLog = addRelease release (addRelease older emptyReleaseLog)
          legacyBytes = renderReleaseConfigMap "demo" "personal" oldLog
      (_, rollbackNative) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteRollbackScope
              (inputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              oldLog
              older
              source
          )
      Map.keysSet rollbackNative @?= Map.keysSet native
      (_, rollbackHistoryBytes) <-
        maybe
          (fail "missing rollback history")
          pure
          (Map.lookup releaseId rollbackNative)
      extractReleaseLog rollbackHistoryBytes @?= Right (oldLog & #current .~ Just "v0")
      (cdnRollbackScope, cdnRollbackNative) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteRollbackScopeWithCdn
              cdnBinding
              (cdnInputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              oldLog
              older
              source
          )
      Map.keysSet cdnRollbackNative @?= Map.keysSet cdnNative
      assertBool
        "CDN rollback lost its DNS declaration"
        ( any
            ( \bundle ->
                any
                  ( \case
                      Managed member -> member ^. #executor == InventoryModel.CdnExecutor
                      _ -> False
                  )
                  (declarations bundle)
            )
            (scopeBundles cdnRollbackScope)
        )
      (cloudflareRollback, _) <-
        either
          (fail . show)
          pure
          ( compileStaticSiteRollbackScopeWithCloudflare
              cloudflareBinding
              (cloudflareInputs & #imageTag .~ "v0")
              cluster
              namespaceId
              imageId
              Map.empty
              oldLog
              older
              source
          )
      assertBool
        "Cloudflare rollback lost its DNS declaration"
        ( any
            ( \bundle ->
                any
                  ( \case
                      Managed member -> member ^. #spec == InventoryModel.CloudflareProxiedARecord "203.0.113.5"
                      _ -> False
                  )
                  (declarations bundle)
            )
            (scopeBundles cloudflareRollback)
        )
      assertBool
        "rollback invented a release outside accepted history"
        ( isLeft
            ( compileStaticSiteRollbackScope
                (inputs & #imageTag .~ "v2")
                cluster
                namespaceId
                imageId
                Map.empty
                oldLog
                (older {releaseId = "v2", imageTag = "v2"})
                source
            )
        )
      legacyStaticSiteReleaseImport site "v1" legacyBytes @?= Right (oldLog, release)
      assertBool
        "legacy static-site import accepted a different rollout tag"
        (isLeft (legacyStaticSiteReleaseImport site "v2" legacyBytes))
      assertBool
        "legacy static-site import would reorder old entries"
        ( isLeft
            ( legacyStaticSiteReleaseImport
                site
                "v1"
                ( renderReleaseConfigMap
                    "demo"
                    "personal"
                    (oldLog & #releases %~ reverse)
                )
            )
        )
  ]
