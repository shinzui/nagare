-- | gcloud observations and guarded effects for the reviewed foundation plan.
module Nagare.Inventory.Adapters.FoundationRuntime
  ( GcloudRunner (..)
  , realGcloudRunner
  , mkFoundationRuntimeOps
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..))
import Nagare.Inventory.Adapters.Foundation
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Ops.PulumiBackend
  ( bucketProjectNumberArgs, projectNumberArgs )
import Nagare.Platform.StackConfig (linkContextStackConfig)
import Nagare.Resource.Types
import Nagare.Target (mkContextName)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

data GcloudRunner = GcloudRunner
  { gcloudCapture :: !([String] -> IO (Either Text ByteString))
  , gcloudEffect :: !([String] -> IO (Either Text ()))
  , pulumiCapture :: !(FoundationTarget -> [String] -> IO (Either Text ByteString))
  , pulumiEffect :: !(FoundationTarget -> [String] -> IO (Either Text ()))
  }

realGcloudRunner :: GcloudRunner
realGcloudRunner = GcloudRunner capture effect capturePulumi effectPulumi
  where
    capture args = do
      result <- try (readProcessWithExitCode "gcloud" args "")
      pure $ case result of
        Left (err :: IOException) -> Left ("could not run gcloud: " <> T.pack (show err))
        Right (ExitFailure code, _, stderr) -> Left
          ("gcloud failed (exit " <> T.pack (show code) <> "): " <> T.pack stderr)
        Right (ExitSuccess, stdout, _) -> Right (BC.pack stdout)
    effect args = fmap (fmap (const ())) (capture args)
    capturePulumi target args = case target of
      FoundationStack _ stack backend _ home _ _ -> do
        inherited <- getEnvironment
        let overrides =
              [("PULUMI_HOME", home), ("PULUMI_BACKEND_URL", T.unpack backend),
               ("PULUMI_CONFIG_PASSPHRASE_FILE", home </> "passphrase"),
               ("NAGARE_PULUMI_STACK", T.unpack (nameText stack))]
            variables = overrides <> filter (\(key, value) ->
              key `notElem` map fst overrides
                && (key /= "PULUMI_CONFIG_PASSPHRASE" || not (null value))) inherited
            command = (proc "pulumi" args) {env = Just variables}
        result <- try (readCreateProcessWithExitCode command "")
        pure $ case result of
          Left (err :: IOException) -> Left ("could not run Pulumi: " <> T.pack (show err))
          Right (ExitFailure code, _, stderr) -> Left
            ("Pulumi failed (exit " <> T.pack (show code) <> "): " <> T.pack stderr)
          Right (ExitSuccess, stdout, _) -> Right (TE.encodeUtf8 (T.pack stdout))
      _ -> pure (Left "Pulumi command has no reviewed stack target")
    effectPulumi target args = fmap (fmap (const ())) (capturePulumi target args)

mkFoundationRuntimeOps :: GcloudRunner -> FoundationAdapterOps
mkFoundationRuntimeOps runner = FoundationAdapterOps
  { foundationInspect = inspectTarget runner
  , foundationMutate = mutateTarget runner
  }

inspectTarget :: GcloudRunner -> FoundationTarget -> IO FoundationObservation
inspectTarget runner target = case target of
  FoundationBucket project bucket location member -> inspectBucket runner project bucket location member
  FoundationService project service -> inspectService runner project service
  FoundationStack {} -> inspectStack runner target

inspectBucket :: GcloudRunner -> Name -> Name -> Name -> Maybe Text -> IO FoundationObservation
inspectBucket runner project bucket location member = do
  targetNumber <- readNumber runner (projectNumberArgs (nameText project))
  listed <- gcloudCapture runner
    ["storage", "buckets", "list", "--project=" <> T.unpack (nameText project), "--format=json(name)"]
  case (targetNumber, listed >>= decodeBucketNames) of
    (Left err, _) -> pure (FoundationUnavailable err)
    (_, Left err) -> pure (FoundationUnavailable err)
    (Right number, Right names)
      | nameText bucket `notElem` names -> pure (FoundationAbsent
          (contentDigest (TE.encodeUtf8 (nameText project <> ":" <> number <> ":" <> nameText bucket <> ":absent"))))
      | otherwise -> do
          described <- gcloudCapture runner
            ["storage", "buckets", "describe", "gs://" <> T.unpack (nameText bucket),
             "--raw", "--format=json"]
          case described >>= decodeBucketState of
            Left err -> pure (FoundationUnavailable err)
            Right state
              | bucketOwner state /= number -> pure (FoundationForeign
                  (physicalBucket bucket) "bucket belongs to another project")
              | otherwise -> do
                  membership <- case member of
                    Nothing -> pure (Right True)
                    Just value -> bucketMemberPresent runner bucket value
                  pure $ case membership of
                    Left err -> FoundationUnavailable err
                    Right hasMember -> FoundationPresent (physicalBucket bucket)
                      (if bucketConverged location state && hasMember
                        then foundationTargetDigest (FoundationBucket project bucket location member)
                        else contentDigest (bucketRaw state))

