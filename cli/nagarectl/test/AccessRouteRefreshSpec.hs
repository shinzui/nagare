-- | EP-273: an accepted route to the access enforcer that lacks Kourier's HTTP/1.1 annotation is
-- re-declared from its accepted bytes by a release transition. The transform alone, then through the
-- interpreters: the review planned by the production planner and applied by the production Kubernetes
-- adapter and runtime over the model API server, with one route annotated by hand as on labs.
module AccessRouteRefreshSpec (accessRouteRefreshTests) where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Access.ProtectedRouteRefresh
import Nagare.Access.Resolve (RouteTarget (..), disableHttp2Annotation, renderAccessDomainMapping)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (ForeignFieldPlanning (..))
import Nagare.Inventory.Adapters.KubernetesApplication (kubernetesApplicationAdapter)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Model.Fixtures (appCluster, appScope, ok, plainShape)
import Nagare.Test.Model.Run
import Nagare.Test.World.ApiServer (ObjectKey (..), patchUpdate)
import Nagare.Test.World.Cluster (Cluster (..), clusterConfig)
import Nagare.Test.World.Kubernetes (worldKubernetesAdapter)
import Test.Tasty
import Test.Tasty.HUnit

accessRouteRefreshTests :: TestTree
accessRouteRefreshTests =
  testGroup
    "protected route refresh (EP-273)"
    [ testCase "a route rendered before the annotation is re-declared as the renderer renders it now, the scope otherwise unchanged" $ do
        let digest = contentDigest "config"
            accepted = withScopeOverrides (Map.singleton "replicas" "2") (withScopeConfigDigest digest (scopeOf [old "docs.test", direct "site.test"] [backend]))
        (scope, refreshed) <- refresh [old "docs.test", direct "site.test"] accepted >>= maybe (assertFailure "no route was refreshed" >> pure (error "unreachable")) pure
        Map.keys refreshed @?= [routeId "docs.test"]
        let (route, bytes) = refreshed Map.! routeId "docs.test"
        bytes @?= ok (canonicalValue (ok (maybe (Left ("not JSON" :: Text)) Right (decodeStrict (renderAccessDomainMapping "nagare-system" "docs.test" enforcer)))))
        route @?= (fst (old "docs.test") & #spec .~ NativeObject (contentDigest bytes))
        scopeOverrides scope @?= scopeOverrides accepted
        scopeConfigDigest scope @?= Just digest
        concatMap (^. #contributions) (scopeBundles scope) @?= [backend]
        [m | bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations, m ^. #identity /= routeId "docs.test"] @?= [fst (direct "site.test")]
    , testCase "an annotated route, a route to another target and a mapping outside the enforcer's namespace are left alone" $ do
        refresh [current "docs.test", direct "site.test", elsewhere "own.test"] (scopeOf [current "docs.test", direct "site.test", elsewhere "own.test"] []) >>= (@?= Nothing)
    , testCase "the annotation joins the route's other annotations" $ do
        let carried = bindRoute "nagare-system" "old.test" (withAnnotations [("networking.knative.dev/disable-external-domain-tls", "true")] (routeValue "nagare-system" "old.test" "nagare-access"))
        (_, refreshed) <- refresh [carried] (scopeOf [carried] []) >>= maybe (assertFailure "no route was refreshed" >> pure (error "unreachable")) pure
        annotationsOf (snd (refreshed Map.! routeId "old.test"))
          @?= Just (KM.fromList [("networking.knative.dev/disable-external-domain-tls", String "true"), (Key.fromText disableHttp2Annotation, String "true")])
    , testCase "a route without its accepted bytes refuses" $
        case refreshProtectedRoutes Map.empty (scopeOf [old "docs.test"] []) of
          Left reason -> assertBool (T.unpack reason) ("lacks its accepted native bytes" `T.isInfixOf` reason)
          Right _ -> assertFailure "a route was refreshed without its accepted bytes"
    , testCase "the commit refuses while an accepted route lacks the annotation" $ do
        unrefreshedRouteRefusal Map.empty @?= Nothing
        case unrefreshedRouteRefusal (Map.fromList [(routeId "docs.test", old "docs.test")]) of
          Just reason -> assertBool (T.unpack reason) ("docs.test" `T.isInfixOf` reason)
          Nothing -> assertFailure "the commit went ahead with an un-annotated protected route"
    , testCase "through the interpreters: accepted routes are annotated, a hand annotation becomes Nagare's, and planning again finds nothing" $ do
        run <- newRun plainShape [] []
        let routes = [old "docs.test", old "hand.test", direct "site.test"]
        converge False run (Map.fromList [(m ^. #identity, route) | route@(m, _) <- routes]) (ReplaceScope (scopeOf routes []) :| [])
        -- The operator's `kubectl annotate` of 2026-11-21: live only, owned by another field manager.
        modifyIORef' (runWorld run) (#server %~ \server -> either (error . show) fst (patchUpdate "kubectl-annotate" (routeKey "hand.test") (object ["metadata" .= object ["annotations" .= object [Key.fromText disableHttp2Annotation .= ("true" :: Text)]]]) server))
        managers run "hand.test" >>= assertBool "the hand annotation is not another writer's" . elem "kubectl-annotate"
        (scopes, refreshed) <- pending run
        Map.keysSet refreshed @?= Set.fromList [routeId "docs.test", routeId "hand.test"]
        -- The plan binds the scope's unchanged members to their accepted bytes, as the CLI's registry does (F80).
        converge True run (Map.union refreshed (Map.fromList [(m ^. #identity, route) | route@(m, _) <- routes])) (ok (maybe (Left ("no scope to re-declare" :: Text)) Right (NE.nonEmpty (map ReplaceScope scopes))))
        live <- (^. #server) <$> readIORef (runWorld run)
        [annotated live host | host <- ["docs.test", "hand.test", "site.test"]] @?= [True, True, False]
        managers run "hand.test" >>= assertBool "another writer still owns a field of the route" . notElem "kubectl-annotate"
        pending run >>= (@?= ([], Map.empty))
    ]
  where
    refresh routes = either (\reason -> assertFailure (T.unpack reason) >> pure Nothing) pure . refreshProtectedRoutes (Map.fromList [(m ^. #identity, bytes) | (m, bytes) <- routes])
    annotated server host = (Map.lookup (routeKey host) (server ^. #objects) >>= annotationsOfValue . (^. #content) >>= KM.lookup (Key.fromText disableHttp2Annotation)) == Just (String "true")

-- | What `platform transition plan`'s last stage would re-declare, from the accepted state.
pending :: Run -> IO ([ScopeDeclaration], Map.Map ResourceId (ManagedResource, ByteString))
pending run = do
  history <- inspectHistory run >>= orFail "read history"
  let snapshot = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
  asOperator run (\store -> refreshAcceptedProtectedRoutes store snapshot) >>= either (\reason -> assertFailure (T.unpack reason) >> pure ([], Map.empty)) pure

managers :: Run -> Text -> IO [Text]
managers run host = do
  server <- (^. #server) <$> readIORef (runWorld run)
  pure (maybe [] (map (^. #manager) . (^. #managed)) (Map.lookup (routeKey host) (server ^. #objects)))

-- | Plan, publish and apply one review as an operator does, and require it to converge. With
-- @takeover@ the plan records direct field managers, as the transition's route stage plans (F37).
converge :: Bool -> Run -> Map.Map ResourceId (ManagedResource, ByteString) -> NonEmpty ScopeChange -> IO ()
converge takeover run members changes = do
  history <- inspectHistory run >>= orFail "read history"
  let snapshot = ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
      candidate = ok (composeInventory snapshot changes)
  adapter <-
    if takeover
      then pure (kubernetesApplicationAdapter (ForeignFieldsTakenOver ()) (clusterConfig (fixtureBinding ^. #identity) (Cluster (runWorld run) (runAdversary run))) (\_ -> pure (Left "the world has no cache client")) members)
      else worldKubernetesAdapter (fixtureBinding ^. #identity) members (runWorld run) (runAdversary run)
  reviewed <- asOperator run (planned (ok (mkAdapterRegistry [adapter])) candidate) >>= either (assertFailure . T.unpack) pure
  applyRegistry <- reviewRegistryFor run (fst reviewed)
  asOperator run (\store -> first (T.pack . show) <$> applyReviewed store applyRegistry (snd reviewed)) >>= \case
    Right (Converged _) -> pure ()
    other -> assertFailure ("the review did not converge: " <> show other)
  where
    planned registry candidate store = do
      history <- loadInventoryPlanningHistory store candidate >>= either (throwIO . userError . show) pure
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor (Set.toList (requiredResources (observationRequirements candidate history))))
      case observed >>= \observations -> first (T.pack . show) (planChanges candidate noLifecycleDecisions history observations) of
        Left err -> pure (Left err)
        Right proposal -> do
          before <- readStoreSnapshot store >>= either (throwIO . userError . show) pure
          prepareReviewWithPayloadIdentity "operator-cli" registry (storeSnapshotHead before) proposal >>= \case
            Left err -> pure (Left (T.pack (show (NE.toList err))))
            Right bundle -> do
              _ <- publishReview store bundle >>= either (throwIO . userError . show) pure
              published <- readStoreSnapshot store >>= either (throwIO . userError . show) pure
              pure (bimap (T.pack . show . NE.toList) (bundle,) (verifyReview published bundle))

scopeOf :: [(ManagedResource, ByteString)] -> [Contribution] -> ScopeDeclaration
scopeOf routes contributions = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) routes) [] [] contributions [] []])

-- | A protected site's backend registration, which the refresh must keep.
backend :: Contribution
backend = RegisterBackend appScope appCluster (ok (mkName "docs.test")) "http://web.model.svc.cluster.local" ProtectedBackend (ok (mkLogicalKey "docs.test")) Nothing

enforcer :: RouteTarget
enforcer = RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" "nagare-system"

-- | A route to the enforcer as v0.24.4 rendered it, as it is rendered now, a route to a site's own
-- service, and a mapping in a site's namespace.
old, current, direct, elsewhere :: Text -> (ManagedResource, ByteString)
old host = bindRoute "nagare-system" host (routeValue "nagare-system" host "nagare-access")
current host = bindRoute "nagare-system" host (withAnnotations [(disableHttp2Annotation, "true")] (routeValue "nagare-system" host "nagare-access"))
direct host = bindRoute "nagare-system" host (routeValue "nagare-system" host "web")
elsewhere host = bindRoute "model" host (routeValue "model" host "nagare-access")

bindRoute :: Text -> Text -> Value -> (ManagedResource, ByteString)
bindRoute _ host value =
  let bytes = ok (canonicalValue value)
   in ok (bindKubernetesObject (KubernetesInput (routeId host) appScope appCluster value (contentDigest bytes) DeleteWhenUnreferenced Stateless Private (SourceLocation "model" host)))

routeId :: Text -> ResourceId
routeId host = mintResourceId appScope (ok (mkLogicalKey (T.replace "." "-" host))) (ok (mkName "domainmapping"))

routeKey :: Text -> ObjectKey
routeKey = ObjectKey "serving.knative.dev" "domainmapping" (Just "nagare-system")

routeValue :: Text -> Text -> Text -> Value
routeValue namespace host target =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata" .= object ["name" .= host, "namespace" .= namespace, "labels" .= object ["nagare.dev/managed-by" .= ("nagarectl" :: Text)]]
    , "spec" .= object ["ref" .= object ["name" .= target, "kind" .= ("Service" :: Text), "apiVersion" .= ("serving.knative.dev/v1" :: Text), "namespace" .= ("nagare-system" :: Text)]]
    ]

withAnnotations :: [(Text, Text)] -> Value -> Value
withAnnotations annotations = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root -> Object (KM.insert "metadata" (Object (KM.insert "annotations" (object [Key.fromText k .= v | (k, v) <- annotations]) metadata)) root)
  other -> other

annotationsOf :: ByteString -> Maybe (KM.KeyMap Value)
annotationsOf bytes = decodeStrict bytes >>= annotationsOfValue

annotationsOfValue :: Value -> Maybe (KM.KeyMap Value)
annotationsOfValue = \case
  Object root | Just (Object metadata) <- KM.lookup "metadata" root, Just (Object annotations) <- KM.lookup "annotations" metadata -> Just annotations
  _ -> Nothing
