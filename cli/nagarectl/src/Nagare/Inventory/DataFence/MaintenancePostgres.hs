-- | PostgreSQL's own client-backend view closes the gap left by stopping
-- controllers: an established connection may survive a new ingress denial.
module Nagare.Inventory.DataFence.MaintenancePostgres
  ( PostgresMaintenanceTransport (..)
  , kubectlPostgresMaintenanceTransport
  ) where

import Control.Exception (IOException, try)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  (KubernetesRuntimeConfig (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data PostgresMaintenanceTransport = PostgresMaintenanceTransport
  { observePostgresClients :: !(Text -> Text -> Text -> IO (Either Text Bool))
  , terminateMarkedPostgresClients :: !(Text -> Text -> Text -> Text
      -> IO (Either Text ()))
  }

-- | Query through the selected server's Unix socket using its injected
-- database role. The query excludes only its own backend. Read the Pod UID on both
-- sides so an exec redirected to a replacement Pod cannot certify exclusion.
kubectlPostgresMaintenanceTransport :: KubernetesRuntimeConfig
  -> PostgresMaintenanceTransport
kubectlPostgresMaintenanceTransport config = PostgresMaintenanceTransport
  observe terminateMarked
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

    terminateMarked namespace pod uid session
      | T.null session || T.length session > 20
          || not (T.all (\character -> isAsciiLower character
            || isDigit character || character == '-') session) =
          pure (Left "maintenance session marker is malformed")
      | otherwise = do
          before <- readUid namespace pod
          case before of
            Left reason -> pure (Left reason)
            Right observed | observed /= uid ->
              pure (Left "maintenance PostgreSQL Pod incarnation changed")
            Right _ -> do
              let marker = "nagare-maintenance-" <> session
                  sql = "select coalesce(bool_and(pg_terminate_backend(pid)), true) "
                    <> "from pg_stat_activity where backend_type = 'client backend' "
                    <> "and application_name = '" <> marker
                    <> "' and pid <> pg_backend_pid()"
                  stopScript = unlines
                    [ "set -eu"
                    , "for path in /proc/[0-9]*/environ; do"
                    , "  [ -r \"$path\" ] || continue"
                    , "  pid=${path#/proc/}; pid=${pid%/environ}"
                    , "  grep -qx psql \"/proc/$pid/comm\" 2>/dev/null || continue"
                    , "  grep -azFxq \"PGAPPNAME=$1\" \"$path\" 2>/dev/null || continue"
                    , "  kill -TERM \"$pid\""
                    , "done"
                    , "for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do"
                    , "  found=0"
                    , "  for path in /proc/[0-9]*/environ; do"
                    , "    [ -r \"$path\" ] || continue"
                    , "    pid=${path#/proc/}; pid=${pid%/environ}"
                    , "    grep -qx psql \"/proc/$pid/comm\" 2>/dev/null || continue"
                    , "    if grep -azFxq \"PGAPPNAME=$1\" \"$path\" 2>/dev/null; then found=1; fi"
                    , "  done"
                    , "  [ \"$found\" -eq 0 ] && exit 0"
                    , "  sleep 0.25"
                    , "done"
                    , "exit 1" ]
              stopped <- invoke namespace
                ["exec", T.unpack pod, "--container", "postgres", "--",
                  "sh", "-c", stopScript, "sh", T.unpack marker]
              case stopped >>= requireSuccess of
                Left _ -> pure (Left
                  "maintenance marked PostgreSQL client process did not stop")
                Right _ -> do
                  terminated <- invoke namespace
                    ["exec", T.unpack pod, "--container", "postgres", "--",
                      "sh", "-c",
                      "psql -v ON_ERROR_STOP=1 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -Atqc \"$1\"",
                      "sh", T.unpack sql]
                  after <- readUid namespace pod
                  pure $ do
                    (_, output, _) <- terminated >>= requireSuccess
                    unless (T.strip (T.pack output) == "t")
                      (Left "maintenance marked PostgreSQL backend termination was refused")
                    current <- after
                    unless (current == uid)
                      (Left "maintenance PostgreSQL Pod changed during client termination")

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
