-- | Move the intranet to a release candidate, or pin it to the published tag
-- (EP-210 M5, ported by EP-229; docs/runbooks/releases.md).
-- @nagare-harness release candidate@ runs the candidate form after the
-- rehearsal and @release publish@ the tag form after the public flake check.
--
-- The candidate form pins the operator repository's Nagare input to the run's
-- revision, plans (@platform transition plan@) and applies (@inventory apply@)
-- the platform transition until a plan has no operations, commits it
-- (@platform transition commit@), and requires an exact platform status, a
-- converged inventory and the protected URL answering 302 to its login page.
-- Only then does it commit the pin files, by path, and write
-- @<run>/intranet.json@, which release-publish requires. It never edits app
-- config.
--
-- MasterPlan 37 D3: the run records in @<run>/intranet/pins.json@ the git blob
-- of every pin file it changed: the root flake files after it pins them, the
-- files nagarectl writes (the host flake, the context) after each nagarectl
-- command. A rerun continues only while every changed pin file holds exactly
-- what this run left, and the commit checks the same; any other change, such
-- as an edit to @flake.nix@ beside the pin, refuses and is left in place. Every step stops at its first refusal; an apply that stops
-- ambiguous is resumed once (@inventory resume@) by transaction id, and a
-- rerun first resumes the transaction this run left open.
--
-- nagarectl runs through the operator repository's dev shell
-- (@direnv exec@) from an empty environment, so nothing from the calling
-- shell's context reaches it.
module Nagare.Harness.Release.Intranet
  ( IntranetOptions (..)
  , transitionRun
  , transitionPinTag
  , operatorImageOverrides
  , stagesMax
  , loginLocation
  , repoint
  )
where

import Control.Applicative ((<|>))
import Control.Monad (filterM)
import Data.Aeson (Value, fromJSON, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time (defaultTimeLocale, formatTime)
import Nagare.Contract.ReleaseImages (overrideVariable, releaseImageKeys)
import Nagare.Contract.V1 (VersionInfo (..))
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import Nagare.Harness.Release.Review
import Nagare.Harness.Release.RunIndex
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removePathForcibly)
import System.FilePath (dropExtension, takeDirectory, (</>))

data IntranetOptions = IntranetOptions
  { version :: !Text
  , run :: !(Maybe FilePath)
  , context :: !(Maybe Text)
  , revision :: !(Maybe Text)
  , takeOverFields :: !Bool
  -- ^ EP-280: the operator's reviewed field-takeover opt-in, passed to every stage's plan.
  }
  deriving stock (Eq, Show, Generic)

-- | The resolved run: the candidate it names and the operator repository.
data Setup = Setup
  { version :: !Text
  , tag :: !Text
  , run :: !FilePath
  , revision :: !Text
  , previous :: !Text
  , context :: !Text
  , operator :: !FilePath
  , tracked :: ![FilePath]
  , clean :: ![(String, String)]
  , takeOverFields :: !Bool
  }
  deriving stock (Eq, Show, Generic)

stagesMax :: Int
stagesMax = 12

