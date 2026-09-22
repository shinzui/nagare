-- | Stable inventory identity for a managed database. A configured logical key
-- survives a provider rename; legacy declarations default to their name.
module Nagare.Resource.Database (databaseResourceId) where

import Data.Generics.Labels ()
import Nagare.Dsl.Database (Database (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (databaseNameText)
import Nagare.Resource.Types

databaseResourceId :: ScopeId -> Name -> Database -> Either Text ResourceId
databaseResourceId owner role database =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (databaseNameText (database ^. #name))) Right (database ^. #logicalKey)
