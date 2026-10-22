-- | One Shomei refresh per refresh token, however many requests carry it.
--
-- A page whose access token has just expired sends its document and its
-- subresources together, each with the same @nagare_refresh@ cookie. Shomei
-- rotates a refresh token once and treats a second use as theft: it revokes
-- the whole session. On the intranet every such burst signed the user out
-- (EP-211). So concurrent refreshes of one token share the first caller's
-- Shomei call, and for a short window after it succeeds a late request still
-- carrying the old token gets the pair already obtained instead of spending
-- the token again.
--
-- The enforcer runs as one replica and is the only holder of the refresh
-- cookie (ADR 15), so this in-process map sees every refresh of a browser
-- session. Only successes outlive their call: an unavailable or rejected
-- refresh is retried by the next request. Keys are the SHA-256 of the token,
-- and the map is bounded.
module Nagare.Access.RefreshCoalescer
  ( RefreshCoalescer
  , coalesceRefresh
  , coalescerSize
  , defaultRefreshReuseSeconds
  , newBoundedRefreshCoalescer
  , newRefreshCoalescer
  )
where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (onException)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Access.Auth (LoginOutcome (..), SessionTokens)
import Nagare.Access.Prelude

data RefreshCoalescer = RefreshCoalescer
  { reuseSeconds :: !Int
  , maxEntries :: !Int
  , nowSeconds :: !(IO Int)
  , entriesRef :: !(IORef (Map ByteString Entry))
  }
  deriving stock (Generic)

data Entry
  = InFlight !(MVar LoginOutcome)
  | Settled !Int !SessionTokens

data Claim
  = Reuse !SessionTokens
  | Join !(MVar LoginOutcome)
  | Lead !(MVar LoginOutcome)

-- | Long enough for a slow mobile link to deliver a page's subresource
-- requests, which leave before the document's @Set-Cookie@ arrives.
defaultRefreshReuseSeconds :: Int
defaultRefreshReuseSeconds = 30

-- | The clock must be monotonic, as for the decision cache.
newRefreshCoalescer :: Int -> IO Int -> IO RefreshCoalescer
newRefreshCoalescer reuse = newBoundedRefreshCoalescer reuse 10000

newBoundedRefreshCoalescer :: Int -> Int -> IO Int -> IO RefreshCoalescer
newBoundedRefreshCoalescer reuse bound now =
  RefreshCoalescer reuse bound now <$> newIORef Map.empty

-- | Refresh through the coalescer. The first caller for a token runs
-- @refresh@; callers that arrive while it runs wait for its outcome; callers
-- within the reuse window after a success get that success. An exception in
-- the leader reaches it alone: its waiters see 'LoginUnavailable', and the
-- entry is cleared so the next request tries again.
coalesceRefresh :: RefreshCoalescer -> (Text -> IO LoginOutcome) -> Text -> IO LoginOutcome
coalesceRefresh coalescer refresh token = do
  now <- coalescer ^. #nowSeconds
  fresh <- newEmptyMVar
  claim <- atomicModifyIORef' (coalescer ^. #entriesRef) (claimEntry coalescer now key fresh)
  case claim of
    Reuse tokens -> pure (LoginSucceeded tokens)
    Join pending -> readMVar pending
    Lead pending -> do
      outcome <-
        refresh token `onException` do
          putMVar pending (LoginUnavailable "refresh raised")
          atomicModifyIORef' (coalescer ^. #entriesRef) (\entries -> (Map.delete key entries, ()))
      settled <- coalescer ^. #nowSeconds
      atomicModifyIORef' (coalescer ^. #entriesRef) $ \entries ->
        ( case outcome of
            LoginSucceeded tokens -> Map.insert key (Settled settled tokens) entries
            _ -> Map.delete key entries
        , ()
        )
      putMVar pending outcome
      pure outcome
  where
    key = convert (hash (TE.encodeUtf8 token) :: Digest SHA256)

claimEntry :: RefreshCoalescer -> Int -> ByteString -> MVar LoginOutcome -> Map ByteString Entry -> (Map ByteString Entry, Claim)
claimEntry coalescer now key fresh entries =
  case Map.lookup key entries of
    Just (Settled at tokens)
      | now - at < coalescer ^. #reuseSeconds -> (entries, Reuse tokens)
    Just (InFlight pending) -> (entries, Join pending)
    _ -> (Map.insert key (InFlight fresh) (bounded entries), Lead fresh)
  where
    -- At the bound, drop settled entries past their window; in-flight ones
    -- always have a caller waiting.
    bounded current
      | Map.size current < coalescer ^. #maxEntries = current
      | otherwise = Map.filter live current
    live (InFlight _) = True
    live (Settled at _) = now - at < coalescer ^. #reuseSeconds

-- | How many tokens the coalescer currently tracks, for tests.
coalescerSize :: RefreshCoalescer -> IO Int
coalescerSize coalescer = Map.size <$> readIORef (coalescer ^. #entriesRef)
