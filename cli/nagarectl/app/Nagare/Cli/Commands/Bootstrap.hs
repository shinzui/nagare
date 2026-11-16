-- | Commands / Bootstrap. Executable-private CLI boundary.
module Nagare.Cli.Commands.Bootstrap
  ( runPlatformBootstrapApply
  , runPlatformBootstrapPlan
  )
where

import Data.Text qualified as T
import Nagare.Cli.Bootstrap.Review (applyStageReview, planStageReview)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude

-- | Build the production cloud adapter from the same composed declarations the
-- generic planner sees. Other domains retain their refusing adapters until
-- their production runtimes are registered by this child or later children.
runPlatformBootstrapPlan :: Maybe String -> FilePath -> IO ()
runPlatformBootstrapPlan mctx output = do
  active <- activeTarget mctx
  planStageReview active ("nagare-bootstrap:" <>) output

runPlatformBootstrapApply :: Maybe String -> FilePath -> Bool -> IO ()
runPlatformBootstrapApply mctx reviewDirectory yes = do
  active <- activeTarget mctx
  applyStageReview mctx active ("nagare-bootstrap:" `T.isPrefixOf`) "platform bootstrap apply requires a payload-bound bootstrap review" reviewDirectory yes
