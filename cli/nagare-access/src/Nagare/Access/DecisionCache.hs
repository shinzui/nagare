-- | Short-lived cache for en authorization decisions.
module Nagare.Access.DecisionCache
  ( AccessDecision (..)
  , AuthorizationResult (..)
  , DecisionCache
  , DecisionKey (..)
  , cacheLookupOrLoad
  , cacheSize
  , disabledDecisionCache
  , newDecisionCache
  )
where

import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

data AccessDecision
  = AccessAllowed
  | AccessDenied
  | AccessConditional
  deriving stock (Eq, Show)

-- | The outcome of asking the authorizer, which is not the same thing as a
-- decision: either the authorizer answered (and its answer is an
-- 'AccessDecision'), or it could not be reached at all.
--
-- Keeping these apart is the whole point. Folding "en is unreachable" into
-- 'AccessDenied' means a transient outage is cached as a legitimate denial for
-- the full TTL, locking users out of every protected host and looking, from
-- the outside, exactly like a real policy decision.
data AuthorizationResult
  = AuthorizationDecision !AccessDecision
  | -- | the authorizer could not be reached; the text is the transport-level
    -- diagnostic, for logs and 5xx bodies
    AuthorizationUnavailable !Text
  deriving stock (Eq, Show)

data DecisionKey = DecisionKey
  { subject :: !Text
  , host :: !Text
  }
  deriving stock (Eq, Ord, Show)

data DecisionCache
  = DecisionCacheDisabled
  | DecisionCache
      { ttlSeconds :: !Int
      , nowSeconds :: !(IO Int)
      , entriesRef :: !(IORef (Map DecisionKey CachedDecision))
      }

data CachedDecision = CachedDecision
  { cachedAtSeconds :: !Int
  , cachedDecision :: !AccessDecision
  }
  deriving stock (Eq, Show)

newDecisionCache :: Int -> IO Int -> IO DecisionCache
newDecisionCache ttl now
  | ttl <= 0 = pure DecisionCacheDisabled
  | otherwise = DecisionCache ttl now <$> newIORef Map.empty

disabledDecisionCache :: DecisionCache
disabledDecisionCache = DecisionCacheDisabled

-- | Return the cached decision for this key when one is fresh, otherwise run
-- the loader and cache what it produced.
--
-- Only an 'AuthorizationDecision' is ever written: an 'AuthorizationUnavailable'
-- is passed straight back to the caller, so the next request retries the
-- authorizer instead of inheriting an outage for the rest of the TTL.
cacheLookupOrLoad :: DecisionCache -> DecisionKey -> IO AuthorizationResult -> IO AuthorizationResult
cacheLookupOrLoad DecisionCacheDisabled _ loadDecision =
  loadDecision
cacheLookupOrLoad cache key loadDecision = do
  now <- nowSeconds cache
  entries <- readIORef (entriesRef cache)
  case Map.lookup key entries of
    Just cached
      | not (isExpired cache now cached) ->
          pure (AuthorizationDecision (cachedDecision cached))
    _ -> do
      result <- loadDecision
      case result of
        AuthorizationDecision decision -> writeCache cache key now decision
        AuthorizationUnavailable _ -> pure ()
      pure result

-- | How many entries the cache currently holds (0 when disabled). Exposed so
-- eviction is observable in tests without handing out the map.
cacheSize :: DecisionCache -> IO Int
cacheSize DecisionCacheDisabled = pure 0
cacheSize cache = Map.size <$> readIORef (entriesRef cache)

isExpired :: DecisionCache -> Int -> CachedDecision -> Bool
isExpired DecisionCacheDisabled _ _ = True
isExpired cache now cached =
  now - cachedAtSeconds cached >= ttlSeconds cache

-- | Insert an entry, dropping every expired one on the way in.
--
-- Without this the map only ever grows: an entry for a (subject, host) pair
-- that is never queried again is never removed, so a process that runs for
-- weeks accumulates dead keys forever. Filtering on write is O(n) over a map
-- that this same filtering keeps small, needs no extra bookkeeping, and is
-- deterministic to test through the injected clock.
writeCache :: DecisionCache -> DecisionKey -> Int -> AccessDecision -> IO ()
writeCache DecisionCacheDisabled _ _ _ =
  pure ()
writeCache cache key now decision =
  atomicModifyIORef'
    (entriesRef cache)
    ( \entries ->
        ( Map.insert
            key
            CachedDecision {cachedAtSeconds = now, cachedDecision = decision}
            (Map.filter (not . isExpired cache now) entries)
        , ()
        )
    )
