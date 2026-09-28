-- | Redis client observation for an online, single-Pod maintenance fence.
-- The observing client is the only connection allowed after managed writers
-- drain; a surviving terminal must be stopped before release.
module Nagare.Inventory.DataFence.MaintenanceRedis
  ( RedisMaintenanceTransport (..)
  , kubectlRedisMaintenanceTransport
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

data RedisMaintenanceTransport = RedisMaintenanceTransport
  { observeRedisClients :: !(Text -> Text -> Text -> IO (Either Text Bool))
  , terminateMarkedRedisClients :: !(Text -> Text -> Text -> Text
      -> IO (Either Text ()))
  }

kubectlRedisMaintenanceTransport :: KubernetesRuntimeConfig
  -> RedisMaintenanceTransport
kubectlRedisMaintenanceTransport config = RedisMaintenanceTransport observe terminateMarked
  where
    observe namespace pod uid = do
      before <- readUid namespace pod
      case before of
        Left reason -> pure (Left reason)
        Right observed | observed /= uid ->
          pure (Left "maintenance Redis Pod incarnation changed")
        Right _ -> do
          listing <- invoke namespace
            ["exec", T.unpack pod, "--container", "redis", "--", "sh", "-c",
              "REDISCLI_AUTH=\"$REDIS_PASSWORD\" exec redis-cli --no-auth-warning --raw CLIENT LIST"]
          after <- readUid namespace pod
          pure $ do
            (_, output, _) <- listing >>= requireSuccess
            current <- after
            unless (current == uid)
              (Left "maintenance Redis Pod changed during client observation")
            let clients = filter (not . T.null) (T.lines (T.pack output))
            unless (all (T.isInfixOf "id=") clients)
              (Left "maintenance Redis client listing is malformed")
            pure (length clients == 1 && any
              (T.isInfixOf "cmd=client|list") clients)

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
              pure (Left "maintenance Redis Pod incarnation changed")
            Right _ -> do
              let marker = "nagare-maintenance-" <> session
                  stopScript = unlines
                    [ "set -eu"
                    , "for path in /proc/[0-9]*/environ; do"
                    , "  [ -r \"$path\" ] || continue"
                    , "  pid=${path#/proc/}; pid=${pid%/environ}"
                    , "  grep -qx redis-cli \"/proc/$pid/comm\" 2>/dev/null || continue"
                    , "  grep -azFxq \"NAGARE_MAINTENANCE_SESSION=$1\" \"$path\" 2>/dev/null || continue"
                    , "  kill -TERM \"$pid\""
                    , "done"
                    , "for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do"
                    , "  found=0"
                    , "  for path in /proc/[0-9]*/environ; do"
                    , "    [ -r \"$path\" ] || continue"
                    , "    pid=${path#/proc/}; pid=${pid%/environ}"
                    , "    grep -qx redis-cli \"/proc/$pid/comm\" 2>/dev/null || continue"
                    , "    if grep -azFxq \"NAGARE_MAINTENANCE_SESSION=$1\" \"$path\" 2>/dev/null; then found=1; fi"
                    , "  done"
                    , "  [ \"$found\" -eq 0 ] && exit 0"
                    , "  sleep 0.25"
                    , "done"
                    , "exit 1" ]
              stopped <- invoke namespace
                ["exec", T.unpack pod, "--container", "redis", "--",
                  "sh", "-c", stopScript, "sh", T.unpack marker]
              after <- readUid namespace pod
              pure $ do
                _ <- stopped >>= requireSuccess
                current <- after
                unless (current == uid)
                  (Left "maintenance Redis Pod changed during client termination")

    readUid namespace pod = do
      result <- invoke namespace ["get", "pod", T.unpack pod, "-o",
        "jsonpath={.metadata.uid}"]
      pure $ do
        (_, output, _) <- result >>= requireSuccess
        let value = T.strip (T.pack output)
        if T.null value then Left "maintenance Redis Pod UID is absent"
          else Right value

    requireSuccess result = case result of
      (ExitSuccess, _, _) -> Right result
      _ -> Left "maintenance Redis client observation failed"

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
              Left "could not invoke kubectl for Redis clients"
            Right output -> Right output
