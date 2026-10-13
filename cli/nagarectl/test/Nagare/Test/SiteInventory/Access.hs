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
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Dsl.Access (AccessPolicy (..), authPortal, mkAccessPermission, mkAudience, requireLogin)
import Nagare.Dsl.Cdn.Types (cloudflareCdn)
import Nagare.Dsl.Config (encodeServerSite, encodeStaticSite)
import Nagare.Dsl.Load (decodeServerSite, decodeStaticSite)
import Nagare.Dsl.Prelude hiding ((.=), (<.>))
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild), StaticSite, mkFilePathText, mkSiteName, siteNameText)
import Nagare.Dsl.Types (mkDomains, mkSecretName, withTlsSecret)
import Nagare.Inventory.Adapter (PlannedOperation (..), ResourceObservation (ConfirmedAbsent), observationSet)
import Nagare.Inventory.Application (AccessBinding, acceptedAccessBinding)
import Nagare.Inventory.BackendMap (compileContributedBackendMaps)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Environment (compilePreviewEnvChannel, compilePreviewSecretChannel, compileRuntimeEnvChannel, compileRuntimeSecretChannel)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
  ( PlanError (..)
  , historyAccepted
  , historyReservations
  , loadInventoryHistory
  , loadInventoryPlanningHistory
  , noLifecycleDecisions
  , observationRequirements
  , planChanges
  , proposalOperations
  , requiredResources
  , seedInventoryHistory
  )
import Nagare.Inventory.Site
  ( SiteReleaseAction (..)
  , acceptedSitePreviewDependencies
  , compileServerSiteScopeWith
  , compileStaticSitePreviewScope
  , compileStaticSiteScopeWith
  , sitePreviewRetirementScope
  )
