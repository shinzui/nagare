-- | @nagared@ — the Nagare webhook runner (EP-16).
--
-- A small HTTP service that receives GitHub webhooks, verifies their HMAC-SHA256
-- signature, checks out the named commit, and drives the *same* static deploy
-- path as @nagarectl site deploy@ (it imports 'Nagare.Static.Deploy', not a
-- second engine). A push to the configured production branch triggers a
-- production deploy; a pull-request open/sync triggers a preview deploy.
--
-- Routes:
--
-- > GET  /healthz                              -> 200 (readiness)
-- > POST /webhooks/github/static/<site>        -> verify, checkout, deploy
--
-- The signature is checked before the body is parsed or any deploy runs, so an
-- unsigned or mis-signed request never reaches Docker or the cluster. The
-- selected context's inventory store is checked on every triggered delivery;
-- direct webhook deployment refuses once that store is initialized.
--
-- handling is idempotent: a retried delivery for the same commit re-resets the
-- checkout and re-records the same release id (deduped), so no duplicate work.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO.Encoding (setLocaleEncoding)
import Nagare.Dsl.Load
  ( ConfigTimeout (..)
  , defaultConfigTimeout
  , loadStaticSiteWith
  , renderLoadError
  )
import Nagare.Dsl.Prelude
import Nagare.GhcEnv (resolveProjectGhcEnv)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Store (StoreError (..))
import Nagare.Static.Checkout (checkoutRepo)
import Nagare.Static.Deploy
  ( DeployInputs (..)
  , deployStaticPreview
  , deployStaticProduction
  )
import Nagare.Static.Webhook
  ( CheckoutSpec (..)
  , DeployAction (..)
  , WebhookConfig (..)
  , WebhookOutcome (..)
  , decideWebhook
  )
import Nagare.Target (ActiveTarget, TargetProfile, resolveActiveTarget)
import Network.HTTP.Types
  ( Status
  , status200
  , status400
  , status401
  , status404
  , status409
  , status500
  )
import Network.Wai
  ( Application
  , Request
  , Response
  , pathInfo
  , requestHeaders
  , requestMethod
  , responseLBS
  , strictRequestBody
  )
import Network.Wai.Handler.Warp (run)
import Options.Applicative
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, hSetEncoding, stderr, stdout, utf8)

-- ---------------------------------------------------------------------------
-- Options / environment

