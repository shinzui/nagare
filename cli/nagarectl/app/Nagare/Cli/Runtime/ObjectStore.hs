-- | Runtime / ObjectStore. Executable-private CLI boundary.
module Nagare.Cli.Runtime.ObjectStore
  ( resolveStoreBackend
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeProfile)
import Nagare.Cluster.GcsJob (StoreBackend)
import Nagare.Dsl.Prelude
import Nagare.Target (storeBackendFor)

-- | Resolve the GCS backup bucket: an explicit @--bucket@ flag wins; otherwise
-- the resolved target profile's backup bucket (EP-62; honors
-- @NAGARE_BACKUP_BUCKET@ and the @\<project>-nagare-backups@ derivation).
resolveBackupBucket :: Maybe String -> Maybe String -> IO Text
resolveBackupBucket _ (Just b) = pure (T.pack b)
resolveBackupBucket mctx Nothing = (^. #backupBucket) <$> activeProfile mctx

-- | Resolve the object-store backend for the four data-movement verbs (EP-84):
-- the cloud GCS backend (project + 'resolveBackupBucket') in cloud mode, the
-- in-cluster MinIO backend (from @NAGARE_LOCAL_OBJECT_STORE@) in local mode. The
-- backend is constructed __once__ here from 'mode' ('storeBackendFor') and
-- threaded into the database Job previews and direct volume data commands.
resolveStoreBackend :: Maybe String -> Maybe String -> IO StoreBackend
resolveStoreBackend mctx bucketArg = do
  tp <- activeProfile mctx
  bucket <- resolveBackupBucket mctx bucketArg
  either dieT pure (storeBackendFor tp bucket)
