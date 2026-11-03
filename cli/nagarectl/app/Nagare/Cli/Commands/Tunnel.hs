-- | Commands / Tunnel. Executable-private CLI boundary.
--
-- The operator's side of a tunnel context (ADR 34). The tunnel and its rules are reviewed inventory
-- members; these commands move the token between Cloudflare and sops, rotate it, and show what
-- Cloudflare sees. The API token stays in this process's environment.
module Nagare.Cli.Commands.Tunnel
  ( runTunnel
  )
where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cdn.Cloudflare (cfRequestWithStatus)
import Nagare.Cli.Options (TunnelCommand (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.CloudflareTunnel (cloudflareTunnelTokenSecretFile)
import Nagare.Inventory.Components.CloudflareZone (cloudflareTunnelName)
import Nagare.Inventory.Components.ObservabilitySecrets (contextSecretsDirectory)
import Nagare.Ops.CloudflareTunnel
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Target
  ( ActiveTarget
  , IngressMode (IngressCloudflareTunnel)
  , contextNameText
  )
import System.Directory (doesFileExist, renameFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess), exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Process (proc, readCreateProcessWithExitCode)

runTunnel :: Maybe String -> TunnelCommand -> IO ()
runTunnel mctx command = do
  active <- activeTarget mctx
  unless
    (active ^. #profile . #ingress == IngressCloudflareTunnel)
    (dieT "this context's NAGARE_INGRESS is not cloudflare-tunnel")
  account <- requiredEnv "CF_ACCOUNT_ID"
  apiToken <- requiredEnv "CF_API_TOKEN"
  let request = cfRequestWithStatus apiToken
      tunnelPath suffix tunnelId = "/accounts/" <> account <> "/cfd_tunnel/" <> tunnelId <> suffix
      name = cloudflareTunnelName (contextNameText (active ^. #contextName))
      findTunnel = do
        listed <- request "GET" ("/accounts/" <> account <> "/cfd_tunnel?is_deleted=false&name=" <> name) Nothing >>= orDie
        either dieT pure (uncurry (parseTunnelId name) listed)
      saveToken tunnelId = do
        received <- request "GET" (tunnelPath "/token" tunnelId) Nothing >>= orDie
        token <- either dieT pure (uncurry parseTunnelToken received)
        writeEncryptedToken active token
  case command of
    TunnelToken -> findTunnel >>= saveToken
    TunnelRotate yes -> do
      unless yes (dieT "rotating the tunnel secret needs --yes; a running connector keeps serving until the next reviewed apply rolls it")
      tunnelId <- findTunnel
      secret <- randomSecret
      rotated <- request "PATCH" (tunnelPath "" tunnelId) (Just (object ["tunnel_secret" .= secret])) >>= orDie
      unless (fst rotated >= 200 && fst rotated < 300) (dieT ("Cloudflare refused the rotation: HTTP " <> T.pack (show (fst rotated))))
      saveToken tunnelId
      TIO.putStrLn "Rotated. The old token is refused for new connections, but running connectors keep theirs."
      TIO.putStrLn "Next: `nagarectl platform bootstrap plan`, apply it to roll the connector, then `nagarectl tunnel status`, and `nagarectl tunnel evict ID` for anything left."
    TunnelStatus -> do
      tunnelId <- findTunnel
      listed <- request "GET" (tunnelPath "/connections" tunnelId) Nothing >>= orDie
      connectors <- either dieT pure (uncurry parseConnectors listed)
      (_, workspace) <- ensurePulumiForActiveContext mctx
      address <-
        maybe (dieT "this context's stack has no publicIp output") pure
          =<< stackOutput (workspace ^. #pulumiDir) "publicIp"
      TIO.putStrLn ("tunnel " <> name <> " (" <> tunnelId <> ")")
      forM_ connectors $ \connector ->
        TIO.putStrLn
          ( "connector "
              <> connector ^. #connectorId
              <> " version "
              <> connector ^. #connectorVersion
              <> " from "
              <> T.intercalate "," (connector ^. #connectorOrigins)
          )
      configured <- request "GET" (tunnelPath "/configurations" tunnelId) Nothing >>= orDie
      rules <- either dieT pure (uncurry parseTunnelRules configured)
      case connectorProblems expectedConnectors address connectors <> tunnelRuleProblems (active ^. #profile . #baseDomain) rules of
        [] -> TIO.putStrLn "ok: only this context's connectors, and the declared rules"
        problems -> do
          mapM_ (TIO.putStrLn . ("FAIL: " <>)) problems
          exitFailure
    TunnelEvict connector yes -> do
      unless yes (dieT "evicting a connector needs --yes; it can reconnect unless its token was rotated first")
      tunnelId <- findTunnel
      evicted <- request "DELETE" (tunnelPath "/connections?client_id=" tunnelId <> T.pack connector) Nothing >>= orDie
      unless (fst evicted >= 200 && fst evicted < 300) (dieT ("Cloudflare refused the eviction: HTTP " <> T.pack (show (fst evicted))))
      TIO.putStrLn ("Evicted " <> T.pack connector <> ".")
  where
    orDie = either dieT pure

requiredEnv :: String -> IO T.Text
requiredEnv name =
  lookupEnv name >>= \case
    Just value | not (null value) -> pure (T.pack value)
    _ -> dieT (T.pack name <> " is required: tunnel commands use the operator's scoped Cloudflare credentials")

randomSecret :: IO T.Text
randomSecret = TE.decodeUtf8 . Base64.encode <$> withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 32)

-- | Encrypt with the context's own @.sops.yaml@, the token reaching sops on stdin only, and replace
-- the file in one step so a failed run leaves the previous token.
writeEncryptedToken :: ActiveTarget -> T.Text -> IO ()
writeEncryptedToken active token = do
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  directory <- contextSecretsDirectory (workspace ^. #root) (contextNameText (active ^. #contextName))
  let config = directory </> ".sops.yaml"
      path = directory </> cloudflareTunnelTokenSecretFile
      temporary = path <> ".new"
  hasConfig <- doesFileExist config
  unless hasConfig (dieT ("no sops recipients for this context's secrets: " <> T.pack config))
  (code, encrypted, _) <-
    readCreateProcessWithExitCode
      ( proc
          "sops"
          ["--config", config, "--encrypt", "--input-type", "yaml", "--output-type", "yaml", "--filename-override", path, "/dev/stdin"]
      )
      (T.unpack (tokenSecretYaml token))
  -- sops's error text can quote its input, so it is not repeated here.
  unless (code == ExitSuccess && "ENC[" `T.isInfixOf` T.pack encrypted) (dieT "sops could not encrypt the tunnel token")
  writeFile temporary encrypted
  setFileMode temporary (ownerReadMode `unionFileModes` ownerWriteMode)
  renameFile temporary path
  TIO.putStrLn ("Wrote the encrypted tunnel token to " <> T.pack path <> ". Commit it with the operator's other secrets.")
