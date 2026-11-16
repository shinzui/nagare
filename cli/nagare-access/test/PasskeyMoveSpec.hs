{-# LANGUAGE OverloadedRecordDot #-}

-- | EP-246 D4 against a real Shomei: a move to a new base domain exports the passkeys bound to the
-- old domain, removes exactly those, and on rollback restores the table to the export. The SQL is the
-- move's own, read from the platform payload, so what nagarectl runs through psql is what this proves.
module PasskeyMoveSpec (passkeyMoveTests) where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEADMode (AEAD_GCM), AuthTag (..), aeadInit, aeadSimpleEncrypt, cipherInit)
import Crypto.Error (throwCryptoError)
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.Functor.Contravariant ((>$<))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as HasqlPool
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.Credential (Credential (..))
import Nagare.Access.Jwks (fetchJwksFromShomei, newJwksCache)
import Nagare.Access.Prelude
import Nagare.Access.Shomei (verifyShomeiCredentialCached)
import Network.HTTP.Client qualified as HC
import RealShomei (withRealShomeiServer, withRealShomeiServerAndPool)
import Shomei.Account.Dto qualified as ShomeiAccountDTO
import Shomei.Account.User.Dto (UserResponse (..))
import Shomei.Client qualified as ShomeiClient
import Shomei.Id (UserId, parseId, userIdToUUID)
import Shomei.Session.Dto qualified as ShomeiSessionDTO
import Test.Tasty
import Test.Tasty.HUnit

passkeyMoveTests :: TestTree
passkeyMoveTests =
  testGroup
    "a move's passkey export, removal and restore against real Shomei (EP-246 D4)"
    [ testCase "a passkey holder signs in with a password after the removal and can register again; TOTP still applies; rollback restores the export exactly" $
        withRealShomeiServerAndPool $ \pool port -> do
          env <- ShomeiClient.shomeiClientEnv ("http://127.0.0.1:" <> show port)
          alice <- signupUser env "alice"
          bob <- signupUser env "bob"
          carol <- signupUser env "carol"
          run pool (insertPasskey alice "old laptop")
          run pool (insertPasskey carol "old phone")
          run pool (insertConfirmedTotp bob)
          run pool (insertConfirmedTotp carol)
          -- Before the move every holder is asked for a second factor.
          loginState env "alice" >>= (@?= Left ["passkey"])
          loginState env "bob" >>= (@?= Left ["totp"])
          fmap (either (elem "totp") (const False)) (loginState env "carol") >>= (@?= True)

          columns <- moveSql "columns.sql" >>= run pool . queryText
          columns @?= expectedColumns
          exported <- moveSql "export-passkeys.sql" >>= run pool . queryText
          assertBool "the export holds both passkeys" (Text.count "passkey_id" exported == 2)
          removeSql <- moveSql "remove-passkeys.sql"
          run pool (withRows removeSql exported)
          -- Running the removal again changes nothing.
          run pool (withRows removeSql exported)

          -- A password-and-passkey account is no longer gated by a passkey its browser cannot use.
          aliceLogin <- loginState env "alice"
          token <- either (\methods -> assertFailure ("alice was still asked for " <> show methods)) pure aliceLogin
          begun <- ShomeiClient.passkeyRegisterBegin env token
          case begun of
            Right (ShomeiClient.ApplicationSuccess _) -> pure ()
            other -> assertFailure ("alice could not begin registering a new passkey: " <> show (either show (const "an application error") other))
          -- TOTP still applies, alone and beside a removed passkey.
          loginState env "bob" >>= (@?= Left ["totp"])
          loginState env "carol" >>= (@?= Left ["totp"])

          -- A passkey registered after the flip is bound to the new domain; rollback removes it.
          run pool (insertPasskey bob "new laptop")
          restoreSql <- moveSql "restore-passkeys.sql"
          run pool (withRows restoreSql exported)
          restored <- moveSql "export-passkeys.sql" >>= run pool . queryText
          restored @?= exported
          run pool (withRows restoreSql exported)
          (moveSql "export-passkeys.sql" >>= run pool . queryText) >>= (@?= exported)
          loginState env "alice" >>= (@?= Left ["passkey"])
    , testCase "a token issued before the flip verifies on the new base: the issuer, audience and keys do not follow the domain (EP-246 D3)" $
        withRealShomeiServer $ \port -> do
          let url = "http://127.0.0.1:" <> show port
          env <- ShomeiClient.shomeiClientEnv url
          _ <- signupUser env "dora"
          ShomeiClient.Token token <- loginState env "dora" >>= either (\methods -> assertFailure ("dora was asked for " <> show methods)) pure
          manager <- HC.newManager HC.defaultManagerSettings
          let plane domain =
                AuthPlaneConfig
                  { shomeiUrl = Text.pack url
                  , shomeiIssuer = "nagare-shomei-test"
                  , shomeiAudience = "shomei-clients"
                  , enUrl = "http://127.0.0.1:1"
                  , enApiKey = Nothing
                  , cookieDomain = domain
                  , cookieKey = Just "cookie-secret"
                  }
              verifyOn domain = do
                cache <- newJwksCache 0 (pure 0) (fetchJwksFromShomei manager (plane domain))
                verifyShomeiCredentialCached cache ((plane domain) {shomeiIssuer = "shomei"}) (BearerToken token)
          before <- verifyOn ".labs.example.net"
          after <- verifyOn ".examplelabs.com"
          assertBool ("the token did not verify before the flip: " <> show (void before)) (isRight before)
          assertBool ("the token did not verify after the flip: " <> show (void after)) (isRight after)
    ]

