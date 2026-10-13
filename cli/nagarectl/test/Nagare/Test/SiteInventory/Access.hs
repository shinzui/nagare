-- | Protected sites (MasterPlan 27, EP-186): a StaticSite or ServerSite that
-- opts into access reviews a cluster-local origin, one enforcer route per
-- hostname in @nagare-system@, and a backend contribution the auth owner
-- composes into @nagare-access-backends@. The composed map bytes asserted here
-- are the ones the enforcer suite decodes and denies through (its
-- "a site backend map entry" case), so the two packages agree on one literal.
module Nagare.Test.SiteInventory.Access
  ( protectedSiteInventoryTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy (toStrict)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Dsl.Access (AccessPolicy (..), authPortal, mkAccessPermission, mkAudience, requireLogin)
import Nagare.Dsl.Cdn.Types (cloudflareCdn)
import Nagare.Dsl.Config (encodeServerSite, encodeStaticSite)
import Nagare.Dsl.Load (decodeServerSite, decodeStaticSite)
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild), StaticSite, mkFilePathText)
import Nagare.Dsl.Types (mkDomains, mkSecretName, withTlsSecret)
import Nagare.Inventory.Application (AccessBinding, acceptedAccessBinding)
import Nagare.Inventory.BackendMap (compileContributedBackendMaps)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Site
  ( SiteReleaseAction (..)
  , compileServerSiteScopeWith
  , compileStaticSiteScopeWith
  )
import Nagare.Resource.Inventory
  ( BackendRole (ProtectedBackend)
  , Contribution (RegisterBackend)
  , ContributionGrant (BackendMapGrant, ShomeiSettingsGrant)
  , Declaration (External, Managed)
  , ManagedResource
  , ResourceBundle (ResourceBundle, contributions, declarations)
  , ScopeChange (ReplaceScope)
  , ScopeDeclaration
  , ScopeSnapshot
  , backendMapResourceId
  , candidateInventory
  , composeInventory
  , inventoryDeclarations
  , mkScopeDeclaration
  , mkScopeSnapshot
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Protect), Sensitivity (Public))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Server.Deploy qualified as ServerDeploy
import Nagare.Static.Deploy (DeployInputs (..), staticUrl)
import Nagare.Static.Release (StaticRelease (StaticRelease), addRelease, emptyReleaseLog)
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite, demoServerSite)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

