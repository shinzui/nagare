-- | EP-243: the open context move in the inventory head, and the admission rule while it is open.
module Nagare.Test.ContextMoveStore
  ( contextMoveStoreTests
  )
where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Context.Move
import Nagare.Context.MoveStore
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Manifest (MoveMarker (..), moveReviewIdentity, parseMoveReviewIdentity)
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

contextMoveStoreTests :: [TestTree]
contextMoveStoreTests =
  [ testCase "a move opens on an idle head, reopens as itself, and refuses another kind" $ do
      store <- fixtureStore
      opened <- openMove store "ingress" "2026-11-16T00:00:00Z" "apps.example.com" sameDomainSteps >>= expectRight
      moveProgress opened @?= newMove sameDomainSteps
      again <- openMove store "ingress" "2026-11-17T00:00:00Z" "other.example.com" sameDomainSteps >>= expectRight
      again @?= opened
      refused <- openMove store "base-domain" "2026-11-17T00:00:00Z" "" sameDomainSteps
      assertRefusedWith "already open" refused
  , testCase "a move does not open beside an active transaction or a release transition" $ do
      active <- fixtureStore
      adjustHead active (\h -> h {headActiveTransaction = Just "tx-elsewhere"})
      openMove active "ingress" "t" "" sameDomainSteps >>= assertRefusedWith "tx-elsewhere"
      transition <- fixtureStore
      adjustHead transition (\h -> h {headTransition = Just (TransitionMarker "0.4.0" "payload-t" "t" Nothing)})
      openMove transition "ingress" "t" "" sameDomainSteps >>= assertRefusedWith "release transition"
  , testCase "progress saves on an idle head, refuses another step list, and is read back" $ do
      store <- fixtureStore
      saveMoveProgress store (newMove sameDomainSteps) >>= assertRefusedWith "no context move"
      _ <- openMove store "ingress" "t" "" sameDomainSteps >>= expectRight
      let started = newMove sameDomainSteps & #completed .~ 1 & #inProgress .~ Just MirrorZone
      saveMoveProgress store started >>= expectRight
      saveMoveProgress store started >>= expectRight
      fmap (fmap (fmap moveProgress)) (openMoveOf store) >>= (@?= Right (Just started))
      saveMoveProgress store (newMove [CheckPreconditions]) >>= assertRefusedWith "different step list"
      adjustHead store (\h -> h {headActiveTransaction = Just "tx-step"})
      saveMoveProgress store (started & #inProgress .~ Nothing & #completed .~ 2) >>= assertRefusedWith "tx-step"
  , testCase "a move closes only when every step finished or every completed step rolled back" $ do
      store <- fixtureStore
      _ <- openMove store "ingress" "t" "" sameDomainSteps >>= expectRight
      saveMoveProgress store (newMove sameDomainSteps & #completed .~ 4) >>= expectRight
      closeMove store >>= assertRefusedWith "confirm-direct"
      saveMoveProgress store (newMove sameDomainSteps & #completed .~ length sameDomainSteps) >>= expectRight
      _ <- closeMove store >>= expectRight
      openMoveOf store >>= (@?= Right Nothing)
      _ <- openMove store "ingress" "t" "" sameDomainSteps >>= expectRight
      saveMoveProgress store (newMove sameDomainSteps & #direction .~ RollingBack) >>= expectRight
      _ <- closeMove store >>= expectRight
      openMoveOf store >>= (@?= Right Nothing)
  , testCase "the marker round-trips, and a head refuses a move beside a transition and an unknown field" $ do
      store <- fixtureStore
      marker <- openMove store "ingress" "t" "apps.example.com" sameDomainSteps >>= expectRight
      eitherDecode (encode marker) @?= Right marker
      headValue <- readHead store >>= either (fail . show) pure >>= maybe (fail "no head") pure
      eitherDecode (encode headValue) @?= Right headValue
      let both = headValue {headTransition = Just (TransitionMarker "0.4.0" "payload-t" "t" Nothing)}
      assertBool "a head with both decoded" (isLeftOf (eitherDecode @HeadManifest (encode both)))
      let progress = toJSONRecord (newMove sameDomainSteps)
      assertBool "an unknown field decoded" (isLeftOf (eitherDecode @MoveRecord (encode (object ["steps" .= sameDomainSteps, "completed" .= (0 :: Int), "inProgress" .= (Nothing :: Maybe MoveStep), "direction" .= MovingForward, "extra" .= True]))))
      assertBool "a step in progress out of order decoded" (isLeftOf (eitherDecode @MoveRecord (encode (newMove sameDomainSteps & #completed .~ 2 & #inProgress .~ Just SwitchRecords))))
      eitherDecode progress @?= Right (newMove sameDomainSteps)
  , testCase "while a move is open only its step in progress is admitted" $ do
      let marker = MoveMarker "ingress" "t" "" (newMove sameDomainSteps & #completed .~ 1 & #inProgress .~ Just MirrorZone)
      moveAdmissionRefusal Nothing "nagare-bootstrap:payload" @?= Nothing
      assertBool "a move review without a move" (isJust (moveAdmissionRefusal Nothing (moveReviewIdentity "ingress" MirrorZone)))
      moveAdmissionRefusal (Just marker) (moveReviewIdentity "ingress" MirrorZone) @?= Nothing
      assertBool "another step" (isJust (moveAdmissionRefusal (Just marker) (moveReviewIdentity "ingress" SwitchRecords)))
      assertBool "another kind" (isJust (moveAdmissionRefusal (Just marker) (moveReviewIdentity "base-domain" MirrorZone)))
      assertBool "an ordinary review" (isJust (moveAdmissionRefusal (Just marker) "nagare-bootstrap:payload"))
      parseMoveReviewIdentity (moveReviewIdentity "ingress" CloseFirewall) @?= Just ("ingress", CloseFirewall)
  , testCase "the engine saving to the head stops, and a new process resumes from what the head says" $ do
      store <- fixtureStore
      marker <- openMove store "ingress" "t" "" sameDomainSteps >>= expectRight
      let stopAt target = MoveOps {performStep = \_ step -> pure (if step == target then StepWaiting "operator" else StepCompleted), saveMove = \r -> saveMoveProgress store r >>= either (fail . T.unpack) pure}
      (first', _) <- runMove (stopAt AwaitNameServers) (moveProgress marker)
      first' @?= MoveStopped AwaitNameServers (StepWaiting "operator")
      reread <- openMoveOf store >>= either (fail . T.unpack) pure >>= maybe (fail "no move") pure
      (moveProgress reread ^. #completed, moveProgress reread ^. #inProgress) @?= (2, Just AwaitNameServers)
      (second', finished) <- runMove (stopAt CommitMove `withCompleted` ()) (moveProgress reread)
      second' @?= MoveFinished
      finished ^. #completed @?= length sameDomainSteps
      _ <- closeMove store >>= expectRight
      pure ()
  ]
  where
    withCompleted ops () = ops {performStep = \_ _ -> pure StepCompleted}
    toJSONRecord = encode

fixtureStore :: IO InventoryStore
fixtureStore = do
  store <- newMemoryStore
  _ <- initializeStore store (ContextBinding (either (error . show) id (mkContextId "fixture")) (either (error . show) id (mkName "project"))) "move-test" >>= either (fail . show) pure
  pure store

adjustHead :: InventoryStore -> (HeadManifest -> HeadManifest) -> IO ()
adjustHead store change = do
  observed <- observeHead store >>= either (fail . show) pure
  current <- maybe (fail "no head") pure (observedHeadManifest observed)
  replaceObservedHead observed (change current) {headGeneration = headGeneration current + 1} >>= either (fail . show) (const (pure ()))

expectRight :: Either Text a -> IO a
expectRight = either (\reason -> assertFailure (T.unpack reason) >> fail "refused") pure

assertRefusedWith :: Text -> Either Text a -> Assertion
assertRefusedWith fragment = \case
  Left reason -> assertBool (T.unpack reason) (fragment `T.isInfixOf` reason)
  Right _ -> assertFailure ("expected a refusal naming " <> T.unpack fragment)

isLeftOf :: Either a b -> Bool
isLeftOf = either (const True) (const False)
