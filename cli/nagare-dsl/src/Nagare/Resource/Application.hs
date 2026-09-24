-- | Stable inventory identities for user-declared application resources.
-- The optional key is pinned before a provider name changes; otherwise the
-- original declared name is the key for backward compatibility.
module Nagare.Resource.Application
  ( applicationScopeId
  , deploymentResourceId
  , volumeResourceId
  ) where

import Data.Generics.Labels ()
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( Deployment (..)
  , Volume (..)
  , serviceNameText
  , volumeNameText
  )
import Nagare.Resource.Types

applicationScopeId :: Application -> Either Text ScopeId
applicationScopeId app =
  mkScopeId Application (maybe (serviceNameText (app ^. #name)) logicalKeyText
    (app ^. #logicalKey))

deploymentResourceId :: ScopeId -> Name -> Deployment -> Either Text ResourceId
deploymentResourceId owner role deployment =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (serviceNameText (deployment ^. #name))) Right
      (deployment ^. #logicalKey)

volumeResourceId :: ScopeId -> Name -> Volume -> Either Text ResourceId
volumeResourceId owner role volume =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (volumeNameText (volume ^. #name))) Right
      (volume ^. #logicalKey)