inspectService :: GcloudRunner -> Name -> Name -> IO FoundationObservation
inspectService runner project service = do
  projectNumber <- readNumber runner (projectNumberArgs (nameText project))
  listed <- gcloudCapture runner
    ["services", "list", "--enabled", "--project=" <> T.unpack (nameText project), "--format=json"]
  pure $ case (projectNumber, listed >>= decodeServiceNames) of
    (Left err, _) -> FoundationUnavailable err
    (_, Left err) -> FoundationUnavailable err
    (Right number, Right names)
      | nameText service `elem` names -> FoundationPresent
          (physicalService project service)
          (foundationTargetDigest (FoundationService project service))
      | otherwise -> FoundationAbsent (contentDigest
          (TE.encodeUtf8 (nameText project <> ":" <> number <> ":" <> nameText service <> ":disabled")))

inspectStack :: GcloudRunner -> FoundationTarget -> IO FoundationObservation
inspectStack runner target@(FoundationStack project stack backend pulumiDir _ backendBucket config) = do
  ready <- case backendBucket of
    Nothing -> case T.stripPrefix "file://" backend of
      Nothing -> pure (Left "reviewed Pulumi stack has an unsupported backend URL")
      Just path -> do
        exists <- doesDirectoryExist (T.unpack path)
        pure (Right exists)
    Just bucket -> do
      number <- readNumber runner (projectNumberArgs (nameText project))
      listed <- gcloudCapture runner
        ["storage", "buckets", "list", "--project=" <> T.unpack (nameText project),
         "--format=json(name)"]
      case (number, listed >>= decodeBucketNames) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right _, Right names) | nameText bucket `notElem` names -> pure (Right False)
        _ -> fmap (fmap (const True)) (bucketOwnerMatches runner project bucket)
  case ready of
    Left err -> pure (FoundationUnavailable err)
    Right False -> pure (FoundationAbsent (stackAbsenceProof target))
    Right True -> do
      listed <- pulumiCapture runner target
        ["-C", pulumiDir, "stack", "ls", "--json", "--project=nagare"]
      case listed >>= decodeStackNames of
        Left err -> pure (FoundationUnavailable err)
        Right names
          | nameText stack `notElem` names
              && ("nagare/" <> nameText stack) `notElem` names ->
              pure (FoundationAbsent (stackAbsenceProof target))
          | otherwise -> do
              values <- pulumiCapture runner target
                ["-C", pulumiDir, "config", "--json", "--stack", T.unpack (nameText stack)]
              pure $ case values >>= configMatches config of
                Left err -> FoundationUnavailable err
                Right True -> FoundationPresent (physicalStack target) (foundationTargetDigest target)
                Right False -> FoundationPresent (physicalStack target)
                  (contentDigest (either (const BC.empty) id values))
inspectStack _ _ = pure (FoundationUnavailable "reviewed Pulumi stack target is invalid")

stackAbsenceProof :: FoundationTarget -> ContentDigest
stackAbsenceProof target = contentDigest (TE.encodeUtf8
  ("pulumi-stack-absent:" <> T.pack (show (foundationTargetDigest target))))

decodeStackNames :: ByteString -> Either Text [Text]
decodeStackNames bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  first T.pack (parseEither (withArray "Pulumi stack list" (traverse one . toList)) value)
  where
    one = withObject "Pulumi stack" (.: "name")

configMatches :: [(Text, Text)] -> ByteString -> Either Text Bool
configMatches expected bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  first T.pack (parseEither parser value)
  where
    parser = withObject "Pulumi config" $ \config ->
      and <$> traverse (one config) expected
    one config (key, wanted) = do
      entry <- config .:? AesonKey.fromText key
      case entry of
        Nothing -> pure False
        Just value -> withObject "Pulumi config entry" (\entryObject -> do
          actual <- entryObject .:? "value"
          secret <- entryObject .:? "secret"
          pure (actual == Just wanted && secret == Just False)) value

