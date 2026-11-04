-- | Off-cluster escrow of Shomei's key-encryption key (F146). The key wraps
-- every restored signing key and TOTP secret, so a recovery point of Shomei's
-- database is unusable without it. @db escrow-signing-key shomei-db@ writes
-- this file; a later create of the Secret takes the key from it instead of
-- generating one.
module Nagare.Inventory.ShomeiKeyEscrow
  ( ShomeiKeyEscrow (..)
  , renderShomeiKeyEscrow
  , parseShomeiKeyEscrow
  , shomeiKeyEscrowPath
  , readShomeiKeyEscrow
  , sopsEnvironment
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Target (nagareConfigDir)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.Process (CreateProcess (cwd, env), proc, readCreateProcessWithExitCode)

data ShomeiKeyEscrow = ShomeiKeyEscrow
  { context :: !Text
  , keyEncryptionKey :: !Text
  }
  deriving stock (Eq, Generic)

-- | The key never appears in rendered diagnostics.
instance Show ShomeiKeyEscrow where
  show escrow = "ShomeiKeyEscrow " <> show (context escrow) <> " <key redacted>"

renderShomeiKeyEscrow :: ShomeiKeyEscrow -> ByteString
renderShomeiKeyEscrow escrow =
  Yaml.encode $
    object
      [ "kind" .= ("NagareShomeiKeyEscrow" :: Text)
      , "version" .= (1 :: Int)
      , "context" .= context escrow
      , "keyEncryptionKey" .= keyEncryptionKey escrow
      ]

parseShomeiKeyEscrow :: ByteString -> Either Text ShomeiKeyEscrow
parseShomeiKeyEscrow bytes = do
  value <- first (const "Shomei key escrow is not valid YAML") (Yaml.decodeEither' bytes)
  fields <- case value of
    Object root
      | KM.size root == 4
      , KM.lookup "kind" root == Just (String "NagareShomeiKeyEscrow")
      , KM.lookup "version" root == Just (Number 1) ->
          Right root
    _ -> Left "Shomei key escrow has an unknown kind, version or field set"
  let text key = case KM.lookup key fields of
        Just (String found) | not (T.null found) -> Right found
        _ -> Left "Shomei key escrow has a missing or empty field"
  key <- text "keyEncryptionKey"
  unless
    (T.length key == 44 && T.isSuffixOf "=" key && T.all (\c -> isAlphaNum c || c `elem` ("+/=" :: String)) key)
    (Left "Shomei key escrow does not hold a 32-byte base64 key")
  ShomeiKeyEscrow <$> text "context" <*> pure key

-- | Beside the context's other sops-encrypted cluster secrets (ADR 13).
shomeiKeyEscrowPath :: Text -> IO FilePath
shomeiKeyEscrowPath contextName = do
  config <- nagareConfigDir
  pure (config </> "cluster-secrets" </> T.unpack contextName </> "shomei-key-encryption-key.sops.yaml")

-- | The context's escrowed key, or 'Nothing' when none was escrowed. A file
-- that cannot be read is a refusal: generating a new key in its place would
-- leave the restored rows undecryptable.
readShomeiKeyEscrow :: Text -> IO (Either Text (Maybe Text))
readShomeiKeyEscrow contextName = do
  path <- shomeiKeyEscrowPath contextName
  exists <- doesFileExist path
  if not exists
    then pure (Right Nothing)
    else do
      environment <- sopsEnvironment
      outcome <-
        try
          ( readCreateProcessWithExitCode
              (proc "sops" ["decrypt", "--input-type", "yaml", "--output-type", "yaml", path])
                { cwd = Just (takeDirectory path)
                , env = Just environment
                }
              ""
          ) ::
          IO (Either IOException (ExitCode, String, String))
      pure $ case outcome of
        Right (ExitSuccess, plaintext, _) -> do
          escrow <- parseShomeiKeyEscrow (BC.pack plaintext)
          unless (context escrow == contextName) (Left "the Shomei key escrow belongs to another context")
          Right (Just (keyEncryptionKey escrow))
        Right _ -> Left "could not decrypt the Shomei key escrow with the available age key"
        Left _ -> Left "sops is not available to read the Shomei key escrow"

-- | The conventional age key location used by the other operator-secret
-- readers, unless SOPS_AGE_KEY_FILE is already set.
sopsEnvironment :: IO [(String, String)]
sopsEnvironment = do
  environment <- getEnvironment
  age <- lookupEnv "SOPS_AGE_KEY_FILE"
  case age of
    Just value | not (null value) -> pure environment
    _ -> do
      config <- nagareConfigDir
      let conventional = config </> ".." </> "sops/age/keys.txt"
      found <- doesFileExist conventional
      pure (if found then ("SOPS_AGE_KEY_FILE", conventional) : environment else environment)
