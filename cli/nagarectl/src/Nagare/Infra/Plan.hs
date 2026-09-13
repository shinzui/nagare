{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure parsing and classification for the instance-replacement preflight.
-- Process execution stays in @app/Main.hs@ so fixtures can exercise every
-- decision without Pulumi, credentials, or a cloud stack.
module Nagare.Infra.Plan
  ( StepOp (..)
  , PlanStep (..)
  , PlanVerdict (..)
  , gceInstanceType
  , dnsManagedZoneType
  , storageBucketType
  , protectedResourceTypes
  , parsePreview
  , previewErrors
  , classifyPlan
  , renderVerdict
  )
where

import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

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
    opToken (OpReplaceLike token) = token
    opToken OpSame = "same"
    opToken OpCreate = "create"
    opToken OpUpdate = "update"
    opToken OpDelete = "delete"
    opToken OpRefresh = "refresh"
    opToken OpImport = "import"
