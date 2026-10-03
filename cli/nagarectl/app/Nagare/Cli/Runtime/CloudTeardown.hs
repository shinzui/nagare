-- | Teardown is policy review, retained retirement, then exact leaf collection.
module Nagare.Cli.Runtime.CloudTeardown (saveReviewedCloudTeardown) where

import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.CloudHistory (requireCloudCollectionProtocol)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Platform.InfrastructureReview (prepareInfraTargetWithPulumi)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.CloudCollection
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Inventory.Status (consumersOf)
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types
import Nagare.Target (Mode (Cloud))

saveReviewedCloudTeardown :: Maybe String -> FilePath -> IO ()
saveReviewedCloudTeardown selected output = do
  active <- activeTarget selected
  unless (active ^. #profile . #mode == Cloud) (dieT "infra destroy requires a cloud context")
  -- Planning prepares Pulumi collection plans, so it needs the context's
  -- Pulumi home, backend and passphrase file exactly as inventory apply does.
  -- This target-level preparation never probes the guest being torn down.
  (_, workspace) <- prepareInfraTargetWithPulumi True active
  requireCloudCollectionProtocol workspace
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  history <- Plan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (Resource.composeSnapshot snapshot)
  let cloudOwner owner = scopeKind owner == Platform && nameText (scopeName owner) == "cloud"
      activeCloud = [scope | (_, scope) <- Map.elems (Resource.snapshotScopes snapshot), cloudOwner (Resource.scopeId scope)]
      retained = Map.filter (cloudOwner . (^. #owner) . snd) (Plan.historyRetained history)
      desired = Set.fromList (map Resource.declarationId (Resource.inventoryDeclarations inventory))
      eligible =
        [ resource
        | (resource, (_, member)) <- Map.toAscList retained
        , cloudCollectionEligible member
        , supportsRetainedCollection member
        , Set.notMember resource desired
        , null (consumersOf history inventory resource)
        ]
      registry check candidate previous = withPreparationGuard check <$> inventoryPlanRegistry active workspace candidate previous
  case activeCloud of
    [scope] -> do
      revised <- either dieT pure (compileCloudCollectionPolicy scope)
      if revised /= scope
        then do
          candidate <- either (dieT . T.pack . show) pure (Resource.composeInventory snapshot (Resource.ReplaceScope revised NE.:| []))
          Inventory.planInventoryCandidateWith (registry verifyOnly) active candidate output
          TIO.putStrLn "Saved cloud teardown policy review; apply it, then review retirement. Data and authority remain protected."
        else do
          Inventory.planInventoryRetirementsWith (registry verifyOnly) (const (Right ())) active (Resource.scopeId scope NE.:| []) output
          TIO.putStrLn "Saved cloud scope retirement with all native resources retained; apply it, then review exact leaf collection."
    [] -> case eligible of
      resource : _ -> do
        Inventory.planInventoryCollectionWith (registry (collectOnly resource)) active resource output
        TIO.putStrLn "Saved one exact retained cloud collection; protected resources and members with consumers remain retained."
      [] -> TIO.putStrLn ("No eligible cloud collection; " <> T.pack (show (Map.size retained)) <> " protected or dependency-blocked members remain retained. No review created.")
    _ -> dieT "cloud scope is ambiguous"
  where
    verifyOnly operation =
      unless
        (plannedAction operation == VerifyResource)
        (Left "cloud teardown policy and retirement cannot repair or mutate native resources")
    collectOnly resource operation =
      unless
        (plannedAction operation == VerifyResource || (plannedAction operation == RetireResource && NE.toList (plannedResources operation) == [resource]))
        (Left "cloud collection cannot mutate beyond its exact selected retained member")
