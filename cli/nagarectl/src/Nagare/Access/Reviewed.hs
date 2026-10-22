-- | Public access commands compile one independent scope and use the common journal.
module Nagare.Access.Reviewed (checkEffectiveAccess, planAccess, planTeamAccess, planTeamMember, accessPlanRegistry, planPortalSync, accessAdapter) where

import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Aeson (toJSON)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Nagare.Access.Check (CheckReport (..), CheckResult (Unavailable), effectiveAccess)
import Nagare.Access.ShomeiUser (ShomeiUser)
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
import Nagare.Inventory.Plan.Types (historyDeclarations)
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store (headBinding)
import Nagare.Resource.Access (TeamKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Target
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)

planAccess ::
  ActiveTarget ->
  EnTransport ->
  Text ->
  ShomeiUser ->
  Maybe Text ->
  Bool ->
  FilePath ->
  IO ()
planAccess active en host user =
  planRelationship active en (\snapshot -> compileAccessScope snapshot host user)

-- | A team's viewer grant on a protected host (EP-187).
planTeamAccess ::
  ActiveTarget ->
  EnTransport ->
  Text ->
  TeamKey ->
  Maybe Text ->
  Bool ->
  FilePath ->
  IO ()
planTeamAccess active en host team =
  planRelationship active en (\snapshot -> compileTeamAccessScope snapshot host team)

-- | One user's membership in a team (EP-187).
planTeamMember ::
  ActiveTarget ->
  EnTransport ->
  TeamKey ->
  ShomeiUser ->
  Maybe Text ->
  Bool ->
  FilePath ->
  IO ()
planTeamMember active en team user =
  planRelationship active en (\snapshot -> compileTeamMemberScope snapshot team user)

-- | Every reviewed relationship is one independent scope composed against
-- the accepted snapshot and planned through the common journal. The store is
-- opened once and the history loaded once, at the head the review binds
-- (EP-212).
planRelationship ::
  ActiveTarget ->
  EnTransport ->
  (ScopeSnapshot -> Bool -> Either Text ScopeDeclaration) ->
  Maybe Text ->
  Bool ->
  FilePath ->
  IO ()
planRelationship active en compile configuredKey present output = do
  opened <- Command.openInventoryForPlanning active
  snapshot <- Command.openedSnapshot opened
  scope <- either (fail . T.unpack) pure (compile snapshot present)
  candidate <- either (fail . show) pure (composeInventory snapshot (ReplaceScope scope :| []))
  withEnApiKey configuredKey (Command.planInventoryCandidateLoaded (accessPlanRegistry active en) active opened candidate output)

-- | Run an action with @--en-api-key@ exported as the private key, restoring
-- the environment afterwards; without the option the environment stands.
withEnApiKey :: Maybe Text -> IO a -> IO a
withEnApiKey configuredKey action = case configuredKey of
  Nothing -> action
  Just key -> bracket
    (lookupEnv "NAGARE_EN_API_KEY")
    (maybe (unsetEnv "NAGARE_EN_API_KEY") (setEnv "NAGARE_EN_API_KEY"))
    $ \_ ->
      setEnv "NAGARE_EN_API_KEY" (T.unpack key) >> action

-- | @access check@ (EP-188 M1): one fully consistent en check of a user on a
-- host this context protects, through the same private transport reviewed
-- writes use. The user's login token is never an en credential.
checkEffectiveAccess :: ActiveTarget -> EnTransport -> Text -> Text -> Maybe Text -> IO CheckReport
checkEffectiveAccess active en host subject configuredKey = do
  snapshot <- Command.loadTargetSnapshotReadOnly active
  protected <- either (fail . T.unpack) pure (acceptedProtectedHost snapshot host)
  guarded <- clusterGuard en
  case guarded of
    Left reason -> pure (CheckReport (nameText protected) subject (Unavailable ("context guard refused: " <> reason)))
    Right () -> do
      answer <-
        withEnApiKey configuredKey $
          withEn en $ \call ->
            effectiveAccess (\path body -> call "POST" path (toJSON body)) (nameText protected) subject
      pure (either (CheckReport (nameText protected) subject . Unavailable) id answer)

accessPlanRegistry ::
  ActiveTarget ->
  EnTransport ->
  CompositionCandidate ->
  InventoryHistory ->
  IO AdapterRegistry
accessPlanRegistry active en candidate history = do
  let inventory = candidateInventory candidate
  access <- accessAdapter active en (inventoryDeclarations inventory) history
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
              , AppDatabaseExecutor
              ]
        )
    )

accessAdapter :: ActiveTarget -> EnTransport -> [Declaration] -> InventoryHistory -> IO Adapter
accessAdapter active en declarations history = do
  desiredSpecs <- either (fail . T.unpack) pure (accessBindings declarations)
  -- A retirement removes a tuple from the desired declarations; it is still
  -- observed through its accepted binding.
  let specs = Map.union desiredSpecs (acceptedAccessBindings (historyDeclarations history))
  selectedGuard <-
    if Map.null specs
      then pure (clusterGuard en)
      else do
        selected <- kubeconfigPath (active ^. #contextName)
        exists <- doesFileExist selected
        if exists
          then setEnv "KUBECONFIG" selected >> pure (clusterGuard en)
          else pure (pure (Left "selected context kubeconfig is missing for access observation"))
  let accepted =
        Map.fromList
          [ (r ^. #identity, r)
          | (_, scope) <- Map.elems (historyAccepted history)
          , bundle <- scopeBundles scope
          , Managed r <- bundle ^. #declarations
          , r ^. #executor == AccessExecutor
          ]
  ops <- accessRuntimeOpsWith (en {clusterGuard = selectedGuard}) (headBinding (historyHead history))
  pure (mkAccessAdapter accepted specs ops)

-- The accepted owner and all accepted contributors supply authority. Live reads
-- check the resulting objects; they never discover or discard contributors.
planPortalSync :: ActiveTarget -> IO (Either Text ()) -> FilePath -> IO ()
planPortalSync active guard output = do
  opened <- Command.openInventoryForPlanning active
  snapshot <- Command.openedSnapshot opened
  owner <- either (fail . T.unpack) pure (mkScopeId Platform "auth")
  (_, scope) <-
    maybe
      (fail "portal sync requires an accepted auth owner")
      pure
      (Map.lookup owner (snapshotScopes snapshot))
  inventory <- either (fail . show) pure (composeSnapshot snapshot)
  let store = opened ^. #inventoryStore
      history = opened ^. #loadedHistory
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
  Command.planInventoryCandidateLoaded
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
                      withStuckRollouts (observationStuck observed)
                        <$> observationSet (Map.toAscList (observationMap observed) <> Map.toAscList (observationMap acceptedFacts))
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
                    , AppDatabaseExecutor
                    ]
              )
          )
    )
    active
    opened
    candidate
    output
