{-# LANGUAGE PackageImports #-}

-- | @nagarectl db list@ (MasterPlan 9, EP-45): print a table of all managed
-- databases in a namespace, discovered by the IP3 labels. Read-only.
module Nagare.Database.List
  ( runDbList
  ) where

import Nagare.Dsl.Prelude

import Data.Text.IO qualified as TIO
import Nagare.Database.Discover (formatDbTable, listDatabases)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Print the @NAME ENGINE VERSION SIZE STATUS HOST@ table for the namespace.
runDbList :: Text -> IO ()
runDbList ns = do
  erows <- listDatabases ns
  case erows of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right rows -> TIO.putStr (formatDbTable rows)
