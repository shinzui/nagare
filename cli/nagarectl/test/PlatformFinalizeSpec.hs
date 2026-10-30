-- | EP-228 M1: closing a release transition survives a stop between the
-- local pin and the remote marker, and refuses when the head or the pin
-- changed under it.
module PlatformFinalizeSpec (platformFinalizeTests) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Data.Aeson (eitherDecode, encode)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import InventoryTransactionSpec (preparedFixtureHead)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterExecution (AdapterEffectCompleted), RecoveryDecision (RecoveryUnresolved))
import Nagare.Inventory.Store
import Nagare.Platform.Finalize
import Nagare.Platform.Transition (transitionContinueRefusal)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

platformFinalizeTests :: TestTree
platformFinalizeTests =
  testGroup
    "transition finalization (EP-228 M1)"
    [ testCase "a commit moves the pin, then closes the marker" $ do
        (store, pin, writes) <- opened id
        finalize (store, pin, writes) (const (pure ())) >>= either (assertFailure . T.unpack) (const (pure ()))
        readIORef pin >>= (@?= Just "0.5.0")
        readIORef writes >>= (@?= 1)
        markerOf store >>= (@?= Nothing)
    , testCase "a stop after the intent is finished by committing again; meanwhile planning refuses" $ do
        (store, pin, writes) <- opened id
        stopped <- try @ErrorCall (finalize (store, pin, writes) (crashAt AfterIntent))
        assertBool "the commit did not stop" (either (const True) (const False) stopped)
        marker <- markerOf store >>= maybe (assertFailure "the marker was closed" >> fail "") pure
        transitionFinalizing marker @?= Just "0.5.0"
        readIORef pin >>= (@?= Just "0.4.0")
        headValue <- currentHead store
        assertBool "a finalizing transition could be planned" (isJust (transitionContinueRefusal headValue marker "payload-t"))
        finalize (store, pin, writes) (const (pure ())) >>= either (assertFailure . T.unpack) (const (pure ()))
        (,) <$> readIORef pin <*> readIORef writes >>= (@?= (Just "0.5.0", 1))
        markerOf store >>= (@?= Nothing)
    , testCase "a stop after the pin is finished by committing again without writing the pin twice" $ do
        (store, pin, writes) <- opened id
        stopped <- try @ErrorCall (finalize (store, pin, writes) (crashAt AfterPin))
        assertBool "the commit did not stop" (either (const True) (const False) stopped)
        readIORef pin >>= (@?= Just "0.5.0")
        fmap (>>= transitionFinalizing) (markerOf store) >>= (@?= Just "0.5.0")
        finalize (store, pin, writes) (const (pure ())) >>= either (assertFailure . T.unpack) (const (pure ()))
        readIORef writes >>= (@?= 1)
        markerOf store >>= (@?= Nothing)
    , testCase "a transaction admitted before the lock refuses, and the pin does not move" $ do
        (store, pin, writes) <- opened id
        -- Another writer admits a review after the status was gathered.
        observed <- observeHead store >>= either (fail . show) pure
        current <- maybe (fail "no head") pure (observedHeadManifest observed)
        replaceObservedHead observed current {headGeneration = headGeneration current + 1, headActiveTransaction = Just "tx-admitted-meanwhile"} >>= either (fail . show) pure
        refused <- finalize (store, pin, writes) (const (pure ()))
        assertBool "a commit with an unresolved transaction moved on" (either ("unresolved transaction" `T.isInfixOf`) (const False) refused)
        (,) <$> readIORef pin <*> readIORef writes >>= (@?= (Just "0.4.0", 0))
        fmap (>>= transitionFinalizing) (markerOf store) >>= (@?= Nothing)
    , testCase "a foreign pin refuses; the transition stays finalizing until the pin is put back" $ do
        (store, pin, writes) <- opened id
        atomicModifyIORef' pin (const (Just "0.3.9", ()))
        refused <- finalize (store, pin, writes) (const (pure ()))
        assertBool "a foreign pin was overwritten" (either ("neither the transition's source" `T.isInfixOf`) (const False) refused)
        (,) <$> readIORef pin <*> readIORef writes >>= (@?= (Just "0.3.9", 0))
        atomicModifyIORef' pin (const (Just "0.4.0", ()))
        finalize (store, pin, writes) (const (pure ())) >>= either (assertFailure . T.unpack) (const (pure ()))
        readIORef pin >>= (@?= Just "0.5.0")
    , testCase "a marker without the intent encodes as before; with it, an older decoder would refuse" $ do
        let plain = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z" Nothing
            finalizing = plain {transitionFinalizing = Just "0.5.0"}
            rendered = TL.toStrict . TLE.decodeUtf8 . encode
        rendered plain @?= "{\"from\":\"0.4.0\",\"startedAt\":\"2026-10-11T00:00:00Z\",\"to\":\"payload-t\"}"
        assertBool "the intent is not on the wire" ("\"finalizing\":\"0.5.0\"" `T.isInfixOf` rendered finalizing)
        eitherDecode (encode finalizing) @?= Right finalizing
    ]
  where
    finalize (store, pin, writes) pause = finalizeTransition store (pinOps pin writes) pause "payload-t" (const False) "0.5.0"
    crashAt step reached = when (reached == step) (throwIO (ErrorCall "stopped"))
    markerOf store = headTransition <$> currentHead store
    currentHead store = readHead store >>= either (fail . show) pure >>= maybe (fail "no head") pure

-- | A store whose head carries an open transition from 0.4.0 to payload-t, a
-- context pin at 0.4.0, and a count of pin writes.
opened :: (HeadManifest -> HeadManifest) -> IO (InventoryStore, IORef (Maybe Text), IORef Int)
opened adjust = do
  store <- newMemoryStore
  _ <- preparedFixtureHead "operator-cli" (adjust . withOpen) store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryUnresolved "no recovery")) (\_ registry -> registry)
  (store,,) <$> newIORef (Just "0.4.0") <*> newIORef 0
  where
    withOpen headValue = headValue {headTransition = Just (TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z" Nothing)}

pinOps :: IORef (Maybe Text) -> IORef Int -> PinOps
pinOps pin writes =
  PinOps
    { readPin = Right <$> readIORef pin
    , writePin = \version -> Right () <$ (atomicModifyIORef' pin (const (Just version, ())) >> atomicModifyIORef' writes (\n -> (n + 1, ())))
    }
