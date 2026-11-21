{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | EP-229: the release runner's commands interpreted with a recording fake
-- transport. Each expected invocation order was taken from the shell script
-- the command replaced (scripts/release-candidate.sh,
-- scripts/release-intranet.sh, scripts/release-rehearse.sh and
-- scripts/transition-rehearsal.sh at 280a0da2) before its logic was deleted.
-- The intranet stages replay the sanitized reviews of the v0.11.1 intranet
-- move (test/fixtures/release/v0.11.1-intranet).
module ReleaseTransitionSpec (releaseTransitionTests) where

import Control.Exception (try)
import Data.Aeson (Value, eitherDecodeFileStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Text qualified as T
import Nagare.Contract.V1 (Outcome (..))
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Candidate
import Nagare.Harness.Release.Intranet
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Rehearse
import Nagare.Harness.Release.Review
import ReleaseFake
import ReleaseImagesSpec (digestFor, fixtureImages, imageKeys, storePathFor)
import ReleaseRehearsalSpec (drillTests, rehearseTests)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, doesPathExist, pathIsSymbolicLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

releaseTransitionTests :: TestTree
releaseTransitionTests =
  testGroup
    "ReleaseTransition (EP-229)"
    [ testGroup
        "review decisions"
        [ testCase "the v0.11.1 intranet reviews count 2, 211 and 0 operations, re-accepting 1, 6 and 0 scopes" $ do
            counts <- forM [1, 2, 3] $ \n -> eitherDecodeFileStrict (fixtureReview n) >>= either fail (either fail pure . parseEither reviewCounts)
            map (operationCount AllOperations) counts @?= [2, 211, 0]
            map (^. #reaccepted) counts @?= [1, 6, 0]
            map (isConverged AllOperations) counts @?= [False, False, True]
        , testCase "converged means no counted operation and no re-accepted scope; the bootstrap stamp and source verifies do not count" $ do
            isConverged AllOperations (ReviewCounts [] 0 0) @?= True
            isConverged AllOperations (ReviewCounts [] 1 0) @?= False
            isConverged AllOperations (ReviewCounts [] 0 205) @?= False
            isConverged AllOperations (ReviewCounts ["VerifyResource"] 0 0) @?= False
            isConverged MutatingOperations (ReviewCounts ["VerifyResource", "VerifyResource"] 0 0) @?= True
            isConverged MutatingOperations (ReviewCounts ["VerifyResource", "UpdateResource"] 0 0) @?= False
            withSystemTempDirectory "review" $ \dir -> do
              let stamp = object ["kind" .= ("Platform" :: Text), "name" .= ("bootstrap-stamp" :: Text)]
                  entry generation = object ["scope" .= stamp, "revision" .= object ["generation" .= (generation :: Int)]]
              BL.writeFile (dir </> "review.json") (Aeson.encode (object ["operations" .= ([] :: [Value]), "baseRevisions" .= [entry 1], "desiredRevisions" .= [entry 2]]))
              readReviewCounts dir >>= (@?= Right (ReviewCounts [] 0 0))
        , testCase "a stage's work is its candidate, operation and validation identities; repeating it is no progress (EP-228 M3)" $ do
            works <- forM [1, 2, 3] $ \n -> eitherDecodeFileStrict (fixtureReview n) >>= either fail (either fail pure . parseEither reviewWork)
            map (length . (^. #operations)) works @?= [2, 211, 0]
            -- Three successive stages each planned different work.
            and [a /= b | (a, b) <- zip works (drop 1 works)] @?= True
            let repeated = noProgress "intranet" 4 (works !! 1)
            assertBool (T.unpack repeated) (all (`T.isInfixOf` repeated) ["intranet stage 4 plans the same work", "211 operations"])
        , testCase "the ambiguous stop's transaction is read from the last ambiguous line" $ do
            ambiguousTransaction "planning\nambiguous tx-ab12 at op-1: provider timeout\n" @?= Just "tx-ab12"
            ambiguousTransaction "ambiguous tx-01 at a\nambiguous tx-02 at b\n" @?= Just "tx-02"
            ambiguousTransaction "converged tx-cd34\n" @?= Nothing
            ambiguousTransaction "ambiguous tx-XY at op\n" @?= Nothing
            stoppedAmbiguousAt "tx-ab12" "x\nambiguous tx-ab12 at op-2: again" @?= True
        , testCase "only a 302 to a login page on the protected host counts" $ do
            map loginLocation ["https://auth.example.test/login?return_to=x", "http://a/x/login", "https://a/?next=login", "https:///login", "", "https://a/logout"]
              @?= [True, True, False, False, False, False]
        , testCase "the newest accepted source is picked by version, and versions are unpadded" $ do
            newestVersion ["0.9.0", "0.11.0", "0.10.0"] @?= Just "0.11.0"
            map validVersion ["0.11.1", "1.0.0", "01.0.0", "1.0", "1.0.0-rc1"] @?= [True, True, False, False, False]
        , testCase "the rehearsal's tool PATH has no Python, and the fake transport fails any Python launch (M3)" $ do
            assertBool "python3 is a rehearsal tool" ("python3" `notElem` rehearsalTools)
            forM_ [invocation "python3" ["-I", "-"], invocation "/nix/store/x-python3/bin/python3.12" [], invocation "env" ["python3", "x.py"], invocation "bash" ["-c", "python3 -c 1"]] $ \command ->
              try @HUnitFailure (noPython command) >>= \case
                Left _ -> pure ()
                Right () -> assertFailure ("not detected: " <> show command)
            noPython (invocation "nix" ["build", "nixpkgs#jq"])
        , testCase "pinning rewrites only the nagare input's url" $ do
            repoint "github:shinzui/nagare/abc" "  inputs.nagare.url = \"github:shinzui/nagare/v9.8.6\"; # pin" @?= "  inputs.nagare.url = \"github:shinzui/nagare/abc\"; # pin"
            repoint "github:shinzui/nagare/abc" "  inputs.other.url = \"x\";" @?= "  inputs.other.url = \"x\";"
        ]
    , intranetTests
    , candidateTests
    , rehearseTests
    , drillTests
    ]

-- * transition run and pin-tag (scripts/release-intranet.sh)

data Knobs = Knobs
  { ambiguous :: !Bool
  , resumeFails :: !Bool
  , applyFails :: !Bool
  , endless :: !Bool
  , dirtyPin :: !Bool
  , wrongCli :: !Bool
  , wrongLock :: !Bool
  , activeTransaction :: !Bool
  , compileError :: !Bool
  , hostSkew :: !Bool
  , unconverged :: !Bool
  , unprotected :: !Bool
  }
  deriving stock (Eq, Show, Generic)

calm :: Knobs
calm = Knobs False False False False False False False False False False False False

data Operator = Operator
  { root :: !FilePath
  , operator :: !FilePath
  , run :: !FilePath
  , environment :: ![(String, String)]
  }
  deriving stock (Eq, Show, Generic)

withOperator :: (Operator -> IO a) -> IO a
withOperator body =
  withSystemTempDirectory "intranet" $ \raw -> do
    root' <- canonicalizePath raw
    let operator' = root' </> "operator"
        run' = root' </> "run"
    forM_ [operator' </> ".git", operator' </> "hosts/intranet", operator' </> "contexts", run'] (createDirectoryIfMissing True)
    writeFile (operator' </> "flake.nix") "{\n  inputs.nagare.url = \"github:shinzui/nagare/v9.8.6\";\n}\n"
    writeFile (operator' </> "flake.lock") "{\"nodes\":{\"nagare\":{\"locked\":{\"rev\":\"old\"}}}}\n"
    BL.writeFile (run' </> "candidate.json") (Aeson.encode (object ["version" .= version', "revision" .= rev, "previous" .= ("9.8.6" :: Text)]))
    body
      Operator
        { root = root'
        , operator = operator'
        , run = run'
        , environment = [("HOME", root' </> "home"), ("PATH", "/usr/bin:/bin"), ("USER", "release"), ("NAGARE_CONTEXT", "another"), ("KUBECONFIG", "/elsewhere"), ("NAGARE_RELEASE_OPERATOR_REPO", operator')]
        }

-- | The operator repository, its dev shell and the intranet, scripted.
intranetWorld :: Operator -> Knobs -> IO Responder
intranetWorld o knobs = do
  plans <- newIORef (0 :: Int)
  stopped <- newIORef False
  committed <- newIORef False
  changed <- newIORef ["flake.lock" | knobs ^. #dirtyPin]
  let at' identity = object ["version" .= identity, "revision" .= (if identity == version' then rev else "old"), "payloadSchema" .= (1 :: Int)]
      ok out = pure (0, out)
      fails out = pure (1, out)
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", "-C" : _ : "ls-files" : _) -> ok ""
    ("git", "-C" : _ : "status" : "--porcelain" : "--" : files) -> do
      dirty <- readIORef changed
      ok (T.concat [" M " <> T.pack file <> "\n" | file <- files, file `elem` dirty])
    ("git", "-C" : _ : "add" : _) -> ok ""
    ("git", "-C" : _ : "commit" : _) -> writeIORef changed [] >> ok ""
    ("git", "-C" : _ : "rev-parse" : "--short" : _) -> ok "abc1234\n"
    ("nix", ["flake", "update", "nagare"]) -> do
      BL.writeFile (fromMaybe "" (command ^. #directory) </> "flake.lock") (Aeson.encode (object ["nodes" .= object ["nagare" .= object ["locked" .= object ["rev" .= (if knobs ^. #wrongLock then "another" else rev)]]]]))
      modifyIORef' changed (<> ["flake.nix", "flake.lock"])
      ok ""
    ("curl", _) -> ok (if knobs ^. #unprotected then "200 \n" else "302 https://auth.example.test/login?return_to=x\n")
    ("direnv", "exec" : _ : "sh" : _) -> ok "/bin/gcloud\n"
    ("direnv", ["exec", _, "printenv", "NAGARE_BASE_DOMAIN"]) -> ok "example.test\n"
    ("direnv", "exec" : _ : "nagarectl" : "--context" : _ : rest) -> case rest of
      ["version", "--json"] -> ok (versionDocument version' (if knobs ^. #wrongCli then "another" else rev))
      ["inventory", "store", "status", "--json"] -> ok (encodeText (object ["activeTransaction" .= (if knobs ^. #activeTransaction then Just ("tx-open" :: Text) else Nothing)]))
      ["platform", "transition", "plan", "--out", out, "--summary", summary']
        | knobs ^. #compileError -> fails "apps/Databases.hs:3:5: error: missing field privileges\n"
        | knobs ^. #endless -> writeReview out ["VerifyResource"] 0 >> writeSummary out summary' >> ok "Saved the next transition stage\n"
        | otherwise -> do
            modifyIORef' plans (+ 1)
            n <- readIORef plans
            createDirectoryIfMissing True out
            BS.readFile (fixtureReview (min n 3)) >>= BS.writeFile (out </> "review.json")
            writeSummary out summary'
            ok "Saved the next transition stage (9.8.6 -> 9.8.7).\n"
      ["inventory", "apply", _, "--yes", "--contract", "1"] -> do
        already <- readIORef stopped
        case () of
          _
            | knobs ^. #applyFails -> pure (4, outcomeDocument OutcomeStopped "tx-ef56" (Just "the provider refused"))
            | knobs ^. #ambiguous && not already -> writeIORef stopped True >> pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "no acknowledgement"))
            | otherwise -> modifyIORef' changed (<> ["hosts/intranet/flake.nix"]) >> ok (outcomeDocument OutcomeConverged "tx-cd34" Nothing)
      ["inventory", "resume", "tx-ab12", "--yes", "--contract", "1"]
        | knobs ^. #resumeFails -> pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "still no acknowledgement"))
        | otherwise -> ok (outcomeDocument OutcomeConverged "tx-ab12" Nothing)
      ["platform", "status", "--json"] -> do
        done <- readIORef committed
        let host = if knobs ^. #hostSkew then object ["version" .= version', "revision" .= ("another" :: Text)] else at' version'
        ok . encodeText $
          if done
            then object ["compatibility" .= ("exact" :: Text), "identities" .= object ["cli" .= at' version', "payload" .= at' version', "host" .= host, "cluster" .= at' version', "context" .= object ["version" .= version', "revision" .= Aeson.Null]]]
            else object ["compatibility" .= ("minor-upgrade-required" :: Text), "identities" .= object ["cli" .= at' version', "payload" .= at' version', "host" .= at' "9.8.6", "cluster" .= at' "9.8.6", "context" .= at' "9.8.6"]]
      ["platform", "transition", "commit", "--yes"] -> writeIORef committed True >> modifyIORef' changed (<> ["contexts/intranet.env"]) >> ok "committed\n"
      ["inventory", "status", "--json"] -> do
        let scope = object ["scope" .= object ["kind" .= ("platform" :: Text), "name" .= ("auth" :: Text)], "revision" .= object ["generation" .= (2 :: Int), "digest" .= ("d" :: Text)]]
        ok (encodeText (object ["activeTransaction" .= Aeson.Null, "accepted" .= [scope], "converged" .= [scope | not (knobs ^. #unconverged)], "findings" .= ([] :: [Value])]))
      _ -> fails ("fake nagarectl: unexpected " <> T.pack (unwords rest) <> "\n")
    other -> assertFailure ("unexpected invocation " <> show other) >> fails ""

intranetOptions :: Operator -> IntranetOptions
intranetOptions o = IntranetOptions {version = version', run = Just (o ^. #run), context = Nothing, revision = Nothing}

nagare :: [String] -> String
nagare rest = unwords (["direnv", "exec", "$T/operator", "nagarectl", "--context", "intranet"] <> rest)

pinFiles :: [String]
pinFiles = ["flake.nix", "flake.lock", "hosts/intranet/flake.nix", "hosts/intranet/flake.lock", "contexts/intranet.env"]

-- | The order scripts/release-intranet.sh ran for a candidate whose first
-- apply stops ambiguous and is resumed, converging at the third plan. Since
-- M2 the plans write a @--summary@ and the applies print their @--contract 1@
-- outcome; nothing else changed.
intranetOrder :: [String]
intranetOrder =
  ["git -C $T/operator ls-files --error-unmatch -- " <> file | file <- pinFiles]
    <> [ "git -C $T/operator status --porcelain -- " <> unwords pinFiles
       , "direnv exec $T/operator sh -c command -v gcloud"
       , "direnv exec $T/operator printenv NAGARE_BASE_DOMAIN"
       , "nix flake update nagare"
       , nagare ["version", "--json"]
       , nagare ["inventory", "store", "status", "--json"]
       , nagare ["platform", "status", "--json"]
       , nagare ["platform", "transition", "plan", "--out", "$T/run/intranet/stage-1", "--summary", "$T/run/intranet/stage-1.summary.json"]
       , nagare ["inventory", "apply", "$T/run/intranet/stage-1", "--yes", "--contract", "1"]
       , nagare ["inventory", "resume", "tx-ab12", "--yes", "--contract", "1"]
       , nagare ["platform", "transition", "plan", "--out", "$T/run/intranet/stage-2", "--summary", "$T/run/intranet/stage-2.summary.json"]
       , nagare ["inventory", "apply", "$T/run/intranet/stage-2", "--yes", "--contract", "1"]
       , nagare ["platform", "transition", "plan", "--out", "$T/run/intranet/stage-3", "--summary", "$T/run/intranet/stage-3.summary.json"]
       , nagare ["platform", "status", "--json"]
       , nagare ["platform", "transition", "commit", "--yes"]
       , nagare ["platform", "status", "--json"]
       , nagare ["inventory", "status", "--json"]
       , "curl -sS -o /dev/null -m 30 -w %{http_code} %{redirect_url}\n https://protected-hello.example.test/"
       ]
    <> ["git -C $T/operator status --porcelain -- " <> file | file <- pinFiles]
    <> [ "git -C $T/operator add -- flake.nix flake.lock hosts/intranet/flake.nix contexts/intranet.env"
       , "git -C $T/operator commit -q -m feat(nagare): upgrade the intranet to the v9.8.7 candidate -m Moved the intranet to Nagare 9.8.7 at "
           <> T.unpack rev
           <> " with just release-candidate: platform status is exact, every accepted scope has converged, and https://protected-hello.example.test/ redirects to the login page. --only -- flake.nix flake.lock hosts/intranet/flake.nix contexts/intranet.env"
       , "git -C $T/operator rev-parse --short HEAD"
       ]

intranetTests :: TestTree
intranetTests =
  testGroup
    "transition run and pin-tag"
    [ testCase "the candidate move runs the script's order, resumes the ambiguous apply once, converges on the v0.11.1 reviews and writes the record" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {ambiguous = True}
          transitionRun runtime (intranetOptions o)
          calls' <- recorded world
          rendered (o ^. #root) calls' @?= intranetOrder
          -- nagarectl gets the empty environment, never the caller's context;
          -- a plan, apply or resume also gets its trace file (EP-224).
          forM_ [call | call <- calls', call ^. #program == "direnv"] $ \call -> do
            let staged = any (`elem` call ^. #arguments) ["plan", "apply", "resume"]
            call ^. #names @?= ["HOME", "TMPDIR", "PATH", "TERM", "USER"] <> ["NAGARE_TRACE_FILE" | staged]
          record <- eitherDecodeFileStrict @Value (o ^. #run </> "intranet.json") >>= either fail pure
          let field = fieldAt record
          field ["version"] @?= Just (Aeson.String version')
          field ["revision"] @?= Just (Aeson.String rev)
          field ["status", "compatibility"] @?= Just (Aeson.String "exact")
          field ["protected", "status"] @?= Just (Aeson.Number 302)
          field ["inventory", "converged"] @?= Just (Aeson.Bool True)
          field ["checkedAt"] @?= Just (Aeson.String "2026-10-29T14:04:58Z")
          said' <- lines' world
          assertBool "no resume line" (any ("apply 1 stopped ambiguous; resuming tx-ab12 once" `T.isInfixOf`) said')
          assertBool "no stage line" (any ("stage 2: 211 operations, re-accepts 6 scopes" `T.isInfixOf`) said')
          readFile (o ^. #operator </> "flake.nix") >>= assertMentions ("inputs.nagare.url = \"github:shinzui/nagare/" <> rev <> "\";") . T.pack
          -- the version-one run index names every stage and attempt
          index <- eitherDecodeFileStrict @Value (o ^. #run </> "intranet-index.json") >>= either fail pure
          let at' = fieldAt index
          at' ["schemaVersion"] @?= Just (Aeson.Number 1)
          at' ["kind"] @?= Just (Aeson.String "intranet")
          at' ["profile"] @?= Just (Aeson.String "intranet")
          at' ["status"] @?= Just (Aeson.String "passed")
          at' ["candidate", "revision"] @?= Just (Aeson.String rev)
          at' ["source", "version"] @?= Just (Aeson.String "9.8.6")
          at' ["records", "intranet"] @?= Just (Aeson.String "intranet.json")
          stages <- maybe (assertFailure "no stages" >> pure []) pure (at' ["stages"] >>= \case Aeson.Array items -> Just (toList items); _ -> Nothing)
          map (\stage -> (fieldAt stage ["stageId"], fieldAt stage ["operations"], fieldAt stage ["converged"], fieldAt stage ["review"])) stages
            @?= [ (Just "intranet-1", Just (Aeson.Number 2), Just (Aeson.Bool False), Just "intranet/stage-1")
                , (Just "intranet-2", Just (Aeson.Number 211), Just (Aeson.Bool False), Just "intranet/stage-2")
                , (Just "intranet-3", Just (Aeson.Number 0), Just (Aeson.Bool True), Just "intranet/stage-3")
                ]
          [(fieldAt attempt' ["attemptId"], fieldAt attempt' ["transaction"], fieldAt attempt' ["outcome"]) | stage <- take 1 stages, Just (Aeson.Array attempts') <- [fieldAt stage ["attempts"]], attempt' <- toList attempts']
            @?= [(Just "intranet-1/apply", Just "tx-ab12", Just "ambiguous"), (Just "intranet-1/resume", Just "tx-ab12", Just "converged")]
    , testCase "a rerun continues from pin files an earlier run left on this candidate" $
        withOperator $ \o -> do
          writeFile (o ^. #operator </> "flake.lock") ("{\"nodes\":{\"nagare\":{\"locked\":{\"rev\":\"" <> T.unpack rev <> "\"}}}}\n")
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {dirtyPin = True}
          transitionRun runtime (intranetOptions o)
          said' <- lines' world
          assertBool "no continue line" (any (("the pin files already name " <> rev) `T.isInfixOf`) said')
          doesFileExist (o ^. #run </> "intranet.json") >>= assertBool "no record"
    , testCase "a second ambiguous stop is not resumed again" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {ambiguous = True, resumeFails = True}
          reason <- refused (transitionRun runtime (intranetOptions o))
          assertMentions "resume of tx-ab12 failed" reason
          calls' <- rendered (o ^. #root) <$> recorded world
          length (filter (isPrefixOf (nagare ["inventory", "resume"])) calls') @?= 1
          assertNothingLanded o calls'
    , testCase "an apply that stops for another reason is not resumed" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {applyFails = True}
          refused (transitionRun runtime (intranetOptions o)) >>= assertMentions "apply 1 failed: stopped tx-ef56 at op-1 (the provider refused)"
          calls' <- rendered (o ^. #root) <$> recorded world
          filter (isPrefixOf (nagare ["inventory", "resume"])) calls' @?= []
    , testCase "a transition that plans the same work again after applying it stops at the repeat (EP-228 M3)" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {endless = True}
          refused (transitionRun runtime (intranetOptions o)) >>= assertMentions "intranet stage 2 plans the same work as the stage before it"
          calls' <- rendered (o ^. #root) <$> recorded world
          length (filter (isPrefixOf (nagare ["platform", "transition", "plan"])) calls') @?= 2
          length (filter (isPrefixOf (nagare ["inventory", "apply"])) calls') @?= 1
          assertNothingLanded o calls'
    , testCase "pin-tag pins and commits flake.nix and flake.lock alone and does not re-run the rollout" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm
          transitionPinTag runtime (intranetOptions o)
          calls' <- rendered (o ^. #root) <$> recorded world
          calls'
            @?= ["git -C $T/operator ls-files --error-unmatch -- " <> file | file <- pinFiles]
              <> [ "git -C $T/operator status --porcelain -- flake.nix flake.lock"
                 , "nix flake update nagare"
                 , "git -C $T/operator status --porcelain -- flake.nix"
                 , "git -C $T/operator status --porcelain -- flake.lock"
                 , "git -C $T/operator add -- flake.nix flake.lock"
                 , "git -C $T/operator commit -q -m chore(nagare): pin the intranet to the published v9.8.7 tag -m v9.8.7 is the candidate " <> T.unpack rev <> " the intranet already runs. --only -- flake.nix flake.lock"
                 , "git -C $T/operator rev-parse --short HEAD"
                 ]
          readFile (o ^. #operator </> "flake.nix") >>= assertMentions "inputs.nagare.url = \"github:shinzui/nagare/v9.8.7\";" . T.pack
    , testGroup
        "every refusal writes no record and commits nothing"
        [ refusal "dirty pin files" calm {dirtyPin = True} "the pin files have uncommitted changes"
        , refusal "the wrong CLI" calm {wrongCli = True} ("nagarectl is not 9.8.7 at " <> rev)
        , refusal "a lock on another revision" calm {wrongLock = True} ("does not resolve github:shinzui/nagare/" <> rev <> " to " <> rev)
        , refusal "an active transaction" calm {activeTransaction = True} "has an active transaction"
        , refusal "an operator config the candidate does not compile" calm {compileError = True} "missing field privileges"
        , refusal "host skew" calm {hostSkew = True} ("platform status is not exact on 9.8.7 at " <> rev)
        , refusal "an unconverged scope" calm {unconverged = True} "an accepted scope that has not converged"
        , refusal "an unprotected URL" calm {unprotected = True} "answered 200"
        ]
    ]
  where
    refusal name knobs words' =
      testCase name $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o knobs
          refused (transitionRun runtime (intranetOptions o)) >>= assertMentions words'
          assertNothingLanded o . rendered (o ^. #root) =<< recorded world
          -- a run that got as far as its index ends it failed with the refusal
          indexed' <- doesFileExist (o ^. #run </> "intranet-index.json")
          when indexed' $ do
            index <- eitherDecodeFileStrict @Value (o ^. #run </> "intranet-index.json") >>= either fail pure
            fieldAt index ["status"] @?= Just (Aeson.String "failed")
            fieldAt index ["detail"] >>= (\case Aeson.String text -> Just text; _ -> Nothing) & maybe (assertFailure "no detail") (assertMentions words')

assertNothingLanded :: Operator -> [String] -> Assertion
assertNothingLanded o calls' = do
  assertBool "a refusal wrote a record" . not =<< doesFileExist (o ^. #run </> "intranet.json")
  filter (isPrefixOf "git -C $T/operator commit") calls' @?= []

-- * release candidate (scripts/release-candidate.sh)

candidateWorld :: FilePath -> IO Responder
candidateWorld root' = candidateWorldWith root' False ""

-- | @images@: release.json names its service images. @pinned@ is what the
-- operator shell reports as exported image overrides.
candidateWorldWith :: FilePath -> Bool -> Text -> IO Responder
candidateWorldWith root' images pinned = do
  let repo = root' </> "repo"
      ok out = pure (0, out)
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack repo <> "\n")
    ("git", ["rev-parse", "--verify", "HEAD^{commit}"]) -> ok (rev <> "\n")
    ("nix", "eval" : _) -> ok "aarch64-darwin"
    ("git", ["show", _]) -> ok (encodeText (object (["platformVersion" .= version', "supportedSystems" .= ["x86_64-linux", "aarch64-darwin" :: Text], "transitionsFrom" .= ["9.8.5", "9.8.6", "9.10.0" :: Text]] <> ["releaseImages" .= fixtureImages | images])))
    ("direnv", "exec" : _ : "sh" : _) -> ok pinned
    ("cat", [path]) | "/digest" `isSuffixOf` path -> ok (digestFor 'a' <> "\n")
    ("git", ["rev-parse", "-q", "--verify", tagRef]) -> pure (if tagRef == "refs/tags/v9.10.0" then 0 else 1, "")
    ("git", ["worktree", "add", "-q", "--detach", tree, _]) -> do
      createDirectoryIfMissing True (tree </> "scripts")
      writeFile (tree </> "scripts/release-native-container.sh") "#!/bin/sh\n"
      ok ""
    ("just", ["gate-release", _]) -> ok "gate: full gate green\n"
    ("mktemp", _) -> ok (T.pack (root' </> "rehearse-work") <> "\n")
    ("scripts/release-rehearse.sh", _) -> case command ^. #environment of
      Extended [("NAGARE_RELEASE_REHEARSAL_RECORD", path)] -> writeFile path "{}" >> ok ""
      other -> assertFailure ("rehearse without its record path: " <> show other) >> pure (1, "")
    ("git", ["cat-file", "-e", _]) -> pure (1, "")
    ("nix", "build" : rest) -> ok ("/nix/store/out-" <> T.takeWhileEnd (/= '.') (T.pack (last rest)) <> "\n")
    _ -> ok ""

candidateOrder :: Bool -> [String]
candidateOrder rehearsal' =
  [ "git rev-parse --show-toplevel"
  , "git rev-parse --verify HEAD^{commit}"
  , "nix eval --impure --raw --expr builtins.currentSystem"
  , "git show " <> T.unpack rev <> ":release.json"
  , "git fetch -q origin master --tags"
  , "git merge-base --is-ancestor " <> T.unpack rev <> " origin/master"
  ]
    <> ["git rev-parse -q --verify refs/tags/v9.8.7" | not rehearsal']
    <> [ "git rev-parse -q --verify refs/tags/v9.10.0"
       , "git worktree add -q --detach " <> run' <> "/worktree " <> T.unpack rev
       , "just gate-release " <> T.unpack rev
       , "mktemp -d /private/tmp/nagare-release-rehearse.XXXXXX"
       , "scripts/release-rehearse.sh " <> T.unpack rev <> " 9.10.0 --run $T/rehearse-work"
       , "scripts/release-native.sh 9.8.7 " <> run' <> "/native/aarch64-darwin"
       ]
    <> ["nix build --no-link --print-out-paths --max-jobs 0 git+file://$T/repo?rev=" <> T.unpack rev <> "#packages.x86_64-linux." <> package | package <- ["nagarectl", "nagare", "nagare-platform", "release-tools"]]
    <> [ "nix copy --to file://$T/state/nagare/releases/x86-work/cache " <> unwords ["/nix/store/out-" <> package | package <- ["nagarectl", "nagare", "nagare-platform", "release-tools"]]
       , "git -C " <> run' <> "/worktree bundle create -q $T/state/nagare/releases/x86-work/candidate.bundle HEAD"
       , "container system status"
       , "container run --rm --platform linux/amd64 --rosetta -c 4 -m 16G -e HOME=/root -v $T/state/nagare/releases/x86-work:/work nixos/nix:2.35.2 bash /work/release-native-container.sh " <> T.unpack rev <> " 9.8.7"
       , "cp -R $T/state/nagare/releases/x86-work/out/x86_64-linux " <> run' <> "/native/x86_64-linux"
       ]
    <> [run' <> "/worktree/scripts/assemble-release.sh --version 9.8.7 --input-root " <> run' <> "/native --transition-rehearsal " <> run' <> "/transition-rehearsal.json --output-dir " <> run' <> "/" <> dist | dist <- ["dist", "dist-again"]]
    <> [ "diff -r " <> run' <> "/dist " <> run' <> "/dist-again"
       , "shasum -a 256 -c SHA256SUMS"
       ]
    <> ( if rehearsal'
           then []
           else
             [ run' <> "/worktree/scripts/release-intranet.sh 9.8.7 --run " <> run'
             , "git fetch -q origin master"
             , "git cat-file -e origin/master:" <> record
             , "git worktree add -q --detach " <> run' <> "/evidence origin/master"
             , "git -C " <> run' <> "/evidence add -- " <> record
             , "git -C " <> run' <> "/evidence commit -q -m docs(release): record the v9.8.7 transition rehearsal -m Moved a disposable local context from v9.10.0 to the candidate " <> T.unpack rev <> "; the seeded row read back unchanged."
             , "just land HEAD"
             ]
       )
    <> ["git -C $T/repo worktree remove --force " <> run' <> "/" <> tree | tree <- ["worktree", "evidence"]]
  where
    run' = "$T/state/nagare/releases/v9.8.7/" <> (if rehearsal' then "rehearsal-" else "") <> "20261029T140458Z"
    record = "docs/release-evidence/" <> T.unpack rev <> "/transition-rehearsal.json"

candidateTests :: TestTree
candidateTests =
  testGroup
    "release candidate"
    [ testCase "--rehearsal runs every step in the script's order, gates in the background in the worktree, and lands nothing" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root'
          releaseCandidate runtime (CandidateOptions version' "HEAD" True)
          calls' <- recorded world
          rendered root' calls' @?= candidateOrder True
          let runDir = root' </> "state/nagare/releases/v9.8.7/rehearsal-20261029T140458Z"
          [(call ^. #directory, call ^. #background) | call <- calls', call ^. #program == "just"] @?= [(Just (runDir </> "worktree"), True)]
          [call ^. #background | call <- calls', call ^. #program == "scripts/release-rehearse.sh"] @?= [True]
          candidate <- eitherDecodeFileStrict @Value (runDir </> "candidate.json") >>= either fail pure
          candidate @?= object ["version" .= version', "revision" .= rev, "previous" .= ("9.10.0" :: Text)]
          assertBool "a rehearsal pointed latest at its run" . not =<< doesPathExist (root' </> "state/nagare/releases/v9.8.7/latest")
          said' <- lines' world
          assertBool "the gate's last line was not printed" ("gate: full gate green" `elem` said')
    , testCase "a candidate moves the intranet, lands the rehearsal record from an evidence worktree, and points latest at its run" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) =<< candidateWorld root'
          releaseCandidate runtime (CandidateOptions version' "HEAD" False)
          calls' <- recorded world
          rendered root' calls' @?= candidateOrder False
          [call ^. #directory | call <- calls', call ^. #arguments == ["land", "HEAD"]] @?= [Just (root' </> "state/nagare/releases/v9.8.7/20261029T140458Z/evidence")]
          assertBool "latest is not a link" =<< pathIsSymbolicLink (root' </> "state/nagare/releases/v9.8.7/latest")
          landed <- readFile (root' </> "state/nagare/releases/v9.8.7/20261029T140458Z/evidence/docs/release-evidence" </> T.unpack rev </> "transition-rehearsal.json")
          landed @?= "{}"
          index <- eitherDecodeFileStrict @Value (root' </> "state/nagare/releases/v9.8.7/20261029T140458Z/index.json") >>= either fail pure
          fieldAt index ["status"] @?= Just (Aeson.String "passed")
          fieldAt index ["children"] @?= Just (object ["rehearsal" .= (root' </> "rehearse-work/index.json"), "intranet" .= ("intranet-index.json" :: Text)])
          fieldAt index ["records"] @?= Just (object ["candidate" .= ("candidate.json" :: Text), "dist" .= ("dist" :: Text), "transitionRehearsal" .= ("transition-rehearsal.json" :: Text)])
          [(fieldAt entry ["name"], fieldAt entry ["status"]) | Just (Aeson.Array entries) <- [fieldAt index ["steps"]], entry <- toList entries]
            @?= [(Just (Aeson.String name), Just "passed") | name <- ["worktree", "gate", "rehearsal", "aarch64-darwin", "x86_64-linux-outputs", "x86_64-linux", "assembly", "gate-wait", "intranet", "record"]]
    , testCase "a release with images pushes them to the cache after the gate starts and before the rehearsal, with no registry call" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state"), ("CACHIX_AUTH_TOKEN", "secret")] <> pathless) =<< candidateWorldWith root' True ""
          releaseCandidate runtime (CandidateOptions version' "HEAD" True)
          calls' <- rendered root' <$> recorded world
          let cut = dropWhile (/= "just gate-release " <> T.unpack rev) calls'
          takeWhile (not . isPrefixOf "mktemp") (drop 1 cut)
            @?= concat
              [ ["nix build --no-link --print-out-paths --max-jobs 0 git+file://$T/repo?rev=" <> T.unpack rev <> "#packages.x86_64-linux." <> package, "cat " <> storePathFor package <> "/digest"]
              | (_, package) <- imageKeys
              ]
              <> ["cachix push shinzui " <> unwords [storePathFor package | (_, package) <- imageKeys]]
              <> ["nix path-info --store https://shinzui.cachix.org " <> storePathFor package | (_, package) <- imageKeys]
          assertBool "the candidate called a registry" (not (any ("skopeo" `isPrefixOf`) calls'))
          assertBool "a rehearsal read the operator shell" (not (any ("direnv" `isPrefixOf`) calls'))
    , testCase "a release with images refuses before anything runs while the operator shell exports a pin, naming it" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          createDirectoryIfMissing True (root' </> "operator/.git")
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state"), ("CACHIX_AUTH_TOKEN", "secret"), ("NAGARE_RELEASE_OPERATOR_REPO", root' </> "operator")] <> pathless
          (runtime, world) <- fake environment' =<< candidateWorldWith root' True "NAGARE_AUTH_EN_IMAGE\nNAGARE_ADMIN_API_IMAGE\n"
          reason <- refused (releaseCandidate runtime (CandidateOptions version' "HEAD" False))
          assertMentions "NAGARE_AUTH_EN_IMAGE, NAGARE_ADMIN_API_IMAGE" reason
          calls' <- rendered root' <$> recorded world
          assertBool "the run went on after the refusal" (not (any (\call -> "git worktree" `isPrefixOf` call || "just" `isPrefixOf` call) calls'))
          (runtime', _) <- fake environment' =<< candidateWorldWith root' True ""
          releaseCandidate runtime' (CandidateOptions version' "HEAD" False)
    , testCase "a release without images reads no token and no operator shell, and a release with images needs the token" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          pathless <- withoutPython root'
          let environment' = [("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless
          (runtime, _) <- fake environment' =<< candidateWorldWith root' True ""
          refused (releaseCandidate runtime (CandidateOptions version' "HEAD" True)) >>= assertMentions "CACHIX_AUTH_TOKEN"
          (runtime', world') <- fake environment' =<< candidateWorld root'
          releaseCandidate runtime' (CandidateOptions version' "HEAD" True)
          calls' <- rendered root' <$> recorded world'
          assertBool "a release without images read the operator shell" (not (any ("direnv" `isPrefixOf`) calls'))
    , testCase "a red release gate stops the run before the intranet and still removes the worktrees" $
        withSystemTempDirectory "candidate" $ \raw -> do
          root' <- canonicalizePath raw
          base <- candidateWorld root'
          let red command = if command ^. #arguments == ["gate-release", T.unpack rev] then pure (1, "gate: red\n") else base command
          pathless <- withoutPython root'
          (runtime, world) <- fake ([("HOME", root' </> "home"), ("XDG_STATE_HOME", root' </> "state")] <> pathless) red
          refused (releaseCandidate runtime (CandidateOptions version' "HEAD" False)) >>= assertMentions "the release gate failed"
          calls' <- rendered root' <$> recorded world
          filter ("release-intranet.sh" `T.isInfixOf`) (map T.pack calls') @?= []
          take 2 (reverse calls') @?= reverse ["git -C $T/repo worktree remove --force $T/state/nagare/releases/v9.8.7/20261029T140458Z/" <> tree | tree <- ["worktree", "evidence"]]
    ]
