-- | Runtime / Pulumi. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Pulumi
  ( bootstrapGcsIfNeeded
  , ensurePulumiForActiveContext
  , ensurePulumiForContext
  , ensurePulumiForContextWithDependencies
  , ensurePulumiForContextWithInstallNotice
  , ensurePulumiInWorkspace
  , ensurePulumiInWorkspaceWithDependencies
  , pulumiQuiet
  , selectReviewedPulumiForContext
  )
where

import Control.Exception (IOException, catch, try)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target
  ( activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Ops.PulumiBackend (bootstrapPulumiStateBucket)
import Nagare.Platform.Paths (PlatformRootSource (SourceRoot))
import Nagare.Platform.StackConfig (linkContextStackConfig)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Target
  ( ContextName
  , PulumiBackendKind (PulumiBackendGcs, PulumiBackendLocal)
  , TargetProfile
  , contextNameText
  , nagareStateDir
  , pulumiEnvFor
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process
  ( CreateProcess (cwd)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  )

ensurePulumiForContext :: ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContext = ensurePulumiForContextWithInstallNotice True

ensurePulumiForContextWithInstallNotice :: Bool -> ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContextWithInstallNotice announceInstall =
  ensurePulumiForContextWithPolicy announceInstall True

selectReviewedPulumiForContext :: ContextName -> TargetProfile -> IO PlatformWorkspace
selectReviewedPulumiForContext = ensurePulumiForContextWithPolicy True False

ensurePulumiForContextWithPolicy :: Bool -> Bool -> ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContextWithPolicy = ensurePulumiForContextWithDependencies True

ensurePulumiForContextWithDependencies :: Bool -> Bool -> Bool -> ContextName -> TargetProfile -> IO PlatformWorkspace
ensurePulumiForContextWithDependencies installDependencies announceInstall createMissing name tp = do
  (paths, workspace) <- resolvePlatformWorkspace name
  -- EP-121: a source checkout's own `just` recipes run Pulumi in its infra/pulumi,
  -- so it must read the same context-owned stack config as the workspace.
  when (paths ^. #rootSource == SourceRoot) $
    linkContextStackConfig name (paths ^. #pulumiDir) >>= either dieT (const (pure ()))
  ensurePulumiInWorkspaceWithDependencies installDependencies announceInstall createMissing name tp workspace
  pure workspace

ensurePulumiInWorkspace :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspace = ensurePulumiInWorkspaceWithInstallNotice True

ensurePulumiInWorkspaceWithInstallNotice :: Bool -> ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspaceWithInstallNotice announceInstall =
  ensurePulumiInWorkspaceWithPolicy announceInstall True

ensurePulumiInWorkspaceWithPolicy :: Bool -> Bool -> ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspaceWithPolicy = ensurePulumiInWorkspaceWithDependencies True

ensurePulumiInWorkspaceWithDependencies :: Bool -> Bool -> Bool -> ContextName -> TargetProfile -> PlatformWorkspace -> IO ()
ensurePulumiInWorkspaceWithDependencies installDependencies announceInstall createMissing name tp workspace = do
  stateRoot <- nagareStateDir
  let penv = pulumiEnvFor stateRoot (contextNameText name) tp
      stack = penv ^. #stack
      pulumiDir = workspace ^. #pulumiDir
  -- EP-121: payload workspaces exclude every Pulumi.<stack>.yaml, so link the
  -- context-owned stack config in before Pulumi reads or writes it.
  linkContextStackConfig name pulumiDir >>= either dieT (const (pure ()))
  when installDependencies (ensurePulumiProgramDependencies announceInstall pulumiDir)
  createDirectoryIfMissing True (penv ^. #home)
  -- Only a local (@file://@) backend has a state directory to create; a GCS
  -- backend URL is @gs://…@ and must never be treated as a local path.
  case penv ^. #kind of
    PulumiBackendLocal ->
      createDirectoryIfMissing True (T.unpack (T.drop (T.length ("file://" :: Text)) (penv ^. #backendUrl)))
    PulumiBackendGcs -> pure ()
  -- EP-116: the passphrase file may hold the operator's real stack passphrase,
  -- so create it only when absent and never truncate it.
  let passphraseFile = penv ^. #home </> "passphrase"
  passphraseExists <- doesFileExist passphraseFile
  unless passphraseExists (writeFile passphraseFile "")
  setEnv "PULUMI_HOME" (penv ^. #home)
  setEnv "PULUMI_BACKEND_URL" (T.unpack (penv ^. #backendUrl))
  -- Pulumi prefers PULUMI_CONFIG_PASSPHRASE over the file whenever it is set,
  -- even to "", so drop an empty one and let the file decide.
  inheritedPassphrase <- lookupEnv "PULUMI_CONFIG_PASSPHRASE"
  when (maybe True null inheritedPassphrase) (unsetEnv "PULUMI_CONFIG_PASSPHRASE")
  setEnv "PULUMI_CONFIG_PASSPHRASE_FILE" passphraseFile
  setEnv "NAGARE_PULUMI_STACK" (T.unpack stack)
  selected <- pulumiQuiet ["-C", pulumiDir, "stack", "select", T.unpack stack]
  case selected of
    ExitSuccess -> pure ()
    ExitFailure _
      | not createMissing ->
          dieT "reviewed Pulumi stack is absent or unavailable; plan and apply the cloud foundation stage"
    ExitFailure _ -> do
      _ <- pulumiQuiet ["-C", pulumiDir, "stack", "init", T.unpack stack]
      void (pulumiQuiet ["-C", pulumiDir, "stack", "select", T.unpack stack])

-- | Bootstrap the GCS Pulumi state bucket for a context that opts into it. A
-- local/local-mode context is a no-op. A bootstrap failure is FATAL (EP-113): a
-- partially-applied bootstrap that lets @init@ report success is exactly the state
-- that hides a foreign-bucket refusal from the operator. The blast radius is small,
-- because the bootstrap is a no-op for every context whose Pulumi backend is @local@
-- (the default) — only a context that explicitly opted into
-- @NAGARE_PULUMI_BACKEND=gcs@ can reach the failure at all. Recovery is to fix the
-- cause the message names and re-run, both call sites being idempotent.
bootstrapGcsIfNeeded :: Bool -> Text -> TargetProfile -> Maybe Text -> IO ()
bootstrapGcsIfNeeded dryRun ctx tp mMember =
  bootstrapPulumiStateBucket dryRun ctx tp mMember
    >>= either (\msg -> dieT ("GCS state-bucket bootstrap failed: " <> msg)) pure

-- | EP-121: payload workspaces exclude node_modules, so a clone-free Pulumi run
-- would fail with "the Pulumi SDK has not been installed". Install the program's
-- locked dependencies once per workspace, before any Pulumi command needs them.
ensurePulumiProgramDependencies :: Bool -> FilePath -> IO ()
ensurePulumiProgramDependencies announceInstall pulumiDir = do
  installed <- doesFileExist (pulumiDir </> "node_modules" </> "@pulumi" </> "pulumi" </> "package.json")
  locked <- doesFileExist (pulumiDir </> "package-lock.json")
  when (locked && not installed) $ do
    when announceInstall $
      TIO.hPutStrLn stderr ("Installing the Pulumi program's locked Node dependencies in " <> T.pack pulumiDir <> " ...")
    result <-
      try (readCreateProcessWithExitCode ((proc "npm" ["ci", "--no-audit", "--no-fund"]) {cwd = Just pulumiDir}) "")
    case result of
      Left (err :: IOException) ->
        dieT ("could not run `npm ci` for the Pulumi program (Node.js and npm are required): " <> T.pack (show err))
      Right (ExitSuccess, _, _) -> pure ()
      Right (ExitFailure code, _, err) ->
        dieT ("`npm ci` failed in " <> T.pack pulumiDir <> " (exit " <> T.pack (show code) <> "):\n" <> T.strip (T.pack err))

pulumiQuiet :: [String] -> IO ExitCode
pulumiQuiet args =
  runIt `catch` handleMissing
  where
    runIt = do
      (code, _, _) <- readProcessWithExitCode "pulumi" args ""
      pure code
    handleMissing :: IOException -> IO ExitCode
    handleMissing _ = pure (ExitFailure 127)

ensurePulumiForActiveContext :: Maybe String -> IO (ContextName, PlatformWorkspace)
ensurePulumiForActiveContext mctx = do
  active <- activeTarget mctx
  workspace <- ensurePulumiForContext (active ^. #contextName) (active ^. #profile)
  pure (active ^. #contextName, workspace)
