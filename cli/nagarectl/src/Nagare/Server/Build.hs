-- | Produce the runtime output of a 'ServerSite' (EP-18).
--
-- Parallel to 'Nagare.Static.Build': run the build command in the project root
-- (unless skipped) through a shell, then validate that every directory in the
-- runtime's @outputDirs@ exists. Each validated directory is recorded as a
-- (relative, absolute) pair so the image-context step can recreate the relative
-- layout under @/app@ (e.g. @.output@ → @app/.output@) that the start command
-- expects.
module Nagare.Server.Build
  ( PreparedServerOutput (..)
  , prepareServerOutput
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Cradle
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (filePathText)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- | The validated runtime output: each entry is @(relativePath, absolutePath)@
-- for a directory to copy into the image.
newtype PreparedServerOutput = PreparedServerOutput
  { outputs :: NonEmpty (FilePath, FilePath)
  }
  deriving stock (Eq, Show)

-- | Run the server build (unless skipped) and resolve/validate every output
-- directory. @prepareServerOutput skipBuild site projectRoot@ runs in
-- @projectRoot@.
prepareServerOutput ::
  Bool -> ServerSite -> FilePath -> IO (Either Text PreparedServerOutput)
prepareServerOutput skipBuild site projectRoot = do
  rootExists <- doesDirectoryExist projectRoot
  if not rootExists
    then pure (Left ("project root does not exist: " <> T.pack projectRoot))
    else do
      buildResult <- runBuild
      case buildResult of
        Left err -> pure (Left err)
        Right () -> do
          resolved <- mapM resolveDir (NE.toList (site ^. #build . #outputDirs))
          pure (PreparedServerOutput . NE.fromList <$> sequence resolved)
  where
    runBuild
      | skipBuild = pure (Right ())
      | otherwise = do
          let command = site ^. #build . #command
          code <-
            run $
              cmd "sh"
                & addArgs ["-c", T.unpack command]
                & setWorkingDir projectRoot
          pure $ case code of
            ExitSuccess -> Right ()
            ExitFailure n -> Left ("server build command failed (exit " <> tshow n <> "): " <> command)

    resolveDir fp = do
      let rel = T.unpack (filePathText fp)
      absPath <- makeAbsolute (projectRoot </> rel)
      exists <- doesDirectoryExist absPath
      pure $
        if exists
          then Right (rel, absPath)
          else Left ("server output directory not found after build: " <> T.pack absPath)

    tshow :: Int -> Text
    tshow = T.pack . show
