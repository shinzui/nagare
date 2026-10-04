-- | Platform / Upgrade. Executable-private CLI boundary.
module Nagare.Cli.Platform.Upgrade
  ( runPlatformUpgrade
  , runPlatformUpgradeRecoverPulumi
  , runPlatformUpgradeRollback
  , runPlatformUpgradeStatus
  )
where

import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Char (isAlphaNum)
import Data.Generics.Labels ()
import Data.List (find, sort)
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Options (UpgradeOpts (..))
import Nagare.Cli.Platform.InfrastructureReview
  ( applyVerifiedReviewedPlan
  , saveReviewedPlan
  , verifyLocalReviewedPlanBundle
  , verifyReviewedPlanBundle
  , verifyReviewedPlanBundleEvidence
  )
import Nagare.Cli.Platform.KubernetesReview
  ( applyClusterMarker
  , applyReviewedKubernetesPlan
  , saveReviewedKubernetesPlan
  )
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error
  ( dieT
  , printPreflightWarnings
  , renderVersionError
  )
import Nagare.Cli.Runtime.Guards (guardLegacyMutationInventory)
import Nagare.Cli.Runtime.Process
  ( currentTimestamp
  , runExternal
  , withEnvironment
  , withEnvironmentValues
  )
import Nagare.Cli.Runtime.ProjectGuard
  ( observeAdcForProject
  , projectGuardInputsFor
  )
import Nagare.Cli.Runtime.Pulumi (ensurePulumiInWorkspace)
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc (validateAdc)
import Nagare.Host.Config
  ( commitStagedHostFlake
  , hostConfigDir
  , hostSwitchEnvironment
  , hostSwitchIdentity
  , readStagedHostName
  , stageHostFlake
  )
import Nagare.Infra.Plan
  ( CurrentInfraIdentity
  , SavedPlanMetadata
  )
