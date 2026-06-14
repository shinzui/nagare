-- | @nagarectl db delete NAME@ (MasterPlan 9, EP-45): remove a managed database,
-- honoring its 'RetentionPolicy'. Deletes the StatefulSet, then the Service, then
-- the Secret (and the ClickHouse memory ConfigMap), each @--ignore-not-found@ and
-- in dependency order (MasterPlan 7 found namespace-cascade leaves resources
-- stuck). The data PVC is removed only when the policy is @Delete@; @Retain@
-- keeps it and prints how to remove it manually. Guarded by @--yes@: without it
-- (or with @--dry-run@), the deletion plan is printed and nothing is deleted.
module Nagare.Database.Delete
  ( DbDeleteParams (..)
  , runDbDelete
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Database.Discover (DbRow (..), getDatabase)
import Nagare.Dsl.Database (dbSecretName)
import Nagare.Dsl.Database.Render (dbConfigMapName, dbPvcName)
import System.Exit (exitFailure)
import System.IO (stderr)

data DbDeleteParams = DbDeleteParams
  { ddpName :: !Text
  , ddpNamespace :: !Text
  , ddpYes :: !Bool
  , ddpDryRun :: !Bool
  }
  deriving stock (Generic, Show)

runDbDelete :: DbDeleteParams -> IO ()
runDbDelete p = do
  erow <- getDatabase (ddpNamespace p) (ddpName p)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right r -> do
      let ns = ddpNamespace p
          name = ddpName p
          deleteData = drRetention r == "Delete"
          pvc = dbPvcName name
      if not (ddpYes p) || ddpDryRun p
        then do
          TIO.putStr $
            T.unlines
              ( ["Would delete (run again with --yes):"]
                  <> map ("  " <>) (objectsToDelete name)
                  <> [ if deleteData
                        then "Retention is Delete: the data volume " <> pvc <> " is REMOVED."
                        else
                          "Retention is Retain: the data volume " <> pvc <> " is KEPT.\n"
                            <> "  Remove it manually with: kubectl delete pvc "
                            <> pvc
                            <> " -n "
                            <> ns
                     ]
              )
        else do
          mapM_ (deleteObj ns) (objectsToDelete name)
          if deleteData
            then do
              deleteObj ns ("pvc/" <> pvc)
              TIO.putStrLn ("Deleted database " <> name <> " (data volume removed)")
            else do
              TIO.putStrLn
                ( "Retention is Retain: kept pvc "
                    <> pvc
                    <> " (delete manually to reclaim the disk)."
                )
              TIO.putStrLn ("Deleted database " <> name)

-- | The objects deleted in dependency order (workload, then Service, then Secret,
-- then the ClickHouse memory ConfigMap). The data PVC is handled separately by
-- the retention policy.
objectsToDelete :: Text -> [Text]
objectsToDelete name =
  [ "statefulset/" <> name
  , "service/" <> name
  , "secret/" <> dbSecretName name
  , "configmap/" <> dbConfigMapName name
  ]

deleteObj :: Text -> Text -> IO ()
deleteObj ns obj =
  run_ $
    cmd "kubectl"
      & addArgs ["delete", T.unpack obj, "-n", T.unpack ns, "--ignore-not-found"]
