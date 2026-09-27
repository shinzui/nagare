-- | PostgreSQL's own client-backend view closes the gap left by stopping
-- controllers: an established connection may survive a new ingress denial.
module Nagare.Inventory.DataFence.MaintenancePostgres
  ( PostgresMaintenanceTransport (..)
  , kubectlPostgresMaintenanceTransport
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data PostgresMaintenanceTransport = PostgresMaintenanceTransport
  { observePostgresClients :: !(Text -> Text -> Text -> IO (Either Text Bool))
  }

-- | Query through the selected server's Unix socket using its injected
-- database role. The query excludes only its own backend. Read the Pod UID on both
-- sides so an exec redirected to a replacement Pod cannot certify exclusion.
kubectlPostgresMaintenanceTransport :: KubernetesRuntimeConfig
  -> PostgresMaintenanceTransport
kubectlPostgresMaintenanceTransport config = PostgresMaintenanceTransport observe
  where
    observe namespace pod uid = do
      before <- readUid namespace pod
      case before of
        Left reason -> pure (Left reason)
        Right observed | observed /= uid ->
          pure (Left "maintenance PostgreSQL Pod incarnation changed")
        Right _ -> do
          counted <- invoke namespace
            ["exec", T.unpack pod, "--container", "postgres", "--",
              "sh", "-c",
              "psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -Atqc \"select count(*) from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()\""]
          after <- readUid namespace pod
          pure $ do
            count <- counted >>= parseCount
            current <- after
            if current == uid then Right (count == 0)
              else Left "maintenance PostgreSQL Pod changed during client observation"

    readUid namespace pod = do
      result <- invoke namespace ["get", "pod", T.unpack pod, "-o",
        "jsonpath={.metadata.uid}"]
      pure $ do
        (_, output, _) <- result >>= requireSuccess
        let value = T.strip (T.pack output)
        if T.null value then Left "maintenance PostgreSQL Pod UID is absent"
          else Right value

    parseCount result = do
      (_, output, _) <- requireSuccess result
      case reads (T.unpack (T.strip (T.pack output))) of
        [(number, "")] | number >= (0 :: Int) -> Right number
        _ -> Left "maintenance PostgreSQL client count is malformed"

    requireSuccess result = case result of
      (ExitSuccess, _, _) -> Right result
      _ -> Left "maintenance PostgreSQL client observation failed"

    invoke namespace arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <- try (readProcessWithExitCode "kubectl"
            (["--context", T.unpack (runtimeKubectlContext config),
              "--request-timeout=10s", "--namespace", T.unpack namespace]
              <> arguments) "")
          pure $ case result of
            Left (_ :: IOException) ->
              Left "could not invoke kubectl for PostgreSQL clients"
            Right output -> Right output
