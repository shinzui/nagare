{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | GCS transport using a command-local SDK environment. The caller supplies
-- credentials explicitly after checking context and bucket ownership; quota
-- attribution is not an ownership check. No ambient credential discovery occurs.
-- SDK source: mori://brendanhay/gogol/repos/gogol
module Nagare.Inventory.Store.Gogol
  ( StorageCredentials
  , StorageEnv
  , newGogolObjectOps
  , gogolObjectOpsWithEnv
  , newGogolObjectOpsWithToken
  , validateGogolLocation
  , inventoryManagerSettings
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (Handler (..), IOException, catches)
import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isControl, isDigit)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Gogol qualified as G
import Gogol.Auth qualified as Auth
import Gogol.Env qualified as Env
import Gogol.Storage qualified as S
import Gogol.Storage.Objects.Get qualified as Get
import Gogol.Storage.Objects.Insert qualified as Insert
import Gogol.Storage.Objects.List qualified as List
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (statusCode, urlEncode)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Timeout (timeout)

type StorageEnv = G.Env '[S.Devstorage'ReadWrite]

type StorageCredentials = Auth.Credentials '[S.Devstorage'ReadWrite]

data Failure = Failure !(Maybe Int)

-- SDK exceptions can carry bearer tokens in requests and private response bytes.
-- Keep only the HTTP status, and never catch cancellation as an ordinary failure.
attempt :: IO a -> IO (Either Failure a)
attempt action = do
  bounded <-
    timeout 20000000 $
      (Right <$> action)
        `catches` [ Handler $ \(err :: G.Error) ->
                      pure
                        ( Left
                            ( Failure
                                ( case err of
                                    G.ServiceError value -> Just (statusCode (G._serviceStatus value))
                                    _ -> Nothing
                                )
                            )
                        )
                  , Handler $ \(_ :: HTTP.HttpException) -> pure (Left (Failure Nothing))
                  , Handler $ \(_ :: IOException) -> pure (Left (Failure Nothing))
                  , Handler $ \(_ :: Auth.AuthError) -> pure (Left (Failure Nothing))
                  ]
  pure (fromMaybe (Left (Failure Nothing)) bounded)

-- | Apply to the manager used by the supplied environment as well as auth
-- refresh. Conditional uploads are never implicitly retried. Media stays raw.
inventoryManagerSettings :: HTTP.ManagerSettings
inventoryManagerSettings =
  tlsManagerSettings
    { HTTP.managerRetryableException = const False
    , HTTP.managerModifyRequest = \request ->
        pure
          request
            { HTTP.redirectCount = 0
            , HTTP.responseTimeout = HTTP.responseTimeoutMicro 20000000
            , HTTP.decompress = const False
            }
    }

newGogolObjectOps :: StorageCredentials -> Text -> Text -> IO (Either Text ObjectOps)
newGogolObjectOps credentials project url = case location project url of
  Left reason -> pure (Left reason)
  Right _ -> do
    initialized <- attempt $ do
      manager <- HTTP.newManager inventoryManagerSettings
      G.newEnvWith credentials (\_ _ -> pure ()) manager
    pure $ case initialized of
      Left _ -> Left "inventory GCS credentials could not be initialized"
      Right env -> gogolObjectOpsWithEnv env project url

-- | Injection boundary for explicit credential lifecycle and local HTTP tests.
-- The environment must use 'inventoryManagerSettings'; production construction
-- uses 'newGogolObjectOps'. Retain this environment for the whole command.
gogolObjectOpsWithEnv :: StorageEnv -> Text -> Text -> Either Text ObjectOps
gogolObjectOpsWithEnv supplied = objectOpsWithEnvironment (pure supplied)

