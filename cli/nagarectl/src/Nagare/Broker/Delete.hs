-- | @nagarectl broker delete NAME@: remove broker workload/service resources.
--
-- The data PVC is retained in v1. That matches the conservative managed-data
-- posture: deleting the broker command must not silently remove topic data.
module Nagare.Broker.Delete
  ( BrokerDeleteParams (..)
  , runBrokerDelete
  )
where

import Cradle
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Broker.Discover (getBroker)
import Nagare.Dsl.Broker.Render (brokerPvcName)
import Nagare.Dsl.Prelude
import System.Exit (exitFailure)
import System.IO (stderr)
import "generic-lens" Data.Generics.Labels ()

data BrokerDeleteParams = BrokerDeleteParams
  { name :: !Text
  , namespace :: !Text
  , yes :: !Bool
  , dryRun :: !Bool
  }
  deriving stock (Generic, Show)

runBrokerDelete :: BrokerDeleteParams -> IO ()
runBrokerDelete params = do
  erow <- getBroker (params ^. #namespace) (params ^. #name)
  case erow of
    Left err -> do
      TIO.hPutStrLn stderr ("nagarectl: " <> err)
      exitFailure
    Right _ -> do
      let ns = params ^. #namespace
          name' = params ^. #name
          pvc = brokerPvcName name'
      if not (params ^. #yes) || params ^. #dryRun
        then
          TIO.putStr $
            T.unlines
              ( [ if params ^. #dryRun
                    then "Would delete (dry run):"
                    else "Would delete (run again with --yes):"
                ]
                  <> map ("  " <>) (objectsToDelete name')
                  <> [ "Data volume is KEPT: " <> pvc
                     , "  Remove it manually with: kubectl delete pvc " <> pvc <> " -n " <> ns
                     ]
              )
        else do
          mapM_ (deleteObj ns) (objectsToDelete name')
          TIO.putStrLn ("Deleted broker " <> name' <> "; kept pvc " <> pvc)

objectsToDelete :: Text -> [Text]
objectsToDelete name =
  [ "statefulset/" <> name
  , "service/" <> name
  ]

deleteObj :: Text -> Text -> IO ()
deleteObj ns obj =
  run_ $
    cmd "kubectl"
      & addArgs ["delete", T.unpack obj, "-n", T.unpack ns, "--ignore-not-found"]
