-- | Pulumi saved-plan adapter for the common inventory protocol.
--
-- The prepared native bundle contains a canonical, redacted binding header
-- followed by Pulumi's opaque saved-plan bytes.  Apply therefore uses exactly
-- the bytes reviewed during preparation while the public review exposes only
-- operation classes and URNs.
module Nagare.Inventory.Adapters.Pulumi
  ( PulumiIdentity (..)
  , PulumiPreparation (..)
  , PulumiAdapterOps (..)
  , PulumiBundleError (..)
  , mkPulumiAdapter
  , validatePulumiPreparation
  )
where

import Control.Monad (forM_)
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding (op, (.=))
import Nagare.Infra.Plan (PlanStep (..), StepOp (..), parsePreview)
import Nagare.Inventory.Adapter
import Nagare.Inventory.Cloud
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory (Executor (PulumiExecutor))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data PulumiIdentity = PulumiIdentity
  { pulumiContext :: !Text
  , pulumiProject :: !Text
  , pulumiStack :: !Text
  , pulumiBackend :: !Text
  , pulumiPayloadId :: !Text
  , pulumiPayloadDigest :: !ContentDigest
  , pulumiProgramDigest :: !ContentDigest
  , pulumiConfigDigest :: !ContentDigest
  , pulumiToolVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)

data PulumiPreparation = PulumiPreparation
  { preparationIdentity :: !PulumiIdentity
  , preparationPreview :: !ByteString
  , preparationSavedPlan :: !ByteString
  , preparationRegistrations :: ![NativeRegistration]
  }
  deriving stock (Eq, Show)

data PulumiAdapterOps = PulumiAdapterOps
  { pulumiObserveResources :: !([ResourceId] -> IO (Either Text ObservationSet))
  , pulumiPrepareSavedPlan :: !(PlannedOperation -> IO (Either Text PulumiPreparation))
  , pulumiReadIdentity :: !(IO (Either Text PulumiIdentity))
  , pulumiApplySavedPlan :: !(PlannedOperation -> ByteString -> IO AdapterExecution)
  , pulumiVerifyResources :: !(PlannedOperation -> ByteString -> IO (Either Text ContentDigest))
  , pulumiRecoverSavedPlan :: !(PlannedOperation -> ByteString -> IO RecoveryDecision)
  }

data PulumiBundleHeader = PulumiBundleHeader
  { headerVersion :: !Int
  , headerOperation :: !OperationId
  , headerInputDigest :: !ContentDigest
  , headerIdentity :: !PulumiIdentity
  , headerPreviewDigest :: !ContentDigest
  , headerPlanDigest :: !ContentDigest
  , headerRegistrationsDigest :: !ContentDigest
  , headerSteps :: ![PlanStep]
  }
  deriving stock (Eq, Show, Generic)

data PulumiBundleError
  = PulumiRegistrationParity !(NonEmpty RegistrationParityError)
  | PulumiUnknownMutation !Text
  | PulumiResourceNotDeclared !ResourceId
  | PulumiActionMismatch !ResourceId !OperationAction !StepOp
  | PulumiResourceStepMissing !ResourceId
  | PulumiMalformedBundle !Text
  | PulumiBundleBindingChanged !Text
  deriving stock (Eq, Show, Generic)

