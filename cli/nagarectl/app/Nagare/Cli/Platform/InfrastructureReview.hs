-- | Platform / InfrastructureReview. Executable-private CLI boundary.
module Nagare.Cli.Platform.InfrastructureReview
  ( applyReviewedPlan
  , applyVerifiedReviewedPlan
  , instanceReplacementGuard
  , prepareInfraMutation
  , prepareInfraMutationWithPulumi
  , prepareInfraTargetWithPulumi
  , prepareVmPowerMutation
  , saveReviewedPlan
  , verifyLocalReviewedPlanBundle
  , verifyReviewedPlanBundle
  , verifyReviewedPlanBundleEvidence
  )
where

import Control.Exception (IOException, catch, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT, printPreflightWarnings)
import Nagare.Cli.Runtime.PlatformStatus (gatherPlatformStatus)
import Nagare.Cli.Runtime.Process (currentTimestamp, runExternal)
import Nagare.Cli.Runtime.ProjectGuard
  ( observeAdcForProject
  , projectGuardInputsFor
  )
import Nagare.Cli.Runtime.Pulumi
  ( ensurePulumiForContext
  , ensurePulumiForContextWithDependencies
  , selectReviewedPulumiForContext
  )
import Nagare.Cli.Runtime.ReviewFiles (cleanupPlanStaging)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc (validateAdc)
import Nagare.Infra.Plan
  ( CurrentInfraIdentity (..)
  , PlanVerdict (..)
  , SavedPlanMetadata (..)
  , SavedPlanReview (..)
  , classifyPlan
  , digestFile
  , digestPulumiProgram
  , parsePreview
  , previewErrors
  , protectedResourceTypes
  , renderPlanBindingError
  , renderVerdict
  , reviewVerdict
  , verifySavedPlan
  )
