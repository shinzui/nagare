-- | Bootstrap / Stage. Executable-private CLI boundary.
module Nagare.Cli.Bootstrap.Stage (StageMode (..)) where

import Nagare.Dsl.Prelude

-- | Who plans a stage: a fresh bootstrap, or the release transition of an
-- admitted context (EP-172), which may replace the accepted host image and
-- re-pin the host flake to the target payload.
data StageMode = FreshBootstrap | ReleaseTransition
  deriving stock (Eq, Show)