protectedSiteInventoryTests :: [TestTree]
protectedSiteInventoryTests =
  [ testCase "a protected static site reviews a private origin, an enforcer route, and the shared backend entry" $ do
      site <- roundTrip (protectedStatic & #domains .~ unsafe (mkDomains [("demo.example.com", True)]))
      (scope, native) <- compileStatic RecordRelease (Just binding) site emptyReleaseLog
      assertProtected scope native "demo.example.com"
      -- Compose with the accepted auth owner: the contribution lands in the
      -- shared backend map as exactly these bytes.
      candidate <- either (fail . show) pure (composeInventory snapshot (ReplaceScope scope :| []))
      maps <- either (fail . T.unpack) pure (compileContributedBackendMaps (inventoryDeclarations (candidateInventory candidate)))
      backends <- case Map.lookup (backendMapResourceId authOwner) maps of
        Just (_, bytes) -> backendsJson bytes
        Nothing -> assertFailure "the auth owner composed no backend map" >> fail "no map"
      backends @?= "{\"demo.example.com\":\"http://demo.personal.svc.cluster.local\"}"
  , testCase "a protected site with no declared domain routes its default hostname through the enforcer" $ do
      site <- roundTrip protectedStatic
      (scope, native) <- compileStatic RecordRelease (Just binding) site emptyReleaseLog
      assertProtected scope native "demo.personal.example.com"
  , testCase "a protected server site reviews the same contract" $ do
      site <- either (fail . show) pure (decodeServerSite (toStrict (encodeServerSite protectedServer)))
      site @?= protectedServer
      let inputs = ServerDeploy.ServerDeployInputs site "v1" "example.com" "." True initProfile
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileServerSiteScopeWith RecordRelease Nothing (Just binding) mempty inputs cluster namespaceId imageId Map.empty Map.empty Map.empty emptyReleaseLog (release "demo.example.com") source)
      assertProtected scope native "demo.example.com"
  , testCase "a rollback keeps the reviewed protection" $ do
      site <- roundTrip (protectedStatic & #domains .~ unsafe (mkDomains [("demo.example.com", True)]))
      let prior = addRelease (release "demo.example.com") emptyReleaseLog
      (scope, native) <- compileStatic SelectRelease (Just binding) site prior
      assertProtected scope native "demo.example.com"
  , testCase "a public site reviews no route in nagare-system and no contribution" $ do
      site <- roundTrip (protectedStatic & #access .~ Nothing & #domains .~ unsafe (mkDomains [("demo.example.com", True)]))
      (scope, native) <- compileStatic RecordRelease Nothing site emptyReleaseLog
      enforcerRoutes scope @?= []
      backendRequests scope @?= []
      assertBool "public origin became cluster-local" (not (any (privateOrigin . snd) (Map.elems native)))
  , testCase "access without its accepted auth binding, or a binding without access, refuses" $ do
      protected <- roundTrip protectedStatic
      public <- roundTrip (protectedStatic & #access .~ Nothing)
      assertBool "protected site planned without auth evidence" (isLeft (compileStaticEither RecordRelease Nothing protected emptyReleaseLog))
      assertBool "public site accepted an auth binding" (isLeft (compileStaticEither RecordRelease (Just binding) public emptyReleaseLog))
      assertBool
        "binding for another base domain accepted"
        (isLeft (compileStaticEitherWith "other.example" RecordRelease (Just binding) protected emptyReleaseLog))
  , testCase "unsupported policies, the portal role, a CDN, and supplied TLS refuse before any route is planned" $ do
      let custom = requireLogin {permission = unsafe (mkAccessPermission "site_access")}
          audience = requireLogin {audience = Just (unsafe (mkAudience "notes"))}
          withPolicy policy = protectedStatic & #access .~ Just policy
      forM_ [withPolicy custom, withPolicy authPortal, withPolicy audience, protectedStatic & #cdn .~ Just cloudflareCdn] $ \site -> do
        loaded <- roundTrip site
        assertBool ("refusal missing for " <> show (loaded ^. #access, loaded ^. #cdn)) (isLeft (compileStaticEither RecordRelease (Just binding) loaded emptyReleaseLog))
      let supplied = protectedStatic & #domains .~ map (withTlsSecret (unsafe (mkSecretName "demo-tls"))) (unsafe (mkDomains [("demo.example.com", True)]))
      loaded <- roundTrip supplied
      assertBool "supplied TLS accepted on a protected site" (isLeft (compileStaticEither RecordRelease (Just binding) loaded emptyReleaseLog))
  ]
  where
    roundTrip site = do
      loaded <- either (fail . show) pure (decodeStaticSite (toStrict (encodeStaticSite site)))
      loaded @?= site
      pure loaded
    compileStatic action accessBinding site prior =
      either (fail . show) pure (compileStaticEither action accessBinding site prior)
    compileStaticEither = compileStaticEitherWith "example.com"
    compileStaticEitherWith baseDomain action accessBinding site prior =
      let inputs = DeployInputs site "v1" baseDomain "." True initProfile
          current = release (T.drop (T.length "https://") (staticUrl site baseDomain))
       in compileStaticSiteScopeWith action Nothing accessBinding inputs cluster namespaceId imageId Map.empty prior current source
    assertProtected scope native host = do
      Resource.scopeKind (scopeId scope) @?= Resource.Standalone
      let routes = enforcerRoutes scope
      map (\route -> route ^. #aliases) routes @?= [[Resource.Hostname (unsafe (Resource.mkName host))]]
      assertBool
        "enforcer route does not order after the shared backend map and the enforcer"
        ( all
            (\route -> all (`elem` route ^. #dependencies) [OrderedAfter (backendMapResourceId authOwner), OrderedAfter enforcerId])
            routes
        )
      -- No DomainMapping remains in the site's own namespace.
      [ ()
        | bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        , Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) _ <- [member ^. #address]
        , kind == unsafe (Resource.mkName "domainmapping")
        , ns /= unsafe (Resource.mkName "nagare-system")
        ]
        @?= []
      routeBytes <- case routes of
        [route] -> maybe (assertFailure "route has no native bytes" >> fail "no bytes") (pure . snd) (Map.lookup (route ^. #identity) native)
        other -> assertFailure ("expected one enforcer route, got " <> show (length other)) >> fail "routes"
      assertBool "route does not target the enforcer" (BC.isInfixOf "\"name\":\"nagare-access\"" routeBytes)
      assertBool "the origin is still publicly routable" (any (privateOrigin . snd) (Map.elems native))
      backendRequests scope
        @?= [ RegisterBackend
                authOwner
                cluster
                (unsafe (Resource.mkName host))
                "http://demo.personal.svc.cluster.local"
                ProtectedBackend
                (unsafe (Resource.mkLogicalKey host))
            ]
    enforcerRoutes scope =
      [ member
      | bundle <- scopeBundles scope
      , Managed member <- declarations bundle
      , Resource.Kubernetes _ "serving.knative.dev" kind (Just ns) _ <- [member ^. #address]
      , kind == unsafe (Resource.mkName "domainmapping")
      , ns == unsafe (Resource.mkName "nagare-system")
      ]
    backendRequests scope =
      [request | bundle <- scopeBundles scope, request@RegisterBackend {} <- contributions bundle]
    privateOrigin = BC.isInfixOf "\"networking.knative.dev/visibility\":\"cluster-local\""
    backendsJson :: ByteString -> IO ByteString
    backendsJson bytes = case eitherDecodeStrict bytes of
      Right (Object root)
        | Just (Object payload) <- KM.lookup "data" root
        , Just (String json) <- KM.lookup "backends.json" payload ->
            pure (BC.pack (T.unpack json))
      other -> assertFailure ("backend map ConfigMap has no backends.json: " <> show other) >> fail "no data"

protectedStatic :: StaticSite
protectedStatic =
  baseSite (NoBuild (unsafe (mkFilePathText "dist")))
    & #access
    .~ Just requireLogin

protectedServer :: ServerSite
protectedServer =
  demoServerSite
    & #domains
    .~ unsafe (mkDomains [("demo.example.com", True)])
    & #access
    .~ Just requireLogin

release :: Text -> StaticRelease
release host =
  StaticRelease
    "v1"
    "demo"
    "personal"
    "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo"
    "v1"
    ("https://" <> host)
    Nothing
    (UTCTime (fromGregorian 2026 10 12) 0)

source :: Resource.SourceLocation
source = Resource.SourceLocation "fixture" "protected-site"

-- ---------------------------------------------------------------------------
-- The accepted foundation and auth owner a protected site binds against.

foundation :: Resource.ScopeId
foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")

cluster, namespaceId, imageId :: Resource.ResourceId
cluster = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
namespaceId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "namespace")) (unsafe (Resource.mkName "resource"))
imageId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "image")) (unsafe (Resource.mkName "publication"))

authOwner :: Resource.ScopeId
authOwner = unsafe (Resource.mkScopeId Resource.Platform "auth")

enforcerId :: Resource.ResourceId
enforcerId = unsafe (Resource.mkResourceId "platform:auth/nagare-access/service")

enforcer :: ManagedResource
enforcer =
  fst
    ( ok
        ( bindKubernetesObject
            KubernetesInput
              { resourceId = enforcerId
              , ownerScope = authOwner
              , clusterId = cluster
              , inputObject = value
              , objectDigest = contentDigest (unsafe (canonicalValue value))
              , lifecyclePolicy = Protect
              , inputDataPolicy = Stateless
              , inputSensitivity = Public
              , sourceLocation = Resource.SourceLocation "fixture" "nagare-access"
              }
        )
    )
  where
    value =
      object
        [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
        , "kind" .= ("Service" :: Text)
        , "metadata" .= object ["name" .= ("nagare-access" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "spec" .= object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("fixture-enforcer:accepted" :: Text)]]]]]
        ]

foundationScope, authScope :: ScopeDeclaration
foundationScope =
  ok
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
authScope =
  ok
    ( mkScopeDeclaration
        authOwner
        [ ResourceBundle
            [Managed enforcer]
            []
            []
            []
            []
            [BackendMapGrant cluster, ShomeiSettingsGrant cluster (unsafe (Resource.mkName "example.com"))]
        ]
    )

snapshot :: ScopeSnapshot
snapshot =
  ok
    ( mkScopeSnapshot
        (Resource.ContextBinding (unsafe (Resource.mkContextId "protected-site")) (unsafe (Resource.mkName "project")))
        (Map.fromList [(scopeId scope, (unsafe (Resource.mkScopeGeneration 1), scope)) | scope <- [foundationScope, authScope]])
        Map.empty
    )

binding :: AccessBinding
binding = either (error . T.unpack) id (acceptedAccessBinding snapshot cluster)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
