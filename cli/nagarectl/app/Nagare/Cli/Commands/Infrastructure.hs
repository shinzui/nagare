-- | Commands / Infrastructure. Executable-private CLI boundary.
module Nagare.Cli.Commands.Infrastructure
  ( runCleanup
  , runDoctor
  , runInfraApply
  , runInfraDestroy
  , runInfraGuard
  , runInfraPreview
  , runServerStatus
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Workflow
  ( runInventoryApply
  , runInventoryPlan
  )
import Nagare.Cli.Options
  ( DoctorOpts (..)
  , InfraApplyOpts (..)
  , InfraPreviewOpts (..)
  , ServerStatusOpts (..)
  )
import Nagare.Cli.Platform.InfrastructureReview
  ( applyReviewedPlan
  , instanceReplacementGuard
  , prepareInfraMutation
  , saveReviewedPlan
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Cli.Runtime.PlatformStatus (gatherPlatformStatus)
import Nagare.Cli.Runtime.Process (runExternal)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolvePlatformWorkspace
  )
import Nagare.Dsl.Prelude
import Nagare.Ops.Cleanup
  ( CleanupOpts
  , executeCleanup
  , formatCleanupReport
  )
import Nagare.Ops.Doctor
  ( doctorExitOk
  , formatDoctor
  , gradeChecksAt
  )
import Nagare.Ops.Probe (renderInventory)
import Nagare.Ops.Status (gatherInventory, inventoryOptsFor)
import Nagare.Platform.Status (platformProbe)
import Nagare.Target (Mode (Cloud, Local), contextNameText)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  , exitFailure
  , exitWith
  )
import System.FilePath ((</>))
import System.IO (stderr)

runServerStatus :: Maybe String -> ServerStatusOpts -> IO ()
runServerStatus mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  let invOpts = inventoryOptsFor (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp & #skipVm .~ o ^. #skipVm
  probes <- gatherInventory tp invOpts
  (_, versionStatus) <- gatherPlatformStatus mctx
  TIO.putStr (renderInventory (probes <> [platformProbe versionStatus]))

-- | @doctor@: gather EP-38's probes, re-grade them into a remediation checklist,
-- print it, and exit non-zero iff any check FAILs. Read-only and advisory —
-- every remediation is printed text the operator runs themselves
-- ('gatherInventory' degrades unreachable sources to @UNKNOWN@, so the report is
-- always printed; only the exit code varies).
runDoctor :: Maybe String -> DoctorOpts -> IO ()
runDoctor mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  let invOpts = inventoryOptsFor (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp & #skipVm .~ o ^. #skipVm
  probes <- gatherInventory tp invOpts
  (_, versionStatus) <- gatherPlatformStatus mctx
  let checks = gradeChecksAt (workspace ^. #root) (workspace ^. #pulumiDir) (workspace ^. #scriptsDir </> "iap-ssh.sh") tp (probes <> [platformProbe versionStatus])
  TIO.putStr (formatDoctor checks)
  unless (doctorExitOk checks) (exitWith (ExitFailure 1))

runInfraGuard :: Maybe String -> Bool -> IO ()
runInfraGuard mctx allowReplacementFlag = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  case tp ^. #mode of
    Local -> TIO.putStrLn "infra guard: local mode has no GCE instance to protect"
    Cloud -> do
      ctx <- fromMaybe "default" <$> lookupEnv "NAGARE_PULUMI_STACK"
      envAllowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
      result <- instanceReplacementGuard tp workspace ctx (allowReplacementFlag || envAllowed)
      case result of
        Right message -> TIO.putStr message
        Left message -> TIO.hPutStr stderr (ensureNewline message) >> exitFailure
  where
    ensureNewline t = if "\n" `T.isSuffixOf` t then t else t <> "\n"

runInfraPreview :: Maybe String -> InfraPreviewOpts -> IO ()
runInfraPreview mctx options = case options ^. #inventory of
  Just candidate -> do
    when (options ^. #allowReplacement) (dieT "--allow-replacement belongs to the reviewed lifecycle decision; it cannot be attached to an inventory preview")
    runInventoryPlan mctx candidate [] (options ^. #savePlan)
  Nothing -> do
    (active, workspace) <- prepareInfraMutation mctx
    result <- saveReviewedPlan active workspace (options ^. #savePlan) (options ^. #allowReplacement)
    either dieT TIO.putStr result

runInfraApply :: Maybe String -> InfraApplyOpts -> IO ()
runInfraApply mctx options = do
  unless (options ^. #yes) $
    dieT "refusing to apply a reviewed infrastructure plan without --yes"
  inventoryReview <- doesFileExist (options ^. #plan </> "review.sha256")
  if inventoryReview
    then do
      when (options ^. #allowReplacement) (dieT "--allow-replacement belongs to the reviewed lifecycle decision and cannot alter an inventory review")
      runInventoryApply mctx (options ^. #plan) True
    else do
      selected <- activeTarget mctx
      guardLegacyMutationInventory "infra apply" selected
      (active, workspace) <- prepareInfraMutation mctx
      result <- applyReviewedPlan active workspace (options ^. #plan) (options ^. #allowReplacement)
      either dieT TIO.putStr result

runInfraDestroy :: Maybe String -> Bool -> IO ()
runInfraDestroy mctx yes = do
  unless yes $
    dieT "refusing to destroy the selected context's infrastructure without --yes"
  selected <- activeTarget mctx
  guardLegacyMutationInventory "infra destroy" selected
  (active, workspace) <- prepareInfraMutation mctx
  let stack = T.unpack (contextNameText (active ^. #contextName))
  result <- runExternal [ExitSuccess] "pulumi" ["-C", workspace ^. #pulumiDir, "destroy", "--stack", stack, "--yes", "--non-interactive"] ""
  either dieT TIO.putStr result

-- | @cleanup@: gather (and, under @--confirm@, perform) reclamation across
-- images/previews/releases, then print the report. Dry-run by default.
runCleanup :: Maybe String -> CleanupOpts -> IO ()
runCleanup mctx o = do
  active <- activeTarget mctx
  when (o ^. #confirm) (guardLegacyMutationInventory "cleanup --confirm" active)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  report <- executeCleanup (workspace ^. #scriptsDir </> "iap-ssh.sh") (active ^. #profile . #instanceName) o
  TIO.putStr (formatCleanupReport report)
