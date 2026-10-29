-- | Everything up to the tag, unattended (MP-26 item 11, ported by EP-229;
-- docs/runbooks/releases.md). The release gate, the transition rehearsal from
-- the newest release the candidate accepts, both systems' native attachments
-- (aarch64-darwin here, x86_64-linux in an amd64 Apple container), and two
-- assemblies that must be byte-identical. The release gate runs alongside the
-- other steps. Then the intranet moves to the candidate (the candidate's
-- @scripts/release-intranet.sh@), and the rehearsal record is committed on the
-- current origin/master and landed. Every step runs in the run's own
-- worktrees, never the checkout it was started from (EP-210 M4), and stops at
-- its first failure; nothing is retried. @just release-publish VERSION@ takes
-- the run from here.
--
-- @--rehearsal@ runs every step for an already tagged or unreleased revision
-- but lands nothing and leaves the run where release-publish does not look.
module Nagare.Harness.Release.Candidate
  ( CandidateOptions (..)
  , releaseCandidate
  , newestVersion
  , validVersion
  )
where

import Control.Exception (finally)
import Data.Aeson (toJSON)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort, sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time (defaultTimeLocale, formatTime)
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import Nagare.Harness.Release.RunIndex
import System.Directory (copyFile, createDirectoryIfMissing, createDirectoryLink, doesFileExist, removePathForcibly)
import System.FilePath (takeDirectory, (</>))

