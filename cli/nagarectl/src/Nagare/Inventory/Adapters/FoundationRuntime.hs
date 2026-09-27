-- | gcloud observations and guarded effects for the reviewed foundation plan.
module Nagare.Inventory.Adapters.FoundationRuntime
  ( GcloudRunner (..)
  , realGcloudRunner
  , mkFoundationRuntimeOps
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
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
import Nagare.Resource.Types
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data GcloudRunner = GcloudRunner
  { gcloudCapture :: !([String] -> IO (Either Text ByteString))
  , gcloudEffect :: !([String] -> IO (Either Text ()))
  }

realGcloudRunner :: GcloudRunner
realGcloudRunner = GcloudRunner capture effect
  where
    capture args = do
      result <- try (readProcessWithExitCode "gcloud" args "")
      pure $ case result of
        Left (err :: IOException) -> Left ("could not run gcloud: " <> T.pack (show err))
        Right (ExitFailure code, _, stderr) -> Left
          ("gcloud failed (exit " <> T.pack (show code) <> "): " <> T.pack stderr)
        Right (ExitSuccess, stdout, _) -> Right (BC.pack stdout)
    effect args = fmap (fmap (const ())) (capture args)

mkFoundationRuntimeOps :: GcloudRunner -> FoundationAdapterOps
mkFoundationRuntimeOps runner = FoundationAdapterOps
  { foundationInspect = inspectTarget runner
  , foundationMutate = mutateTarget runner
  }

inspectTarget :: GcloudRunner -> FoundationTarget -> IO FoundationObservation
inspectTarget runner target = case target of
  FoundationBucket project bucket location member -> inspectBucket runner project bucket location member
  FoundationService project service -> inspectService runner project service

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
          FoundationAbsent _ -> runCommand runner commands 0
          _ -> pure (Right ())
        case created of
          Left err -> pure (AdapterEffectAmbiguous err)
          Right () -> do
            owner <- bucketOwnerMatches runner project bucket
            case owner of
              Left err -> pure (AdapterEffectAmbiguous err)
              Right () -> do
                updated <- runCommand runner commands 1
                case updated of
                  Left err -> pure (AdapterEffectAmbiguous err)
                  Right () -> do
                    granted <- if length commands == 3
                      then runCommand runner commands 2 else pure (Right ())
                    pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) granted)
  target@(FoundationService _ _) -> do
    state <- inspectTarget runner target
    case state of
      FoundationPresent _ digest | digest == foundationTargetDigest target -> pure AdapterEffectCompleted
      FoundationAbsent _ -> do
        result <- runCommand runner (foundationPlanCommands plan) 0
        pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) result)
      FoundationForeign _ err -> pure (AdapterEffectAmbiguous err)
      FoundationUnavailable err -> pure (AdapterEffectAmbiguous err)
      _ -> pure (AdapterEffectAmbiguous "cloud service observation changed")

runCommand :: GcloudRunner -> [[Text]] -> Int -> IO (Either Text ())
runCommand runner commands commandIndex = case drop commandIndex commands of
  (("gcloud" : args) : _) -> gcloudEffect runner (map T.unpack args)
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
