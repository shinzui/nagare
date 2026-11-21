-- | Rehearse the reviewed release transition of a local context (EP-172 M3,
-- ported by EP-229), from a published source release to the candidate, on a
-- disposable Docker daemon; seed a database row before the move and read it
-- back unchanged after it. Every step stops at its first refusal.
--
-- The source release bootstraps the context with @platform bootstrap plan@
-- and @platform bootstrap apply@; the candidate moves it with
-- @transition plan@ and @inventory apply@, then @platform transition commit@
-- pins it, and a candidate bootstrap replan must be converged. The seeded
-- row lives in the @transition_sentinel@ table.
--
-- Its inputs are environment variables, as the script's were:
-- @NAGARE_REHEARSAL_SOURCE@, @NAGARE_REHEARSAL_TARGET@, @DOCKER_HOST@ and
-- @NAGARE_REHEARSAL_IMAGES@, the candidate's
-- @scripts/publish-local-minio-images.sh@ (required), @NAGARE_REHEARSAL_ROOT@,
-- @NAGARE_REHEARSAL_CONTEXT@ and @NAGARE_REHEARSAL_SKIP_BOOTSTRAP@. The
-- daemon must hold no k3d cluster and no registry forward: the drill never
-- deletes anything it did not create (MasterPlan 37 D3).
module Nagare.Harness.Release.TransitionDrill
  ( transitionDrill
  , drillEnvironment
  , localImagePins
  )
