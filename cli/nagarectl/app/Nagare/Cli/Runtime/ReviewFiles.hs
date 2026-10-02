-- | Runtime / ReviewFiles. Executable-private CLI boundary.
module Nagare.Cli.Runtime.ReviewFiles
  ( cleanupPlanStaging
  )
where

import Nagare.Dsl.Prelude
import System.Directory
  ( doesDirectoryExist
  , removeDirectoryRecursive
  )

cleanupPlanStaging :: FilePath -> Text -> IO (Either Text a)
cleanupPlanStaging staging message = do
  present <- doesDirectoryExist staging
  when present (removeDirectoryRecursive staging)
  pure (Left message)
