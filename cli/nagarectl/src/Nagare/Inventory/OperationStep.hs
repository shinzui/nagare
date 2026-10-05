-- | The single serial phase decision for apply and resume. No provider IO.
module Nagare.Inventory.OperationStep
  ( OperationStep (..)
  , nextOperation
  , validateOperationGraph
  , dependenciesComplete
  , bootstrapRecoveryMarker
  )
where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan (ReviewOperation (..))
import Nagare.Resource.Types (ContentDigest, mkContentDigest)

data OperationStep
  = OperationsFinished
  | OperationBlocked !OperationId !Text
  | RecoverOperation !ReviewOperation
  | ExecuteOperation !ReviewOperation
  deriving stock (Eq, Show)

-- | Reject malformed graphs before acquiring execution authority. The driver
-- also refuses blocked graphs, so neither entry point can bypass dependencies.
validateOperationGraph :: [ReviewOperation] -> Either Text ()
validateOperationGraph operations
  | Set.size ids /= length operations = Left "duplicate operation identity"
  | any (any (`Set.notMember` ids) . dependencies) operations =
      Left "operation dependency is absent from the review"
  | otherwise = visit Set.empty operations
  where
    ids = Set.fromList (map identity operations)
    visit _ [] = Right ()
    visit completed remaining =
      let ready = filter (all (`Set.member` completed) . dependencies) remaining
          rest = filter (not . all (`Set.member` completed) . dependencies) remaining
       in if null ready
            then Left "operation dependency cycle"
            else visit (Set.union completed (Set.fromList (map identity ready))) rest

-- | Uncertain effects take priority over untouched work. Only a durable
-- completion proof satisfies a dependency. Legacy text markers are allowlisted;
-- an unknown resolution must never silently authorize another effect.
nextOperation :: [ReviewOperation] -> Map OperationId OperationState -> OperationStep
nextOperation operations states =
  case [(operation, reason) | operation <- ordered, Blocked reason <- [phase operation]] of
    (operation, reason) : _ -> OperationBlocked (identity operation) reason
    [] -> case [operation | operation <- ordered, Recover <- [phase operation]] of
      operation : _ -> RecoverOperation operation
      [] -> case [operation | operation <- ordered, Execute <- [phase operation], ready operation] of
        operation : _ -> ExecuteOperation operation
        [] -> case [operation | operation <- ordered, Execute <- [phase operation]] of
          operation : _ -> OperationBlocked (identity operation) "operation dependencies lack completion proof"
          [] -> OperationsFinished
  where
    ordered = sortOn identity operations
    phase operation = operationPhase (Map.lookup (identity operation) states)
    ready = dependenciesComplete states

data Phase = Done | Recover | Execute | Blocked Text

operationPhase :: Maybe OperationState -> Phase
operationPhase Nothing = Execute
operationPhase (Just state) = case state of
  Pending -> Execute
  IntentRecorded -> Recover
  Completed _ -> Done
  Failed failure -> case failure of
    KnownNoEffect _ -> Execute
    PartialOrUnknown _ -> Recover
  Ambiguous -> Recover
  OperatorResolved marker
    | marker == "adapter-proved-safe-retry"
        || marker == "fence-not-reserved-safe-retry" ->
        Execute
    | Just (_, Just _) <- bootstrapRecoveryMarker marker -> Recover
    | otherwise -> Blocked ("operator resolution requires explicit recovery: " <> marker)

-- Only a strictly parsed receipt returns to observation. An intent stays
-- blocked until the exact saved recovery is explicitly resolved.
bootstrapRecoveryMarker :: Text -> Maybe (ContentDigest, Maybe ContentDigest)
bootstrapRecoveryMarker marker = case T.splitOn ":" marker of
  ["bootstrap-registry-intent", native] ->
    (,Nothing) <$> either (const Nothing) Just (mkContentDigest native)
  ["bootstrap-registry-proved", native, receipt] -> do
    selected <- either (const Nothing) Just (mkContentDigest native)
    proof <- either (const Nothing) Just (mkContentDigest receipt)
    pure (selected, Just proof)
  _ -> Nothing

identity :: ReviewOperation -> OperationId
identity = plannedOperationId . reviewPlannedOperation

dependencies :: ReviewOperation -> [OperationId]
dependencies = plannedDependencies . reviewPlannedOperation

-- Recovery may inspect a historical effect out of order, but safe-to-retry is
-- not permission to mutate before its predecessors have durable proof.
dependenciesComplete :: Map OperationId OperationState -> ReviewOperation -> Bool
dependenciesComplete states =
  all
    ( \dependency -> case Map.lookup dependency states of
        Just (Completed _) -> True
        _ -> False
    )
    . dependencies
