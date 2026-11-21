-- | Publish the run @just release-candidate VERSION@ left ready (MP-26 item
-- 11; MasterPlan 37 D3 ported it from @scripts/release-publish.sh@;
-- docs/runbooks/releases.md). A release is a signed tag, its notes and the
-- rehearsal record bound to its candidate.
--
-- Every proof is checked before anything leaves the machine: the run names
-- this version, its candidate is on origin/master, the previous release it
-- moved from is a published tag the candidate's release.json accepts, the
-- rehearsal record moved that release to this candidate and read its seeded
-- row back, and the intranet record shows the context exact on the candidate.
-- The tag is then signed locally and the candidate's own CLI reviews the
-- assets from a checkout of it, which validates the rehearsal record against
-- that release.json. Only then is the tag pushed and the release published.
-- A rerun accepts the tag it already made; the only retry is the publisher's
-- "created draft is not yet visible".
module Nagare.Harness.Release.Publish
  ( PublishOptions (..)
  , releasePublish
  , assetNames
  )
where

import Control.Exception (finally)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Candidate (candidateRun, notesTitled, validVersion)
import Nagare.Harness.Release.Images (pinReleaseImages, readReleaseImages)
import Nagare.Harness.Release.Intranet (IntranetOptions (..), transitionPinTag)
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removePathForcibly)
import System.FilePath ((</>))

