-- | EP-224 M2: the cost record of a release run. @collect@ reads a run index
-- ("Nagare.Harness.Release.RunIndex") and the command traces it names
-- ("Nagare.Contract.Trace") and writes one record; @check@ judges a record
-- against its budgets; @history@ lists the records under a directory by
-- profile. A run with a missing or unreadable trace is incomplete, never
-- passing; a local rehearsal and the intranet are never compared.
module Nagare.Harness.TransitionCost
  ( costSchemaVersion
  , CostRecord (..)
  , StageCost (..)
  , Budget (..)
  , Verdict (..)
  , collectRun
  , collectTo
  , judge
  , checkRecord
  , historyLines
  , writeFixture
  , writeFixtureNow
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict', genericParseJSON, genericToJSON, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List (isPrefixOf, isSuffixOf, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Traversable (for)
import Data.Word (Word64)
import Nagare.Contract.Trace
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Records (writeSortedAtomically)
import Nagare.Harness.Release.RunIndex (Attempt (..), RunIndex, RunStatus (..), StageEntry (..), newRunIndex)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))

costSchemaVersion :: Int
costSchemaVersion = 1

data CostRecord = CostRecord
  { schemaVersion :: !Int
  , profile :: !Text
  , kind :: !Text
  , context :: !(Maybe Text)
  , candidateRevision :: !(Maybe Text)
  , sourceVersion :: !(Maybe Text)
  , runStatus :: !Text
  , missing :: ![FilePath]
  -- ^ Traces the index names that could not be read.
  , endToEndSeconds :: !Double
  -- ^ The run's start to its last index update, preparation included.
  , activationSeconds :: !Double
  -- ^ The traced plan and apply commands, summed: they run one after another.
  , stages :: ![StageCost]
  }
  deriving stock (Eq, Show, Generic)