data CandidateOptions = CandidateOptions
  { version :: !Text
  , revision :: !Text
  , rehearsal :: !Bool
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
  rev <- captureText runtime ("no commit " <> options ^. #revision) ((git ["rev-parse", "--verify", T.unpack (options ^. #revision) <> "^{commit}"]))
  let state = stateDirectory runtime </> "nagare/releases"
      image = "nixos/nix:2.35.2"
  -- preflight: everything that can refuse without building
  system <- captureText runtime "nix eval failed" ((invocation "nix" ["eval", "--impure", "--raw", "--expr", "builtins.currentSystem"]))
  unless (system == "aarch64-darwin") (refuse "run it on the aarch64-darwin workstation; the x86_64-linux attachments come from an Apple container")
  metadataBytes <- capture runtime ("no release.json at " <> rev) ((git ["show", T.unpack rev <> ":release.json"]))
  metadata <- either refuse pure (decodeDocument @ReleaseMetadata "release.json" metadataBytes)
  unless (metadata ^. #platformVersion == version') $
    refuse ("release.json at " <> rev <> " is not " <> version' <> "; land chore(release): prepare v" <> version' <> " first")
  unless (sort (metadata ^. #supportedSystems) == ["aarch64-darwin", "x86_64-linux"]) $
    refuse ("release.json at " <> rev <> " names systems this command does not build")
  require runtime "git fetch failed" ((git ["fetch", "-q", "origin", "master", "--tags"]))
  require runtime (rev <> " is not on origin/master; land the candidate first") ((git ["merge-base", "--is-ancestor", T.unpack rev, "origin/master"]))
  unless rehearsal' $ do
    tagged <- succeeds runtime ((git ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack version']) & #stdoutTo .~ Discard)
    when tagged (refuse ("v" <> version' <> " is already tagged"))
  -- The rehearsal starts from the newest release the candidate accepts a
  -- transition from.
  previous <- maybe (refuse ("release.json at " <> rev <> " accepts no transition")) pure (newestVersion (metadata ^. #transitionsFrom))
  require runtime ("v" <> previous <> ", the newest accepted source, is not a published tag") ((git ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack previous]) & #stdoutTo .~ Discard)
  container <- (runtime ^. #locate) "container"
  when (isNothing container) (refuse "Apple container is not installed")
  started <- runtime ^. #now
  let run = state </> ("v" <> T.unpack version') </> ((if rehearsal' then "rehearsal-" else "") <> formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" started)
      worktree = run </> "worktree"
      evidence = run </> "evidence"
      revision' = T.unpack rev
  createDirectoryIfMissing True run
  index <-
    openIndex runtime (run </> "index.json") $
      newRunIndex "candidate" "release" started
        & #candidate
        .~ Revisioned (Just version') (Just rev)
        & #source
        .~ Revisioned (Just previous) Nothing
  let phase name' message = advance index name' Nothing >> step runtime message
  gateRef <- newIORef Nothing
  let cleanup = do
        readIORef gateRef >>= mapM_ (^. #stop)
        forM_ [worktree, evidence] $ \tree ->
          invoke runtime (git ["-C", repo, "worktree", "remove", "--force", tree] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
  flip finally cleanup . withRunIndex index $ do
    phase "worktree" ("v" <> version' <> " at " <> rev <> " from v" <> previous <> "; run directory " <> T.pack run)
    require runtime "git worktree add failed" ((git ["worktree", "add", "-q", "--detach", worktree, revision']))
    let inWorktree command = command & #directory ?~ worktree
    -- 1. the release gate, in parallel with steps 2-5; its result is
    -- required before anything lands
    step runtime ("release gate (in the background, log " <> T.pack (run </> "gate-release.log") <> ")")
    beginStep index "gate" (Just (run </> "gate-release.log")) True
    gate <- (runtime ^. #transport . #spawn) (inWorktree (invocation "just" ["gate-release", revision']) & #stdoutTo .~ WriteTo (run </> "gate-release.log") & #stderrTo .~ SameAsStdout)
    writeIORef gateRef (Just gate)
    -- 2. the transition rehearsal
    phase "rehearsal" ("transition rehearsal from v" <> previous)
    rehearsalWork <- T.unpack <$> captureText runtime "mktemp failed" (invocation "mktemp" ["-d", "/private/tmp/nagare-release-rehearse.XXXXXX"])
    setChild index "rehearsal" (rehearsalWork </> "index.json")
    require runtime "the transition rehearsal failed" $
      inWorktree (invocation "scripts/release-rehearse.sh" [revision', T.unpack previous, "--run", rehearsalWork])
        & #environment
        .~ Extended [("NAGARE_RELEASE_REHEARSAL_RECORD", run </> "transition-rehearsal.json")]
    rehearsed <- doesFileExist (run </> "transition-rehearsal.json")
    unless rehearsed (refuse ("release-rehearse left no " <> T.pack (run </> "transition-rehearsal.json")))
    setRecord index "transitionRehearsal" (run </> "transition-rehearsal.json")
    let record = "docs/release-evidence/" <> revision' <> "/transition-rehearsal.json"
    -- 3. aarch64-darwin attachments, from the candidate's worktree
    phase "aarch64-darwin" "aarch64-darwin attachments"
    require runtime "the aarch64-darwin attachments failed" (inWorktree (invocation "scripts/release-native.sh" [T.unpack version', run </> "native/aarch64-darwin"]))
    -- 4. x86_64-linux attachments, in an amd64 Apple container under Rosetta.
    -- The work root is the container's only mount and persists across
    -- releases, so the file cache of builder outputs is reused.
    phase "x86_64-linux-outputs" "x86_64-linux outputs on the builder"
    let work = state </> "x86-work"
        flake = "git+file://" <> repo <> "?rev=" <> revision'
    createDirectoryIfMissing True (work </> "cache")
    outputs <- forM ["nagarectl", "nagare", "nagare-platform", "release-tools"] $ \package ->
      T.unpack <$> captureText runtime ("the x86_64-linux " <> T.pack package <> " build failed") ((invocation "nix" ["build", "--no-link", "--print-out-paths", "--max-jobs", "0", flake <> "#packages.x86_64-linux." <> package]))
    require runtime "nix copy to the work cache failed" ((invocation "nix" (["copy", "--to", "file://" <> work </> "cache"] <> outputs)))
    removePathForcibly (work </> "out")
    removePathForcibly (work </> "candidate.bundle")
    require runtime "git bundle failed" (git ["-C", worktree, "bundle", "create", "-q", work </> "candidate.bundle", "HEAD"])
    copyFile (worktree </> "scripts/release-native-container.sh") (work </> "release-native-container.sh")
    phase "x86_64-linux" "x86_64-linux attachments"
    running <- succeeds runtime (invocation "container" ["system", "status"] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
    unless running (require runtime "container system start failed" (invocation "container" ["system", "start"]))
    -- Apple container starts processes with HOME=/, so nix profile would
    -- install off PATH.
    require runtime "the x86_64-linux attachments failed" $
      invocation "container" ["run", "--rm", "--platform", "linux/amd64", "--rosetta", "-c", "4", "-m", "16G", "-e", "HOME=/root", "-v", work <> ":/work", image, "bash", "/work/release-native-container.sh", revision', T.unpack version']
    createDirectoryIfMissing True (run </> "native")
    require runtime "copying the x86_64-linux attachments failed" (invocation "cp" ["-R", work </> "out/x86_64-linux", run </> "native/x86_64-linux"])
    -- 5. assemble twice and compare
    phase "assembly" "assembly"
    forM_ ["dist", "dist-again"] $ \dist ->
      require runtime ("assembly into " <> T.pack (run </> dist) <> " failed") $
        invocation (worktree </> "scripts/assemble-release.sh") ["--version", T.unpack version', "--input-root", run </> "native", "--transition-rehearsal", run </> "transition-rehearsal.json", "--output-dir", run </> dist]
    require runtime ("the two assemblies differ: " <> T.pack (run </> "dist") <> " " <> T.pack (run </> "dist-again")) (invocation "diff" ["-r", run </> "dist", run </> "dist-again"] & #stdoutTo .~ Discard)
    require runtime ("SHA256SUMS does not verify in " <> T.pack (run </> "dist")) (invocation "shasum" ["-a", "256", "-c", "SHA256SUMS"] & #directory ?~ run </> "dist" & #stdoutTo .~ Discard)
    writeSorted True (run </> "candidate.json") (toJSON (CandidateRecord {previous = previous, revision = rev, version = version'}))
    setRecord index "candidate" (run </> "candidate.json")
    setRecord index "dist" (run </> "dist")
    phase "gate-wait" "waiting for the release gate"
    gateExit <- gate ^. #finished
    endStep index "gate" (gateExit == 0)
    unless (gateExit == 0) (refuse ("the release gate failed: " <> T.pack (run </> "gate-release.log")))
    gateLog <- TE.decodeUtf8With TE.lenientDecode <$> BS.readFile (run </> "gate-release.log")
    (runtime ^. #say) (lastLines 1 gateLog)
    if rehearsal'
      then step runtime ("rehearsal complete; nothing landed and the intranet is untouched. Attachments in " <> T.pack (run </> "dist") <> ", the rehearsal record in " <> T.pack run)
      else do
        -- 6. the intranet on the candidate; release-publish requires its record
        phase "intranet" "the intranet"
        setChild index "intranet" (run </> "intranet-index.json")
        require runtime "the intranet move failed" (invocation (worktree </> "scripts/release-intranet.sh") [T.unpack version', "--run", run])
        -- 7. land the rehearsal record on origin/master (never part of the
        -- candidate itself). Fetch again: the operator may have landed during
        -- the run, and the record must go on top.
        phase "record" "rehearsal record"
        require runtime "git fetch failed" ((git ["fetch", "-q", "origin", "master"]))
        held <- succeeds runtime ((git ["cat-file", "-e", "origin/master:" <> record]) & #stderrTo .~ Discard)
        if held
          then do
            landed <- capture runtime "git show failed" ((git ["show", "origin/master:" <> record]))
            ours <- BS.readFile (run </> "transition-rehearsal.json")
            unless (landed == ours) (refuse ("origin/master already holds a different " <> T.pack record))
          else do
            require runtime "git worktree add failed" ((git ["worktree", "add", "-q", "--detach", evidence, "origin/master"]))
            createDirectoryIfMissing True (evidence </> takeDirectory record)
            copyFile (run </> "transition-rehearsal.json") (evidence </> record)
            require runtime "git add of the rehearsal record failed" (git ["-C", evidence, "add", "--", record])
            require runtime "the rehearsal record commit failed" $
              git
                [ "-C"
                , evidence
                , "commit"
                , "-q"
                , "-m"
                , "docs(release): record the v" <> T.unpack version' <> " transition rehearsal"
                , "-m"
                , "Moved a disposable local context from v" <> T.unpack previous <> " to the candidate " <> revision' <> "; the seeded row read back unchanged."
                ]
            require runtime "just land failed" (invocation "just" ["land", "HEAD"] & #directory ?~ evidence)
        let latest = state </> ("v" <> T.unpack version') </> "latest"
        removePathForcibly latest
        createDirectoryLink run latest
        step runtime ("v" <> version' <> " is ready to publish: just release-publish " <> version')