data PublishOptions = PublishOptions
  { version :: !Text
  , run :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

repository :: Text
repository = "shinzui/nagare"

draftAttempts :: Int
draftAttempts = 5

-- | The notes and the rehearsal record, as the publisher names them.
assetNames :: Text -> (FilePath, FilePath)
assetNames version' = ("nagare-v" <> T.unpack version' <> ".md", "nagare-transition-rehearsal-v" <> T.unpack version' <> ".json")

step :: Runtime -> Text -> IO ()
step runtime message = do
  moment <- runtime ^. #now
  (runtime ^. #say) (stampedLine "%H:%M:%SZ" moment "release-publish" message)

-- | The run to publish: the one named, the tagged commit's, or the only run
-- of this version whose intranet record exists.
locateRun :: Runtime -> Text -> Maybe FilePath -> IO FilePath
locateRun runtime version' named = case named of
  Just path -> pure path
  Nothing -> do
    let releases = stateDirectory runtime </> "nagare/releases" </> ("v" <> T.unpack version')
    tagged <- invoke runtime (invocation "git" ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack version' <> "^{commit}"] & #stdoutTo .~ Capture & #stderrTo .~ Discard)
    if tagged ^. #exit == 0
      then pure (candidateRun (stateDirectory runtime) version' False (trimEnd (lenient (tagged ^. #output))))
      else do
        present <- doesDirectoryExist releases
        names <- if present then sort <$> listDirectory releases else pure []
        moved <- filterIO (\name -> doesFileExist (releases </> name </> "intranet.json")) [name | name <- names, not ("rehearsal-" `T.isPrefixOf` T.pack name)]
        case moved of
          [one] -> pure (releases </> one)
          [] -> refuse ("no run of " <> version' <> " under " <> T.pack releases <> " has moved the intranet; run just release-candidate " <> version')
          many -> refuse ("several runs of " <> version' <> " moved the intranet (" <> T.intercalate ", " (map T.pack many) <> "); name one with --run DIR")

releasePublish :: Runtime -> PublishOptions -> IO ()
releasePublish outer options = do
  let version' = options ^. #version
      tag = "v" <> version'
      git arguments' = invocation "git" arguments'
  unless (validVersion version') (refuse "VERSION must be an unpadded major.minor.patch version")
  repo <- T.unpack <$> captureText outer "not in a git repository" (git ["rev-parse", "--show-toplevel"])
  let runtime = runningIn repo outer
  run' <- locateRun runtime version' (options ^. #run)
  -- 1. every proof, before anything is written
  candidate <- readDocument @CandidateRecord (run' </> "candidate.json") >>= either (\reason -> refuse ("no candidate run at " <> T.pack run' <> ": " <> reason)) pure
  unless (candidate ^. #version == version') (refuse (T.pack run' <> " is not a run for " <> version'))
  let rev = candidate ^. #revision
      previous = candidate ^. #previous
  intranet <- readDocument @IntranetCheck (run' </> "intranet.json")
  unless (either (const False) (intranetOn version' rev) intranet) $
    refuse ("no intranet record for " <> version' <> " at " <> rev <> " in " <> T.pack run' <> "; run just release-candidate " <> version')
  require runtime "git fetch failed" (git ["fetch", "-q", "origin", "master", "--tags"])
  require runtime (rev <> " is not on origin/master") (git ["merge-base", "--is-ancestor", T.unpack rev, "origin/master"])
  metadataBytes <- capture runtime ("no release.json at " <> rev) (git ["show", T.unpack rev <> ":release.json"])
  metadata <- either refuse pure (decodeDocument @ReleaseMetadata "release.json" metadataBytes)
  unless (metadata ^. #platformVersion == version') (refuse ("release.json at " <> rev <> " is not " <> version'))
  unless (previous `elem` metadata ^. #transitionsFrom) (refuse ("release.json at " <> rev <> " does not accept a transition from " <> previous))
  require runtime ("v" <> previous <> ", the release the rehearsal moved from, is not a published tag") (git ["rev-parse", "-q", "--verify", "refs/tags/v" <> T.unpack previous] & #stdoutTo .~ Discard)
  let rehearsed = run' </> "transition-rehearsal.json"
  rehearsal <- doesFileExist rehearsed >>= \present -> if present then readDocument @RehearsalCheck rehearsed else pure (Left "missing")
  unless (either (const False) (rehearsalMatches rev previous) rehearsal) $
    refuse ("no rehearsal record of a move from " <> previous <> " to " <> rev <> " in " <> T.pack run')
  let notesPath = "docs/releases/" <> T.unpack tag <> ".md"
  notes <- capture runtime ("no " <> T.pack notesPath <> " at " <> rev) (git ["show", T.unpack rev <> ":" <> notesPath])
  unless (notesTitled version' (TE.decodeUtf8With TE.lenientDecode notes)) (refuse (T.pack notesPath <> " does not begin # Nagare " <> version'))
  key <- maybe (pure (fromMaybe "" (lookupVariable runtime "HOME") </> ".ssh/id_ed25519.pub")) pure (lookupVariable runtime "NAGARE_RELEASE_SIGNING_KEY")
  keyPresent <- doesFileExist key
  unless keyPresent (refuse ("no SSH signing key at " <> T.pack key <> "; set NAGARE_RELEASE_SIGNING_KEY"))
  let assets = run' </> "assets"
      (notesName, rehearsalName) = assetNames version'
  removePathForcibly assets
  createDirectoryIfMissing True assets
  BS.writeFile (assets </> notesName) notes
  BS.readFile rehearsed >>= BS.writeFile (assets </> rehearsalName)
  -- EP-237: keep a released image in the binary cache for as long as the
  -- release exists.
  images <- either refuse pure (readReleaseImages metadataBytes)
  forM_ images (pinReleaseImages runtime version')
  -- 2. the signed tag, locally
  email <- captureText runtime "git config user.email failed" (git ["config", "user.email"])
  keyText <- trimEnd . lenient <$> BS.readFile key
  let signers = run' </> "allowed-signers"
      publish = run' </> "publish"
      removePublish = invoke runtime (git ["worktree", "remove", "--force", publish] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
  BS.writeFile signers (TE.encodeUtf8 (email <> " " <> keyText <> "\n"))
  tagged <- succeeds runtime (git ["rev-parse", "-q", "--verify", "refs/tags/" <> T.unpack tag] & #stdoutTo .~ Discard)
  if tagged
    then step runtime (tag <> " exists; checking it")
    else do
      step runtime ("signing " <> tag <> " on " <> rev)
      require runtime ("signing " <> tag <> " failed") (git ["-c", "gpg.format=ssh", "-c", "user.signingkey=" <> key, "tag", "-s", T.unpack tag, "-m", "Nagare " <> T.unpack tag, T.unpack rev])
  kind <- captureText runtime "git cat-file failed" (git ["cat-file", "-t", "refs/tags/" <> T.unpack tag])
  unless (kind == "tag") (refuse (tag <> " is not an annotated tag"))
  target <- captureText runtime "git rev-parse failed" (git ["rev-parse", "refs/tags/" <> T.unpack tag <> "^{commit}"])
  unless (target == rev) (refuse (tag <> " does not resolve to the candidate " <> rev))
  require runtime (tag <> " has no good signature by " <> T.pack key) (git ["-c", "gpg.ssh.allowedSignersFile=" <> signers, "tag", "-v", T.unpack tag] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
  flip finally removePublish $ do
    -- 3. the candidate's own CLI reviews the assets from a checkout of the tag
    void removePublish
    require runtime "git worktree add failed" (git ["worktree", "add", "-q", "--detach", publish, T.unpack tag])
    cliOut <- captureText runtime "the candidate nagarectl did not build" (invocation "nix" ["build", "--no-link", "--print-out-paths", "git+file://" <> repo <> "?rev=" <> T.unpack rev <> "#nagarectl"])
    let cli = T.unpack cliOut </> "bin/nagarectl"
        publisher extra = invocation cli (["release", "publish", "--repo", T.unpack repository, "--version", T.unpack version', "--assets", assets] <> extra) & #directory ?~ publish
        logFile = run' </> "publish.log"
    require runtime ("the candidate nagarectl refuses the release assets; see " <> T.pack logFile) (publisher [] & #stdoutTo .~ WriteTo logFile & #stderrTo .~ SameAsStdout)
    -- 4. push only the tag
    object' <- captureText runtime "git rev-parse failed" (git ["rev-parse", "refs/tags/" <> T.unpack tag])
    remote <- T.takeWhile (/= '\t') <$> captureText runtime "git ls-remote failed" (git ["ls-remote", "origin", "refs/tags/" <> T.unpack tag])
    if T.null remote
      then step runtime ("pushing " <> tag) >> require runtime ("pushing " <> tag <> " failed") (git ["push", "origin", "refs/tags/" <> T.unpack tag])
      else do
        unless (remote == object') (refuse ("origin holds a different " <> tag <> " (" <> remote <> "); never move a published tag"))
        step runtime (tag <> " is already on origin")
    -- 5. publish these exact bytes
    step runtime ("publishing " <> tag)
    let attempt n = do
          published <- invoke runtime (publisher ["--yes"] & #stdoutTo .~ Tee logFile & #stderrTo .~ SameAsStdout)
          unless (published ^. #exit == 0) $ do
            logged <- lenient <$> BS.readFile logFile
            unless ("created draft is not yet visible" `T.isInfixOf` logged) (refuse ("publication failed; see " <> T.pack logFile))
            when (n >= draftAttempts) (refuse ("the draft was still not visible after " <> T.pack (show draftAttempts) <> " attempts; rerun just release-publish " <> version'))
            step runtime ("the created draft is not yet visible; publishing again (attempt " <> T.pack (show (n + 1)) <> ")")
            (runtime ^. #pause) 15
            attempt (n + 1)
    attempt (1 :: Int)
  -- 6. the public flake
  step runtime ("checking github:" <> repository <> "/" <> tag)
  identity <- capture runtime ("github:" <> repository <> "/" <> tag <> "#nagarectl did not run") (invocation "nix" ["run", "--refresh", "github:" <> T.unpack repository <> "/" <> T.unpack tag <> "#nagarectl", "--", "version", "--json"])
  case decodeDocument @ReleaseIdentity "version --json" identity of
    Right found | found ^. #version == Just version' && found ^. #revision == Just rev -> pure ()
    _ -> refuse ("github:" <> repository <> "/" <> tag <> "#nagarectl does not report " <> version' <> " at " <> rev)
  -- 7. the operator repository names the tag instead of the revision
  transitionPinTag runtime (IntranetOptions version' (Just run') Nothing (Just rev))
  step runtime (tag <> " is published")

lenient :: BS.ByteString -> Text
lenient = TE.decodeUtf8With TE.lenientDecode

filterIO :: (a -> IO Bool) -> [a] -> IO [a]
filterIO keep = fmap concat . mapM (\item -> (\kept -> [item | kept]) <$> keep item)
