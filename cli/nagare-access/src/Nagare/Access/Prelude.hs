{-# LANGUAGE PackageImports #-}

-- | The @nagare-access@ custom prelude. It deliberately does not re-export
-- @Data.Generics.Labels@; modules using generic-lens labels import that orphan
-- instance explicitly.
module Nagare.Access.Prelude
  ( module X
  , module Control.Lens
  )
where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Data.Bifunctor as X (first)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