mkPulumiAdapter :: [NativeRegistration] -> PulumiAdapterOps -> Adapter
mkPulumiAdapter declared ops =
  Adapter
    { adapterExecutor = PulumiExecutor
    , adapterIdentity = "pulumi-saved-plan"
    , adapterVersion = "1"
    , adapterObserve = pulumiObserveResources ops
    , adapterPrepare = prepare
    , adapterPreflight = preflight
    , adapterExecute = executePlan
    , adapterVerify = verifyPlan
    , adapterRecover = recoverPlan
    }
  where
    prepare operation = do
      prepared <- pulumiPrepareSavedPlan ops operation
      pure $ do
        preparation <- first (PrepareRefused (plannedOperationId operation)) prepared
        header <- first (PrepareRefused (plannedOperationId operation) . renderBundleError) (validatePulumiPreparation declared operation preparation)
        bytes <- first (PrepareRefused (plannedOperationId operation)) (encodePrepared header (preparationSavedPlan preparation))
        pure (PreparedNative bytes (renderSummary header))
    preflight operation prepared = do
      current <- pulumiReadIdentity ops
      pure $ do
        identity <- current
        (header, _) <- first renderBundleError (decodePrepared (preparedNativeBytes prepared))
        first renderBundleError (validateHeader operation identity header)
    executePlan operation prepared =
      case decodePrepared (preparedNativeBytes prepared) of
        Left err -> pure (AdapterEffectFailed (KnownNoEffect (renderBundleError err)))
        Right (_, planBytes) -> pulumiApplySavedPlan ops operation planBytes
    verifyPlan operation prepared = case decodePrepared (preparedNativeBytes prepared) of
      Left err -> pure (Left (renderBundleError err))
      Right (_, planBytes) -> pulumiVerifyResources ops operation planBytes
    recoverPlan operation prepared =
      case decodePrepared (preparedNativeBytes prepared) of
        Left err -> pure (RecoveryUnresolved (renderBundleError err))
        Right (_, planBytes) -> pulumiRecoverSavedPlan ops operation planBytes

validatePulumiPreparation :: [NativeRegistration] -> PlannedOperation -> PulumiPreparation -> Either PulumiBundleError PulumiBundleHeader
validatePulumiPreparation declared operation preparation = do
  first PulumiRegistrationParity (validateNativeRegistrationParity declared (preparationRegistrations preparation))
  steps <- first PulumiMalformedBundle (parsePreview (preparationPreview preparation))
  let byResource = Map.fromList [(registrationResource registration, registration) | registration <- declared]
      knownUrns = Set.fromList (map registrationPulumiUrn declared)
      mutating = filter (isMutation . op) steps
  forM_ mutating $ \step -> unless (Set.member (urn step) knownUrns) (Left (PulumiUnknownMutation (urn step)))
  forM_ (NE.toList (plannedResources operation)) $ \resource -> do
    registration <- maybe (Left (PulumiResourceNotDeclared resource)) Right (Map.lookup resource byResource)
    let resourceSteps = filter ((== registrationPulumiUrn registration) . urn) steps
    case resourceSteps of
      [] -> Left (PulumiResourceStepMissing resource)
      matches -> forM_ matches $ \step -> unless (actionMatches (plannedAction operation) (op step)) (Left (PulumiActionMismatch resource (plannedAction operation) (op step)))
  let registrationsBytes = either (error . T.unpack) id (canonicalValue (toJSON (sort declared)))
  pure
    PulumiBundleHeader
      { headerVersion = 1
      , headerOperation = plannedOperationId operation
      , headerInputDigest = plannedInputDigest operation
      , headerIdentity = preparationIdentity preparation
      , headerPreviewDigest = contentDigest (preparationPreview preparation)
      , headerPlanDigest = contentDigest (preparationSavedPlan preparation)
      , headerRegistrationsDigest = contentDigest registrationsBytes
      , headerSteps = steps
      }

isMutation :: StepOp -> Bool
isMutation OpSame = False
isMutation OpRefresh = False
isMutation _ = True

actionMatches :: OperationAction -> StepOp -> Bool
actionMatches CreateResource OpCreate = True
actionMatches AdoptResource OpImport = True
actionMatches UpdateResource OpUpdate = True
actionMatches UpdateResource OpReplaceLike {} = True
actionMatches RetireResource OpDelete = True
actionMatches RunDeclaredOperation _ = True
actionMatches _ OpSame = True
actionMatches _ OpRefresh = True
actionMatches _ _ = False

