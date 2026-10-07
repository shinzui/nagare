-- | Live-object evidence for Kubernetes updates: the spec-digest stamp, the
-- managed-field owners and the identity a write is guarded by.
module Nagare.Inventory.KubernetesConfiguration
  ( liveStamp
  , stampOf
  , confirmUpdateTarget
  , confirmInventoryFieldOwnership
  , confirmInventoryFieldOwnershipFor
  , confirmReviewedFieldTakeover
  , confirmTakeoverSettled
  , confirmLandedUnready
  , foreignFieldManagers
  , liveIdentity
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | The spec-digest stamp of an observed object. Nagare writes it in the same
-- atomic write as the spec it describes (RES-4 U3), so on the same UID it
-- witnesses which of Nagare's writes is live.
liveStamp :: Text -> Maybe ContentDigest
liveStamp output = either (const Nothing) stampOf (eitherDecodeStrict (TE.encodeUtf8 output))

stampOf :: Value -> Maybe ContentDigest
stampOf = \case
  Object root
    | Just (Object metadata) <- KM.lookup "metadata" root
    , Just (Object annotations) <- KM.lookup "annotations" metadata
    , Just (String stamp) <- KM.lookup "nagare.dev/spec-digest" annotations ->
        either (const Nothing) Just (mkContentDigest stamp)
  _ -> Nothing

-- | G6, RES-4 U10 (E13): an update's target is as reviewed when it is the
-- reviewed UID, still carries the before-state stamp, and no other writer owns
-- a non-status field (beyond a reviewed takeover). Every API write records its
-- writer per field, and status writes go to status-subresource entries, so
-- this is immune to status churn and catches any foreign write that changed a
-- spec or metadata field (one that changes nothing takes no ownership and
-- leaves the object as Nagare wrote it). The result is the live
-- resourceVersion, the write's precondition. A reviewed takeover (F37) forces
-- another writer's fields, so it stays bound to the exact reviewed
-- resourceVersion.
confirmUpdateTarget :: Maybe ProviderAddress -> [Value] -> PhysicalIdentity -> Maybe ContentDigest -> Maybe Text -> Value -> Either Text Text
confirmUpdateTarget target reviewed uid stamp takeoverRevision observed = do
  (actualUid, actualRevision) <- liveIdentity observed
  unless (actualUid == physicalIdentityText uid) (Left "Kubernetes object was replaced after the reviewed observation")
  unless (maybe True (== actualRevision) takeoverRevision) (Left "Kubernetes object changed after the reviewed observation")
  unless (stampOf observed == stamp) (Left "Kubernetes object's stamp changed after the reviewed observation")
  actualRevision <$ confirmReviewedFieldTakeover target reviewed uid actualRevision observed

-- | A create is recorded as an Update field manager even when it uses the
-- same manager name as later server-side apply. Force is safe only while all
-- non-status fields still belong exclusively to that manager. The subsequent
-- apply includes the observed UID/resourceVersion, so a change after this
-- read makes the API server reject the write.
confirmInventoryFieldOwnership :: PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnership = confirmInventoryFieldOwnershipFor Nothing

confirmInventoryFieldOwnershipFor :: Maybe ProviderAddress -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnershipFor target = confirmReviewedFieldTakeover target []

-- | A reviewed field takeover (F37) names the exact foreign managed-field
-- entries observed at planning, without their timestamps. A live foreign
-- entry is accepted only when it is one of those entries; a new manager, or
-- the same manager owning different fields, refuses. The empty list is the
-- strict check.
confirmReviewedFieldTakeover :: Maybe ProviderAddress -> [Value] -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmReviewedFieldTakeover target reviewed uid revision observed = do
  (actualUid, actualRevision) <- liveIdentity observed
  unless
    (actualUid == physicalIdentityText uid && actualRevision == revision)
    (Left "Kubernetes object changed after the reviewed observation")
  fields <- managedFieldEntries observed
  others <- foreignEntries target fields
  case [entry | entry <- others, untimed entry `notElem` reviewed] of
    entry : _ -> Left ("Kubernetes object has fields managed by another writer: " <> fromMaybe "unknown" (managerOf entry))
    [] -> pure ()
  unless
    (any ((== Just "nagare-inventory") . managerOf) fields)
    (Left "Kubernetes object has no inventory-managed fields to update")

-- | After a forced takeover write, the same object must have no foreign
-- owner of a non-status field left; a remaining one owns fields that Nagare
-- does not declare, so the next update would refuse again.
confirmTakeoverSettled :: Maybe ProviderAddress -> PhysicalIdentity -> Value -> Either Text ()
confirmTakeoverSettled target uid observed = do
  (actualUid, _) <- liveIdentity observed
  unless (actualUid == physicalIdentityText uid) (Left "Kubernetes object was replaced during its field takeover")
  remaining <- foreignFieldManagers target observed
  unless (null remaining) (Left "field takeover left fields owned by another writer; inspect managed fields")

-- | F54: a landed but unready update may be stopped only when the live object
-- is the one the adapter observed (UID and resourceVersion), its controller has
-- observed this generation, Nagare alone owns its non-status fields, and the
-- controller does not report it Ready.
confirmLandedUnready :: Maybe ProviderAddress -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmLandedUnready target uid revision observed = do
  confirmInventoryFieldOwnershipFor target uid revision observed
  metadata <- metadataOf observed
  status <- case observed of
    Object root | Just (Object value) <- KM.lookup "status" root -> Right value
    _ -> Left "Kubernetes object has no controller status"
  case (KM.lookup "generation" metadata, KM.lookup "observedGeneration" status) of
    (Just (Number generation), Just (Number seen)) | generation == seen -> pure ()
    _ -> Left "Kubernetes controller has not observed the landed generation"
  case target of
    -- F63: a StatefulSet reports readiness through its replica counts, not a
    -- Ready condition.
    Just (Kubernetes _ "apps" kind _ _)
      | nameText kind == "statefulset" -> do
          let wanted = case observed of
                Object root
                  | Just (Object spec) <- KM.lookup "spec" root
                  , Just (Number replicas) <- KM.lookup "replicas" spec ->
                      replicas
                _ -> 1
              readyCount = case KM.lookup "readyReplicas" status of
                Just (Number replicas) -> replicas
                _ -> 0
          when (readyCount >= wanted) (Left "Kubernetes StatefulSet has every replica ready")
    _ -> case KM.lookup "conditions" status of
      Just (Array conditions) | any ready (toList conditions) -> Left "Kubernetes object is Ready"
      _ -> pure ()
  where
    ready (Object condition) =
      KM.lookup "type" condition == Just (String "Ready")
        && KM.lookup "status" condition == Just (String "True")
    ready _ = False

-- | The foreign managed-field entries of a live object, without timestamps,
-- in API order. Status-only entries and proved controller paths are not
-- foreign.
foreignFieldManagers :: Maybe ProviderAddress -> Value -> Either Text [Value]
foreignFieldManagers target observed = map untimed <$> (managedFieldEntries observed >>= foreignEntries target)

liveIdentity :: Value -> Either Text (Text, Text)
liveIdentity observed = do
  metadata <- metadataOf observed
  (,) <$> fieldText "uid" metadata <*> fieldText "resourceVersion" metadata

managedFieldEntries :: Value -> Either Text [Value]
managedFieldEntries observed = do
  metadata <- metadataOf observed
  case KM.lookup "managedFields" metadata of
    Just (Array entries) | not (null entries) -> Right (toList entries)
    _ -> Left "Kubernetes managed fields are missing; update ownership is unknown"

foreignEntries :: Maybe ProviderAddress -> [Value] -> Either Text [Value]
foreignEntries target = fmap catMaybes . traverse classify
  where
    classify value@(Object entry) = do
      manager <- fieldText "manager" entry
      fieldSet <- case KM.lookup "fieldsV1" entry of
        Just (Object fields) -> Right fields
        _ -> Left "Kubernetes managed-field entry is malformed"
      pure $
        if manager == "nagare-inventory" || statusOnly fieldSet || expectedControllerFields target manager fieldSet
          then Nothing
          else Just value
    classify _ = Left "Kubernetes managed-field entry is malformed"
    statusOnly fields = all (== "f:status") (KM.keys fields)

untimed :: Value -> Value
untimed (Object entry) = Object (KM.delete "time" entry)
untimed other = other

managerOf :: Value -> Maybe Text
managerOf (Object entry) = textAt "manager" entry
managerOf _ = Nothing

-- PVC provisioners add these annotations after the create-only write. They
-- do not intersect inventory's desired fields. Any other controller field is
-- still a refusal until its specific owner and path have been established.
expectedControllerFields :: Maybe ProviderAddress -> Text -> Object -> Bool
expectedControllerFields (Just (Kubernetes _ "" kind _ _)) "k3s" fields
  | nameText kind == "persistentvolumeclaim" =
      not (null paths) && all (`elem` allowed) paths
  where
    paths = managedPaths [] fields
    allowed =
      [ ["f:metadata", "f:annotations", "f:volume.beta.kubernetes.io/storage-provisioner"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/selected-node"]
      , ["f:metadata", "f:annotations", "f:volume.kubernetes.io/storage-provisioner"]
      , ["f:spec", "f:volumeName"]
      ]
expectedControllerFields (Just (Kubernetes _ "apps" kind _ _)) "k3s" fields
  | nameText kind == "deployment" =
      ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] `elem` paths
        && all permitted paths
  where
    paths = managedPaths [] fields
    permitted ["f:metadata", "f:annotations", "."] = True
    permitted ["f:metadata", "f:annotations", "f:deployment.kubernetes.io/revision"] = True
    permitted ("f:status" : _) = True
    permitted _ = False
expectedControllerFields _ _ _ = False

managedPaths :: [Text] -> Object -> [[Text]]
managedPaths prefix fields = concatMap one (KM.toList fields)
  where
    one (key, Object nested)
      | KM.null nested = [prefix <> [Key.toText key]]
      | otherwise = managedPaths (prefix <> [Key.toText key]) nested
    one (key, _) = [prefix <> [Key.toText key]]

metadataOf :: Value -> Either Text Object
metadataOf (Object root) = case KM.lookup "metadata" root of
  Just (Object value) -> Right value
  _ -> Left "Kubernetes observation has no metadata"
metadataOf _ = Left "Kubernetes observation is not an object"

fieldText :: Key -> Object -> Either Text Text
fieldText key metadata = case KM.lookup key metadata of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes observation lacks " <> T.pack (show key))

textAt :: Key -> Object -> Maybe Text
textAt key value = case KM.lookup key value of Just (String textValue) -> Just textValue; _ -> Nothing
