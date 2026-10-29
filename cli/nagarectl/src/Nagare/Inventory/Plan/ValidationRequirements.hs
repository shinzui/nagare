-- | EP-225 M2: validation requirements. A verification of an unchanged member
-- that only a bootstrap review asks for is not a mutation intent: the review
-- lists it apart from its operations, admission proves it freshly with the
-- adapter's own preflight and verification, and nothing journals it.
module Nagare.Inventory.Plan.ValidationRequirements
  ( separateValidations
  )
where

import Data.List (partition)
import Data.Set (Set)
import Data.Set qualified as Set
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (VerifyResource), PlannedOperation (..))
import Nagare.Resource.Types (ResourceId)

-- | Split the planned operations into the operations and the validations of
-- the given members. Admission proves every validation before any operation
-- runs, so no operation keeps an edge to one, and no validation waits on
-- another: proofs are effect-free and independent.
separateValidations :: Set ResourceId -> [PlannedOperation] -> ([PlannedOperation], [PlannedOperation])
separateValidations validated planned =
  ( [operation {plannedDependencies = filter (`Set.notMember` identities) (plannedDependencies operation)} | operation <- operations]
  , [validation {plannedDependencies = []} | validation <- validations]
  )
  where
    (validations, operations) = partition validationOnly planned
    identities = Set.fromList (map plannedOperationId validations)
    validationOnly operation = plannedAction operation == VerifyResource && all (`Set.member` validated) (plannedResources operation)