physicalStack :: FoundationTarget -> PhysicalIdentity
physicalStack (FoundationStack _ stack backend _ _ _ _) = either (error . T.unpack) id
  (mkPhysicalIdentity ("pulumi-stack:" <> backend <> "/" <> nameText stack))
physicalStack _ = error "physicalStack requires a stack target"

mutateTarget :: GcloudRunner -> FoundationNativePlan -> IO AdapterExecution
mutateTarget runner plan = case foundationPlanTarget plan of
  target@(FoundationBucket project bucket _ _) -> do
    state <- inspectTarget runner target
    case state of
      FoundationForeign _ err -> pure (AdapterEffectAmbiguous err)
      FoundationUnavailable err -> pure (AdapterEffectAmbiguous err)
      FoundationPresent _ digest | digest == foundationTargetDigest target -> pure AdapterEffectCompleted
      _ -> do
        let commands = foundationPlanCommands plan
        created <- case state of
          FoundationAbsent _ -> runCommand runner target commands 0
          _ -> pure (Right ())
        case created of
          Left err -> pure (AdapterEffectAmbiguous err)
          Right () -> do
            owner <- bucketOwnerMatches runner project bucket
            case owner of
              Left err -> pure (AdapterEffectAmbiguous err)
              Right () -> do
                updated <- runCommand runner target commands 1
                case updated of
                  Left err -> pure (AdapterEffectAmbiguous err)
                  Right () -> do
                    granted <- if length commands == 3
                      then runCommand runner target commands 2 else pure (Right ())
                    pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) granted)
  target@(FoundationService _ _) -> do
    state <- inspectTarget runner target
    case state of
      FoundationPresent _ digest | digest == foundationTargetDigest target -> pure AdapterEffectCompleted
      FoundationAbsent _ -> do
        result <- runCommand runner target (foundationPlanCommands plan) 0
        pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) result)
      FoundationForeign _ err -> pure (AdapterEffectAmbiguous err)
      FoundationUnavailable err -> pure (AdapterEffectAmbiguous err)
      _ -> pure (AdapterEffectAmbiguous "cloud service observation changed")
  target@(FoundationStack _ _ _ _ _ _ _) -> do
    state <- inspectTarget runner target
    case state of
      FoundationPresent _ digest | digest == foundationTargetDigest target ->
        pure AdapterEffectCompleted
      FoundationForeign _ err -> pure (AdapterEffectAmbiguous err)
      FoundationUnavailable err -> pure (AdapterEffectAmbiguous err)
      _ -> do
        prepared <- prepareStackLocal target
        case prepared of
          Left err -> pure (AdapterEffectAmbiguous err)
          Right () -> do
            created <- case state of
              FoundationAbsent _ -> runCommand runner target (foundationPlanCommands plan) 0
              _ -> pure (Right ())
            case created of
              Left err -> pure (AdapterEffectAmbiguous err)
              Right () -> do
                configured <- runRemainingCommands runner target (foundationPlanCommands plan) 1
                pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted)
                  configured)

runRemainingCommands :: GcloudRunner -> FoundationTarget -> [[Text]] -> Int -> IO (Either Text ())
runRemainingCommands runner target commands commandIndex
  | commandIndex >= length commands = pure (Right ())
  | otherwise = do
      result <- runCommand runner target commands commandIndex
      case result of
        Left err -> pure (Left err)
        Right () -> runRemainingCommands runner target commands (commandIndex + 1)

prepareStackLocal :: FoundationTarget -> IO (Either Text ())
prepareStackLocal (FoundationStack _ stack backend pulumiDir home _ _) = do
  case mkContextName (nameText stack) of
    Left err -> pure (Left err)
    Right context -> do
      linked <- linkContextStackConfig context pulumiDir
      case linked of
        Left err -> pure (Left err)
        Right _ -> do
          created <- try $ do
            createDirectoryIfMissing True home
            case T.stripPrefix "file://" backend of
              Just path -> createDirectoryIfMissing True (T.unpack path)
              Nothing -> pure ()
            let passphrase = home </> "passphrase"
            exists <- doesFileExist passphrase
            unless exists (writeFile passphrase "")
          pure (first (\(err :: IOException) -> T.pack (show err)) created)
prepareStackLocal _ = pure (Left "reviewed Pulumi stack target is invalid")

runCommand :: GcloudRunner -> FoundationTarget -> [[Text]] -> Int -> IO (Either Text ())
runCommand runner target commands commandIndex = case drop commandIndex commands of
  (("gcloud" : args) : _) -> gcloudEffect runner (map T.unpack args)
  (("pulumi" : args) : _) -> pulumiEffect runner target (map T.unpack args)
  _ -> pure (Left "reviewed foundation command is missing")

