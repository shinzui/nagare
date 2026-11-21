{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | The release candidate and its publication interpreted with the recording
-- fake transport (ReleaseFake). MasterPlan 37 D3: a candidate run belongs to
-- one version and revision, a rerun keeps the steps it finished, and
-- publication checks every proof before anything leaves the machine.
module ReleaseCandidateSpec (candidateTests, publishTests) where

import Data.Aeson (Value, eitherDecodeFileStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Data.Text qualified as T
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Candidate
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Publish
import ReleaseFake
import ReleaseImagesSpec (digestFor, fixtureImages, imageKeys, storePathFor)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

-- * release candidate (scripts/release-candidate.sh)

-- | What the candidate world answers differently per test.
data Knobs = Knobs
  { images :: !Bool
  , pinned :: !Text
  , gateRecord :: !Bool
  , intranetPasses :: !Bool
  , notes :: !Text
  }
  deriving stock (Generic)

calm :: Knobs
calm = Knobs {images = False, pinned = "", gateRecord = True, intranetPasses = True, notes = "# Nagare 9.8.7\n\nNotes.\n"}

metadataFor :: Bool -> Text
metadataFor images' = encodeText (object (["platformVersion" .= version', "supportedSystems" .= ["x86_64-linux", "aarch64-darwin" :: Text], "transitionsFrom" .= ["9.8.5", "9.8.6", "9.10.0" :: Text]] <> ["releaseImages" .= fixtureImages | images']))

candidateWorld :: FilePath -> Knobs -> IO Responder
candidateWorld root' knobs = do
  gateRan <- newIORef False
  let repo = root' </> "repo"
      ok out = pure (0, out)
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack repo <> "\n")
    ("git", ["rev-parse", "--verify", "HEAD^{commit}"]) -> ok (rev <> "\n")
    ("git", ["show", ref])
      | ":release.json" `isSuffixOf` ref -> ok (metadataFor (knobs ^. #images))
      | otherwise -> ok (knobs ^. #notes)
    ("direnv", "exec" : _ : "sh" : _) -> ok (knobs ^. #pinned)
    ("cat", [path]) | "/digest" `isSuffixOf` path -> ok (digestFor 'a' <> "\n")
    ("git", ["rev-parse", "-q", "--verify", tagRef]) -> pure (if tagRef == "refs/tags/v9.10.0" then 0 else 1, "")
    ("git", ["worktree", "add", "-q", "--detach", tree, _]) -> createDirectoryIfMissing True (tree </> "scripts") >> ok ""
    ("just", ["gate-verify", _]) -> (\ran -> (if knobs ^. #gateRecord || ran then 0 else 1, "")) <$> readIORef gateRan
    ("just", ["gate", _]) -> modifyIORef' gateRan (const True) >> ok "gate: full gate green\n"
    ("mktemp", _) -> ok (T.pack (root' </> "rehearse-work") <> "\n")
    ("scripts/release-rehearse.sh", _) -> case command ^. #environment of
      Extended [("NAGARE_RELEASE_REHEARSAL_RECORD", path)] -> BL.writeFile path (Aeson.encode (rehearsalRecord rev "9.10.0")) >> ok ""
      other -> assertFailure ("rehearse without its record path: " <> show other) >> pure (1, "")
    (program', _) | "/scripts/release-intranet.sh" `isSuffixOf` program' -> pure (if knobs ^. #intranetPasses then 0 else 1, "")
    ("nix", "build" : rest) -> ok ("/nix/store/out-" <> T.takeWhileEnd (/= '.') (T.pack (last rest)) <> "\n")
    _ -> ok ""

runOf :: Bool -> String
runOf rehearsal' = "$T/state/nagare/releases/v9.8.7/" <> (if rehearsal' then "rehearsal-" else "") <> T.unpack rev

candidateOrder :: Bool -> [String]
candidateOrder rehearsal' =
  [ "git rev-parse --show-toplevel"
  , "git rev-parse --verify HEAD^{commit}"
  , "git show " <> T.unpack rev <> ":release.json"
  , "git show " <> T.unpack rev <> ":docs/releases/v9.8.7.md"
  , "git fetch -q origin master --tags"
  , "git merge-base --is-ancestor " <> T.unpack rev <> " origin/master"
  ]
    <> ["git rev-parse -q --verify refs/tags/v9.8.7" | not rehearsal']
    <> [ "git rev-parse -q --verify refs/tags/v9.10.0"
       , "git -C $T/repo worktree remove --force " <> run' <> "/worktree"
       , "git worktree add -q --detach " <> run' <> "/worktree " <> T.unpack rev
       , "just gate-verify " <> T.unpack rev
       , "mktemp -d /private/tmp/nagare-release-rehearse.XXXXXX"
       , "scripts/release-rehearse.sh " <> T.unpack rev <> " 9.10.0 --run $T/rehearse-work"
       ]
    <> [run' <> "/worktree/scripts/release-intranet.sh 9.8.7 --run " <> run' | not rehearsal']
    <> ["git -C $T/repo worktree remove --force " <> run' <> "/worktree"]
  where
    run' = runOf rehearsal'

stepsOf :: Value -> [(Maybe Value, Maybe Value)]
stepsOf index = [(fieldAt entry ["name"], fieldAt entry ["status"]) | Just (Aeson.Array entries) <- [fieldAt index ["steps"]], entry <- toList entries]

candidateTests :: TestTree
candidateTests =
  testGroup
    "release candidate"
    [ testCase "--rehearsal binds its run first, keeps the landed gate record, rehearses in the worktree and leaves the intranet alone" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root' calm
          releaseCandidate runtime (CandidateOptions version' "HEAD" True Nothing)
          calls' <- recorded world
          rendered root' calls' @?= candidateOrder True
          let runDir = root' </> "state/nagare/releases/v9.8.7/rehearsal-" <> T.unpack rev
          [call ^. #directory | call <- calls', call ^. #program `elem` ["just", "scripts/release-rehearse.sh"]] @?= replicate 2 (Just (runDir </> "worktree"))
          candidate <- eitherDecodeFileStrict @Value (runDir </> "candidate.json") >>= either fail pure
          candidate @?= object ["version" .= version', "revision" .= rev, "previous" .= ("9.10.0" :: Text)]
          assertBool "a candidate wrote a latest link" . not =<< doesPathExist (root' </> "state/nagare/releases/v9.8.7/latest")
    , testCase "a candidate moves the intranet from its worktree and indexes every step" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root' calm
          releaseCandidate runtime (CandidateOptions version' "HEAD" False Nothing)
          rendered root' <$> recorded world >>= (@?= candidateOrder False)
          index <- eitherDecodeFileStrict @Value (root' </> "state/nagare/releases/v9.8.7" </> T.unpack rev </> "index.json") >>= either fail pure
          fieldAt index ["status"] @?= Just (Aeson.String "passed")
          fieldAt index ["records"] @?= Just (object ["candidate" .= ("candidate.json" :: Text), "intranet" .= ("intranet.json" :: Text), "transitionRehearsal" .= ("transition-rehearsal.json" :: Text)])
          stepsOf index @?= [(Just "worktree", Just "passed"), (Just "gate", Just "kept"), (Just "rehearsal", Just "passed"), (Just "intranet", Just "passed")]
    , testCase "a rerun after the intranet step stopped runs only the intranet again; the rehearsal ran once (MasterPlan 37 D3)" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless
          (stopped, _) <- fake environment' =<< candidateWorld root' (calm & #intranetPasses .~ False)
          refused (releaseCandidate stopped (CandidateOptions version' "HEAD" False Nothing)) >>= assertMentions "the intranet move failed"
          (runtime, world) <- fake environment' =<< candidateWorld root' calm
          releaseCandidate runtime (CandidateOptions version' "HEAD" False Nothing)
          calls' <- rendered root' <$> recorded world
          [call | call <- calls', any (`isInfixOf` call) ["release-rehearse.sh", "mktemp", "just gate "]] @?= []
          [call | call <- calls', "release-intranet.sh" `isInfixOf` call] @?= [runOf False <> "/worktree/scripts/release-intranet.sh 9.8.7 --run " <> runOf False]
          index <- eitherDecodeFileStrict @Value (root' </> "state/nagare/releases/v9.8.7" </> T.unpack rev </> "index.json") >>= either fail pure
          [status | (Just "rehearsal", status) <- stepsOf index] @?= [Just "passed", Just "kept"]
          [status | (Just "intranet", status) <- stepsOf index] @?= [Just "failed", Just "passed"]
          [status | (Just "gate", status) <- stepsOf index] @?= [Just "kept", Just "kept"]
    , testCase "a run directory of another candidate is refused before any step" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          let runDir = root' </> "mine"
          createDirectoryIfMissing True runDir
          BL.writeFile (runDir </> "candidate.json") (Aeson.encode (object ["version" .= version', "revision" .= ("f" <> T.drop 1 rev), "previous" .= ("9.10.0" :: Text)]))
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root' calm
          refused (releaseCandidate runtime (CandidateOptions version' "HEAD" False (Just runDir))) >>= assertMentions "not this candidate"
          calls' <- rendered root' <$> recorded world
          assertBool "a step ran" (not (any (\call -> "git worktree" `isPrefixOf` call || "just" `isPrefixOf` call) calls'))
    , testCase "without a landed full-gate record the full gate runs in the background and must leave a green record" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root' (calm & #gateRecord .~ False)
          releaseCandidate runtime (CandidateOptions version' "HEAD" True Nothing)
          calls' <- recorded world
          [(unwords (call ^. #arguments), call ^. #background) | call <- calls', call ^. #program == "just"]
            @?= [("gate-verify " <> T.unpack rev, False), ("gate " <> T.unpack rev, True), ("gate-verify " <> T.unpack rev, False)]
          respond <- candidateWorld root' (calm & #gateRecord .~ False)
          let red command = if command ^. #arguments == ["gate", T.unpack rev] then pure (1, "gate: red\n") else respond command
          (redRuntime, redWorld) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "red")] <> pathless) red
          refused (releaseCandidate redRuntime (CandidateOptions version' "HEAD" False Nothing)) >>= assertMentions "the full gate failed"
          filter ("release-intranet.sh" `isInfixOf`) . rendered root' <$> recorded redWorld >>= (@?= [])
    , testCase "notes that do not begin with their release's title refuse before any step" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, _) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root' (calm & #notes .~ "Preface\n# Nagare 9.8.7\n")
          refused (releaseCandidate runtime (CandidateOptions version' "HEAD" True Nothing)) >>= assertMentions "does not begin # Nagare 9.8.7"
    , testCase "a release with images pushes them to the cache before the rehearsal, with no registry call, and a rerun keeps the receipt" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state"), ("CACHIX_AUTH_TOKEN", "secret")] <> pathless
          (runtime, world) <- fake environment' =<< candidateWorld root' (calm & #images .~ True)
          releaseCandidate runtime (CandidateOptions version' "HEAD" True Nothing)
          calls' <- rendered root' <$> recorded world
          let cut = dropWhile (/= "just gate-verify " <> T.unpack rev) calls'
          takeWhile (not . isPrefixOf "mktemp") (drop 1 cut)
            @?= concat
              [ ["nix build --no-link --print-out-paths --max-jobs 0 git+file://$T/repo?rev=" <> T.unpack rev <> "#packages.x86_64-linux." <> package, "cat " <> storePathFor package <> "/digest"]
              | (_, package) <- imageKeys
              ]
              <> ["cachix push shinzui " <> unwords [storePathFor package | (_, package) <- imageKeys]]
              <> ["nix path-info --store https://shinzui.cachix.org " <> storePathFor package | (_, package) <- imageKeys]
          assertBool "the candidate called a registry" (not (any ("skopeo" `isPrefixOf`) calls'))
          assertBool "a rehearsal read the operator shell" (not (any ("direnv" `isPrefixOf`) calls'))
          (again, againWorld) <- fake environment' =<< candidateWorld root' (calm & #images .~ True)
          releaseCandidate again (CandidateOptions version' "HEAD" True Nothing)
          filter (\call -> "cachix" `isPrefixOf` call || "release-rehearse" `isInfixOf` call) . rendered root' <$> recorded againWorld >>= (@?= [])
    , testCase "a release with images refuses before anything runs while the operator shell exports a pin, naming it" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          createDirectoryIfMissing True (root' </> "operator/.git")
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state"), ("CACHIX_AUTH_TOKEN", "secret"), ("NAGARE_RELEASE_OPERATOR_REPO", root' </> "operator")] <> pathless
          (runtime, world) <- fake environment' =<< candidateWorld root' (calm & #images .~ True & #pinned .~ "NAGARE_AUTH_EN_IMAGE\nNAGARE_ADMIN_API_IMAGE\n")
          reason <- refused (releaseCandidate runtime (CandidateOptions version' "HEAD" False Nothing))
          assertMentions "NAGARE_AUTH_EN_IMAGE, NAGARE_ADMIN_API_IMAGE" reason
          calls' <- rendered root' <$> recorded world
          assertBool "the run went on after the refusal" (not (any (\call -> "git worktree" `isPrefixOf` call || "just" `isPrefixOf` call) calls'))
          (runtime', _) <- fake environment' =<< candidateWorld root' (calm & #images .~ True)
          releaseCandidate runtime' (CandidateOptions version' "HEAD" False Nothing)
    , testCase "a release without images reads no token and no operator shell, and a release with images needs the token" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless
          (runtime, _) <- fake environment' =<< candidateWorld root' (calm & #images .~ True)
          refused (releaseCandidate runtime (CandidateOptions version' "HEAD" True Nothing)) >>= assertMentions "CACHIX_AUTH_TOKEN"
          (runtime', world') <- fake environment' =<< candidateWorld root' calm
          releaseCandidate runtime' (CandidateOptions version' "HEAD" True Nothing)
          calls' <- rendered root' <$> recorded world'
          assertBool "a release without images read the operator shell" (not (any ("direnv" `isPrefixOf`) calls'))
    ]

-- * release publish (scripts/release-publish.sh)

-- | A run the candidate left ready, and an operator repository already on
-- the candidate.
readyRun :: FilePath -> IO FilePath
readyRun root' = do
  let runDir = root' </> "state/nagare/releases/v9.8.7" </> T.unpack rev
      operator = root' </> "operator"
  createDirectoryIfMissing True runDir
  BL.writeFile (runDir </> "candidate.json") (Aeson.encode (object ["version" .= version', "revision" .= rev, "previous" .= ("9.10.0" :: Text)]))
  BL.writeFile (runDir </> "intranet.json") (Aeson.encode (object ["version" .= version', "revision" .= rev, "status" .= object ["compatibility" .= ("exact" :: Text)]]))
  BL.writeFile (runDir </> "transition-rehearsal.json") (Aeson.encode (rehearsalRecord rev "9.10.0"))
  createDirectoryIfMissing True (operator </> ".git")
  writeFile (operator </> "flake.nix") ("{\n  inputs.nagare.url = \"github:shinzui/nagare/" <> T.unpack rev <> "\";\n}\n")
  BL.writeFile (operator </> "flake.lock") (Aeson.encode (object ["nodes" .= object ["nagare" .= object ["locked" .= object ["rev" .= rev]]]]))
  writeFile (root' </> "key.pub") "ssh-ed25519 AAAA release\n"
  pure runDir

-- | @accepts@: the candidate CLI accepts the assets on review. @drafts@: how
-- many --yes runs report the draft not yet visible.
publishWorld :: FilePath -> Bool -> Int -> IO Responder
publishWorld root' accepts drafts = do
  attempts <- newIORef (0 :: Int)
  let ok out = pure (0, out)
      cli = "/nix/store/candidate-nagarectl/bin/nagarectl"
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack (root' </> "repo") <> "\n")
    ("git", ["rev-parse", "-q", "--verify", tagRef]) -> pure (if tagRef == "refs/tags/v9.10.0" then 0 else 1, "")
    ("git", ["show", ref])
      | ":release.json" `isSuffixOf` ref -> ok (metadataFor False)
      | otherwise -> ok "# Nagare 9.8.7\n\nNotes.\n"
    ("git", ["config", "user.email"]) -> ok "release@example.invalid\n"
    ("git", ["cat-file", "-t", _]) -> ok "tag\n"
    ("git", ["rev-parse", ref])
      | "^{commit}" `isSuffixOf` ref -> ok (rev <> "\n")
      | otherwise -> ok "fedcba9876543210fedcba9876543210fedcba98\n"
    ("git", ["ls-remote", "origin", _]) -> ok ""
    ("git", ["-C", _, "ls-files", "--error-unmatch", "--", file]) -> pure (if file `elem` ["flake.nix", "flake.lock"] then 0 else 1, "")
    ("nix", ["build", "--no-link", "--print-out-paths", _]) -> ok "/nix/store/candidate-nagarectl\n"
    ("nix", "run" : _) -> ok (versionDocument version' rev)
    (program', arguments')
      | program' == cli && "--yes" `elem` arguments' -> do
          modifyIORef' attempts (+ 1)
          n <- readIORef attempts
          pure (if n <= drafts then (1, "created draft is not yet visible; retry after the provider listing converges\n") else (0, "Release v9.8.7 verified\n"))
      | program' == cli -> pure (if accepts then 0 else 1, if accepts then "Review only\n" else "transition rehearsal belongs to another candidate\n")
    _ -> ok ""

publishEnvironment :: FilePath -> [(String, String)]
publishEnvironment root' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state"), ("NAGARE_RELEASE_SIGNING_KEY", root' </> "key.pub"), ("NAGARE_RELEASE_OPERATOR_REPO", root' </> "operator")]

-- | Writes that leave the machine or the run: none may happen on a refusal.
provider :: String -> Bool
provider call = any (`isPrefixOf` call) ["git -c gpg.format=ssh", "git push", "git worktree add"] || " --yes" `isSuffixOf` call

publishTests :: TestTree
publishTests =
  testGroup
    "release publish"
    [ testCase "checks every proof, signs, has the candidate CLI review the two assets, then pushes only the tag, publishes, checks the public flake and pins the tag" $
        withSystemTempDirectory "publish" $ \raw -> do
          root' <- canonicalizePath raw
          runDir <- readyRun root'
          (runtime, world) <- fake (publishEnvironment root') =<< publishWorld root' True 1
          releasePublish runtime (PublishOptions version' Nothing)
          calls' <- rendered root' <$> recorded world
          let assets = "$T/state/nagare/releases/v9.8.7/" <> T.unpack rev <> "/assets"
              review = "/nix/store/candidate-nagarectl/bin/nagarectl release publish --repo shinzui/nagare --version 9.8.7 --assets " <> assets
              position call = length (takeWhile (/= call) calls')
          assertBool "the review did not run before the push" (position review < position "git push origin refs/tags/v9.8.7")
          [call | call <- calls', provider call]
            @?= [ "git -c gpg.format=ssh -c user.signingkey=$T/key.pub tag -s v9.8.7 -m Nagare v9.8.7 " <> T.unpack rev
                , "git worktree add -q --detach $T/state/nagare/releases/v9.8.7/" <> T.unpack rev <> "/publish v9.8.7"
                , "git push origin refs/tags/v9.8.7"
                , review <> " --yes"
                , review <> " --yes"
                ]
          readIORef (world ^. #pauses) >>= (@?= [15])
          assertBool "the public flake was not checked" ("nix run --refresh github:shinzui/nagare/v9.8.7#nagarectl -- version --json" `elem` calls')
          published <- mapM (doesPathExist . ((runDir </> "assets") </>)) ["nagare-v9.8.7.md", "nagare-transition-rehearsal-v9.8.7.json"]
          published @?= [True, True]
    , testCase "a mismatched revision or a missing rehearsal refuses before a provider write (MasterPlan 37 D3)" $
        withSystemTempDirectory "publish" $ \raw -> do
          root' <- canonicalizePath raw
          let refusesWith change needle = do
                runDir <- readyRun root'
                change runDir
                (runtime, world) <- fake (publishEnvironment root') =<< publishWorld root' True 0
                refused (releasePublish runtime (PublishOptions version' Nothing)) >>= assertMentions needle
                filter provider . rendered root' <$> recorded world >>= (@?= [])
          refusesWith (\runDir -> BL.writeFile (runDir </> "intranet.json") (Aeson.encode (object ["version" .= version', "revision" .= ("f" <> T.drop 1 rev), "status" .= object ["compatibility" .= ("exact" :: Text)]]))) "no intranet record for 9.8.7"
          refusesWith (\runDir -> BL.writeFile (runDir </> "transition-rehearsal.json") (Aeson.encode (rehearsalRecord ("f" <> T.drop 1 rev) "9.10.0"))) "no rehearsal record of a move from 9.10.0"
          refusesWith (\runDir -> BL.writeFile (runDir </> "transition-rehearsal.json") "") "no rehearsal record"
          refusesWith (\runDir -> BL.writeFile (runDir </> "candidate.json") (Aeson.encode (object ["version" .= version', "revision" .= rev, "previous" .= ("9.7.0" :: Text)]))) "does not accept a transition from 9.7.0"
    , testCase "assets the candidate CLI refuses on review stop publication before the tag is pushed" $
        withSystemTempDirectory "publish" $ \raw -> do
          root' <- canonicalizePath raw
          _ <- readyRun root'
          (runtime, world) <- fake (publishEnvironment root') =<< publishWorld root' False 0
          refused (releasePublish runtime (PublishOptions version' Nothing)) >>= assertMentions "refuses the release assets"
          calls' <- rendered root' <$> recorded world
          [call | call <- calls', "git push" `isPrefixOf` call || " --yes" `isSuffixOf` call] @?= []
    , testCase "two runs that moved the intranet need --run" $
        withSystemTempDirectory "publish" $ \raw -> do
          root' <- canonicalizePath raw
          _ <- readyRun root'
          let other = root' </> "state/nagare/releases/v9.8.7/other"
          createDirectoryIfMissing True other
          writeFile (other </> "intranet.json") "{}"
          (runtime, _) <- fake (publishEnvironment root') =<< publishWorld root' True 0
          refused (releasePublish runtime (PublishOptions version' Nothing)) >>= assertMentions "name one with --run DIR"
    ]
