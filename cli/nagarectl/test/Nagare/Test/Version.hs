-- | Version responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Version
  ( versionTests
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Either (isLeft)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Version
  ( BuildVersion (..)
  , Compatibility (..)
  , PlatformVersion (..)
  , comparePlatformVersions
  , parsePlatformVersion
  , renderBuildVersionJson
  , renderBuildVersionJsonWithTools
  , renderBuildVersionText
  , renderPlatformVersion
  )
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

versionTests :: [TestTree]
versionTests =
  [ testCase "text rendering includes the program and semantic version" $
      renderBuildVersionText (BuildVersion "1.2.3" Nothing) @?= "nagarectl 1.2.3"
  , testCase "JSON rendering preserves optional revision metadata" $
      (eitherDecodeStrict (renderBuildVersionJson (BuildVersion "1.2.3" (Just "abc123"))) :: Either String Aeson.Value)
        @?= Right (Aeson.object ["version" Aeson..= ("1.2.3" :: Text), "platformVersion" Aeson..= ("1.2.3" :: Text), "revision" Aeson..= ("abc123" :: Text)])
  , testCase "tool JSON reports resolved paths and explicit nulls" $
      ( eitherDecodeStrict
          ( renderBuildVersionJsonWithTools
              (BuildVersion "1.2.3" Nothing)
              [("pulumi", Just "/opt/bin/pulumi"), ("npm", Nothing)]
          ) ::
          Either String Aeson.Value
      )
        @?= Right
          ( Aeson.object
              [ "version" Aeson..= ("1.2.3" :: Text)
              , "platformVersion" Aeson..= ("1.2.3" :: Text)
              , "tools"
                  Aeson..= Aeson.object
                    [ "pulumi" Aeson..= (Just "/opt/bin/pulumi" :: Maybe FilePath)
                    , "npm" Aeson..= (Nothing :: Maybe FilePath)
                    ]
              ]
          )
  , testCase "platform versions round-trip releases and prereleases" $ do
      let release = PlatformVersion 2 4 7 Nothing
          candidate = PlatformVersion 2 4 7 (Just "rc.1")
      parsePlatformVersion "2.4.7" @?= Right release
      parsePlatformVersion "2.4.7-rc.1" @?= Right candidate
      renderPlatformVersion candidate @?= "2.4.7-rc.1"
      assertBool "leading zeros are invalid" (isLeft (parsePlatformVersion "02.4.7"))
      assertBool "missing patch is invalid" (isLeft (parsePlatformVersion "2.4"))
  , testCase "compatibility distinguishes exact, patch, minor, major, and legacy" $ do
      let running = PlatformVersion 1 3 2 Nothing
      comparePlatformVersions running (Just running) @?= Exact
      comparePlatformVersions running (Just (PlatformVersion 1 3 1 Nothing)) @?= PatchSkew
      comparePlatformVersions running (Just (PlatformVersion 1 2 9 Nothing)) @?= MinorUpgradeRequired
      comparePlatformVersions running (Just (PlatformVersion 2 0 0 Nothing)) @?= MajorIncompatible
      comparePlatformVersions running Nothing @?= LegacyUnknown
  ]
