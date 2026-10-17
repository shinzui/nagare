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
import Nagare.Dsl.Prelude
import Nagare.Inventory.Site.Listing (SiteSelection (..), readSiteListing, renderSiteTable)

runSiteList :: Maybe String -> SiteListOpts -> IO ()
runSiteList mctx options = do
  forM_' (options ^. #contract) $ \version ->
    unless (version == 1) (dieT ("unsupported contract version " <> T.pack (show version) <> "; this nagarectl emits contract 1"))
  target <- activeTarget mctx
  listing <-
    readSiteListing target (SiteSelection (T.pack <$> options ^. #namespace) (options ^. #includePreviews))
      >>= either dieT pure
  let (headValue, sites) = listing
  if options ^. #json || isJust (options ^. #contract)
    then LBC.putStrLn (Aeson.encode (siteList headValue sites))
    else TIO.putStr (renderSiteTable sites)
  where
    forM_' value action = maybe (pure ()) action value