expectedColumns :: Text
expectedColumns =
  "passkey_id uuid,user_id uuid,credential_id bytea,user_handle bytea,public_key bytea,sign_counter bigint,transports jsonb,label text,created_at timestamp with time zone,last_used_at timestamp with time zone"

password :: Text
password = "A-long-random-password-42"

signupUser :: ShomeiClient.ClientEnv -> Text -> IO UUID
signupUser env login = do
  result <-
    ShomeiClient.signup
      env
      ShomeiAccountDTO.SignupRequest
        { ShomeiAccountDTO.loginId = login
        , ShomeiAccountDTO.email = Just (login <> "@example.com")
        , ShomeiAccountDTO.password = password
        , ShomeiAccountDTO.displayName = login
        }
  case result of
    Right (ShomeiClient.ApplicationSuccess response) ->
      either (assertFailure . Text.unpack) (pure . userIdToUUID) (parseId (ShomeiClient.cookieBody response).user.userId :: Either Text UserId)
    _ -> assertFailure ("signup of " <> Text.unpack login <> " failed")

-- | Either the second factors Shomei asks for, or the access token of a completed sign-in.
loginState :: ShomeiClient.ClientEnv -> Text -> IO (Either [Text] ShomeiClient.Token)
loginState env login = do
  result <- ShomeiClient.login env (ShomeiSessionDTO.LoginRequest login password Nothing)
  case result of
    Right (ShomeiClient.ApplicationSuccess response) -> case ShomeiClient.cookieBody response of
      ShomeiSessionDTO.LoginMfaRequiredResponse {ShomeiSessionDTO.methods = methods} -> pure (Left methods)
      ShomeiSessionDTO.LoginCompleteResponse {ShomeiSessionDTO.token = pair} ->
        maybe (assertFailure "a completed sign-in carried no access token") (pure . Right . ShomeiClient.Token) pair.accessToken
    Right other -> assertFailure ("sign-in of " <> Text.unpack login <> " was refused: " <> show (void other))
    Left failure -> assertFailure ("sign-in of " <> Text.unpack login <> " failed: " <> show failure)

moveSql :: FilePath -> IO Text
moveSql name = TIO.readFile ("../../cluster/bootstrap/shomei/move/" <> name)

-- | The move's psql variable @:'rows'@, bound as a statement parameter here.
withRows :: Text -> Text -> Session.Session ()
withRows sql rows =
  Session.statement rows (preparable (Text.replace ":'rows'" "$1" sql) (E.param (E.nonNullable E.text)) D.noResult :: Statement Text ())

queryText :: Text -> Session.Session Text
queryText sql = Session.statement () (preparable sql E.noParams (D.singleRow (D.column (D.nonNullable D.text))))

insertPasskey :: UUID -> Text -> Session.Session ()
insertPasskey user label =
  Session.statement
    (user, label)
    ( preparable
        "INSERT INTO shomei.shomei_webauthn_credentials VALUES (gen_random_uuid(), $1, decode(md5(random()::text), 'hex'), decode(md5(random()::text), 'hex'), decode(md5(random()::text) || md5(random()::text), 'hex'), 0, '[\"internal\"]'::jsonb, $2, now(), NULL)"
        ((fst >$< E.param (E.nonNullable E.uuid)) <> (snd >$< E.param (E.nonNullable E.text)))
        D.noResult
    )

-- | A confirmed TOTP credential, its secret sealed as Shomei seals it (AES-256-GCM, @nonce || ciphertext
-- || tag@) under the harness's all-zero key.
insertConfirmedTotp :: UUID -> Session.Session ()
insertConfirmedTotp user =
  Session.statement
    (user, sealed)
    ( preparable
        "INSERT INTO shomei.shomei_totp_credentials (totp_credential_id, user_id, secret_enc, last_used_counter, confirmed_at, created_at) VALUES (gen_random_uuid(), $1, $2, NULL, now(), now())"
        ((fst >$< E.param (E.nonNullable E.uuid)) <> (snd >$< E.param (E.nonNullable E.bytea)))
        D.noResult
    )
  where
    nonce = BS.replicate 12 1
    cipher = throwCryptoError (cipherInit (BS.replicate 32 0)) :: AES256
    state = throwCryptoError (aeadInit AEAD_GCM cipher nonce)
    (tag, ciphertext) = aeadSimpleEncrypt state BS.empty (BS.replicate 20 7) 16
    sealed = nonce <> ciphertext <> BA.convert (unAuthTag tag)

run :: HasqlPool.Pool -> Session.Session a -> IO a
run pool session = HasqlPool.use pool session >>= either (assertFailure . show) pure
