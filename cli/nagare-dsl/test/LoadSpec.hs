-- | Failure-mode tests for 'Nagare.Dsl.Load' (config-as-program / Branch B).
--
-- The subprocess paths (compile error, missing binding) use a temp file; the
-- 'MarshalError' re-validation path is tested directly through the pure
-- 'decodeDeployment' so it needs no @runghc@ invocation.
module LoadSpec (loadTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Load
import Nagare.Dsl.Types
  ( Deployment (..)
  , EnvScope (..)
  , ScopedEnvVar (..)
  , mkEnvName
  )
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.HUnit

loadTests :: TestTree
loadTests =
  testGroup
    "Nagare.Dsl.Load failure modes"
    [ testCase "file not found returns FileNotFound" $ do
        result <- loadDeployment "/nonexistent/Config.hs"
        result @?= Left (FileNotFound "/nonexistent/Config.hs")
    , testCase "renderLoadError FileNotFound contains path" $
        assertContains
          "/nonexistent/Config.hs"
          (renderLoadError (FileNotFound "/nonexistent/Config.hs"))
    , testCase "bad service name (decodeDeployment) returns MarshalError name" $
        case decodeDeployment (BC.pack badNameJSON) of
          Left (MarshalError "name" msg) -> assertContains "invalid" msg
          other -> assertFailure ("expected MarshalError name, got: " <> show other)
    , testCase "max < min (decodeDeployment) returns MarshalError scale" $
        case decodeDeployment (BC.pack badScaleJSON) of
          Left (MarshalError "scale" msg) -> assertContains ">=" msg
          other -> assertFailure ("expected MarshalError scale, got: " <> show other)
    , testCase "value+secretRef cannot appear together (sum type / decode)" $
        -- A literal env entry that also carries a secretName still decodes as a
        -- single EnvLiteral — the sum type cannot hold both at once.
        case decodeDeployment (BC.pack bothEnvJSON) of
          Right _ -> pure ()
          other -> assertFailure ("expected Right (literal wins), got: " <> show other)
    , testCase "compile error in Config.hs returns CompileError" $ do
        result <- withConfigFixture syntaxErrorConfig loadDeployment
        case result of
          Left (CompileError _ _) -> pure ()
          other -> assertFailure ("expected CompileError, got: " <> show other)
    , testCase "Config.hs with no emitDeployment returns MissingBinding" $ do
        result <- withConfigFixture noEmitConfig loadDeployment
        case result of
          Left (MissingBinding _) -> pure ()
          other -> assertFailure ("expected MissingBinding, got: " <> show other)
    , testCase "renderLoadError CompileError contains path and diagnostic" $ do
        let err = CompileError "/app/Config.hs" "parse error"
        assertContains "/app/Config.hs" (renderLoadError err)
        assertContains "parse error" (renderLoadError err)
    , testCase "renderLoadError MarshalError contains field and message" $
        assertContains
          "name"
          (renderLoadError (MarshalError "name" "contains invalid characters"))
    , testCase "scopes [\"Build\"] decodes to {Build}" $
        assertScopes "BUILD_ONLY" (Set.fromList [Build]) (envDeploymentJSON "BUILD_ONLY" ",\"scopes\":[\"Build\"]")
    , testCase "missing scopes defaults to {Runtime}" $
        assertScopes "X" (Set.fromList [Runtime]) (envDeploymentJSON "X" "")
    , testCase "empty scopes array defaults to {Runtime}" $
        assertScopes "X" (Set.fromList [Runtime]) (envDeploymentJSON "X" ",\"scopes\":[]")
    , testCase "multiple scopes [\"Runtime\",\"Build\"] decode to both" $
        assertScopes
          "BOTH"
          (Set.fromList [Runtime, Build])
          (envDeploymentJSON "BOTH" ",\"scopes\":[\"Runtime\",\"Build\"]")
    , testCase "unknown scope token returns MarshalError ...scopes" $
        case decodeDeployment (BC.pack (envDeploymentJSON "X" ",\"scopes\":[\"Nope\"]")) of
          Left (MarshalError field msg)
            | ".scopes" `Text.isInfixOf` field ->
                assertContains "unknown env scope" msg
          other -> assertFailure ("expected MarshalError ...scopes, got: " <> show other)
    , -- A config-as-program is ordinary Haskell, so it can block forever. With
      -- no bound it wedges whichever thread loaded it — for nagared, a webhook
      -- handler. The budget is 1 second here so the test costs one runghc
      -- compile plus a second, not the 120s production default.
      testCase "a config that never terminates returns LoadTimedOut" $ do
        result <- withConfigFixture sleepingConfig (runConfigWith (ConfigTimeout 1))
        case result of
          Left (LoadTimedOut _ 1) -> pure ()
          other -> assertFailure ("expected LoadTimedOut _ 1, got: " <> show other)
    , testCase "renderLoadError LoadTimedOut names the path and the budget" $ do
        let err = LoadTimedOut "/app/Config.hs" 1
        assertContains "/app/Config.hs" (renderLoadError err)
        assertContains "timed out after 1s" (renderLoadError err)
    , testCase "defaultConfigTimeout is 120 seconds" $
        configTimeoutSeconds defaultConfigTimeout @?= 120
    ]

-- | A minimal valid Deployment JSON with a single Literal env entry whose
-- @scopes@ suffix is the given JSON fragment (e.g. @,"scopes":["Build"]@ or @""@).
envDeploymentJSON :: String -> String -> String
envDeploymentJSON var scopesField =
  "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\""
    <> ",\"port\":8080,\"env\":[{\"varName\":\""
    <> var
    <> "\",\"kind\":\"Literal\",\"value\":\"v\""
    <> scopesField
    <> "}]}"

-- | Decode the JSON and assert the named env var's scope set matches.
assertScopes :: Text -> Set EnvScope -> String -> Assertion
assertScopes var expected json =
  case decodeDeployment (BC.pack json) of
    Right Deployment {env = m} ->
      case Map.lookup key m of
        Just sev -> scopes sev @?= expected
        Nothing -> assertFailure ("env var " <> Text.unpack var <> " not found in decoded map")
    other -> assertFailure ("expected Right, got: " <> show other)
  where
    key = either (error . Text.unpack) id (mkEnvName var)

-- | Write Haskell source to a temp file and run the action on its path.
withConfigFixture :: String -> (FilePath -> IO a) -> IO a
withConfigFixture content action =
  withSystemTempFile "Config.hs" $ \path h -> do
    hPutStr h content
    hClose h
    action path

badNameJSON :: String
badNameJSON =
  "{\"name\":\"Hello_World\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[]}"

badScaleJSON :: String
badScaleJSON =
  "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[],\"scaleMin\":5,\"scaleMax\":1}"

bothEnvJSON :: String
bothEnvJSON =
  "{\"name\":\"hello\",\"namespace\":\"personal\",\"image\":\"gcr.io/foo/bar\",\"port\":8080,\"env\":[{\"varName\":\"X\",\"kind\":\"Literal\",\"value\":\"v\",\"secretName\":\"s\"}]}"

syntaxErrorConfig :: String
syntaxErrorConfig = "THIS IS NOT VALID HASKELL ###"

noEmitConfig :: String
noEmitConfig =
  unlines
    [ "module Main (main) where"
    , "main :: IO ()"
    , "main = pure ()"
    ]

-- | A config that compiles and then blocks forever — the shape a runaway or
-- deliberately hostile @Config.hs@ takes.
sleepingConfig :: String
sleepingConfig =
  unlines
    [ "module Main (main) where"
    , "import Control.Concurrent (threadDelay)"
    , "main :: IO ()"
    , "main = threadDelay maxBound"
    ]

assertContains :: Text -> Text -> Assertion
assertContains needle haystack
  | needle `Text.isInfixOf` haystack = pure ()
  | otherwise =
      assertFailure ("expected " <> show needle <> " to appear in: " <> Text.unpack haystack)
