-- | Short-lived cache for en authorization decisions.
module Nagare.Access.DecisionCache
  ( AccessDecision (..)
  , DecisionCache
  , DecisionKey (..)
  , cacheLookupOrLoad
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

cacheLookupOrLoad :: DecisionCache -> DecisionKey -> IO AccessDecision -> IO AccessDecision
cacheLookupOrLoad DecisionCacheDisabled _ loadDecision =
  loadDecision
cacheLookupOrLoad cache key loadDecision = do
  now <- nowSeconds cache
  entries <- readIORef (entriesRef cache)
  case Map.lookup key entries of
    Just cached
      | not (isExpired cache now cached) ->
          pure (cachedDecision cached)
    _ -> do
      decision <- loadDecision
      writeCache cache key now decision
      pure decision

isExpired :: DecisionCache -> Int -> CachedDecision -> Bool
isExpired DecisionCacheDisabled _ _ = True
isExpired cache now cached =
  now - cachedAtSeconds cached >= ttlSeconds cache

writeCache :: DecisionCache -> DecisionKey -> Int -> AccessDecision -> IO ()
writeCache DecisionCacheDisabled _ _ _ =
  pure ()
writeCache cache key now decision =
  atomicModifyIORef'
    (entriesRef cache)
    (\entries -> (Map.insert key CachedDecision {cachedAtSeconds = now, cachedDecision = decision} entries, ()))
