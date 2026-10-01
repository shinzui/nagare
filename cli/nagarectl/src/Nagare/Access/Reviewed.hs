-- | Public access commands compile one independent scope and use the common journal.
module Nagare.Access.Reviewed (planAccess, accessPlanRegistry, planPortalSync, accessAdapter) where

import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Cluster.Kubeconfig (kubeconfigPath)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Access
import Nagare.Inventory.AccessRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes (mkKubernetesAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (KubernetesRuntimeConfig (..), mkKubernetesRuntimeOps)
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, compileContributedShomeiSettings)
import Nagare.Inventory.Command qualified as Command
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store (headBinding)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Target
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)

planAccess ::
  ActiveTarget ->
  IO (Either Text ()) ->
  Text ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  Bool ->
  FilePath ->
  IO ()
planAccess active guard host user configuredUrl configuredKey granted output = do
  endpoint <-
    maybe
      ( lookupEnv "NAGARE_EN_URL"
          >>= maybe
            (fail "reviewed access requires --en-url or NAGARE_EN_URL")
            (pure . T.pack)
      )
      pure
      configuredUrl
  snapshot <- Command.loadTargetSnapshotReadOnly active
  scope <-
    either
      (fail . T.unpack)
      pure
      ( compileAccessScope
          snapshot
          host
          user
          (T.dropWhileEnd (== '/') endpoint)
          granted
      )
  candidate <- either (fail . show) pure (composeInventory snapshot (ReplaceScope scope :| []))
  withKey (Command.planInventoryCandidateWith (accessPlanRegistry active guard) active candidate output)
  where
    withKey action = case configuredKey of
      Nothing -> action
      Just key -> bracket
        (lookupEnv "NAGARE_EN_API_KEY")
        (maybe (unsetEnv "NAGARE_EN_API_KEY") (setEnv "NAGARE_EN_API_KEY"))
        $ \_ ->
          setEnv "NAGARE_EN_API_KEY" (T.unpack key) >> action

accessPlanRegistry ::
  ActiveTarget ->
  IO (Either Text ()) ->
  CompositionCandidate ->
  InventoryHistory ->
  IO AdapterRegistry
accessPlanRegistry active guard candidate history = do
  let inventory = candidateInventory candidate
  access <- accessAdapter active guard (inventoryDeclarations inventory) history
  either
    (fail . T.unpack)
    pure
    ( mkAdapterRegistry
        ( access
            : map
              (Command.manifestAdapterFor history)
              [ KubernetesExecutor
              , PulumiExecutor
              , CloudFoundationExecutor
              , HostExecutor
              , ArtifactExecutor
              , CacheExecutor
              , BrokerExecutor
              , HelmExecutor
              , CdnExecutor
              ]
        )
    )

