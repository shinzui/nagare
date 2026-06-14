-- | @nagarectl db get NAME@ (MasterPlan 9, EP-45): show one managed database's
-- detail (engine, version, size, in-cluster host, readiness) plus the /key names/
-- present in its managed Secret — never the values. Read-only.
module Nagare.Database.Get
  ( runDbGet
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.List (sort)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (dbSecretName)
import Nagare.Env.Store (extractSecretData)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

-- | Print the field block for one database, or a clear error if it is unknown.
runDbGet :: Text -> Text -> IO ()
runDbGet ns name = do
  erow <- getDatabase ns name
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right r -> do
      keys <- secretKeyNames ns name
      TIO.putStr $
        T.unlines
          [ "Name:      " <> drName r
          , "Engine:    " <> drEngine r
          , "Version:   " <> drVersion r
          , "Size:      " <> drSize r
          , "Host:      " <> drHost r
          , "Retention: " <> drRetention r
          , "Ready:     " <> (if drReady r then "True" else "False")
          , "Secret:    " <> dbSecretName name <> " (" <> T.intercalate ", " keys <> ")"
          ]

-- | The sorted key names present in the managed Secret (values never shown).
-- An absent/unreadable Secret yields an empty list.
secretKeyNames :: Text -> Text -> IO [Text]
secretKeyNames ns name = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "secret", T.unpack (dbSecretName name), "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> []
    ExitSuccess -> case extractSecretData out of
      Right kvs -> sort (Map.keys kvs)
      Left _ -> []
