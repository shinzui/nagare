-- | EP-286 M2: the rotator's run against an in-memory API server that
-- enforces resourceVersion preconditions. It writes the public ConfigMap
-- before the Secret, so a conflict or a crash on either write is repaired by
-- the next run from the Secret alone.
module KeySetRotatorSpec (keySetRotatorTests) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.KeySet
import Nagare.KeySet.Rotator
import Test.Tasty
import Test.Tasty.HUnit

keySetRotatorTests :: TestTree
keySetRotatorTests =
  testGroup
    "key set rotator"
    [ testCase "a first run fills the key set, and a second run at once writes nothing" $ do
        server <- newServer
        rotateAt server start >>= expectRotated
        state <- secretState server
        fmap (^. #kid) (state ^. #active) @?= Just "k1"
        publicConsistent server
        writes <- writeCount server
        rotateAt server start >>= (@?= Right Unchanged)
        writeCount server >>= (@?= writes)
    , testCase "after a period the next key is promoted in both files" $ do
        server <- newServer
        _ <- rotateAt server start
        rotateAt server (minutesLater 60) >>= \case
          Right (Rotated events) -> assertBool "k2 was not activated" (Activated "k2" `elem` events)
          other -> assertFailure (show other)
        publicConsistent server
        fmap (^. #kid) . (^. #active) <$> secretState server >>= (@?= Just "k2")
    , testCase "a conflict on the ConfigMap writes nothing, and the next run completes" $ do
        server <- newServer
        failNext server "configmaps" WriteConflict
        rotateAt server start >>= expectLeft
        secretRaw server >>= (@?= Nothing)
        rotateAt server start >>= expectRotated
        publicConsistent server
    , testCase "a conflict or a crash between the writes leaves only a harmless public key, which the next run replaces" $
        forM_ [WriteConflict, WriteRefused "the process stopped"] $ \failure -> do
          server <- newServer
          failNext server "secrets" failure
          rotateAt server start >>= expectLeft
          secretRaw server >>= (@?= Nothing)
          rotateAt server (minutesLater 1) >>= expectRotated
          publicConsistent server
    , testCase "a hand-edited public file is restored from the Secret without a rotation" $ do
        server <- newServer
        _ <- rotateAt server start
        before <- secretRaw server
        edit server "configmaps" publicFileKey (String "{\"keys\":[]}")
        rotateAt server start >>= (@?= Right PublicRestored)
        publicConsistent server
        secretRaw server >>= (@?= before)
    , testCase "a missing policy or an unreadable private file is refused without a write" $ do
        server <- newServer
        edit server "configmaps" policyFileKey (String "{}")
        rotateAt server start >>= expectLeft
        writeCount server >>= (@?= 0)
        server' <- newServer
        edit server' "secrets" privateFileKey (String "bm90IGpzb24=")
        rotateAt server' start >>= expectLeft
        writeCount server' >>= (@?= 0)
    , testCase "a policy round-trips, and one the DSL refuses is refused" $ do
        decodePolicy (encodePolicy policy) @?= Right policy
        assertBool "an overlap over the period was accepted" (either (const True) (const False) (decodePolicy "{\"periodMinutes\":10,\"overlapMinutes\":20}"))
    ]

name' :: KeySetName
name' = either (error . T.unpack) id (mkKeySetName "view-grants")

policy :: RotationPolicy
policy = either (error . T.unpack) id (mkRotationPolicy (ok (mkMinutes 60)) (ok (mkMinutes 20)))

start :: UTCTime
start = UTCTime (fromGregorian 2026 12 1) 0

minutesLater :: Int -> UTCTime
minutesLater n = addUTCTime (fromIntegral (60 * n)) start

-- | The in-memory API server: objects by (resource, name) with their
-- resourceVersion, the failures to inject on the next write of a resource,
-- and a count of the writes it accepted.
data Server = Server
  { objects :: !(IORef (Map (Text, Text) (Int, Value)))
  , failures :: !(IORef (Map Text WriteFailure))
  , writes :: !(IORef Int)
  }

newServer :: IO Server
newServer = do
  objects' <-
    newIORef
      ( Map.fromList
          [ (("configmaps", keySetPublicName name'), (1, document "ConfigMap" (keySetPublicName name') [(policyFileKey, String (encodePolicy policy))]))
          , (("secrets", keySetSecretName name'), (1, document "Secret" (keySetSecretName name') []))
          ]
      )
  Server objects' <$> newIORef Map.empty <*> newIORef 0
  where
    document :: Text -> Text -> [(Text, Value)] -> Value
    document kind objectName fields =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= kind
        , "metadata" .= object ["name" .= objectName, "namespace" .= ("personal" :: Text)]
        , "data" .= object [Key.fromText k .= v | (k, v) <- fields]
        ]

