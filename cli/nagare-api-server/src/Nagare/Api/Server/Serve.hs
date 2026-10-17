-- | The serving path of every admin API route (EP-197).
--
-- A state request reads one fresh checked head, then validates itself
-- against that head (cursor, filters, scope existence) before any scope is
-- hydrated. Its representation is cached by route, arguments and the revision
-- vector it depends on, so an unchanged list is answered from cached bytes
-- even while transactions churn the head; only immutable verified data is
-- reused, never the mutable head. The whole request runs under one deadline
-- covering the head read, hydration, projection and encoding.
module Nagare.Api.Server.Serve
  ( Env (..)
  , newEnv
  , Plan (..)
  , serveState
  , serveBuild
  , acceptedVector
  , headRevisionText
  , RequestStats (..)
  , beginRequest
  , endRequest
  )
where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Api.Response
import Nagare.Api.Server.Problems (storeProblem)
import Nagare.Api.Server.Validators (entityTag, noneMatch, stateValidators)
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails, internalError, problemFor, storeTimeout)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Recorded (RecordedHead, RecordedReader, readRecordedHead, recordedHeadManifest, recordedHeadRevision)
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision (..))
import Nagare.Resource.Types (digestText, generationNumber, scopeIdText)
import Servant.Server (Handler)
import System.Timeout (timeout)

-- | Everything a request needs. The reader owns the context-bound store
-- session and the immutable scope cache.
data Env = Env
  { reader :: !RecordedReader
  , build :: !Text
  , deadlineMicroseconds :: !Int
  , representations :: !(MVar Representations)
  , representationLimit :: !Int
  , requests :: !(IORef (Map ThreadId RequestStats))
  }

