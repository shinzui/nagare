-- | Options / NixCache. Option records for the @nix-cache@ commands; parsing-only.
module Nagare.Cli.Options.NixCache
  ( NixCacheCommand (..)
  , NixCacheTokenOpts (..)
  , NixCacheForwardOpts (..)
  , NixCachePushOpts (..)
  )
where

import Data.List.NonEmpty (NonEmpty)
import Nagare.Dsl.Prelude

-- | The workstation producer path to the context's Attic cache (EP-230).
data NixCacheCommand
  = NixCacheToken NixCacheTokenOpts
  | NixCacheForward NixCacheForwardOpts
  | NixCachePush NixCachePushOpts
  deriving stock (Generic, Show)

data NixCacheTokenOpts = NixCacheTokenOpts
  { out :: !FilePath
  , subject :: !String
  , validity :: !String
  }
  deriving stock (Generic, Show)

newtype NixCacheForwardOpts = NixCacheForwardOpts
  { contract :: Maybe Int
  }
  deriving stock (Generic, Show)

-- | Without @--endpoint@ the push goes to the context's cache; with it, to
-- any Attic, through @--token-file@ and @--cache@.
data NixCachePushOpts = NixCachePushOpts
  { endpoint :: !(Maybe String)
  , tokenFile :: !(Maybe FilePath)
  , cache :: !(Maybe String)
  , paths :: !(NonEmpty FilePath)
  , contract :: !(Maybe Int)
  }
  deriving stock (Generic, Show)
