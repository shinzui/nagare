-- | The decision cache: what it serves, what it never caches, and the bound
-- it puts on how long a revoked grant keeps admitting requests (EP-186 M3).
module DecisionCacheSpec (decisionCacheTests) where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Nagare.Access.DecisionCache
import Nagare.Access.Prelude
import Test.Tasty
import Test.Tasty.HUnit

decisionCacheTests :: TestTree
decisionCacheTests =
  testGroup
    "decision cache"
    [ testCase "cache hit reuses the previous decision" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (readIORef clock)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessAllowed)
        first <- cacheLookupOrLoad cache alice load
        second <- cacheLookupOrLoad cache alice load
        first @?= AuthorizationDecision AccessAllowed
        second @?= AuthorizationDecision AccessAllowed
        readIORef loads >>= (@?= 1)
    , testCase "expired entry reloads" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (readIORef clock)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessDenied)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
        modifyIORef' clock (+ 30)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
        readIORef loads >>= (@?= 2)
    , -- The revocation bound: a grant revoked at t is still served from the
      -- cache until t + TTL, and never past it. No sleeps: the clock is injected.
      testCase "a revoke is observed after at most the TTL" $ do
        clock <- newIORef 100
        answer <- newIORef AccessAllowed
        cache <- newDecisionCache 30 (readIORef clock)
        let load = AuthorizationDecision <$> readIORef answer
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessAllowed)
        writeIORef answer AccessDenied
        writeIORef clock 129
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessAllowed)
        writeIORef clock 130
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
    , testCase "a grant is observed after at most the TTL" $ do
        clock <- newIORef 100
        answer <- newIORef AccessDenied
        cache <- newDecisionCache 30 (readIORef clock)
        let load = AuthorizationDecision <$> readIORef answer
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
        writeIORef answer AccessAllowed
        writeIORef clock 130
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessAllowed)
    , -- Expiry is anchored to the start of the check, so a check that takes
      -- longer than the TTL produces an entry that is already stale.
      testCase "a result delayed past the TTL does not extend the allow" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (readIORef clock)
        let slow = modifyIORef' loads (+ 1) >> writeIORef clock 131 >> pure (AuthorizationDecision AccessAllowed)
            fresh = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessDenied)
        cacheLookupOrLoad cache alice slow >>= (@?= AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache alice fresh >>= (@?= AuthorizationDecision AccessDenied)
        readIORef loads >>= (@?= 2)
    , -- Two concurrent misses for one key may complete out of order. The one
      -- that started later saw the later state, so its answer wins even when
      -- the older check finishes last.
      testCase "an older concurrent completion cannot replace a newer entry" $ do
        clock <- newIORef 100
        cache <- newDecisionCache 30 (readIORef clock)
        let older = do
              -- While the older check is in flight, a newer one starts (at 110) and lands.
              writeIORef clock 110
              _ <- cacheLookupOrLoad cache alice (pure (AuthorizationDecision AccessDenied))
              pure (AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache alice older >>= (@?= AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache alice (pure (AuthorizationUnavailable "not asked")) >>= (@?= AuthorizationDecision AccessDenied)
    , -- Concurrent misses are not coalesced: each in-flight miss costs one en
      -- check. This records the duplicate cost rather than hiding it.
      testCase "concurrent misses for one key each ask the authorizer once" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        let inner = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessAllowed)
            outer = modifyIORef' loads (+ 1) >> cacheLookupOrLoad cache alice inner
        cacheLookupOrLoad cache alice outer >>= (@?= AuthorizationDecision AccessAllowed)
        readIORef loads >>= (@?= 2)
        cacheLookupOrLoad cache alice outer >>= (@?= AuthorizationDecision AccessAllowed)
        readIORef loads >>= (@?= 2)
    , testCase "zero ttl disables caching" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 0 (pure 100)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessConditional)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessConditional)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessConditional)
        readIORef loads >>= (@?= 2)
    , testCase "subject and host both participate in the cache key" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache DecisionKey {subject = "user:bob", host = "tools.example.com"} load >>= (@?= AuthorizationDecision AccessAllowed)
        cacheLookupOrLoad cache DecisionKey {subject = "user:alice", host = "admin.example.com"} load >>= (@?= AuthorizationDecision AccessAllowed)
        readIORef loads >>= (@?= 3)
    , -- The core of the outage fix: an unreachable authorizer is returned to
      -- the caller but never written, so the next request retries instead of
      -- inheriting the outage for the rest of the TTL.
      testCase "an unavailable authorizer is not cached and is retried" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationUnavailable "en is down")
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationUnavailable "en is down")
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationUnavailable "en is down")
        readIORef loads >>= (@?= 2)
        cacheSize cache >>= (@?= 0)
    , -- The other half: a genuine denial IS still cached. Without this the
      -- previous test could pass by never caching anything.
      testCase "a genuine denial is still cached" $ do
        loads <- newIORef (0 :: Int)
        cache <- newDecisionCache 30 (pure 100)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessDenied)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
        cacheLookupOrLoad cache alice load >>= (@?= AuthorizationDecision AccessDenied)
        readIORef loads >>= (@?= 1)
        cacheSize cache >>= (@?= 1)
    , -- Eviction at the bound: expired entries go first, so a long-running
      -- process does not accumulate dead keys.
      testCase "reaching the bound evicts entries that expired in the meantime" $ do
        clock <- newIORef 100
        cache <- newBoundedDecisionCache 30 2 (readIORef clock)
        let load d = pure (AuthorizationDecision d)
        _ <- cacheLookupOrLoad cache alice (load AccessAllowed)
        _ <- cacheLookupOrLoad cache (keyFor "a.example.com") (load AccessAllowed)
        cacheSize cache >>= (@?= 2)
        writeIORef clock 200
        _ <- cacheLookupOrLoad cache (keyFor "b.example.com") (load AccessAllowed)
        cacheSize cache >>= (@?= 1)
    , -- The bound holds for live entries too: 2N distinct insertions into a
      -- cache bounded at N keep N, dropping the oldest, and a dropped key is
      -- simply a miss again. Inserts below the bound touch one key, not the
      -- whole map (the previous design filtered every entry on every write).
      testCase "live entries never exceed the bound; the oldest are dropped first" $ do
        clock <- newIORef 100
        loads <- newIORef (0 :: Int)
        let bound = 50
        -- A TTL longer than the run keeps every entry live, so only the bound evicts.
        cache <- newBoundedDecisionCache 1000 bound (readIORef clock)
        let load = modifyIORef' loads (+ 1) >> pure (AuthorizationDecision AccessAllowed)
        forM_ [1 .. 2 * bound] $ \n -> do
          writeIORef clock (100 + n)
          cacheLookupOrLoad cache (keyFor (Text.pack (show n) <> ".example.com")) load >>= (@?= AuthorizationDecision AccessAllowed)
        cacheSize cache >>= (@?= bound)
        readIORef loads >>= (@?= 2 * bound)
        -- The newest key is still served; the oldest is gone and reloads.
        cacheLookupOrLoad cache (keyFor (Text.pack (show (2 * bound)) <> ".example.com")) load >>= (@?= AuthorizationDecision AccessAllowed)
        readIORef loads >>= (@?= 2 * bound)
        cacheLookupOrLoad cache (keyFor "1.example.com") load >>= (@?= AuthorizationDecision AccessAllowed)
        readIORef loads >>= (@?= 2 * bound + 1)
        cacheSize cache >>= (@?= bound)
    ]
  where
    alice = DecisionKey {subject = "user:alice", host = "tools.example.com"}
    keyFor host = DecisionKey {subject = "user:alice", host = host}