import Nagare.Inventory.Store (ScopeRevision (..), initializeStore, newMemoryStore)
import Nagare.Resource.Inventory
  ( BackendRole (ProtectedBackend)
  , Contribution (RegisterBackend)
  , ContributionGrant (BackendMapGrant, ShomeiSettingsGrant)
  , Declaration (External, Managed)
  , DesiredSpec (NativeObject)
  , Executor (KubernetesExecutor)
  , ManagedResource (ManagedResource)
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
  , snapshotScopes
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Protect, Retain), Sensitivity (Public))
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
      assertProtected scope native "demo.example.com" demoUpstream
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
      assertProtected scope native "demo.personal.example.com" demoUpstream
  , testCase "a protected server site reviews the same contract" $ do
      site <- either (fail . show) pure (decodeServerSite (toStrict (encodeServerSite protectedServer)))
      site @?= protectedServer
      let inputs = ServerDeploy.ServerDeployInputs site "v1" "example.com" "." True initProfile
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileServerSiteScopeWith RecordRelease Nothing (Just binding) mempty inputs cluster namespaceId imageId Map.empty Map.empty Map.empty emptyReleaseLog (releaseFor "demo" "demo.example.com") source)
      assertProtected scope native "demo.example.com" demoUpstream
  , testCase "a rollback keeps the reviewed protection" $ do
      site <- roundTrip (protectedStatic & #domains .~ unsafe (mkDomains [("demo.example.com", True)]))
      let prior = addRelease (releaseFor "demo" "demo.example.com") emptyReleaseLog
      (scope, native) <- compileStatic SelectRelease (Just binding) site prior
      assertProtected scope native "demo.example.com" demoUpstream
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
  , testCase "a protected site's preview is its own protected hostname with its own backend entry" $ do
      site <- roundTrip protectedStatic
      let inputs = DeployInputs site "v1" "example.com" "." True initProfile
          previewHost = "branch.demo.preview.example.com"
      (previewSnapshot, stores) <- previewFixture
      (scope, native) <-
        either
          (fail . show)
          pure
          (compileStaticSitePreviewScope (Just binding) inputs "branch" cluster namespaceId imageId stores source)
      assertProtected scope native previewHost "http://demo-pr-branch.personal.svc.cluster.local"
      -- Retirement and cleanup find the enforcer route as the preview's one route.
      withPreview <-
        either
          (fail . show)
          pure
          (mkScopeSnapshot context (Map.insert (scopeId scope) (generation, scope) (snapshotScopes previewSnapshot)) Map.empty)
      sitePreviewRetirementScope withPreview cluster "demo-pr-branch" "personal" previewHost [] @?= Right (scopeId scope)
      assertBool
        "protected preview planned without auth evidence"
        (isLeft (compileStaticSitePreviewScope Nothing inputs "branch" cluster namespaceId imageId stores source))
      (publicScope, _) <-
        either
          (fail . show)
          pure
          (compileStaticSitePreviewScope Nothing (inputs & #site . #access .~ Nothing) "branch" cluster namespaceId imageId stores source)
      enforcerRoutes publicScope @?= []
  , testCase "an accepted public site cannot become protected in place; its route needs a reviewed retirement first" $ do
      public <- roundTrip (protectedStatic & #access .~ Nothing & #domains .~ demoDomains)
      protected <- roundTrip (protectedStatic & #domains .~ demoDomains)
      (publicScope, _) <- compileStatic RecordRelease Nothing public emptyReleaseLog
      (protectedScope, _) <- compileStatic RecordRelease (Just binding) protected emptyReleaseLog
      -- The route keeps its identity and moves its native address, which the
      -- planner refuses in place: the reviewed path retires and collects the
      -- public route first.
      map (^. #identity) (siteRoutes publicScope) @?= map (^. #identity) (siteRoutes protectedScope)
      assertBool "the protected route kept the public address" (map (^. #address) (siteRoutes publicScope) /= map (^. #address) (siteRoutes protectedScope))
      store <- newMemoryStore
      _ <- initializeStore store context "protected-site" >>= either (fail . show) pure
      let seeded = ok (mkScopeSnapshot context (Map.insert (scopeId publicScope) (generation, publicScope) (snapshotScopes snapshot)) Map.empty)
          placeholder = ok (mkScopeDeclaration (unsafe (Resource.mkScopeId Resource.Standalone "placeholder")) [])
      _ <- seedInventoryHistory store (ok (composeInventory seeded (ReplaceScope placeholder :| []))) >>= either (fail . show) pure
      history <- loadInventoryHistory store >>= either (fail . show) pure
      let accepted = ok (mkScopeSnapshot context (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
          candidate = ok (composeInventory accepted (ReplaceScope protectedScope :| []))
      planning <- loadInventoryPlanningHistory store candidate >>= either (fail . show) pure
      let observed =
            ok
              ( observationSet
                  [ (resource, ConfirmedAbsent (contentDigest "absent"))
                  | resource <- Set.toAscList (requiredResources (observationRequirements candidate planning))
                  ]
              )
      case planChanges candidate noLifecycleDecisions planning observed of
        Left errors -> assertBool (show errors) (any ((== "migration-review-required") . planErrorCode) (NE.toList errors))
        Right proposal -> assertFailure ("a public route was rewritten in place: " <> show (map plannedResources (proposalOperations proposal)))
  , testCase "two sites cannot claim one protected hostname" $ do
      first' <- roundTrip (protectedStatic & #domains .~ demoDomains)
      second <- roundTrip (protectedStatic & #name .~ unsafe (mkSiteName "other") & #domains .~ demoDomains)
      (firstScope, _) <- compileStatic RecordRelease (Just binding) first' emptyReleaseLog
      (secondScope, _) <- compileStatic RecordRelease (Just binding) second emptyReleaseLog
      withFirst <-
        either
          (fail . show)
          pure
          (mkScopeSnapshot context (Map.insert (scopeId firstScope) (generation, firstScope) (snapshotScopes snapshot)) Map.empty)
      assertBool "a second site claimed an accepted protected hostname" (isLeft (composeInventory withFirst (ReplaceScope secondScope :| [])))
  , testCase "an unrelated accepted contributor keeps its backend entry beside the site's" $ do
      site <- roundTrip (protectedStatic & #domains .~ demoDomains)
      (scope, _) <- compileStatic RecordRelease (Just binding) site emptyReleaseLog
      withOther <-
        either
          (fail . show)
          pure
          (mkScopeSnapshot context (Map.insert (scopeId otherApp) (generation, otherApp) (snapshotScopes snapshot)) Map.empty)
      candidate <- either (fail . show) pure (composeInventory withOther (ReplaceScope scope :| []))
      maps <- either (fail . T.unpack) pure (compileContributedBackendMaps (inventoryDeclarations (candidateInventory candidate)))
      backends <- maybe (assertFailure "no composed backend map" >> fail "no map") (backendsJson . snd) (Map.lookup (backendMapResourceId authOwner) maps)
      backends @?= "{\"demo.example.com\":\"http://demo.personal.svc.cluster.local\",\"other.example.com\":\"http://other.personal.svc.cluster.local\"}"
  ]
  where
    demoDomains = unsafe (mkDomains [("demo.example.com", True)])
    demoUpstream = "http://demo.personal.svc.cluster.local"
    siteRoutes scope =
      [ member
      | bundle <- scopeBundles scope
      , Managed member <- declarations bundle
      , Resource.Kubernetes _ "serving.knative.dev" kind _ _ <- [member ^. #address]
      , kind == unsafe (Resource.mkName "domainmapping")
      ]
    previewFixture = do
      stores <-
        traverse
          (either (fail . show) pure)
          [ compileRuntimeEnvChannel "demo" "personal" cluster namespaceId Map.empty source
          , compileRuntimeSecretChannel "demo" "personal" cluster namespaceId (unsafe (Resource.mkName "v1")) Map.empty source
          , compilePreviewEnvChannel "demo" "personal" cluster namespaceId Map.empty source
          , compilePreviewSecretChannel "demo" "personal" cluster namespaceId (unsafe (Resource.mkName "v1")) Map.empty source
          ]
      previewSnapshot <-
        either
          (fail . show)
          pure
          ( mkScopeSnapshot
              context
              (Map.union (Map.fromList [(scopeId store, (generation, store)) | (store, _) <- stores]) (snapshotScopes snapshot))
              Map.empty
          )
      declarations' <-
        either
          (fail . T.unpack)
          pure
          (acceptedSitePreviewDependencies previewSnapshot cluster "demo" "personal" (concatMap (Map.keys . snd) stores))
      pure (previewSnapshot, declarations')
    roundTrip site = do
      loaded <- either (fail . show) pure (decodeStaticSite (toStrict (encodeStaticSite site)))
      loaded @?= site
      pure loaded
    compileStatic action accessBinding site prior =
      either (fail . show) pure (compileStaticEither action accessBinding site prior)
    compileStaticEither = compileStaticEitherWith "example.com"
    compileStaticEitherWith baseDomain action accessBinding site prior =
      let inputs = DeployInputs site "v1" baseDomain "." True initProfile
          current = releaseFor (siteNameText (site ^. #name)) (T.drop (T.length "https://") (staticUrl site baseDomain))
       in compileStaticSiteScopeWith action Nothing accessBinding inputs cluster namespaceId imageId Map.empty prior current source
    assertProtected scope native host upstream = do
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
                upstream
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

releaseFor :: Text -> Text -> StaticRelease
releaseFor siteName host =
  StaticRelease
    "v1"
    siteName
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
        context
        (Map.fromList [(scopeId scope, (generation, scope)) | scope <- [foundationScope, authScope]])
        Map.empty
    )

context :: Resource.ContextBinding
context = Resource.ContextBinding (unsafe (Resource.mkContextId "protected-site")) (unsafe (Resource.mkName "project"))

generation :: Resource.ScopeGeneration
generation = unsafe (Resource.mkScopeGeneration 1)

-- An accepted application that already contributes its own protected host.
otherApp :: ScopeDeclaration
otherApp =
  ok
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [Managed route]
            []
            []
            [RegisterBackend authOwner cluster host "http://other.personal.svc.cluster.local" ProtectedBackend key]
            []
            []
        ]
    )
  where
    owner = unsafe (Resource.mkScopeId Resource.Application "other")
    host = unsafe (Resource.mkName "other.example.com")
    key = unsafe (Resource.mkLogicalKey "web")
    route =
      ManagedResource
        (Resource.mintResourceId owner key (unsafe (Resource.mkName "route")))
        owner
        KubernetesExecutor
        (unsafe (Resource.kubernetesAddress cluster "serving.knative.dev/v1beta1" "DomainMapping" (Just "nagare-system") "other.example.com"))
        [Resource.Hostname host]
        (NativeObject (contentDigest "route-other"))
        Retain
        Stateless
        Public
        [OrderedAfter cluster, OrderedAfter (backendMapResourceId authOwner)]
        []
        source

binding :: AccessBinding
binding = either (error . T.unpack) id (acceptedAccessBinding snapshot cluster)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
