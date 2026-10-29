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
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Contract.V1 (Outcome (..), TransactionOutcome (..), VersionInfo (..))
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Candidate
import Nagare.Harness.Release.Intranet
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Rehearse
import Nagare.Harness.Release.Review
import Nagare.Harness.Release.TransitionDrill
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, doesPathExist, getPermissions, pathIsSymbolicLink, setOwnerExecutable, setPermissions)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

-- | What the fake records of one invocation: never a variable's value.
data Call = Call
  { program :: !FilePath
  , arguments :: ![String]
  , directory :: !(Maybe FilePath)
  , names :: ![String]
  , background :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data World = World
  { calls :: !(IORef [Call])
  , said :: !(IORef [Text])
  , pauses :: !(IORef [Int])
  }
  deriving stock (Generic)

type Responder = Invocation -> IO (Int, Text)

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 10 29) 50698

-- | A runtime whose transport records each call, answers it with
-- @respond@, and honours the call's sinks with the answer's text.
fake :: [(String, String)] -> Responder -> IO (Runtime, World)
fake environment' respond = do
  calls' <- newIORef []
  said' <- newIORef []
  pauses' <- newIORef []
  let record isBackground command =
        modifyIORef' calls' (Call (command ^. #program) (command ^. #arguments) (command ^. #directory) (variableNames (command ^. #environment)) isBackground :)
      answer command = do
        (code, out) <- respond command
        let bytes = TE.encodeUtf8 out
        case command ^. #stdoutTo of
          WriteTo path -> BS.writeFile path bytes
          AppendTo path -> BS.appendFile path bytes
          Tee path -> BS.writeFile path bytes
          _ -> pure ()
        -- a separate stderr file holds the progress lines
        case command ^. #stderrTo of
          WriteTo path -> BS.writeFile path "progress\n"
          AppendTo path -> BS.appendFile path "progress\n"
          _ -> pure ()
        pure (Result code (if command ^. #stdoutTo == Capture then bytes else ""))
      transport' =
        Transport
          { run = \command -> noPython command >> record False command >> answer command
          , spawn = \command -> do
              noPython command
              record True command
              result <- answer command
              pure Background {finished = pure (result ^. #exit), stop = pure ()}
          }
  pure
    ( Runtime
        { transport = transport'
        , now = pure fixedTime
        , pause = \seconds -> modifyIORef' pauses' (seconds :)
        , say = \line -> modifyIORef' said' (line :)
        , warn = const (pure ())
        , variables = environment'
        , harness = "/harness/bin/nagare-harness"
        , locate = \_ -> pure (Just "/usr/bin/container")
        }
    , World calls' said' pauses'
    )
  where
    variableNames = \case
      Inherited -> []
      Extended extra -> map fst extra
      Exactly exact -> map fst exact

-- | M3: the release path starts no Python interpreter, by name, by absolute
-- path, through @env@ or inside a shell command line.
noPython :: Invocation -> IO ()
noPython command =
  when (any python (command ^. #program : command ^. #arguments)) $
    assertFailure ("a Python interpreter was launched: " <> unwords (command ^. #program : command ^. #arguments))
  where
    python word = any (\token -> "python" `isPrefixOf` takeFileName token) (words word)

-- | A search path with no Python on it, for the commands' own lookups.
withoutPython :: FilePath -> IO [(String, String)]
withoutPython root' = do
  createDirectoryIfMissing True (root' </> "bin")
  found <- searchPath (root' </> "bin") "python3"
  found @?= Nothing
  pure [("PATH", root' </> "bin")]

recorded :: World -> IO [Call]
recorded world = reverse <$> readIORef (world ^. #calls)

-- | Each call as its command line, with the test root shown as @$T@.
rendered :: FilePath -> [Call] -> [String]
rendered root = map (\call -> T.unpack (T.replace (T.pack root) "$T" (T.pack (unwords (call ^. #program : call ^. #arguments)))))

lines' :: World -> IO [Text]
lines' world = reverse <$> readIORef (world ^. #said)

refused :: IO () -> IO Text
refused action =
  try action >>= \case
    Left (Refusal reason) -> pure reason
    Right () -> assertFailure "expected a refusal" >> pure ""

assertMentions :: Text -> Text -> Assertion
assertMentions needle haystack = assertBool (T.unpack ("expected \"" <> needle <> "\" in: " <> haystack)) (needle `T.isInfixOf` haystack)

-- | The value at a path of object keys.
fieldAt :: Value -> [Text] -> Maybe Value
fieldAt = foldl (\value key -> case value of Just (Aeson.Object fields) -> KeyMap.lookup (Key.fromText key) fields; _ -> Nothing) . Just

encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . BL.toStrict . Aeson.encode

-- | The @--contract 1@ outcome an apply or resume prints.
outcomeDocument :: Outcome -> Text -> Maybe Text -> Text
outcomeDocument outcome' transaction' detail' =
  encodeText . Aeson.toJSON $
    TransactionOutcome
      { contractVersion = ContractVersion1
      , document = DocumentName
      , outcome = outcome'
      , transaction = nullable (Just transaction')
      , operation = nullable (if outcome' == OutcomeConverged then Nothing else Just "op-1")
      , failureClass = nullable Nothing
      , barriers = []
      , detail = nullable detail'
      , problem = nullable Nothing
      }

-- | @version --json@ of a build.
versionDocument :: Text -> Text -> Text
versionDocument version'' revision'' = encodeText (Aeson.toJSON (VersionInfo version'' version'' (Just revision'') Nothing [1]))

-- | What @platform transition plan --summary@ writes for a review.
writeSummary :: FilePath -> FilePath -> IO ()
writeSummary review path = do
  counts <- readReviewCounts review >>= either (assertFailure . T.unpack) pure
  BL.writeFile path . Aeson.encode $
    object
      [ "schemaVersion" .= (1 :: Int)
      , "review" .= review
      , "operations" .= Map.fromListWith (+) [(tag, 1 :: Int) | tag <- counts ^. #actions]
      , "operationCount" .= length (counts ^. #actions)
      , "reaccepted" .= ["platform:scope-" <> T.pack (show i) | i <- [1 .. counts ^. #reaccepted]]
      ]

fixtureReview :: Int -> FilePath
fixtureReview n = "test/fixtures/release/v0.11.1-intranet/stage-" <> show n <> ".review.json"

writeReview :: FilePath -> [Text] -> Int -> IO ()
writeReview out tags reaccepts = do
  createDirectoryIfMissing True out
  let scope i = object ["kind" .= ("Platform" :: Text), "name" .= ("scope-" <> show i)]
      entry i generation = object ["scope" .= scope i, "revision" .= object ["generation" .= (generation :: Int), "digest" .= ("d" :: Text)]]
  BL.writeFile
    (out </> "review.json")
    ( Aeson.encode
        ( object
            [ "operations" .= [object ["operation" .= object ["action" .= object ["tag" .= tag]]] | tag <- tags]
            , "baseRevisions" .= [entry i 1 | i <- [1 .. reaccepts]]
            , "desiredRevisions" .= [entry i 2 | i <- [1 .. reaccepts]]
            ]
        )
    )

version' :: Text
version' = "9.8.7"

rev :: Text
rev = "0123456789abcdef0123456789abcdef01234567"

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
            isConverged AllOperations (ReviewCounts [] 0) @?= True
            isConverged AllOperations (ReviewCounts [] 1) @?= False
            isConverged AllOperations (ReviewCounts ["VerifyResource"] 0) @?= False
            isConverged MutatingOperations (ReviewCounts ["VerifyResource", "VerifyResource"] 0) @?= True
            isConverged MutatingOperations (ReviewCounts ["VerifyResource", "UpdateResource"] 0) @?= False
            withSystemTempDirectory "review" $ \dir -> do
              let stamp = object ["kind" .= ("Platform" :: Text), "name" .= ("bootstrap-stamp" :: Text)]
                  entry generation = object ["scope" .= stamp, "revision" .= object ["generation" .= (generation :: Int)]]
              BL.writeFile (dir </> "review.json") (Aeson.encode (object ["operations" .= ([] :: [Value]), "baseRevisions" .= [entry 1], "desiredRevisions" .= [entry 2]]))
              readReviewCounts dir >>= (@?= Right (ReviewCounts [] 0))
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
          -- nagarectl gets the empty environment, never the caller's context
          forM_ [call | call <- calls', call ^. #program == "direnv"] $ \call ->
            call ^. #names @?= ["HOME", "TMPDIR", "PATH", "TERM", "USER"]
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
    , testCase "a transition that never converges stops after twelve stages" $
        withOperator $ \o -> do
          (runtime, world) <- fake (o ^. #environment) =<< intranetWorld o calm {endless = True}
          refused (transitionRun runtime (intranetOptions o)) >>= assertMentions "did not converge in 12 stages"
          calls' <- rendered (o ^. #root) <$> recorded world
          length (filter (isPrefixOf (nagare ["platform", "transition", "plan"])) calls') @?= 12
          length (filter (isPrefixOf (nagare ["inventory", "apply"])) calls') @?= 12
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
candidateWorld root' = do
  let repo = root' </> "repo"
      ok out = pure (0, out)
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack repo <> "\n")
    ("git", ["rev-parse", "--verify", "HEAD^{commit}"]) -> ok (rev <> "\n")
    ("nix", "eval" : _) -> ok "aarch64-darwin"
    ("git", ["show", _]) -> ok (encodeText (object ["platformVersion" .= version', "supportedSystems" .= ["x86_64-linux", "aarch64-darwin" :: Text], "transitionsFrom" .= ["9.8.5", "9.8.6", "9.10.0" :: Text]]))
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

-- * transition rehearse (scripts/release-rehearse.sh)

rehearseWorld :: FilePath -> Bool -> IO Responder
rehearseWorld root' carriesHelm = do
  let ok out = pure (0, out)
      tool name = root' </> "store" </> name
  forM_ ["bash", "kubectl"] $ \name -> createDirectoryIfMissing True (tool name </> "bin")
  when carriesHelm (createDirectoryIfMissing True (tool "kubectl/bin") >> writeFile (tool "kubectl/bin/helm") "" >> makeExecutable (tool "kubectl/bin/helm"))
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("git", ["rev-parse", "--show-toplevel"]) -> ok (T.pack (root' </> "repo") <> "\n")
    ("git", ["-C", _, "rev-parse", "--verify", _]) -> ok (rev <> "\n")
    ("nix", "build" : rest)
      | "nixpkgs#bash" `elem` rest -> ok (T.pack (unlines [tool "bash", tool "kubectl", tool "no-bin"]))
      | "nixpkgs#kubernetes-helm" `elem` rest -> ok "/nix/store/helm\n"
      | any ("github:" `isPrefixOf`) rest -> ok "/nix/store/source-nagarectl\n"
      | otherwise -> ok "/nix/store/candidate-nagarectl\n"
    ("/nix/store/candidate-nagarectl/bin/nagarectl", ["version", "--json"]) -> ok (versionDocument version' rev)
    ("/harness/bin/nagare-harness", ["transition", "drill"]) -> do
      let rootDir = case command ^. #environment of
            Exactly entries -> fromMaybe "" (lookup "NAGARE_REHEARSAL_ROOT" entries)
            _ -> ""
      createDirectoryIfMissing True (rootDir </> "evidence")
      BL.writeFile (rootDir </> "evidence/transition-rehearsal.json") (Aeson.encode (rehearsalRecord rev "9.8.6"))
      ok "rehearsal: transition rehearsal OK\n"
    _ -> ok ""
  where
    makeExecutable path = getPermissions path >>= setPermissions path . setOwnerExecutable True

rehearsalRecord :: Text -> Text -> Value
rehearsalRecord revision' previous' =
  object
    [ "candidate" .= object ["revision" .= revision', "version" .= version']
    , "source" .= object ["version" .= previous', "revision" .= ("s" :: Text)]
    , "sentinel" .= object ["seeded" .= ("transition x" :: Text), "readBack" .= ("transition x" :: Text)]
    ]

rehearseTests :: TestTree
rehearseTests =
  testGroup
    "transition rehearse"
    [ testCase "builds both CLIs and the tool PATH, starts the drill from an empty environment, and keeps its record" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          let record = root' </> "evidence/transition-rehearsal.json"
          (runtime, world) <- fake [("HOME", root' </> "home"), ("USER", "release"), ("NAGARE_RELEASE_REHEARSAL_RECORD", record), ("NAGARE_CONTEXT", "another")] =<< rehearseWorld root' False
          transitionRehearse runtime (RehearseOptions rev "v9.8.6" (Just (root' </> "work")))
          calls' <- recorded world
          rendered root' calls'
            @?= [ "git rev-parse --show-toplevel"
                , "git -C $T/repo rev-parse --verify " <> T.unpack rev <> "^{commit}"
                , "colima status -p nagare-mp23"
                , "colima ssh -p nagare-mp23 -- sudo tee /etc/resolv.conf"
                , "nix build --no-link --print-out-paths github:shinzui/nagare/v9.8.6#nagarectl"
                , "nix build --no-link --print-out-paths git+file://$T/repo?rev=" <> T.unpack rev <> "#nagarectl"
                , "nix build --no-link --print-out-paths --inputs-from github:shinzui/nagare/v9.8.6 nixpkgs#kubernetes-helm"
                , "nix build --no-link --print-out-paths --inputs-from git+file://$T/repo?rev=" <> T.unpack rev <> " " <> unwords (map ("nixpkgs#" <>) rehearsalTools)
                , "/nix/store/candidate-nagarectl/bin/nagarectl version --json"
                , "/harness/bin/nagare-harness transition drill"
                ]
          [call ^. #names | call <- calls', call ^. #program == "/harness/bin/nagare-harness"]
            @?= [["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "DOCKER_HOST", "NAGARE_REHEARSAL_SOURCE", "NAGARE_REHEARSAL_TARGET", "NAGARE_REHEARSAL_ROOT", "NAGARE_REHEARSAL_RESET"]]
          kept <- eitherDecodeFileStrict @Value record >>= either fail pure
          kept @?= rehearsalRecord rev "9.8.6"
          index <- eitherDecodeFileStrict @Value (root' </> "work/index.json") >>= either fail pure
          fieldAt index ["status"] @?= Just "passed"
          fieldAt index ["children", "drill"] @?= Just "run/index.json"
          fieldAt index ["records", "transitionRehearsal"] @?= Just (Aeson.String (T.pack record))
          wrapper <- readFile (root' </> "work/bin/source-nagarectl")
          wrapper @?= "#!/bin/sh\nPATH=/nix/store/helm/bin:$PATH exec /nix/store/source-nagarectl/bin/nagarectl \"$@\"\n"
    , testCase "an existing record for the same move is kept without a run; another move's is refused" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          let record = root' </> "transition-rehearsal.json"
          BL.writeFile record (Aeson.encode (rehearsalRecord rev "9.8.6"))
          (runtime, world) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", record)] =<< rehearseWorld root' False
          transitionRehearse runtime (RehearseOptions rev "9.8.6" Nothing)
          length <$> recorded world >>= (@?= 2)
          refused (transitionRehearse runtime (RehearseOptions rev "9.8.5" Nothing)) >>= assertMentions "does not record a move from 9.8.5"
    , testCase "a tool PATH that carries a helm is refused before the drill" $
        withSystemTempDirectory "rehearse" $ \raw -> do
          root' <- canonicalizePath raw
          (runtime, world) <- fake [("HOME", root'), ("NAGARE_RELEASE_REHEARSAL_RECORD", root' </> "r.json")] =<< rehearseWorld root' True
          refused (transitionRehearse runtime (RehearseOptions rev "9.8.6" (Just (root' </> "work")))) >>= assertMentions "carries a helm"
          calls' <- recorded world
          filter ((== "/harness/bin/nagare-harness") . (^. #program)) calls' @?= []
    ]

-- * transition drill (scripts/transition-rehearsal.sh)

drillWorld :: IO Responder
drillWorld = do
  plans <- newIORef (0 :: Int)
  applies <- newIORef (0 :: Int)
  resumes <- newIORef (0 :: Int)
  sentinel <- newIORef ""
  let ok out = pure (0, out)
      source = "/nix/store/source/bin/nagarectl"
      target = "/nix/store/target/bin/nagarectl"
  pure $ \command -> case (command ^. #program, command ^. #arguments) of
    ("docker", ["ps", "-a", "--format", _]) -> ok "k3d-nagare-local-server-0\n"
    ("docker", ["ps", "--format", _]) -> ok "k3d-registry.localhost\nk3d-nagare-local-server-0\n"
    ("docker", ["push", image]) -> ok ("The push refers to " <> T.pack image <> "\nlatest: digest: sha256:0abc size: 1\n")
    ("docker", ["exec", _, "wget", _, _, _, _]) -> ok "{\"repositories\":[]}\n"
    ("curl", ["-s", "-m", "2", "-o", "/dev/null", "-w", _, _]) -> ok "000"
    ("curl", ["-s", "-m", "3", _]) -> ok "{\"repositories\":[]}"
    ("age-keygen", ["-y", _]) -> ok "age1recipient\n"
    (program', ["version"]) | program' `elem` [source, target] -> ok (if program' == source then "nagarectl 9.8.6 (s)\nmore\n" else "nagarectl 9.8.7 (t)\n")
    (program', ["version", "--json"]) -> ok (encodeText (object ["version" .= (if program' == source then "9.8.6" else version' :: Text), "revision" .= (if program' == source then "s" else rev :: Text)]))
    (_, "--context" : "transition" : rest) -> case rest of
      ["context", "create", _, "--mode", "local", _, _, _, _, _, _, _, _, "--use"] -> ok "context transition created\nnow current\n"
      ["platform", "root", "--json"] -> ok "{\"platformVersion\":\"9.8.6\"}"
      ["platform", "bootstrap", "plan", "--out", out] | takeFileName out == "replan" -> writeReview out [] 0 >> ok ""
      ["platform", "bootstrap", "plan", "--out", out] -> do
        modifyIORef' plans (+ 1)
        n <- readIORef plans
        writeReview out (if n == 1 then ["CreateResource", "UpdateResource", "VerifyResource"] else replicate 214 "VerifyResource") 0
        ok ""
      ["platform", "bootstrap", "apply", _, "--yes"] -> ok "converged tx-01\n"
      ["platform", "transition", "plan", "--out", out, "--summary", summary'] -> do
        n <- (+ 1) <$> readIORef applies
        writeReview out (if n == 1 then "UpdateResource" : replicate 213 "VerifyResource" else []) (if n == 1 then 2 else 0)
        writeSummary out summary'
        ok ""
      ["inventory", "apply", _, "--yes", "--contract", "1"] -> modifyIORef' applies (+ 1) >> pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "no acknowledgement"))
      ["inventory", "resume", "tx-ab12", "--yes", "--contract", "1"] -> do
        modifyIORef' resumes (+ 1)
        k <- readIORef resumes
        if k == 1 then pure (5, outcomeDocument OutcomeAmbiguous "tx-ab12" (Just "still waiting")) else ok (outcomeDocument OutcomeConverged "tx-ab12" Nothing)
      ["platform", "transition", "commit", "--yes"] -> ok "context transition pinned to 9.8.7\n"
      ["platform", "status", "--json"] -> ok "{\"compatibility\":\"exact\"}"
      ["inventory", "status", "--json"] -> ok "{\"activeTransaction\":null,\"transactionStatus\":null,\"observationComplete\":true,\"accepted\":[]}"
      ["db", "create", "postgres", "rehearsal", _, _, _, _, _, _] -> ok "created\n"
      _ -> pure (2, "fake nagarectl: unexpected " <> T.pack (unwords rest))
    ("kubectl", ["-n", "personal", "get", "statefulset", "rehearsal"]) -> pure (1, "")
    ("kubectl", ["-n", "personal", "get", "secret", _, "-o", _]) -> ok "cmVoZWFyc2Fs"
    ("kubectl", "-n" : "personal" : "exec" : "rehearsal-0" : "--" : "env" : _ : "psql" : rest) -> case reverse rest of
      sql : _
        | "INSERT" `T.isInfixOf` T.pack sql -> writeIORef sentinel (T.takeWhile (/= '\'') (T.drop 1 (T.dropWhile (/= '\'') (snd (T.breakOn "VALUES" (T.pack sql)))))) >> ok ""
        | otherwise -> (,) 0 . (<> "\n") <$> readIORef sentinel
      [] -> ok ""
    _ -> ok ""

drillOrder :: [String]
drillOrder =
  [ "chmod 700 $T/root $T/root/sops $T/root/sops/age"
  , "docker ps -a --format {{.Names}}"
  , "docker rm -f registry-forward"
  , "k3d cluster delete nagare-local"
  , "k3d registry delete k3d-registry.localhost"
  , source "version"
  , target "version"
  , "age-keygen -o $T/root/sops/age/keys.txt"
  , "age-keygen -y $T/root/sops/age/keys.txt"
  , "sops --config $T/root/config/nagare/cluster-secrets/transition/.sops.yaml --encrypt --in-place $T/root/config/nagare/cluster-secrets/transition/grafana-admin.yaml"
  , source "--context transition context create transition --mode local --registry-host k3d-registry.localhost:5000 --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use"
  , source "--context transition platform root --json"
  , source "version --json"
  , source "--context transition platform bootstrap plan --out $T/root/reviews/bootstrap-1"
  , source "--context transition platform bootstrap apply $T/root/reviews/bootstrap-1 --yes"
  , "docker ps --format {{.Names}}"
  ]
    <> concat
      [ [ "docker image inspect k3d-registry.localhost:5000/" <> repository <> ":" <> tag'
        , "docker tag k3d-registry.localhost:5000/" <> repository <> ":" <> tag' <> " localhost:5000/" <> repository <> ":" <> tag'
        , "docker push localhost:5000/" <> repository <> ":" <> tag'
        ]
      | (repository, tag', _) <- pinnedImages
      ]
    <> [ "curl -s -m 2 -o /dev/null -w %{http_code} http://127.0.0.1:15213/v2/"
       , "docker rm -f registry-forward"
       , "docker run -d --name registry-forward --network k3d-nagare-local -p 127.0.0.1:15213:5000 alpine/socat TCP-LISTEN:5000,fork,reuseaddr TCP:k3d-registry.localhost:5000"
       , "curl -s -m 2 -o /dev/null http://127.0.0.1:15213/v2/"
       , "curl -s -m 3 http://127.0.0.1:15213/v2/_catalog"
       , "docker exec k3d-registry.localhost wget -q -O - http://localhost:5000/v2/_catalog"
       , source "--context transition platform bootstrap plan --out $T/root/reviews/bootstrap-2"
       , source "--context transition inventory status --json"
       , "kubectl -n personal get statefulset rehearsal"
       , source "--context transition db create postgres rehearsal -n personal --recovery-backup postgres-backup --recovery-key-version v1"
       ]
    <> ["kubectl -n personal get secret nagare-db-rehearsal -o jsonpath={.data." <> key <> "}" | key <- ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]]
    <> [ "kubectl -n personal exec rehearsal-0 -- pg_isready -h 127.0.0.1 -U rehearsal -d rehearsal"
       , psql "CREATE TABLE IF NOT EXISTS transition_sentinel(v text); TRUNCATE transition_sentinel; INSERT INTO transition_sentinel VALUES ('transition 20261029T140458Z');"
       , psql "SELECT v FROM transition_sentinel;"
       , target "--context transition platform transition plan --out $T/root/reviews/transition-1 --summary $T/root/reviews/transition-1.summary.json"
       , target "--context transition inventory apply $T/root/reviews/transition-1 --yes --contract 1"
       , target "--context transition inventory resume tx-ab12 --yes --contract 1"
       , target "--context transition inventory resume tx-ab12 --yes --contract 1"
       , target "--context transition platform transition plan --out $T/root/reviews/transition-2 --summary $T/root/reviews/transition-2.summary.json"
       , target "--context transition platform transition commit --yes"
       , target "--context transition platform status --json"
       , target "--context transition inventory status --json"
       , psql "SELECT v FROM transition_sentinel;"
       , target "--context transition platform bootstrap plan --out $T/root/reviews/replan"
       , source "version --json"
       , target "version --json"
       ]
  where
    source rest = "/nix/store/source/bin/nagarectl " <> rest
    target rest = "/nix/store/target/bin/nagarectl " <> rest
    psql sql = "kubectl -n personal exec rehearsal-0 -- env PGPASSWORD=rehearsal psql -h 127.0.0.1 -U rehearsal -d rehearsal -tAc " <> sql

drillTests :: TestTree
drillTests =
  testGroup
    "transition drill"
    [ testCase "resets the daemon, bootstraps on the source, seeds the images once, moves on the candidate resuming an ambiguous apply, and writes the record" $
        withSystemTempDirectory "drill" $ \raw -> do
          root' <- canonicalizePath raw
          let rootDir = root' </> "root"
          respond <- drillWorld
          (runtime, world) <-
            fake
              [ ("HOME", root')
              , ("PATH", "/tools/bin")
              , ("DOCKER_HOST", "unix://" <> root' </> "docker.sock")
              , ("NAGARE_REHEARSAL_SOURCE", "/nix/store/source/bin/nagarectl")
              , ("NAGARE_REHEARSAL_TARGET", "/nix/store/target/bin/nagarectl")
              , ("NAGARE_REHEARSAL_ROOT", rootDir)
              , ("NAGARE_REHEARSAL_RESET", "1")
              , ("NAGARE_CONTEXT", "another")
              , ("NAGARE_PLATFORM_ROOT", "/checkout")
              , ("KUBECONFIG", "/elsewhere")
              , ("CLOUDSDK_CORE_PROJECT", "elsewhere")
              ]
              respond
          transitionDrill runtime
          calls' <- recorded world
          rendered root' calls' @?= drillOrder
          readIORef (world ^. #pauses) >>= (@?= [20, 20])
          -- no ambient context reaches either release
          forM_ calls' $ \call -> do
            assertBool ("a scrubbed variable reached " <> call ^. #program) (all (`notElem` call ^. #names) ["NAGARE_CONTEXT", "NAGARE_PLATFORM_ROOT", "CLOUDSDK_CORE_PROJECT"])
            assertBool ("the drill's XDG root is missing from " <> call ^. #program) ("XDG_CONFIG_HOME" `elem` call ^. #names)
          let first' = take 1 calls'
              seeded = [call | call <- calls', "db" `elem` call ^. #arguments]
          assertBool "the ambient kubeconfig reached the drill" (all (("KUBECONFIG" `notElem`) . (^. #names)) first')
          map (\call -> "KUBECONFIG" `elem` call ^. #names) seeded @?= [True]
          images <- lines <$> readFile (rootDir </> "images.env")
          sort (map (takeWhile (/= '=')) images) @?= sort [variable | (_, _, variable) <- pinnedImages]
          record <- eitherDecodeFileStrict @Value (rootDir </> "evidence/transition-rehearsal.json") >>= either fail pure
          let field = fieldAt record
          field ["bootstrap", "reviews"] @?= Just (Aeson.Number 1)
          field ["transition", "reviews"] @?= Just (Aeson.Number 1)
          field ["transition", "operations"] @?= Just (Aeson.Number 214)
          field ["sentinel", "seeded"] @?= Just (Aeson.String "transition 20261029T140458Z")
          field ["sentinel", "readBack"] @?= Just (Aeson.String "transition 20261029T140458Z")
          field ["candidate", "revision"] @?= Just (Aeson.String rev)
          field ["source", "version"] @?= Just (Aeson.String "9.8.6")
          field ["inventory", "observationComplete"] @?= Just (Aeson.Bool True)
          field ["platform", "compatibility"] @?= Just (Aeson.String "exact")
          raw' <- readFile (rootDir </> "evidence/transition-rehearsal.json")
          take 2 (lines raw') @?= ["{", "  \"bootstrap\": {"]
          assertBool "the secret file was not encrypted in place" =<< doesFileExist (rootDir </> "config/nagare/cluster-secrets/transition/grafana-admin.yaml")
          takeDirectory rootDir @?= root'
          index <- eitherDecodeFileStrict @Value (rootDir </> "index.json") >>= either fail pure
          fieldAt index ["kind"] @?= Just "drill"
          fieldAt index ["profile"] @?= Just "local-rehearsal"
          fieldAt index ["status"] @?= Just "passed"
          fieldAt index ["candidate", "revision"] @?= Just (Aeson.String rev)
          fieldAt index ["records", "transitionRehearsal"] @?= Just "evidence/transition-rehearsal.json"
          let stages = [stage | Just (Aeson.Array items) <- [fieldAt index ["stages"]], stage <- toList items]
          map (\stage -> (fieldAt stage ["stageId"], fieldAt stage ["converged"])) stages
            @?= [(Just "bootstrap-1", Just (Aeson.Bool False)), (Just "bootstrap-2", Just (Aeson.Bool True)), (Just "transition-1", Just (Aeson.Bool False)), (Just "transition-2", Just (Aeson.Bool True))]
          [(fieldAt attempt' ["attemptId"], fieldAt attempt' ["outcome"]) | stage <- drop 2 (take 3 stages), Just (Aeson.Array attempts') <- [fieldAt stage ["attempts"]], attempt' <- toList attempts']
            @?= [(Just "transition-1/apply", Just "ambiguous"), (Just "transition-1/resume-1", Just "ambiguous"), (Just "transition-1/resume-2", Just "converged")]
    , testCase "the drill scrubs the ambient context but keeps its own inputs" $
        drillEnvironment "/r" [("NAGARE_CONTEXT", "x"), ("NAGARE_REHEARSAL_SOURCE", "s"), ("KUBECONFIG", "k"), ("PULUMI_HOME", "p"), ("NAGARE_X1", "kept"), ("HOME", "/h")]
          @?= [("NAGARE_REHEARSAL_SOURCE", "s"), ("NAGARE_X1", "kept"), ("HOME", "/h"), ("XDG_CONFIG_HOME", "/r/config"), ("XDG_STATE_HOME", "/r/state"), ("XDG_CACHE_HOME", "/r/cache")]
    , testCase "the pushed digest is docker push's last" $
        pushedDigest "a: digest: sha256:00ff size: 1\nlatest: digest: sha256:abc123 size: 528\n" @?= Just "sha256:abc123"
    ]
