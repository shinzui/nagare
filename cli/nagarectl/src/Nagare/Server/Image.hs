{-# LANGUAGE PackageImports #-}

-- | Assemble the temporary Docker build context for a server-site release (EP-18).
--
-- Parallel to 'Nagare.Static.Image': write the generated Node Dockerfile and an
-- @app/@ directory holding the copied runtime outputs, then hand the context
-- path to a continuation (typically 'Nagare.Image.buildImage'). The relative
-- layout is preserved (e.g. @.output@ → @app/.output@) so the default start
-- command @node .output/server/index.mjs@ resolves under @WORKDIR /app@.
module Nagare.Server.Image
  ( withServerImageContext
  ) where

import Cradle
import Data.List.NonEmpty qualified as NE
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Server.Render (renderServerDockerfile)
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Server.Build (PreparedServerOutput (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)

-- | Build the temp image context for @site@ from its @prepared@ outputs, then
-- run @action@ with the context directory path. Cleaned up on return or throw.
withServerImageContext ::
  ServerSite -> PreparedServerOutput -> (FilePath -> IO a) -> IO a
withServerImageContext site prepared action =
  withSystemTempDirectory "nagare-server-ctx" $ \ctx -> do
    let appDir = ctx </> "app"
    createDirectoryIfMissing True appDir
    mapM_ (copyOutput appDir) (NE.toList (outputs prepared))
    TIO.writeFile (ctx </> "Dockerfile") (renderServerDockerfile site)
    action ctx
  where
    -- copy <abs> to app/<rel>, recreating any parent dirs of <rel>.
    copyOutput appDir (rel, absPath) = do
      let dest = appDir </> rel
      createDirectoryIfMissing True (takeDirectory dest)
      run_ $ cmd "cp" & addArgs ["-R", absPath, dest]
