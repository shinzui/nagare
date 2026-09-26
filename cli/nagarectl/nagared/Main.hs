-- | @nagared@ — the Nagare webhook runner (EP-16).
--
-- A small HTTP service that receives GitHub webhooks, verifies their HMAC-SHA256
-- signature, checks out the named commit, selects its accepted OCI publication,
-- and invokes the reviewed @nagarectl site@ command. A push to the configured
-- production branch triggers production; a pull-request open/sync triggers a
-- preview when its four environment stores are accepted.
--
-- Routes:
--
-- > GET  /healthz                              -> 200 (readiness)
-- > POST /webhooks/github/static/<site>        -> verify, checkout, deploy
--
-- The signature is checked before the body is parsed or any deploy runs, so an
-- unsigned or mis-signed request never reaches the reviewed command. The
-- selected context's initialized inventory store is checked on every delivery.
--
-- A retried delivery for the same commit repeats the reviewed submission;
-- inventory journal replay handles an interrupted apply.
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
import Nagare.Dsl.Static.Types (StaticSite, siteNameText)
import Nagare.Dsl.Types (imageRefText, namespaceText)
import Nagare.GhcEnv (resolveProjectGhcEnv)
import Nagare.Image (qualifyImage)
import Nagare.Inventory.Application (acceptedImageResourceForDestination)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.Site (acceptedSitePreviewStoreIds)
import Nagare.Inventory.Store (StoreError (..))
import Nagare.Resource.Types (resourceIdText)
import Nagare.Static.Checkout (checkoutRepo)
import Nagare.Static.Webhook
  ( CheckoutSpec (..)
  , DeployAction (..)
  , WebhookConfig (..)
  , WebhookOutcome (..)
  , decideWebhook
  , reviewedSiteArgs
  )
import Nagare.Target
  ( ActiveTarget
  , InventoryStoreKind (..)
  , Mode (..)
  , TargetProfile
  , contextNameText
  , effectiveInventoryStore
  , resolveActiveTarget
  )
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
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hSetBuffering, hSetEncoding, stderr, stdout, utf8)
import System.Process (proc, readCreateProcessWithExitCode)

-- ---------------------------------------------------------------------------
-- Options / environment

data Options = Options
  { port :: !Int
  , secretFile :: !(Maybe FilePath)
  , productionBranch :: !Text
  , baseDomain :: !Text
  , workspace :: !FilePath
  , ghcEnv :: !(Maybe FilePath)
  , nagarectlBin :: !FilePath
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
    <*> strOption (long "nagarectl-bin" <> metavar "FILE" <> value "nagarectl" <> showDefault <> help "Reviewed site command executable")
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
  , nagarectlBin :: !FilePath
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
  when (contextNameText (active ^. #contextName) == "default") $
    ioError (userError "nagared requires a named Nagare context before reviewed webhook deployment")
  let env =
        Env
          { secret = secret
          , productionBranch = o ^. #productionBranch
          , baseDomain = o ^. #baseDomain
          , workspace = o ^. #workspace
          , targetProfile = active ^. #profile
          , activeTarget = active
          , nagarectlBin = o ^. #nagarectlBin
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
runAction env site act = do
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
                  outcome <- try (submitReviewedSite env site dir s act)
                    :: IO (Either SomeException (Either (Status, Text) Text))
                  pure $ case outcome of
                    Left _ -> textResponse status500 "reviewed submission failed"
                    Right (Left (status, reason)) -> textResponse status reason
                    Right (Right tag) -> textResponse status200 ("reviewed site deployed: " <> tag)

-- | Require the shared history that makes a webhook image and site review
-- possible. Check on every delivery, including a retry on a long-lived runner.
webhookInventoryGate :: ActiveTarget -> IO (Either (Status, Text) ())
webhookInventoryGate active
  | active ^. #profile . #mode == Cloud
      && effectiveInventoryStore (active ^. #profile) == InventoryStoreLocal =
      pure (Left (status409, "cloud webhooks require a shared GCS inventory store"))
webhookInventoryGate active = do
  opened <- Inventory.openTargetStoreReadOnly active
  pure $ case opened of
    Left (StoreConditionFailed "inventory store is not initialized") ->
      Left (status409, "reviewed webhook requires initialized inventory history")
    Left (StoreConditionFailed "inventory object prefix is not initialized") ->
      Left (status409, "reviewed webhook requires initialized inventory history")
    Left err -> Left (status500, "cannot verify inventory history before webhook deploy: " <> T.pack (show err))
    Right _ -> Right ()

submitReviewedSite
  :: Env -> Text -> FilePath -> StaticSite -> DeployAction
  -> IO (Either (Status, Text) Text)
submitReviewedSite env routeSite dir site action =
  case qualifyImage (env ^. #targetProfile) (site ^. #image) of
    Left reason -> pure (Left (status400, reason))
    Right qualifiedImage
      | siteNameText (site ^. #name) /= routeSite ->
          pure (Left (status400, "webhook route does not match the checked-out site"))
      | otherwise -> do
          let tag = T.take 12 (actionCheckout action ^. #sha)
              destination = imageRefText qualifiedImage <> ":" <> tag
              name = siteNameText (site ^. #name)
              ns = namespaceText (site ^. #namespace)
          snapshot <- Inventory.loadTargetSnapshot (env ^. #activeTarget)
          case acceptedImageResourceForDestination snapshot destination of
            Left reason -> pure (Left (status409, reason))
            Right imageId -> do
              previewIds <- case action of
                DeployProduction _ -> pure (Right [])
                DeployPreview _ _ -> pure $ do
                  (cluster, _) <- acceptedFoundationNamespace snapshot ns
                  acceptedSitePreviewStoreIds snapshot cluster name ns
              case previewIds of
                Left reason -> pure (Left (status409, reason))
                Right stores -> do
                  let args = reviewedSiteArgs
                        (contextNameText (env ^. #activeTarget . #contextName))
                        (dir </> "nagare" </> "Config.hs") dir (env ^. #baseDomain)
                        (resourceIdText imageId) (map resourceIdText stores) action
                  (exitCode, _, _) <- readCreateProcessWithExitCode
                    (proc (env ^. #nagarectlBin) args) ""
                  case exitCode of
                    ExitSuccess -> pure (Right tag)
                    ExitFailure code -> do
                      putStrLn ("reviewed site command failed with exit " <> show code)
                      pure (Left (status409, "reviewed site submission refused; inspect nagared logs"))

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
