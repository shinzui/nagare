-- | The Nginx configuration Nagare generates for a static site, from the site
-- JSON its typed config emits (EP-188 M3). The site-access drill builds the
-- example's image exactly as a static release does: this config, the generated
-- Dockerfile, and the site's files.
module Main (main) where

import Data.ByteString qualified as BS
import Nagare.Dsl.Load (decodeStaticSite, renderLoadError)
import Nagare.Dsl.Static.Render (renderNginxConfig)
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure)
import System.IO (stderr)

main :: IO ()
main = do
  site <- BS.getContents
  case decodeStaticSite site of
    Left err -> TIO.hPutStrLn stderr (renderLoadError err) >> exitFailure
    Right loaded -> BS.putStr (renderNginxConfig loaded)
