-- | The Shomei user an access grant names. The enforcer checks the Shomei user
-- id (@user_…@), so an email is resolved to that id before any tuple is
-- planned, and anything that cannot be a Shomei subject is refused (F96).
module Nagare.Access.ShomeiUser
  ( ShomeiUser (..)
  , UserRef (..)
  , emailLookupArgs
  , emailLookupSql
  , isShomeiUserId
  , lookupShomeiEmail
  , parseEmailLookup
  , parseUserRef
  , shomeiUserIdFromUuid
  )
where

import Control.Exception (IOException, try)
import Data.Bits (shiftR, (.&.))
import Data.Char (digitToInt, isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | A resolved grant subject: the Shomei user id, and the email it was
-- resolved from when the operator named one.
data ShomeiUser = ShomeiUser
  { userId :: !Text
  , email :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data UserRef
  = UserById !Text
  | UserByEmail !Text
  deriving stock (Eq, Show)

parseUserRef :: Text -> Either Text UserRef
parseUserRef raw
  | isShomeiUserId value = Right (UserById value)
  | isEmail value = Right (UserByEmail (T.toLower value))
  | otherwise =
      Left
        ( "--user must be the email the person signed up with or their Shomei user id (user_…); got "
            <> T.pack (show value)
        )
  where
    value = T.strip raw
    isEmail candidate = case T.splitOn "@" candidate of
      [local, domain] ->
        not (T.null local)
          && T.isInfixOf "." domain
          && not (T.any (\c -> c <= ' ' || c == '\DEL') candidate)
      _ -> False

-- | A Shomei user id is a TypeID: @user_@ and 26 lowercase Crockford base32
-- characters whose first encodes the top three bits of a UUID.
isShomeiUserId :: Text -> Bool
isShomeiUserId value = case T.stripPrefix "user_" value of
  Just suffix ->
    T.length suffix == 26
      && T.all (`T.elem` crockford) suffix
      && T.head suffix <= '7'
  Nothing -> False

-- | Shomei stores the id's UUID; its API and the enforcer speak the TypeID.
shomeiUserIdFromUuid :: Text -> Either Text Text
shomeiUserIdFromUuid raw = do
  let value = T.strip raw
      digits = T.filter (/= '-') value
  unless
    (map T.length (T.splitOn "-" value) == [8, 4, 4, 4, 12] && T.all isHexDigit digits)
    (Left ("Shomei returned a malformed user UUID: " <> T.pack (show value)))
  let n = T.foldl' (\acc c -> acc * 16 + toInteger (digitToInt c)) 0 digits :: Integer
  pure ("user_" <> T.pack [T.index crockford (fromInteger ((n `shiftR` (5 * i)) .&. 31)) | i <- [25, 24 .. 0]])

crockford :: Text
crockford = "0123456789abcdefghjkmnpqrstvwxyz"

-- | Shomei lowercases emails at sign-up and keeps them unique, so exactly one
-- row names a known person.
parseEmailLookup :: Text -> Text -> Either Text Text
parseEmailLookup address output = case filter (not . T.null) (map T.strip (T.lines output)) of
  [uuid] -> shomeiUserIdFromUuid uuid
  [] -> Left ("no Shomei user has the email " <> address <> "; the person signs up first, then grant again")
  rows ->
    Left
      ( address
          <> " matches "
          <> T.pack (show (length rows))
          <> " Shomei users; grant one by its user_… id"
      )

-- | Read-only lookup in the platform's @shomei-db@. The email reaches psql as
-- a variable, never as SQL text.
emailLookupArgs :: Text -> Text -> [String]
emailLookupArgs kubectlContext address =
  [ "--context"
  , T.unpack kubectlContext
  , "--request-timeout=30s"
  , "--namespace"
  , "nagare-system"
  , "exec"
  , "-i"
  , "shomei-db-0"
  , "--container"
  , "postgres"
  , "--"
  , "sh"
  , "-c"
  , "PGPASSWORD=\"$POSTGRES_PASSWORD\" exec psql -X -q -At -v ON_ERROR_STOP=1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -v email=\"$1\""
  , "sh"
  , T.unpack address
  ]

emailLookupSql :: String
emailLookupSql = "SELECT user_id FROM shomei.shomei_users WHERE email = :'email';\n"

lookupShomeiEmail :: Text -> IO (Either Text ()) -> Text -> IO (Either Text ShomeiUser)
lookupShomeiEmail kubectlContext contextGuard address = do
  guarded <- contextGuard
  case guarded of
    Left reason -> pure (Left ("refusing to look up " <> address <> ": " <> reason))
    Right () -> do
      result <- try (readProcessWithExitCode "kubectl" (emailLookupArgs kubectlContext address) emailLookupSql)
      pure $ case result of
        Left (failure :: IOException) -> Left ("cannot run kubectl to look up " <> address <> ": " <> T.pack (show failure))
        Right (ExitFailure _, _, err) -> Left ("Shomei user lookup in nagare-system/shomei-db failed: " <> T.strip (T.pack err))
        Right (ExitSuccess, out, _) -> do
          found <- parseEmailLookup address (T.pack out)
          pure (ShomeiUser found (Just address))