-- | The manager and token source live for the command. Gogol's opaque auth store
-- lacks a callback credential constructor. Load each bounded request's token via
-- a private, immediately removed temporary file, avoiding a persistent token file
-- or background refresh thread. Its SDK token lifetime (60s) exceeds the whole
-- request budget (20s); the external source owns real expiry and refresh.
newGogolObjectOpsWithToken :: IO Text -> (StorageEnv -> StorageEnv) -> Text -> Text -> IO (Either Text ObjectOps)
newGogolObjectOpsWithToken token configureEnv project url = case location project url of
  Left reason -> pure (Left reason)
  Right _ -> do
    manager <- HTTP.newManager inventoryManagerSettings
    let environment = do
          access <- token
          withSystemTempFile "nagare-gcs-token" $ \path handle -> do
            BS.hPut handle (TE.encodeUtf8 access)
            hClose handle
            configureEnv <$> (G.newEnvWith (Auth.FromTokenFile path) (\_ _ -> pure ()) manager :: IO StorageEnv)
    pure (objectOpsWithEnvironment environment project url)

objectOpsWithEnvironment :: IO StorageEnv -> Text -> Text -> Either Text ObjectOps
objectOpsWithEnvironment environment project url = do
  (bucket, root) <- location project url
  let sdk :: (StorageEnv -> IO a) -> IO (Either Failure a)
      sdk action = attempt (environment >>= action . Env.configure (G.serviceTimeout ?~ 20))
      full (ObjectName key) = root <> "/" <> key
      request name =
        (S.newStorageObjectsGet bucket (encodePart (full name)))
          { Get.userProject = Just project
          }
      metadata name object = do
        unless
          (object.name == Just (full name) && object.bucket == Just bucket)
          (Left "inventory object metadata has a foreign identity")
        gen <- maybe (Left "inventory object generation is missing") Right object.generation
        unless (gen > 0) (Left "inventory object generation is invalid")
        size <- maybe (Left "inventory object size is missing") Right object.size
        pure (gen, size)
      download name object = case metadata name object of
        Left reason -> pure (Left reason)
        Right (gen, size) -> do
          result <- sdk $ \env -> G.runResourceT $ G.download env ((request name) {Get.generation = Just gen}) >>= G.sinkLBS
          pure $ case result of
            Right bytes | toInteger (LBS.length bytes) == toInteger size -> Right (Generation (toInteger gen), LBS.toStrict bytes)
            _ -> Left "inventory object generation could not be downloaded completely"
      -- Consume every continuation page before proving absence or returning a
      -- journal batch. Reject repeated tokens, duplicate keys and foreign data.
      listing requested = pages Set.empty Map.empty Nothing
        where
          prefix = full requested
          pages tokens found token = do
            result <-
              sdk $ \env ->
                G.runResourceT $
                  G.send
                    env
                    ((S.newStorageObjectsList bucket) {List.prefix = Just prefix, List.pageToken = token, List.userProject = Just project})
            case result of
              Left _ -> pure (Left "inventory object listing failed")
              Right response -> case foldM (add prefix) found (fromMaybe [] response.items) of
                Left reason -> pure (Left reason)
                Right accumulated -> case response.nextPageToken of
                  Nothing -> pure (Right accumulated)
                  Just next
                    | T.null next || Set.member next tokens || Set.size tokens >= 10000 ->
                        pure (Left "inventory object listing has an invalid continuation")
                  Just next -> pages (Set.insert next tokens) accumulated (Just next)
          add prefix found object = do
            name <- maybe (Left "inventory object listing omitted a name") Right object.name
            unless (prefix `T.isPrefixOf` name) (Left "inventory object listing escaped its requested prefix")
            relative <- maybe (Left "inventory object listing escaped its private prefix") Right (T.stripPrefix (root <> "/") name)
            let key = ObjectName relative
            validateKey False key
            _ <- metadata key object
            when (Map.member key found) (Left "inventory object listing repeated a name")
            pure (Map.insert key object found)
      get name = case validateKey False name of
        Left reason -> pure (GetUnknown reason)
        Right () -> do
          result <- sdk $ \env -> G.runResourceT $ G.send env (request name)
          case result of
            Right object -> either GetUnknown (uncurry ObjectFound) <$> download name object
            Left (Failure (Just 404)) -> do
              listed <- listing name
              pure $ case listed of
                Right objects | Map.notMember name objects -> ObjectAbsent
                _ -> GetUnknown "inventory object absence could not be confirmed"
            Left _ -> pure (GetUnknown "inventory object metadata could not be read")
      put condition name bytes = case (validateKey False name, conditionNumber condition) of
        (Left reason, _) -> pure (PutNoEffect reason)
        (_, Left reason) -> pure (PutNoEffect reason)
        (Right (), Right expected) -> do
          result <-
            sdk $ \env ->
              G.runResourceT $
                G.upload
                  env
                  ( (S.newStorageObjectsInsert bucket S.newObject)
                      { Insert.name = Just (full name)
                      , Insert.ifGenerationMatch = Just expected
                      , Insert.userProject = Just project
                      }
                  )
                  (G.GBody "application/octet-stream" (HTTP.RequestBodyBS bytes))
          case result of
            -- A definite CAS refusal must not be reclassified as success merely
            -- because a different writer put identical bytes at a new generation.
            Left (Failure (Just 412)) | IfGenerationMatches _ <- condition -> pure PutPreconditionFailed
            Right object
              | Right (gen, size) <- metadata name object
              , toInteger size == toInteger (BS.length bytes) ->
                  pure (PutWritten (Generation (toInteger gen)))
            _ -> classifyPutReadback condition bytes <$> get name
      batch name@(ObjectName prefix) = case validateKey False name of
        Left reason -> pure (Left reason)
        Right () -> do
          listed <- listing (ObjectName (prefix <> "/"))
          case listed of
            Left reason -> pure (Left reason)
            Right objects -> chunks (Map.toAscList objects)
          where
            -- A fixed window bounds both network concurrency and worker count.
            -- Listing metadata already supplies the generation: no per-entry
            -- describe, subprocess, or mutable-head rediscovery is needed.
            chunks [] = pure (Right Map.empty)
            chunks entries = do
              let (window, rest) = splitAt 8 entries
              fetched <- mapConcurrently (\(key, object) -> fmap (\(_, bytes) -> (key, bytes)) <$> download key object) window
              case sequence fetched of
                Left reason -> pure (Left reason)
                Right values -> fmap (Map.union (Map.fromList values)) <$> chunks rest
  pure
    ObjectOps
      { getObject = get
      , putObject = put
      , getObjects = batch
      , listObjects = \key -> case validateKey True key of
          Left reason -> pure (Left reason)
          Right () -> fmap Map.keys <$> listing key
      }