accessAdapter :: ActiveTarget -> IO (Either Text ()) -> [Declaration] -> InventoryHistory -> IO Adapter
accessAdapter active guard declarations history = do
  specs <- either (fail . T.unpack) pure (accessBindings declarations)
  selectedGuard <-
    if Map.null specs
      then pure guard
      else do
        selected <- kubeconfigPath (active ^. #contextName)
        exists <- doesFileExist selected
        if exists
          then setEnv "KUBECONFIG" selected >> pure guard
          else pure (pure (Left "selected context kubeconfig is missing for access observation"))
  let accepted =
        Map.fromList
          [ (r ^. #identity, r)
          | (_, scope) <- Map.elems (historyAccepted history)
          , bundle <- scopeBundles scope
          , Managed r <- bundle ^. #declarations
          , r ^. #executor == AccessExecutor
          ]
  pure
    ( mkAccessAdapter
        accepted
        specs
        ( accessRuntimeOps
            (headBinding (historyHead history))
            (contextNameText (active ^. #contextName))
            selectedGuard
        )
    )

-- The accepted owner and all accepted contributors supply authority. Live reads
-- check the resulting objects; they never discover or discard contributors.
planPortalSync :: ActiveTarget -> IO (Either Text ()) -> FilePath -> IO ()
planPortalSync active guard output = do
  snapshot <- Command.loadTargetSnapshotReadOnly active
  owner <- either (fail . T.unpack) pure (mkScopeId Platform "auth")
  (_, scope) <-
    maybe
      (fail "portal sync requires an accepted auth owner")
      pure
      (Map.lookup owner (snapshotScopes snapshot))
  inventory <- either (fail . show) pure (composeSnapshot snapshot)
  store <- Command.openTargetStoreReadOnly active >>= either (fail . show) pure
  history <- loadInventoryHistory store >>= either (fail . show) pure
  let workloads =
        [ resource
        | Managed resource <- inventoryDeclarations inventory
        , resource ^. #owner == owner
        , Kubernetes _ group kind (Just namespace) name <- [resource ^. #address]
        , nameText namespace == "nagare-system"
        , (group, nameText kind, nameText name)
            `elem` [("apps", "deployment", "shomei"), ("serving.knative.dev", "service", "nagare-access")]
        ]
  unless
    (length workloads == 2)
    (fail "portal sync requires one accepted Shomei Deployment and access enforcer Service")
  (acceptedNative, _) <-
    loadAcceptedNativeSelected (Set.fromList (map (^. #identity) workloads)) store history inventory
      >>= either (fail . T.unpack) pure
  members <- forM workloads $ \resource ->
    maybe
      (fail "accepted portal workload native evidence is missing")
      pure
      (Map.lookup (resource ^. #identity) acceptedNative)
  stamp <- T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" <$> getCurrentTime
  (revised, rollout) <-
    either
      (fail . T.unpack)
      pure
      (compilePortalSyncScope scope members stamp)
  candidate <- either (fail . show) pure (composeInventory snapshot (ReplaceScope revised :| []))
  let declarations = inventoryDeclarations inventory
  backends <- either (fail . T.unpack) pure (compileContributedBackendMaps declarations)
  settings <- either (fail . T.unpack) pure (compileContributedShomeiSettings declarations)
  let maps = Map.union backends settings
      native = Map.union maps rollout
      expected = Map.fromList [(backendMapResourceId owner, ()), (shomeiSettingsResourceId owner, ())]
  unless
    (Map.keysSet maps == Map.keysSet expected)
    (fail "portal sync requires exactly the accepted auth backend and Shomei settings grants")
  Command.planInventoryCandidateWith
    ( \_ history -> do
        accepted <- maybe (fail "portal auth revision is missing") (pure . fst) (Map.lookup owner (historyAccepted history))
        unless
          (Map.lookup owner (historyConverged history) == Just accepted)
          (fail "portal sync requires the accepted auth scope to be converged")
        let runtime =
              KubernetesRuntimeConfig
                (inventoryBinding inventory ^. #identity)
                (contextNameText (active ^. #contextName))
                guard
            provider = mkKubernetesAdapter native (mkKubernetesRuntimeOps runtime native)
            manifest = Command.manifestAdapterFor history KubernetesExecutor
            -- Other owner objects are unchanged accepted dependencies. Only these
            -- maps and both startup-reader rollouts can be prepared; synchronization cannot advance
            -- a previously unconverged auth owner or mutate another resource.
            kubernetes =
              provider
                { adapterObserve = \ids -> do
                    live <- adapterObserve provider (filter (`Map.member` native) ids)
                    known <- adapterObserve manifest (filter (`Map.notMember` native) ids)
                    pure $ do
                      observed <- live
                      acceptedFacts <- known
                      observationSet (Map.toAscList (observationMap observed) <> Map.toAscList (observationMap acceptedFacts))
                }
        either
          (fail . T.unpack)
          pure
          ( mkAdapterRegistry
              ( kubernetes
                  : map
                    (Command.manifestAdapterFor history)
                    [ PulumiExecutor
                    , CloudFoundationExecutor
                    , HostExecutor
                    , ArtifactExecutor
                    , CacheExecutor
                    , BrokerExecutor
                    , HelmExecutor
                    , CdnExecutor
                    , AccessExecutor
                    ]
              )
          )
    )
    active
    candidate
    output
