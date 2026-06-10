{-# LANGUAGE PackageImports #-}

-- | @nagarectl db shell NAME@ (MasterPlan 9, EP-45): open an interactive engine
-- client inside the database pod via @kubectl exec -it@. The credentials are
-- already present in the pod's environment (the StatefulSet wires them from the
-- managed Secret), so the client reads them from env rather than embedding the
-- password in argv.
module Nagare.Database.Shell
  ( runDbShell
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Database.Discover (DbRow (..), getDatabase)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Exec the engine-appropriate client inside @\<name\>-0@.
runDbShell :: Text -> Text -> IO ()
runDbShell ns name = do
  erow <- getDatabase ns name
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right r -> case clientArgs (drEngine r) of
      Nothing -> do
        TIO.hPutStrLn stderr ("nagarectl: unknown engine '" <> drEngine r <> "' for db shell")
        exitFailure
      Just clientCmd ->
        run_ $
          cmd "kubectl"
            & addArgs
              ( ["exec", "-it", T.unpack name <> "-0", "-n", T.unpack ns, "--"]
                  <> map T.unpack clientCmd
              )

-- | The in-pod client invocation per engine. Postgres' @psql@ reads
-- @PGUSER@/@PGPASSWORD@/@PGDATABASE@ — but the StatefulSet sets @POSTGRES_*@, so
-- we pass @-U@/db explicitly and rely on the trust/local socket; simplest robust
-- form is @psql -U \<user\> \<db\>@ using the pod's @POSTGRES_USER@/@POSTGRES_DB@
-- via a shell. Redis and ClickHouse read the password from their env var.
clientArgs :: Text -> Maybe [Text]
clientArgs "postgres" =
  Just ["sh", "-c", "PGPASSWORD=\"$POSTGRES_PASSWORD\" psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
clientArgs "redis" =
  Just ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\""]
clientArgs "clickhouse" =
  Just ["sh", "-c", "clickhouse-client -u \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\""]
clientArgs _ = Nothing
