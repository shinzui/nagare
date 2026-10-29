-- | EP-224: the versioned record of what one nagarectl command spent, written
-- to @NAGARE_TRACE_FILE@ and read by the harness cost collector. It holds
-- names, counts, sizes and monotonic times only: never native bodies,
-- credentials, kubeconfig contents or raw arguments.
--
-- A span is one timed step with explicit labels (stage, operation, epoch,
-- attempt) and an explicit parent; nothing is attributed through a global
-- "current operation", so overlapping steps keep their own identities. Span
-- times are nanoseconds since the command started. Concurrent and nested
-- spans overlap, so wall time is the command's elapsed time, never a sum of
-- spans; 'uncoveredNanos' is the part of it no root span accounts for.
module Nagare.Contract.Trace
  ( traceSchemaVersion
  , TraceDocument (..)
  , TraceOutcome (..)
  , TraceSpan (..)
  , SpanLabels (..)
  , noLabels
  , SpanResult (..)
  , TraceCount (..)
  , CountCategory (..)
  , OperationCount (..)
  , OperationRecord (..)
  , decodeTraceDocument
  , uncoveredNanos
  , countsIn
  , operationTotal
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict', genericParseJSON, genericToJSON, withObject, (.:))
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Word (Word64)
import Nagare.Contract.Prelude
import Nagare.Contract.Schema (enumOptions, recordOptions)

traceSchemaVersion :: Int
traceSchemaVersion = 1

data TraceDocument = TraceDocument
  { schemaVersion :: !Int
  , command :: !Text
  -- ^ The command's name, e.g. @PlatformTransitionPlan@; never its arguments.
  , outcome :: !TraceOutcome
  , elapsedNanos :: !Word64
  , spans :: ![TraceSpan]
  , counts :: ![TraceCount]
  , operations :: ![OperationCount]
  }
  deriving stock (Eq, Show, Generic)

-- | How the command ended. A hard kill writes no document; a reader reports
-- the missing file as incomplete.
data TraceOutcome = OutcomeCompleted | OutcomeFailed | OutcomeCancelled
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

data TraceSpan = TraceSpan
  { spanId :: !Int
  , parent :: !(Maybe Int)
  , phase :: !Text
  , labels :: !SpanLabels
  , startNanos :: !Word64
  , endNanos :: !Word64
  , result :: !SpanResult
  }
  deriving stock (Eq, Show, Generic)

data SpanLabels = SpanLabels
  { stage :: !(Maybe Text)
  , operation :: !(Maybe Text)
  , epoch :: !(Maybe Text)
  , attempt :: !(Maybe Int)
  }
  deriving stock (Eq, Ord, Show, Generic)

noLabels :: SpanLabels
noLabels = SpanLabels Nothing Nothing Nothing Nothing

-- | A span whose action threw is recorded as such; its exception still
-- propagates unchanged.
data SpanResult = ResultSucceeded | ResultThrew
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | One counted kind of work: how often, how long in total (zero when
-- untimed) and how many bodies and bytes it moved.
data TraceCount = TraceCount
  { category :: !CountCategory
  , name :: !Text
  , count :: !Int
  , nanos :: !Word64
  , bodies :: !Int
  , bytes :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | Logical store work ('CategoryStore') is distinct from the HTTP requests
-- that carried it ('CategoryWire'). A Kubernetes read the command asked for
-- ('CategoryKubernetesLogical') is distinct from a request that left the
-- process ('CategoryKubernetesTransport') and from one answered by an earlier
-- read ('CategoryKubernetesReuse'). 'CategoryProcess' counts external
-- programs started; 'CategoryGuard' counts cluster guard admissions by verdict,
-- apart from the programs they start; 'CategoryRetry' counts repeated attempts.
data CountCategory
  = CategoryStore
  | CategoryWire
  | CategoryKubernetesLogical
  | CategoryKubernetesTransport
  | CategoryKubernetesReuse
  | CategoryProcess
  | CategoryGuard
  | CategoryRetry
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | Operations a review planned, and operations a transaction ran, by action
-- and executor, so the collector never decodes a review.
data OperationCount = OperationCount
  { recorded :: !OperationRecord
  , action :: !Text
  , executor :: !Text
  , count :: !Int
  }
  deriving stock (Eq, Show, Generic)

data OperationRecord = RecordPlanned | RecordExecuted
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | Decode a document, refusing any schema version this build does not know.
decodeTraceDocument :: ByteString -> Either Text TraceDocument
decodeTraceDocument = first T.pack . eitherDecodeStrict'

-- | Elapsed time that no root span covers. Root spans may overlap; their
-- union is subtracted once.
uncoveredNanos :: TraceDocument -> Word64
uncoveredNanos (TraceDocument _ _ _ elapsed traced _ _) = elapsed - min elapsed covered
  where
    roots = sortOn fst [(start, max start end) | TraceSpan _ Nothing _ _ start end _ <- traced]
    covered = sum [end - start | (start, end) <- merge roots]
    merge = \case
      (a, b) : (c, d) : rest | c <= b -> merge ((a, max b d) : rest)
      interval : rest -> interval : merge rest
      [] -> []

-- | The counts of one category, by name.
countsIn :: CountCategory -> TraceDocument -> [(Text, Int)]
countsIn selected (TraceDocument _ _ _ _ _ counted _) = [(name, n) | TraceCount category name n _ _ _ <- counted, category == selected]

-- | The planned or executed operations of one action, over all executors.
operationTotal :: OperationRecord -> Text -> TraceDocument -> Int
operationTotal kind selected (TraceDocument _ _ _ _ _ _ entries) =
  sum [n | OperationCount recorded action _ n <- entries, recorded == kind, action == selected]

instance ToJSON TraceDocument where toJSON = genericToJSON recordOptions

instance FromJSON TraceDocument where
  parseJSON value = do
    version <- withObject "trace" (.: "schemaVersion") value
    unless (version == traceSchemaVersion) (fail ("unsupported trace schema version " <> show version))
    genericParseJSON recordOptions value

instance ToJSON TraceOutcome where toJSON = genericToJSON (enumOptions "Outcome")

instance FromJSON TraceOutcome where parseJSON = genericParseJSON (enumOptions "Outcome")

instance ToJSON TraceSpan where toJSON = genericToJSON recordOptions

instance FromJSON TraceSpan where parseJSON = genericParseJSON recordOptions

instance ToJSON SpanLabels where toJSON = genericToJSON recordOptions

instance FromJSON SpanLabels where parseJSON = genericParseJSON recordOptions

instance ToJSON SpanResult where toJSON = genericToJSON (enumOptions "Result")

instance FromJSON SpanResult where parseJSON = genericParseJSON (enumOptions "Result")

instance ToJSON TraceCount where toJSON = genericToJSON recordOptions

instance FromJSON TraceCount where parseJSON = genericParseJSON recordOptions

instance ToJSON CountCategory where toJSON = genericToJSON (enumOptions "Category")

instance FromJSON CountCategory where parseJSON = genericParseJSON (enumOptions "Category")

instance ToJSON OperationCount where toJSON = genericToJSON recordOptions

instance FromJSON OperationCount where parseJSON = genericParseJSON recordOptions

instance ToJSON OperationRecord where toJSON = genericToJSON (enumOptions "Record")

instance FromJSON OperationRecord where parseJSON = genericParseJSON (enumOptions "Record")
