-- | EP-246 D5 and D7 through the interpreters: a base move's routes carried across the flip and
-- across a rollback, then the new base's names retired, each review planned by the production
-- planner and applied by the production Kubernetes adapter and runtime over the model API server,
-- with external-domain TLS as the move sets it. The carrier, the retire phases and their decisions
-- are the ones `deploy` and `context move retire` call.
module InventoryBaseMoveRoutesSpec (inventoryBaseMoveRoutesTests) where

import Control.Exception (throwIO, try)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Context.MoveCarry (carryWithAcceptedRoutes)
import Nagare.Context.MoveRetire (RetirePhase (..), retirePhase)
import Nagare.Context.MoveRoutes (otherBase)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Collection.Adapter (controllerCollectionAdapter)
import Nagare.Inventory.Components.CloudflareZone (CloudflareZoneInput (CloudflareZoneInput), compileCloudflareZone)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (decideCollection, decideMemberRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Model.Fixtures (appCluster, appScope, ok, plainShape)
import Nagare.Test.Model.Run
import Nagare.Test.World.Cluster (Cluster (..), clusterConfig)
import Nagare.Test.World.Kubernetes
import Test.Tasty
import Test.Tasty.HUnit

inventoryBaseMoveRoutesTests :: TestTree
inventoryBaseMoveRoutesTests =
  testGroup
    "base move routes through the interpreters (EP-246)"
    [ testCase "routes carried across the flip and a rollback stay ready, and retiring the new names collects theirs" $ do
        (run, bound) <- throughRollback
        -- `context move retire` on the new names: carried routes are already deletable (the packaged one
        -- too), so every route is retired by its own decision and collected.
        phase run newHosts >>= \case
          RetireRoutes (scope : rest) routes -> do
            Set.fromList routes @?= Set.fromList (map routeId newHosts)
            converge run bound (ReplaceScope scope :| map ReplaceScope rest) (decideMemberRetirement routes)
          other -> assertFailure ("expected the routes' retirement: " <> show other)
        phase run newHosts >>= \case
          CollectRoute route -> convergeWith True run bound (CollectRetained route :| []) decideCollection
          other -> assertFailure ("expected a route's collection: " <> show other)
        phase run newHosts >>= \case
          CollectRoute route -> convergeWith True run bound (CollectRetained route :| []) decideCollection
          other -> assertFailure ("expected the other route's collection: " <> show other)
        phase run newHosts >>= (@?= NamesRetired)
        world <- readIORef (runWorld run)
        assertBool "a new route is still live" (all ((`Map.notMember` objects world) . routeId) newHosts)
        assertBool "an old route is gone" (all ((`Map.member` objects world) . routeId) oldHosts)
    , testCase "after a rollback the context moves again: the kept routes become the new base's own, the old ones are carried" $ do
        (run, bound) <- throughRollback
        tls run False []
        again <- deploy run bound (otherBase newBase "" (Just (oldBase, newBase)) []) newHosts
        assertBool "the old routes are carried with the TLS opt-out" (all (optedOut again . routeId) oldHosts)
        assertBool "the new routes are declared again without the opt-out" (not (any (optedOut again . routeId) newHosts))
    ]

-- | The context on its old base, moved to the new one, and rolled back: each redeploy carries the other
-- base's routes ('otherBase', as `deploy` computes it).
throughRollback :: IO (Run, IORef (Map.Map ResourceId (ManagedResource, ByteString)))
throughRollback = do
  run <- newRun plainShape [] []
  bound <- newIORef Map.empty
  -- The context serves its old base, with external-domain TLS and every certificate issued.
  tls run True []
  _ <- deploy run bound (otherBase oldBase "" Nothing []) oldHosts
  -- The flip: the tunnel serves the new base without origin TLS, and the redeploy carries the old routes.
  tls run False []
  onNewBase <- deploy run bound (otherBase newBase "" (Just (oldBase, newBase)) []) newHosts
  assertBool "the old routes are carried with the TLS opt-out" (all (optedOut onNewBase . routeId) oldHosts)
  -- The rollback closes the move and keeps its zone. Origin TLS returns, and the old issuer cannot solve
  -- for the new base. The redeploy from the old config carries the new routes, ready without a certificate.
  tls run True newHosts
  rolledBack <- deploy run bound (otherBase oldBase "" Nothing [keptZone]) oldHosts
  assertBool "the new routes are carried with the TLS opt-out" (all (optedOut rolledBack . routeId) newHosts)
  assertBool "the old routes are declared again without the opt-out" (not (any (optedOut rolledBack . routeId) oldHosts))
  pure (run, bound)

tls :: Run -> Bool -> [Text] -> IO ()
tls run on unissued = modifyIORef' (runWorld run) (#server %~ ((#externalDomainTls .~ on) . (#unissued .~ Set.fromList unissued)))

-- | Redeploy the routes from their config, carrying the other base's as `deploy` does.
deploy :: Run -> IORef (Map.Map ResourceId (ManagedResource, ByteString)) -> Maybe Text -> [Text] -> IO (Map.Map ResourceId (ManagedResource, ByteString))
deploy run bound other hosts = do
  let native = Map.fromList [(routeId h, bindRoute h) | h <- hosts]
      scope = ok (mkScopeDeclaration appScope [ResourceBundle (map (Managed . fst) (Map.elems native)) [] [] [] [] []])
  snapshot <- acceptedSnapshot run
  (carried, carriedNative) <- case other of
    Nothing -> pure (scope, native)
    Just base -> asOperator run (\store -> carryWithAcceptedRoutes base store snapshot (scope, native)) >>= either (assertFailure . T.unpack) pure
  modifyIORef' bound (Map.union carriedNative)
  converge run bound (ReplaceScope carried :| []) (\_ _ _ -> Right noLifecycleDecisions)
  pure carriedNative

oldBase, newBase :: Text
oldBase = "old.test"
newBase = "new.test"

-- | The zone a rolled-back move keeps: its tunnel config serves the new base.
keptZone :: ScopeDeclaration
keptZone = ok (compileCloudflareZone (CloudflareZoneInput (ok (mkName "zone-id")) newBase "model" Nothing))

-- | A site's route, and the admin API's, which its packaged component declares Retain.
oldHosts, newHosts :: [Text]
oldHosts = ["docs.old.test", "admin.old.test"]
newHosts = ["docs.new.test", "admin.new.test"]

bindRoute :: Text -> (ManagedResource, ByteString)
bindRoute host =
  let value = routeValue host
      bytes = ok (canonicalValue value)
      lifecycle = if "admin." `T.isPrefixOf` host then Retain else DeleteWhenUnreferenced
   in ok (bindKubernetesObject (KubernetesInput (routeId host) appScope appCluster value (contentDigest bytes) lifecycle Stateless Private (SourceLocation "model" host)))

routeId :: Text -> ResourceId
routeId host = mintResourceId appScope (ok (mkLogicalKey (T.replace "." "-" host))) (ok (mkName "domainmapping"))

-- | A protected route's DomainMapping, as the access compiler renders it.
routeValue :: Text -> Value
routeValue host =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata" .= object ["name" .= host, "namespace" .= ("nagare-system" :: Text)]
    , "spec" .= object ["ref" .= object ["name" .= ("nagare-access" :: Text), "kind" .= ("Service" :: Text), "apiVersion" .= ("serving.knative.dev/v1" :: Text), "namespace" .= ("nagare-system" :: Text)]]
    ]