bucketOwnerMatches :: GcloudRunner -> Name -> Name -> IO (Either Text ())
bucketOwnerMatches runner project bucket = do
  target <- readNumber runner (projectNumberArgs (nameText project))
  actual <- readNumber runner (bucketProjectNumberArgs (nameText bucket))
  pure $ do
    targetNumber <- target
    bucketNumber <- actual
    unless (targetNumber == bucketNumber) (Left "bucket belongs to another project")

readNumber :: GcloudRunner -> [String] -> IO (Either Text Text)
readNumber runner args = do
  output <- gcloudCapture runner args
  pure $ do
    bytes <- output
    value <- first (const "gcloud project number is not UTF-8") (TE.decodeUtf8' bytes)
    let trimmed = T.strip value
    unless (not (T.null trimmed) && T.all (`elem` ['0' .. '9']) trimmed)
      (Left "gcloud returned no valid project number")
    pure trimmed

data BucketState = BucketState
  { bucketOwner :: !Text
  , bucketLocation :: !Text
  , bucketVersioning :: !Bool
  , bucketUniformAccess :: !Bool
  , bucketPublicAccessPrevention :: !Text
  , bucketRaw :: !ByteString
  }

decodeBucketState :: ByteString -> Either Text BucketState
decodeBucketState bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  first T.pack (parseEither parser value)
  where
    parser = withObject "bucket" $ \o -> do
      owner <- o .: "projectNumber"
      location <- o .: "location"
      versioningConfig <- o .:? "versioning"
      versioning <- maybe (pure False)
        (\configuration -> fromMaybe False <$> configuration .:? "enabled") versioningConfig
      iam <- o .:? "iamConfiguration"
      uniform <- case iam of
        Nothing -> pure False
        Just configuration -> do
          access <- configuration .:? "uniformBucketLevelAccess"
          maybe (pure False)
            (\value -> fromMaybe False <$> value .:? "enabled") access
      publicAccess <- maybe (pure "inherited")
        (\configuration -> fromMaybe "inherited" <$> configuration .:? "publicAccessPrevention") iam
      pure (BucketState owner location versioning uniform publicAccess bytes)

bucketConverged :: Name -> BucketState -> Bool
bucketConverged location state =
  T.toLower (bucketLocation state) == nameText location
    && bucketVersioning state
    && bucketUniformAccess state
    && T.toLower (bucketPublicAccessPrevention state) == "enforced"

decodeBucketNames :: ByteString -> Either Text [Text]
decodeBucketNames bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  first T.pack (parseEither (withArray "bucket list" (traverse one . toList)) value)
  where
    one = withObject "bucket" (.: "name")

decodeServiceNames :: ByteString -> Either Text [Text]
decodeServiceNames bytes = do
  value <- first T.pack (eitherDecodeStrict bytes)
  first T.pack (parseEither (withArray "service list" (traverse one . toList)) value)
  where
    one = withObject "service" $ \o -> do
      config <- o .: "config"
      config .: "name"

bucketMemberPresent :: GcloudRunner -> Name -> Text -> IO (Either Text Bool)
bucketMemberPresent runner bucket member = do
  output <- gcloudCapture runner
    ["storage", "buckets", "get-iam-policy", "gs://" <> T.unpack (nameText bucket), "--format=json"]
  pure $ do
    bytes <- output
    value <- first T.pack (eitherDecodeStrict bytes)
    first T.pack (parseEither (withObject "bucket policy" $ \o -> do
      bindings <- o .:? "bindings" .!= ([] :: [Value])
      pure (any (bindingHasMember member) bindings)) value)

bindingHasMember :: Text -> Value -> Bool
bindingHasMember member value = case parseEither parser value of
  Right True -> True
  _ -> False
  where
    parser = withObject "binding" $ \o -> do
      role <- o .: "role"
      members <- o .: "members"
      pure (role == ("roles/storage.objectAdmin" :: Text) && member `elem` (members :: [Text]))

physicalBucket :: Name -> PhysicalIdentity
physicalBucket bucket = either (error . T.unpack) id
  (mkPhysicalIdentity ("gs://" <> nameText bucket))

physicalService :: Name -> Name -> PhysicalIdentity
physicalService project service = either (error . T.unpack) id
  (mkPhysicalIdentity ("gcp-service:" <> nameText project <> ":" <> nameText service))
