{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The admin API's read-only session on one context's GCS inventory store
-- (EP-196).
--
-- It authenticates as a dedicated reader service account from a key file,
-- never through gcloud, the operator's workspace or the node's credential,
-- and requests only the read-only storage scope. Its object operations are
-- exact GETs: a 404 is absence, with no listing to prove it; writes and
-- listings are refused before any request. Every fresh head read first
-- rechecks that the bucket belongs to the configured project number, so a
-- reused bucket name cannot serve another project's history. The session
-- (HTTP manager and token store) lives for the server; gogol refreshes an
-- expiring token once for all waiting requests. The caller's deadline cancels
-- any request.
-- SDK source: mori://brendanhay/gogol/repos/gogol
module Nagare.Inventory.Store.Service
  ( ServiceStoreConfig (..)
  , ServiceStore (..)
  , ReaderEnv
  , openServiceStore
  , readOnlyObjectOps
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (Handler (..), IOException, catches)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Gogol qualified as G
import Gogol.Auth qualified as Auth
import Gogol.Env qualified as Env
import Gogol.Internal.Auth qualified as AuthInternal
import Gogol.Storage qualified as S
import Gogol.Storage.Objects.Get qualified as Get
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store
  ( HeadManifest
  , InventoryStore
  , StoreError (..)
  , openObjectStoreReadOnly
  , readHead
  )
import Nagare.Inventory.Store.Gogol (gogolLocation)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types (ContextBinding, nameText)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode, urlEncode)

-- | An SDK environment that can only read storage.
type ReaderEnv = G.Env '[S.Devstorage'ReadOnly]

data ServiceStoreConfig = ServiceStoreConfig
  { binding :: !ContextBinding
  , projectNumber :: !Text
  -- ^ The numeric number of the context's project, from its deployment
  -- configuration; the bucket's owner must equal it.
  , storeUrl :: !Text
  -- ^ @gs://<bucket>/<prefix>@ of the context's inventory.
  , credentialsFile :: !FilePath
  -- ^ The reader service account's key, a @service_account@ JSON file.
  , cacheDirectory :: !(Maybe FilePath)
  -- ^ A private writable directory for verified immutable objects.
  , managerSettings :: !HTTP.ManagerSettings
  , configureEnv :: !(ReaderEnv -> ReaderEnv)
  -- ^ Production uses 'id'; tests point the SDK at a loopback server.
  }
  deriving stock (Generic)

-- | A read-only store and the action the recorded reader uses for a fresh,
-- ownership-checked head.
data ServiceStore = ServiceStore
  { store :: !InventoryStore
  , freshHead :: !(IO (Either StoreError (Maybe HeadManifest)))
  }
  deriving stock (Generic)