data Options = Options
  { port :: !Int
  , secretFile :: !(Maybe FilePath)
  , productionBranch :: !Text
  , baseDomain :: !Text
  , workspace :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , configTimeout :: !Int
  }
  deriving stock (Generic, Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> option auto (long "port" <> metavar "PORT" <> value 8088 <> showDefault <> help "Listen port")
    <*> optional (strOption (long "secret-file" <> metavar "FILE" <> help "File with the webhook shared secret (else NAGARE_WEBHOOK_SECRET)"))
    <*> strOption (long "production-branch" <> metavar "BRANCH" <> value "main" <> showDefault <> help "Branch whose pushes deploy production")
    <*> strOption (long "base-domain" <> metavar "DOMAIN" <> value "apps.example.com" <> showDefault <> help "Apps base domain")
    <*> strOption (long "workspace" <> metavar "DIR" <> value "/var/lib/nagare/webhook-workspaces" <> showDefault <> help "Repository checkout workspace root")
    <*> optional (strOption (long "ghc-env" <> metavar "FILE" <> help "GHC package-environment file for the config loader's runghc"))
    <*> option
      positiveInt
      ( long "config-timeout"
          <> metavar "SECONDS"
          <> value (defaultConfigTimeout ^. #seconds)
          <> showDefault
          <> help "Kill a pushed nagare/Config.hs that has not finished within this many seconds"
      )

-- | An @optparse-applicative@ reader for a strictly positive whole number. A
-- zero or negative config timeout would make every load fail instantly, so it
-- is rejected at parse time with a usage error rather than accepted.
positiveInt :: ReadM Int
positiveInt = do
  n <- auto
  if n > 0
    then pure n
    else readerError "must be a positive number of seconds"

data Env = Env
  { secret :: !ByteString
  , productionBranch :: !Text
  , baseDomain :: !Text
  , workspace :: !FilePath
  , targetProfile :: !TargetProfile
  , activeTarget :: !ActiveTarget
  , configTimeout :: !ConfigTimeout
  }
  deriving stock (Generic, Show)

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetBuffering stdout LineBuffering
  o <- execParser parserInfo
  secret <- resolveSecret (o ^. #secretFile)
  provisionGhcEnv (o ^. #ghcEnv)
  active <- resolveActiveTarget Nothing
  let env =
        Env
          { secret = secret
          , productionBranch = o ^. #productionBranch
          , baseDomain = o ^. #baseDomain
          , workspace = o ^. #workspace
          , targetProfile = active ^. #profile
          , activeTarget = active
          , configTimeout = ConfigTimeout (o ^. #configTimeout)
          }
  putStrLn ("nagared listening on :" <> show (o ^. #port))
  run (o ^. #port) (app env)
  where
    parserInfo =
      info
        (optionsParser <**> helper)
        (fullDesc <> progDesc "nagared — Nagare Git webhook runner for static/server sites")

resolveSecret :: Maybe FilePath -> IO ByteString
resolveSecret (Just fp) = BS.readFile fp >>= pure . trimNewline
resolveSecret Nothing = do
  menv <- lookupEnv "NAGARE_WEBHOOK_SECRET"
  case menv of
    Just s -> pure (TE.encodeUtf8 (T.pack s))
    Nothing -> error "no webhook secret: pass --secret-file or set NAGARE_WEBHOOK_SECRET"

-- | Drop a single trailing newline a secret file commonly carries.
trimNewline :: ByteString -> ByteString
trimNewline bs
  | not (BS.null bs) && BS.last bs == 10 = BS.init bs
  | otherwise = bs

-- | Export a GHC package-environment file as @GHC_ENVIRONMENT@ for the loader's
-- child @runghc@ (EP-6 M1). An explicit path wins; otherwise the project's
-- @.ghc.environment.*@ is auto-discovered. 'Nothing' found ⇒ leave it unset.
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv (Just p) = do
  abs' <- makeAbsolute p
  setEnv "GHC_ENVIRONMENT" abs'
provisionGhcEnv Nothing = do
  mfile <- resolveProjectGhcEnv
  case mfile of
    Just f -> setEnv "GHC_ENVIRONMENT" f
    Nothing -> pure ()

-- ---------------------------------------------------------------------------
-- HTTP

app :: Env -> Application
app env req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["healthz"]) ->
      respond (textResponse status200 "ok")
    ("POST", ["webhooks", "github", "static", site]) ->
      handleWebhook env site req >>= respond
    _ ->
      respond (textResponse status404 "not found")

handleWebhook :: Env -> Text -> Request -> IO Response
handleWebhook env site req = do
  body <- LBS.toStrict <$> strictRequestBody req
  let hdr name = lookup name (requestHeaders req)
      cfg =
        WebhookConfig
          { secret = env ^. #secret
          , productionBranch = env ^. #productionBranch
          }
  -- Log every outcome: the operator's journal is the only place the reason a
  -- delivery did or did not deploy is visible (a fork PR, for instance, is a
  -- silent 200 to GitHub).
  case decideWebhook cfg (hdr "X-GitHub-Event") (hdr "X-Hub-Signature-256") body of
    Rejected code reason -> do
      putStrLn (T.unpack ("webhook " <> site <> ": rejected " <> T.pack (show code) <> ": " <> reason))
      pure (textResponse (statusFor code) reason)
    Ignored reason -> do
      putStrLn (T.unpack ("webhook " <> site <> ": ignored: " <> reason))
      pure (textResponse status200 reason)
    Triggered act -> do
      putStrLn (T.unpack ("webhook " <> site <> ": triggered " <> describeAction act))
      runAction env site act

-- | A one-line description of an accepted action, for the log.
describeAction :: DeployAction -> Text
describeAction = \case
  DeployProduction spec -> "production deploy of " <> spec ^. #repoFullName <> "@" <> T.take 12 (spec ^. #sha)
  DeployPreview name spec -> "preview '" <> name <> "' of " <> spec ^. #repoFullName <> "@" <> T.take 12 (spec ^. #sha)

runAction :: Env -> Text -> DeployAction -> IO Response
runAction env _site act = do
  gate <- webhookInventoryGate (env ^. #activeTarget)
  case gate of
    Left (status, reason) -> pure (textResponse status reason)
    Right () -> do
      let spec = actionCheckout act
      checkout <- checkoutRepo (env ^. #workspace) spec
      case checkout of
        Left e -> pure (textResponse status500 ("checkout failed: " <> e))
        Right dir -> do
          esite <- loadStaticSiteWith (env ^. #configTimeout) (dir </> "nagare" </> "Config.hs")
          case esite of
            Left le -> pure (textResponse status500 (renderLoadError le))
            Right s -> do
              gateBeforeDeploy <- webhookInventoryGate (env ^. #activeTarget)
              case gateBeforeDeploy of
                Left (status, reason) -> pure (textResponse status reason)
                Right () -> do
                  let inputs =
                        DeployInputs
                          { site = s
                          , imageTag = T.take 12 (spec ^. #sha)
                          , baseDomain = env ^. #baseDomain
                          , projectDir = dir
                          , skipBuild = False
                          , targetProfile = env ^. #targetProfile
                          }
                  outcome <- try (deployFor inputs act) :: IO (Either SomeException (Either Text Text))
                  pure $ case outcome of
                    Left ex -> textResponse status500 ("deploy raised: " <> T.pack (show ex))
                    Right (Left e) -> textResponse status500 e
                    Right (Right url) -> textResponse status200 ("deployed: " <> url)

-- | Webhooks have no reviewed image or site submission. Check the selected
-- context on every delivery, including a retry handled by a long-lived runner.
webhookInventoryGate :: ActiveTarget -> IO (Either (Status, Text) ())
webhookInventoryGate active = do
  opened <- Inventory.openTargetStoreReadOnly active
  pure $ case opened of
    Left (StoreConditionFailed "inventory store is not initialized") -> Right ()
    Left (StoreConditionFailed "inventory object prefix is not initialized") -> Right ()
    Left err -> Left (status500, "cannot verify inventory history before webhook deploy: " <> T.pack (show err))
    Right _ -> Left (status409, "inventory history is initialized; direct webhook deploy is refused")

deployFor :: DeployInputs -> DeployAction -> IO (Either Text Text)
deployFor inputs = \case
  DeployProduction spec -> deployStaticProduction inputs (Just (spec ^. #sha))
  DeployPreview name _ -> deployStaticPreview inputs name

actionCheckout :: DeployAction -> CheckoutSpec
actionCheckout (DeployProduction spec) = spec
actionCheckout (DeployPreview _ spec) = spec

textResponse :: Status -> Text -> Response
textResponse status msg =
  responseLBS status [("Content-Type", "text/plain; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (msg <> "\n")))

-- | Map a numeric status from 'decideWebhook' to a wai 'Status'.
statusFor :: Int -> Status
statusFor 400 = status400
statusFor 401 = status401
statusFor _ = status500
