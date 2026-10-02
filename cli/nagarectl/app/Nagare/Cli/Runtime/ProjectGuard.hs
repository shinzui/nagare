-- | Runtime / ProjectGuard. Executable-private CLI boundary.
module Nagare.Cli.Runtime.ProjectGuard
  ( observeAdcForProject
  , projectGuardInputsFor
  , runContextGuard
  )
where

import Control.Exception (IOException, catch)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi
  ( ensurePulumiForContextWithInstallNotice
  )
import Nagare.Cli.Runtime.Target (activeTarget)
import Nagare.Dsl.Prelude
import Nagare.Gcp.Adc
  ( AdcError
  , AdcObservation
  , adcEnvFromProcess
  , adcEvidenceValue
  , observeAdc
  , validateAdc
  )
import Nagare.Ops.ContextGuard
  ( ProjectGuardInputs (..)
  , PulumiProjectObservation (..)
  , parsePulumiProjectConfig
  , projectGuardObservationsValue
  , projectGuardVerdict
  , renderProjectGuard
  )
import Nagare.Ops.Probe (captureTool)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Target
  ( ContextName
  , Mode (Cloud, Local)
  , TargetProfile
  , contextNameText
  , nagareStateDir
  , pulumiEnvFor
  )
import System.Directory (findExecutable)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit
  ( ExitCode (ExitFailure, ExitSuccess)
  , exitFailure
  )
import System.IO (stderr)
import System.Process
  ( CreateProcess (env)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  )

