-- | The release transition (EP-172): the compatibility check, and the store
-- head marker that admission opens for the first transition review, keeps for
-- the later ones, and that closes the store to every other review.
module PlatformTransitionSpec (platformTransitionTests) where

import Data.Aeson (eitherDecode, eitherDecodeStrict', encode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import InventoryTransactionSpec (preparedFixtureHead)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterExecution (AdapterEffectCompleted), AdapterRegistry, RecoveryDecision (RecoveryUnresolved))
import Nagare.Inventory.Execute (AdmissionError (..), applyReviewed)
import Nagare.Inventory.Plan (ReviewedPlan)
import Nagare.Inventory.Store
import Nagare.Platform.Transition
import Nagare.Platform.Workspace (PayloadManifest)
import Test.Tasty
import Test.Tasty.HUnit

platformTransitionTests :: TestTree
platformTransitionTests = testGroup "release transition (EP-172)" [compatibilityTests, markerTests]

compatibilityTests :: TestTree
compatibilityTests =
  testGroup
    "compatibility check"
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
    , testCase "a transition review's payload identity names the source release and the target payload" $ do
        transitionReviewIdentity "0.4.0" "payload-t" @?= "nagare-transition:0.4.0->payload-t"
        parseTransitionReviewIdentity "nagare-transition:0.4.0->payload-t" @?= Just ("0.4.0", "payload-t")
        parseTransitionReviewIdentity "nagare-bootstrap:payload-t" @?= Nothing
        parseTransitionReviewIdentity "nagare-transition:0.4.0->" @?= Nothing
        parseTransitionReviewIdentity "nagare-transition:->payload-t" @?= Nothing
    , testCase "a platform review expects the payload that planned it and the pin it was planned against" $ do
        manifest <- decoded current
        platformReviewExpectation manifest "nagare-bootstrap:p" @?= Just ("p", "0.5.0")
        platformReviewExpectation manifest (transitionReviewIdentity "0.4.0" "p") @?= Just ("p", "0.4.0")
        platformReviewExpectation manifest "operator-cli" @?= Nothing
    , testCase "only the target payload's nagarectl may continue an open transition" $ do
        let marker = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
        transitionOwnerRefusal marker "payload-t" @?= Nothing
        case transitionOwnerRefusal marker "payload-s" of
          Nothing -> assertFailure "a foreign payload continued the transition"
          Just reason -> assertBool (show reason) ("payload-t" `T.isInfixOf` reason && "payload-s" `T.isInfixOf` reason)
    ]
  where
    current = "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.5.0\",\"sourceRevision\":null,\"transitionsFrom\":[\"0.4.0\"]}"
    decoded :: ByteString -> IO PayloadManifest
    decoded = either assertFailure pure . eitherDecodeStrict'

markerTests :: TestTree
markerTests =
  testGroup
    "store head marker"
    [ testCase "admitting a transition review opens the marker, which the head wire keeps" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-t") id store
        _ <- applyReviewed store registry reviewed >>= expectRight
        headValue <- currentHead store
        marker <- maybe (assertFailure "no transition marker after admission" >> error "unreachable") pure (headTransition headValue)
        transitionSource marker @?= "0.4.0"
        transitionTarget marker @?= "payload-t"
        assertBool "the marker records when it opened" (not (T.null (transitionStartedAt marker)))
        eitherDecode (encode headValue) @?= Right headValue
        assertBool "an open transition is substantive history" (hasSubstantiveHistory headValue {headGeneration = 0, headSequence = 0, headAccepted = mempty, headConverged = mempty, headIncarnations = mempty})
    , testCase "while a transition is open, a review that is not its own refuses and names the target payload" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture "operator-cli" withOpen store
        errors <- applyReviewed store registry reviewed >>= expectLeft
        map admissionErrorCode (NE.toList errors) @?= ["open-transition"]
        assertBool (show errors) (all (("payload-t" `T.isInfixOf`) . admissionErrorMessage) errors)
        headValue <- currentHead store
        headTransition headValue @?= Just opened
        headActiveTransaction headValue @?= Nothing
    , testCase "a transition review for another pair is refused by the open one" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-u") withOpen store
        errors <- applyReviewed store registry reviewed >>= expectLeft
        map admissionErrorCode (NE.toList errors) @?= ["open-transition"]
    , testCase "a later review of the open transition is admitted and keeps the marker's start" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-t") withOpen store
        _ <- applyReviewed store registry reviewed >>= expectRight
        headValue <- currentHead store
        headTransition headValue @?= Just opened
    , testCase "the head wire refuses a transition marker with an unknown field" $ do
        store <- newMemoryStore
        (_, _) <- fixture "operator-cli" id store
        headValue <- currentHead store
        let withMarker = headValue {headTransition = Just opened}
            good = TL.toStrict (TLE.decodeUtf8 (encode withMarker))
            bad = T.replace "\"startedAt\"" "\"started\"" good
        assertBool "the marker encodes under the transition key" ("\"transition\"" `T.isInfixOf` good)
        eitherDecode (LBS.fromStrict (TE.encodeUtf8 good)) @?= Right withMarker
        case eitherDecode (LBS.fromStrict (TE.encodeUtf8 bad)) :: Either String HeadManifest of
          Left _ -> pure ()
          Right _ -> assertFailure "a marker with an unknown field decoded"
    ]
  where
    opened = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
    withOpen headValue = headValue {headTransition = Just opened}
    fixture :: Text -> (HeadManifest -> HeadManifest) -> InventoryStore -> IO (ReviewedPlan, AdapterRegistry)
    fixture identity adjust store =
      preparedFixtureHead identity adjust store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryUnresolved "no recovery")) (\_ registry -> registry)
    currentHead store = readHead store >>= expectRight >>= maybe (assertFailure "store has no head" >> error "unreachable") pure
    expectRight :: (Show e) => Either e a -> IO a
    expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
    expectLeft :: (Show a) => Either e a -> IO e
    expectLeft = either pure (\value -> assertFailure ("expected a refusal, got " <> show value) >> error "unreachable")
