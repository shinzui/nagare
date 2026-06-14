-- | @nagarectl storage list@ (EP-35): print a table of an app's declared
-- volumes joined to their live PVC status on the cluster.
--
-- Identity and the declared volume set come from the loaded typed config (the
-- source of truth for what /should/ exist); the cluster reports what PVCs
-- currently exist (via 'Nagare.Storage.Discover.listAppPVCs'). A declared volume
-- with no PVC shows @MISSING@, so a never-deployed volume is visible.
module Nagare.Storage.List
  ( runStorageList
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Types (Deployment, namespaceText, serviceNameText)
import Nagare.Storage.Discover (formatStorageTable, listAppPVCs)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | Print the @VOLUME PVC SIZE STATUS NODE-PATH@ table for the app described by
-- the loaded 'Deployment'. Read-only.
runStorageList :: Deployment -> IO ()
runStorageList dep = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      vols = dep ^. #volumes
  erows <- listAppPVCs ns app
  case erows of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right rows -> TIO.putStr (formatStorageTable app vols rows)
