-- | Observe ClickHouse's idle and active client connections while an online
-- maintenance fence keeps its exact server Pod running.
module Nagare.Inventory.DataFence.MaintenanceClickHouse
  ( ClickHouseMaintenanceTransport (..)
  , kubectlClickHouseMaintenanceTransport
  )
where

import Control.Exception (IOException, try)
import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data ClickHouseMaintenanceTransport = ClickHouseMaintenanceTransport
  { observeClickHouseClients :: !(Text -> Text -> Text -> IO (Either Text Bool))
  , terminateMarkedClickHouseClients ::
      !( Text ->
         Text ->
         Text ->
         Text ->
         IO (Either Text ())
       )
  }

kubectlClickHouseMaintenanceTransport ::
  KubernetesRuntimeConfig ->
  ClickHouseMaintenanceTransport
kubectlClickHouseMaintenanceTransport config =
  ClickHouseMaintenanceTransport
    observe
    terminateMarked
  where
    observe namespace pod uid = do
      before <- readUid namespace pod
      case before of
        Left reason -> pure (Left reason)
        Right observed
          | observed /= uid ->
              pure (Left "maintenance ClickHouse Pod incarnation changed")
        Right _ -> do
          let query =
                "SELECT metric, value FROM system.metrics WHERE metric IN "
                  <> "('TCPConnection','HTTPConnection','MySQLConnection',"
                  <> "'PostgreSQLConnection','InterserverConnection') "
                  <> "ORDER BY metric FORMAT TSV"
          metrics <-
            invoke
              namespace
              [ "exec"
              , T.unpack pod
              , "--container"
              , "clickhouse"
              , "--"
              , "sh"
              , "-c"
              , "clickhouse-client --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query \"$1\""
              , "sh"
              , T.unpack query
              ]
          after <- readUid namespace pod
          pure $ do
            (_, output, _) <- metrics >>= requireSuccess
            current <- after
            unless
              (current == uid)
              (Left "maintenance ClickHouse Pod changed during client observation")
            values <- parseMetrics (T.pack output)
            pure
              ( values
                  == Map.fromList
                    [ ("TCPConnection", 1)
                    , ("HTTPConnection", 0)
                    , ("MySQLConnection", 0)
                    , ("PostgreSQLConnection", 0)
                    , ("InterserverConnection", 0)
                    ]
              )

    terminateMarked namespace pod uid session
      | T.null session
          || T.length session > 20
          || not
            ( T.all
                ( \character ->
                    isAsciiLower character
                      || isDigit character
                      || character == '-'
                )
                session
            ) =
          pure (Left "maintenance session marker is malformed")
      | otherwise = do
          before <- readUid namespace pod
          case before of
            Left reason -> pure (Left reason)
            Right observed
              | observed /= uid ->
                  pure (Left "maintenance ClickHouse Pod incarnation changed")
            Right _ -> do
              let marker = "nagare-maintenance-" <> session
                  stopScript =
                    unlines
                      [ "set -eu"
                      , "for path in /proc/[0-9]*/environ; do"
                      , "  [ -r \"$path\" ] || continue"
                      , "  pid=${path#/proc/}; pid=${pid%/environ}"
                      , "  grep -qx clickhouse-clie \"/proc/$pid/comm\" 2>/dev/null || continue"
                      , "  grep -azFxq \"NAGARE_MAINTENANCE_SESSION=$1\" \"$path\" 2>/dev/null || continue"
                      , "  kill -TERM \"$pid\""
                      , "done"
                      , "for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do"
                      , "  found=0"
                      , "  for path in /proc/[0-9]*/environ; do"
                      , "    [ -r \"$path\" ] || continue"
                      , "    pid=${path#/proc/}; pid=${pid%/environ}"
                      , "    grep -qx clickhouse-clie \"/proc/$pid/comm\" 2>/dev/null || continue"
                      , "    if grep -azFxq \"NAGARE_MAINTENANCE_SESSION=$1\" \"$path\" 2>/dev/null; then found=1; fi"
                      , "  done"
                      , "  [ \"$found\" -eq 0 ] && exit 0"
                      , "  sleep 0.25"
                      , "done"
                      , "exit 1"
                      ]
              stopped <-
                invoke
                  namespace
                  [ "exec"
                  , T.unpack pod
                  , "--container"
                  , "clickhouse"
                  , "--"
                  , "sh"
                  , "-c"
                  , stopScript
                  , "sh"
                  , T.unpack marker
                  ]
              after <- readUid namespace pod
              pure $ do
                _ <- stopped >>= requireSuccess
                current <- after
                unless
                  (current == uid)
                  (Left "maintenance ClickHouse Pod changed during client termination")

    readUid namespace pod = do
      result <-
        invoke
          namespace
          [ "get"
          , "pod"
          , T.unpack pod
          , "-o"
          , "jsonpath={.metadata.uid}"
          ]
      pure $ do
        (_, output, _) <- result >>= requireSuccess
        let value = T.strip (T.pack output)
        if T.null value
          then Left "maintenance ClickHouse Pod UID is absent"
          else Right value

    requireSuccess result = case result of
      (ExitSuccess, _, _) -> Right result
      _ -> Left "maintenance ClickHouse client observation failed"

    invoke namespace arguments = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <-
            try
              ( readProcessWithExitCode
                  "kubectl"
                  ( [ "--context"
                    , T.unpack (runtimeKubectlContext config)
                    , "--request-timeout=10s"
                    , "--namespace"
                    , T.unpack namespace
                    ]
                      <> arguments
                  )
                  ""
              )
          pure $ case result of
            Left (_ :: IOException) ->
              Left "could not invoke kubectl for ClickHouse clients"
            Right output -> Right output

parseMetrics :: Text -> Either Text (Map Text Int)
parseMetrics output = do
  values <- traverse parseLine (filter (not . T.null) (T.lines output))
  let observed = Map.fromList values
  unless
    (length values == Map.size observed && Map.size observed == 5)
    (Left "maintenance ClickHouse connection metrics are incomplete")
  pure observed
  where
    parseLine line = case T.splitOn "\t" line of
      [name, value] -> case reads (T.unpack value) of
        [(count, "")] | count >= (0 :: Int) -> Right (name, count)
        _ -> Left "maintenance ClickHouse connection count is malformed"
      _ -> Left "maintenance ClickHouse connection metrics are malformed"