client :: Server -> KubeObjects
client server =
  KubeObjects
    { readObject = \resource _ objectName -> do
        stored <- Map.lookup (resource, objectName) <$> readIORef (objects server)
        pure (Right (fmap (\(version, value) -> withVersion version value) stored))
    , replaceObject = \resource _ objectName value -> do
        injected <- Map.lookup resource <$> readIORef (failures server)
        modifyIORef' (failures server) (Map.delete resource)
        case injected of
          Just failure -> pure (Left failure)
          Nothing -> do
            stored <- Map.lookup (resource, objectName) <$> readIORef (objects server)
            case stored of
              Just (version, _)
                | versionOf value == Just (T.show version) -> do
                    modifyIORef' (objects server) (Map.insert (resource, objectName) (version + 1, value))
                    modifyIORef' (writes server) (+ 1)
                    pure (Right ())
              _ -> pure (Left WriteConflict)
    }
  where
    withVersion version = \case
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root ->
            Object (KM.insert "metadata" (Object (KM.insert "resourceVersion" (String (T.show version)) metadata)) root)
      other -> other
    versionOf = \case
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (String version) <- KM.lookup "resourceVersion" metadata ->
            Just version
      _ -> Nothing

rotateAt :: Server -> UTCTime -> IO (Either Text RotationRun)
rotateAt server now = rotateOnce (client server) now keys "personal" name'
  where
    seed = fromIntegral (floor (utctDayTime now) `mod` 200 :: Integer)
    keys = [KeyPair (BS.replicate 32 seed) (BS.replicate 32 (seed + 1)), KeyPair (BS.replicate 32 (seed + 2)) (BS.replicate 32 (seed + 3))]

failNext :: Server -> Text -> WriteFailure -> IO ()
failNext server resource failure = modifyIORef' (failures server) (Map.insert resource failure)

-- | An out-of-band change to one data field, which moves the resourceVersion.
edit :: Server -> Text -> Text -> Value -> IO ()
edit server resource fieldName value = modifyIORef' (objects server) (Map.adjust change (resource, objectName))
  where
    objectName = if resource == "secrets" then keySetSecretName name' else keySetPublicName name'
    change (version, Object root) =
      let fields = case KM.lookup "data" root of
            Just (Object existing) -> existing
            _ -> KM.empty
       in (version + 1, Object (KM.insert "data" (Object (KM.insert (Key.fromText fieldName) value fields)) root))
    change other = other

dataField :: Server -> Text -> Text -> Text -> IO (Maybe Text)
dataField server resource objectName fieldName = do
  stored <- Map.lookup (resource, objectName) <$> readIORef (objects server)
  pure $ case stored of
    Just (_, Object root)
      | Just (Object fields) <- KM.lookup "data" root
      , Just (String value) <- KM.lookup (Key.fromText fieldName) fields ->
          Just value
    _ -> Nothing

secretRaw :: Server -> IO (Maybe ByteString)
secretRaw server = fmap decode <$> dataField server "secrets" (keySetSecretName name') privateFileKey
  where
    decode value = either (error . ("secret field: " <>) . show) TE.encodeUtf8 (b64decode value)

secretState :: Server -> IO KeySetState
secretState server = secretRaw server >>= maybe (assertFailure "the Secret has no private file" >> pure emptyKeySet) (either (\e -> assertFailure (T.unpack e) >> pure emptyKeySet) pure . decodeKeySet)

-- | The public file is exactly the Secret's state without its seeds.
publicConsistent :: Server -> Assertion
publicConsistent server = do
  state <- secretState server
  published <- dataField server "configmaps" (keySetPublicName name') publicFileKey
  published @?= Just (TE.decodeUtf8 (LBS.toStrict (encodePublicKeySet policy state)))
  assertBool "the public file is not JSON" (either (const False) (const True) (eitherDecodeStrict (maybe "" TE.encodeUtf8 published) :: Either String Value))

writeCount :: Server -> IO Int
writeCount = readIORef . writes

expectRotated :: Either Text RotationRun -> Assertion
expectRotated = \case
  Right (Rotated _) -> pure ()
  other -> assertFailure ("expected a rotation, got " <> show other)

expectLeft :: Either Text RotationRun -> Assertion
expectLeft = \case
  Left _ -> pure ()
  other -> assertFailure ("expected a refusal, got " <> show other)

ok :: Either Text a -> a
ok = either (error . T.unpack) id
