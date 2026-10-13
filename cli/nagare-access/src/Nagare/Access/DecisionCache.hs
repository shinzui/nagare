-- | Short-lived cache for en authorization decisions.
--
-- The cache bounds how long a revoked grant keeps admitting new requests: a
-- miss asks en at a fully consistent snapshot ("Nagare.Access.En"), and the
-- answer is served for at most the TTL, measured on the injected clock from
-- the start of that check. @NAGARE_ACCESS_DECISION_TTL@ sets the TTL (default
-- 30 seconds; zero disables the cache). Live entries are bounded too, so a
-- long-running process with many subject/host pairs cannot grow without limit.
module Nagare.Access.DecisionCache
  ( AccessDecision (..)
  , AuthorizationResult (..)
  , DecisionCache
  , DecisionKey (..)
  , cacheLookupOrLoad
  , cacheSize
  , defaultDecisionCacheEntries
  , disabledDecisionCache
  , newBoundedDecisionCache
  , newDecisionCache
  )
where

import Data.Generics.Labels ()
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Nagare.Access.Prelude

data AccessDecision
  = AccessAllowed
  | AccessDenied
  | AccessConditional
  deriving stock (Generic, Eq, Show)

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
  deriving stock (Generic, Eq, Show)

data DecisionKey = DecisionKey
  { subject :: !Text
  , host :: !Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data DecisionCache
  = DecisionCacheDisabled
  | DecisionCache
      { ttlSeconds :: !Int
      , maxEntries :: !Int
      , nowSeconds :: !(IO Int)
      , entriesRef :: !(IORef (Map DecisionKey CachedDecision))
      }
  deriving stock (Generic)

data CachedDecision = CachedDecision
  { atSeconds :: !Int
  , decision :: !AccessDecision
  }
  deriving stock (Generic, Eq, Show)

-- | The default bound on live entries: one entry per subject/host pair seen
-- within a TTL, far above what one enforcer serves, and small in memory.
defaultDecisionCacheEntries :: Int
defaultDecisionCacheEntries = 10000

-- | A cache with the default entry bound. The clock must be monotonic (the
-- enforcer passes 'GHC.Clock.getMonotonicTime' seconds): the TTL is a
-- duration, and a wall clock that steps backwards would revive an expired
-- allow.
newDecisionCache :: Int -> IO Int -> IO DecisionCache
newDecisionCache ttl = newBoundedDecisionCache ttl defaultDecisionCacheEntries

newBoundedDecisionCache :: Int -> Int -> IO Int -> IO DecisionCache
newBoundedDecisionCache ttl bound now
  | ttl <= 0 || bound <= 0 = pure DecisionCacheDisabled
  | otherwise = DecisionCache ttl bound now <$> newIORef Map.empty

disabledDecisionCache :: DecisionCache
disabledDecisionCache = DecisionCacheDisabled

-- | Return the cached decision for this key when one is fresh, otherwise run
-- the loader and cache what it produced.
--
-- Only an 'AuthorizationDecision' is ever written: an 'AuthorizationUnavailable'
-- is passed straight back to the caller, so the next request retries the
-- authorizer instead of inheriting an outage for the rest of the TTL.
--
-- The entry is stamped with the clock read before the loader ran, so a
-- loader that takes longer than the TTL produces an entry that is already
-- expired, and a slow older check can never extend a newer answer.
-- Concurrent misses for one key each run the loader; there is no coalescing,
-- so the duplicate cost is one en check per in-flight miss.
cacheLookupOrLoad :: DecisionCache -> DecisionKey -> IO AuthorizationResult -> IO AuthorizationResult
cacheLookupOrLoad DecisionCacheDisabled _ loadDecision =
  loadDecision
cacheLookupOrLoad cache@DecisionCache {nowSeconds, entriesRef} key loadDecision = do
  now <- nowSeconds
  entries <- readIORef entriesRef
  case Map.lookup key entries of
    Just cached
      | not (isExpired cache now cached) ->
          pure (AuthorizationDecision (cached ^. #decision))
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
cacheSize DecisionCache {entriesRef} = Map.size <$> readIORef entriesRef

isExpired :: DecisionCache -> Int -> CachedDecision -> Bool
isExpired DecisionCacheDisabled _ _ = True
isExpired DecisionCache {ttlSeconds} now cached =
  now - cached ^. #atSeconds >= ttlSeconds

-- | Insert an entry, keeping a newer one for the same key, and keep the map
-- within its bound.
--
-- A write never replaces an entry stamped later than itself: two concurrent
-- misses for one key may complete out of order, and the later check saw the
-- later state. Eviction runs only when the bound is reached, first dropping
-- expired entries and then the oldest live ones, so an ordinary insert costs
-- one map update rather than a scan of every entry.
writeCache :: DecisionCache -> DecisionKey -> Int -> AccessDecision -> IO ()
writeCache DecisionCacheDisabled _ _ _ =
  pure ()
writeCache cache@DecisionCache {entriesRef, maxEntries} key now decision =
  atomicModifyIORef'
    entriesRef
    ( \entries ->
        let inserted = Map.insertWith keepNewer key CachedDecision {atSeconds = now, decision = decision} entries
         in (if Map.size inserted > maxEntries then bounded inserted else inserted, ())
    )
  where
    keepNewer new old = if new ^. #atSeconds >= old ^. #atSeconds then new else old
    bounded entries =
      let live = Map.filter (not . isExpired cache now) entries
          excess = Map.size live - maxEntries
       in if excess <= 0
            then live
            else foldr Map.delete live (map fst (take excess (sortOn (atSeconds . snd) (Map.toList live))))
