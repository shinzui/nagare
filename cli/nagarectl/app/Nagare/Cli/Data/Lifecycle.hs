-- | Data / Lifecycle. Executable-private CLI boundary.
module Nagare.Cli.Data.Lifecycle
  ( runDataRestart
  , runStandaloneRetirePlan
  )
where

import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistry
  , inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Ownership
  ( ownedHistoryResources
  , withAcceptedInventoryHistoryResult
  )
import Nagare.Cli.Runtime.Process (currentTimestamp)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesStuckPod (KubernetesPodOps (..), runtimePodOps)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService
  ( NativeDataKind
  , compileStatefulSetRestart
  , dataCommandNativeOwned
  , standaloneRetirementScope
  )
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (KubernetesRuntimeConfig))
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

-- | Accepted data workloads restart from exact private native evidence. The
-- legacy renderer remains available only for a read-only dry run.
runDataRestart ::
  Maybe String ->
  NativeDataKind ->
  Text ->
  Text ->
  Bool ->
  Maybe FilePath ->
  IO () ->
  IO ()
runDataRestart mctx kind name namespaceName dryRun output preview = do
  owned <- withAcceptedInventoryHistoryResult mctx "data restart" False $ \history ->
    pure
      ( dataCommandNativeOwned
          kind
          name
          namespaceName
          (ownedHistoryResources history)
      )
  if owned || isJust output || not dryRun
    then do
      when dryRun (dieT "accepted data restart requires a review; use --save-plan to inspect it")
      active <- activeTarget mctx
      (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
      store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      snapshot <- Inventory.loadTargetSnapshot active
      let restartTarget resource = case resource ^. #address of
            Resource.Kubernetes _ "apps" resourceKind (Just ns) nativeName ->
              Resource.nameText resourceKind == "statefulset"
                && Resource.nameText ns == namespaceName
                && Resource.nameText nativeName == name
            _ -> False
          selected =
            [ scope
            | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
            , bundle <- ResourceInventory.scopeBundles scope
            , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
            , restartTarget resource
            ]
      scope <- case selected of
        [single] -> pure single
        _ -> dieT "reviewed data restart requires one accepted StatefulSet scope"
      history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      acceptedInventory <-
        either
          (dieT . T.pack . show)
          pure
          (ResourceInventory.composeSnapshot snapshot)
      (acceptedNative, _) <-
        InventoryStatus.loadAcceptedNative store history acceptedInventory
          >>= either dieT pure
      -- EP-181: whether the StatefulSet's rollout is stuck is observed, never
      -- assumed; a failed read refuses the restart.
      stuck <- case [resource ^. #identity | bundle <- ResourceInventory.scopeBundles scope, ResourceInventory.Managed resource <- ResourceInventory.declarations bundle, restartTarget resource] of
        [member] -> do
          context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
          let config = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) (fmap (fmap (const ())) (guardKubernetesContext active))
          readStuckPod (runtimePodOps config acceptedNative) member >>= either (dieT . ("could not read the StatefulSet's pods: " <>)) pure
        _ -> dieT "reviewed data restart requires one accepted StatefulSet"
      stamp <- currentTimestamp
      (revised, native, note) <-
        either
          (dieT . T.pack . show)
          pure
          (compileStatefulSetRestart stuck kind name namespaceName stamp scope acceptedNative)
      traverse_ (TIO.putStrLn . ("db restart: " <>)) note
      candidate <-
        either
          (dieT . T.pack . show)
          pure
          ( ResourceInventory.composeInventory
              snapshot
              (ResourceInventory.ReplaceScope revised NE.:| [])
          )
      case output of
        Nothing ->
          Inventory.convergeInventoryCandidateWith
            (inventoryPlanRegistryWithNative active workspace native)
            (inventoryExecutionRegistry mctx)
            active
            candidate
        Just directory ->
          Inventory.planInventoryCandidateWith
            (inventoryPlanRegistryWithNative active workspace native)
            active
            candidate
            directory
    else preview

-- | Select only an accepted standalone data scope whose StatefulSet has the
-- requested native identity. A display name alone must never authorize
-- retirement of a different scope after a logical-key rename.
runStandaloneRetirePlan ::
  Maybe String ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  FilePath ->
  IO ()
runStandaloneRetirePlan mctx kind name namespaceName pinnedKey output = do
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshot active
  owner <- either dieT pure (standaloneRetirementScope kind name namespaceName pinnedKey snapshot)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  Inventory.planInventoryRetirementWith
    (inventoryPlanRegistry active workspace)
    active
    owner
    output
