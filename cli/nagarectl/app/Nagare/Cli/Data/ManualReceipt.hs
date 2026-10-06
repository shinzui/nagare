-- | Review the transition from a completed manual backup Job to a durable
-- stored-object receipt record. The Job is retained by the scope replacement;
-- collection remains a separate reviewed action.
module Nagare.Cli.Data.ManualReceipt
  ( runReviewedManualReceiptPlan
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.ObjectStore (resolveStoreBackend)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Kubernetes
  ( KubernetesState (KubernetesPresent)
  , kubernetesObserve
  )
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (KubernetesRuntimeConfig)
  , mkKubernetesRuntimeOpsWithCacheKey
  , readBackupReceiptFromCompletedPod
  )
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Digest qualified as InventoryDigest
import Nagare.Inventory.ManualReceipt
  ( ManualReceiptEvidence (manualReceiptBytes)
  , compileManualReceiptScope
  )
import Nagare.Inventory.ManualReceiptSource
  ( inspectManualReceipt
  , withGcsManualObjectReader
  )
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.ScheduledStore
  ( ObjectReader (readObjectToFile)
  , withLocalObjectStore
  )
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Reference qualified as ResourceReference
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

runReviewedManualReceiptPlan ::
  Maybe String -> Text -> Text -> Text -> Maybe String -> FilePath -> IO ()
runReviewedManualReceiptPlan mctx database namespaceName backupId bucketArg output = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  owner <-
    either
      dieT
      pure
      ( Resource.mkScopeId
          Resource.Standalone
          ("database-backup-" <> namespaceName <> "-" <> database <> "-" <> backupId)
      )
  backupScope <- case Map.lookup owner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, accepted) -> pure accepted
    Nothing -> dieT "exact manual backup scope is not accepted"
  backupJob <- case [ member
                    | bundle <- ResourceInventory.scopeBundles backupScope
                    , ResourceInventory.Managed member <- ResourceInventory.declarations bundle
                    , case member ^. #address of
                        Resource.Kubernetes _ "batch" kind (Just ns) _ ->
                          Resource.nameText kind == "job" && Resource.nameText ns == namespaceName
                        _ -> False
                    ] of
    [single] -> pure single
    _ -> dieT "accepted manual backup has no unique Job"
  let users =
        [ Resource.scopeIdText (ResourceInventory.scopeId scope)
        | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
        , ResourceInventory.scopeId scope /= owner
        , any
            ( \bundle ->
                any
                  ( \case
                      ResourceInventory.Managed member ->
                        ResourceReference.OrderedAfter (backupJob ^. #identity)
                          `elem` (member ^. #dependencies)
                      _ -> False
                  )
                  (ResourceInventory.declarations bundle)
            )
            (ResourceInventory.scopeBundles scope)
        ]
  unless
    (null users)
    (dieT ("accepted scopes still depend on the backup Job: " <> T.intercalate ", " users))
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  backupRevision <- case Map.lookup owner (InventoryPlan.historyAccepted history) of
    Just (revision, accepted) | accepted == backupScope -> pure revision
    _ -> dieT "manual backup scope differs from accepted history"
  acceptedInventory <-
    either
      (dieT . T.pack . show)
      pure
      (ResourceInventory.composeSnapshot snapshot)
  (acceptedNative, _) <-
    InventoryStatus.loadAcceptedNative store history acceptedInventory
      >>= either dieT pure
  backupNative <- case Map.lookup (backupJob ^. #identity) acceptedNative of
    Just pair | fst pair == backupJob -> pure (Map.singleton (backupJob ^. #identity) pair)
    _ -> dieT "accepted manual backup Job lacks exact private native evidence"
  context <-
    either
      dieT
      pure
      ( Resource.mkContextId
          (contextNameText (active ^. #contextName))
      )
  let config =
        KubernetesRuntimeConfig
          context
          (contextNameText (active ^. #contextName))
          (fmap (fmap (const ())) (guardKubernetesContext active))
      ops =
        mkKubernetesRuntimeOpsWithCacheKey
          config
          (\_ -> pure (Left "backup Job observation does not use a cache key"))
          backupNative
  state <- kubernetesObserve ops (backupJob ^. #identity)
  backupUid <- case (state, Map.lookup (backupJob ^. #identity) backupNative) of
    (KubernetesPresent uid _ (Just stamped) digest, Just (_, bytes))
      | stamped == backupJob ^. #identity
      , digest == InventoryDigest.contentDigest bytes ->
          pure uid
    _ -> dieT "accepted backup Job is absent, incomplete, foreign, or drifted"
  podReceipt <-
    readBackupReceiptFromCompletedPod
      config
      backupNative
      (backupJob ^. #identity)
      backupUid
      >>= either dieT pure
  backend <- resolveStoreBackend mctx bucketArg
  guarded <- guardKubernetesContext active
  _ <- either dieT pure guarded
  inspected <- case backend of
    MinioBackend ref -> withLocalObjectStore
      (contextNameText (active ^. #contextName))
      ref
      $ \reader ->
        inspectManualReceipt
          (\address path -> readObjectToFile reader address Nothing path)
          backupScope
          backupUid
    GcsBackend {} -> withGcsManualObjectReader backend $ \readOne ->
      inspectManualReceipt readOne backupScope backupUid
  evidence <- either dieT pure inspected >>= either dieT pure
  unless
    (manualReceiptBytes evidence == podReceipt)
    (dieT "stored manual receipt differs from the completed accepted Job")
  record <-
    either
      (dieT . T.pack . show)
      pure
      (compileManualReceiptScope backupRevision backupScope backupNative evidence)
  candidate <-
    either
      (dieT . T.pack . show)
      pure
      ( ResourceInventory.composeInventory
          snapshot
          (ResourceInventory.ReplaceScope record NE.:| [])
      )
  Inventory.planInventoryCandidateWithRetirements
    (inventoryPlanRegistryWithNative active workspace Map.empty)
    active
    candidate
    [backupJob ^. #identity]
    output
  TIO.putStrLn "Saved manual receipt review. Apply it to retain the completed Job; collect that Job in a separate reviewed action."
