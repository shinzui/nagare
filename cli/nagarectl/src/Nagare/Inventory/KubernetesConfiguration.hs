-- | Status-independent configuration evidence for versioned Knative updates.
module Nagare.Inventory.KubernetesConfiguration (configurationDigest, confirmInventoryFieldOwnership, confirmInventoryFieldOwnershipFor) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

configurationDigest :: Value -> Either Text ContentDigest
configurationDigest (Object root) = do
  metadata <- case KM.lookup "metadata" root of
    Just (Object value) -> Right value
    _ -> Left "configuration observation lacks metadata"
  unless
    (KM.lookup "deletionTimestamp" metadata `elem` [Nothing, Just Null])
    (Left "terminating resource cannot receive a configuration update")
  fields <- case KM.lookup "managedFields" metadata of
    Just (Array entries) -> traverse normalize (toList entries)
    _ -> Left "configuration observation lacks managed-field authority"
  let stableMetadata = KM.insert "managedFields" (toJSON (catMaybes fields)) (KM.delete "resourceVersion" metadata)
  contentDigest <$> canonicalValue (Object (KM.insert "metadata" (Object stableMetadata) (KM.delete "status" root)))
  where
    normalize (Object entry) = case KM.lookup "fieldsV1" entry of
      Just (Object fields)
        | KM.lookup "subresource" entry == Just (String "status")
            || (not (KM.null fields) && all (== "f:status") (KM.keys fields)) ->
            Right Nothing
        | otherwise -> Right (Just (Object (KM.delete "time" entry)))
      _ -> Left "configuration observation has malformed managed fields"
    normalize _ = Left "configuration observation has malformed managed fields"
configurationDigest _ = Left "configuration observation is not an object"

-- | A create is recorded as an Update field manager even when it uses the
-- same manager name as later server-side apply. Force is safe only while all
-- non-status fields still belong exclusively to that manager. The subsequent
-- apply includes the observed UID/resourceVersion, so a change after this
-- read makes the API server reject the write.
confirmInventoryFieldOwnership :: PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnership = confirmInventoryFieldOwnershipFor Nothing

confirmInventoryFieldOwnershipFor :: Maybe ProviderAddress -> PhysicalIdentity -> Text -> Value -> Either Text ()
confirmInventoryFieldOwnershipFor target uid revision observed = do
  metadata <- metadataOf observed
  actualUid <- fieldText "uid" metadata
  actualRevision <- fieldText "resourceVersion" metadata
  unless
    (actualUid == physicalIdentityText uid && actualRevision == revision)
    (Left "Kubernetes object changed after the reviewed observation")
  fields <- case KM.lookup "managedFields" metadata of
    Just (Array entries) | not (null entries) -> Right (foldr (:) [] entries)
    _ -> Left "Kubernetes managed fields are missing; update ownership is unknown"
  mapM_ checkEntry fields
  unless
    (any isInventoryOwner fields)
    (Left "Kubernetes object has no inventory-managed fields to update")
  where
    checkEntry (Object entry) = do
      manager <- fieldText "manager" entry
      fieldSet <- case KM.lookup "fieldsV1" entry of
        Just (Object value) -> Right value
        _ -> Left "Kubernetes managed-field entry is malformed"
      unless
        (manager == "nagare-inventory" || statusOnly fieldSet || expectedControllerFields target manager fieldSet)
        (Left ("Kubernetes object has fields managed by another writer: " <> manager))
    checkEntry _ = Left "Kubernetes managed-field entry is malformed"
    isInventoryOwner (Object entry) = textAt "manager" entry == Just "nagare-inventory"
    isInventoryOwner _ = False
    statusOnly fields = all (== "f:status") (KM.keys fields)

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
