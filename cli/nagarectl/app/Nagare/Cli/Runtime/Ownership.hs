-- | Runtime / Ownership. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Ownership
  ( ownedHistoryResources
  , refuseDirectAccessOwnerIfManaged
  , refuseDirectCdnHostMutationIfOwned
  , refuseDirectCloudflareZoneMutationIfOwned
  , refuseDirectLegacyOperationWhenManaged
  , withAcceptedInventoryHistory
  , withAcceptedInventoryHistoryResult
  )
where

import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (hostnameClaimOwned)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Store qualified as InventoryStore
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (contextNameText)

-- | Reuse one read-only, context-bound history check for every legacy command
-- that can mutate a native resource without an inventory receipt.
withAcceptedInventoryHistory :: Maybe String -> Text -> (InventoryPlan.InventoryHistory -> IO ()) -> IO ()
withAcceptedInventoryHistory mctx operation inspect =
  withAcceptedInventoryHistoryResult mctx operation () inspect

withAcceptedInventoryHistoryResult ::
  Maybe String -> Text -> a -> (InventoryPlan.InventoryHistory -> IO a) -> IO a
withAcceptedInventoryHistoryResult mctx operation missing inspect = do
  active <- activeTarget mctx
  opened <- Inventory.openTargetStoreReadOnly active
  case opened of
    Left (InventoryStore.StoreConditionFailed "inventory store is not initialized") -> pure missing
    Left (InventoryStore.StoreConditionFailed "inventory object prefix is not initialized") -> pure missing
    Left err -> dieT ("cannot verify inventory ownership before " <> operation <> ": " <> T.pack (show err))
    Right store -> do
      history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
      context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
      project <- either dieT pure (Resource.mkName (active ^. #profile . #project))
      unless
        (InventoryStore.headBinding (InventoryPlan.historyHead history) == Resource.ContextBinding context project)
        (dieT "accepted inventory belongs to a different context or project")
      inspect history

ownedHistoryResources :: InventoryPlan.InventoryHistory -> [ResourceInventory.ManagedResource]
ownedHistoryResources history =
  [ resource
  | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
  , bundle <- ResourceInventory.scopeBundles scope
  , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
  ]
    <> map snd (Map.elems (InventoryPlan.historyRetained history))

historyHostnameDeclarations :: InventoryPlan.InventoryHistory -> [ResourceInventory.Declaration]
historyHostnameDeclarations history =
  [ declaration
  | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
  , bundle <- ResourceInventory.scopeBundles scope
  , declaration <- ResourceInventory.declarations bundle
  ]
    <> [ ResourceInventory.Managed resource
       | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
       ]

-- The accepted auth owner composes backend and portal settings from contributor
-- scopes. Legacy resolver and portal-sync paths can rewrite those shared maps
-- even when their selected Service is otherwise unowned.
authSharedSettingsOwned :: InventoryPlan.InventoryHistory -> Bool
authSharedSettingsOwned history = acceptedGrant || acceptedResource || retained
  where
    acceptedGrant =
      or
        [ True
        | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles scope
        , grant <- ResourceInventory.grants bundle
        , case grant of
            ResourceInventory.BackendMapGrant _ -> True
            ResourceInventory.ShomeiSettingsGrant _ _ -> True
            _ -> False
        ]
    acceptedResource =
      or
        [ shared resource
        | (_, scope) <- Map.elems (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        ]
    retained =
      or
        [ True
        | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
        , shared resource
        ]
    shared resource = case resource ^. #spec of
      ResourceInventory.BackendMapSpec _ -> True
      ResourceInventory.ShomeiSettingsSpec {} -> True
      _ -> False

refuseDirectAccessOwnerIfManaged :: Maybe String -> Text -> IO ()
refuseDirectAccessOwnerIfManaged mctx operation =
  withAcceptedInventoryHistory mctx operation $ \history ->
    when
      (authSharedSettingsOwned history)
      (dieT "shared auth settings are owned by accepted or retained inventory; direct access routing is refused")

refuseDirectLegacyOperationWhenManaged :: Maybe String -> Text -> Text -> IO ()
refuseDirectLegacyOperationWhenManaged mctx operation remedy =
  withAcceptedInventoryHistory mctx operation $ \_ ->
    dieT
      ( "inventory history is initialized; direct "
          <> operation
          <> " is refused; "
          <> remedy
      )

refuseDirectCdnHostMutationIfOwned :: Maybe String -> Text -> Text -> IO ()
refuseDirectCdnHostMutationIfOwned mctx operation host =
  withAcceptedInventoryHistory mctx operation $ \history ->
    when
      (hostnameClaimOwned host (historyHostnameDeclarations history))
      ( dieT
          ( "hostname "
              <> host
              <> " is claimed by accepted or retained inventory; direct "
              <> operation
              <> " is refused"
          )
      )

refuseDirectCloudflareZoneMutationIfOwned :: Maybe String -> Text -> IO ()
refuseDirectCloudflareZoneMutationIfOwned mctx operation =
  withAcceptedInventoryHistory mctx operation $ \history ->
    when
      (cloudflareZoneOwned history)
      ( dieT
          ( "direct "
              <> operation
              <> " is refused while Cloudflare zone ownership is accepted or retained, or an inventory transaction is active"
          )
      )

cloudflareZoneOwned :: InventoryPlan.InventoryHistory -> Bool
cloudflareZoneOwned history = accepted || retained || unresolved
  where
    accepted =
      or
        [ True
        | (_, (_, scope)) <- Map.toAscList (InventoryPlan.historyAccepted history)
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.CloudflareZoneGrant _ _ <- ResourceInventory.grants bundle
        ]
    retained =
      or
        [ True
        | (_, resource) <- Map.elems (InventoryPlan.historyRetained history)
        , case resource ^. #address of
            Resource.CloudflareRuleset _ -> True
            Resource.CloudflareTlsSetting _ -> True
            Resource.CloudflareDnsRecord _ _ -> True
            _ -> False
        ]
    unresolved = isJust (InventoryStore.headActiveTransaction (InventoryPlan.historyHead history))
