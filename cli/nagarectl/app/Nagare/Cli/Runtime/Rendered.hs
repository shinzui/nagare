-- | Runtime / Rendered (EP-249). Executable-private CLI boundary: a command's
-- configuration from @-f FILE@ (a config program, run with the provisioned GHC
-- environment) or from @--rendered PATH@ (a rendered document, decoded as
-- data with no GHC and no process), and the @render@ commands.
module Nagare.Cli.Runtime.Rendered
  ( loadApplicationInput
  , loadWorkerInput
  , loadSiteInput
  , runRender
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (RenderTarget (..))
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Load (LoadError (..), RenderedKind (..), SiteConfig (..))
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Prelude
import Nagare.Dsl.Worker (Worker)
import Nagare.Version (BuildVersion (..), currentBuildVersion)
import System.IO (stderr)

renderedBytes :: [RenderedKind] -> FilePath -> IO (Either LoadError (RenderedKind, ByteString))
renderedBytes kinds path = do
  bytes <- try (BS.readFile path) :: IO (Either IOException ByteString)
  pure (either (const (Left (RenderedRefused "the rendered document cannot be read"))) (Load.decodeRendered (currentBuildVersion ^. #version) kinds) bytes)

loadApplicationInput :: Maybe FilePath -> Maybe FilePath -> FilePath -> IO (Either LoadError Application)
loadApplicationInput rendered ghc file = case rendered of
  Just path -> (>>= Load.decodeApplication . snd) <$> renderedBytes [RenderedApplication] path
  Nothing -> provisionGhcEnv ghc >> Load.loadApplication file

loadWorkerInput :: Maybe FilePath -> Maybe FilePath -> FilePath -> IO (Either LoadError Worker)
loadWorkerInput rendered ghc file = case rendered of
  Just path -> (>>= Load.decodeWorker . snd) <$> renderedBytes [RenderedWorker] path
  Nothing -> provisionGhcEnv ghc >> Load.loadWorker file

loadSiteInput :: Maybe FilePath -> Maybe FilePath -> FilePath -> IO (Either LoadError SiteConfig)
loadSiteInput rendered ghc file = case rendered of
  Just path -> (>>= Load.decodeSite . snd) <$> renderedBytes [RenderedStaticSite, RenderedServerSite] path
  Nothing -> provisionGhcEnv ghc >> Load.loadSite file

-- | Run the program once, decode it with the deploy command's own decoder,
-- and print or write its rendered document. Needs no context or store.
runRender :: RenderTarget -> FilePath -> Maybe FilePath -> Maybe FilePath -> IO ()
runRender target file ghc out = do
  provisionGhcEnv ghc
  stdout' <- Load.runConfigWith Load.defaultConfigTimeout file >>= either (dieT . Load.renderLoadError) pure
  kind <- either (dieT . Load.renderLoadError) pure $ case target of
    RenderApplication -> RenderedApplication <$ Load.decodeApplication stdout'
    RenderWorker -> RenderedWorker <$ Load.decodeWorker stdout'
    RenderSite ->
      Load.decodeSite stdout' <&> \case
        SiteStatic _ -> RenderedStaticSite
        SiteServer _ -> RenderedServerSite
  document <- either (dieT . Load.renderLoadError) pure (Load.renderedDocument (currentBuildVersion ^. #version) kind stdout')
  case out of
    Nothing -> BS.putStr document
    Just path -> BS.writeFile path document >> TIO.hPutStrLn stderr ("rendered " <> Load.renderedDocumentName kind <> " to " <> T.pack path)