conditionNumber :: PutCondition -> Either Text Int64
conditionNumber IfAbsent = Right 0
conditionNumber (IfGenerationMatches (Generation value))
  | value > 0 && value <= toInteger (maxBound :: Int64) = Right (fromInteger value)
  | otherwise = Left "inventory conditional generation is out of range"

encodePart :: Text -> Text
encodePart = TE.decodeUtf8 . urlEncode False . TE.encodeUtf8

validateKey :: Bool -> ObjectName -> Either Text ()
validateKey allowEmpty (ObjectName key)
  | allowEmpty && T.null key = Right ()
  | T.any isControl key || not (all validPart (T.splitOn "/" (if allowEmpty then T.dropWhileEnd (== '/') key else key))) =
      Left "inventory object key is not a confined relative path"
  | otherwise = Right ()
  where
    validPart part = not (T.null part) && part /= "." && part /= ".."

location :: Text -> Text -> Either Text (Text, Text)
location project url = do
  when (T.null (T.strip project) || T.any isControl project) (Left "inventory GCS project is missing or invalid")
  suffix <- maybe (Left "inventory object store URL must start with gs://") Right (T.stripPrefix "gs://" url)
  let (bucket, raw) = T.breakOn "/" suffix
      root = T.dropWhileEnd (== '/') (T.drop 1 raw)
  unless
    (not (T.null bucket) && T.all (\c -> isAsciiLower c || (isDigit c && c <= '9') || c `elem` (".-_" :: String)) bucket)
    (Left "inventory GCS bucket is invalid")
  validateKey False (ObjectName root)
  pure (bucket, root)

validateGogolLocation :: Text -> Text -> Either Text ()
validateGogolLocation project url = () <$ location project url
