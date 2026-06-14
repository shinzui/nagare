-- | @nagarectl storage inspect APP VOLUME@ (EP-35): show the full detail of one
-- declared volume's PVC via @kubectl describe@.
--
-- The @VOLUME@ argument is resolved to its deterministic PVC name
-- ('Nagare.Storage.Discover.pvcName', IP3); a volume the config does not declare
-- is a clear error (exit non-zero) rather than a confusing empty @describe@.
module Nagare.Storage.Inspect
  ( runStorageInspect
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Types (Deployment, namespaceText, serviceNameText, volumeNameText)
import Nagare.Storage.Discover (pvcName)
import System.Exit (exitFailure)
import System.IO (stderr)

-- | @kubectl describe@ the PVC for @volume@ of the app described by the loaded
-- 'Deployment'. Errors if the config declares no such volume.
runStorageInspect :: Deployment -> Text -> IO ()
runStorageInspect dep volume = do
  let app = serviceNameText (dep ^. #name)
      ns = namespaceText (dep ^. #namespace)
      declared = map (volumeNameText . (^. #volName)) (dep ^. #volumes)
  if volume `notElem` declared
    then do
      TIO.hPutStrLn
        stderr
        ("nagarectl: app " <> app <> " declares no volume named '" <> volume <> "'")
      exitFailure
    else
      run_ $
        cmd "kubectl"
          & addArgs ["describe", "pvc", T.unpack (pvcName app volume), "-n", T.unpack ns]
