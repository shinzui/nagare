-- | A release's upgrade rehearsal (EP-172) as one unattended command (MP-26
-- item 12, ported by EP-229).
--
-- It builds the previous release's packaged nagarectl (the published tag)
-- and the candidate's, then runs the transition drill
-- ("Nagare.Harness.Release.TransitionDrill") on a disposable local context in
-- the Colima profile @nagare-mp23@, and writes the record a release binds to
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
  , colimaProfile
  )
where

import Control.Monad (filterM)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.V1 (VersionInfo (..))
import Nagare.Harness.Prelude
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

colimaProfile :: String
colimaProfile = "nagare-mp23"

-- | The nixpkgs tools on the drill's PATH, from the candidate's lock.
rehearsalTools :: [String]
rehearsalTools =
  ["bash", "coreutils", "findutils", "gnugrep", "gnused", "gawk", "gnutar", "gzip", "curl", "git", "openssl", "jq", "python3", "docker-client", "k3d", "kubectl", "sops", "age", "skopeo", "socat"]

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

-- | The rehearsal proper, in its work directory.
rehearseIn :: Runtime -> IndexWriter -> FilePath -> Text -> Text -> FilePath -> FilePath -> (FilePath -> IO ()) -> IO ()
rehearseIn runtime index repo rev prev work record checkRecord = do
  let home = fromMaybe "" (lookupVariable runtime "HOME")
      socket = home </> ".colima" </> colimaProfile </> "docker.sock"
  note runtime ("work " <> T.pack work <> "; candidate " <> rev <> "; source v" <> prev)
  -- the Colima colimaProfile, and a VM resolver that answers (a fresh VM's
  -- 192.168.5.3 does not)
  up <- succeeds runtime (invocation "colima" ["status", "-p", colimaProfile] & #stdoutTo .~ Discard & #stderrTo .~ Discard)
  unless up (require runtime ("colima could not start " <> T.pack colimaProfile) (invocation "colima" ["start", "-p", colimaProfile, "--activate=false"]))
  require runtime "the VM resolver could not be written" $
    invocation "colima" ["ssh", "-p", colimaProfile, "--", "sudo", "tee", "/etc/resolv.conf"]
      & #input
      ?~ "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
      & #stdoutTo
      .~ Discard
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
  -- the drill, from an empty environment (no direnv context, payload
  -- root or kubeconfig)
  let user = fromMaybe "" (lookupVariable runtime "USER")
  require runtime "the transition rehearsal failed" $
    invocation (runtime ^. #harness) ["transition", "drill"]
      & #environment
      .~ Exactly
        [ ("HOME", home)
        , ("USER", user)
        , ("LOGNAME", fromMaybe user (lookupVariable runtime "LOGNAME"))
        , ("TMPDIR", fromMaybe "/tmp" (lookupVariable runtime "TMPDIR"))
        , ("PATH", toolPath)
        , ("DOCKER_HOST", "unix://" <> socket)
        , ("NAGARE_REHEARSAL_SOURCE", wrapper)
        , ("NAGARE_REHEARSAL_TARGET", candidateCli </> "bin/nagarectl")
        , ("NAGARE_REHEARSAL_ROOT", work </> "run")
        , ("NAGARE_REHEARSAL_RESET", "1")
        ]
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