where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isDigit, isHexDigit, isUpper)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime)
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import Nagare.Harness.Release.Review
import Nagare.Harness.Release.RunIndex
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (dropExtension, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (setFileCreationMask)

data Drill = Drill
  { runtime :: !Runtime
  , root :: !FilePath
  , context :: !String
  , source :: !FilePath
  , target :: !FilePath
  , images :: !FilePath
  , environment :: !(IORef [(String, String)])
  , index :: !IndexWriter
  }
  deriving stock (Generic)

-- | The two releases a loop runs on.
data Release = Source | Target
  deriving stock (Eq, Show, Generic)

-- | One reviewed loop: its label, plan and apply words, and what counts.
data Loop = Loop
  { label :: !String
  , release :: !Release
  , plan :: ![String]
  , apply :: ![String]
  , counting :: !Counting
  }
  deriving stock (Eq, Show, Generic)

data LoopResult = LoopResult
  { reviews :: !Int
  , operations :: !Int
  }
  deriving stock (Eq, Show, Generic)

stagesMax :: Int
stagesMax = 12

-- | The candidate transition's whole-rollout deadline, in seconds (EP-228 M3).
rolloutDeadline :: Int
rolloutDeadline = 600

namespace :: String
namespace = "personal"

database :: String
database = "rehearsal"

-- | The pins @scripts/publish-local-minio-images.sh@ prints: only the local
-- object store's images, which no release names. Both releases run the
-- service images their release.json names (EP-237; the rehearsal refuses a
-- release that names none), so a pin here can never stand in for one: the
-- v0.22.0 rehearsal's pinned En 9577009 predated tenant mode and crash-looped
-- the 0.21.0 source.
localImagePins :: Text -> [(String, String)]
localImagePins printed =
  [ (T.unpack name, T.unpack (T.drop 1 value))
  | line <- T.lines printed
  , let (name, value) = T.breakOn "=" (T.strip line)
  , name `elem` ["NAGARE_LOCAL_MINIO_IMAGE", "NAGARE_LOCAL_MC_IMAGE"]
  , T.length value > 1
  ]

-- | The ambient shell may carry a context, a payload root and a kubeconfig;
-- the drill uses only its own root and each nagarectl's packaged payload.
drillEnvironment :: FilePath -> [(String, String)] -> [(String, String)]
drillEnvironment root' ambient =
  [entry | entry@(name, _) <- ambient, not (scrubbed name), name `notElem` ["XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]]
    <> [("XDG_CONFIG_HOME", root' </> "config"), ("XDG_STATE_HOME", root' </> "state"), ("XDG_CACHE_HOME", root' </> "cache")]
  where
    scrubbed name =
      not ("NAGARE_REHEARSAL_" `isPrefix` name)
        && (any (\prefix -> maybe False (all upperOrUnderscore) (strip prefix name)) ["NAGARE_", "CLOUDSDK_", "PULUMI_"] || name `elem` ["KUBECONFIG", "SOPS_AGE_KEY_FILE"])
    upperOrUnderscore c = isUpper c || c == '_'
    isPrefix prefix name = take (length prefix) name == prefix
    strip prefix name = if isPrefix prefix name then Just (drop (length prefix) name) else Nothing

say' :: Drill -> Text -> IO ()
say' drill message = do
  moment <- drill ^. #runtime . #now
  (drill ^. #runtime . #say) (stampedLine "%H:%M:%S" moment "rehearsal" message)

setVariable :: Drill -> String -> String -> IO ()
setVariable drill name value = modifyIORef' (drill ^. #environment) (\entries -> [entry | entry@(key, _) <- entries, key /= name] <> [(name, value)])

-- | An invocation with the drill's current environment.
command :: Drill -> FilePath -> [String] -> IO Invocation
command drill program' arguments' = do
  entries <- readIORef (drill ^. #environment)
  pure (invocation program' arguments' & #environment .~ Exactly entries)

nagarectl :: Drill -> Release -> [String] -> IO Invocation
nagarectl drill which arguments' = command drill (binary drill which) (["--context", drill ^. #context] <> arguments')

binary :: Drill -> Release -> FilePath
binary drill = \case
  Source -> drill ^. #source
  Target -> drill ^. #target

run' :: Drill -> Invocation -> IO Result
run' drill = invoke (drill ^. #runtime)

ok :: Drill -> Text -> Invocation -> IO ()
ok drill = require (drill ^. #runtime)

text :: Drill -> Text -> Invocation -> IO Text
text drill = captureText (drill ^. #runtime)

-- | The last line of a command's stdout, as @| tail -1@ prints it.
lastLine :: Drill -> Text -> Invocation -> IO ()
lastLine drill message invocation' = do
  out <- text drill message invocation'
  (drill ^. #runtime . #say) (lastLines 1 out)

lenient :: BS.ByteString -> Text
lenient = TE.decodeUtf8With TE.lenientDecode

readLenient :: FilePath -> IO Text
readLenient path = lenient <$> BS.readFile path

showText :: Int -> Text
showText = T.pack . show

transitionDrill :: Runtime -> IO ()
transitionDrill runtime' = do
  let required name reason = maybe (refuse (T.pack name <> ": " <> reason)) pure (lookupVariable runtime' name)
      optional' name = lookupVariable runtime' name
  sourceCli <- required "NAGARE_REHEARSAL_SOURCE" "the source release nagarectl, a nix output bin/nagarectl"
  targetCli <- required "NAGARE_REHEARSAL_TARGET" "the candidate nagarectl, a nix output bin/nagarectl"
  _ <- required "DOCKER_HOST" "an empty Docker daemon; release-rehearse creates one"
  imagesScript <- required "NAGARE_REHEARSAL_IMAGES" "scripts/publish-local-minio-images.sh of the candidate"
  root' <- maybe (T.unpack <$> captureText runtime' "mktemp failed" (invocation "mktemp" ["-d", "/private/tmp/nagare-transition.XXXXXX"])) pure (optional' "NAGARE_REHEARSAL_ROOT")
  started <- runtime' ^. #now
  let context' = fromMaybe "transition" (optional' "NAGARE_REHEARSAL_CONTEXT")
      sentinel = "transition " <> T.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" started)
  environment' <- newIORef (drillEnvironment root' (runtime' ^. #variables))
  forM_ ["config", "state", "cache", "reviews", "evidence", "sops/age"] (createDirectoryIfMissing True . (root' </>))
  index' <- openIndex runtime' (root' </> "index.json") (newRunIndex "drill" "local-rehearsal" started & #context ?~ T.pack context')
  let drill = Drill {runtime = runtime', root = root', context = context', source = sourceCli, target = targetCli, images = imagesScript, environment = environment', index = index'}
  withRunIndex index' (runDrill drill sentinel)

runDrill :: Drill -> Text -> IO ()
runDrill drill sentinel = do
  let runtime' = drill ^. #runtime
      root' = drill ^. #root
      context' = drill ^. #context
      sourceCli = drill ^. #source
      targetCli = drill ^. #target
      optional' = lookupVariable runtime'
  ok drill "chmod failed" =<< command drill "chmod" ["700", root', root' </> "sops", root' </> "sops/age"]
  let keyFile = root' </> "sops/age/keys.txt"
  bootstrapReviews <-
    if optional' "NAGARE_REHEARSAL_SKIP_BOOTSTRAP" == Just "1"
      then do
        -- Continue from a root whose context is already bootstrapped on the
        -- source release.
        setVariable drill "SOPS_AGE_KEY_FILE" keyFile
        pins <- readLenient (root' </> "images.env")
        forM_ (T.lines pins) $ \line -> case T.breakOn "=" line of
          (name, value) | not (T.null value) -> setVariable drill (T.unpack name) (T.unpack (T.drop 1 value))
          _ -> pure ()
        forward drill
        say' drill ("continuing in " <> T.pack root' <> " on the bootstrapped context " <> T.pack context')
        pure Nothing
      else Just <$> bootstrap drill keyFile
  -- 5. seed a database row on the source release
  setVariable drill "KUBECONFIG" (root' </> "config/nagare/kubeconfigs" </> (context' <> ".yaml"))
  present <- run' drill . (\i -> i & #stdoutTo .~ Discard & #stderrTo .~ Discard) =<< command drill "kubectl" ["-n", namespace, "get", "statefulset", database]
  unless (present ^. #exit == 0) $
    lastLine drill "db create failed" =<< nagarectl drill Source ["db", "create", "postgres", database, "-n", namespace, "--recovery-backup", "postgres-backup", "--recovery-key-version", "v1"]
  let secret key = do
        encoded <- text drill ("the " <> T.pack key <> " of nagare-db-" <> T.pack database <> " is unreadable") =<< command drill "kubectl" ["-n", namespace, "get", "secret", "nagare-db-" <> database, "-o", "jsonpath={.data." <> key <> "}"]
        either (\reason -> refuse ("nagare-db-" <> T.pack database <> " " <> T.pack key <> ": " <> T.pack reason)) (pure . T.unpack . lenient) (Base64.decode (TE.encodeUtf8 encoded))
  pgUser <- secret "POSTGRES_USER"
  pgPassword <- secret "POSTGRES_PASSWORD"
  pgDatabase <- secret "POSTGRES_DB"
  let waitReady :: Int -> IO ()
      waitReady n = when (n <= 60) $ do
        ready <- run' drill . (\i -> i & #stdoutTo .~ Discard & #stderrTo .~ Discard) =<< command drill "kubectl" ["-n", namespace, "exec", database <> "-0", "--", "pg_isready", "-h", "127.0.0.1", "-U", pgUser, "-d", pgDatabase]
        unless (ready ^. #exit == 0) ((runtime' ^. #pause) 2 >> waitReady (n + 1))
      psql sql = text drill "psql in the database pod failed" =<< command drill "kubectl" ["-n", namespace, "exec", database <> "-0", "--", "env", "PGPASSWORD=" <> pgPassword, "psql", "-h", "127.0.0.1", "-U", pgUser, "-d", pgDatabase, "-tAc", sql]
  waitReady 1
  _ <- psql ("CREATE TABLE IF NOT EXISTS transition_sentinel(v text); TRUNCATE transition_sentinel; INSERT INTO transition_sentinel VALUES ('" <> T.unpack sentinel <> "');")
  seeded <- psql "SELECT v FROM transition_sentinel;"
  say' drill ("seeded: " <> seeded)
  -- 6. the transition on the candidate, then the pin
  moved <- reviewedLoop drill (Loop "transition" Target ["transition", "plan"] ["inventory", "apply"] AllOperations)
  lastLine drill "transition commit failed" =<< nagarectl drill Target ["platform", "transition", "commit", "--yes"]
  -- 7. read back on the candidate
  ok drill "platform status failed" . (\i -> i & #stdoutTo .~ WriteTo (root' </> "evidence/after-platform.json")) =<< nagarectl drill Target ["platform", "status", "--json"]
  ok drill "inventory status failed" . (\i -> i & #stdoutTo .~ WriteTo (root' </> "evidence/after-status.json")) =<< nagarectl drill Target ["inventory", "status", "--json"]
  readBack' <- psql "SELECT v FROM transition_sentinel;"
  unless (readBack' == sentinel) (refuse ("sentinel differs after the transition: " <> readBack'))
  let replan = root' </> "reviews/replan"
  ok drill "the candidate's bootstrap replan failed" . (\i -> i & #stdoutTo .~ WriteTo (replan <> ".plan.log") & #stderrTo .~ SameAsStdout) =<< nagarectl drill Target ["platform", "bootstrap", "plan", "--out", replan]
  replanned <- readReviewCounts replan >>= either refuse pure
  unless (isConverged AllOperations replanned) (refuse "replan on the candidate has operations or re-accepts a scope")
  -- The record a release binds (published beside its notes): what moved from where, the seeded row and what
  -- read back, the final platform status, the idle inventory and the
  -- converged replan.
  sourceIdentity <- capture runtime' "the source nagarectl has no version" =<< command drill sourceCli ["version", "--json"]
  targetIdentity <- capture runtime' "the candidate nagarectl has no version" =<< command drill targetCli ["version", "--json"]
  platform <- readDocument @Value (root' </> "evidence/after-platform.json") >>= either refuse pure
  status <- readDocument @Value (root' </> "evidence/after-status.json") >>= either refuse pure
  let identity raw = object [Key.fromText key .= field (decodeDocument @Value "version --json" raw) key | key <- ["version", "revision"]]
      field decoded key = case decoded of
        Right (Object fields) -> fromMaybe Null (KeyMap.lookup (Key.fromText key) fields)
        _ -> Null
  writeSorted
    False
    (root' </> "evidence/transition-rehearsal.json")
    ( object
        [ "schemaVersion" .= (1 :: Int)
        , "mode" .= ("local" :: Text)
        , "context" .= T.pack context'
        , "source" .= identity sourceIdentity
        , "candidate" .= identity targetIdentity
        , "bootstrap" .= object ["reviews" .= bootstrapReviews]
        , "transition" .= object ["reviews" .= (moved ^. #reviews), "operations" .= (moved ^. #operations)]
        , "sentinel" .= object ["seeded" .= sentinel, "readBack" .= readBack']
        , "platform" .= platform
        , "inventory" .= object [Key.fromText key .= field (Right status) key | key <- ["activeTransaction", "transactionStatus", "observationComplete"]]
        , "replan" .= object ["operations" .= (0 :: Int), "reaccepts" .= (0 :: Int)]
        ]
    )
  let revisioned raw = case decodeDocument @ReleaseIdentity "version --json" raw of
        Right found -> Revisioned (found ^. #version) (found ^. #revision)
        Left _ -> Revisioned Nothing Nothing
  updateIndex (drill ^. #index) ((#candidate .~ revisioned targetIdentity) . (#source .~ revisioned sourceIdentity))
  setRecord (drill ^. #index) "transitionRehearsal" (root' </> "evidence/transition-rehearsal.json")
  say' drill ("transition rehearsal OK: record in " <> T.pack (root' </> "evidence/transition-rehearsal.json"))

-- | Steps 0 to 4: an empty disposable daemon, the context's secrets, the
-- context on the source release and its bootstrap. Returns the number of
-- bootstrap reviews applied.
bootstrap :: Drill -> FilePath -> IO Int
bootstrap drill keyFile = do
  let root' = drill ^. #root
      runtime' = drill ^. #runtime
  -- 0. the daemon is empty of k3d: the drill deletes nothing it did not make
  names <- text drill "docker ps failed" =<< command drill "docker" ["ps", "-a", "--format", "{{.Names}}"]
  when (any (\name -> "k3d-" `T.isPrefixOf` name || name == "registry-forward") (T.lines names)) $
    refuse "the daemon already holds a k3d cluster or registry forward; rehearse on an empty daemon (release-rehearse creates one)"
  architecture <- text drill "docker info failed" =<< command drill "docker" ["info", "--format", "{{.Architecture}}"]
  platform <- case T.strip architecture of
    arch | arch `elem` ["aarch64", "arm64"] -> pure "linux/arm64"
    arch | arch `elem` ["x86_64", "amd64"] -> pure "linux/amd64"
    arch -> refuse ("the daemon runs " <> arch <> "; a rehearsal needs linux/arm64 or linux/amd64")
  sourceVersion <- text drill "the source nagarectl has no version" =<< command drill (drill ^. #source) ["version"]
  targetVersion <- text drill "the candidate nagarectl has no version" =<< command drill (drill ^. #target) ["version"]
  say' drill ("root " <> T.pack root' <> "; source " <> firstLine sourceVersion <> "; target " <> firstLine targetVersion)
  -- 1. context-owned observability secrets, encrypted to a fresh age key
  setVariable drill "SOPS_AGE_KEY_FILE" keyFile
  restricted (run' drill . quiet =<< command drill "age-keygen" ["-o", keyFile]) >>= \result ->
    unless (result ^. #exit == 0) (refuse "age-keygen failed")
  recipient <- text drill "age-keygen -y failed" =<< command drill "age-keygen" ["-y", keyFile]
  let secrets = root' </> "config/nagare/cluster-secrets" </> drill ^. #context
  createDirectoryIfMissing True secrets
  BS.writeFile (secrets </> ".sops.yaml") (TE.encodeUtf8 ("creation_rules:\n  - age: " <> recipient <> "\n"))
  password <- randomPassword
  restricted $
    BS.writeFile
      (secrets </> "grafana-admin.yaml")
      (TE.encodeUtf8 ("apiVersion: v1\nkind: Secret\nmetadata:\n  name: grafana-admin\n  namespace: monitoring\nstringData:\n  admin-user: admin\n  admin-password: " <> password <> "\n"))
  ok drill "sops could not encrypt the grafana secret" =<< command drill "sops" ["--config", secrets </> ".sops.yaml", "--encrypt", "--in-place", secrets </> "grafana-admin.yaml"]
  -- 2. the context on the source release
  lastLine drill "context create failed"
    =<< nagarectl
      drill
      Source
      ["context", "create", drill ^. #context, "--mode", "local", "--registry-host", "k3d-registry.localhost:5000", "--base-domain", "127-0-0-1.sslip.io", "--target-platform", platform, "--local-object-store", "http://minio.nagare-system.svc.cluster.local:9000/nagare-backups", "--use"]
  rootDocument <- capture runtime' "platform root failed" =<< nagarectl drill Source ["platform", "root", "--json"]
  let payloadVersion = either (const Nothing) (^. #platformVersion) (decodeDocument @PlatformRoot "platform root --json" rootDocument)
  ownVersion <- capture runtime' "the source nagarectl has no version" =<< command drill (drill ^. #source) ["version", "--json"]
  let own = either (const Nothing) (^. #version) (decodeDocument @ReleaseIdentity "version --json" ownVersion)
  unless (isJust payloadVersion && payloadVersion == own) (refuse ("the source nagarectl resolved payload " <> fromMaybe "None" payloadVersion <> ", not its own release"))
  say' drill ("source payload " <> fromMaybe "None" payloadVersion)
  result <- reviewedLoopWith drill (Loop "bootstrap" Source ["bootstrap", "plan"] ["platform", "bootstrap", "apply"] MutatingOperations) (seedOnce drill)
  ok drill "inventory status failed" . (\i -> i & #stdoutTo .~ WriteTo (root' </> "evidence/before-status.json")) =<< nagarectl drill Source ["inventory", "status", "--json"]
  pure (result ^. #reviews)
  where
    quiet i = i & #stdoutTo .~ Discard & #stderrTo .~ Discard
    firstLine = T.takeWhile (/= '\n')

-- | Run an action with the file-creation mask 077, as @(umask 077; …)@.
restricted :: IO a -> IO a
restricted action = bracket (setFileCreationMask 0o077) setFileCreationMask (const action)

-- | Twenty-four random bytes in base64 without @/+=@, as the script's
-- @head -c 24 /dev/urandom | base64 | tr -d '/+='@.
randomPassword :: IO Text
randomPassword = do
  bytes <- withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 24)
  pure (T.filter (`notElem` ("/+=" :: String)) (lenient (Base64.encode bytes)))

reviewedLoop :: Drill -> Loop -> IO LoopResult
reviewedLoop drill loop = reviewedLoopWith drill loop (pure ())

-- | Plan and apply until a review is converged; @afterApply@ runs after each
-- applied stage.
reviewedLoopWith :: Drill -> Loop -> IO () -> IO LoopResult
reviewedLoopWith drill loop afterApply = do
  started <- drill ^. #runtime . #now
  go started Nothing 1 (LoopResult 0 0)
  where
    go started previous n acc
      | n > stagesMax = refuse (T.pack (loop ^. #label) <> " did not converge in " <> showText stagesMax <> " stages")
      | otherwise = do
          -- EP-228 M3: the candidate's transition has a whole-rollout
          -- deadline, checked before each new stage; the run stops between
          -- stages, where planning again continues it.
          now <- drill ^. #runtime . #now
          when (loop ^. #release == Target && loop ^. #label == "transition" && n > 1 && diffUTCTime now started > fromIntegral rolloutDeadline) $
            refuse ("the transition exceeded its " <> showText rolloutDeadline <> " s deadline before stage " <> showText n <> "; its reviews are in " <> T.pack (drill ^. #root </> "reviews"))
          let review = drill ^. #root </> "reviews" </> (loop ^. #label <> "-" <> show n)
              planLog = review <> ".plan.log"
              applyLog = review <> ".apply.log"
              summaryFile = review <> ".summary.json"
              planTrace = review <> ".plan.trace.json"
              typed = loop ^. #release == Target
              -- EP-224: only the candidate writes a command trace.
              tracing path = if typed then withVariable "NAGARE_TRACE_FILE" path else id
              stage = T.pack (loop ^. #label) <> "-" <> showText n
              index = drill ^. #index
          planned <-
            run' drill . (\i -> tracing planTrace i & #stdoutTo .~ WriteTo planLog & #stderrTo .~ SameAsStdout)
              =<< nagarectl drill (loop ^. #release) (["platform"] <> loop ^. #plan <> ["--out", review] <> (if typed then ["--summary", summaryFile] else []))
          unless (planned ^. #exit == 0) $ do
            logged <- readLenient planLog
            refuse (T.pack (loop ^. #label) <> " plan " <> showText n <> " refused: " <> lastLines 2 logged)
          -- The candidate summarises its own review; a published source
          -- release cannot, so its review is decoded here.
          counts <-
            if typed
              then summaryCounts <$> (readPlanSummary summaryFile >>= either refuse pure)
              else readReviewCounts review >>= either refuse pure
          let operations' = operationCount (loop ^. #counting) counts
              done = isConverged (loop ^. #counting) counts
          -- EP-228 M3: a stage that plans what the stage before it planned,
          -- after that stage applied, makes no progress: stop and name it.
          work <- readReviewWork review >>= either refuse pure
          when (not done && previous == Just work) $
            refuse (noProgress (T.pack (loop ^. #label)) n work)
          plannedAt' <- drill ^. #runtime . #now
          addStage index (StageEntry stage (T.pack (loop ^. #label)) n (relativeIn index review) (relativeIn index planLog) (if typed then Just (relativeIn index summaryFile) else Nothing) operations' (counts ^. #reaccepted) done plannedAt' [] (if typed then Just (relativeIn index planTrace) else Nothing))
          say' drill (T.pack (loop ^. #label) <> " stage " <> showText n <> ": " <> showText operations' <> " operations, re-accepts scopes: " <> showText (counts ^. #reaccepted))
          if done
            then pure acc
            else do
              applied <-
                if typed
                  then applyTyped drill stage loop review applyLog
                  else applyText drill stage loop review applyLog
              unless applied $ do
                logged <- readLenient applyLog
                refuse (T.pack (loop ^. #label) <> " apply " <> showText n <> " failed: " <> lastLines 3 logged)
              when (loop ^. #label == "bootstrap") afterApply
              go started (Just work) (n + 1) (LoopResult (acc ^. #reviews + 1) (acc ^. #operations + operations'))

-- | Index one apply or resume of a stage.
indexAttempt :: Drill -> Text -> Text -> Maybe Text -> Text -> FilePath -> Maybe FilePath -> UTCTime -> IO ()
indexAttempt drill stage action' transaction' outcome' logFile' document' started = do
  -- A typed attempt's trace sits beside its outcome document.
  let trace' = (\document -> dropExtension document <> ".trace.json") <$> document'
  finished' <- drill ^. #runtime . #now
  let index = drill ^. #index
  addAttempt index stage (Attempt (stage <> "/" <> action') action' transaction' outcome' (relativeIn index logFile') (relativeIn index <$> document') started finished' (relativeIn index <$> trace'))

-- | The candidate's apply under @--contract 1@: an ambiguous stop (an effect
-- the provider did not acknowledge in time) is resumed, as the operator
-- would, until it converges; anything else is a stop.
applyTyped :: Drill -> Text -> Loop -> FilePath -> FilePath -> IO Bool
applyTyped drill stage loop review applyLog = do
  started <- drill ^. #runtime . #now
  let document' = review <> ".apply.json"
  _ <- run' drill . (\i -> withVariable "NAGARE_TRACE_FILE" (dropExtension document' <> ".trace.json") i & #stdoutTo .~ WriteTo document' & #stderrTo .~ WriteTo applyLog) =<< nagarectl drill (loop ^. #release) (loop ^. #apply <> [review, "--yes", "--contract", "1"])
  (outcome', transaction', name') <- readApplyOutcome document'
  indexAttempt drill stage "apply" transaction' name' applyLog (Just document') started
  case outcome' of
    AppliedConverged -> pure True
    AppliedAmbiguous transaction -> go transaction (1 :: Int)
    AppliedStopped _ -> pure False
  where
    go transaction n
      | n > 12 = pure False
      | otherwise = do
          (drill ^. #runtime . #pause) 20
          say' drill ("resume " <> T.pack (show n) <> " of " <> transaction)
          started <- drill ^. #runtime . #now
          let document' = review <> ".resume-" <> show n <> ".json"
          _ <- run' drill . (\i -> withVariable "NAGARE_TRACE_FILE" (dropExtension document' <> ".trace.json") i & #stdoutTo .~ WriteTo document' & #stderrTo .~ AppendTo applyLog) =<< nagarectl drill (loop ^. #release) ["inventory", "resume", T.unpack transaction, "--yes", "--contract", "1"]
          (outcome', transaction', name') <- readApplyOutcome document'
          indexAttempt drill stage ("resume-" <> showText n) transaction' name' applyLog (Just document') started
          case outcome' of
            AppliedConverged -> pure True
            AppliedAmbiguous again | again == transaction -> go transaction (n + 1)
            _ -> pure False

-- | The source release's bootstrap apply, which prints no outcome
-- document: its human @ambiguous TX at OP@ stop line is the only signal a
-- published release gives.
applyText :: Drill -> Text -> Loop -> FilePath -> FilePath -> IO Bool
applyText drill stage loop review applyLog = do
  started <- drill ^. #runtime . #now
  applied <- run' drill . (\i -> i & #stdoutTo .~ WriteTo applyLog & #stderrTo .~ SameAsStdout) =<< nagarectl drill (loop ^. #release) (loop ^. #apply <> [review, "--yes"])
  logged <- readLenient applyLog
  let stopped = ambiguousTransaction (lastLines 2 logged)
  indexAttempt drill stage "apply" stopped (if applied ^. #exit == 0 then "converged" else maybe "failed" (const "ambiguous") stopped) applyLog Nothing started
  if applied ^. #exit == 0 then pure True else maybe (pure False) (\transaction -> go transaction (1 :: Int)) stopped
  where
    go transaction n
      | n > 12 = pure False
      | otherwise = do
          (drill ^. #runtime . #pause) 20
          say' drill ("resume " <> T.pack (show n) <> " of " <> transaction)
          started <- drill ^. #runtime . #now
          resumed <- run' drill . (\i -> i & #stdoutTo .~ AppendTo applyLog & #stderrTo .~ SameAsStdout) =<< nagarectl drill (loop ^. #release) ["inventory", "resume", T.unpack transaction, "--yes"]
          logged <- readLenient applyLog
          let again = stoppedAmbiguousAt transaction (lastLines 2 logged)
          indexAttempt drill stage ("resume-" <> showText n) (Just transaction) (if resumed ^. #exit == 0 then "converged" else if again then "ambiguous" else "failed") applyLog Nothing started
          if resumed ^. #exit == 0 then pure True else if again then go transaction (n + 1) else pure False

-- | After a bootstrap stage: once the registry exists, seed the pinned
-- images (once).
seedOnce :: Drill -> IO ()
seedOnce drill = do
  seededAlready <- doesFileExist (drill ^. #root </> "images.env")
  unless seededAlready $ do
    names <- text drill "docker ps failed" =<< command drill "docker" ["ps", "--format", "{{.Names}}"]
    when (any ("k3d-registry" `T.isPrefixOf`) (T.lines names)) $ do
      seedImages drill
      pins <- readLenient (drill ^. #root </> "images.env")
      say' drill ("images seeded: " <> showText (length (T.lines pins)) <> " pins")

-- | Step 3: the local object store's images, from the candidate's
-- digest-checked upstream binaries, pushed through the daemon's own loopback
-- (port 5000 on a Mac belongs to AirPlay), then a loopback forward to the
-- registry, which the artifact transport honours, on the first port from
-- 15213 that refuses connections on the host. Docker cannot pick it: each VM
-- allocates its own ephemeral ports, and another VM's forwarder may already
-- hold the one it picks on the host.
seedImages :: Drill -> IO ()
seedImages drill = do
  printed <- text drill "scripts/publish-local-minio-images.sh failed" . withVariable "NAGARE_LOCAL_REGISTRY_PUSH_HOST" "localhost:5000" =<< command drill "bash" [drill ^. #images]
  let pins = localImagePins printed
  unless (length pins == 2) (refuse "scripts/publish-local-minio-images.sh printed no NAGARE_LOCAL_MINIO_IMAGE and NAGARE_LOCAL_MC_IMAGE")
  forM_ pins (uncurry (setVariable drill))
  BS.writeFile (drill ^. #root </> "images.env") (TE.encodeUtf8 (T.pack (unlines [name <> "=" <> value | (name, value) <- pins])))
  port <- freePort drill 15213
  ok drill "the registry forward did not start" . (\i -> i & #stdoutTo .~ Discard)
    =<< command drill "docker" ["run", "-d", "--name", "registry-forward", "--network", "k3d-nagare-local", "-p", "127.0.0.1:" <> show port <> ":5000", "alpine/socat", "TCP-LISTEN:5000,fork,reuseaddr", "TCP:k3d-registry.localhost:5000"]
  forward drill

-- | The first loopback port from @n@ on which a connection is refused.
freePort :: Drill -> Int -> IO Int
freePort drill n
  | n > 15299 = refuse "no loopback port from 15213 to 15299 is free for the registry forward"
  | otherwise = do
      probe <- run' drill . (\i -> i & #stdoutTo .~ Discard & #stderrTo .~ Discard) =<< command drill "curl" ["-s", "-o", "/dev/null", "-m", "2", "http://127.0.0.1:" <> show n <> "/"]
      -- curl's exit 7: the connection was refused
      if probe ^. #exit == 7 then pure n else freePort drill (n + 1)

-- | Point the artifact transport at the registry forward's host port, once it
-- answers with this daemon's registry.
forward :: Drill -> IO ()
forward drill = do
  let runtime' = drill ^. #runtime
  published <- text drill "docker port registry-forward failed" =<< command drill "docker" ["port", "registry-forward", "5000/tcp"]
  address <- case filter ("127.0.0.1:" `T.isPrefixOf`) (T.lines published) of
    found : _ -> pure (T.unpack (T.strip found))
    [] -> refuse ("the registry forward publishes no loopback port: " <> published)
  let endpoint = "http://" <> address
      await :: Int -> IO ()
      await n = when (n <= 30) $ do
        up <- run' drill =<< command drill "curl" ["-s", "-m", "2", "-o", "/dev/null", endpoint <> "/v2/"]
        unless (up ^. #exit == 0) ((runtime' ^. #pause) 1 >> await (n + 1))
  await 1
  catalog <- run' drill . (\i -> i & #stdoutTo .~ Capture) =<< command drill "curl" ["-s", "-m", "3", endpoint <> "/v2/_catalog"]
  own <- run' drill . (\i -> i & #stdoutTo .~ Capture) =<< command drill "docker" ["exec", "k3d-registry.localhost", "wget", "-q", "-O", "-", "http://localhost:5000/v2/_catalog"]
  unless (trimEnd (lenient (catalog ^. #output)) == trimEnd (lenient (own ^. #output))) $
    refuse ("the registry forward on " <> T.pack address <> " does not answer with this daemon's registry")
  setVariable drill "NAGARE_LOCAL_REGISTRY_FORWARD" address
