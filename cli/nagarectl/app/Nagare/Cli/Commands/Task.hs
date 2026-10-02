-- | Commands / Task. Executable-private CLI boundary.
module Nagare.Cli.Commands.Task
  ( runTask
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Execution
  ( inventoryExecutionRegistry
  )
import Nagare.Cli.Inventory.Planning
  ( inventoryPlanRegistryWithNative
  )
import Nagare.Cli.Options
  ( TaskCommand (..)
  , TaskDeleteOpts
  , TaskRunOpts
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (taskResourceName)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Inventory.TaskLifecycle
  ( compileTaskSuspensionScope
  , retireSuspendedTaskScope
  , taskSuspended
  )
import Nagare.Inventory.TaskRun (compileTaskRunScope)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Task.Delete (previewTaskDelete)
import Nagare.Task.Discover (AppScope (..))
import Nagare.Task.List (runTaskList)
import Nagare.Task.Logs (TaskLogTarget (..), runTaskLogs)
import Nagare.Task.Run (previewTaskRun)

-- | Dispatch the @task@ command group (MasterPlan 10, EP-51). Mirrors 'runDb'.
-- The @APP@ positional becomes an 'AppScope': @-@ means app-less, anything else is
-- that app; for @task list@ an omitted @APP@ means "any app".
runTask :: Maybe String -> TaskCommand -> IO ()
runTask mctx = \case
  TaskList o -> runTaskList (nsOf (o ^. #namespace)) (scopeOfMaybe (o ^. #app))
  TaskRun o -> do
    case o ^. #savePlan of
      Just output -> runReviewedTaskRunPlan mctx o (Just output)
      Nothing | isJust (o ^. #runId) -> runReviewedTaskRunPlan mctx o Nothing
      Nothing
        | o ^. #dryRun ->
            previewTaskRun (nsOf (o ^. #namespace)) (T.pack (o ^. #task))
      Nothing -> dieT "live task run requires --run-id for a reviewed Job"
  TaskLogs o ->
    runTaskLogs
      TaskLogTarget
        { namespace = nsOf (o ^. #namespace)
        , task = T.pack (o ^. #task)
        , scope = scopeOf (o ^. #app)
        , follow = o ^. #follow
        , tail = o ^. #tail
        }
  TaskDelete o -> do
    case o ^. #savePlan of
      Just output -> runReviewedTaskDeletePlan mctx o output
      Nothing
        | o ^. #yes && not (o ^. #dryRun) ->
            dieT "task delete requires --save-plan; apply each reviewed stage with inventory apply --yes"
      Nothing ->
        previewTaskDelete
          (nsOf (o ^. #namespace))
          (scopeOf (o ^. #app))
          (T.pack (o ^. #task))
  where
    nsOf = maybe "personal" T.pack
    -- A required APP positional: "-" means app-less, anything else is that app.
    scopeOf "-" = NoApp
    scopeOf a = App (T.pack a)
    -- An optional APP positional (task list): absent means "any app".
    scopeOfMaybe Nothing = AnyApp
    scopeOfMaybe (Just a) = scopeOf a

-- | Each invocation saves exactly one deletion stage. Applying a suspension
-- first prevents new scheduled runs; member retention and physical collection
-- each need their own explicit reviewed lifecycle decision.
runReviewedTaskDeletePlan :: Maybe String -> TaskDeleteOpts -> FilePath -> IO ()
runReviewedTaskDeletePlan mctx options output = do
  when
    (options ^. #yes || options ^. #dryRun)
    (dieT "--save-plan is a reviewed task deletion stage; apply its review with inventory apply --yes")
  let appName = T.pack (options ^. #app)
      taskName = T.pack (options ^. #task)
      ns = maybe "personal" T.pack (options ^. #namespace)
      appLabel = if appName == "-" then Nothing else Just appName
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  cronAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "batch/v1"
          "CronJob"
          (Just ns)
          (taskResourceName taskName)
      )
  let accepted =
        [ (resource, scope)
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , resource ^. #address == cronAddress
        ]
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  let retained =
        [ resource
        | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
        , resource ^. #address == cronAddress
        ]
  unless
    (length accepted + length retained == 1)
    (dieT "reviewed task delete requires one accepted or retained CronJob at the selected address")
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  let nativeBytes resource = do
        (bound, bytes) <-
          maybe
            (dieT "CronJob lacks private native evidence")
            pure
            (Map.lookup (resource ^. #identity) acceptedNative)
        unless
          (bound == resource)
          (dieT "CronJob differs from its private native evidence")
        pure bytes
      nativeFor candidate replacements =
        let desired =
              Set.fromList
                [ resource ^. #identity
                | ResourceInventory.Managed resource <-
                    ResourceInventory.inventoryDeclarations
                      (ResourceInventory.candidateInventory candidate)
                ]
         in Map.filterWithKey
              (\resource _ -> Set.member resource desired)
              (Map.union replacements acceptedNative)
      nativeAccepted =
        let desired =
              Set.fromList
                [ resource ^. #identity
                | ResourceInventory.Managed resource <-
                    ResourceInventory.inventoryDeclarations
                      acceptedInventory
                ]
         in Map.filterWithKey (\resource _ -> Set.member resource desired) acceptedNative
  case (accepted, retained) of
    ([(resource, scope)], []) -> do
      bytes <- nativeBytes resource
      suspended <- either (dieT . T.pack . show) pure (taskSuspended appLabel resource bytes)
      if suspended
        then do
          revised <-
            either
              (dieT . T.pack . show)
              pure
              (retireSuspendedTaskScope appLabel resource scope acceptedNative)
          candidate <-
            either
              (dieT . T.pack . show)
              pure
              ( ResourceInventory.composeInventory
                  snapshot
                  (ResourceInventory.ReplaceScope revised NE.:| [])
              )
          Inventory.planInventoryCandidateWithRetirements
            (inventoryPlanRegistryWithNative active workspace (nativeFor candidate Map.empty))
            active
            candidate
            [resource ^. #identity]
            output
          TIO.putStrLn "Saved CronJob retention review. Apply it, then run task delete --save-plan again to review collection."
        else do
          (revised, changedNative) <-
            either
              (dieT . T.pack . show)
              pure
              (compileTaskSuspensionScope appLabel resource scope acceptedNative)
          candidate <-
            either
              (dieT . T.pack . show)
              pure
              ( ResourceInventory.composeInventory
                  snapshot
                  (ResourceInventory.ReplaceScope revised NE.:| [])
              )
          Inventory.planInventoryCandidateWith
            (inventoryPlanRegistryWithNative active workspace (nativeFor candidate changedNative))
            active
            candidate
            output
          TIO.putStrLn "Saved CronJob suspension review. Apply it, then run task delete --save-plan again to review retention."
    ([], [resource]) -> do
      bytes <- nativeBytes resource
      suspended <- either (dieT . T.pack . show) pure (taskSuspended appLabel resource bytes)
      unless suspended (dieT "retained CronJob was not suspended in accepted intent; refusing collection")
      Inventory.planInventoryCollectionWith
        (inventoryPlanRegistryWithNative active workspace nativeAccepted)
        active
        (resource ^. #identity)
        output
      TIO.putStrLn "Saved exact CronJob collection review. Apply it to delete the retained schedule."
    _ -> dieT "reviewed task delete found ambiguous CronJob ownership"

runReviewedTaskRunPlan :: Maybe String -> TaskRunOpts -> Maybe FilePath -> IO ()
runReviewedTaskRunPlan mctx options output = do
  when
    (options ^. #dryRun)
    (dieT "--dry-run cannot be combined with a reviewed task run; use --save-plan to inspect its review")
  let appName = T.pack (options ^. #app)
      taskName = T.pack (options ^. #task)
      ns = maybe "personal" T.pack (options ^. #namespace)
      appLabel = if appName == "-" then Nothing else Just appName
  runId <-
    maybe
      (dieT "reviewed task run requires --run-id")
      (pure . T.pack)
      (options ^. #runId)
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  (cluster, _) <- either dieT pure (acceptedFoundationNamespace snapshot ns)
  cronAddress <-
    either
      dieT
      pure
      ( Resource.kubernetesAddress
          cluster
          "batch/v1"
          "CronJob"
          (Just ns)
          (taskResourceName taskName)
      )
  let accepted =
        [ resource
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , resource ^. #address == cronAddress
        ]
  cronJob <- case accepted of
    [resource] -> pure resource
    _ -> dieT "reviewed task run requires one accepted CronJob at the selected address"
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  (bound, cronBytes) <-
    maybe
      (dieT "accepted CronJob lacks private native evidence")
      pure
      (Map.lookup (cronJob ^. #identity) acceptedNative)
  unless
    (bound == cronJob)
    (dieT "accepted CronJob differs from its private native evidence")
  let source =
        Resource.SourceLocation
          ("task/" <> appName <> "/" <> taskName)
          ("manual-run/" <> runId)
  (scope, native) <-
    either
      (dieT . T.pack . show)
      pure
      (compileTaskRunScope appLabel cronJob cronBytes runId source)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
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
