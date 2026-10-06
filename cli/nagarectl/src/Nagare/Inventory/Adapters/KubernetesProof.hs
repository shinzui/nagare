-- | The pure proof layer of reviewed Kubernetes mutations: the observed state
-- and the reviewed mutation with their encodings, the before-state guard, and
-- the completion and settlement proofs (ADR 26). The adapter in
-- "Nagare.Inventory.Adapters.Kubernetes" runs them against the provider.
module Nagare.Inventory.Adapters.KubernetesProof
  ( KubernetesState (..)
  , KubernetesMutation (..)
  , FieldTakeover (..)
  , settleMutation
  , requireSameBefore
  , completionProof
  , statePhysical
  , knativeServiceAddress
  , statefulSetAddress
  , deploymentAddress
  , orTakeover
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal (OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The revision is the Kubernetes metadata.resourceVersion. The owner is
-- read from the guarded logical-identity stamp, never inferred from a name.
data KubernetesState
  = KubernetesAbsent !ContentDigest
  | KubernetesPresent !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesNotReady !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesFailed !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesReplacementRequired !PhysicalIdentity !Text !(Maybe ResourceId) !ContentDigest
  | KubernetesUnknown !Text
  deriving stock (Eq, Show, Generic)

-- | Private reviewed plan. The native JSON is the exact canonical object
-- submitted by the transport, including any private Secret fields. Version 3
-- is a version-1 update that also carries a reviewed field takeover.
data KubernetesMutation = KubernetesMutation
  { mutationVersion :: !Int
  , mutationOperation :: !OperationId
  , mutationInputDigest :: !ContentDigest
  , mutationAction :: !OperationAction
  , mutationResource :: !ResourceId
  , mutationAddress :: !ProviderAddress
  , mutationNativeJson :: !Text
  , mutationNativeDigest :: !ContentDigest
  , mutationBefore :: !KubernetesState
  , mutationTakeover :: !(Maybe FieldTakeover)
  , mutationBeforeStamp :: !(Maybe ContentDigest)
  -- ^ An update's before-state stamp, observed at review (F67, RES-4 U3).
  -- Every update records it, as Nothing when the object carried none.
  }
  deriving stock (Eq, Generic)

-- | The foreign managed-field entries an operator reviewed for takeover (F37),
-- bound to the object's UID and resourceVersion at planning. Execution may
-- force Nagare's fields only while every live foreign entry is one of these.
data FieldTakeover = FieldTakeover
  { takeoverPhysical :: !PhysicalIdentity
  , takeoverResourceVersion :: !Text
  , takeoverManagers :: ![Value]
  }
  deriving stock (Eq, Show, Generic)

-- | ADR 26's proof classes for one Kubernetes operation (obligations O1–O5):
-- the reviewed before-state unchanged is no effect; the reviewed digest on the
-- reviewed (or, for a create, newly stamped) object, not ready, is landed; an
-- owned target that is gone or carries another UID, or an object not stamped
-- as this member's at a create's or update's address (F66, F68), is gone; a
-- failed object of this operation is a terminal partial effect. Anything else
-- stays unknown.
settleMutation :: KubernetesMutation -> KubernetesState -> KubernetesState -> RecoveryDecision -> Settlement
settleMutation mutation before current decision = case decision of
  RecoveryProvedComplete _ -> SettledUnknown "the effect is proved complete" "inventory resume"
  RecoveryLandedUnready physical -> SettledLanded physical
  RecoveryAwaitingReadiness physical -> SettledLanded physical
  RecoveryTargetReplaced physical -> SettledTargetGone (Just physical)
  RecoveryTerminalFailure physical -> SettledTerminalPartial physical
  _ | Right () <- requireSameBefore mutation before -> SettledNoEffect "the reviewed before-state is unchanged"
  _ -> case current of
    -- F66, F68: a create writes only to an empty address and an update only to
    -- the reviewed UID, and both stamp the object as this member's, so another
    -- object there not stamped as this member proves the write is not live.
    KubernetesPresent physical _ owner _ | notLive physical owner -> SettledTargetGone (Just physical)
    KubernetesNotReady physical _ owner _ | notLive physical owner -> SettledTargetGone (Just physical)
    KubernetesFailed physical _ owner _ | notLive physical owner -> SettledTargetGone (Just physical)
    KubernetesAbsent _
      | Just _ <- beforeIdentity -> SettledTargetGone Nothing
    KubernetesPresent physical _ (Just owner) _
      | owner == resource, Just prior <- beforeIdentity, prior /= physical -> SettledTargetGone (Just physical)
    KubernetesNotReady physical _ (Just owner) _
      | owner == resource, Just prior <- beforeIdentity, prior /= physical -> SettledTargetGone (Just physical)
    KubernetesNotReady physical _ (Just owner) digest
      | owner == resource
      , digest == mutationNativeDigest mutation
      , maybe True (== physical) beforeIdentity ->
          SettledLanded physical
    KubernetesFailed physical _ (Just owner) digest
      | owner == resource
      , digest == mutationNativeDigest mutation ->
          SettledTerminalPartial physical
    _ -> SettledUnknown (unresolved decision) "a corrected review, or an attested close"
  where
    resource = mutationResource mutation
    notLive physical owner = owner /= Just resource && (createdOver || updatedOver physical)
    createdOver = mutationAction mutation == CreateResource && (case mutationBefore mutation of KubernetesAbsent {} -> True; _ -> False)
    updatedOver physical = mutationAction mutation == UpdateResource && maybe False (/= physical) beforeIdentity
    -- The owned object the operation was reviewed against, if any.
    beforeIdentity = case mutationBefore mutation of
      KubernetesPresent prior _ (Just owner) _ | owner == resource -> Just prior
      KubernetesNotReady prior _ (Just owner) _ | owner == resource -> Just prior
      KubernetesFailed prior _ (Just owner) _ | owner == resource -> Just prior
      _ -> Nothing
    unresolved = \case
      RecoveryUnresolved reason -> reason
      RecoverySafeToRetry -> "a retry is safe but the effect is not proved absent"
      other -> T.pack (show other)

requireSameBefore :: KubernetesMutation -> KubernetesState -> Either Text ()
requireSameBefore mutation current =
  if mutationAction mutation == RunDeclaredOperation
    then case current of
      KubernetesPresent _ _ (Just owner) digest
        | owner == mutationResource mutation && digest == mutationNativeDigest mutation -> Right ()
      _ -> Left "declared Kubernetes Job is not complete at the reviewed digest"
    else
      if mutationAction mutation == VerifyResource
        then case (mutationBefore mutation, current) of
          ( KubernetesPresent expectedPhysical _ (Just expectedOwner) expectedDigest
            , KubernetesPresent physical _ (Just owner) digest
            )
              | expectedPhysical == physical && expectedOwner == owner
              , owner == mutationResource mutation
              , expectedDigest == digest && digest == mutationNativeDigest mutation ->
                  Right ()
          ( KubernetesNotReady expectedPhysical _ (Just expectedOwner) expectedDigest
            , KubernetesPresent physical _ (Just owner) digest
            )
              | Kubernetes _ "serving.knative.dev" kind (Just _) _ <- mutationAddress mutation
              , nameText kind == "domainmapping"
              , expectedPhysical == physical && expectedOwner == owner
              , owner == mutationResource mutation
              , expectedDigest == digest && digest == mutationNativeDigest mutation ->
                  Right ()
          _ -> Left "Kubernetes object identity or desired fields changed since review"
        else
          if mutationVersion mutation == 2 && mutationAction mutation == UpdateResource
            then case (configured (mutationBefore mutation), configured current) of
              (Just before, Just now) | before == now -> Right ()
              _ -> Left "Knative Service configuration or ownership changed since review"
            else
              if current == mutationBefore mutation
                then Right ()
                else Left "Kubernetes object changed since review; replan before mutation"
  where
    configured (KubernetesPresent uid _ (Just owner) digest) | owner == mutationResource mutation = Just (uid, owner, digest)
    configured (KubernetesNotReady uid _ (Just owner) digest) | owner == mutationResource mutation = Just (uid, owner, digest)
    configured _ = Nothing

knativeServiceAddress :: ProviderAddress -> Bool
knativeServiceAddress (Kubernetes _ "serving.knative.dev" kind (Just _) _) = nameText kind == "service"
knativeServiceAddress _ = False

statefulSetAddress :: ProviderAddress -> Bool
statefulSetAddress (Kubernetes _ "apps" kind (Just _) _) = nameText kind == "statefulset"
statefulSetAddress _ = False

deploymentAddress :: ProviderAddress -> Bool
deploymentAddress (Kubernetes _ "apps" kind (Just _) _) = nameText kind == "deployment"
deploymentAddress _ = False

completionProof :: KubernetesMutation -> KubernetesState -> Either Text ContentDigest
completionProof mutation state
  | mutationAction mutation == VerifyResource
  , Left reason <- requireSameBefore mutation state =
      Left reason
  | mutationAction mutation == RetireResource = case state of
      KubernetesAbsent absence -> case mutationBefore mutation of
        KubernetesPresent physical _ _ _ ->
          contentDigest
            <$> canonicalValue
              ( object
                  [ "operation" .= mutationOperation mutation
                  , "resource" .= mutationResource mutation
                  , "removedPhysical" .= physical
                  , "absence" .= absence
                  ]
              )
        KubernetesNotReady physical _ _ _ ->
          contentDigest
            <$> canonicalValue
              ( object
                  [ "operation" .= mutationOperation mutation
                  , "resource" .= mutationResource mutation
                  , "removedPhysical" .= physical
                  , "absence" .= absence
                  ]
              )
        _ -> Left "collection lacks a present historical precondition"
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
      KubernetesFailed {} -> Left "Kubernetes Job has a terminal failure"
      _ -> Left "collected Kubernetes object remains present or was replaced"
  -- ADR 27 (N9): an update or adoption writes the reviewed object in place,
  -- so only that object proves it; a same-stamp replacement does not.
  | mutationAction mutation `elem` [UpdateResource, AdoptResource]
  , Just reviewed <- statePhysical (mutationBefore mutation)
  , Just live <- statePhysical state
  , live /= reviewed =
      Left "Kubernetes object was replaced; it is not the reviewed object the operation wrote"
  | otherwise = case state of
      KubernetesPresent physical _ (Just owner) digest
        | owner == mutationResource mutation && digest == mutationNativeDigest mutation ->
            contentDigest <$> canonicalValue (object ["operation" .= mutationOperation mutation, "resource" .= owner, "physicalIdentity" .= physical, "desiredDigest" .= digest])
      KubernetesUnknown reason -> Left ("Kubernetes observation unavailable: " <> reason)
      KubernetesNotReady {} -> Left "Kubernetes object remains present but is not ready"
      KubernetesFailed {} -> Left "Kubernetes Job has a terminal failure"
      _ -> Left "Kubernetes object is absent, foreign, or differs from the reviewed native object"

-- | The identity of an observed object, when one is present.
statePhysical :: KubernetesState -> Maybe PhysicalIdentity
statePhysical = \case
  KubernetesPresent physical _ _ _ -> Just physical
  KubernetesNotReady physical _ _ _ -> Just physical
  KubernetesFailed physical _ _ _ -> Just physical
  KubernetesReplacementRequired physical _ _ _ -> Just physical
  _ -> Nothing

instance ToJSON KubernetesState where
  toJSON = \case
    KubernetesAbsent proof -> object ["kind" .= ("absent" :: Text), "proof" .= proof]
    KubernetesPresent physical revision owner digest -> object ["kind" .= ("present" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesNotReady physical revision owner digest -> object ["kind" .= ("not-ready" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesFailed physical revision owner digest -> object ["kind" .= ("failed" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesReplacementRequired physical revision owner digest -> object ["kind" .= ("replacement-required" :: Text), "physical" .= physical, "resourceVersion" .= revision, "owner" .= owner, "digest" .= digest]
    KubernetesUnknown reason -> object ["kind" .= ("unknown" :: Text), "reason" .= reason]

instance FromJSON KubernetesState where
  parseJSON = withObject "Kubernetes state" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "absent" -> KubernetesAbsent <$> o .: "proof"
      "present" -> KubernetesPresent <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "not-ready" -> KubernetesNotReady <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "failed" -> KubernetesFailed <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "replacement-required" -> KubernetesReplacementRequired <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "owner" <*> o .: "digest"
      "unknown" -> KubernetesUnknown <$> o .: "reason"
      _ -> fail "unknown Kubernetes state"

instance ToJSON KubernetesMutation where
  toJSON mutation =
    object
      ( [ "version" .= mutationVersion mutation
        , "operation" .= mutationOperation mutation
        , "inputDigest" .= mutationInputDigest mutation
        , "action" .= mutationAction mutation
        , "resource" .= mutationResource mutation
        , "address" .= mutationAddress mutation
        , "nativeJson" .= mutationNativeJson mutation
        , "nativeDigest" .= mutationNativeDigest mutation
        , "before" .= mutationBefore mutation
        ]
          -- Versions 1 and 2 keep their exact earlier bytes.
          <> maybe [] (\takeover -> ["takeover" .= takeover]) (mutationTakeover mutation)
          <> ["beforeStamp" .= mutationBeforeStamp mutation | mutationAction mutation == UpdateResource]
      )

instance FromJSON KubernetesMutation where
  parseJSON = withObject "Kubernetes mutation" $ \o -> do
    action <- o .: "action"
    -- An update records its before-state stamp, even when it is null.
    stamp <-
      if action == UpdateResource
        then maybe (fail "a Kubernetes update mutation lacks its before-state stamp") parseJSON (KM.lookup "beforeStamp" o)
        else pure Nothing
    KubernetesMutation <$> o .: "version" <*> o .: "operation" <*> o .: "inputDigest" <*> pure action <*> o .: "resource" <*> o .: "address" <*> o .: "nativeJson" <*> o .: "nativeDigest" <*> o .: "before" <*> o .:? "takeover" <*> pure stamp

instance ToJSON FieldTakeover where
  toJSON takeover =
    object
      [ "physical" .= takeoverPhysical takeover
      , "resourceVersion" .= takeoverResourceVersion takeover
      , "managers" .= takeoverManagers takeover
      ]

instance FromJSON FieldTakeover where
  parseJSON = withObject "Kubernetes field takeover" $ \o ->
    FieldTakeover <$> o .: "physical" <*> o .: "resourceVersion" <*> o .: "managers"

-- | Only a version-3 update carries a takeover, bound to its own exact
-- precondition; no other version may carry one.
orTakeover :: Either Text () -> KubernetesMutation -> Either Text ()
orTakeover versionCheck mutation = case (mutationVersion mutation, mutationTakeover mutation, mutationBefore mutation) of
  (3, Just takeover, before)
    | mutationAction mutation == UpdateResource
    , not (null (takeoverManagers takeover))
    , Just (physical, revision) <- presentIdentity before
    , physical == takeoverPhysical takeover && revision == takeoverResourceVersion takeover ->
        Right ()
  (3, _, _) -> Left "Kubernetes field takeover is not bound to its reviewed update precondition"
  (_, Just _, _) -> Left "only a version-3 Kubernetes update may carry a field takeover"
  _ -> versionCheck
  where
    presentIdentity (KubernetesPresent physical revision _ _) = Just (physical, revision)
    presentIdentity (KubernetesNotReady physical revision _ _) = Just (physical, revision)
    presentIdentity _ = Nothing
