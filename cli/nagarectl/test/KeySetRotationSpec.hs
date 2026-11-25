-- | EP-286 M1: the rotation step. Over arbitrary schedules of steps and clock
-- advances, a signer's key is always known to a verifier one step behind or
-- ahead, a key is withdrawn no sooner than the overlap after it stopped
-- signing, a repeated step changes nothing, and the private file holds the
-- whole state.
module KeySetRotationSpec (keySetRotationTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, diffUTCTime, fromGregorian)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Prelude
import Nagare.KeySet
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

keySetRotationTests :: TestTree
keySetRotationTests =
  testGroup
    "key set rotation"
    [ testCase "an empty set gets an active key and a next key at once" $ do
        let (state, events) = step start emptyKeySet
        fmap (^. #kid) (state ^. #active) @?= Just "k1"
        fmap (^. #kid) (state ^. #next) @?= Just "k2"
        state ^. #previous @?= Nothing
        events @?= [Generated "k1", Generated "k2", Activated "k1"]
        map (^. #kid) (state ^. #history) @?= ["k1"]
    , testCase "after a period next is promoted, and the old key is withdrawn after the overlap" $ do
        let created = fst (step start emptyKeySet)
            early = fst (step (minutesAfter 59 start) created)
            promoted = fst (step (minutesAfter 60 start) created)
            during = fst (step (minutesAfter 79 start) promoted)
            after = fst (step (minutesAfter 80 start) promoted)
        early @?= created
        kids promoted @?= [("next", "k3"), ("active", "k2"), ("previous", "k1")]
        kids during @?= kids promoted
        kids after @?= [("next", "k3"), ("active", "k2")]
        map (^. #kid) (after ^. #history) @?= ["k2", "k1"]
    , testCase "the public file holds no private key and is not a whole state" $ do
        let state = fst (step start emptyKeySet)
            publicFile = LBS.toStrict (encodePublicKeySet policy state)
        assertBool "a private part is in the public file" (not ("\"d\":" `BS.isInfixOf` publicFile))
        assertBool "the private file has no private part" ("\"d\":" `BS.isInfixOf` LBS.toStrict (encodePrivateKeySet policy state))
        assertBool "the public file decodes to a state" (either (const True) (const False) (decodeKeySet publicFile))
    , testProperty "a signer's key is known one step behind and one step ahead" $
        forAll schedules $ \(rotation, advances) ->
          let states = run rotation advances
           in and
                [ activeKid now' `elem` kidsOf before' && activeKid now' `elem` kidsOf after'
                | (before', now', after') <- zip3 states (drop 1 states) (drop 2 states)
                , isJust (before' ^. #active)
                ]
    , testProperty "a key is withdrawn no sooner than the overlap after it stopped signing" . checkCoverage $
        forAll schedules $ \(rotation, advances) ->
          let timed = runTimed rotation advances
              stopped = Map.fromList [(kid', at') | (at', events) <- timed, Superseded kid' <- events]
              overlapSeconds = fromIntegral (60 * minutesInt (rotation ^. #overlap))
           in cover 40 (not (null [() | (_, events) <- timed, Withdrawn _ <- events])) "a key was withdrawn" $
                and
                  [ maybe False (\since -> diffUTCTime at' since >= overlapSeconds) (Map.lookup kid' stopped)
                  | (at', events) <- timed
                  , Withdrawn kid' <- events
                  ]
    , testProperty "a step repeated at the same instant changes nothing" $
        forAll schedules $ \(rotation, advances) ->
          and
            [ rotateStep at' rotation freshKeys state == (state, [])
            | (at', state) <- zip (times advances) (drop 1 (run rotation advances))
            ]
    , testProperty "the history gains one entry per activation, up to its limit" $
        forAll schedules $ \(rotation, advances) ->
          let timed = runTimed rotation advances
              activations = length [() | (_, events) <- timed, Activated _ <- events]
              final = last (run rotation advances)
           in length (final ^. #history) == min historyLimit activations
    , testProperty "the private file decodes to the whole state" $
        forAll schedules $ \(rotation, advances) ->
          all (\state -> decodeKeySet (LBS.toStrict (encodePrivateKeySet rotation state)) == Right state) (run rotation advances)
    ]

start :: UTCTime
start = UTCTime (fromGregorian 2026 12 1) 0

minutesAfter :: Int -> UTCTime -> UTCTime
minutesAfter n = addUTCTime (fromIntegral (60 * n))

policy :: RotationPolicy
policy = either (error . T.unpack) id (mkRotationPolicy (ok (mkMinutes 60)) (ok (mkMinutes 20)))

step :: UTCTime -> KeySetState -> (KeySetState, [RotationEvent])
step now = rotateStep now policy freshKeys

-- | Distinct material for each draw; the step uses at most two.
freshKeys :: [KeyPair]
freshKeys = [KeyPair (BS.replicate 32 n) (BS.replicate 32 (n + 100)) | n <- [1, 2]]

kids :: KeySetState -> [(Text, Text)]
kids state = [(keyStatus status, published ^. #kid) | (status, published) <- publishedKeys state]

kidsOf :: KeySetState -> [Text]
kidsOf = map snd . kids

activeKid :: KeySetState -> Text
activeKid state = maybe "" (^. #kid) (state ^. #active)

-- | A policy and a list of clock advances in seconds, covering skipped runs
-- (an advance longer than a period) and runs closer than the rotator's.
schedules :: Gen (RotationPolicy, [Int])
schedules = do
  period' <- chooseInt (minimumPeriod, 180)
  overlap' <- chooseInt (minimumOverlap, period')
  advances <- listOf1 (frequency [(6, chooseInt (60, 600)), (2, chooseInt (0, 59)), (1, chooseInt (600, 4 * 60 * period'))])
  pure (either (error . T.unpack) id (mkRotationPolicy (ok (mkMinutes period')) (ok (mkMinutes overlap'))), take 80 advances)

times :: [Int] -> [UTCTime]
times = scanl (\now advance -> addUTCTime (fromIntegral advance) now) start

-- | The states from empty, one per step: the first step runs at 'start'.
run :: RotationPolicy -> [Int] -> [KeySetState]
run rotation advances = emptyKeySet : map fst (drop 1 (scanl next' (emptyKeySet, []) (times advances)))
  where
    next' (state, _) now = rotateStep now rotation freshKeys state

runTimed :: RotationPolicy -> [Int] -> [(UTCTime, [RotationEvent])]
runTimed rotation advances = zip (times advances) (map snd (drop 1 (scanl next' (emptyKeySet, []) (times advances))))
  where
    next' (state, _) now = rotateStep now rotation freshKeys state

ok :: Either Text a -> a
ok = either (error . T.unpack) id
