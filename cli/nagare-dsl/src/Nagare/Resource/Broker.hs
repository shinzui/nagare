-- | Stable inventory identity for a declared broker. Provider renames keep
-- the same identity only when the operator pins an explicit logical key.
module Nagare.Resource.Broker (brokerResourceId) where

import Data.Generics.Labels ()
import Nagare.Dsl.Broker (Broker (..), brokerNameText)
import Nagare.Dsl.Prelude
import Nagare.Resource.Types

brokerResourceId :: ScopeId -> Name -> Broker -> Either Text ResourceId
brokerResourceId owner role broker =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (brokerNameText (broker ^. #name))) Right
      (broker ^. #logicalKey)
