-- | Context-bound store opening, including retained local-profile authority.
module Nagare.Inventory.Store.Target
  ( openTargetStoreReadOnly
  , openProfileReviewStoreReadOnly
  , openRemoteStore
  , remoteInventoryUrl
  )
where

import Control.Exception (IOException, try)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Context.Review (ProfileReview, profileReviewContext, profileReviewLocalRoot, profileReviewOriginal)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.Remote (remoteObjectOps)
import Nagare.Ops.PulumiBackend (gcsBucketOfUrl)
import Nagare.Resource.Types
import Nagare.Target
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (hClose)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (fileMode, getFileStatus, isDirectory, setFileMode)
import System.Posix.IO (OpenMode (WriteOnly), creat, defaultFileFlags, exclusive, fdToHandle, openFd)

openTargetStoreReadOnly :: ActiveTarget -> IO (Either StoreError InventoryStore)
openTargetStoreReadOnly target = do
  stateRoot <- nagareStateDir
  let path = stateRoot </> T.unpack (contextNameText (target ^. #contextName)) </> "inventory"
  case effectiveInventoryStore (target ^. #profile) of
    InventoryStoreLocal -> openFilesystemStoreReadOnly path
    InventoryStoreGcs -> openRemoteStore False target stateRoot

-- | A validated local removal review retains authority when its profile file
-- no longer exists. This opener never initializes history/cache/client state;
-- the caller verifies the completed removal receipt and original store head.
openProfileReviewStoreReadOnly :: ProfileReview -> IO (Either StoreError InventoryStore)
openProfileReviewStoreReadOnly review = do
  stateRoot <- nagareStateDir
  let profile = profileReviewOriginal review
      target = ActiveTarget (profileReviewContext review) profile
  case profileReviewLocalRoot review of
    Just _ -> openTargetStoreReadOnly (target & #profile . #inventoryStore .~ InventoryStoreLocal)
    Nothing -> openRemoteStoreWithProfile False target stateRoot (Right profile)

remoteInventoryUrl :: ActiveTarget -> T.Text
remoteInventoryUrl target =
  let profile = target ^. #profile
   in if T.null (profile ^. #inventoryStoreUrl)
        then defaultGcsInventoryStoreUrl (contextNameText (target ^. #contextName)) profile
        else profile ^. #inventoryStoreUrl

openRemoteStore :: Bool -> ActiveTarget -> FilePath -> IO (Either StoreError InventoryStore)
openRemoteStore mayInitialize target stateRoot = do
  stored <- readContextProfile (target ^. #contextName)
  openRemoteStoreWithProfile mayInitialize target stateRoot stored

openRemoteStoreWithProfile :: Bool -> ActiveTarget -> FilePath -> Either T.Text TargetProfile -> IO (Either StoreError InventoryStore)
openRemoteStoreWithProfile mayInitialize target stateRoot stored = do
  let contextName = target ^. #contextName
      profile = target ^. #profile
      project = profile ^. #project
      contextText = contextNameText contextName
      url =
        if T.null (profile ^. #inventoryStoreUrl)
          then defaultGcsInventoryStoreUrl contextText profile
          else profile ^. #inventoryStoreUrl
      invalid reason = Left (StoreConditionFailed reason)
  ambientProject <- lookupEnv "CLOUDSDK_CORE_PROJECT"
  case stored of
    Left reason -> pure (invalid reason)
    Right persisted
      | persisted ^. #project /= project ->
          pure (invalid "active project disagrees with the stored inventory context")
    Right persisted
      | remoteInventoryUrl (target & #profile .~ persisted) /= remoteInventoryUrl target ->
          pure (invalid "active remote inventory URL disagrees with the stored context")
    Right _
      | Just ambient <- ambientProject
      , T.pack ambient /= project ->
          pure (invalid "ambient gcloud project disagrees with the inventory context")
    Right _ -> case gcsBucketOfUrl url of
      Nothing -> pure (invalid "inventory store URL has no GCS bucket")
      Just _ -> do
        selected <- remoteObjectOps project url
        case selected of
          Left reason -> pure (invalid reason)
          Right ops -> do
            clientResult <- localStoreClientIdentity mayInitialize stateRoot contextText
            case clientResult of
              Left err -> pure (Left err)
              Right client -> do
                case (mkContextId contextText, mkName project) of
                  (Right contextId, Right providerName) -> do
                    let binding = ContextBinding contextId providerName
                    cacheRoot <- inventoryCacheRoot contextText
                    cacheReady <- validateInventoryCache mayInitialize cacheRoot
                    case cacheReady of
                      Left err -> pure (Left err)
                      Right () ->
                        if mayInitialize
                          then
                            newObjectStoreWithLock
                              ops
                              binding
                              client
                              (Just cacheRoot)
                              (stateRoot </> T.unpack contextText </> "inventory-remote.lock")
                          else
                            openObjectStoreReadOnlyWithLock
                              ops
                              binding
                              client
                              (Just cacheRoot)
                              (stateRoot </> T.unpack contextText </> "inventory-remote.lock")
                  (Left err, _) -> pure (invalid err)
                  (_, Left err) -> pure (invalid err)

inventoryCacheRoot :: T.Text -> IO FilePath
inventoryCacheRoot context = do
  root <- lookupEnv "XDG_CACHE_HOME"
  home <- lookupEnv "HOME"
  let base = maybe (maybe "" (</> ".cache") home) id root
  unless (isAbsolute base) (ioError (userError "inventory cache requires an absolute XDG_CACHE_HOME or HOME"))
  pure (base </> "nagare" </> T.unpack context </> "inventory-blobs")

validateInventoryCache :: Bool -> FilePath -> IO (Either StoreError ())
validateInventoryCache mayCreate root = do
  attempted <- try $ do
    when mayCreate (createDirectoryIfMissing True root)
    exists <- doesPathExist root
    when exists $ do
      linked <- pathIsSymbolicLink root
      when linked (ioError (userError "inventory cache root is a symlink"))
      status <- getFileStatus root
      unless (isDirectory status) (ioError (userError "inventory cache root is not a directory"))
      when mayCreate (setFileMode root 0o700)
  pure $ case attempted of
    Left (err :: IOException) -> Left (StoreIoError (T.pack (show err)))
    Right () -> Right ()

localStoreClientIdentity :: Bool -> FilePath -> T.Text -> IO (Either StoreError T.Text)
localStoreClientIdentity mayCreate stateRoot context = do
  let path = stateRoot </> T.unpack context </> "inventory-client-id"
  exists <- doesPathExist path
  if exists
    then readClient path
    else
      if not mayCreate
        then pure (Right "status-only")
        else do
          createDirectoryIfMissing True (takeDirectory path)
          randomBytes <- getRandomBytes 32 :: IO ByteString
          let identityText = "client-" <> digestText (contentDigest randomBytes)
          attempted <- try (openFd path WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600})
          case attempted of
            Left (err :: IOException) | isAlreadyExistsError err -> readClient path
            Left (err :: IOException) -> pure (Left (StoreIoError (T.pack (show err))))
            Right fd -> do
              handle <- fdToHandle fd
              BS.hPut handle (TE.encodeUtf8 identityText)
              hClose handle
              pure (Right identityText)
  where
    readClient path = do
      attempted <- try $ do
        linked <- pathIsSymbolicLink path
        when linked (ioError (userError "inventory client identity is a symlink"))
        status <- getFileStatus path
        unless (fileMode status .&. 0o077 == 0) (ioError (userError "inventory client identity is not private"))
        bytes <- BS.readFile path
        case TE.decodeUtf8' bytes of
          Right value | "client-" `T.isPrefixOf` value, T.length value == 71 -> pure value
          _ -> ioError (userError "inventory client identity is invalid")
      pure (first (StoreIoError . T.pack . show) (attempted :: Either IOException T.Text))