step :: Runtime -> Text -> IO ()
step runtime message = do
  moment <- runtime ^. #now
  (runtime ^. #say) (stampedLine "%H:%M:%SZ" moment "release-intranet" message)

-- | An empty environment, as a fresh operator shell has: the calling shell
-- may carry another context's NAGARE_*, CLOUDSDK_* and KUBECONFIG.
cleanEnvironment :: Runtime -> [(String, String)]
cleanEnvironment runtime =
  [ ("HOME", fromMaybe "" (lookup "HOME" own))
  , ("TMPDIR", fromMaybe "/tmp" (lookupVariable runtime "TMPDIR"))
  , ("PATH", fromMaybe "" (lookup "PATH" own))
  , ("TERM", fromMaybe "dumb" (lookupVariable runtime "TERM"))
  ]
    <> [(name, value) | name <- ["USER", "LOGNAME", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"], Just value <- [lookupVariable runtime name]]
  where
    own = runtime ^. #variables

setup :: Runtime -> IntranetOptions -> IO Setup
setup runtime options = do
  let version' = options ^. #version
      tag' = "v" <> version'
  given <- maybe (refuse "name the candidate run with --run DIR") pure (options ^. #run)
  present <- doesFileExist (given </> "candidate.json")
  unless present (refuse ("no candidate run at " <> T.pack given))
  run' <- canonicalizePath given
  candidate <- readDocument @CandidateRecord (run' </> "candidate.json") >>= either refuse pure
  unless (candidate ^. #version == version') (refuse (T.pack run' <> " is not a run for " <> version'))
  let revision' = candidate ^. #revision
  forM_ (options ^. #revision) $ \wanted ->
    unless (wanted == revision') (refuse (T.pack run' <> " is a run for " <> revision' <> ", not " <> wanted))
  let context' = fromMaybe (maybe "intranet" T.pack (lookupVariable runtime "NAGARE_RELEASE_CONTEXT")) (options ^. #context)
  operator' <- operatorRepository runtime
  let pins = ["flake.nix", "flake.lock", "hosts/" <> T.unpack context' <> "/flake.nix", "hosts/" <> T.unpack context' <> "/flake.lock", "contexts/" <> T.unpack context' <> ".env"]
  tracked' <- filterM (\file -> succeeds runtime (git operator' ["ls-files", "--error-unmatch", "--", file] & #stdoutTo .~ Discard & #stderrTo .~ Discard)) pins
  unless ("flake.nix" `elem` tracked') (refuse (T.pack operator' <> " does not track flake.nix"))
  pure
    Setup
      { version = version'
      , tag = tag'
      , run = run'
      , revision = revision'
      , previous = candidate ^. #previous
      , context = context'
      , operator = operator'
      , tracked = tracked'
      , clean = cleanEnvironment runtime
      , takeOverFields = options ^. #takeOverFields
      }

-- | The operator repository whose dev shell runs the intranet's nagarectl.
operatorRepository :: Runtime -> IO FilePath
operatorRepository runtime = do
  operator' <- case lookupVariable runtime "NAGARE_RELEASE_OPERATOR_REPO" of
    Just path -> pure path
    Nothing -> do
      found <- invoke runtime (invocation "mori" ["path", "mori://tan/tan-ng-labs"] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
      pure (T.unpack (lastLines 1 (lenient (found ^. #output))))
  repository <- if null operator' then pure False else doesDirectoryExist (operator' </> ".git")
  unless repository (refuse ("no operator repository at '" <> T.pack operator' <> "'; set NAGARE_RELEASE_OPERATOR_REPO"))
  pure operator'

-- | The image overrides the operator's dev shell exports (EP-237). Only their
-- names leave the shell; an empty variable is no override.
operatorImageOverrides :: Runtime -> IO [Text]
operatorImageOverrides runtime = do
  operator' <- operatorRepository runtime
  let names = map overrideVariable releaseImageKeys
      script = "for name do eval \"value=\\${$name:-}\"; [ -z \"$value\" ] || echo \"$name\"; done"
  said <-
    capture runtime ("cannot read the image overrides from the shell of " <> T.pack operator') $
      invocation "direnv" (["exec", operator', "sh", "-c", script, "sh"] <> map T.unpack names)
        & #environment
        .~ Exactly (cleanEnvironment runtime)
        & #stderrTo
        .~ Discard
  pure (filter (`elem` names) (T.lines (lenient said)))

git :: FilePath -> [String] -> Invocation
git operator' arguments' = invocation "git" (["-C", operator'] <> arguments')

-- | @direnv exec OPERATOR nagarectl --context CONTEXT …@ from the empty
-- environment.
-- | EP-224: ask nagarectl for its command trace at @.
traced :: FilePath -> Invocation -> Invocation
traced = withVariable "NAGARE_TRACE_FILE"

nagarectl :: Setup -> [String] -> Invocation
nagarectl s arguments' = inShell s (["nagarectl", "--context", T.unpack (s ^. #context)] <> arguments')

inShell :: Setup -> [String] -> Invocation
inShell s command = invocation "direnv" (["exec", s ^. #operator] <> command) & #environment .~ Exactly (s ^. #clean)

-- | The pin files only the pin step writes.
rootPins :: [FilePath]
rootPins = ["flake.nix", "flake.lock"]

-- | The tracked pin files nagarectl writes: the host flake and the context.
generatedPins :: Setup -> [FilePath]
generatedPins s = filter (`notElem` rootPins) (s ^. #tracked)

ledgerPath :: Setup -> FilePath
ledgerPath s = s ^. #run </> "intranet/pins.json"

readLedger :: Setup -> IO (Map.Map FilePath Text)
readLedger s = do
  present <- doesFileExist (ledgerPath s)
  if present then either refuse pure =<< readDocument (ledgerPath s) else pure Map.empty

-- | The tracked pin files among @files@ that differ from the operator's HEAD.
changedPins :: Runtime -> Setup -> [FilePath] -> IO [FilePath]
changedPins runtime s files
  | null files = pure []
  | otherwise = do
      out <- captureText runtime "git status failed" (git (s ^. #operator) (["status", "--porcelain", "--"] <> files))
      let listed = map (T.unpack . T.drop 3) (T.lines out)
      pure (filter (`elem` listed) files)

-- | A working-tree file's git blob, or @deleted@.
blobOf :: Runtime -> Setup -> FilePath -> IO Text
blobOf runtime s file = do
  found <- invoke runtime (git (s ^. #operator) ["hash-object", "--", file] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
  pure (if found ^. #exit == 0 then T.strip (lenient (found ^. #output)) else "deleted")

-- | Record what this run left in each changed file of @files@.
recordPins :: Runtime -> Setup -> [FilePath] -> IO ()
recordPins runtime s files = do
  changed <- changedPins runtime s files
  blobs <- forM changed (\file -> (,) file <$> blobOf runtime s file)
  ledger <- readLedger s
  createDirectoryIfMissing True (takeDirectory (ledgerPath s))
  writeSortedAtomically (ledgerPath s) (Aeson.toJSON (Map.union (Map.fromList blobs) ledger))

-- | Refuse unless every changed pin file holds exactly what this run left;
-- whether any had changed.
checkPins :: Runtime -> Setup -> IO Bool
checkPins runtime s = do
  ledger <- readLedger s
  changed <- changedPins runtime s (s ^. #tracked)
  strangers <- filterM (\file -> (\blob -> Map.lookup file ledger /= Just blob) <$> blobOf runtime s file) changed
  unless (null strangers) $
    refuse ("the pin files " <> T.intercalate ", " (map T.pack strangers) <> " in " <> T.pack (s ^. #operator) <> " have changes this run did not make; commit or stash them, then rerun")
  pure (not (null changed))

-- | Pin the published tag: the same commit, named by its tag.
transitionPinTag :: Runtime -> IntranetOptions -> IO ()
transitionPinTag runtime options = do
  s <- setup runtime options
  dirty <- captureText runtime "git status failed" (git (s ^. #operator) ["status", "--porcelain", "--", "flake.nix", "flake.lock"])
  unless (T.null dirty) (refuse ("flake.nix or flake.lock has uncommitted changes in " <> T.pack (s ^. #operator)))
  pin runtime s (s ^. #tag)
  commitPins
    runtime
    s
    ("chore(nagare): pin the " <> s ^. #context <> " to the published " <> s ^. #tag <> " tag")
    (s ^. #tag <> " is the candidate " <> s ^. #revision <> " the " <> s ^. #context <> " already runs.")
    ["flake.nix", "flake.lock"]

-- | Move the intranet to the run's candidate.
transitionRun :: Runtime -> IntranetOptions -> IO ()
transitionRun runtime options = do
  s <- setup runtime options
  started <- runtime ^. #now
  index <-
    openIndex runtime (s ^. #run </> "intranet-index.json") $
      newRunIndex "intranet" "intranet" started
        & #context
        ?~ s
        ^. #context
        & #candidate
        .~ Revisioned (Just (s ^. #version)) (Just (s ^. #revision))
        & #source
        .~ Revisioned (Just (s ^. #previous)) Nothing
  withRunIndex index (moveIntranet runtime s index)

moveIntranet :: Runtime -> Setup -> IndexWriter -> IO ()
moveIntranet runtime s index = do
  let operator' = T.pack (s ^. #operator)
      context' = s ^. #context
      version' = s ^. #version
      revision' = s ^. #revision
  -- preflight: refuse before changing anything. A run that stopped after
  -- pinning left the pin files as it recorded them; a rerun continues.
  continuing <- checkPins runtime s
  when continuing (step runtime "the pin files hold this run's earlier changes; continuing")
  gcloud <- succeeds runtime (inShell s ["sh", "-c", "command -v gcloud"] & #stdoutTo .~ Discard)
  unless gcloud (refuse "gcloud is not on PATH")
  protected <- case lookupVariable runtime "NAGARE_RELEASE_PROTECTED_URL" of
    Just url -> pure (T.pack url)
    Nothing -> do
      domain <- captureText runtime "the operator shell has no NAGARE_BASE_DOMAIN" (inShell s ["printenv", "NAGARE_BASE_DOMAIN"])
      pure ("https://protected-hello." <> domain <> "/")
  let reviews = s ^. #run </> "intranet"
  createDirectoryIfMissing True reviews
  -- 1. pin the candidate; the dev shell then carries its nagarectl
  step runtime ("pinning " <> operator' <> " to " <> revision')
  pin runtime s revision'
  recordPins runtime s rootPins
  let notCandidate = "the operator shell's nagarectl is not " <> version' <> " at " <> revision'
  identity <- capture runtime notCandidate (nagarectl s ["version", "--json"])
  case decodeDocument @VersionInfo "version --json" identity of
    Right found | found ^. #version == version' && found ^. #revision == Just revision' -> pure ()
    _ -> refuse notCandidate
  -- The head alone answers this; full status needs the candidate's
  -- workspace, which the first plan below prepares.
  store <- capture runtime ("cannot read the " <> context' <> " store's head") (nagarectl s ["inventory", "store", "status", "--json"])
  found <- either refuse pure (decodeDocument @StoreStatus "inventory store status --json" store)
  forM_ (found ^. #activeTransaction) (resumeOwn runtime s reviews)
  -- 2. plan and apply until a plan has no operations, then commit. A rerun
  -- after the context already moved to this candidate has nothing to plan.
  moved <- alreadyExact runtime s version' revision'
  if moved
    then step runtime ("the " <> context' <> " already runs " <> version' <> " at " <> revision')
    else converge runtime s index reviews Nothing 1
  status <- platformStatus runtime s
  status' <-
    if status ^. _2 . #identities . #context . #version == Just version'
      then pure status
      else do
        step runtime "committing the transition"
        let commitLog = reviews </> "commit.log"
        committed <- succeeds runtime (nagarectl s ["platform", "transition", "commit", "--yes"] & #stdoutTo .~ WriteTo commitLog & #stderrTo .~ SameAsStdout)
        recordPins runtime s (generatedPins s)
        unless committed $ do
          logged <- readLenient commitLog
          refuse ("transition commit refused: " <> lastLines 5 logged)
        platformStatus runtime s
  -- 3. the checks the record stands for
  unless (exactOn version' revision' (status' ^. _2)) $
    refuse ("platform status is not exact on " <> version' <> " at " <> revision' <> ": " <> compactStatus (status' ^. _1))
  inventoryBytes <- capture runtime "inventory status failed" (nagarectl s ["inventory", "status", "--json"])
  inventory <- either refuse pure (decodeDocument @InventoryStatus "inventory status --json" inventoryBytes)
  unless (platformConverged inventory) $
    refuse ("the " <> context' <> " inventory has an active transaction or an accepted scope that has not converged: " <> T.intercalate ", " (fst (unconvergedScopes inventory)))
  let elsewhere = snd (unconvergedScopes inventory)
  unless (null elsewhere) $
    step runtime ("an application's, so not blocking: " <> T.intercalate ", " elsewhere <> " accepted but not converged")
  answer <- invoke runtime (invocation "curl" ["-sS", "-o", "/dev/null", "-m", "30", "-w", "%{http_code} %{redirect_url}\n", T.unpack protected] & #stdoutTo .~ Capture)
  let (code, location) = case T.lines (lenient (answer ^. #output)) of
        firstLine : _ -> let (c, rest) = T.break (== ' ') (T.strip firstLine) in (c, T.strip rest)
        [] -> ("", "")
  unless (code == "302" && loginLocation location) $
    refuse (protected <> " answered " <> (if T.null code then "nothing" else code) <> " " <> location <> ", not a 302 to a login page")
  -- 4. the pin commit, then the record
  _ <- checkPins runtime s
  commitPins
    runtime
    s
    ("feat(nagare): upgrade the " <> context' <> " to the " <> s ^. #tag <> " candidate")
    ("Moved the " <> context' <> " to Nagare " <> version' <> " at " <> revision' <> " with just release-candidate: platform status is exact, every accepted platform scope has converged, and " <> protected <> " redirects to the login page.")
    (s ^. #tracked)
  moment <- runtime ^. #now
  let statusCode = fromMaybe 0 (readInt code)
  writeSortedAtomically
    (s ^. #run </> "intranet.json")
    ( object
        [ "version" .= version'
        , "revision" .= revision'
        , "context" .= context'
        , "checkedAt" .= T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" moment)
        , "status" .= (status' ^. _1)
        , "inventory" .= object ["activeTransaction" .= (inventory ^. #activeTransaction), "accepted" .= length (fromMaybe [] (inventory ^. #accepted)), "converged" .= True, "unconvergedApplicationScopes" .= elsewhere]
        , "protected" .= object ["url" .= protected, "status" .= statusCode, "location" .= location]
        ]
    )
  setRecord index "intranet" (s ^. #run </> "intranet.json")
  step runtime ("the " <> context' <> " runs " <> version' <> " at " <> revision' <> "; record " <> T.pack (s ^. #run </> "intranet.json"))

-- | A rerun resumes the transaction an earlier attempt of this run left open,
-- named by an outcome document in the run's reviews. Another transaction is
-- not this run's to resume.
resumeOwn :: Runtime -> Setup -> FilePath -> Text -> IO ()
resumeOwn runtime s reviews transaction = do
  documents <- filter (\file -> any (`isSuffixOf` file) [".apply.json", ".resume.json"]) <$> listDirectory reviews
  own <- forM documents (\file -> (\(_, opened, _) -> opened) <$> readApplyOutcome (reviews </> file))
  unless (Just transaction `elem` own) $
    refuse ("the " <> s ^. #context <> " store has the active transaction " <> transaction <> ", which this run did not open; resume or close it with the release that opened it")
  step runtime ("resuming " <> transaction <> ", which this run left open")
  let document' = reviews </> "rerun.resume.json"
      logFile = reviews </> "rerun.resume.log"
  _ <- invoke runtime (traced (reviews </> "rerun.resume.trace.json") (nagarectl s ["inventory", "resume", T.unpack transaction, "--yes", "--contract", "1"]) & #stdoutTo .~ WriteTo document' & #stderrTo .~ WriteTo logFile)
  recordPins runtime s (generatedPins s)
  (resumed, _, _) <- readApplyOutcome document'
  unless (resumed == AppliedConverged) $ do
    logged <- readLenient logFile
    refuse ("resume of " <> transaction <> " failed: " <> describeOutcome resumed <> ": " <> lastLines 5 logged)

-- | Plan stage @n@; stop when its summary counts no operation and no
-- re-accepted scope, otherwise apply it, resuming an ambiguous stop once.
-- Both decisions come from documents nagarectl writes: the plan's
-- @--summary@ and the apply's @--contract 1@ outcome.
converge :: Runtime -> Setup -> IndexWriter -> FilePath -> Maybe ReviewWork -> Int -> IO ()
converge runtime s index reviews previous n
  | n > stagesMax = refuse ("the transition did not converge in " <> showText stagesMax <> " stages; reviews in " <> T.pack reviews)
  | otherwise = do
      let review = reviews </> ("stage-" <> show n)
          planLog = review <> ".plan.log"
          summaryFile = review <> ".summary.json"
          applyLog = review <> ".apply.log"
          stage = "intranet-" <> showText n
          planTrace = review <> ".plan.trace.json"
      removePathForcibly review
      planned <- succeeds runtime (traced planTrace (nagarectl s (["platform", "transition", "plan", "--out", review, "--summary", summaryFile] <> ["--take-over-fields" | s ^. #takeOverFields])) & #stdoutTo .~ WriteTo planLog & #stderrTo .~ SameAsStdout)
      recordPins runtime s (generatedPins s)
      unless planned $ do
        logged <- readLenient planLog
        refuse ("plan " <> showText n <> " refused: " <> lastLines 5 logged)
      counts <- summaryCounts <$> (readPlanSummary summaryFile >>= either refuse pure)
      let operations' = operationCount AllOperations counts
          moves = counts ^. #reaccepted
          done = isConverged AllOperations counts
      -- EP-228 M3: a stage repeating the work the previous stage applied
      -- makes no progress; stop and name it rather than plan twelve times.
      work <- readReviewWork review >>= either refuse pure
      when (not done && previous == Just work) (refuse (noProgress "intranet" n work))
      plannedAt' <- runtime ^. #now
      addStage index (StageEntry stage "intranet" n (relativeIn index review) (relativeIn index planLog) (Just (relativeIn index summaryFile)) operations' moves done plannedAt' [] (Just (relativeIn index planTrace)) (Just (s ^. #takeOverFields)))
      step runtime ("stage " <> showText n <> ": " <> showText operations' <> " operations, re-accepts " <> showText moves <> " scopes")
      unless done $ do
        applied <- attempt runtime s index stage "apply" (nagarectl s ["inventory", "apply", review, "--yes", "--contract", "1"]) (review <> ".apply.json") (WriteTo applyLog)
        case applied of
          AppliedConverged -> pure ()
          AppliedAmbiguous transaction -> do
            step runtime ("apply " <> showText n <> " stopped ambiguous; resuming " <> transaction <> " once")
            resumed <- attempt runtime s index stage "resume" (nagarectl s ["inventory", "resume", T.unpack transaction, "--yes", "--contract", "1"]) (review <> ".resume.json") (AppendTo applyLog)
            unless (resumed == AppliedConverged) $ do
              logged <- readLenient applyLog
              refuse ("resume of " <> transaction <> " failed: " <> describeOutcome resumed <> ": " <> lastLines 5 logged)
          AppliedStopped reason -> do
            logged <- readLenient applyLog
            refuse ("apply " <> showText n <> " failed: " <> reason <> ": " <> lastLines 5 logged)
        converge runtime s index reviews (Just work) (n + 1)

-- | Run one apply or resume with its outcome document on stdout and its
-- progress in the stage's log, record the pin files it wrote, and index the
-- attempt.
attempt :: Runtime -> Setup -> IndexWriter -> Text -> Text -> Invocation -> FilePath -> Sink -> IO ApplyOutcome
attempt runtime s index stage action' command document' logSink = do
  started <- runtime ^. #now
  let trace' = dropExtension document' <> ".trace.json"
  _ <- invoke runtime (traced trace' command & #stdoutTo .~ WriteTo document' & #stderrTo .~ logSink)
  recordPins runtime s (generatedPins s)
  (outcome', transaction', name') <- readApplyOutcome document'
  finished' <- runtime ^. #now
  let logFile' = case logSink of
        WriteTo path -> path
        AppendTo path -> path
        _ -> document'
  addAttempt index stage (Attempt (stage <> "/" <> action') action' transaction' name' (relativeIn index logFile') (Just (relativeIn index document')) started finished' (Just (relativeIn index trace')))
  pure outcome'

describeOutcome :: ApplyOutcome -> Text
describeOutcome = \case
  AppliedConverged -> "converged"
  AppliedAmbiguous transaction -> "ambiguous " <> transaction
  AppliedStopped reason -> reason

-- | Whether platform status already reads exact on this candidate. A status
-- that cannot be read counts as not moved.
alreadyExact :: Runtime -> Setup -> Text -> Text -> IO Bool
alreadyExact runtime s version' revision' = do
  result <- invoke runtime (nagarectl s ["platform", "status", "--json"] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
  pure $
    result ^. #exit == 0
      && either (const False) (exactOn version' revision') (decodeDocument @PlatformStatus "platform status --json" (result ^. #output))

platformStatus :: Runtime -> Setup -> IO (Value, PlatformStatus)
platformStatus runtime s = do
  bytes <- capture runtime "platform status failed" (nagarectl s ["platform", "status", "--json"])
  raw <- either refuse pure (decodeDocument @Value "platform status --json" bytes)
  case fromJSON raw of
    Aeson.Success typed -> pure (raw, typed)
    Aeson.Error reason -> refuse ("platform status --json: " <> T.pack reason <> ": " <> compactStatus raw)

compactStatus :: Value -> Text
compactStatus raw = case raw of
  Aeson.Object fields -> lenientLazy (Aeson.encode (object [Key.fromText key .= field | key <- ["compatibility", "identities"], Just field <- [KeyMap.lookup (Key.fromText key) fields]]))
  other -> lenientLazy (Aeson.encode other)

-- | Point @inputs.nagare.url@ at @ref@, lock it, and require the lock to
-- resolve to the candidate.
pin :: Runtime -> Setup -> Text -> IO ()
pin runtime s ref = do
  let path = s ^. #operator </> "flake.nix"
      url = "github:shinzui/nagare/" <> ref
  original <- readLenient path
  let updated = T.intercalate "\n" (map (repoint url) (T.splitOn "\n" original))
  BS.writeFile path (TE.encodeUtf8 updated)
  unless (("inputs.nagare.url = \"" <> url <> "\";") `T.isInfixOf` updated) $
    refuse (T.pack path <> " has no inputs.nagare.url line to pin")
  locked <- succeeds runtime (invocation "nix" ["flake", "update", "nagare"] & #directory ?~ s ^. #operator & #environment .~ Exactly (s ^. #clean) & #stdoutTo .~ Discard)
  unless locked (refuse ("nix flake update nagare failed in " <> T.pack (s ^. #operator)))
  lock <- readDocument @Value (s ^. #operator </> "flake.lock") >>= either refuse pure
  unless (lockedRevision lock == Just (s ^. #revision)) $
    refuse ("the operator flake.lock does not resolve " <> url <> " to " <> s ^. #revision)

-- | One line of @flake.nix@ with its @inputs.nagare.url = "…";@ value
-- replaced, the way the script's @sed@ did.
repoint :: Text -> Text -> Text
repoint url line =
  let (indent, rest) = T.span (`elem` (" \t" :: String)) line
      prefix = "inputs.nagare.url = \""
   in case T.stripPrefix prefix rest of
        Just afterPrefix
          | let (_, tailText) = T.break (== '"') afterPrefix
          , "\";" `T.isPrefixOf` tailText ->
              indent <> prefix <> url <> tailText
        _ -> line

-- | Commit exactly the changed pin files; nothing else the operator has
-- staged goes with them.
commitPins :: Runtime -> Setup -> Text -> Text -> [FilePath] -> IO ()
commitPins runtime s subject body files = do
  changed <- filterM (\file -> not . T.null <$> captureText runtime "git status failed" (git (s ^. #operator) ["status", "--porcelain", "--", file])) files
  if null changed
    then step runtime "the operator repository already records this pin"
    else do
      require runtime "git add of the pin files failed" (git (s ^. #operator) (["add", "--"] <> changed))
      require runtime "the pin commit failed" (git (s ^. #operator) (["commit", "-q", "-m", T.unpack subject, "-m", T.unpack body, "--only", "--"] <> changed))
      short <- captureText runtime "git rev-parse failed" (git (s ^. #operator) ["rev-parse", "--short", "HEAD"])
      step runtime ("committed " <> short <> " in " <> T.pack (s ^. #operator) <> ": " <> T.unwords (map T.pack changed))

-- | @^https?://[^/]+/[^?#]*login@.
loginLocation :: Text -> Bool
loginLocation location = case T.stripPrefix "https://" location <|> T.stripPrefix "http://" location of
  Just rest ->
    let (hostPart, path) = T.break (== '/') rest
     in not (T.null hostPart) && "/" `T.isPrefixOf` path && "login" `T.isInfixOf` T.takeWhile (`notElem` ("?#" :: String)) path
  Nothing -> False

readLenient :: FilePath -> IO Text
readLenient path = lenient <$> BS.readFile path

lenient :: BS.ByteString -> Text
lenient = TE.decodeUtf8With TE.lenientDecode

lenientLazy :: BL.ByteString -> Text
lenientLazy = lenient . BL.toStrict

showText :: Int -> Text
showText = T.pack . show

readInt :: Text -> Maybe Int
readInt text = case reads (T.unpack text) of
  [(n, "")] -> Just n
  _ -> Nothing