import Nagare.Ops.ContextGuard
  ( projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Ops.Probe (captureTool)
import Nagare.Platform.Paths
  ( PlatformPaths
  , PlatformRootSource (ExplicitRoot)
  , renderPlatformPathError
  , resolvePlatformPaths
  , validatePlatformRoot
  )
import Nagare.Platform.PulumiReceipt
  ( PulumiApplyReceipt (..)
  , PulumiReceiptState (..)
  , PulumiRecoveryOutcome (..)
  , pulumiReceiptPath
  , readVerifiedPulumiReceipt
  , renderPulumiReceiptEvidence
  , writeRecoveryReceipt
  , writeResultReceipt
  , writeStartedReceipt
  )
import Nagare.Platform.Status
  ( parseClusterIdentity
  , parseHostIdentity
  )
import Nagare.Platform.Upgrade
  ( PhaseState (..)
  , ResumeDecision (..)
  , TransactionState (..)
  , UpgradeOps (..)
  , UpgradePhase (..)
  , UpgradeTransaction (..)
  , UpgradeTransactionView (..)
  , applyUpgrade
  , inspectUpgradeTransaction
  , newUpgradeTransaction
  , phaseToken
  , planUpgrade
  , readUpgradeTransaction
  , recordUpgradePhase
  , renderUpgradeTransaction
  , writeUpgradeTransaction
  )
import Nagare.Platform.Workspace
  ( PayloadManifest
  , PlatformWorkspace (..)
  , preparePlatformWorkspace
  , readPayloadManifest
  , renderWorkspaceError
  )
import Nagare.Target
  ( ActiveTarget
  , ContextName
  , Mode (Cloud, Local)
  , contextNameText
  , nagareStateDir
  , readContextProfile
  , writeContextPlatformVersion
  )
import Nagare.Version
  ( BuildVersion (BuildVersion)
  , parsePlatformVersion
  , renderPlatformVersion
  )
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath
  ( dropExtension
  , takeDirectory
  , takeExtension
  , (</>)
  )
import System.Process (readProcessWithExitCode)

upgradeTransactionsDir :: ContextName -> IO FilePath
upgradeTransactionsDir context = do
  stateRoot <- nagareStateDir
  pure (stateRoot </> T.unpack (contextNameText context) </> "upgrades")

upgradeTransactionPath :: ContextName -> Text -> IO FilePath
upgradeTransactionPath context txId = (</> T.unpack txId <> ".json") <$> upgradeTransactionsDir context

latestUpgradeTransactionId :: ContextName -> IO (Maybe Text)
latestUpgradeTransactionId context = do
  directory <- upgradeTransactionsDir context
  exists <- doesDirectoryExist directory
  if not exists
    then pure Nothing
    else do
      entries <- listDirectory directory
      let ids = sort [T.pack (dropExtension entry) | entry <- entries, takeExtension entry == ".json"]
      pure (case reverse ids of [] -> Nothing; latest : _ -> Just latest)

loadUpgradeTransaction :: ContextName -> Maybe String -> IO (FilePath, UpgradeTransaction)
loadUpgradeTransaction context requested = do
  txId <- case requested of
    Just requestedId -> pure (T.pack requestedId)
    Nothing -> latestUpgradeTransactionId context >>= maybe (dieT "no upgrade transaction exists for this context") pure
  path <- upgradeTransactionPath context txId
  tx <- readUpgradeTransaction path >>= either dieT pure
  when (tx ^. #context /= contextNameText context) $
    dieT ("upgrade transaction belongs to context '" <> tx ^. #context <> "', not '" <> contextNameText context <> "'")
  pure (path, tx)

runPlatformUpgradeStatus :: Maybe String -> Maybe String -> Bool -> IO ()
runPlatformUpgradeStatus mctx requested asJson = do
  active <- activeTarget mctx
  let context = active ^. #contextName
  txId <- case requested of
    Just requestedId -> pure (T.pack requestedId)
    Nothing -> latestUpgradeTransactionId context >>= maybe (dieT "no upgrade transaction exists for this context") pure
  path <- upgradeTransactionPath context txId
  inspected <- inspectUpgradeTransaction path >>= either dieT pure
  case inspected of
    SupportedUpgrade tx -> do
      when (tx ^. #context /= contextNameText context) $
        dieT ("upgrade transaction belongs to context '" <> tx ^. #context <> "', not '" <> contextNameText context <> "'")
      printUpgradeTransaction asJson tx
    UnsupportedUpgrade version observedId observedContext target -> do
      when (observedContext /= contextNameText context || observedId /= txId) $
        dieT "unsupported upgrade transaction identity does not match the requested context and ID"
      if asJson
        then
          LBC.putStrLn
            ( Aeson.encode
                ( Aeson.object
                    [ "id" Aeson..= observedId
                    , "context" Aeson..= observedContext
                    , "schemaVersion" Aeson..= version
                    , "targetVersion" Aeson..= target
                    , "state" Aeson..= ("unsupported-schema" :: Text)
                    ]
                )
            )
        else
          TIO.putStrLn
            ( "Upgrade "
                <> observedId
                <> " ("
                <> observedContext
                <> ") uses unsupported schema "
                <> T.pack (show version)
                <> "; inspect with a newer operator payload before mutation"
            )

runPlatformUpgradeRollback :: Maybe String -> String -> Bool -> Bool -> IO ()
runPlatformUpgradeRollback mctx requested yes asJson = do
  active <- activeTarget mctx
  guardLegacyMutationInventory "platform upgrade rollback" active
  (_, original) <- loadUpgradeTransaction (active ^. #contextName) (Just requested)
  unless yes (dieT "refusing to roll back a release selection without --yes")
  unless (original ^. #state == Completed) (dieT "only a completed upgrade transaction can be rolled back")
  unless (original ^. #rollbackSupported) $
    dieT "release metadata does not declare this rollback direction supported; Nagare will not claim to reverse data or Pulumi schema migrations automatically"
  oldVersion <- maybe (dieT "the completed transaction began from a legacy context and has no previous release to select") pure (original ^. #previousVersion)
  oldWorkspace <- findRetainedWorkspace (active ^. #contextName) oldVersion
  runPlatformUpgrade
    mctx
    UpgradeOpts
      { to = Just (T.unpack oldVersion)
      , payloadRoot = Just oldWorkspace
      , apply = False
      , resume = Nothing
      , dryRun = True
      , yes = False
      , json = asJson
      }
  newId <- latestUpgradeTransactionId (active ^. #contextName) >>= maybe (dieT "rollback plan did not create a transaction") pure
  runPlatformUpgrade
    mctx
    UpgradeOpts
      { to = Nothing
      , payloadRoot = Nothing
      , apply = True
      , resume = Just (T.unpack newId)
      , dryRun = False
      , yes = True
      , json = asJson
      }

runPlatformUpgradeRecoverPulumi :: Maybe String -> String -> String -> Bool -> IO ()
runPlatformUpgradeRecoverPulumi mctx requested outcomeToken yes = do
  outcome <- case outcomeToken of
    "applied" -> pure RecoveryApplied
    "retry" -> pure RecoveryRetry
    _ -> dieT "--outcome must be either applied or retry"
  unless yes (dieT "refusing to record a Pulumi recovery decision without --yes")
  active <- activeTarget mctx
  guardLegacyMutationInventory "platform upgrade recover-pulumi" active
  (txPath, tx) <- loadUpgradeTransaction (active ^. #contextName) (Just requested)
  when (tx ^. #state == Completed) (dieT "a completed upgrade has no Pulumi outcome to recover")
  let workspace = platformWorkspaceFromTransaction tx
      bundle = takeDirectory (tx ^. #stagedHostRoot) </> "pulumi-plan"
      receiptPath = pulumiReceiptPath txPath tx
      pulumiRecord = find ((== PulumiApply) . (^. #name)) (tx ^. #phases)
  (metadata, _) <- verifyLocalReviewedPlanBundle bundle >>= either dieT pure
  existing <- readVerifiedPulumiReceipt receiptPath tx metadata >>= either dieT pure
  let isLegacySuccess = maybe False ((== Succeeded) . (^. #state)) pulumiRecord && existing == Nothing
      isAmbiguous = maybe False ((== ReceiptStarted) . receiptState) existing
      repeatsSameRecovery =
        maybe
          False
          (\receipt -> receiptState receipt == ReceiptOperatorAttested && receiptRecoveryOutcome receipt == Just outcome)
          existing
  unless (isLegacySuccess || isAmbiguous || repeatsSameRecovery) $
    dieT "Pulumi recovery is available only for an ambiguous started receipt or a successful legacy journal without a receipt"
  validatePulumiRecoveryEnvironment active workspace
  allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
  (identity, verifiedMetadata) <- verifyReviewedPlanBundleEvidence active workspace bundle allowed >>= either dieT pure
  TIO.putStrLn (renderPulumiRecoveryReview tx verifiedMetadata identity outcome)
  now <- currentTimestamp
  receipt <- writeRecoveryReceipt receiptPath tx verifiedMetadata outcome now >>= either dieT pure
  let recoveredState = case outcome of RecoveryApplied -> Succeeded; RecoveryRetry -> Failed
      evidence = renderPulumiReceiptEvidence receipt
      updated =
        recordUpgradePhase PulumiApply recoveredState evidence now tx
          & #state
          .~ TransactionFailed
          & #updatedAt
          .~ now
  writeUpgradeTransaction txPath updated
  TIO.putStrLn ("Recorded " <> recoveryOutcomeLabel outcome <> " recovery at " <> T.pack receiptPath)

validatePulumiRecoveryEnvironment :: ActiveTarget -> PlatformWorkspace -> IO ()
validatePulumiRecoveryEnvironment active workspace = do
  let context = active ^. #contextName
      profile = active ^. #profile
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      (gcloudAccount, adc) <- observeAdcForProject
      warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
      printPreflightWarnings warnings
  ensurePulumiInWorkspace context profile workspace
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      inputs <- projectGuardInputsFor context profile workspace
      either dieT pure (projectGuardVerdict inputs)
      TIO.putStrLn (renderProjectGuard inputs)

renderPulumiRecoveryReview :: UpgradeTransaction -> SavedPlanMetadata -> CurrentInfraIdentity -> PulumiRecoveryOutcome -> Text
renderPulumiRecoveryReview tx metadata identity outcome =
  T.unlines
    [ "Pulumi recovery review"
    , "Transaction: " <> tx ^. #id
    , "Context: " <> tx ^. #context
    , "Target version: " <> tx ^. #targetVersion
    , "Reviewed project/stack: " <> metadata ^. #project <> "/" <> metadata ^. #stack
    , "Reviewed backend: " <> metadata ^. #backend
    , "Reviewed plan digest: " <> metadata ^. #planDigest
    , "Reviewed Pulumi version: " <> metadata ^. #pulumiVersion
    , "Current project/stack: " <> identity ^. #currentProject <> "/" <> identity ^. #currentStack
    , "Current backend: " <> identity ^. #currentBackend
    , "Current Pulumi version: " <> identity ^. #currentPulumiVersion
    , "Recovery outcome: " <> recoveryOutcomeLabel outcome
    ]

recoveryOutcomeLabel :: PulumiRecoveryOutcome -> Text
recoveryOutcomeLabel RecoveryApplied = "applied"
recoveryOutcomeLabel RecoveryRetry = "retry"

findRetainedWorkspace :: ContextName -> Text -> IO FilePath
findRetainedWorkspace context wantedVersion = do
  stateRoot <- nagareStateDir
  let directory = stateRoot </> T.unpack (contextNameText context) </> "platform"
  exists <- doesDirectoryExist directory
  unless exists (dieT ("no retained platform workspaces exist for context '" <> contextNameText context <> "'"))
  names <- sort <$> listDirectory directory
  matches <- fmap catMaybes . forM names $ \name -> do
    let root = directory </> name
    candidate <- validatePlatformRoot ExplicitRoot root
    case candidate of
      Left _ -> pure Nothing
      Right paths -> do
        manifest <- readPayloadManifest paths
        pure $ case manifest of
          Right candidateManifest | candidateManifest ^. #platformVersion == wantedVersion -> Just root
          _ -> Nothing
  case reverse matches of
    root : _ -> pure root
    [] -> dieT ("the retained workspace for platform " <> wantedVersion <> " is unavailable; automatic rollback cannot proceed")

printUpgradeTransaction :: Bool -> UpgradeTransaction -> IO ()
printUpgradeTransaction asJson tx =
  if asJson then LBC.putStrLn (Aeson.encode tx) else TIO.putStr (renderUpgradeTransaction tx)

runPlatformUpgrade :: Maybe String -> UpgradeOpts -> IO ()
runPlatformUpgrade mctx options = do
  active <- activeTarget mctx
  -- The coarse upgrade runner has no component receipts. Once a context has
  -- accepted inventory history, replaying its Pulumi/host/bootstrap phases
  -- would bypass the reviewed component transaction and could overwrite an
  -- independently revised application scope.
  guardLegacyMutationInventory "platform upgrade" active
  if options ^. #apply
    then do
      unless (options ^. #yes) (dieT "refusing to apply an upgrade without --yes")
      resumeId <- maybe (dieT "--apply requires --resume TRANSACTION_ID") pure (options ^. #resume)
      (path, tx) <- loadUpgradeTransaction (active ^. #contextName) (Just resumeId)
      paths <- validatePlatformRoot ExplicitRoot (tx ^. #workspaceRoot) >>= either (dieT . renderPlatformPathError) pure
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      either dieT pure (guardUpgradePayloadCompatibility manifest)
      let workspace = platformWorkspaceFromTransaction tx
      hostRoot <- hostConfigDir (active ^. #contextName)
      ops <- upgradeOps active workspace manifest (tx ^. #stagedHostRoot) hostRoot path
      result <- withEnvironment "NAGARE_SKIP_PULUMI_STACK_SELECT" "1" (applyUpgrade True ops tx)
      case result of
        Left err -> do
          readUpgradeTransaction path >>= either (const (pure ())) (printUpgradeTransaction (options ^. #json))
          dieT err
        Right completed -> printUpgradeTransaction (options ^. #json) completed
    else do
      when (options ^. #resume /= Nothing) (dieT "--resume is only valid with --apply")
      target <- maybe (dieT "a new upgrade plan requires --to VERSION") (either (dieT . ("invalid --to version: " <>) . renderVersionError) (pure . renderPlatformVersion) . parsePlatformVersion . T.pack) (options ^. #to)
      targetPaths <- resolveUpgradePayload target (options ^. #payloadRoot)
      manifest <- readPayloadManifest targetPaths >>= either (dieT . renderWorkspaceError) pure
      either dieT pure (guardUpgradePayloadCompatibility manifest)
      when (manifest ^. #platformVersion /= target) $
        dieT ("target payload reports version " <> manifest ^. #platformVersion <> ", expected " <> target)
      stateRoot <- nagareStateDir
      workspace <- preparePlatformWorkspace stateRoot (active ^. #contextName) targetPaths >>= either (dieT . renderWorkspaceError) pure
      now <- currentTimestamp
      let compactTime = T.take 20 (T.filter isAlphaNum now)
          txId = compactTime <> "-" <> target <> "-" <> T.take 8 (workspace ^. #digest)
      txPath <- upgradeTransactionPath (active ^. #contextName) txId
      txDirectory <- upgradeTransactionsDir (active ^. #contextName)
      let staged = txDirectory </> T.unpack txId </> "host-flake"
      hostRoot <- hostConfigDir (active ^. #contextName)
      hostExists <- doesDirectoryExist hostRoot
      unless hostExists (dieT "platform upgrade requires a generated host flake; run `nagarectl host init` first")
      _ <- stageHostFlake hostRoot staged (targetPaths ^. #nixosDir) (BuildVersion target (manifest ^. #sourceRevision)) >>= either dieT pure
      let tx =
            newUpgradeTransaction
              txId
              (contextNameText (active ^. #contextName))
              (active ^. #profile . #platformVersion)
              target
              (manifest ^. #payloadId)
              (workspace ^. #digest)
              (workspace ^. #root)
              staged
              (maybe False (`elem` manifest ^. #rollbackSupportedFrom) (active ^. #profile . #platformVersion))
              now
      writeUpgradeTransaction txPath tx
      ensurePulumiInWorkspace (active ^. #contextName) (active ^. #profile) workspace
      ops <- upgradeOps active workspace manifest staged hostRoot txPath
      result <- planUpgrade ops tx
      case result of
        Left err -> do
          readUpgradeTransaction txPath >>= either (const (pure ())) (printUpgradeTransaction (options ^. #json))
          dieT err
        Right planned -> printUpgradeTransaction (options ^. #json) planned

guardUpgradePayloadCompatibility :: PayloadManifest -> Either Text ()
guardUpgradePayloadCompatibility manifest
  | manifest ^. #minimumInventorySchemaVersion /= 1 =
      Left "target payload requires an inventory schema this operator does not support; use the target operator payload"
  | manifest ^. #minimumUpgradeTransactionSchemaVersion /= 1 =
      Left "target payload requires an upgrade transaction schema this operator does not support; use the target operator payload"
  | otherwise = Right ()

-- The transaction stores all paths needed to resume without re-resolving a tag.
platformWorkspaceFromTransaction :: UpgradeTransaction -> PlatformWorkspace
platformWorkspaceFromTransaction tx =
  PlatformWorkspace
    { root = tx ^. #workspaceRoot
    , payloadId = tx ^. #payloadId
    , platformVersion = tx ^. #targetVersion
    , sourceRevision = Nothing
    , digest = tx ^. #payloadDigest
    , pulumiDir = tx ^. #workspaceRoot </> "infra" </> "pulumi"
    , scriptsDir = tx ^. #workspaceRoot </> "scripts"
    , clusterDir = tx ^. #workspaceRoot </> "cluster"
    , nixosDir = tx ^. #workspaceRoot </> "nixos"
    , justfile = tx ^. #workspaceRoot </> "justfile"
    , docsDir = tx ^. #workspaceRoot </> "docs" </> "user"
    }

resolveUpgradePayload :: Text -> Maybe FilePath -> IO PlatformPaths
resolveUpgradePayload target override = case override of
  Just root -> validatePlatformRoot ExplicitRoot root >>= either (dieT . renderPlatformPathError) pure
  Nothing -> do
    current <- resolvePlatformPaths Nothing >>= either (dieT . renderPlatformPathError) pure
    currentManifest <- readPayloadManifest current >>= either (dieT . renderWorkspaceError) pure
    if currentManifest ^. #platformVersion == target
      then pure current
      else do
        (code, out, err) <-
          readProcessWithExitCode
            "nix"
            [ "build"
            , "github:shinzui/nagare/v" <> T.unpack target <> "#nagare-platform"
            , "--no-link"
            , "--print-out-paths"
            ]
            ""
        case (code, reverse (filter (not . null) (lines out))) of
          (ExitSuccess, packageRoot : _) ->
            validatePlatformRoot ExplicitRoot (packageRoot </> "share" </> "nagare") >>= either (dieT . renderPlatformPathError) pure
          _ -> dieT ("could not resolve Nagare release v" <> target <> " through Nix: " <> T.pack (err <> out))

upgradeOps :: ActiveTarget -> PlatformWorkspace -> PayloadManifest -> FilePath -> FilePath -> FilePath -> IO UpgradeOps
upgradeOps active workspace manifest staged hostRoot txPath = do
  generatedHostName <- readStagedHostName context staged >>= either dieT pure
  let hostEnvironment = hostSwitchEnvironment staged (hostSwitchIdentity generatedHostName)
  pure
    UpgradeOps
      { runUpgradePhase = runPhase hostEnvironment
      , upgradeResumeDecision = resumeDecision
      , saveUpgradeTransaction = writeUpgradeTransaction txPath
      , upgradeNow = currentTimestamp
      }
  where
    context = active ^. #contextName
    profile = active ^. #profile
    bootstrapEnvironment =
      [ ("NAGARE_CONTEXT", T.unpack (contextNameText context))
      , ("NAGARE_NIX_CACHE_ENABLED", if profile ^. #nixCacheEnabled then "1" else "0")
      , ("NAGARE_CDN_ENABLED", if profile ^. #cdnEnabled then "1" else "0")
      , -- Force shell helpers to discard any stale context variables inherited
        -- from the operator's calling shell before they source the selected
        -- persisted context.
        ("NAGARE_RESOLVED_CONTEXT", "upgrade-transaction")
      ]
    reviewedPlanBundle = takeDirectory staged </> "pulumi-plan"
    reviewedKubernetesBundle = takeDirectory staged </> "kubernetes-plan"
    runPhase _ NixEvaluate =
      runExternal [ExitSuccess] "nix" ["eval", "path:" <> staged <> "#packages.x86_64-linux.nagare-image.drvPath"] ""
    -- EP-136: the preview phase persists one context-bound Pulumi plan beside
    -- the transaction. Apply verifies and consumes that exact bundle; it never
    -- launches a separate preview process.
    runPhase _ PulumiPreview = do
      guarded <- guardPulumiContext
      case guarded of
        Left err -> pure (Left err)
        Right evidence -> do
          allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
          alreadySaved <- doesDirectoryExist reviewedPlanBundle
          saved <-
            if alreadySaved
              then fmap (const ("Retained reviewed Pulumi plan at " <> T.pack reviewedPlanBundle <> "\n")) <$> verifyReviewedPlanBundle active workspace reviewedPlanBundle allowed
              else saveReviewedPlan active workspace reviewedPlanBundle allowed
          pure (fmap ((evidence <> "\n") <>) saved)
    runPhase _ PulumiApply = do
      ensurePulumiInWorkspace context profile workspace
      guarded <- guardPulumiContext
      case guarded of
        Left err -> pure (Left err)
        Right evidence -> do
          allowed <- (== Just "1") <$> lookupEnv "NAGARE_ALLOW_VM_REPLACEMENT"
          verified <- verifyReviewedPlanBundleEvidence active workspace reviewedPlanBundle allowed
          case verified of
            Left err -> pure (Left err)
            Right (identity, metadata) -> do
              loadedTx <- readUpgradeTransaction txPath
              case loadedTx of
                Left err -> pure (Left err)
                Right tx -> do
                  startedAt <- currentTimestamp
                  let receiptPath = pulumiReceiptPath txPath tx
                  started <- writeStartedReceipt receiptPath tx metadata startedAt
                  case started of
                    Left err -> pure (Left err)
                    Right _ -> do
                      applied <- applyVerifiedReviewedPlan workspace reviewedPlanBundle identity
                      resultAt <- currentTimestamp
                      recorded <-
                        writeResultReceipt
                          receiptPath
                          tx
                          metadata
                          (either (const ReceiptFailed) (const ReceiptSucceeded) applied)
                          resultAt
                      pure $ case (applied, recorded) of
                        (Left err, Right _) -> Left err
                        (Right applyEvidence, Right receipt) ->
                          Right (evidence <> "\n" <> applyEvidence <> "\n" <> renderPulumiReceiptEvidence receipt)
                        (Left applyError, Left receiptError) -> Left (applyError <> "\n" <> receiptError)
                        (Right _, Left receiptError) ->
                          Left
                            ( "Pulumi apply returned success but its durable receipt could not be recorded; outcome is ambiguous:\n"
                                <> receiptError
                            )
    runPhase _ KubernetesDiff = do
      guarded <- guardKubernetesContext active
      case guarded of
        Left err -> pure (Left err)
        Right evidence ->
          fmap ((evidence <> "\n") <>)
            <$> saveReviewedKubernetesPlan active workspace txPath reviewedKubernetesBundle
    runPhase hostEnvironment HostApply = do
      switched <- withEnvironmentValues hostEnvironment $ runExternal [ExitSuccess] "bash" [workspace ^. #scriptsDir </> "host-switch.sh"] ""
      case switched of
        Left err -> pure (Left err)
        Right evidence -> do
          committed <- commitStagedHostFlake staged hostRoot
          pure (evidence <$ committed)
    runPhase _ KubernetesApply = do
      migration <- applyReviewedKubernetesPlan active workspace txPath reviewedKubernetesBundle
      case migration of
        Left err -> pure (Left err)
        Right migrationEvidence -> do
          bootstrap <-
            withEnvironmentValues bootstrapEnvironment $
              withEnvironment "NAGARE_UPGRADE_APPLY" "1" $
                runExternal
                  [ExitSuccess]
                  "just"
                  ["--justfile", workspace ^. #justfile, "--working-directory", workspace ^. #root, bootstrapRecipe]
                  ""
          pure (fmap (\evidence -> migrationEvidence <> "\n" <> evidence) bootstrap)
    runPhase _ ClusterStamp = applyClusterMarker manifest
    runPhase _ ContextCommit =
      writeContextPlatformVersion context (manifest ^. #platformVersion)
        >>= pure . fmap (const ("context pin advanced to " <> manifest ^. #platformVersion))
    guardPulumiContext = case profile ^. #mode of
      Local ->
        pure (Right "context guard: local mode; no GCP project to confine")
      Cloud -> do
        pgi <- projectGuardInputsFor context profile workspace
        case projectGuardVerdict pgi of
          Left refusal -> pure (Left refusal)
          Right () -> pure (Right (renderProjectGuard pgi))
    bootstrapRecipe = case profile ^. #mode of
      Local -> "local-bootstrap"
      Cloud -> "cluster-bootstrap"
    phaseSatisfied NixEvaluate = doesFileExist (staged </> "flake.nix")
    phaseSatisfied PulumiPreview = pure False
    phaseSatisfied KubernetesDiff = pure False
    phaseSatisfied PulumiApply = pure False
    phaseSatisfied HostApply = do
      exists <- doesFileExist (hostRoot </> "flake.nix")
      if exists
        then (== Just (manifest ^. #platformVersion)) . (^. #version) . parseHostIdentity <$> TIO.readFile (hostRoot </> "flake.nix")
        else pure False
    phaseSatisfied KubernetesApply = pure False
    phaseSatisfied ClusterStamp = do
      observed <- captureTool "kubectl" ["get", "configmap", "nagare-platform-version", "-n", "nagare-system", "-o", "json", "--request-timeout=5s"]
      pure $ case observed >>= parseClusterIdentity of
        Just identity -> identity ^. #version == Just (manifest ^. #platformVersion)
        Nothing -> False
    phaseSatisfied ContextCommit = do
      current <- readContextProfile context
      pure (either (const False) ((== Just (manifest ^. #platformVersion)) . (^. #platformVersion)) current)
    resumeDecision PulumiApply state = pulumiResumeDecision state
    resumeDecision phase state
      | state /= Succeeded = pure RunPhase
      | otherwise = do
          satisfied <- phaseSatisfied phase
          pure (if satisfied then SkipPhase (phaseToken phase <> " postcondition is satisfied") else RunPhase)
    pulumiResumeDecision state = do
      loadedTx <- readUpgradeTransaction txPath
      case loadedTx of
        Left err -> pure (RefusePhase err)
        Right tx -> do
          localPlan <- verifyLocalReviewedPlanBundle reviewedPlanBundle
          case localPlan of
            Left err -> pure (RefusePhase err)
            Right (metadata, _) -> do
              receipt <- readVerifiedPulumiReceipt (pulumiReceiptPath txPath tx) tx metadata
              pure $ case receipt of
                Left err -> RefusePhase err
                Right Nothing
                  | state == Succeeded ->
                      RefusePhase
                        ( "the successful Pulumi journal predates durable receipts; run `nagarectl platform upgrade recover-pulumi "
                            <> tx ^. #id
                            <> " --outcome applied|retry --yes`"
                        )
                  | otherwise -> RunPhase
                Right (Just proof) -> case (receiptState proof, receiptRecoveryOutcome proof) of
                  (ReceiptSucceeded, Nothing) -> SkipPhase (renderPulumiReceiptEvidence proof)
                  (ReceiptFailed, Nothing) -> RunPhase
                  (ReceiptStarted, Nothing) ->
                    RefusePhase
                      ( "Pulumi may have changed provider state before its result was recorded; run `nagarectl platform upgrade recover-pulumi "
                          <> tx ^. #id
                          <> " --outcome applied|retry --yes`"
                      )
                  (ReceiptOperatorAttested, Just RecoveryApplied) -> SkipPhase (renderPulumiReceiptEvidence proof)
                  (ReceiptOperatorAttested, Just RecoveryRetry) -> RunPhase
                  _ -> RefusePhase "Pulumi apply receipt has an invalid state"
