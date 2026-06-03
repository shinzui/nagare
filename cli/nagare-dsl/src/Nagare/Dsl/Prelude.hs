{-# LANGUAGE PackageImports #-}

-- | The @nagare-dsl@ custom prelude. Re-exports the common imports used across
-- the package (so modules do not repeat them) plus the lens operators. Per the
-- house standard it deliberately does NOT re-export @Data.Generics.Labels@ —
-- each module that uses @#label@ access imports it itself, so the orphan
-- @IsLabel@ instance is not forced on every module.
module Nagare.Dsl.Prelude
  ( module X
  , module Control.Lens
  ) where

import "lens" Control.Lens
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" GHC.Generics as X (Generic)
import "text" Data.Text as X (Text)
