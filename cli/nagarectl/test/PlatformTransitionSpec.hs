-- | The release transition's compatibility check (EP-172).
module PlatformTransitionSpec (platformTransitionTests) where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Nagare.Dsl.Prelude
import Nagare.Platform.Transition
import Nagare.Platform.Workspace (PayloadManifest)
import Test.Tasty
import Test.Tasty.HUnit

platformTransitionTests :: TestTree
platformTransitionTests =
  testGroup
    "release transition compatibility (EP-172)"
    [ testCase "a payload without the field accepts no source release" $ do
        manifest <- decoded "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.4.0\",\"sourceRevision\":null}"
        manifest ^. #transitionsFrom @?= []
        checkTransition manifest (Just "0.3.0") 1 @?= Left (UnsupportedSource "0.3.0" "0.4.0" [])
    , testCase "a listed source at the current wire version is accepted" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.4.0") 1 @?= Right (TransitionPair "0.4.0" "0.5.0")
    , testCase "an unlisted source, the target itself, and an unpinned context refuse" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.3.0") 1 @?= Left (UnsupportedSource "0.3.0" "0.5.0" ["0.4.0"])
        checkTransition manifest (Just "0.5.0") 1 @?= Left (AlreadyAtTarget "0.5.0")
        checkTransition manifest Nothing 1 @?= Left UnpinnedContext
    , testCase "a head wire version this payload does not read refuses" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.4.0") 2 @?= Left (UnsupportedStoreVersion 2 1 1)
        checkTransition manifest (Just "0.4.0") 0 @?= Left (UnsupportedStoreVersion 0 1 1)
    ]
  where
    current = "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.5.0\",\"sourceRevision\":null,\"transitionsFrom\":[\"0.4.0\"]}"
    decoded :: ByteString -> IO PayloadManifest
    decoded = either assertFailure pure . eitherDecodeStrict'
