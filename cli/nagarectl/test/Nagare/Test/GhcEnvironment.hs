-- | GhcEnvironment responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.GhcEnvironment
  ( ghcEnvTests
  )
where

import Data.List (isInfixOf, isSuffixOf)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.GhcEnv (findGhcEnvForCompilerIn, findGhcEnvIn)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )

-- | EP-6 M1: the GHC-env auto-resolver's testable core. 'findGhcEnvIn' returns
-- the first @.ghc.environment.*@ across the given dirs (absolute), else Nothing.
ghcEnvTests :: [TestTree]
ghcEnvTests =
  [ testCase "findGhcEnvIn finds a planted .ghc.environment file" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        let envFile = root </> ".ghc.environment.aarch64-darwin-9.12.3"
        writeFile envFile "package-db dummy\n"
        found <- findGhcEnvIn [root]
        case found of
          Just p -> assertBool "returns the planted file (absolute)" (".ghc.environment.aarch64-darwin-9.12.3" `isSuffixOf` p)
          Nothing -> assertFailure "expected to find the planted env file"
  , testCase "findGhcEnvIn returns Nothing when no env file exists" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        found <- findGhcEnvIn [root]
        found @?= Nothing
  , testCase "findGhcEnvIn skips a nonexistent directory" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        found <- findGhcEnvIn [root </> "does-not-exist"]
        found @?= Nothing
  , testCase "findGhcEnvIn returns the first hit across dirs" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        let d1 = root </> "empty"
            d2 = root </> "haz"
        createDirectoryIfMissing True d1
        createDirectoryIfMissing True d2
        writeFile (d2 </> ".ghc.environment.x") "x\n"
        found <- findGhcEnvIn [d1, d2]
        case found of
          Just p -> assertBool "from the second dir" ("haz" `isInfixOf` p)
          Nothing -> assertFailure "expected a hit in the second dir"
  , testCase "compiler-specific lookup skips a stale package environment" $
      withSystemTempDirectory "nagare-ghcenv" $ \root -> do
        writeFile (root </> ".ghc.environment.aarch64-darwin-9.12.3") "stale\n"
        writeFile (root </> ".ghc.environment.aarch64-darwin-9.12.4") "current\n"
        found <- findGhcEnvForCompilerIn "9.12.4" [root]
        case found of
          Just p ->
            assertBool
              "selected the current compiler"
              (".ghc.environment.aarch64-darwin-9.12.4" `isSuffixOf` p)
          Nothing -> assertFailure "expected the current GHC environment"
  ]
