-- | Failure-mode tests for 'Nagare.Dsl.Load' (config-as-program / Branch B).
--
-- The subprocess paths (compile error, missing binding) use a temp file; the
-- 'MarshalError' re-validation path is tested directly through the pure
-- 'decodeDeployment' so it needs no @runghc@ invocation.
module LoadSpec (loadTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Load
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
    ]

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

assertContains :: Text -> Text -> Assertion
assertContains needle haystack
  | needle `Text.isInfixOf` haystack = pure ()
  | otherwise =
      assertFailure ("expected " <> show needle <> " to appear in: " <> Text.unpack haystack)
