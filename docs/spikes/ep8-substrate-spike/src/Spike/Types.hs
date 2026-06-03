-- | Minimal, un-validated Deployment record shared by all three spike
-- prototypes. This is NOT the production type (that lives in EP-9's
-- @Nagare.Dsl.Types@). Invariants are deliberately loose here so every
-- substrate is compared against the same rendering function; the scoring
-- rubric assesses each substrate's ability to /enforce/ invariants in its own
-- type system.
module Spike.Types
  ( Deployment (..)
  , EnvVar (..)
  , Resources (..)
  , Scale (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

data EnvVar
  = -- | a plain value: @{ value: "info" }@
    EnvLiteral !Text
  | -- | a secret reference: @valueFrom.secretKeyRef@
    EnvSecretRef !Text
  deriving stock (Eq, Show)

data Resources = Resources
  { resCpu :: !(Maybe Text)
  , resMemory :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data Scale = Scale
  { scaleMin :: !Int
  , scaleMax :: !Int
  }
  deriving stock (Eq, Show)

data Deployment = Deployment
  { depName :: !Text
  , depNamespace :: !Text
  -- | repository path; no tag (the tag is supplied at render time)
  , depImage :: !Text
  , depPort :: !Int
  , depEnv :: !(Map Text EnvVar)
  , depResources :: !(Maybe Resources)
  , depScale :: !(Maybe Scale)
  , depDomain :: !(Maybe Text)
  }
  deriving stock (Eq, Show)