optedOut :: Map.Map ResourceId (ManagedResource, ByteString) -> ResourceId -> Bool
optedOut native resource = maybe False (T.isInfixOf "\"networking.knative.dev/disable-external-domain-tls\":\"true\"" . TE.decodeUtf8 . snd) (Map.lookup resource native)

acceptedSnapshot :: Run -> IO ScopeSnapshot
acceptedSnapshot run = do
  history <- inspectHistory run >>= orFail "read history"
  pure (ok (mkScopeSnapshot fixtureBinding (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history)))

phase :: Run -> [Text] -> IO RetirePhase
phase run hosts = do
  history <- inspectHistory run >>= orFail "read history"
  snapshot <- acceptedSnapshot run
  either (\reason -> assertFailure (T.unpack reason) >> pure NamesRetired) pure (retirePhase hosts [member | (_, (_, member)) <- Map.toAscList (historyRetained history)] snapshot)

-- | Plan, publish and apply one review as an operator does, and require it to converge.
converge ::
  Run ->
  IORef (Map.Map ResourceId (ManagedResource, ByteString)) ->
  NonEmpty ScopeChange ->
  (CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  IO ()
converge = convergeWith False

-- | With @controller@, as `inventory collect --controller-descendants` plans and `inventory apply`
-- applies a DomainMapping's collection: the controller-collection adapter, over the same cluster.
convergeWith ::
  Bool ->
  Run ->
  IORef (Map.Map ResourceId (ManagedResource, ByteString)) ->
  NonEmpty ScopeChange ->
  (CompositionCandidate -> InventoryHistory -> ObservationSet -> Either (NonEmpty PlanError) LifecycleDecisions) ->
  IO ()
convergeWith controller run bound changes decide = do
  snapshot <- acceptedSnapshot run
  candidate <- either (\err -> assertFailure (show err) >> pure (error "unreachable")) pure (composeInventory snapshot changes)
  members <- readIORef bound
  let config = clusterConfig (fixtureBinding ^. #identity) (Cluster (runWorld run) (runAdversary run))
  adapter <-
    if controller
      then pure (controllerCollectionAdapter config members)
      else worldKubernetesAdapter (fixtureBinding ^. #identity) members (runWorld run) (runAdversary run)
  let registry = ok (mkAdapterRegistry [adapter])
  reviewed <- asOperator run (planned registry candidate) >>= either (assertFailure . T.unpack) pure
  applyRegistry <-
    if controller
      then do
        retiring <- asOperator run (\store -> Status.acceptedKubernetesNative "a reviewed collection" (Map.keysSet (reviewCollections (reviewBundleDocument (fst reviewed)))) store)
        bindings <- either (assertFailure . T.unpack) pure retiring
        reviewMembers <- asOperator run (\store -> Status.kubernetesMembersForReview store (fst reviewed) bindings) >>= either (assertFailure . T.unpack) pure
        pure (ok (mkAdapterRegistry [controllerCollectionAdapter config reviewMembers]))
      else reviewRegistryFor run (fst reviewed)
  result <- asOperator run (\store -> first (T.pack . show) <$> applyReviewed store applyRegistry (snd reviewed))
  case result of
    -- The accepted declarations bind their members from now on, as the store gives them to the CLI.
    Right (Converged _) -> modifyIORef' bound (\members' -> foldl' (\acc m -> Map.adjust (\(_, bytes) -> (m, bytes)) (m ^. #identity) acc) members' [m | ReplaceScope scope <- NE.toList changes, bundle <- scopeBundles scope, Managed m <- bundle ^. #declarations])
    other -> assertFailure ("the review did not converge: " <> show other)
  where
    planned registry candidate store = do
      history <- loadInventoryPlanningHistory store candidate >>= either (throwIO . userError . show) pure
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor (Set.toList (requiredResources (observationRequirements candidate history))))
      case observed >>= \observations -> first (T.pack . show) (decide candidate history observations >>= \decisions -> planChanges candidate decisions history observations) of
        Left err -> pure (Left err)
        Right proposal -> do
          before <- readStoreSnapshot store >>= either (throwIO . userError . show) pure
          prepared <- prepareReviewWithPayloadIdentity "operator-cli" registry (storeSnapshotHead before) proposal
          case prepared of
            Left err -> pure (Left (T.pack (show (NE.toList err))))
            Right bundle -> do
              _ <- publishReview store bundle >>= either (throwIO . userError . show) pure
              published <- readStoreSnapshot store >>= either (throwIO . userError . show) pure
              pure (bimap (T.pack . show . NE.toList) (bundle,) (verifyReview published bundle))