data StageCost = StageCost
  { stageId :: !Text
  , planSeconds :: !(Maybe Double)
  , applySeconds :: !Double
  , outcomes :: ![Text]
  , planned :: !(Map Text Int)
  , executed :: !(Map Text Int)
  , kubernetesRequests :: !Int
  , kubernetesReuse :: !Int
  , storeRequests :: !Int
  , processes :: !Int
  , guardAdmissions :: !Int
  , uncoveredSeconds :: !Double
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CostRecord where toJSON = genericToJSON Aeson.defaultOptions

instance FromJSON CostRecord where
  parseJSON value = do
    version <- withObject "cost record" (.: "schemaVersion") value
    unless (version == costSchemaVersion) (fail ("unsupported cost record schema version " <> show version))
    genericParseJSON Aeson.defaultOptions value

instance ToJSON StageCost where toJSON = genericToJSON Aeson.defaultOptions

instance FromJSON StageCost where parseJSON = genericParseJSON Aeson.defaultOptions

-- | Collect the record of the run whose index is in @run@.
collectRun :: FilePath -> IO (Either Text CostRecord)
collectRun run = do
  located <- firstExisting [run </> "index.json", run </> "intranet-index.json", run </> "run" </> "index.json"]
  case located of
    Nothing -> pure (Left ("no run index in " <> T.pack run))
    Just path -> do
      decoded <- eitherDecodeStrict' <$> BS.readFile path
      case decoded of
        Left reason -> pure (Left ("run index " <> T.pack path <> ": " <> T.pack reason))
        Right (index :: RunIndex) -> Right <$> fromIndex (takeDirectory path) index
  where
    firstExisting = \case
      [] -> pure Nothing
      candidate : rest -> doesFileExist candidate >>= \found -> if found then pure (Just candidate) else firstExisting rest

-- | Collect the record of @ and write it to @.
collectTo :: FilePath -> FilePath -> IO (Either Text CostRecord)
collectTo run out = do
  collected <- collectRun run
  for_ collected (writeSortedAtomically out . toJSON)
  pure collected

fromIndex :: FilePath -> RunIndex -> IO CostRecord
fromIndex base index = do
  -- A stage the published source release ran has neither a summary nor a
  -- trace: it prepares the source context and is not measured.
  costed <- traverse stageCost [stage | stage <- index ^. #stages, isJust (stage ^. #trace) || isJust (stage ^. #summary)]
  let costs = map fst costed
      absent = concatMap snd costed
  pure
    CostRecord
      { schemaVersion = costSchemaVersion
      , profile = index ^. #profile
      , kind = index ^. #kind
      , context = index ^. #context
      , candidateRevision = index ^. #candidate . #revision
      , sourceVersion = index ^. #source . #version
      , runStatus = statusText (index ^. #status)
      , missing = absent
      , endToEndSeconds = seconds (index ^. #startedAt) (index ^. #updatedAt)
      , activationSeconds = sum [fromMaybe 0 (stage ^. #planSeconds) + stage ^. #applySeconds | stage <- costs]
      , stages = costs
      }
  where
    stageCost stage = do
      planTrace <- traverse load (stage ^. #trace)
      attemptTraces <- traverse (\attempt' -> traverse load (attempt' ^. #trace)) (stage ^. #attempts)
      let loaded = [document | Just (Right document) <- planTrace : attemptTraces]
          applied = [document | Just (Right document) <- attemptTraces]
          planDocument = [document | Just (Right document) <- [planTrace]]
          absent =
            [path | Just (Left path) <- planTrace : attemptTraces]
              <> [stage ^. #stageId <> "/plan" & T.unpack | isNothing (stage ^. #trace)]
              <> [T.unpack (attempt' ^. #attemptId) | attempt' <- stage ^. #attempts, isNothing (attempt' ^. #trace)]
          total category document = sum (map snd (countsIn category document))
          over category = sum (map (total category) loaded)
      pure
        ( StageCost
            { stageId = stage ^. #stageId
            , planSeconds = nanoSeconds . (^. #elapsedNanos) <$> listToMaybe planDocument
            , applySeconds = sum [nanoSeconds (document ^. #elapsedNanos) | document <- applied]
            , outcomes = [outcomeText (document ^. #outcome) | document <- loaded]
            , planned = operationsOf RecordPlanned planDocument
            , executed = operationsOf RecordExecuted applied
            , kubernetesRequests = over CategoryKubernetesTransport
            , kubernetesReuse = over CategoryKubernetesReuse
            , storeRequests = over CategoryWire
            , processes = over CategoryProcess
            , -- A session's reuse is not an admission (EP-226).
              guardAdmissions = sum [n | document <- loaded, (name, n) <- countsIn CategoryGuard document, name `elem` ["admitted", "renewed", "refused"]]
            , uncoveredSeconds = sum [nanoSeconds (uncoveredNanos document) | document <- loaded]
            }
        , absent
        )
    load relative = do
      let path = if take 1 relative == "/" then relative else base </> relative
      read' <- try @IOException (BS.readFile path)
      pure $ case read' of
        Right bytes | Right document <- decodeTraceDocument bytes -> Right document
        _ -> Left relative
    operationsOf kind' documents =
      Map.fromListWith (+) [(action', n) | document <- documents, OperationCount recorded action' _ n <- document ^. #operations, recorded == kind']

seconds :: UTCTime -> UTCTime -> Double
seconds from to = realToFrac (diffUTCTime to from)

nanoSeconds :: Word64 -> Double
nanoSeconds n = fromIntegral n / 1.0e9

statusText :: RunStatus -> Text
statusText = \case
  Running -> "running"
  Passed -> "passed"
  Failed -> "failed"

outcomeText :: TraceOutcome -> Text
outcomeText = \case
  OutcomeCompleted -> "completed"
  OutcomeFailed -> "failed"
  OutcomeCancelled -> "cancelled"

-- | One budget: its name, its limit, what the record shows and whether it holds.
data Budget = Budget
  { budget :: !Text
  , limit :: !Double
  , observed :: !Double
  , holds :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data Verdict = VerdictPassed | VerdictFailed | VerdictIncomplete
  deriving stock (Eq, Show)

-- | The verdict and the budgets behind it. Every stage plan finishes within
-- 60 s and the traced activation within 300 s (MasterPlan 30). A failed run
-- fails whatever it traced; otherwise one with a missing trace or still
-- running is incomplete, and one whose commands did not all complete fails.
judge :: CostRecord -> (Verdict, [Budget])
judge record = (verdict, budgets)
  where
    planLimit = 60
    budgets =
      [ Budget ("plan " <> stage ^. #stageId) planLimit taken (taken < planLimit)
      | stage <- record ^. #stages
      , Just taken <- [stage ^. #planSeconds]
      ]
        <> [Budget "activation" 300 (record ^. #activationSeconds) (record ^. #activationSeconds < 300)]
    commandsCompleted = all (all (== "completed") . (^. #outcomes)) (record ^. #stages)
    verdict
      | record ^. #runStatus == "failed" = VerdictFailed
      | record ^. #runStatus == "running" || not (null (record ^. #missing)) || null (record ^. #stages) = VerdictIncomplete
      | record ^. #runStatus /= "passed" || not commandsCompleted || not (all (^. #holds) budgets) = VerdictFailed
      | otherwise = VerdictPassed

-- | Decode a record file and judge it.
checkRecord :: FilePath -> IO (Either Text (Verdict, [Budget]))
checkRecord path = do
  decoded <- eitherDecodeStrict' <$> BS.readFile path
  pure (either (Left . T.pack) (Right . judge) decoded)

-- | One line per cost record under @root@ (two levels deep), grouped by
-- profile. A record of an unknown schema refuses the listing.
historyLines :: FilePath -> IO (Either Text [Text])
historyLines root = do
  revisions <- listDirectory root
  paths <-
    concat
      <$> for
        revisions
        ( \revision -> do
            let directory = root </> revision
            isDirectory <- doesDirectoryExist directory
            if not isDirectory
              then pure []
              else filter (costFile . takeFileName) . map (directory </>) <$> listDirectory directory
        )
  decoded <- for paths $ \path -> (\bytes -> (path,) <$> eitherDecodeStrict' bytes) <$> BS.readFile path
  pure $ case sequence [either (\reason -> Left (T.pack path <> ": " <> T.pack reason)) Right result | (path, result) <- zip paths (map (fmap snd) decoded)] of
    Left reason -> Left reason
    Right records ->
      Right
        [ line path record
        | (path, record) <- sortOn (\(path, record) -> (record ^. #profile, path)) (zip paths records)
        ]
  where
    -- One record per file; a release's warm samples are numbered
    -- (transition-cost-1.json and on, EP-224 M3).
    costFile name = any (`isPrefixOf` name) ["transition-cost", "intranet-cost"] && ".json" `isSuffixOf` name
    line path record =
      let (verdict, _) = judge record
       in T.intercalate
            "  "
            [ record ^. #profile
            , verdictText verdict
            , T.pack (show (length (record ^. #stages))) <> " stages"
            , "activation " <> secondsText (record ^. #activationSeconds)
            , "end-to-end " <> secondsText (record ^. #endToEndSeconds)
            , T.pack path
            ]
    secondsText value = T.pack (show (fromIntegral (round (value * 10) :: Integer) / 10 :: Double)) <> " s"

verdictText :: Verdict -> Text
verdictText = \case
  VerdictPassed -> "passed"
  VerdictFailed -> "failed"
  VerdictIncomplete -> "incomplete"

-- | 'writeFixture' stamped now.
writeFixtureNow :: FilePath -> IO (Either Text ())
writeFixtureNow directory = getCurrentTime >>= writeFixture directory

-- | A sanitized two-stage run for the collector's examples: an index and the
-- traces it names. It is synthetic and never native evidence.
writeFixture :: FilePath -> UTCTime -> IO (Either Text ())
writeFixture directory at' = do
  exists <- doesDirectoryExist directory
  present <- if exists then listDirectory directory else pure []
  if not (null present)
    then pure (Left ("refusing to write a fixture into the non-empty " <> T.pack directory))
    else do
      let stage n operations' trace' attempts' = StageEntry ("transition-" <> T.pack (show n)) "transition" n ("reviews/transition-" <> show n) ("reviews/transition-" <> show n <> ".plan.log") Nothing operations' 0 (null attempts') at' attempts' (Just trace')
          attempt = Attempt "transition-1/apply" "apply" (Just "tx-fixture") "converged" "reviews/transition-1.apply.log" Nothing at' at' (Just "reviews/transition-1.apply.trace.json")
          index =
            newRunIndex "drill" "local-rehearsal" at'
              & #status
              .~ Passed
              & #stages
              .~ [stage (1 :: Int) 1 "reviews/transition-1.plan.trace.json" [attempt], stage 2 0 "reviews/transition-2.plan.trace.json" []]
          document command elapsed operations' = TraceDocument traceSchemaVersion command OutcomeCompleted elapsed [TraceSpan 0 Nothing "stage planning" noLabels 0 elapsed ResultSucceeded] [TraceCount CategoryKubernetesTransport "get configmap" 4 elapsed 0 0] operations'
      createDirectoryIfMissing True (directory </> "run" </> "reviews")
      writeSortedAtomically (directory </> "run" </> "index.json") (toJSON index)
      writeSortedAtomically (directory </> "run" </> "reviews/transition-1.plan.trace.json") (toJSON (document "PlatformTransitionPlan" 12000000000 [OperationCount RecordPlanned "UpdateResource" "KubernetesExecutor" 1, OperationCount RecordPlanned "ValidateResource" "KubernetesExecutor" 205]))
      writeSortedAtomically (directory </> "run" </> "reviews/transition-1.apply.trace.json") (toJSON (document "InventoryApply" 30000000000 [OperationCount RecordExecuted "UpdateResource" "KubernetesExecutor" 1, OperationCount RecordExecuted "ValidateResource" "KubernetesExecutor" 205]))
      writeSortedAtomically (directory </> "run" </> "reviews/transition-2.plan.trace.json") (toJSON (document "PlatformTransitionPlan" 8000000000 []))
      pure (Right ())
