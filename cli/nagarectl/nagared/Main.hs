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
-- handling is idempotent: a retried delivery for the same commit re-resets the
-- checkout and re-records the same release id (deduped), so no duplicate work.
module Main (main) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
  ( Status
  , status200
  , status400
  , status401
  , status404
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
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

import Nagare.Dsl.Load (loadStaticSite, renderLoadError)
import Nagare.GhcEnv (resolveProjectGhcEnv)
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

-- ---------------------------------------------------------------------------
-- Options / environment

data Options = Options
  { optPort :: !Int
  , optSecretFile :: !(Maybe FilePath)
  , optProductionBranch :: !Text
  , optBaseDomain :: !Text
  , optWorkspace :: !FilePath
  , optGhcEnv :: !(Maybe FilePath)
  }

optionsParser :: Parser Options
optionsParser =
  Options
    <$> option auto (long "port" <> metavar "PORT" <> value 8088 <> showDefault <> help "Listen port")
    <*> optional (strOption (long "secret-file" <> metavar "FILE" <> help "File with the webhook shared secret (else NAGARE_WEBHOOK_SECRET)"))
    <*> strOption (long "production-branch" <> metavar "BRANCH" <> value "main" <> showDefault <> help "Branch whose pushes deploy production")
    <*> strOption (long "base-domain" <> metavar "DOMAIN" <> value "apps.example.com" <> showDefault <> help "Apps base domain")
    <*> strOption (long "workspace" <> metavar "DIR" <> value "/var/lib/nagare/webhook-workspaces" <> showDefault <> help "Repository checkout workspace root")
    <*> optional (strOption (long "ghc-env" <> metavar "FILE" <> help "GHC package-environment file for the config loader's runghc"))

data Env = Env
  { envSecret :: !ByteString
  , envProductionBranch :: !Text
  , envBaseDomain :: !Text
  , envWorkspace :: !FilePath
  }

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  o <- execParser parserInfo
  secret <- resolveSecret (optSecretFile o)
  provisionGhcEnv (optGhcEnv o)
  let env =
        Env
          { envSecret = secret
          , envProductionBranch = optProductionBranch o
          , envBaseDomain = optBaseDomain o
          , envWorkspace = optWorkspace o
          }
  putStrLn ("nagared listening on :" <> show (optPort o))
  run (optPort o) (app env)
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
          { secret = envSecret env
          , productionBranch = envProductionBranch env
          }
  case decideWebhook cfg (hdr "X-GitHub-Event") (hdr "X-Hub-Signature-256") body of
    Rejected code reason -> pure (textResponse (statusFor code) reason)
    Ignored reason -> pure (textResponse status200 reason)
    Triggered act -> runAction env site act

runAction :: Env -> Text -> DeployAction -> IO Response
runAction env _site act = do
  let spec = actionCheckout act
  checkout <- checkoutRepo (envWorkspace env) spec
  case checkout of
    Left e -> pure (textResponse status500 ("checkout failed: " <> e))
    Right dir -> do
      esite <- loadStaticSite (dir </> "nagare" </> "Config.hs")
      case esite of
        Left le -> pure (textResponse status500 (renderLoadError le))
        Right s -> do
          let inputs =
                DeployInputs
                  { site = s
                  , imageTag = T.take 12 (sha spec)
                  , baseDomain = envBaseDomain env
                  , projectDir = dir
                  , skipBuild = False
                  }
          outcome <- try (deployFor inputs act) :: IO (Either SomeException (Either Text Text))
          pure $ case outcome of
            Left ex -> textResponse status500 ("deploy raised: " <> T.pack (show ex))
            Right (Left e) -> textResponse status500 e
            Right (Right url) -> textResponse status200 ("deployed: " <> url)

deployFor :: DeployInputs -> DeployAction -> IO (Either Text Text)
deployFor inputs = \case
  DeployProduction spec -> deployStaticProduction inputs (Just (sha spec))
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
