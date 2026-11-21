-- | A release's upgrade rehearsal (EP-172) as one unattended command (MP-26
-- item 12, ported by EP-229).
--
-- It builds the previous release's packaged nagarectl (the published tag)
-- and the candidate's, then runs the transition drill
-- ("Nagare.Harness.Release.TransitionDrill") on a disposable local context, on
-- a Colima profile this run creates and deletes (MasterPlan 37 D3), or on the
-- empty daemon @NAGARE_REHEARSAL_DOCKER_HOST@ names, which it never deletes.
-- It writes the record a release binds to
-- @docs/release-evidence/<rev>/transition-rehearsal.json@, uncommitted, or to
-- @NAGARE_RELEASE_REHEARSAL_RECORD@ (the candidate run's directory). An
-- existing record is kept: only a green run writes one.
--
-- Both CLIs are nix packages with every guard on. The drill runs from an
-- empty environment whose PATH holds only the operator tools below and no
-- Helm, so the candidate must bring the tools it pins (F123). The source
-- release gets nixpkgs' Helm from its own lock, as the installed release had
-- on the intranet.
module Nagare.Harness.Release.Rehearse
  ( RehearseOptions (..)
  , transitionRehearse
  , rehearsalTools
  , rehearsalProfile
  )
where

import Control.Exception (finally)
import Control.Monad (filterM)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (defaultTimeLocale, formatTime)
import Nagare.Contract.V1 (VersionInfo (..))
import Nagare.Harness.Prelude
import Nagare.Harness.Release.Images (readReleaseImages)
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Records
import Nagare.Harness.Release.RunIndex
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesPathExist, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath (takeDirectory, (</>))

data RehearseOptions = RehearseOptions
  { revision :: !Text
  , previous :: !Text
  , run :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

-- | The Colima profile a run creates, named by its start time; only this
-- run deletes it.
rehearsalProfile :: Text -> String
rehearsalProfile stamp = "nagare-rehearsal-" <> T.unpack stamp

-- | The @docker_socket@ of @colima status --json@.
colimaSocket :: Value -> Either Text Text
colimaSocket = first (\reason -> "colima status --json: " <> T.pack reason) . parseEither (withObject "colima status" (.: "docker_socket"))

-- | The empty daemon @NAGARE_REHEARSAL_DOCKER_HOST@ names, or a Colima
-- profile created for this run and deleted after it, whatever the outcome.
-- The drill refuses a daemon that already holds a k3d cluster.
withDaemon :: Runtime -> (String -> IO a) -> IO a
withDaemon runtime action = case lookupVariable runtime "NAGARE_REHEARSAL_DOCKER_HOST" of
  Just daemon -> action daemon
  Nothing -> do
    stamp <- T.pack . formatTime defaultTimeLocale "%Y%m%d%H%M%S" <$> runtime ^. #now
    let profile = rehearsalProfile stamp
        delete' = invoke runtime (invocation "colima" ["delete", "-p", profile, "--force", "--data"] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
    note runtime ("creating the Colima profile " <> T.pack profile <> "; this run deletes it")
    flip finally delete' $ do
      -- resolvers that answer: a fresh VM's 192.168.5.3 does not
      require runtime ("colima could not start " <> T.pack profile) $
        invocation "colima" ["start", "-p", profile, "--activate=false", "--cpus", "6", "--memory", "12", "--disk", "100", "--dns", "1.1.1.1", "--dns", "8.8.8.8"]
      status <- capture runtime ("colima status -p " <> T.pack profile <> " failed") (invocation "colima" ["status", "-p", profile, "--json"] & #stderrTo .~ Discard)
      daemon <- either refuse (pure . T.unpack) (decodeDocument @Value "colima status --json" status >>= colimaSocket)
      action daemon

-- | The nixpkgs tools on the drill's PATH, from the candidate's lock.
rehearsalTools :: [String]
rehearsalTools =
  ["bash", "coreutils", "findutils", "gnugrep", "gnused", "gawk", "gnutar", "gzip", "curl", "git", "openssl", "jq", "docker-client", "k3d", "kubectl", "sops", "age", "skopeo", "socat"]

note :: Runtime -> Text -> IO ()
note runtime message = do
  moment <- runtime ^. #now
  (runtime ^. #say) (stampedLine "%H:%M:%S" moment "release-rehearse" message)

transitionRehearse :: Runtime -> RehearseOptions -> IO ()
transitionRehearse runtime options = do
  repo <- T.unpack <$> captureText runtime "not in a git repository" (invocation "git" ["rev-parse", "--show-toplevel"])
  rev <- captureText runtime ("no commit " <> options ^. #revision) (invocation "git" ["-C", repo, "rev-parse", "--verify", T.unpack (options ^. #revision) <> "^{commit}"])
  let prev = fromMaybe (options ^. #previous) (T.stripPrefix "v" (options ^. #previous))
      record = fromMaybe (repo </> "docs/release-evidence" </> T.unpack rev </> "transition-rehearsal.json") (lookupVariable runtime "NAGARE_RELEASE_REHEARSAL_RECORD")
      notAMove = T.pack record <> " does not record a move from " <> prev <> " to " <> rev
      checkRecord path = do
        found <- readDocument @RehearsalCheck path
        unless (either (const False) (rehearsalMatches rev prev) found) (refuse (either (\reason -> notAMove <> ": " <> reason) (const notAMove) found))
  existing <- doesPathExist record
  if existing
    then do
      checkRecord record
      note runtime ("record exists: " <> T.pack record)
    else do
      work <- case options ^. #run of
        Just directory -> createDirectoryIfMissing True directory >> pure directory
        Nothing -> T.unpack <$> captureText runtime "mktemp failed" (invocation "mktemp" ["-d", "/private/tmp/nagare-release-rehearse.XXXXXX"])
      started <- runtime ^. #now
      index <-
        openIndex runtime (work </> "index.json") $
          newRunIndex "rehearsal" "local-rehearsal" started
            & #candidate
            .~ Revisioned Nothing (Just rev)
            & #source
            .~ Revisioned (Just prev) Nothing
      withRunIndex index (rehearseIn runtime index repo rev prev work record checkRecord)

-- | The rehearsal proper, in its work directory: both CLIs and the tool
-- PATH, then the drill on its daemon.
rehearseIn :: Runtime -> IndexWriter -> FilePath -> Text -> Text -> FilePath -> FilePath -> (FilePath -> IO ()) -> IO ()
rehearseIn runtime index repo rev prev work record checkRecord = do
  let home = fromMaybe "" (lookupVariable runtime "HOME")
  note runtime ("work " <> T.pack work <> "; candidate " <> rev <> "; source v" <> prev)
  -- the two packaged CLIs and the operator tools
  let sourceFlake = "github:shinzui/nagare/v" <> T.unpack prev
      candidateFlake = "git+file://" <> repo <> "?rev=" <> T.unpack rev
      build what = T.unpack <$> captureText runtime ("nix build " <> T.pack (unwords what) <> " failed") (invocation "nix" (["build", "--no-link", "--print-out-paths"] <> what))
  sourceCli <- build [sourceFlake <> "#nagarectl"]
  candidateCli <- build [candidateFlake <> "#nagarectl"]
  sourceHelm <- build ["--inputs-from", sourceFlake, "nixpkgs#kubernetes-helm"]
  tools <- build (["--inputs-from", candidateFlake] <> map ("nixpkgs#" <>) rehearsalTools)
  withBin <- filterM (\out -> doesDirectoryExist (out </> "bin")) (words tools)
  let toolPath = T.unpack (T.intercalate ":" (map (T.pack . (</> "bin")) withBin)) <> ":/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  helm <- searchPath toolPath "helm"
  when (isJust helm) (refuse "the rehearsal PATH carries a helm; the candidate must bring its own")
  identity <- capture runtime "the candidate nagarectl has no version" (invocation (candidateCli </> "bin/nagarectl") ["version", "--json"])
  let got = either (const Nothing) (^. #revision) (decodeDocument @VersionInfo "version --json" identity)
  unless (got == Just rev) (refuse ("the candidate nagarectl reports revision " <> fromMaybe "None" got <> ", not " <> rev))
  setChild index "drill" (work </> "run/index.json")
  createDirectoryIfMissing True (work </> "bin")
  let wrapper = work </> "bin/source-nagarectl"
  BS.writeFile wrapper (TE.encodeUtf8 (T.pack ("#!/bin/sh\nPATH=" <> sourceHelm <> "/bin:$PATH exec " <> sourceCli <> "/bin/nagarectl \"$@\"\n")))
  getPermissions wrapper >>= setPermissions wrapper . setOwnerExecutable True
  -- EP-237: both releases run the service images they name; the drill pins
  -- none of them, so a release that names none cannot be rehearsed.
  forM_ [("the candidate " <> rev, T.unpack rev), ("v" <> prev, "v" <> T.unpack prev)] $ \(release', ref) -> do
    bytes <- capture runtime ("no release.json at " <> release') (invocation "git" ["-C", repo, "show", ref <> ":release.json"])
    images <- either refuse pure (readReleaseImages bytes)
    when (isNothing images) (refuse (release' <> " names no service images in release.json; a rehearsal needs releases from 0.21.0 on"))
  -- the drill, from an empty environment (no direnv context, payload
  -- root or kubeconfig)
  let user = fromMaybe "" (lookupVariable runtime "USER")
  withDaemon runtime $ \daemon ->
    require runtime "the transition rehearsal failed" $
      invocation (runtime ^. #harness) ["transition", "drill"]
        & #environment
        .~ Exactly
          ( [ ("HOME", home)
            , ("USER", user)
            , ("LOGNAME", fromMaybe user (lookupVariable runtime "LOGNAME"))
            , ("TMPDIR", fromMaybe "/tmp" (lookupVariable runtime "TMPDIR"))
            , ("PATH", toolPath)
            , ("DOCKER_HOST", daemon)
            , ("NAGARE_REHEARSAL_SOURCE", wrapper)
            , ("NAGARE_REHEARSAL_TARGET", candidateCli </> "bin/nagarectl")
            , ("NAGARE_REHEARSAL_ROOT", work </> "run")
            , ("NAGARE_REHEARSAL_IMAGES", repo </> "scripts/publish-local-minio-images.sh")
            ]
          )
        & #stdoutTo
        .~ Tee (work </> "rehearsal.log")
        & #stderrTo
        .~ SameAsStdout
  let written = work </> "run/evidence/transition-rehearsal.json"
  checkRecord written
  createDirectoryIfMissing True (takeDirectory record)
  copyFile written record
  setRecord index "transitionRehearsal" record
  note runtime ("transition rehearsal OK: " <> T.pack record)
