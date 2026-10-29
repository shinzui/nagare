-- | EP-226 M4: a provider project's number never changes, so ownership checks
-- keep the one last read for each project instead of running
-- @gcloud projects describe@ on every command. The bucket's owning number is
-- still read live, and a remembered number that disagrees with it is reread
-- before any verdict, so a stale entry costs one read and never decides alone.
module Nagare.Inventory.Store.ProjectNumbers
  ( ProjectNumbers (..)
  , noProjectNumbers
  , cachedProjectNumbers
  , projectNumbersAt
  , numericProjectNumber
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import System.Directory (createDirectoryIfMissing, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, (</>))
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)

data ProjectNumbers = ProjectNumbers
  { recall :: !(Text -> IO (Maybe Text))
  , remember :: !(Text -> Text -> IO ())
  }
  deriving stock (Generic)

-- | Every check reads both numbers live.
noProjectNumbers :: ProjectNumbers
noProjectNumbers = ProjectNumbers (const (pure Nothing)) (\_ _ -> pure ())

-- | The user's private cache: @$XDG_CACHE_HOME/nagare/project-numbers@, else
-- @~/.cache@. Without an absolute root nothing is remembered.
cachedProjectNumbers :: IO ProjectNumbers
cachedProjectNumbers = do
  root <- lookupEnv "XDG_CACHE_HOME"
  home <- lookupEnv "HOME"
  pure $ case maybe ((</> ".cache") <$> home) Just root of
    Just base | isAbsolute base -> projectNumbersAt (base </> "nagare" </> "project-numbers")
    _ -> noProjectNumbers

-- | One file per project ID. An unreadable, malformed or unwritable entry is a
-- cache miss; the live read then decides.
projectNumbersAt :: FilePath -> ProjectNumbers
projectNumbersAt directory = ProjectNumbers {recall = recallAt, remember = rememberAt}
  where
    recallAt project = case entry project of
      Nothing -> pure Nothing
      Just path -> do
        read' <- try (BS.readFile path)
        pure $ case read' of
          Right bytes -> either (const Nothing) numericProjectNumber (TE.decodeUtf8' bytes)
          Left (_ :: IOException) -> Nothing
    rememberAt project number = case (entry project, numericProjectNumber number) of
      (Just path, Just digits) -> void . try @IOException $ do
        createDirectoryIfMissing True directory
        setFileMode directory 0o700
        (temporary, handle) <- openBinaryTempFile directory ".project-number-"
        setFileMode temporary 0o600
        BS.hPut handle (TE.encodeUtf8 digits)
        hClose handle
        renameFile temporary path
      _ -> pure ()
    -- Provider project IDs are lowercase letters, digits and hyphens.
    entry project
      | not (T.null project)
      , T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') project =
          Just (directory </> T.unpack project)
      | otherwise = Nothing

numericProjectNumber :: Text -> Maybe Text
numericProjectNumber value = case T.strip value of
  digits | not (T.null digits), T.all (`elem` ['0' .. '9']) digits -> Just digits
  _ -> Nothing
