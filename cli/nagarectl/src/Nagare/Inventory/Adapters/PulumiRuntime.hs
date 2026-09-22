-- | Production subprocess runtime for the Pulumi inventory adapter.
--
-- Planning is the only phase that creates a saved plan. Execution writes the
-- retained bytes to a private temporary file and passes that exact file to
-- @pulumi up --plan@. Verification observes convergence with a no-change
-- preview; it never regenerates execution authority.
module Nagare.Inventory.Adapters.PulumiRuntime
  ( PulumiRuntimeConfig (..)
  , mkPulumiRuntimeOps
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Infra.Plan (digestFile, digestPulumiProgram)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Pulumi
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (operationIdText)
import Nagare.Resource.Types
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data PulumiRuntimeConfig = PulumiRuntimeConfig
  { runtimeContext :: !Text
  , runtimeProject :: !Text
  , runtimeStack :: !Text
  , runtimeBackend :: !Text
  , runtimePayloadId :: !Text
  , runtimePayloadDigest :: !ContentDigest
  , runtimePulumiExecutable :: !FilePath
  , runtimePulumiDirectory :: !FilePath
  , runtimeStackConfig :: !FilePath
  , runtimeDeclarationBundle :: !ByteString
  , runtimeRegistrations :: ![NativeRegistration]
  }
  deriving stock (Eq, Show)

mkPulumiRuntimeOps :: PulumiRuntimeConfig -> PulumiAdapterOps
mkPulumiRuntimeOps config =
  PulumiAdapterOps
    { pulumiObserveResources = observeResources config
    , pulumiPrepareSavedPlan = prepareSavedPlan config
    , pulumiReadIdentity = readIdentity config
    , pulumiApplySavedPlan = applySavedPlan config
    , pulumiVerifyResources = verifyResources config
    , pulumiRecoverSavedPlan = recoverSavedPlan config
    }

observeResources :: PulumiRuntimeConfig -> [ResourceId] -> IO (Either Text ObservationSet)
observeResources config resources = do
  result <- runPulumi config ["stack", "export", "--stack", T.unpack (runtimeStack config), "--show-secrets=false"]
  pure $ do
    output <- successful "Pulumi stack export" result
    physicalByUrn <- decodePhysicalResources (TE.encodeUtf8 (T.pack output))
    let registrationByResource = Map.fromList [(registrationResource registration, registration) | registration <- runtimeRegistrations config]
    observations <- traverse (observeOne registrationByResource physicalByUrn) resources
    observationSet observations
  where
    observeOne registrations physicalByUrn resource = do
      registration <- maybe (Left ("Pulumi resource is absent from the native registration bundle: " <> resourceIdText resource)) Right (Map.lookup resource registrations)
      let urn = registrationPulumiUrn registration
      pure $ case Map.lookup urn physicalByUrn of
        Just physical -> (resource, ObservedPresent physical)
        Nothing -> (resource, ConfirmedAbsent (contentDigest (TE.encodeUtf8 ("pulumi-absence:" <> urn))))

prepareSavedPlan :: PulumiRuntimeConfig -> PlannedOperation -> IO (Either Text PulumiPreparation)
prepareSavedPlan config _ =
  withSystemTempDirectory "nagare-pulumi-inventory-plan" $ \temporary -> do
    let planPath = temporary </> "pulumi-plan.json"
    result <- runPulumiWithDeclarations config temporary ["preview", "--json", "--save-plan", planPath, "--stack", T.unpack (runtimeStack config), "--non-interactive"]
    case successful "Pulumi preview" result of
      Left err -> pure (Left err)
      Right nativePreview -> do
        planResult <- try (BS.readFile planPath)
        identity <- readIdentity config
        pure $ do
          planBytes <- first (\(err :: IOException) -> "Pulumi preview did not retain a readable saved plan: " <> T.pack (show err)) planResult
          current <- identity
          pure
            PulumiPreparation
              { preparationIdentity = current
              , preparationPreview = TE.encodeUtf8 (T.pack nativePreview)
              , preparationSavedPlan = planBytes
              , preparationRegistrations = runtimeRegistrations config
              }

readIdentity :: PulumiRuntimeConfig -> IO (Either Text PulumiIdentity)
readIdentity config = do
  result <- try $ do
    program <- digestPulumiProgram (runtimePulumiDirectory config) >>= digestFromText "program"
    stackConfig <- digestFile (runtimeStackConfig config) >>= digestFromText "stack config"
    versionResult <- runPulumi config ["version"]
    version <- either (ioError . userError . T.unpack) pure (successful "pulumi version" versionResult)
    pure
      PulumiIdentity
        { pulumiContext = runtimeContext config
        , pulumiProject = runtimeProject config
        , pulumiStack = runtimeStack config
        , pulumiBackend = runtimeBackend config
        , pulumiPayloadId = runtimePayloadId config
        , pulumiPayloadDigest = runtimePayloadDigest config
        , pulumiProgramDigest = program
        , pulumiConfigDigest = stackConfig
        , pulumiToolVersion = T.strip (T.pack version)
        }
  pure (first (\(err :: IOException) -> "could not capture Pulumi inventory identity: " <> T.pack (show err)) result)

applySavedPlan :: PulumiRuntimeConfig -> PlannedOperation -> ByteString -> IO AdapterExecution
applySavedPlan config _ planBytes =
  withSystemTempDirectory "nagare-pulumi-inventory-apply" $ \temporary -> do
    let planPath = temporary </> "pulumi-plan.json"
    BS.writeFile planPath planBytes
    result <- runPulumiWithDeclarations config temporary ["up", "--plan", planPath, "--stack", T.unpack (runtimeStack config), "--yes", "--non-interactive"]
    pure $ case successful "Pulumi apply" result of
      Left err -> AdapterEffectAmbiguous err
      Right _ -> AdapterEffectCompleted

verifyResources :: PulumiRuntimeConfig -> PlannedOperation -> ByteString -> IO (Either Text ContentDigest)
verifyResources config operation planBytes =
  withSystemTempDirectory "nagare-pulumi-inventory-verify" $ \temporary -> do
    result <- runPulumiWithDeclarations config temporary ["preview", "--json", "--expect-no-changes", "--stack", T.unpack (runtimeStack config), "--non-interactive"]
    pure $ do
      output <- successful "Pulumi convergence preview" result
      pure (contentDigest (planBytes <> TE.encodeUtf8 (operationIdText (plannedOperationId operation)) <> TE.encodeUtf8 (T.pack output)))

recoverSavedPlan :: PulumiRuntimeConfig -> PlannedOperation -> ByteString -> IO RecoveryDecision
recoverSavedPlan config operation planBytes = do
  verified <- verifyResources config operation planBytes
  pure $ case verified of
    Right proof -> RecoveryProvedComplete proof
    Left err -> RecoveryUnresolved err

runPulumiWithDeclarations :: PulumiRuntimeConfig -> FilePath -> [String] -> IO (Either Text (ExitCode, String, String))
runPulumiWithDeclarations config temporary arguments = do
  let declarationPath = temporary </> "resource-declarations.json"
  BS.writeFile declarationPath (runtimeDeclarationBundle config)
  runPulumiWith config [("NAGARE_RESOURCE_DECLARATIONS", declarationPath)] arguments

runPulumi :: PulumiRuntimeConfig -> [String] -> IO (Either Text (ExitCode, String, String))
runPulumi config = runPulumiWith config []

runPulumiWith :: PulumiRuntimeConfig -> [(String, String)] -> [String] -> IO (Either Text (ExitCode, String, String))
runPulumiWith config additions arguments = do
  environment <- getEnvironment
  let names = map fst additions
      childEnvironment = additions <> filter ((`notElem` names) . fst) environment
      command = (proc (runtimePulumiExecutable config) (["-C", runtimePulumiDirectory config] <> arguments)) {env = Just childEnvironment}
  first (\(err :: IOException) -> "could not run Pulumi: " <> T.pack (show err)) <$> try (readCreateProcessWithExitCode command "")

successful :: Text -> Either Text (ExitCode, String, String) -> Either Text String
successful label result = do
  (status, output, errors) <- result
  case status of
    ExitSuccess -> Right output
    ExitFailure code -> Left (label <> " exited " <> T.pack (show code) <> ": " <> T.strip (T.pack (errors <> "\n" <> output)))

digestFromText :: Text -> Text -> IO ContentDigest
digestFromText label value = case mkContentDigest value of
  Left err -> ioError (userError (T.unpack ("invalid " <> label <> " digest: " <> err)))
  Right digest -> pure digest

decodePhysicalResources :: ByteString -> Either Text (Map Text PhysicalIdentity)
decodePhysicalResources bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  resources <- case value of
    Object root -> case KM.lookup "deployment" root of
      Just (Object deployment) -> case KM.lookup "resources" deployment of
        Just (Array entries) -> Right (toList entries)
        _ -> Left "Pulumi stack export has no deployment resources"
      _ -> Left "Pulumi stack export has no deployment"
    _ -> Left "Pulumi stack export is not an object"
  Map.fromList <$> traverse physical resources
  where
    physical value = first T.pack $ parseEither parser value
    parser = withObject "Pulumi stack resource" $ \resource -> do
      urn <- resource .: "urn"
      identifier <- resource .:? "id"
      identity <- either (fail . T.unpack) pure (mkPhysicalIdentity (fromMaybe urn identifier))
      pure (urn, identity)
