-- | Inventory / CloudCatalog. Executable-private CLI boundary.
module Nagare.Cli.Inventory.CloudCatalog
  ( loadCloudCatalog
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Cloud qualified as InventoryCloud
import Nagare.Platform.Workspace (PlatformWorkspace)
import System.FilePath ((</>))

loadCloudCatalog :: PlatformWorkspace -> IO (ByteString, InventoryCloud.CloudCatalog)
loadCloudCatalog workspace = do
  let catalogPath = workspace ^. #pulumiDir </> "resource-catalog.json"
  bytes <-
    try (BS.readFile catalogPath) >>= \case
      Left (err :: IOException) ->
        dieT
          ("could not read reviewed cloud resource catalog: " <> T.pack (show err))
      Right contents -> pure contents
  catalog <- either dieT pure (InventoryCloud.decodeCloudCatalog bytes)
  pure (bytes, catalog)