-- | @nagarectl context guard@ (EP-113). The project-confinement preflight for
-- @just infra-up@ / @just infra-preview@, which before this had no project check at
-- all: the selected Pulumi stack's own config was the only thing standing between
-- @pulumi up@ and someone else's project.
--
-- Deliberately separate from @nagarectl platform guard@, which answers the orthogonal
-- release-compatibility question. The @justfile@ composes both, which is where a
-- recipe's full preflight belongs.
runContextGuard :: Maybe String -> Bool -> IO ()
runContextGuard mctx asJson = do
  active <- activeTarget mctx
  let name = active ^. #contextName
      tp = active ^. #profile
      ctx = contextNameText name
  case tp ^. #mode of
    -- A local context has no GCP project, exactly as `_require_target_project` in
    -- scripts/lib/target.sh has no project to check there.
    Local ->
      if asJson
        then LBC.putStrLn (Aeson.encode (Aeson.object ["context" Aeson..= ctx, "mode" Aeson..= ("local" :: Text), "confined" Aeson..= True]))
        else TIO.putStrLn "context guard: local mode; no GCP project to confine"
    Cloud -> do
      -- ADC is checked before workspace preparation because preparation can invoke
      -- Pulumi. A foreign quota project must stop the very first Pulumi process.
      (gcloudAccount, adc) <- observeAdcForProject
      case validateAdc (tp ^. #project) gcloudAccount adc of
        Left msg ->
          if asJson
            then do
              let observed =
                    Aeson.object
                      [ "context" Aeson..= ctx
                      , "declaredProject" Aeson..= (tp ^. #project)
                      , "gcloudAccount" Aeson..= gcloudAccount
                      , "adc" Aeson..= adcEvidenceValue (tp ^. #project) gcloudAccount adc
                      , "warnings" Aeson..= ([] :: [Text])
                      ]
              LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["confined" Aeson..= False, "refusal" Aeson..= msg, "observations" Aeson..= observed]))
              exitFailure
            else dieT msg
        Right _ -> pure ()
      -- Ensure the per-context PULUMI_HOME, backend URL and stack exist and are
      -- selected, so the guard is usable as the ONLY preflight a clone-free recipe
      -- needs. These operations are idempotent and `.envrc` performs them on every
      -- shell entry already.
      workspace <- ensurePulumiForContextWithInstallNotice (not asJson) name tp
      pgi <- projectGuardInputsFor name tp workspace
      let observed = projectGuardObservationsValue pgi
      case projectGuardVerdict pgi of
        Left msg ->
          if asJson
            then do
              LBC.hPutStrLn stderr (Aeson.encode (Aeson.object ["confined" Aeson..= False, "refusal" Aeson..= msg, "observations" Aeson..= observed]))
              exitFailure
            else dieT msg
        Right () ->
          if asJson
            then LBC.putStrLn (Aeson.encode (Aeson.object ["confined" Aeson..= True, "observations" Aeson..= observed]))
            else TIO.putStrLn (renderProjectGuard pgi)

-- | The three project observations the project guard compares with the context.
-- Shared by @nagarectl context guard@ and the upgrade's Pulumi phases (EP-121).
projectGuardInputsFor :: ContextName -> TargetProfile -> PlatformWorkspace -> IO ProjectGuardInputs
projectGuardInputsFor name tp workspace = do
  stateRoot <- nagareStateDir
  let ctx = contextNameText name
      penv = pulumiEnvFor stateRoot ctx tp
      stack = penv ^. #stack
  (gcloudAccount, adc) <- observeAdcForProject
  stackProject <- case validateAdc (tp ^. #project) gcloudAccount adc of
    Left _ -> pure PulumiProbeSkipped
    Right _ -> probePulumiProject (workspace ^. #pulumiDir) stack
  ambient <- fmap T.pack <$> lookupEnv "CLOUDSDK_CORE_PROJECT"
  configured <- gcloudConfiguredProject
  pure
    ProjectGuardInputs
      { context = ctx
      , declared = tp ^. #project
      , stack = stack
      , pulumiBackendUrl = penv ^. #backendUrl
      , stackProject = stackProject
      , ambient = nonBlank =<< ambient
      , configured = configured
      , gcloudAccount = gcloudAccount
      , adc = adc
      }
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)
    -- gcloud lets CLOUDSDK_CORE_PROJECT shadow its own configuration, so read the
    -- configured value with that variable stripped from the child's environment —
    -- otherwise the comparison would be a tautology. Modify the inherited
    -- environment rather than unsetting the variable in this process, which would
    -- not be safe.
    gcloudConfiguredProject = do
      parentEnv <- getEnvironment
      let childEnv = filter ((/= "CLOUDSDK_CORE_PROJECT") . fst) parentEnv
      captured <-
        (readCreateProcessResult childEnv) `catch` \(_ :: IOException) -> pure Nothing
      pure (nonBlank =<< captured)
    readCreateProcessResult childEnv = do
      (code, out, _) <-
        readCreateProcessWithExitCode
          (proc "gcloud" ["config", "get-value", "project"]) {env = Just childEnv}
          ""
      pure $ case code of
        ExitSuccess -> Just (T.pack out)
        ExitFailure _ -> Nothing

observeAdcForProject :: IO (Maybe Text, Either AdcError AdcObservation)
observeAdcForProject = do
  gcloudAccount <- activeGcloudAccount
  adcEnv <- adcEnvFromProcess
  adc <- observeAdc adcEnv
  pure (gcloudAccount, adc)

activeGcloudAccount :: IO (Maybe Text)
activeGcloudAccount = do
  observed <- captureTool "gcloud" ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
  pure (nonBlank =<< fmap (TE.decodeUtf8) observed)
  where
    nonBlank accountText
      | T.null (T.strip accountText) = Nothing
      | otherwise = Just (T.strip accountText)

-- | Collect the evidence required by the project guard without collapsing a
-- missing tool, a failed command, invalid output, and an absent config key.
probePulumiProject :: FilePath -> Text -> IO PulumiProjectObservation
probePulumiProject pulumiDir stack = do
  executable <- findExecutable "pulumi"
  case executable of
    Nothing -> pure PulumiToolNotFound
    Just path -> do
      result <-
        catch
          ( Right
              <$> readProcessWithExitCode
                path
                [ "-C"
                , pulumiDir
                , "config"
                , "--json"
                , "--stack"
                , T.unpack stack
                , "--non-interactive"
                ]
                ""
          )
          (pure . Left . T.pack . displayExceptionText)
      pure $ case result of
        Left err -> PulumiToolStartFailed err
        Right (ExitFailure exitCode, out, err) ->
          PulumiCommandFailed exitCode (commandDiagnostic out err)
        Right (ExitSuccess, out, _) ->
          either PulumiProjectInvalidOutput (\observation -> observation) (parsePulumiProjectConfig (TE.encodeUtf8 (T.pack out)))
  where
    displayExceptionText :: IOException -> String
    displayExceptionText = show
    commandDiagnostic out err =
      case filter (not . T.null) [T.strip (T.pack err), T.strip (T.pack out)] of
        diagnostic : _ -> diagnostic
        [] -> "(no stderr)"
