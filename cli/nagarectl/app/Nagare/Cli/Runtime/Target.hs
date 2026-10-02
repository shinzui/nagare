-- | Runtime / Target. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveBaseDomain
  , resolveDomainsBaseAt
  , resolvePlatformWorkspace
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.Paths
  ( PlatformPaths
  , renderPlatformPathError
  , resolvePlatformPaths
  )
import Nagare.Platform.Workspace
  ( PlatformWorkspace
  , preparePlatformWorkspace
  , renderWorkspaceError
  )
import Nagare.Target
  ( ActiveTarget
  , ContextName
  , TargetProfile
  , nagareStateDir
  , resolveActiveContext
  , resolveActiveTarget
  )
import System.Environment (setEnv)

-- | @server status@: gather the platform inventory and print the aligned
-- report. Read-only and always exits 0 — graceful degradation is the probes'
-- job, so a probe whose source is unreachable shows as @UNKNOWN@/@WARN@ rather
-- than aborting the command (script-friendly exit codes belong to EP-39's
-- @doctor@).
activeProfile :: Maybe String -> IO TargetProfile
activeProfile = resolveActiveContext . fmap T.pack

activeTarget :: Maybe String -> IO ActiveTarget
activeTarget = resolveActiveTarget . fmap T.pack

resolvePlatformWorkspace :: ContextName -> IO (PlatformPaths, PlatformWorkspace)
resolvePlatformWorkspace contextName = do
  pathsResult <- resolvePlatformPaths Nothing
  paths <- either (dieT . renderPlatformPathError) pure pathsResult
  stateRoot <- nagareStateDir
  workspaceResult <- preparePlatformWorkspace stateRoot contextName paths
  workspace <- either (dieT . renderWorkspaceError) pure workspaceResult
  setEnv "NAGARE_WORKSPACE_ROOT" (workspace ^. #root)
  pure (paths, workspace)

resolveDomainsBaseAt :: Maybe String -> PlatformWorkspace -> Maybe String -> IO Text
resolveDomainsBaseAt _ _ (Just b) = pure (T.pack b)
resolveDomainsBaseAt mctx workspace Nothing = do
  mp <- stackOutput (workspace ^. #pulumiDir) "baseDomain"
  case mp of
    Just d | not (T.null d) -> pure d
    _ -> resolveBaseDomain mctx Nothing

-- | Resolve the apps base domain: an explicit @--base-domain@ flag wins;
-- otherwise the resolved target profile's base domain (EP-62; honors
-- @NAGARE_BASE_DOMAIN@, default @"apps.example.com"@).
resolveBaseDomain :: Maybe String -> Maybe String -> IO Text
resolveBaseDomain _ (Just bd) = pure (T.pack bd)
resolveBaseDomain mctx Nothing = (^. #baseDomain) <$> activeProfile mctx
