-- | Server responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Server
  ( serverBuildTests
  )
where

import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Server.Build
  ( PreparedServerOutput (PreparedServerOutput)
  , prepareServerOutput
  )
import Nagare.Test.Support.Assertions (assertInfixStr)
import Nagare.Test.Support.Site
  ( demoServerSite
  , demoServerSiteWith
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

-- ---------------------------------------------------------------------------
-- Server build (EP-18)

serverBuildTests :: [TestTree]
serverBuildTests =
  [ testCase "skipBuild + existing .output resolves the output dir" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        createDirectoryIfMissing True (root </> ".output")
        result <- prepareServerOutput True demoServerSite root
        case result of
          Right (PreparedServerOutput outs) ->
            assertInfixStr ".output" (snd (head (toList' outs)))
          Left e -> assertFailure ("expected Right, got: " <> T.unpack e)
  , testCase "missing .output returns a clear error" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        result <- prepareServerOutput True demoServerSite root
        case result of
          Left _ -> pure ()
          Right _ -> assertFailure "expected Left for missing .output"
  , testCase "build command that exits non-zero is reported" $
      withSystemTempDirectory "nagare-srv" $ \root -> do
        result <- prepareServerOutput False (demoServerSiteWith "exit 4") root
        case result of
          Left e -> assertBool "mentions exit 4" (T.isInfixOf "exit 4" e)
          Right _ -> assertFailure "expected Left for failing build"
  ]
  where
    toList' ne = foldr (:) [] ne
