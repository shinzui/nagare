-- | Typed identity and output contract for one logical Attic cache.
-- Kubernetes workload members and the database are separate declarations;
-- this resource owns only Attic's named logical cache configuration.
module Nagare.Resource.Cache
  ( LogicalCacheInput (..)
  , compileLogicalCache
  ) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data LogicalCacheInput = LogicalCacheInput
  { cacheOwnerScope :: !ScopeId
  , cacheCluster :: !ResourceId
  , cacheLogicalKey :: !LogicalKey
  , cacheName :: !Name
  , cacheConfigurationDigest :: !ContentDigest
  , cacheDatabase :: !ResourceId
  , cacheWorkload :: !ResourceId
  , cacheSource :: !SourceLocation
  }

-- | The signing public key is an output of reconciliation, not a caller-supplied
-- string. A client must consume this exact typed reference from the cache.
compileLogicalCache :: LogicalCacheInput -> ResourceBundle
compileLogicalCache input =
  ResourceBundle
    { declarations = [Managed resource]
    , exports = [SomeExport publicKey]
    , conditions = []
    , contributions = []
    , operations =
        [ DeclaredOperation
            { identity = mintResourceId (cacheOwnerScope input) (cacheLogicalKey input) (known "configure-cache")
            , affects = resourceId :| []
            , inputs = [ContentInput (cacheConfigurationDigest input)]
            , recovery = VerifyBeforeRetry
            , operationKind = CreateLogicalCache
            }
        ]
    , grants = []
    }
  where
    resourceId = mintResourceId (cacheOwnerScope input) (cacheLogicalKey input) (known "logical-cache")
    publicKey = outputRef NixCachePublicKeyW resourceId (known "public-key") [NonEmptyOutput] Public
    resource = ManagedResource
      { identity = resourceId
      , owner = cacheOwnerScope input
      , executor = CacheExecutor
      , address = AtticCache (cacheCluster input) (cacheName input)
      , aliases = []
      , spec = LogicalCache (cacheConfigurationDigest input)
      , lifecycle = Retain
      , dataPolicy = Stateless
      , sensitivity = Public
      , dependencies = [OrderedAfter (cacheDatabase input), OrderedAfter (cacheWorkload input)]
      , delegations = []
      , source = cacheSource input
      }
    known value = either (error . show) id (mkName value)