-- | What one request's handler did, for its access log line: whether its
-- representation came from the cache, and whether it ran out of time.
data RequestStats = RequestStats
  { cache :: !(Maybe Bool)
  , deadlineExceeded :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data Representations = Representations
  { entries :: !(Map Text (Text, LBS.ByteString))
  , order :: !(Seq Text)
  }

newEnv :: RecordedReader -> Text -> IO Env
newEnv recordedReader buildIdentity = do
  cached <- newMVar (Representations Map.empty Seq.empty)
  inFlight <- newIORef Map.empty
  pure
    Env
      { reader = recordedReader
      , build = buildIdentity
      , deadlineMicroseconds = 10000000
      , representations = cached
      , representationLimit = 512
      , requests = inFlight
      }

-- | Start recording the current request thread's statistics. Warp serves a
-- request and its handler on one thread.
beginRequest :: Env -> IO ()
beginRequest env = do
  thread <- myThreadId
  atomicModifyIORef' (requests env) (\table -> (Map.insert thread (RequestStats Nothing False) table, ()))

endRequest :: Env -> IO RequestStats
endRequest env = do
  thread <- myThreadId
  atomicModifyIORef' (requests env) (\table -> (Map.delete thread table, Map.findWithDefault (RequestStats Nothing False) thread table))

record :: Env -> (RequestStats -> RequestStats) -> IO ()
record env change = do
  thread <- myThreadId
  atomicModifyIORef' (requests env) (\table -> (Map.adjust change thread table, ()))

-- | A validated state request: the key of its representation and how to
-- build the representation when it is not cached.
data Plan a = Plan
  { key :: !Text
  , construct :: !(IO (Either ProblemDetails a))
  }

-- | Serve one state route. @planFor@ validates the request against the
-- checked head and must not hydrate scopes; @construct@ may.
serveState ::
  (ToJSON a) =>
  Env ->
  Maybe Text ->
  (RecordedHead -> Either ProblemDetails (Plan a)) ->
  Handler (SnapshotResult a)
serveState env match planFor = liftIO $ bounded env $ do
  checked <- readRecordedHead (reader env)
  case checked of
    Left failure -> pure (snapshotProblem (storeProblem failure))
    Right headValue -> case planFor headValue of
      Left problem -> pure (snapshotProblem problem)
      Right plan -> do
        representation <- cachedOr env (key plan) (fmap (fmap encode) (construct plan))
        pure $ case representation of
          Left problem -> snapshotProblem problem
          Right (tag, bytes)
            | noneMatch match tag -> SnapshotNotModified (SnapshotUnchanged (stateValidators tag) revision)
            | otherwise -> SnapshotOk (SnapshotBody (Encoded bytes) (stateValidators tag) revision)
            where
              revision = headRevisionText headValue

-- | Serve a representation of the serving build, which reads no store.
serveBuild :: Text -> LBS.ByteString -> Maybe Text -> Handler (BuildResult a)
serveBuild buildIdentity bytes match =
  pure $
    if noneMatch match tag
      then BuildNotModified (stateValidators tag)
      else BuildOk (BuildBody (Encoded bytes) (stateValidators tag))
  where
    tag = entityTag buildIdentity bytes

-- | The cached bytes and ETag under @key@, or build, encode and cache them.
-- A failure is never cached.
cachedOr :: Env -> Text -> IO (Either ProblemDetails LBS.ByteString) -> IO (Either ProblemDetails (Text, LBS.ByteString))
cachedOr env cacheKey produce = do
  found <- Map.lookup cacheKey . entries <$> readMVar (representations env)
  record env (\stats -> stats {cache = Just (isJust found)})
  case found of
    Just hit -> pure (Right hit)
    Nothing -> do
      produced <- produce
      case produced of
        Left problem -> pure (Left problem)
        Right bytes -> do
          -- Encoding is forced here, inside the request deadline.
          let strict = LBS.fromStrict (LBS.toStrict bytes)
              value = (entityTag (build env) strict, strict)
          modifyMVar_ (representations env) (pure . admit cacheKey value (representationLimit env))
          pure (Right value)

admit :: Text -> (Text, LBS.ByteString) -> Int -> Representations -> Representations
admit cacheKey value limitCount (Representations cached queue)
  | Map.member cacheKey cached = Representations cached queue
  | Seq.length queue >= limitCount
  , oldest Seq.:<| rest <- queue =
      Representations (Map.insert cacheKey value (Map.delete oldest cached)) (rest Seq.|> cacheKey)
  | otherwise = Representations (Map.insert cacheKey value cached) (queue Seq.|> cacheKey)

-- | Run a request under the deadline. A timeout is a retryable store
-- timeout; any other synchronous failure is a sanitized internal error.
-- Cancellation is never caught.
bounded :: Env -> IO (SnapshotResult a) -> IO (SnapshotResult a)
bounded env action = do
  outcome <- try (timeout (deadlineMicroseconds env) action)
  case outcome of
    Right (Just result) -> pure result
    Right Nothing -> record env (\stats -> stats {deadlineExceeded = True}) >> pure (snapshotProblem (problemFor storeTimeout "the inventory store did not answer within the request deadline"))
    Left (failure :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
      | otherwise -> pure (snapshotProblem (problemFor internalError "the request failed unexpectedly"))

-- | The opaque snapshot identity sent as @Nagare-Head-Revision@.
headRevisionText :: RecordedHead -> Text
headRevisionText = digestText . recordedHeadRevision

-- | The accepted and converged scope revisions of a head, as one key. A head
-- change that leaves them alone (a transaction, claim or fence) keeps it.
acceptedVector :: RecordedHead -> Text
acceptedVector checked =
  digestText (contentDigest (TE.encodeUtf8 (render "a" (headAccepted headValue) <> render "c" (headConverged headValue))))
  where
    headValue = recordedHeadManifest checked
    render tag revisions =
      Text.concat
        [ tag <> " " <> scopeIdText scope <> " " <> Text.pack (show (generationNumber (revisionGeneration revisionValue))) <> " " <> digestText (revisionDigest revisionValue) <> "\n"
        | (scope, revisionValue) <- Map.toAscList revisions
        ]
