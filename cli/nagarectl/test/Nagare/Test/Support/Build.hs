-- | Support.Build responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Build
  ( dockerfileSpec
  , nixpacksSpec
  , prebuiltSpec
  )
where

import Data.Map qualified as Map
import Nagare.Dsl.Build (BuildSpec (..), mkTag)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Static.Types (mkFilePathText)
import Nagare.Test.Support.Assertions (unsafe)

-- ---------------------------------------------------------------------------
-- Build modes (EP-20)

dockerfileSpec :: BuildSpec
dockerfileSpec =
  DockerfileBuild
    { dockerfile = unsafe (mkFilePathText "Dockerfile")
    , context = unsafe (mkFilePathText ".")
    , buildArgs = Map.fromList [("MODE", "release"), ("VERSION", "1.0")]
    }

nixpacksSpec :: BuildSpec
nixpacksSpec =
  NixpacksBuild
    { context = unsafe (mkFilePathText ".")
    , buildArgs = Map.empty
    }

prebuiltSpec :: BuildSpec
prebuiltSpec = PrebuiltImage (unsafe (mkTag "v1.2.3"))
