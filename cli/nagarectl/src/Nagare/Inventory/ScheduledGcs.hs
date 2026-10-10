-- | Exact-generation GCS reads for the existing scheduled receipt protocol.
-- Listing never grants deletion authority; incomplete or malformed output refuses.
module Nagare.Inventory.ScheduledGcs
  ( withScheduledObjectStore
  , parseGcsObjectListing
  , parseGcsObjectGenerations
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Nagare.Cluster.GcsJob (StoreBackend (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.ManualReceiptSource (parseGcsManualMetadata, readGcsObjectAt)
import Nagare.Inventory.ScheduledStore
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

withScheduledObjectStore :: Text -> StoreBackend -> (ObjectReader -> IO a) -> IO (Either Text a)
withScheduledObjectStore context (MinioBackend ref) action = withLocalObjectStore context ref action
withScheduledObjectStore _ (GcsBackend project bucket) action = Right <$> action reader
  where
    reader =
      ObjectReader
        (readGcsObjectAt project bucket)
        (fmap (fmap (map listedKey)) . listEntries)
        listEntries
        listGenerations
    -- EP-183 M2: the live generation of every key that starts with this
    -- exact key, from a complete listing of the key's parent prefix. The
    -- versioned bucket's noncurrent generations are not listed: a prune makes
    -- the reviewed generation noncurrent, and only a live one is evidence.
    listGenerations key = do
      let (parent, _) = T.breakOnEnd "/" key
      listed <- listJson parent
      pure (listed >>= parseGcsObjectGenerations bucket parent >>= \entries -> Right [entry | entry@(name, _) <- entries, key `T.isPrefixOf` name])
    listEntries prefix = do
      listed <- listJson prefix
      pure (listed >>= parseGcsObjectListing bucket prefix)
    listJson prefix
      | T.null prefix
          || not ("/" `T.isSuffixOf` prefix)
          || T.any (`elem` ("#*?[]" :: String)) prefix =
          pure (Left "scheduled GCS listing requires a literal object prefix")
      | otherwise = do
          result <-
            try
              ( readProcessWithExitCode
                  "gcloud"
                  [ "--project"
                  , T.unpack project
                  , "storage"
                  , "objects"
                  , "list"
                  , "--format=json"
                  , "--raw"
                  , T.unpack ("gs://" <> bucket <> "/" <> prefix <> "**")
                  ]
                  ""
              ) ::
              IO (Either IOException (ExitCode, String, String))
          pure $ case result of
            Right (ExitSuccess, body, _) -> Right (BC.pack body)
            _ -> Left "scheduled GCS object listing is unavailable or incomplete"

-- | Each listed object's name and live generation.
parseGcsObjectGenerations :: Text -> Text -> ByteString -> Either Text [(Text, Text)]
parseGcsObjectGenerations bucket prefix bytes = do
  value <- first (const "scheduled GCS listing is malformed") (eitherDecodeStrict bytes)
  entries <- case value of
    Array items -> traverse entry (toList items)
    _ -> Left "scheduled GCS listing is not a complete array"
  unless
    (Set.size (Set.fromList (map fst entries)) == length entries)
    (Left "scheduled GCS listing repeats an object key")
  pure entries
  where
    entry (Object fields) = case KM.lookup "name" fields of
      Just (String name)
        | prefix `T.isPrefixOf` name && name /= prefix -> do
            stored <- parseGcsManualMetadata bucket name (LBS.toStrict (Aeson.encode (Object fields)))
            pure (name, storedVersion stored)
      _ -> Left "scheduled GCS listing escaped its object prefix"
    entry _ = Left "scheduled GCS listing contains a non-object"

parseGcsObjectListing :: Text -> Text -> ByteString -> Either Text [ListedObject]
parseGcsObjectListing bucket prefix bytes = do
  value <- first (const "scheduled GCS listing is malformed") (eitherDecodeStrict bytes)
  entries <- case value of
    Array items -> traverse parseEntry (toList items)
    _ -> Left "scheduled GCS listing is not a complete array"
  unless
    (Set.size (Set.fromList (map listedKey entries)) == length entries)
    (Left "scheduled GCS listing repeats an object key")
  pure entries
  where
    parseEntry (Object fields) = do
      name <- field "name" fields
      unless
        (prefix `T.isPrefixOf` name && name /= prefix)
        (Left "scheduled GCS listing escaped its object prefix")
      _ <- parseGcsManualMetadata bucket name (LBS.toStrict (Aeson.encode (Object fields)))
      rawTime <- field "updated" fields
      modified <-
        maybe
          (Left "scheduled GCS object has an invalid timestamp")
          Right
          ( parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack rawTime)
              <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%Ez" (T.unpack rawTime)
          )
      pure (ListedObject name modified)
    parseEntry _ = Left "scheduled GCS listing contains a non-object"
    field key fields = case KM.lookup key fields of
      Just (String value) | not (T.null value) -> Right value
      _ -> Left "scheduled GCS listing lacks exact object metadata"
