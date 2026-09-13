module AccessResolveSpec (accessResolveTests) where

import Control.Exception (try)
import Data.Aeson (eitherDecodeStrict, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Access.Resolve
import Nagare.Dsl.Access (authPortal, requireLogin)
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Types
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

data Event
  = Saved !BackendMap
  | Routed !Namespace !PublicHost !RouteOp
  | ShomeiChanged !ShomeiPortalChange
  deriving stock (Eq, Show)

accessResolveTests :: TestTree
accessResolveTests =
  testGroup
    "Nagare.Access.Resolve"
    [ testCase "deploymentAccessRoutes uses the Knative wildcard host when no custom domains exist" $
        deploymentAccessRoutes "apps.example.com" (demoDep [])
          @?= [AccessRoute "notes.personal.apps.example.com" DefaultKnativeHost]
    , testCase "deploymentAccessRoutes uses every declared custom DomainMapping host" $
        deploymentAccessRoutes "apps.example.com" (demoDep (unsafe (mkDomains [("tools.example.com", True), ("admin.example.com", False)])))
          @?= [AccessRoute "tools.example.com" ExistingDomainMapping, AccessRoute "admin.example.com" ExistingDomainMapping]
    , testCase "protected route aborts before changes when the enforcer is absent" $ do
        store <- newIORef mempty
        events <- newIORef []
        let ops = fakeOps False store events
        result <- try (resolveAccessRouteWithOps ops baseDomain personal notes (AccessRoute "Tools.Example.com." ExistingDomainMapping) (Just requireLogin))
        assertExited result
        readIORef events >>= (@?= [])
    , testCase "protected route saves a legacy-shaped entry and routes through nagare-access" $ do
        initial <- backendMap [("other.example.com", BackendEntry "http://other.personal.svc.cluster.local" ProtectedEntry)]
        store <- newIORef initial
        events <- newIORef []
        let ops = fakeOps True store events
        resolveAccessRouteWithOps ops baseDomain personal notes (AccessRoute "Tools.Example.com." ExistingDomainMapping) (Just requireLogin)
        final <- readIORef store
        LBS.toStrict (encode final)
          @?= "{\"other.example.com\":\"http://other.personal.svc.cluster.local\",\"tools.example.com\":\"http://notes.personal.svc.cluster.local\"}"
        recorded <- readIORef events
        length recorded @?= 2
        case recorded of
          [Saved _, Routed ns host (RouteTo target)] -> do
            ns @?= personal
            publicHostText host @?= "tools.example.com"
            target @?= RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" "nagare-system"
          other -> assertFailure ("unexpected events: " <> show other)
    , testCase "portal deploy writes object entry, routes, and configures Shomei" $ do
        store <- newIORef mempty
        events <- newIORef []
        let ops = fakeOps True store events
        resolveDeploymentAccessWithOps ops baseDomain (portalDep [domainSpec "auth.apps.example.com"])
        final <- readIORef store
        LBS.toStrict (encode final)
          @?= "{\"auth.apps.example.com\":{\"role\":\"portal\",\"upstream\":\"http://notes.personal.svc.cluster.local\"}}"
        host <- unsafeIO (mkPublicHost "auth.apps.example.com")
        readIORef events
          >>= ( @?=
                  [ Saved final
                  , Routed personal host (RouteTo (RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" "nagare-system"))
                  , ShomeiChanged (EnablePortal host baseDomain)
                  ]
              )
    , testCase "a second portal is refused without writes" $ do
        initial <- backendMap [("auth.apps.example.com", BackendEntry "http://auth.personal.svc.cluster.local" PortalEntry)]
        store <- newIORef initial
        events <- newIORef []
        let ops = fakeOps True store events
        result <- try (resolveDeploymentAccessWithOps ops baseDomain (portalDep [domainSpec "login.apps.example.com"]))
        assertExited result
        readIORef store >>= (@?= initial)
        readIORef events >>= (@?= [])
    , testCase "portal outside the base domain is refused" $ do
        store <- newIORef mempty
        events <- newIORef []
        let ops = fakeOps True store events
        result <- try (resolveDeploymentAccessWithOps ops baseDomain (portalDep [domainSpec "auth.other.example"]))
        assertExited result
        readIORef events >>= (@?= [])
    , testCase "portal with multiple public hosts is refused" $ do
        store <- newIORef mempty
        events <- newIORef []
        let ops = fakeOps True store events
        result <- try (resolveDeploymentAccessWithOps ops baseDomain (portalDep [domainSpec "auth.apps.example.com", domainSpec "login.apps.example.com"]))
        assertExited result
        readIORef events >>= (@?= [])
    , testCase "redeploying the same portal is idempotent" $ do
        initial <- backendMap [("auth.apps.example.com", BackendEntry "http://notes.personal.svc.cluster.local" PortalEntry)]
        store <- newIORef initial
        events <- newIORef []
        let ops = fakeOps True store events
        resolveDeploymentAccessWithOps ops baseDomain (portalDep [domainSpec "auth.apps.example.com"])
        readIORef store >>= (@?= initial)
        assertBool "expected an idempotent save" =<< (not . null <$> readIORef events)
    , testCase "switching a portal to public removes it and disables Shomei" $ do
        initial <- backendMap [("auth.apps.example.com", BackendEntry "http://notes.personal.svc.cluster.local" PortalEntry)]
        store <- newIORef initial
        events <- newIORef []
        let ops = fakeOps True store events
        resolveAccessRouteWithOps ops baseDomain personal notes (AccessRoute "auth.apps.example.com" ExistingDomainMapping) Nothing
        final <- readIORef store
        LBS.toStrict (encode final) @?= "{}"
        host <- unsafeIO (mkPublicHost "auth.apps.example.com")
        assertBool "expected Shomei disable" . elem (ShomeiChanged (DisablePortal host)) =<< readIORef events
    , testCase "removeServiceAccessWithOps removes only the selected service" $ do
        initial <-
          backendMap
            [ ("auth.apps.example.com", BackendEntry "http://notes.personal.svc.cluster.local" PortalEntry)
            , ("other.apps.example.com", BackendEntry "http://other.personal.svc.cluster.local" ProtectedEntry)
            ]
        store <- newIORef initial
        events <- newIORef []
        let ops = fakeOps True store events
        removed <- removeServiceAccessWithOps ops personal notes
        map publicHostText removed @?= ["auth.apps.example.com"]
        final <- readIORef store
        LBS.toStrict (encode final) @?= "{\"other.apps.example.com\":\"http://other.personal.svc.cluster.local\"}"
        host <- unsafeIO (mkPublicHost "auth.apps.example.com")
        assertBool "expected enforcer route deletion" . elem (Routed personal host DeleteEnforcerRoute) =<< readIORef events
        assertBool "expected portal disable" . elem (ShomeiChanged (DisablePortal host)) =<< readIORef events
    , testCase "old string backend maps round trip without churn" $ do
        let raw = "{\"app.example.com\":\"http://app.personal.svc.cluster.local\"}"
        parsed <- either assertFailure pure (eitherDecodeStrict raw :: Either String BackendMap)
        LBS.toStrict (encode parsed) @?= raw
    , testCase "origin helpers preserve order and remove duplicates" $ do
        let auth = Origin "https://auth.apps.example.com"
            other = Origin "https://other.apps.example.com"
        addOrigin auth [other, auth, auth] @?= [other, auth]
        removeOrigin auth [other, auth, auth] @?= [other]
        removeOrigin auth [other] @?= [other]
    ]

fakeOps :: Bool -> IORef BackendMap -> IORef [Event] -> AccessOps
fakeOps present store events =
  AccessOps
    { checkEnforcerPresent = pure present
    , loadBackends = readIORef store
    , saveBackends = \backends -> writeIORef store backends >> record (Saved backends)
    , applyRouteOp = \ns host op -> record (Routed ns host op)
    , applyShomeiPortal = record . ShomeiChanged
    }
  where
    record event = modifyIORef' events (<> [event])

backendMap :: [(Text, BackendEntry)] -> IO BackendMap
backendMap = either (assertFailure . T.unpack) pure . backendMapFromList

baseDomain :: BaseDomain
baseDomain = unsafe (mkBaseDomain "apps.example.com")

portalDep :: [DomainSpec] -> Deployment
portalDep domains = (demoDep domains) {access = Just authPortal}

demoDep :: [DomainSpec] -> Deployment
demoDep domains =
  Deployment
    { name = notes
    , namespace = personal
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
    , build = unsafe defaultBuild
    , domains = domains
    , port = defaultPort
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , healthCheck = Nothing
    , volumes = []
    , databases = []
    , brokers = []
    , access = Nothing
    , tasks = []
    , cdn = Nothing
    }

domainSpec :: Text -> DomainSpec
domainSpec host = DomainSpec (unsafe (mkDomain host)) True

personal :: Namespace
personal = unsafe (mkNamespace "personal")

notes :: ServiceName
notes = unsafe (mkServiceName "notes")

assertExited :: Either ExitCode () -> Assertion
assertExited (Left ExitSuccess) = assertFailure "expected exitFailure, got ExitSuccess"
assertExited (Left (ExitFailure _)) = pure ()
assertExited (Right ()) = assertFailure "expected operation to exit"

unsafeIO :: Either Text a -> IO a
unsafeIO = either (assertFailure . T.unpack) pure

unsafe :: Either Text a -> a
unsafe (Right value) = value
unsafe (Left err) = error ("test fixture invalid: " <> T.unpack err)
