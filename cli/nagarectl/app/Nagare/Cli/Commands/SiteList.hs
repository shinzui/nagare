-- | @nagarectl site list@: the active context's recorded sites (EP-193). The
-- library reads the store; this handler only parses, calls and prints.
module Nagare.Cli.Commands.SiteList
  ( runSiteList
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (SiteListOpts (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Contract.Project (siteList)
import Nagare.Contract.Sink (emitDocument)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Site.Listing (SiteSelection (..), readSiteListing, renderSiteTable)

runSiteList :: Maybe String -> SiteListOpts -> IO ()
runSiteList mctx options = do
  target <- activeTarget mctx
  listing <-
    readSiteListing target (SiteSelection (T.pack <$> options ^. #namespace) (options ^. #includePreviews))
      >>= either dieT pure
  let (headValue, sites) = listing
  -- Under the contract the sink owns stdout; the document goes through it.
  case (options ^. #contract, options ^. #json) of
    (Just _, _) -> emitDocument (siteList headValue sites)
    (Nothing, True) -> LBC.putStrLn (Aeson.encode (siteList headValue sites))
    (Nothing, False) -> TIO.putStr (renderSiteTable sites)
