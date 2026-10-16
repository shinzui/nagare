{-# LANGUAGE PackageImports #-}

-- | The @nagare-contract@ custom prelude. Like the other Nagare preludes it
-- deliberately does not re-export @Data.Generics.Labels@.
module Nagare.Contract.Prelude
  ( module X
  , module Control.Lens
  )
where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Data.Bifunctor as X (first)
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