encodePrepared :: PulumiBundleHeader -> ByteString -> Either Text ByteString
encodePrepared header savedPlan = do
  unless (contentDigest savedPlan == headerPlanDigest header) (Left "Pulumi saved-plan digest changed during preparation")
  headerBytes <- canonicalValue (toJSON header)
  pure (headerBytes <> "\n" <> savedPlan)

decodePrepared :: ByteString -> Either PulumiBundleError (PulumiBundleHeader, ByteString)
decodePrepared bytes = do
  let (headerBytes, rest) = BS.break (== 10) bytes
  when (BS.null rest) (Left (PulumiMalformedBundle "prepared Pulumi bundle is missing its saved-plan separator"))
  header <- first (PulumiMalformedBundle . T.pack) (eitherDecodeStrict headerBytes)
  let savedPlan = BS.drop 1 rest
  unless (headerVersion header == 1) (Left (PulumiMalformedBundle "unsupported prepared Pulumi bundle version"))
  unless (contentDigest savedPlan == headerPlanDigest header) (Left (PulumiMalformedBundle "prepared Pulumi saved-plan digest mismatch"))
  pure (header, savedPlan)

validateHeader :: PlannedOperation -> PulumiIdentity -> PulumiBundleHeader -> Either PulumiBundleError ()
validateHeader operation current header = do
  unless (headerOperation header == plannedOperationId operation) (Left (PulumiBundleBindingChanged "operation identity"))
  unless (headerInputDigest header == plannedInputDigest operation) (Left (PulumiBundleBindingChanged "operation input digest"))
  unless (headerIdentity header == current) (Left (PulumiBundleBindingChanged "context, stack, backend, program, config, or Pulumi version"))

renderSummary :: PulumiBundleHeader -> Text
renderSummary header =
  "Pulumi saved plan "
    <> digestText (headerPlanDigest header)
    <> "; "
    <> T.pack (show (length (filter (isMutation . op) (headerSteps header))))
    <> " declared mutation(s); stack "
    <> pulumiStack (headerIdentity header)
    <> "; project "
    <> pulumiProject (headerIdentity header)

renderBundleError :: PulumiBundleError -> Text
renderBundleError = T.pack . show

instance ToJSON PulumiIdentity where
  toJSON identity =
    object
      [ "context" .= pulumiContext identity
      , "project" .= pulumiProject identity
      , "stack" .= pulumiStack identity
      , "backend" .= pulumiBackend identity
      , "payloadId" .= pulumiPayloadId identity
      , "payloadDigest" .= pulumiPayloadDigest identity
      , "programDigest" .= pulumiProgramDigest identity
      , "configDigest" .= pulumiConfigDigest identity
      , "pulumiVersion" .= pulumiToolVersion identity
      ]

instance FromJSON PulumiIdentity where
  parseJSON = withObject "Pulumi identity" $ \o ->
    PulumiIdentity <$> o .: "context" <*> o .: "project" <*> o .: "stack" <*> o .: "backend" <*> o .: "payloadId" <*> o .: "payloadDigest" <*> o .: "programDigest" <*> o .: "configDigest" <*> o .: "pulumiVersion"

instance ToJSON PulumiBundleHeader where
  toJSON header =
    object
      [ "version" .= headerVersion header
      , "operation" .= headerOperation header
      , "inputDigest" .= headerInputDigest header
      , "identity" .= headerIdentity header
      , "previewDigest" .= headerPreviewDigest header
      , "planDigest" .= headerPlanDigest header
      , "registrationsDigest" .= headerRegistrationsDigest header
      , "steps" .= headerSteps header
      ]

instance FromJSON PulumiBundleHeader where
  parseJSON = withObject "prepared Pulumi bundle" $ \o ->
    PulumiBundleHeader <$> o .: "version" <*> o .: "operation" <*> o .: "inputDigest" <*> o .: "identity" <*> o .: "previewDigest" <*> o .: "planDigest" <*> o .: "registrationsDigest" <*> o .: "steps"
