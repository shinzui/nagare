-- | Everything up to the tag (MP-26 item 11, ported by EP-229;
-- docs/runbooks/releases.md): the landing check, a release's service images
-- when it names them (EP-237: built, checked against release.json and pushed
-- to the binary cache before anything fetches them), the transition rehearsal
-- from the newest release the candidate accepts, then the intranet on the
-- candidate (the candidate's @scripts/release-intranet.sh@). Every step runs in
-- the run's own worktree, never the checkout it was started from (EP-210 M4),
-- and stops at its first failure. @just release-publish VERSION@ takes the run
-- from here.
--
-- MasterPlan 37 D3: a run belongs to one version and revision
-- (@releases/vVERSION/REV@, or @--run DIR@) and records them in
-- @candidate.json@ before any step. A rerun continues it: a step whose result
-- this run already holds (the landed gate record, the images receipt, the
-- rehearsal record, the intranet record) is kept, not run again, and the run
-- index lists it as @kept@.
--
-- @--rehearsal@ runs every step but the intranet for an already tagged or
-- unreleased revision, in @releases/vVERSION/rehearsal-REV@.
module Nagare.Harness.Release.Candidate
  ( CandidateOptions (..)
  , releaseCandidate
  , candidateRun
  , newestVersion
  , validVersion
  , notesTitled
  )
where

import Control.Exception (finally)
import Control.Monad (void)
import Data.Aeson (toJSON)
import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Nagare.Contract.ReleaseImages (ReleaseImages)
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Images (ImagesReceipt, PushImages (..), pushReleaseImages, readReleaseImages)
import Nagare.Harness.Release.Intranet (operatorImageOverrides)
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import Nagare.Harness.Release.RunIndex
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

data CandidateOptions = CandidateOptions
  { version :: !Text
  , revision :: !Text
  , rehearsal :: !Bool
  , run :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

step :: Runtime -> Text -> IO ()
step runtime message = do
  moment <- runtime ^. #now
  (runtime ^. #say) (stampedLine "%H:%M:%SZ" moment "release-candidate" message)

-- | An unpadded @major.minor.patch@.
validVersion :: Text -> Bool
validVersion text = case T.splitOn "." text of
  pieces@[_, _, _] -> all component pieces
  _ -> False
  where
    component part = not (T.null part) && T.all isDigit part && (part == "0" || T.head part /= '0')

-- | The newest version of a list, as @sort -V | tail -1@ picks it.
newestVersion :: [Text] -> Maybe Text
newestVersion [] = Nothing
newestVersion versions = Just (last (sortOn key versions))
  where
    key text = (map number (T.splitOn "." text), text)
    number part = case reads (T.unpack part) :: [(Integer, String)] of
      [(n, "")] -> n
      _ -> -1

-- | The notes begin with their release's title.
notesTitled :: Text -> Text -> Bool
notesTitled version' notes = take 1 (T.lines notes) == ["# Nagare " <> version']

-- | The run directory of a candidate: one per version and revision, so a
-- rerun continues the run it names.
candidateRun :: FilePath -> Text -> Bool -> Text -> FilePath
candidateRun state version' rehearsal' rev = state </> "nagare/releases" </> ("v" <> T.unpack version') </> ((if rehearsal' then "rehearsal-" else "") <> T.unpack rev)

-- | What a release with images needs before anything runs. An operator pin
-- would make the intranet's status non-exact only after it had moved, so it
-- refuses here; a rehearsal leaves the intranet alone.
imagesPreflight :: Runtime -> Bool -> IO ()
imagesPreflight runtime rehearsal' = do
  when (isNothing (lookupVariable runtime "CACHIX_AUTH_TOKEN")) $
    refuse "CACHIX_AUTH_TOKEN is not set; this release pushes its images to the binary cache"
  unless rehearsal' $ do
    overrides <- operatorImageOverrides runtime
    unless (null overrides) $
      refuse ("the operator shell still exports " <> T.intercalate ", " overrides <> "; this release names its own images, and a pin would stop its intranet step after the transition applied. Remove the pins first")

releaseCandidate :: Runtime -> CandidateOptions -> IO ()
releaseCandidate outer options = do
  let version' = options ^. #version
      rehearsal' = options ^. #rehearsal
      git arguments' = invocation "git" arguments'
  unless (validVersion version') (refuse "VERSION must be an unpadded major.minor.patch version")
  repo <- T.unpack <$> captureText outer "not in a git repository" (git ["rev-parse", "--show-toplevel"])
  -- Every command below runs from the repository root unless it names the
  -- run's worktree.
  let runtime = runningIn repo outer
  rev <- captureText runtime ("no commit " <> options ^. #revision) (git ["rev-parse", "--verify", T.unpack (options ^. #revision) <> "^{commit}"])
  -- preflight: everything that can refuse without building
  metadataBytes <- capture runtime ("no release.json at " <> rev) (git ["show", T.unpack rev <> ":release.json"])
  metadata <- either refuse pure (decodeDocument @ReleaseMetadata "release.json" metadataBytes)
  unless (metadata ^. #platformVersion == version') $
    refuse ("release.json at " <> rev <> " is not " <> version' <> "; land chore(release): prepare v" <> version' <> " first")
  let notesPath = "docs/releases/v" <> T.unpack version' <> ".md"
  notes <- TE.decodeUtf8With TE.lenientDecode <$> capture runtime ("no " <> T.pack notesPath <> " at " <> rev) (git ["show", T.unpack rev <> ":" <> notesPath])
  unless (notesTitled version' notes) (refuse (T.pack notesPath <> " at " <> rev <> " does not begin # Nagare " <> version'))
  releaseImages <- either refuse pure (readReleaseImages metadataBytes)
  forM_ releaseImages (const (imagesPreflight runtime rehearsal'))
  require runtime "git fetch failed" (git ["fetch", "-q", "origin", "master", "--tags"])
  require runtime (rev <> " is not on origin/master; land the candidate first") (git ["merge-base", "--is-ancestor", T.unpack rev, "origin/master"])
  unless rehearsal' $ do
    tagged <- succeeds runtime (git ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack version'] & #stdoutTo .~ Discard)
    when tagged (refuse ("v" <> version' <> " is already tagged"))
  -- The rehearsal starts from the newest release the candidate accepts a
  -- transition from.
  previous <- maybe (refuse ("release.json at " <> rev <> " accepts no transition")) pure (newestVersion (metadata ^. #transitionsFrom))
  require runtime ("v" <> previous <> ", the newest accepted source, is not a published tag") (git ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack previous] & #stdoutTo .~ Discard)
  let run = fromMaybe (candidateRun (stateDirectory runtime) version' rehearsal' rev) (options ^. #run)
      record = CandidateRecord {previous = previous, revision = rev, version = version'}
  createDirectoryIfMissing True run
  -- The run is bound to one candidate before any step needs it.
  bound <- doesFileExist (run </> "candidate.json")
  if bound
    then do
      earlier <- readDocument @CandidateRecord (run </> "candidate.json") >>= either refuse pure
      unless (earlier == record) $
        refuse (T.pack run <> " is the run of " <> earlier ^. #version <> " at " <> earlier ^. #revision <> " from v" <> earlier ^. #previous <> ", not this candidate")
    else writeSorted True (run </> "candidate.json") (toJSON record)
  started <- runtime ^. #now
  index <-
    resumeIndex runtime (run </> "index.json") $
      newRunIndex "candidate" "release" started
        & #candidate
        .~ Revisioned (Just version') (Just rev)
        & #source
        .~ Revisioned (Just previous) Nothing
  setRecord index "candidate" (run </> "candidate.json")
  let worktree = run </> "worktree"
      revision' = T.unpack rev
      phase name' message = advance index name' Nothing >> step runtime message
      removeWorktree = invoke runtime (git ["-C", repo, "worktree", "remove", "--force", worktree] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
  backgroundRef <- newIORef []
  let cleanup = readIORef backgroundRef >>= mapM_ (^. #stop) >> void removeWorktree
  flip finally cleanup . withRunIndex index $ do
    phase "worktree" ("v" <> version' <> " at " <> rev <> " from v" <> previous <> "; run directory " <> T.pack run)
    -- an earlier invocation that was killed leaves its worktree behind
    void removeWorktree
    require runtime "git worktree add failed" (git ["worktree", "add", "-q", "--detach", worktree, revision'])
    let inWorktree command = command & #directory ?~ worktree
        gateVerified = succeeds runtime (inWorktree (invocation "just" ["gate-verify", revision']) & #stdoutTo .~ Discard & #stderrTo .~ Discard)
    -- 1. the landing check: the landed commit's green full-gate record, or
    -- the same full gate run here, in the background beside steps 2 and 3
    verified <- gateVerified
    gate <-
      if verified
        then keepStep index "gate" >> step runtime ("the landing check passed: " <> rev <> " has a green full gate") >> pure Nothing
        else do
          step runtime ("no green full-gate record for " <> rev <> "; running the full gate (in the background, log " <> T.pack (run </> "gate.log") <> ")")
          beginStep index "gate" (Just (run </> "gate.log")) True
          gate' <- (runtime ^. #transport . #spawn) (inWorktree (invocation "just" ["gate", revision']) & #stdoutTo .~ WriteTo (run </> "gate.log") & #stderrTo .~ SameAsStdout)
          modifyIORef' backgroundRef (gate' :)
          pure (Just gate')
    -- 2. the release images (EP-237): the rehearsal and the intranet fetch
    -- them, so they reach the cache before either starts
    forM_ releaseImages $ \images' -> do
      let receipt = run </> "images/release-images.json"
      kept <- either (const False) ((== rev) . (^. #candidate)) <$> readImagesReceipt receipt
      if kept
        then keepStep index "images"
        else do
          phase "images" "release images: build, push to the binary cache, read back"
          pushImages runtime repo rev revision' run images'
      setRecord index "releaseImages" receipt
    -- 3. the transition rehearsal
    let rehearsed = run </> "transition-rehearsal.json"
    kept <- doesFileExist rehearsed >>= \present -> if present then either (const False) (rehearsalMatches rev previous) <$> readDocument @RehearsalCheck rehearsed else pure False
    if kept
      then keepStep index "rehearsal"
      else do
        -- Under the run directory, in the home directory a Colima VM shares:
        -- the local substrate mounts the context's store from here, and a
        -- path the VM does not share mounts empty (the lifecycle worker then
        -- reads no head).
        rehearsalWork <- T.unpack <$> captureText runtime "mktemp failed" (invocation "mktemp" ["-d", run </> "rehearsal.XXXXXX"])
        setChild index "rehearsal" (rehearsalWork </> "index.json")
        advance index "rehearsal" (Just (run </> "rehearsal.log"))
        step runtime ("transition rehearsal from v" <> previous <> " (log " <> T.pack (run </> "rehearsal.log") <> ")")
        rehearsalExit <-
          invoke
            runtime
            ( inWorktree (invocation "scripts/release-rehearse.sh" [revision', T.unpack previous, "--run", rehearsalWork])
                & #environment
                .~ Extended [("NAGARE_RELEASE_REHEARSAL_RECORD", rehearsed)]
                & #stdoutTo
                .~ WriteTo (run </> "rehearsal.log")
                & #stderrTo
                .~ SameAsStdout
            )
        unless (rehearsalExit ^. #exit == 0) (refuse ("the transition rehearsal failed: " <> T.pack (run </> "rehearsal.log")))
        present <- doesFileExist rehearsed
        unless present (refuse ("release-rehearse left no " <> T.pack rehearsed))
    setRecord index "transitionRehearsal" rehearsed
    -- 4. the landing check, if it ran here
    forM_ gate $ \gate' -> do
      phase "gate-wait" "waiting for the full gate"
      gateExit <- gate' ^. #finished
      endStep index "gate" (gateExit == 0)
      green <- gateVerified
      unless (gateExit == 0 && green) (refuse ("the full gate failed: " <> T.pack (run </> "gate.log")))
    if rehearsal'
      then step runtime ("rehearsal complete; the intranet is untouched. The rehearsal record is " <> T.pack rehearsed)
      else do
        -- 5. the intranet on the candidate; release-publish requires its record
        let moved = run </> "intranet.json"
        done <- doesFileExist moved >>= \present -> if present then either (const False) (intranetOn version' rev) <$> readDocument @IntranetCheck moved else pure False
        if done
          then keepStep index "intranet"
          else do
            phase "intranet" "the intranet"
            setChild index "intranet" (run </> "intranet-index.json")
            require runtime "the intranet move failed" (invocation (worktree </> "scripts/release-intranet.sh") [T.unpack version', "--run", run])
        setRecord index "intranet" moved
        step runtime ("v" <> version' <> " is ready to publish: just release-publish " <> version')

pushImages :: Runtime -> FilePath -> Text -> String -> FilePath -> ReleaseImages -> IO ()
pushImages runtime repo rev revision' run images' =
  ()
    <$ pushReleaseImages
      runtime
      PushImages
        { flake = "git+file://" <> repo <> "?rev=" <> revision'
        , revision = rev
        , images = images'
        , work = run </> "images"
        }

readImagesReceipt :: FilePath -> IO (Either Text ImagesReceipt)
readImagesReceipt path = doesFileExist path >>= \present -> if present then readDocument path else pure (Left "no receipt")
