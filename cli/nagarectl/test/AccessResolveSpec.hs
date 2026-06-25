module AccessResolveSpec (accessResolveTests) where

import Control.Exception (try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Access.Resolve
import Nagare.Dsl.Access (requireLogin)
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Types
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

data Event
  = Wrote !(Map.Map Text Text)
  | Reloaded
  | Routed !Text !Text !RouteOp
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
    , testCase "protected route aborts before backend or route changes when the enforcer is absent" $ do
        events <- newIORef []
        let ops = fakeOps False (Right (Just Map.empty)) events
        result <- try (resolveAccessRouteWithOps ops personal notes (AccessRoute "Tools.Example.com." ExistingDomainMapping) (Just requireLogin))
        case result of
          Left ExitSuccess -> assertFailure "expected exitFailure, got ExitSuccess"
          Left (ExitFailure _) -> pure ()
          Right () -> assertFailure "expected resolveAccessRouteWithOps to exit"
        readIORef events >>= (@?= [])
    , testCase "protected route writes host backend and points the DomainMapping at central nagare-access" $ do
        events <- newIORef []
        let initial = Map.singleton "other.example.com" "http://other.personal.svc.cluster.local"
            ops = fakeOps True (Right (Just initial)) events
        resolveAccessRouteWithOps ops personal notes (AccessRoute "Tools.Example.com." ExistingDomainMapping) (Just requireLogin)
        readIORef events
          >>= ( @?=
                  [ Wrote
                      ( Map.fromList
                          [ ("other.example.com", "http://other.personal.svc.cluster.local")
                          , ("tools.example.com", "http://notes.personal.svc.cluster.local")
                          ]
                      )
                  , Reloaded
                  , Routed "personal" "tools.example.com" (RouteTo (RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" "nagare-system"))
                  ]
              )
    , testCase "public custom domain removes the backend entry and routes directly to the app service" $ do
        events <- newIORef []
        let initial =
              Map.fromList
                [ ("tools.example.com", "http://notes.personal.svc.cluster.local")
                , ("other.example.com", "http://other.personal.svc.cluster.local")
                ]
            ops = fakeOps False (Right (Just initial)) events
        resolveAccessRouteWithOps ops personal notes (AccessRoute "tools.example.com" ExistingDomainMapping) Nothing
        readIORef events
          >>= ( @?=
                  [ Wrote (Map.singleton "other.example.com" "http://other.personal.svc.cluster.local")
                  , Reloaded
                  , Routed "personal" "tools.example.com" (RouteTo (RouteTarget "serving.knative.dev/v1" "Service" "notes" "personal"))
                  ]
              )
    , testCase "public default host deletes the protective DomainMapping override and does not create a backend map" $ do
        events <- newIORef []
        let ops = fakeOps False (Right Nothing) events
        resolveAccessRouteWithOps ops personal notes (AccessRoute "notes.personal.apps.example.com" DefaultKnativeHost) Nothing
        readIORef events
          >>= ( @?=
                  [Routed "personal" "notes.personal.apps.example.com" DeleteRouteOverride]
              )
    ]

fakeOps :: Bool -> Either Text (Maybe (Map.Map Text Text)) -> IORef [Event] -> AccessOps
fakeOps present loaded events =
  AccessOps
    { checkEnforcerPresent = pure present
    , loadBackendMap = pure loaded
    , writeBackendMap = \m -> writeEvent (Wrote m)
    , reloadBackendMap = writeEvent Reloaded
    , applyRouteOp = \ns host op -> writeEvent (Routed ns host op)
    }
  where
    writeEvent event = do
      old <- readIORef events
      writeIORef events (old <> [event])

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

personal :: Namespace
personal = unsafe (mkNamespace "personal")

notes :: ServiceName
notes = unsafe (mkServiceName "notes")

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)
