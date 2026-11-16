-- | What a move to a new base domain reads from the platform's @shomei-db@ (EP-246 D1): the OAuth
-- clients whose redirect URIs name the old base, and every account holding a passkey. Both reads are
-- one read-only @psql@ query each through @kubectl exec@, as 'Nagare.Access.ShomeiUser' does, and
-- each returns one JSON array so the parsers here are pure.
module Nagare.Access.ShomeiMove
  ( oauthClientsSql
  , passkeyHoldersSql
  , parseOAuthClients
  , parsePasskeyHolders
  , readShomeiJson
  , underBase
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.ShomeiUser (shomeiUserIdFromUuid)
import Nagare.Context.BaseMove (OAuthClient (..), PasskeyHolder (..))
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

oauthClientsSql :: String
oauthClientsSql =
  "SELECT coalesce(json_agg(json_build_object('clientId', client_id, 'displayName', display_name, 'redirectUris', redirect_uris) ORDER BY client_id), '[]'::json) FROM shomei.shomei_oauth_clients WHERE status = 'active';\n"

-- | A passkey holder, and whether a confirmed TOTP credential still gives them a second factor.
passkeyHoldersSql :: String
passkeyHoldersSql =
  "SELECT coalesce(json_agg(json_build_object('userId', u.user_id, 'email', u.email, 'passkeys', w.n, 'totp', t.confirmed_at IS NOT NULL) ORDER BY u.email), '[]'::json) FROM shomei.shomei_users u JOIN (SELECT user_id, count(*) AS n FROM shomei.shomei_webauthn_credentials GROUP BY user_id) w ON w.user_id = u.user_id LEFT JOIN shomei.shomei_totp_credentials t ON t.user_id = u.user_id;\n"

data ClientRow = ClientRow !Text !Text ![Text]

instance FromJSON ClientRow where
  parseJSON = withObject "OAuth client" $ \o -> ClientRow <$> o .: "clientId" <*> o .: "displayName" <*> o .: "redirectUris"

data HolderRow = HolderRow !Text !Text !Int !Bool

instance FromJSON HolderRow where
  parseJSON = withObject "passkey holder" $ \o -> HolderRow <$> o .: "userId" <*> o .: "email" <*> o .: "passkeys" <*> o .: "totp"

-- | The active clients with a redirect URI on the old base or a name under it, with only those URIs.
parseOAuthClients :: Text -> Text -> Either Text [OAuthClient]
parseOAuthClients base output = do
  rows <- decodeRows "OAuth clients" output
  pure
    [ OAuthClient client name named
    | ClientRow client name uris <- rows
    , let named = filter (maybe False (underBase base) . uriHost) uris
    , not (null named)
    ]

parsePasskeyHolders :: Text -> Either Text [PasskeyHolder]
parsePasskeyHolders output = do
  rows <- decodeRows "passkey holders" output
  traverse (\(HolderRow uuid address count totp) -> (\user -> PasskeyHolder user address count totp) <$> shomeiUserIdFromUuid uuid) rows

decodeRows :: (FromJSON a) => Text -> Text -> Either Text [a]
decodeRows what output = first (\reason -> "Shomei returned unreadable " <> what <> ": " <> T.pack reason) (eitherDecodeStrict (TE.encodeUtf8 (T.strip output)))

-- | The host of an absolute URI, lower-cased.
uriHost :: Text -> Maybe Text
uriHost uri = do
  (_, rest) <- case T.breakOn "://" uri of
    (scheme, rest) | not (T.null rest) -> Just (scheme, T.drop 3 rest)
    _ -> Nothing
  let authority = T.takeWhile (`notElem` ['/', '?', '#']) rest
      host = T.takeWhile (/= ':') (T.takeWhileEnd (/= '@') authority)
  if T.null host then Nothing else Just (T.toLower host)

underBase :: Text -> Text -> Bool
underBase base host = host == T.toLower base || ("." <> T.toLower base) `T.isSuffixOf` host

-- | Run one read-only query against @nagare-system/shomei-db@ once the context guard passes.
readShomeiJson :: Text -> IO (Either Text ()) -> String -> IO (Either Text Text)
readShomeiJson kubectlContext contextGuard sql =
  contextGuard >>= \case
    Left reason -> pure (Left ("refusing to read Shomei: " <> reason))
    Right () -> do
      result <- try (readProcessWithExitCode "kubectl" args sql)
      pure $ case result of
        Left (failure :: IOException) -> Left ("cannot run kubectl to read Shomei: " <> T.pack (show failure))
        Right (ExitFailure _, _, err) -> Left ("reading nagare-system/shomei-db failed: " <> T.strip (T.pack err))
        Right (ExitSuccess, out, _) -> Right (T.pack out)
  where
    args =
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
      , "PGPASSWORD=\"$POSTGRES_PASSWORD\" exec psql -X -q -At -v ON_ERROR_STOP=1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -c 'SET default_transaction_read_only = on' -f -"
      ]
