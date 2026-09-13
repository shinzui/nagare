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
  , parsePreview
  , classifyPlan
  , renderVerdict
  ) where

import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?), (.!=))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T

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
  { psOp :: !StepOp
  , psUrn :: !Text
  , psReplaceReasons :: ![Text]
  }
  deriving stock (Eq, Show)

data PlanVerdict = PlanAllowed | PlanReplacesInstance ![PlanStep]
  deriving stock (Eq, Show)

-- | Pulumi's type token for the resource created in
-- @infra\/pulumi\/src\/components\/NagareInstance.ts@. Component ancestry makes
-- the complete URN longer, so 'classifyPlan' searches for this substring.
gceInstanceType :: Text
gceInstanceType = "gcp:compute/instance:Instance"

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

classifyPlan :: Text -> [PlanStep] -> PlanVerdict
classifyPlan instanceType steps =
  case filter replacesInstance steps of
    [] -> PlanAllowed
    replacing -> PlanReplacesInstance replacing
  where
    replacesInstance step = case psOp step of
      OpReplaceLike _ -> instanceType `T.isInfixOf` psUrn step
      _ -> False

renderVerdict :: Text -> PlanVerdict -> Text
renderVerdict _ PlanAllowed = "infra guard: no GCE instance replacement is planned\n"
renderVerdict instanceName (PlanReplacesInstance steps) =
  T.unlines
    ( [ "REFUSING TO APPLY: Pulumi plans to replace GCE instance '" <> instanceName <> "'."
      , "Replacement steps:"
      ]
        <> map renderStep steps
        <> [ ""
           , "Replacing the instance destroys its boot disk and the k3s cluster datastore under /var/lib/rancher."
           , "That loses every Knative and cert-manager object, every TLS certificate already issued, and the ACME account key."
           , "Recovery requires re-bootstrapping the cluster and re-issuing certificates."
           , "The separately protected data disk at /var/lib/nagare survives."
           , "A machine-type change is an in-place resize and does not need this override."
           , "For a deliberate rebuild, first read docs/runbooks/disaster-recovery.md, then run:"
           , "  NAGARE_ALLOW_VM_REPLACEMENT=1 nagare infra-up"
           ]
    )
  where
    renderStep step =
      "  - "
        <> resourceName (psUrn step)
        <> " (operation: "
        <> opToken (psOp step)
        <> "; reasons: "
        <> reasons (psReplaceReasons step)
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
