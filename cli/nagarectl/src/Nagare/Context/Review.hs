-- | Reviewed local context control. Provider state is changed only by subsequent
-- inventory reviews; these receipts preserve the original history locator.
module Nagare.Context.Review
  ( ProfileReview
  , prepareProfileReview
  , newProfileRequest
  , renderProfileReplacement
  , renderProfileReplacementPreserving
  , decodeProfileReview
  , profileReviewBytes
  , profileReviewContext
  , profileReviewOriginal
  , profileReviewLocalRoot
  , profileRemovalMarker
  , saveProfileReview
  , applyProfileReview
  , restoreProfileReview
  )
where

import Control.Exception (IOException, bracket, finally, try)
import Crypto.Random (getRandomBytes)
import Data.Aeson (ToJSON (toJSON), eitherDecodeStrict', object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock, hUnlock)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Init (renderTargetEnv)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (HeadManifest (..))
import Nagare.Resource.Types (ContextBinding (..), ScopeKind (Platform), digestText, mkContextId, mkName, mkScopeId)
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target
  ( ContextName
  , InventoryStoreKind (InventoryStoreGcs, InventoryStoreLocal)
  , TargetProfile (..)
  , contextNameText
  , effectiveInventoryStore
  , mkContextName
  , parseAcmeDirectory
  , parseContextEnv
  , profileFromContextMap
  , validateAcmeEmail
  , validateNixCacheMode
  , validateVmShape
  , vmShapeOf
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesPathExist, pathIsSymbolicLink, removeFile, renameFile)
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (IOMode (AppendMode), hClose, openFile)
import System.IO.Temp (openBinaryTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)

-- Constructor stays private: decoding validates context, authority, and bytes.
data ProfileReview = ProfileReview
  { version :: !Int
  , requestId :: !Text
  , context :: !Text
  , path :: !FilePath
  , original :: !Text
  , replacement :: !(Maybe Text)
  , localHistoryRoot :: !(Maybe FilePath)
  , authority :: !HeadManifest
  }
  deriving stock (Eq, Show)

instance ToJSON ProfileReview where
  toJSON review =
    object
      [ "version" .= version review
      , "requestId" .= requestId review
      , "context" .= context review
      , "path" .= path review
      , "original" .= original review
      , "replacement" .= replacement review
      , "localHistoryRoot" .= localHistoryRoot review
      , "authority" .= authority review
      ]

profileReviewContext :: ProfileReview -> ContextName
profileReviewContext = either (error . T.unpack) id . mkContextName . context

profileReviewOriginal :: ProfileReview -> TargetProfile
profileReviewOriginal = profileFromContextMap . parseContextEnv . original

profileReviewLocalRoot :: ProfileReview -> Maybe FilePath
profileReviewLocalRoot = localHistoryRoot

profileReviewBytes :: ProfileReview -> Either Text ByteString
profileReviewBytes = canonicalValue . toJSON

-- Quote every field so the shell consumers cannot interpret replacement values.
-- The existing context reader understands one surrounding quote pair only.
renderProfileReplacement :: TargetProfile -> Either Text Text
renderProfileReplacement = renderProfileReplacementPreserving ""

-- Script transport inputs are immutable local profile inputs, not credentials.
-- Keep their exact values even though TargetProfile does not model them.
renderProfileReplacementPreserving :: Text -> TargetProfile -> Either Text Text
renderProfileReplacementPreserving originalProfile profile = do
  let fields = Map.toAscList (Map.union (transportFields originalProfile) (parseContextEnv (renderTargetEnv profile)))
  for_ fields $ \(_, value) ->
    unless
      (not (T.any (`elem` ("'\n\r\0" :: String)) value))
      (Left "context values cannot contain apostrophes, line breaks or NUL")
  pure (T.unlines ["export " <> T.pack key <> "='" <> value <> "'" | (key, value) <- fields])

transportKeys :: Set.Set String
transportKeys =
  Set.fromList
    [ "NAGARE_BUILDER_PROJECT"
    , "NAGARE_BUILDER_ZONE"
    , "NAGARE_BUILDER_INSTANCE"
    , "NIX_BUILDER_SSH_KEY"
    , "NIX_BUILDER_HOST_KEY_B64"
    , "NIX_BUILDER_TUNNEL_PORT"
    ]

transportFields :: Text -> Map.Map String Text
transportFields = (`Map.restrictKeys` transportKeys) . parseContextEnv

newProfileRequest :: IO Text
newProfileRequest = digestText . contentDigest <$> (getRandomBytes 32 :: IO ByteString)

prepareProfileReview :: Text -> ContextName -> FilePath -> Text -> Maybe Text -> Maybe FilePath -> HeadManifest -> Either Text ProfileReview
prepareProfileReview request name location before after selectedRoot headValue = do
  let review = ProfileReview 1 request (contextNameText name) location before after selectedRoot headValue
  validate review
  pure review

decodeProfileReview :: ByteString -> Either Text ProfileReview
decodeProfileReview bytes = do
  value <- first T.pack (eitherDecodeStrict' bytes)
  review <-
    first
      T.pack
      ( parseEither
          ( withObject "context review" $ \fields ->
              ProfileReview
                <$> fields .: "version"
                <*> fields .: "requestId"
                <*> fields .: "context"
                <*> fields .: "path"
                <*> fields .: "original"
                <*> fields .: "replacement"
                <*> fields .: "localHistoryRoot"
                <*> fields .: "authority"
          )
          value
      )
  validate review
  pure review

validate :: ProfileReview -> Either Text ()
validate review = do
  unless (version review == 1) (Left "unsupported context review version")
  _ <- mkName (requestId review)
  _ <- mkContextName (context review)
  identity <- mkContextId (context review)
  project <- mkName (profileReviewOriginal review ^. #project)
  unless
    (headBinding (authority review) == ContextBinding identity project)
    (Left "context review differs from its original history binding")
  idle (authority review)
  case (effectiveInventoryStore (profileReviewOriginal review), localHistoryRoot review) of
    (InventoryStoreLocal, Nothing) -> Left "local context review lacks its original history root"
    (_, Just selectedRoot) -> do
      unless (isAbsolute selectedRoot) (Left "local context history root must be absolute")
      when (effectiveInventoryStore (profileReviewOriginal review) == InventoryStoreGcs) $ do
        foundation <- mkScopeId Platform "cloud-foundation"
        let headValue = authority review
        unless
          ( Map.keysSet (headAccepted headValue) `Set.isSubsetOf` Set.singleton foundation
              && Map.keysSet (headConverged headValue) `Set.isSubsetOf` Set.singleton foundation
              && Map.null (headRetained headValue)
              && Map.null (headCollected headValue)
          )
          (Left "local foundation profile review contains authority outside the foundation")
    _ -> pure ()

  let originalFields = parseContextEnv (original review)
      allowedFields = Map.keysSet (parseContextEnv (renderTargetEnv (profileReviewOriginal review))) `Set.union` transportKeys
  unless
    (Map.keysSet originalFields `Set.isSubsetOf` allowedFields)
    (Left "context review refuses unrecognized profile fields; keep credentials outside the profile")
  for_ (replacement review) $ \next -> do
    let before = profileReviewOriginal review
        after = profileFromContextMap (parseContextEnv next)
        -- Operational inputs may change; resource/authority identities cannot.
        compatible =
          before
            { machineType = after ^. #machineType
            , bootDiskType = after ^. #bootDiskType
            , bootDiskSizeGb = after ^. #bootDiskSizeGb
            , dataDiskSizeGb = after ^. #dataDiskSizeGb
            , nixCacheEnabled = after ^. #nixCacheEnabled
            , cdnEnabled = after ^. #cdnEnabled
            , externalDomainTlsEnabled = after ^. #externalDomainTlsEnabled
            , acmeEmail = after ^. #acmeEmail
            , acmeDirectory = after ^. #acmeDirectory
            , backupRecoveryPoint = after ^. #backupRecoveryPoint
            }
    canonical <- renderProfileReplacementPreserving (original review) after
    unless (next == canonical) (Left "replacement profile must use canonical quoted exports without extra shell commands")
    _ <- validateVmShape (vmShapeOf after)
    validateNixCacheMode after
    unless (T.null (after ^. #acmeEmail)) (void (validateAcmeEmail (after ^. #acmeEmail)))
    _ <- parseAcmeDirectory (after ^. #acmeDirectory)
    unless
      (Map.keysSet (parseContextEnv next) `Set.isSubsetOf` allowedFields)
      (Left "context review refuses unrecognized replacement fields")
    unless
      (compatible == after)
      (Left "context authority or resource identity changed; store moves require inventory store migrate, other identity/payload moves require a separate supported migration")

idle :: HeadManifest -> Either Text ()
idle headValue =
  unless
    ( isNothing (headActiveTransaction headValue)
        && isNothing (headExecutorClaim headValue)
        && isNothing (headMigration headValue)
        && isNothing (headDataFence headValue)
    )
    (Left "context control requires idle history without an executor claim, data fence or migration")

profileRemovalMarker :: FilePath -> FilePath
profileRemovalMarker location = location <> ".removed"

saveProfileReview :: FilePath -> ProfileReview -> IO (Either Text ())
saveProfileReview output review = safely $ do
  present <- doesPathExist output
  when present (fail "context review output already exists")
  bytes <- either (fail . T.unpack) pure (profileReviewBytes review)
  createDirectoryIfMissing True output
  setFileMode output 0o700
  atomicWrite (output </> "context-review.json") bytes
  atomicWrite (output </> "context-review.sha256") (TE.encodeUtf8 (digestText (contentDigest bytes)))

-- The callback always opens the original authority, even after profile removal.
-- No lock here claims cross-workstation exclusion: only this local file changes.
applyProfileReview :: FilePath -> (ProfileReview -> IO (Either Text HeadManifest)) -> ProfileReview -> IO (Either Text ())
applyProfileReview location observe review = withProfileLock location $ do
  checkLocation location review
  bytes <- either (fail . T.unpack) pure (profileReviewBytes review)
  let root = receiptRoot location bytes
      intent = root </> "intent.json"
      complete = root </> "completed"
  done <- exactOptional complete bytes
  if done
    then pure ()
    else do
      begun <- exactOptional intent bytes
      current <- readOptional location
      let before = Just (TE.encodeUtf8 (original review))
          after = TE.encodeUtf8 <$> replacement review
      if begun && current == after
        then do
          when (isNothing after) (publishExact (profileRemovalMarker location) bytes)
          publishExact complete bytes
        else do
          unless (current == before) (fail "context profile changed since review")
          headValue <- observe review >>= either (fail . T.unpack) pure
          either (fail . T.unpack) pure (idle headValue)
          unless (headValue == authority review) (fail "context history changed since review")
          marker <- readOptional (profileRemovalMarker location)
          when (isJust marker) (fail "context has retained removal authority; restore it before another change")
          publishExact intent bytes
          case after of
            Just value -> atomicWrite location value
            Nothing -> do
              -- Publish authority before unlink: recovery can prove either side.
              publishExact (profileRemovalMarker location) bytes
              durableRemove location
          observed <- readOptional location
          unless (observed == after) (fail "context after-state differs; inspect the original review")
          publishExact complete bytes

restoreProfileReview :: FilePath -> (ProfileReview -> IO (Either Text HeadManifest)) -> ProfileReview -> IO (Either Text ())
restoreProfileReview location observe review = withProfileLock location $ do
  checkLocation location review
  unless (isNothing (replacement review)) (fail "context restore requires a removal review")
  bytes <- either (fail . T.unpack) pure (profileReviewBytes review)
  let root = receiptRoot location bytes
      marker = profileRemovalMarker location
      before = TE.encodeUtf8 (original review)
  completed <- exactOptional (root </> "completed") bytes
  unless completed (fail "context removal has no completion receipt; apply the original review first")
  restored <- exactOptional (root </> "restored") bytes
  current <- readOptional location
  if restored
    then do
      unless (current == Just before) (fail "restored context has changed; refusing historical restore replay")
      remaining <- exactOptional marker bytes
      when remaining (durableRemove marker)
    else do
      retained <- exactOptional marker bytes
      unless retained (fail "context removal authority is absent or different")
      headValue <- observe review >>= either (fail . T.unpack) pure
      unless
        (headBinding headValue == headBinding (authority review) && isNothing (headMigration headValue))
        (fail "retained context authority has migrated or changed binding")
      -- Restoring access to an active transaction is allowed; it changes no
      -- provider or history bytes and is necessary for original recovery.
      unless (current == Nothing || current == Just before) (fail "another context profile occupies the restore path")
      when (current == Nothing) (atomicWrite location before)
      publishExact (root </> "restored") bytes
      durableRemove marker

checkLocation :: FilePath -> ProfileReview -> IO ()
checkLocation location review =
  unless (location == path review) (fail "context review belongs to another local configuration root")

receiptRoot :: FilePath -> ByteString -> FilePath
receiptRoot location bytes = location <> ".reviews" </> T.unpack (digestText (contentDigest bytes))

exactOptional :: FilePath -> ByteString -> IO Bool
exactOptional location bytes = do
  stored <- readOptional location
  case stored of
    Nothing -> pure False
    Just existing | existing == bytes -> pure True
    _ -> fail "context receipt conflicts with immutable review bytes"

publishExact :: FilePath -> ByteString -> IO ()
publishExact location bytes = do
  exists <- exactOptional location bytes
  unless exists (atomicWrite location bytes)

readOptional :: FilePath -> IO (Maybe ByteString)
readOptional location = do
  exists <- doesPathExist location
  if exists
    then do
      linked <- pathIsSymbolicLink location
      when linked (fail "context control refuses symbolic links")
      Just <$> BS.readFile location
    else pure Nothing

atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite location bytes = do
  ensureDirectory (takeDirectory location)
  setFileMode (takeDirectory location) 0o700
  (temporary, handle) <- openBinaryTempFile (takeDirectory location) ".context-review-"
  setFileMode temporary 0o600
  BS.hPut handle bytes
  hClose handle
  synchronise temporary
  renameFile temporary location
  synchronise (takeDirectory location)

withProfileLock :: FilePath -> IO () -> IO (Either Text ())
withProfileLock location action = safely $ do
  createDirectoryIfMissing True (takeDirectory location)
  bracket (openFile (location <> ".lock") AppendMode) hClose $ \handle -> do
    setFileMode (location <> ".lock") 0o600
    acquired <- hTryLock handle ExclusiveLock
    unless acquired (fail "context control is busy in another local process")
    action `finally` hUnlock handle

safely :: IO () -> IO (Either Text ())
safely action = first (T.pack . show) <$> (try action :: IO (Either IOException ()))

synchronise :: FilePath -> IO ()
synchronise location = bracket (openFd location ReadOnly defaultFileFlags) closeFd fileSynchronise

durableRemove :: FilePath -> IO ()
durableRemove location = removeFile location >> synchronise (takeDirectory location)

ensureDirectory :: FilePath -> IO ()
ensureDirectory directory = do
  present <- doesDirectoryExist directory
  unless present $ do
    ensureDirectory (takeDirectory directory)
    createDirectory directory
    setFileMode directory 0o700
    synchronise (takeDirectory directory)