openServiceStore :: ServiceStoreConfig -> IO (Either StoreError ServiceStore)
openServiceStore config = do
  keyBytes <- BS.readFile (config ^. #credentialsFile)
  case (gogolLocation (projectText config) (config ^. #storeUrl), serviceAccount keyBytes) of
    (Left reason, _) -> pure (Left (StoreConditionFailed reason))
    (_, Left reason) -> pure (Left (StoreCredentialsUnavailable reason))
    (Right (bucket, root), Right account) -> do
      manager <- HTTP.newManager (config ^. #managerSettings)
      -- The initial token exchange happens here; a refused one is a
      -- credential failure, not an exception escaping the server's start.
      created <- attempt (G.newEnvWith (Auth.FromAccount account) (\_ _ -> pure ()) manager :: IO ReaderEnv)
      case created of
        Left _ -> pure (Left (StoreCredentialsUnavailable "the reader service account could not obtain a token"))
        Right sdk -> opening ((config ^. #configureEnv) (Env.configure (G.serviceTimeout ?~ 20) sdk)) bucket root
  where
    projectText value = nameText (value ^. #binding . #project)
    opening env bucket root = do
      let ops = readOnlyObjectOps env bucket root
      opened <- openObjectStoreReadOnly ops (config ^. #binding) "admin-api" (config ^. #cacheDirectory)
      pure $ do
        inventory <- opened
        pure
          ServiceStore
            { store = inventory
            , freshHead = do
                owner <- bucketOwner env bucket
                case owner of
                  Left failure -> pure (Left failure)
                  Right number
                    | number == config ^. #projectNumber -> readHead inventory
                    | otherwise -> pure (Left (StoreConditionFailed "the inventory bucket belongs to another project"))
            }

-- | The key must be a service account's: an authorized user would be a
-- person's refreshable credential.
serviceAccount :: BS.ByteString -> Either Text AuthInternal.ServiceAccount
serviceAccount bytes = do
  value <- first (const "the reader credential is not JSON") (eitherDecodeStrict' bytes)
  case value of
    Object fields | KeyMap.lookup "type" fields == Just (String "service_account") -> Right ()
    _ -> Left "the reader credential is not a service account key"
  first (const "the reader credential is not a valid service account key") (eitherDecodeStrict' bytes)

-- | The bucket's owning project number.
bucketOwner :: ReaderEnv -> Text -> IO (Either StoreError Text)
bucketOwner env bucket = do
  result <- attempt (G.runResourceT (G.send env (S.newStorageBucketsGet bucket)))
  pure $ case result of
    Right value
      | value.name == Just bucket
      , Just number <- value.projectNumber
      , number > 0 ->
          Right (T.pack (show number))
    Right _ -> Left (StoreConditionFailed "the inventory bucket has no valid owning project number")
    Left CredentialFailure -> Left (StoreCredentialsUnavailable "the reader service account could not obtain a token")
    Left (StatusFailure (Just 404)) -> Left (StoreConditionFailed "the inventory bucket does not exist")
    Left _ -> Left (StoreIoError "the inventory bucket metadata could not be read")

-- | Exact object reads under one prefix. A 404 is absence; a write or a
-- listing is refused without a request.
readOnlyObjectOps :: ReaderEnv -> Text -> Text -> ObjectOps
readOnlyObjectOps env bucket root =
  ObjectOps
    { getObject = get
    , putObject = \_ _ _ -> pure (PutNoEffect "the admin API's inventory store is read-only")
    , getObjects = \_ -> pure (Left "the admin API's inventory store does not list")
    , listObjects = \_ -> pure (Left "the admin API's inventory store does not list")
    , pauseBeforeRetry = threadDelay
    }
  where
    full (ObjectName key) = root <> "/" <> key
    request name = S.newStorageObjectsGet bucket (TE.decodeUtf8 (urlEncode False (TE.encodeUtf8 (full name))))
    get name
      | not (confined name) = pure (GetUnknown "inventory object key is not a confined relative path")
      | otherwise = do
          described <- attempt (G.runResourceT (G.send env (request name)))
          case described of
            Left (StatusFailure (Just 404)) -> pure ObjectAbsent
            Left _ -> pure (GetUnknown "inventory object metadata could not be read")
            Right object
              | object.name /= Just (full name) || object.bucket /= Just bucket -> pure (GetUnknown "inventory object metadata has a foreign identity")
              | Just generation <- object.generation
              , generation > 0
              , Just size <- object.size -> do
                  downloaded <- attempt (G.runResourceT (G.download env ((request name) {Get.generation = Just generation}) >>= G.sinkLBS))
                  pure $ case downloaded of
                    Right bytes
                      | toInteger (LBS.length bytes) == toInteger size -> ObjectFound (Generation (toInteger generation)) (LBS.toStrict bytes)
                    _ -> GetUnknown "inventory object generation could not be downloaded completely"
              | otherwise -> pure (GetUnknown "inventory object metadata has no generation or size")
    confined (ObjectName key) = not (T.null key) && all (\part -> not (T.null part) && part `notElem` [".", ".."]) (T.splitOn "/" key) && not (T.any (< ' ') key)

data Failure = StatusFailure !(Maybe Int) | CredentialFailure

-- | SDK exceptions can carry tokens and private response bytes; keep only
-- the status, and never catch cancellation.
attempt :: IO a -> IO (Either Failure a)
attempt action =
  (Right <$> action)
    `catches` [ Handler $ \(failure :: G.Error) -> pure . Left $ case failure of
                  G.ServiceError value -> StatusFailure (Just (statusCode (G._serviceStatus value)))
                  _ -> StatusFailure Nothing
              , Handler $ \(_ :: Auth.AuthError) -> pure (Left CredentialFailure)
              , Handler $ \(_ :: HTTP.HttpException) -> pure (Left (StatusFailure Nothing))
              , Handler $ \(_ :: IOException) -> pure (Left (StatusFailure Nothing))
              ]
