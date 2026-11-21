-- | The relationship a reviewed access scope controls, read from its typed
-- address. Apart from "Nagare.Inventory.Access" so a reader of recorded
-- grants does not link the access adapter (MasterPlan 37).
module Nagare.Inventory.Access.Relationship
  ( Relationship (..)
  , relationshipOf
  )
where

import Nagare.Dsl.Prelude
import Nagare.Resource.Access (TeamKey)
import Nagare.Resource.Types (Name, ProviderAddress (..), ResourceId)

-- | The one relationship a reviewed access scope controls.
data Relationship
  = -- | @app:<host>#viewer@user:<id>@
    DirectViewer !Name !Text
  | -- | @group:<team>#member@user:<id>@
    TeamMember !TeamKey !Text
  | -- | @app:<host>#viewer@group:<team>#member@
    TeamViewer !Name !TeamKey
  | -- | EP-250: @delegation:<name>#viewer@group:<team>#member@
    DelegationViewer !Name !TeamKey
  deriving stock (Eq, Show)

-- | The auth en Service and the relationship a typed address names.
relationshipOf :: ProviderAddress -> Maybe (ResourceId, Relationship)
relationshipOf = \case
  AccessTuple auth host subject -> Just (auth, DirectViewer host subject)
  TeamMemberTuple auth team subject -> Just (auth, TeamMember team subject)
  TeamAccessTuple auth host team -> Just (auth, TeamViewer host team)
  DelegationAccessTuple auth delegation team -> Just (auth, DelegationViewer delegation team)
  _ -> Nothing
