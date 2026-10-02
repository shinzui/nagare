-- | Runtime / Config. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Config
  ( provisionGhcEnv
  )
where

import Nagare.Dsl.Prelude
import Nagare.GhcEnv (resolveProjectGhcEnv)
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv, setEnv)

-- | Ensure the loader's child @runghc@ can resolve the @nagare-dsl@ package by
-- exporting a GHC package-environment file as @GHC_ENVIRONMENT@. Precedence
-- (EP-6 M1): the @--ghc-env@ flag > the @NAGARE_GHC_ENVIRONMENT@ env var >
-- the project's auto-discovered @.ghc.environment.*@ file. When none is found,
-- do nothing (the loader then fails with its existing, clear compile error).
provisionGhcEnv :: Maybe FilePath -> IO ()
provisionGhcEnv mflag = do
  menv <- lookupEnv "NAGARE_GHC_ENVIRONMENT"
  case mflag <|> menv of
    Just p -> do
      abs' <- makeAbsolute p
      setEnv "GHC_ENVIRONMENT" abs'
    Nothing -> do
      mfile <- resolveProjectGhcEnv
      case mfile of
        Just f -> setEnv "GHC_ENVIRONMENT" f -- already absolute
        Nothing -> pure ()
