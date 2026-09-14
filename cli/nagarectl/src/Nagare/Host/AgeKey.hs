{-# LANGUAGE OverloadedStrings #-}

module Nagare.Host.AgeKey
  ( AgeKeyTransport
  , LocalAgeKey (..)
  , RemoteAgeKeyStatus (..)
  , inspectLocalAgeKey
  , parseRemoteAgeKeyStatus
  , placeAgeKeyArgs
  , placeAgeKeyWith
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isHexDigit, isSpace)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Target (Mode (..), TargetProfile (..))
import System.Directory (Permissions (readable), doesFileExist, doesPathExist, getPermissions)
import System.Exit (ExitCode (..))

data LocalAgeKey = LocalAgeKey
  { path :: !FilePath
  , sha256 :: !Text
  }
  deriving stock (Generic, Eq, Show)

data RemoteAgeKeyStatus
  = AgeKeyReady !FilePath !Text
  | AgeKeyMissing !FilePath !Text
  | AgeKeyInvalid !FilePath !Text
  | AgeKeyStatusUnsupported !Text
  deriving stock (Eq, Show)

-- | A transport receives the complete child environment and the arguments for
-- @iap-ssh.sh@. The key body is deliberately absent; send-file reopens its path.
type AgeKeyTransport = [(String, String)] -> [String] -> IO (ExitCode, String, String)

inspectLocalAgeKey :: FilePath -> IO (Either Text LocalAgeKey)
inspectLocalAgeKey keyPath = do
  exists <- doesPathExist keyPath
  regular <- doesFileExist keyPath
  if not exists
    then pure (Left ("age key file does not exist: " <> T.pack keyPath))
    else
      if not regular
        then pure (Left ("age key path is not a regular file: " <> T.pack keyPath))
        else do
          permissions <- try (getPermissions keyPath)
          case permissions of
            Left (err :: IOException) -> pure (Left (ioFailure keyPath err))
            Right perms
              | not (readable perms) -> pure (Left ("age key file is not readable: " <> T.pack keyPath))
              | otherwise -> do
                  bytesResult <- try (BS.readFile keyPath)
                  pure $ case bytesResult of
                    Left (err :: IOException) -> Left (ioFailure keyPath err)
                    Right bytes -> inspectBytes keyPath bytes

inspectBytes :: FilePath -> ByteString -> Either Text LocalAgeKey
inspectBytes keyPath bytes
  | BS.null bytes = Left ("age key file is empty: " <> T.pack keyPath)
  | otherwise =
      case contentLines of
        [identity]
          | ageSecretPrefix `BS.isPrefixOf` identity ->
              Right
                LocalAgeKey
                  { path = keyPath
                  , sha256 = T.pack (show (hash bytes :: Digest SHA256))
                  }
          | otherwise -> malformed
        _ -> malformed
  where
    contentLines =
      filter
        (\line -> not (BS.null line) && not ("#" `BS.isPrefixOf` line))
        (map stripAscii (BC.lines bytes))
    malformed = Left ("age key file must contain exactly one non-comment age private-identity line: " <> T.pack keyPath)

ageSecretPrefix :: ByteString
ageSecretPrefix = "AGE-" <> "SECRET-KEY-1"

stripAscii :: ByteString -> ByteString
stripAscii = BC.dropWhileEnd isSpace . BC.dropWhile isSpace

ioFailure :: FilePath -> IOException -> Text
ioFailure keyPath err = "could not read age key file " <> T.pack keyPath <> ": " <> T.pack (show err)

-- | Parse the helper's one-record protocol:
-- @age-key<TAB>(ready|missing|invalid|unknown)<TAB>path<TAB>detail@.
parseRemoteAgeKeyStatus :: ByteString -> Either Text RemoteAgeKeyStatus
parseRemoteAgeKeyStatus raw =
  case BC.split '\t' (stripLineEnd raw) of
    ["age-key", "ready", keyPath, digest]
      | validDigest digest -> Right (AgeKeyReady (BC.unpack keyPath) (decode digest))
      | otherwise -> Left "host age-key ready record contains an invalid SHA-256 digest"
    ["age-key", "missing", keyPath, detail] -> Right (AgeKeyMissing (BC.unpack keyPath) (decode detail))
    ["age-key", "invalid", keyPath, detail] -> Right (AgeKeyInvalid (BC.unpack keyPath) (decode detail))
    ["age-key", "unknown", _, detail] -> Right (AgeKeyStatusUnsupported (decode detail))
    _ -> Left "host age-key status record is missing or malformed"
  where
    decode = T.pack . BC.unpack
    validDigest digest = BS.length digest == 64 && BC.all (\c -> isHexDigit c && not (c >= 'A' && c <= 'F')) digest

stripLineEnd :: ByteString -> ByteString
stripLineEnd = BC.dropWhileEnd (\c -> c == '\n' || c == '\r')

placeAgeKeyArgs :: TargetProfile -> LocalAgeKey -> Bool -> [String]
placeAgeKeyArgs profile key force =
  [ "send-file"
  , T.unpack (profile ^. #instanceName)
  , key ^. #path
  , "--"
  , "sudo"
  , "--"
  , "/run/current-system/sw/bin/nagare-host-age-key"
  , "install"
  , "--sha256"
  , T.unpack (key ^. #sha256)
  ]
    <> ["--force" | force]

placeAgeKeyWith :: AgeKeyTransport -> [(String, String)] -> Text -> TargetProfile -> FilePath -> Bool -> IO (Either Text ())
placeAgeKeyWith transport parentEnv context profile keyPath force
  | profile ^. #mode == Local = pure (Left "host age-key placement uses GCP IAP and is unavailable for local contexts")
  | otherwise = do
      inspected <- inspectLocalAgeKey keyPath
      case inspected of
        Left err -> pure (Left err)
        Right key -> do
          let childEnv = ("NAGARE_CONTEXT", T.unpack context) : filter ((/= "NAGARE_CONTEXT") . fst) parentEnv
          result <- try (transport childEnv (placeAgeKeyArgs profile key force))
          pure $ case result of
            Left (ioErr :: IOException) -> Left ("host age-key placement failed: " <> T.pack (show ioErr))
            Right (ExitSuccess, _, _) -> Right ()
            Right (ExitFailure n, out, err) ->
              Left
                ( "host age-key placement failed (exit "
                    <> T.pack (show n)
                    <> "): "
                    <> T.strip (T.pack (err <> out))
                )
