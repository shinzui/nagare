-- | EP-183 M4: the reviewed rebuild input. After the cluster is lost, each
-- accepted durable member whose object is confirmed absent is recreated as a
-- new incarnation through one decision naming its predecessor and its data
-- source. 'rebuildTargets' generates the decisions `inventory
-- rebuild-decisions` prints; 'decideRebuild' checks an operator's input
-- against a fresh observation and hands it to the one planner as lifecycle
-- decisions, which validate it again.
module Nagare.Inventory.Rebuild
  ( RebuildTarget (..)
  , RebuildInput (..)
  , decodeRebuildInput
  , decideRebuild
  , rebuildTargets
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Either (partitionEithers)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Lineage (RebuildProof (..), RebuildSource (..))
import Nagare.Inventory.Plan
import Nagare.Inventory.Store (HeadManifest (headIncarnations))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (Durable))
import Nagare.Resource.Types
import Nagare.Resource.Wire ()

-- | One member to recreate, at its declared address, and what the rebuild names.
data RebuildTarget = RebuildTarget
  { resource :: !ResourceId
  , address :: !ProviderAddress
  , proof :: !RebuildProof
  }
  deriving stock (Eq, Show, Generic)

data RebuildInput = RebuildInput
  { binding :: !ContextBinding
  , targets :: ![RebuildTarget]
  }
  deriving stock (Eq, Show, Generic)

decodeRebuildInput :: ByteString -> Either Text RebuildInput
decodeRebuildInput bytes = first T.pack (eitherDecodeStrict' bytes)

-- | Check the input against the composed declaration, the context and a fresh
-- observation, then submit one 'ApproveRebuild' per member.
decideRebuild ::
  CompositionCandidate ->
  InventoryHistory ->
  ObservationSet ->
  RebuildInput ->
  Either (NonEmpty PlanError) LifecycleDecisions
decideRebuild candidate history observations input = do
  unless (null errors) (Left (NE.fromList errors))
  validateLifecycleDecisions
    candidate
    history
    observations
    [ LifecycleProposal member (ApproveRebuild (target ^. #proof)) (lifecycleObservationDigest contextBinding member fact)
    | target <- input ^. #targets
    , let member = target ^. #resource
    , Just fact <- [Map.lookup member (observationMap observations)]
    ]
  where
    contextBinding = inventoryBinding (candidateInventory candidate)
    declared = Map.fromList [(declaration ^. #identity, declaration) | Managed declaration <- inventoryDeclarations (candidateInventory candidate)]
    issue code message member = PlanError code message [member]
    errors =
      [issue "rebuild-binding" "the rebuild belongs to another context or provider target" (target ^. #resource) | target <- input ^. #targets, input ^. #binding /= contextBinding]
        <> [ issue "rebuild-declaration" "the rebuild's address differs from the composed declaration" (target ^. #resource)
           | target <- input ^. #targets
           , maybe True ((/= target ^. #address) . (^. #address)) (Map.lookup (target ^. #resource) declared)
           ]
        <> [ issue "rebuild-incarnation" "a rebuild recreates only a member whose object is confirmed absent" (target ^. #resource)
           | target <- input ^. #targets
           , not (confirmedAbsent (Map.lookup (target ^. #resource) (observationMap observations)))
           ]
        <> [issue "duplicate-rebuild" "the member appears more than once in the rebuild" member | member <- duplicateValues (map (^. #resource) (input ^. #targets))]
    confirmedAbsent = \case
      Just (ConfirmedAbsent _) -> True
      _ -> False

-- | One rebuild per accepted durable Kubernetes member that stays declared and
-- is confirmed absent, naming its recorded incarnation (none when none was
-- recorded). A generated Secret starts fresh; the caller chooses every other
-- member's source from its recorded predecessor: a verified recovery point,
-- or, only by the operator's explicit choice, fresh.
rebuildTargets ::
  CompositionCandidate ->
  InventoryHistory ->
  ObservationSet ->
  (ResourceId -> Maybe PhysicalIdentity -> Either PlanError RebuildSource) ->
  Either (NonEmpty PlanError) [RebuildTarget]
rebuildTargets candidate history observations sourceFor = case partitionEithers (map target missing) of
  ([], selected) -> Right selected
  (err : errs, _) -> Left (err :| errs)
  where
    recorded = headIncarnations (historyHead history)
    accepted =
      Set.fromList
        [declaration ^. #identity | (_, scope) <- Map.elems (historyAccepted history), bundle <- scopeBundles scope, Managed declaration <- declarations bundle]
    missing =
      [ declaration
      | Managed declaration <- inventoryDeclarations (candidateInventory candidate)
      , declaration ^. #executor == KubernetesExecutor
      , Durable _ <- [declaration ^. #dataPolicy]
      , Set.member (declaration ^. #identity) accepted
      , Just (ConfirmedAbsent _) <- [Map.lookup (declaration ^. #identity) (observationMap observations)]
      ]
    target declaration = do
      let member = declaration ^. #identity
          predecessor' = Map.lookup member recorded
      source' <- case declaration ^. #address of
        Kubernetes _ "" kind _ _ | nameText kind == "secret" -> Right Fresh
        _ -> sourceFor member predecessor'
      pure (RebuildTarget member (declaration ^. #address) (RebuildProof predecessor' source'))

instance ToJSON RebuildTarget where
  toJSON target = case toJSON (target ^. #proof) of
    Object fields -> Object (KM.insert "resource" (toJSON (target ^. #resource)) (KM.insert "address" (toJSON (target ^. #address)) fields))
    other -> other

instance FromJSON RebuildTarget where
  parseJSON = withObject "RebuildTarget" $ \o ->
    RebuildTarget <$> o .: "resource" <*> o .: "address" <*> parseJSON (Object (KM.delete "resource" (KM.delete "address" o)))

instance ToJSON RebuildInput where
  toJSON input = object ["version" .= (1 :: Int), "binding" .= (input ^. #binding), "rebuilds" .= (input ^. #targets)]

instance FromJSON RebuildInput where
  parseJSON = withObject "RebuildInput" $ \o -> do
    unless (all (`elem` ["version", "binding", "rebuilds"]) (KM.keys o)) (fail "unknown rebuild input field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported rebuild input version")
    selected <- o .: "rebuilds"
    when (null (selected :: [RebuildTarget])) (fail "a rebuild needs at least one member")
    RebuildInput <$> o .: "binding" <*> pure selected
