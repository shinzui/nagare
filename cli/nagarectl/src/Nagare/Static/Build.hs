-- | Produce the directory of static files a 'StaticSite' will serve.
--
-- For a @NoBuild@ site the files already exist; this module only resolves and
-- validates the output directory. For a @BuildCommand@ site it runs the build
-- command (e.g. @npm run build@) in the project root through a shell, then
-- validates that the configured output directory was produced. Every failure —
-- a missing project root, a non-zero build, a missing output directory — is
-- reported as a 'StaticBuildError' the caller can render to one line.
module Nagare.Static.Build
  ( PreparedStaticOutput (..)
  , StaticBuildError (..)
  , renderStaticBuildError
  , prepareStaticOutput
  ) where

import Nagare.Dsl.Prelude

import Data.Generics.Labels ()

import Cradle
import Data.Text qualified as T
import Nagare.Dsl.Static.Types
  ( StaticSite
  , filePathText
  , staticBuildCommand
  , staticOutputDir
  )
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- | The validated, absolute path to the directory whose contents get packaged
-- into the Nginx image.
newtype PreparedStaticOutput = PreparedStaticOutput
  { outputDirectory :: FilePath
  }
  deriving stock (Eq, Show)

-- | Everything that can go wrong while preparing static output.
data StaticBuildError
  = -- | the project root passed on the command line does not exist
    ProjectRootMissing !FilePath
  | -- | the build command exited non-zero (command, exit code)
    BuildCommandFailed !Text !Int
  | -- | the build ran (or was skipped) but the output directory is absent
    -- (resolved path)
    OutputDirectoryMissing !FilePath
  deriving stock (Eq, Show)

-- | Render a 'StaticBuildError' as a single line for stderr.
renderStaticBuildError :: StaticBuildError -> Text
renderStaticBuildError = \case
  ProjectRootMissing p ->
    "project root does not exist: " <> T.pack p
  BuildCommandFailed c code ->
    "static build command failed (exit " <> T.pack (show code) <> "): " <> c
  OutputDirectoryMissing p ->
    "static output directory not found after build: " <> T.pack p

-- | Run the site's build (unless skipped) and return its validated output
-- directory.
--
-- @prepareStaticOutput skipBuild site projectRoot@ runs in @projectRoot@. When
-- @skipBuild@ is 'True' the build command is not run (used for fixtures whose
-- output already exists); the output directory is still validated.
prepareStaticOutput ::
  Bool -> StaticSite -> FilePath -> IO (Either StaticBuildError PreparedStaticOutput)
prepareStaticOutput skipBuild site projectRoot = do
  rootExists <- doesDirectoryExist projectRoot
  if not rootExists
    then pure (Left (ProjectRootMissing projectRoot))
    else do
      buildResult <- runBuild
      case buildResult of
        Left err -> pure (Left err)
        Right () -> do
          let outRel = T.unpack (filePathText (staticOutputDir (site ^. #build)))
          outAbs <- makeAbsolute (projectRoot </> outRel)
          outExists <- doesDirectoryExist outAbs
          pure $
            if outExists
              then Right (PreparedStaticOutput {outputDirectory = outAbs})
              else Left (OutputDirectoryMissing outAbs)
  where
    runBuild :: IO (Either StaticBuildError ())
    runBuild = case (skipBuild, staticBuildCommand (site ^. #build)) of
      (True, _) -> pure (Right ())
      (False, Nothing) -> pure (Right ())
      (False, Just command) -> do
        -- cradle never wraps in a shell, so run the build string through `sh -c`
        -- in the project root. Capture the ExitCode rather than throwing so the
        -- failure renders as a clean one-liner.
        code <-
          run $
            cmd "sh"
              & addArgs ["-c", T.unpack command]
              & setWorkingDir projectRoot
        pure $ case code of
          ExitSuccess -> Right ()
          ExitFailure n -> Left (BuildCommandFailed command n)