import Nagare.Ops.ContextGuard
  ( projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Platform.StackConfig (contextStackConfigPath)
import Nagare.Platform.Status (guardPlatformMutation)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Target
  ( ActiveTarget
  , Mode (Cloud, Local)
  , TargetProfile
  , contextNameText
  , nagareStateDir
  , pulumiEnvFor
  , validateVmShape
  , vmShapeOf
  )
import Nagare.Version (BuildVersion (BuildVersion), compatibilityToken, currentBuildVersion)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  , renameDirectory
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( fileMode
  , getFileStatus
  , isDirectory
  , isRegularFile
  , setFileMode
  )
import System.Process (readProcessWithExitCode)

-- | Compose the release and project/ADC guards before any standalone
-- infrastructure mutation. ADC is validated before workspace preparation,
-- because preparation may select or initialize a Pulumi stack.
prepareInfraMutation :: Maybe String -> IO (ActiveTarget, PlatformWorkspace)
prepareInfraMutation = prepareInfraMutationWithPulumi True

prepareInfraMutationWithPulumi :: Bool -> Maybe String -> IO (ActiveTarget, PlatformWorkspace)
prepareInfraMutationWithPulumi needsPulumi mctx = do
  (active, status) <- gatherPlatformStatus mctx
  either dieT pure (guardPlatformMutation status)
  TIO.putStrLn ("platform mutation allowed (" <> compatibilityToken (status ^. #compatibility) <> ")")
  prepareInfraTargetWithPulumi needsPulumi active

-- Power control must work while the guest and Kubernetes API are unavailable.
-- Preserve static release, ADC and project guards without probing either guest.
prepareVmPowerMutation :: Maybe String -> IO (ActiveTarget, PlatformWorkspace)
prepareVmPowerMutation mctx = do
  active <- activeTarget mctx
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let BuildVersion version _ = currentBuildVersion
  unless
    ( active ^. #profile . #mode == Cloud
        && active ^. #profile . #platformVersion == Just (workspace ^. #platformVersion)
        && version == workspace ^. #platformVersion
    )
    (dieT "VM power requires the accepted context, payload and operator platform version")
  prepareInfraTargetWithPulumi True active

prepareInfraTargetWithPulumi :: Bool -> ActiveTarget -> IO (ActiveTarget, PlatformWorkspace)
prepareInfraTargetWithPulumi needsPulumi active = do
  let contextName = active ^. #contextName
      profile = active ^. #profile
  case profile ^. #mode of
    Local -> pure ()
    Cloud -> do
      (gcloudAccount, adc) <- observeAdcForProject
      warnings <- either dieT pure (validateAdc (profile ^. #project) gcloudAccount adc)
      printPreflightWarnings warnings
  workspace <- case profile ^. #mode of
    Cloud | needsPulumi -> selectReviewedPulumiForContext contextName profile
    Cloud -> ensurePulumiForContextWithDependencies False False False contextName profile
    Local -> ensurePulumiForContext contextName profile
  case profile ^. #mode of
    Local -> TIO.putStrLn "context guard: local mode; no GCP project to confine"
    Cloud -> do
      inputs <- projectGuardInputsFor contextName profile workspace
      either dieT pure (projectGuardVerdict inputs)
      TIO.putStrLn (renderProjectGuard inputs)
  pure (active, workspace)

planFileName, reviewFileName, metadataFileName :: FilePath
planFileName = "pulumi-plan.json"
reviewFileName = "review.json"
metadataFileName = "metadata.json"

currentInfraIdentity :: ActiveTarget -> PlatformWorkspace -> IO (Either Text CurrentInfraIdentity)
currentInfraIdentity active workspace = do
  result <- try $ do
    stateRoot <- nagareStateDir
    let contextName = active ^. #contextName
        profile = active ^. #profile
        penv = pulumiEnvFor stateRoot (contextNameText contextName) profile
    configPath <- contextStackConfigPath contextName
    configDigest <- digestFile configPath
    programDigest <- digestPulumiProgram (workspace ^. #pulumiDir)
    versionResult <- readProcessWithExitCode "pulumi" ["version"] ""
    pulumiVersion <- case versionResult of
      (ExitSuccess, out, _) | not (T.null (T.strip (T.pack out))) -> pure (T.strip (T.pack out))
      (ExitFailure code, out, err) ->
        ioError (userError ("pulumi version exited " <> show code <> ": " <> err <> out))
      _ -> ioError (userError "pulumi version returned an empty version")
    pure
      CurrentInfraIdentity
        { currentContext = contextNameText contextName
        , currentProject = profile ^. #project
        , currentStack = penv ^. #stack
        , currentBackend = penv ^. #backendUrl
        , currentPayloadId = workspace ^. #payloadId
        , currentPayloadDigest = workspace ^. #digest
        , currentProgramDigest = programDigest
        , currentConfigDigest = configDigest
        , currentPulumiVersion = pulumiVersion
        }
  pure $ case result of
    Left (err :: IOException) -> Left ("could not capture the current infrastructure identity: " <> T.pack (show err))
    Right identity -> Right identity

saveReviewedPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text Text)
saveReviewedPlan active workspace destination allowReplacement = do
  exists <- doesPathExist destination
  if exists
    then pure (Left ("refusing to overwrite existing saved-plan bundle " <> T.pack destination))
    else do
      identityResult <- currentInfraIdentity active workspace
      case identityResult of
        Left err -> pure (Left err)
        Right identity -> do
          let parent = takeDirectory destination
          createDirectoryIfMissing True parent
          staging <- createTempDirectory parent ".nagare-plan-"
          setFileMode staging 0o700
          preview <-
            try
              ( readProcessWithExitCode
                  "pulumi"
                  [ "-C"
                  , workspace ^. #pulumiDir
                  , "preview"
                  , "--json"
                  , "--save-plan"
                  , staging </> planFileName
                  , "--stack"
                  , T.unpack (identity ^. #currentStack)
                  , "--non-interactive"
                  ]
                  ""
              )
          case preview of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not run Pulumi preview: " <> T.pack (show err))
            Right (ExitFailure code, out, err) ->
              cleanupPlanStaging
                staging
                ( "Pulumi preview exited "
                    <> T.pack (show code)
                    <> ":\n"
                    <> T.strip (T.unlines (T.pack err : previewErrors (TE.encodeUtf8 (T.pack out))))
                )
            Right (ExitSuccess, out, _) -> case parsePreview (TE.encodeUtf8 (T.pack out)) of
              Left err -> cleanupPlanStaging staging ("could not parse Pulumi preview: " <> err)
              Right steps -> do
                let review = SavedPlanReview 1 allowReplacement steps
                    verdict = reviewVerdict review
                case verdict of
                  PlanReplacesProtected _
                    | not allowReplacement ->
                        cleanupPlanStaging staging (renderVerdict (active ^. #profile . #instanceName) verdict)
                  _ -> finalizePlan staging identity review verdict
  where
    finalizePlan staging identity review verdict = do
      let planPath = staging </> planFileName
          reviewPath = staging </> reviewFileName
          metadataPath = staging </> metadataFileName
          reviewBytes = LBS.toStrict (Aeson.encode review) <> "\n"
      planExists <- doesFileExist planPath
      if not planExists
        then cleanupPlanStaging staging "Pulumi preview succeeded without writing its saved plan"
        else do
          BS.writeFile reviewPath reviewBytes
          setFileMode planPath 0o600
          setFileMode reviewPath 0o600
          planDigest <- digestFile planPath
          reviewDigest <- digestFile reviewPath
          createdAt <- currentTimestamp
          let metadata =
                SavedPlanMetadata
                  { metadataSchemaVersion = 1
                  , context = identity ^. #currentContext
                  , project = identity ^. #currentProject
                  , stack = identity ^. #currentStack
                  , backend = identity ^. #currentBackend
                  , payloadId = identity ^. #currentPayloadId
                  , payloadDigest = identity ^. #currentPayloadDigest
                  , programDigest = identity ^. #currentProgramDigest
                  , configDigest = identity ^. #currentConfigDigest
                  , pulumiVersion = identity ^. #currentPulumiVersion
                  , createdAt = createdAt
                  , planDigest = planDigest
                  , reviewDigest = reviewDigest
                  }
          BS.writeFile metadataPath (LBS.toStrict (Aeson.encode metadata) <> "\n")
          setFileMode metadataPath 0o600
          renamed <- try (renameDirectory staging destination)
          case renamed of
            Left (err :: IOException) -> cleanupPlanStaging staging ("could not publish saved-plan bundle: " <> T.pack (show err))
            Right () ->
              pure
                ( Right
                    ( "Saved reviewed Pulumi plan for context '"
                        <> identity ^. #currentContext
                        <> "' at "
                        <> T.pack destination
                        <> "\n"
                        <> renderVerdict (active ^. #profile . #instanceName) verdict
                    )
                )

applyReviewedPlan :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text Text)
applyReviewedPlan active workspace bundle allowReplacement = do
  verified <- verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement
  case verified of
    Left err -> pure (Left err)
    Right (identity, _) -> applyVerifiedReviewedPlan workspace bundle identity

applyVerifiedReviewedPlan :: PlatformWorkspace -> FilePath -> CurrentInfraIdentity -> IO (Either Text Text)
applyVerifiedReviewedPlan workspace bundle identity = do
  applied <-
    runExternal
      [ExitSuccess]
      "pulumi"
      [ "-C"
      , workspace ^. #pulumiDir
      , "up"
      , "--plan"
      , bundle </> planFileName
      , "--stack"
      , T.unpack (identity ^. #currentStack)
      , "--yes"
      , "--non-interactive"
      ]
      ""
  pure $
    fmap
      ( \evidence ->
          "Applied reviewed Pulumi plan for context '"
            <> identity ^. #currentContext
            <> "' from "
            <> T.pack bundle
            <> if T.null (T.strip evidence) then "\n" else "\n" <> evidence
      )
      applied

verifyReviewedPlanBundle :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text CurrentInfraIdentity)
verifyReviewedPlanBundle active workspace bundle allowReplacement =
  fmap (fmap fst) (verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement)

verifyReviewedPlanBundleEvidence :: ActiveTarget -> PlatformWorkspace -> FilePath -> Bool -> IO (Either Text (CurrentInfraIdentity, SavedPlanMetadata))
verifyReviewedPlanBundleEvidence active workspace bundle allowReplacement = do
  local <- verifyLocalReviewedPlanBundle bundle
  case local of
    Left err -> pure (Left err)
    Right (metadata, savedReview) -> do
      identityResult <- currentInfraIdentity active workspace
      case identityResult of
        Left err -> pure (Left err)
        Right identity -> case verifySavedPlan identity metadata of
          Left err -> pure (Left ("refusing saved plan: " <> renderPlanBindingError err))
          Right () ->
            pure $ case reviewVerdict savedReview of
              PlanReplacesProtected _
                | not allowReplacement ->
                    Left "refusing saved plan: repeat the protected-replacement acknowledgement with --allow-replacement"
              _ -> Right (identity, metadata)

verifyLocalReviewedPlanBundle :: FilePath -> IO (Either Text (SavedPlanMetadata, SavedPlanReview))
verifyLocalReviewedPlanBundle bundle = do
  loaded <- loadPlanBundle bundle
  case loaded of
    Left err -> pure (Left err)
    Right (metadata, savedReview) -> do
      planHash <- digestFile (bundle </> planFileName)
      reviewHash <- digestFile (bundle </> reviewFileName)
      pure $
        if planHash /= metadata ^. #planDigest
          then Left "refusing saved plan: pulumi-plan.json digest does not match metadata.json"
          else
            if reviewHash /= metadata ^. #reviewDigest
              then Left "refusing saved plan: review.json digest does not match metadata.json"
              else case reviewVerdict savedReview of
                PlanReplacesProtected _
                  | not (savedReview ^. #replacementApproved) ->
                      Left "refusing saved plan: review contains a protected replacement that was not approved at preview time"
                _ -> Right (metadata, savedReview)

loadPlanBundle :: FilePath -> IO (Either Text (SavedPlanMetadata, SavedPlanReview))
loadPlanBundle bundle = do
  checked <- try (validatePlanBundleSecurity bundle)
  case checked of
    Left (err :: IOException) -> pure (Left ("invalid saved-plan bundle " <> T.pack bundle <> ": " <> T.pack (show err)))
    Right () -> do
      metadataBytes <- BS.readFile (bundle </> metadataFileName)
      reviewBytes <- BS.readFile (bundle </> reviewFileName)
      pure $ do
        metadata <- firstText "metadata.json" (Aeson.eitherDecodeStrict' metadataBytes)
        review <- firstText "review.json" (Aeson.eitherDecodeStrict' reviewBytes)
        if review ^. #reviewSchemaVersion /= 1
          then Left ("unsupported review.json schema " <> T.pack (show (review ^. #reviewSchemaVersion)))
          else Right (metadata, review)
  where
    firstText name = either (Left . (("invalid " <> name <> ": ") <>) . T.pack) Right

validatePlanBundleSecurity :: FilePath -> IO ()
validatePlanBundleSecurity bundle = do
  linked <- pathIsSymbolicLink bundle
  when linked (ioError (userError "bundle directory is a symlink"))
  bundleStatus <- getFileStatus bundle
  unless (isDirectory bundleStatus) (ioError (userError "bundle path is not a directory"))
  unless (privateMode bundleStatus) (ioError (userError "bundle directory is accessible by group or other users"))
  entries <- sort <$> listDirectory bundle
  unless (entries == sort [metadataFileName, planFileName, reviewFileName]) $
    ioError (userError "bundle must contain exactly metadata.json, pulumi-plan.json, and review.json")
  forM_ entries $ \entry -> do
    let path = bundle </> entry
    entryLinked <- pathIsSymbolicLink path
    when entryLinked (ioError (userError (entry <> " is a symlink")))
    status <- getFileStatus path
    unless (isRegularFile status) (ioError (userError (entry <> " is not a regular file")))
    unless (privateMode status) (ioError (userError (entry <> " is accessible by group or other users")))
  where
    privateMode status = fileMode status .&. 0o077 == 0

-- | Preview the stack and refuse a plan that replaces a protected resource (the
-- GCE instance, the Cloud DNS zone, or a bucket). Any failure to preview or parse
-- is a refusal. Shared by @nagarectl infra guard@ and the upgrade's Pulumi phases
-- (EP-121), so the transaction is never less guarded than @just infra-up@.
instanceReplacementGuard :: TargetProfile -> PlatformWorkspace -> String -> Bool -> IO (Either Text Text)
instanceReplacementGuard tp workspace stack allowReplacement =
  case validateVmShape (vmShapeOf tp) of
    Left err -> pure (Left err)
    Right _ -> do
      previewResult <-
        catch
          (Right <$> readProcessWithExitCode "pulumi" ["-C", workspace ^. #pulumiDir, "preview", "--json", "--stack", stack, "--non-interactive"] "")
          (pure . Left . (\(err :: IOException) -> err))
      pure $ case previewResult of
        Left err -> Left ("infra guard could not run Pulumi preview; refusing to apply: " <> T.pack (show err))
        Right (ExitFailure code, out, err) ->
          Left
            ( "infra guard could not inspect the Pulumi plan (preview exited "
                <> T.pack (show code)
                <> "); refusing to apply:\n"
                <> T.strip (T.unlines (T.pack err : previewErrors (TE.encodeUtf8 (T.pack out))))
            )
        Right (ExitSuccess, out, _) ->
          case parsePreview (TE.encodeUtf8 (T.pack out)) of
            Left err -> Left ("infra guard could not parse Pulumi preview; refusing to apply: " <> err)
            Right steps ->
              let verdict = classifyPlan protectedResourceTypes steps
                  message = renderVerdict (tp ^. #instanceName) verdict
               in case verdict of
                    PlanAllowed -> Right message
                    PlanReplacesProtected _
                      | allowReplacement -> Right ("Protected resource replacement explicitly allowed for this run.\n" <> message)
                      | otherwise -> Left message
