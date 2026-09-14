{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure parsing and classification for the instance-replacement preflight.
-- Process execution stays in @app/Main.hs@ so fixtures can exercise every
-- decision without Pulumi, credentials, or a cloud stack.
module Nagare.Infra.Plan
  ( StepOp (..)
  , PlanStep (..)
  , PlanVerdict (..)
  , SavedPlanReview (..)
  , SavedPlanMetadata (..)
  , CurrentInfraIdentity (..)
  , PlanBindingError (..)
  , gceInstanceType
  , dnsManagedZoneType
  , storageBucketType
  , protectedResourceTypes
  , parsePreview
  , previewErrors
  , classifyPlan
  , renderVerdict
  , reviewVerdict
  , verifySavedPlan
  , renderPlanBindingError
  , digestBytes
  , digestFile
  , digestPulumiProgram
  )
where

import Crypto.Hash (Context, Digest, SHA256, hash, hashFinalize, hashInit, hashUpdate)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (Context)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (makeRelative, takeFileName, (</>))

data StepOp
  = OpSame
  | OpCreate
  | OpUpdate
  | OpDelete
  | OpRefresh
  | OpImport
  | OpReplaceLike Text
  deriving stock (Eq, Show)

data PlanStep = PlanStep
  { op :: !StepOp
  , urn :: !Text
  , replaceReasons :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

data PlanVerdict = PlanAllowed | PlanReplacesProtected ![PlanStep]
  deriving stock (Eq, Show)

-- | The redacted, reviewable result produced by the same Pulumi process that
-- writes @pulumi-plan.json@. It contains operation names, URNs, and replacement
-- reasons, but never resource inputs or decrypted configuration values.
data SavedPlanReview = SavedPlanReview
  { reviewSchemaVersion :: !Int
  , replacementApproved :: !Bool
  , steps :: ![PlanStep]
  }
  deriving stock (Generic, Eq, Show)

-- | Nagare-owned bindings beside Pulumi's opaque deployment plan. Pulumi
-- constrains resource operations; these fields additionally constrain which
-- Nagare context, backend, program, configuration, and payload may apply it.
data SavedPlanMetadata = SavedPlanMetadata
  { metadataSchemaVersion :: !Int
  , context :: !Text
  , project :: !Text
  , stack :: !Text
  , backend :: !Text
  , payloadId :: !Text
  , payloadDigest :: !Text
  , programDigest :: !Text
  , configDigest :: !Text
  , pulumiVersion :: !Text
  , createdAt :: !Text
  , planDigest :: !Text
  , reviewDigest :: !Text
  }
  deriving stock (Generic, Eq, Show)

data CurrentInfraIdentity = CurrentInfraIdentity
  { currentContext :: !Text
  , currentProject :: !Text
  , currentStack :: !Text
  , currentBackend :: !Text
  , currentPayloadId :: !Text
  , currentPayloadDigest :: !Text
  , currentProgramDigest :: !Text
  , currentConfigDigest :: !Text
  , currentPulumiVersion :: !Text
  }
  deriving stock (Generic, Eq, Show)

data PlanBindingError
  = UnsupportedSavedPlanSchema !Int
  | PlanBindingMismatch !Text !Text !Text
  deriving stock (Eq, Show)

instance ToJSON StepOp where
  toJSON = Aeson.String . stepOpToken

instance FromJSON StepOp where
  parseJSON = Aeson.withText "Pulumi operation" (either (fail . T.unpack) pure . parseStepOp)

instance ToJSON PlanStep where
  toJSON step =
    Aeson.object
      [ "op" Aeson..= (step ^. #op)
      , "urn" Aeson..= (step ^. #urn)
      , "replaceReasons" Aeson..= (step ^. #replaceReasons)
      ]

instance ToJSON SavedPlanReview where
  toJSON review =
    Aeson.object
      [ "schemaVersion" Aeson..= (review ^. #reviewSchemaVersion)
      , "replacementApproved" Aeson..= (review ^. #replacementApproved)
      , "verdict" Aeson..= verdictToken (reviewVerdict review)
      , "steps" Aeson..= (review ^. #steps)
      ]

instance FromJSON SavedPlanReview where
  parseJSON = withObject "SavedPlanReview" $ \o ->
    SavedPlanReview <$> o .: "schemaVersion" <*> o .: "replacementApproved" <*> o .: "steps"

instance ToJSON SavedPlanMetadata where
  toJSON metadata =
    Aeson.object
      [ "schemaVersion" Aeson..= (metadata ^. #metadataSchemaVersion)
      , "context" Aeson..= (metadata ^. #context)
      , "project" Aeson..= (metadata ^. #project)
      , "stack" Aeson..= (metadata ^. #stack)
      , "backend" Aeson..= (metadata ^. #backend)
      , "payloadId" Aeson..= (metadata ^. #payloadId)
      , "payloadDigest" Aeson..= (metadata ^. #payloadDigest)
      , "programDigest" Aeson..= (metadata ^. #programDigest)
      , "configDigest" Aeson..= (metadata ^. #configDigest)
      , "pulumiVersion" Aeson..= (metadata ^. #pulumiVersion)
      , "createdAt" Aeson..= (metadata ^. #createdAt)
      , "planDigest" Aeson..= (metadata ^. #planDigest)
      , "reviewDigest" Aeson..= (metadata ^. #reviewDigest)
      ]

instance FromJSON SavedPlanMetadata where
  parseJSON = withObject "SavedPlanMetadata" $ \o ->
    SavedPlanMetadata
      <$> o .: "schemaVersion"
      <*> o .: "context"
      <*> o .: "project"
      <*> o .: "stack"
      <*> o .: "backend"
      <*> o .: "payloadId"
      <*> o .: "payloadDigest"
      <*> o .: "programDigest"
      <*> o .: "configDigest"
      <*> o .: "pulumiVersion"
      <*> o .: "createdAt"
      <*> o .: "planDigest"
      <*> o .: "reviewDigest"

-- | Pulumi's type token for the resource created in
-- @infra\/pulumi\/src\/components\/NagareInstance.ts@. Component ancestry makes
-- the complete URN longer, so 'classifyPlan' searches for this substring.
gceInstanceType :: Text
gceInstanceType = "gcp:compute/instance:Instance"

-- | EP-121: the zone's @dnsName@ is create-only, so a base-domain change replaces
-- it and Cloud DNS assigns new name servers, breaking the parent delegation.
dnsManagedZoneType :: Text
dnsManagedZoneType = "gcp:dns/managedZone:ManagedZone"

-- | EP-121: replacing a bucket deletes the old one and every object in it.
storageBucketType :: Text
storageBucketType = "gcp:storage/bucket:Bucket"

-- | Resources whose replacement destroys state or an external contract.
protectedResourceTypes :: [Text]
protectedResourceTypes = [gceInstanceType, dnsManagedZoneType, storageBucketType]

newtype Preview = Preview [PlanStep]

instance FromJSON Preview where
  parseJSON = withObject "Pulumi preview" $ \obj -> Preview <$> obj .:? "steps" .!= []

instance FromJSON PlanStep where
  parseJSON = withObject "Pulumi preview step" $ \obj -> do
    opToken <- obj .: "op"
    op <- either (fail . T.unpack) pure (parseStepOp opToken)
    PlanStep op <$> obj .: "urn" <*> obj .:? "replaceReasons" .!= []

parseStepOp :: Text -> Either Text StepOp
parseStepOp token = case token of
  "same" -> Right OpSame
  "create" -> Right OpCreate
  "update" -> Right OpUpdate
  "delete" -> Right OpDelete
  "refresh" -> Right OpRefresh
  "import" -> Right OpImport
  "replace" -> replacement
  "create-replacement" -> replacement
  "delete-replaced" -> replacement
  "read-replacement" -> replacement
  "import-replacement" -> replacement
  "discard-replaced" -> replacement
  _ -> Left ("unknown Pulumi preview operation '" <> token <> "'; refusing to classify the plan")
  where
    replacement = Right (OpReplaceLike token)

stepOpToken :: StepOp -> Text
stepOpToken (OpReplaceLike token) = token
stepOpToken OpSame = "same"
stepOpToken OpCreate = "create"
stepOpToken OpUpdate = "update"
stepOpToken OpDelete = "delete"
stepOpToken OpRefresh = "refresh"
stepOpToken OpImport = "import"

parsePreview :: ByteString -> Either Text [PlanStep]
parsePreview bytes = case eitherDecodeStrict bytes of
  Left err -> Left (T.pack err)
  Right (Preview steps) -> Right steps

-- | Error diagnostics from a failed @pulumi preview --json@. Pulumi reports
-- program failures there, often with nothing on stderr.
previewErrors :: ByteString -> [Text]
previewErrors bytes = case eitherDecodeStrict bytes of
  Right (PreviewDiagnostics diagnostics) -> [T.strip message | Diagnostic "error" message <- diagnostics]
  Left _ -> []

data Diagnostic = Diagnostic !Text !Text

instance FromJSON Diagnostic where
  parseJSON = withObject "Pulumi diagnostic" $ \obj ->
    Diagnostic <$> obj .:? "severity" .!= "" <*> obj .:? "message" .!= ""

newtype PreviewDiagnostics = PreviewDiagnostics [Diagnostic]

instance FromJSON PreviewDiagnostics where
  parseJSON = withObject "Pulumi preview" $ \obj -> PreviewDiagnostics <$> obj .:? "diagnostics" .!= []

classifyPlan :: [Text] -> [PlanStep] -> PlanVerdict
classifyPlan protectedTypes steps =
  case filter replacesProtected steps of
    [] -> PlanAllowed
    replacing -> PlanReplacesProtected replacing
  where
    replacesProtected step = case (step ^. #op) of
      OpReplaceLike _ -> any (`T.isInfixOf` (step ^. #urn)) protectedTypes
      _ -> False

reviewVerdict :: SavedPlanReview -> PlanVerdict
reviewVerdict = classifyPlan protectedResourceTypes . (^. #steps)

verdictToken :: PlanVerdict -> Text
verdictToken PlanAllowed = "allowed"
verdictToken (PlanReplacesProtected _) = "protected-replacement"

verifySavedPlan :: CurrentInfraIdentity -> SavedPlanMetadata -> Either PlanBindingError ()
verifySavedPlan current metadata
  | metadata ^. #metadataSchemaVersion /= 1 = Left (UnsupportedSavedPlanSchema (metadata ^. #metadataSchemaVersion))
  | otherwise = traverse_ matches bindings
  where
    bindings =
      [ ("context", current ^. #currentContext, metadata ^. #context)
      , ("project", current ^. #currentProject, metadata ^. #project)
      , ("stack", current ^. #currentStack, metadata ^. #stack)
      , ("backend", current ^. #currentBackend, metadata ^. #backend)
      , ("payloadId", current ^. #currentPayloadId, metadata ^. #payloadId)
      , ("payloadDigest", current ^. #currentPayloadDigest, metadata ^. #payloadDigest)
      , ("programDigest", current ^. #currentProgramDigest, metadata ^. #programDigest)
      , ("configDigest", current ^. #currentConfigDigest, metadata ^. #configDigest)
      , ("pulumiVersion", current ^. #currentPulumiVersion, metadata ^. #pulumiVersion)
      ]
    matches (field, observed, saved)
      | observed == saved = Right ()
      | otherwise = Left (PlanBindingMismatch field saved observed)

renderPlanBindingError :: PlanBindingError -> Text
renderPlanBindingError (UnsupportedSavedPlanSchema version) =
  "saved plan uses unsupported metadata schema " <> T.pack (show version)
renderPlanBindingError (PlanBindingMismatch field saved observed) =
  "saved plan " <> field <> " is '" <> saved <> "', but the current value is '" <> observed <> "'"

digestBytes :: ByteString -> Text
digestBytes bytes = T.pack (show (hash bytes :: Digest SHA256))

digestFile :: FilePath -> IO Text
digestFile path = digestBytes <$> BS.readFile path

-- | Hash the stable Pulumi program inputs. Generated dependencies, Pulumi's
-- working directories, and context-owned @Pulumi.<stack>.yaml@ links are
-- excluded; the latter is hashed separately as @configDigest@.
digestPulumiProgram :: FilePath -> IO Text
digestPulumiProgram root = do
  files <- sort <$> filesBelow root
  context <- foldHash (hashInit :: Context SHA256) files
  pure (T.pack (show (hashFinalize context :: Digest SHA256)))
  where
    ignoredDirectory name = name `elem` ["node_modules", ".pulumi", ".pulumi-home", ".pulumi-state"]
    ignoredFile name = "Pulumi." `isPrefixOf` name && ".yaml" `isSuffixOf` name
    filesBelow path = do
      let name = takeFileName path
      link <- pathIsSymbolicLink path
      if link || ignoredDirectory name || ignoredFile name
        then pure []
        else do
          file <- doesFileExist path
          if file
            then pure [path]
            else do
              directory <- doesDirectoryExist path
              if directory
                then do
                  names <- listDirectory path
                  concat <$> traverse (filesBelow . (path </>)) names
                else pure []
    foldHash context [] = pure context
    foldHash context (path : rest) = do
      bytes <- BS.readFile path
      let relative = TE.encodeUtf8 (T.pack (makeRelative root path))
          separator = BS.singleton 0
          next = hashUpdate (hashUpdate (hashUpdate context relative) separator) bytes
      foldHash (hashUpdate next separator) rest

renderVerdict :: Text -> PlanVerdict -> Text
renderVerdict _ PlanAllowed = "infra guard: no GCE instance replacement is planned (DNS zone and buckets also unchanged)\n"
renderVerdict instanceName (PlanReplacesProtected steps) =
  T.unlines
    ( [ "REFUSING TO APPLY: Pulumi plans to replace a protected resource."
      , "Replacement steps:"
      ]
        <> map renderStep steps
        <> consequences gceInstanceType instanceConsequences
        <> consequences dnsManagedZoneType zoneConsequences
        <> consequences storageBucketType bucketConsequences
        <> [ ""
           , "For a deliberate rebuild, first read docs/runbooks/disaster-recovery.md, then run:"
           , "  NAGARE_ALLOW_VM_REPLACEMENT=1 nagare infra-up"
           ]
    )
  where
    consequences resourceType lines'
      | any ((resourceType `T.isInfixOf`) . (^. #urn)) steps = "" : lines'
      | otherwise = []
    instanceConsequences =
      [ "Replacing GCE instance '" <> instanceName <> "' destroys its boot disk and the k3s cluster datastore under /var/lib/rancher."
      , "That loses every Knative and cert-manager object, every TLS certificate already issued, and the ACME account key."
      , "Recovery requires re-bootstrapping the cluster and re-issuing certificates."
      , "The separately protected data disk at /var/lib/nagare survives."
      , "A machine-type change is an in-place resize and does not need this override."
      ]
    zoneConsequences =
      [ "Replacing the Cloud DNS managed zone assigns new name servers."
      , "The parent domain's NS delegation then points at name servers that no longer serve it, so DNS and certificate issuance break."
      , "A base-domain change (NAGARE_BASE_DOMAIN) is the usual cause; check the context before overriding."
      ]
    bucketConsequences =
      [ "Replacing a storage bucket deletes the existing bucket and every object in it, including images or backups."
      ]
    renderStep step =
      "  - "
        <> resourceName (step ^. #urn)
        <> " (operation: "
        <> opToken (step ^. #op)
        <> "; reasons: "
        <> reasons (step ^. #replaceReasons)
        <> ")"
    resourceName urn = case reverse (T.splitOn "::" urn) of
      name : _ -> name
      [] -> urn
    reasons [] = "not reported by Pulumi"
    reasons xs = T.intercalate ", " xs
    opToken = stepOpToken
