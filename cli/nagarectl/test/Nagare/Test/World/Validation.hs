-- | The admission rules the fake API server applies to a write, as a real
-- server does (422 Invalid): the fields a new object's kind requires, and
-- the fields a kind forbids changing once created (RES-4 E1, E8).
module Nagare.Test.World.Validation
  ( missingRequired
  , immutableViolation
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Nagare.Dsl.Prelude

-- | The paths a new object of this group and kind must carry and lacks: a
-- workload's selector and pod template, a CronJob's schedule and Job
-- template, a PVC's access modes and requested storage.
missingRequired :: (Text, Text) -> Value -> [[Text]]
missingRequired groupKind value = [path | path <- required, leafAt path value == Null]
  where
    required = case groupKind of
      ("apps", "statefulset") -> [["spec", "selector"], ["spec", "template"]]
      ("apps", "deployment") -> [["spec", "selector"], ["spec", "template"]]
      ("batch", "job") -> [["spec", "template"]]
      ("batch", "cronjob") -> [["spec", "schedule"], ["spec", "jobTemplate"]]
      ("", "persistentvolumeclaim") -> [["spec", "accessModes"], ["spec", "resources", "requests", "storage"]]
      _ -> []

-- | Fields the API server refuses to change (422), as validated: a PVC's spec
-- while unbound (E1), a Job's template (E8), a StatefulSet's identity fields
-- and a Deployment's selector.
immutableViolation :: Text -> Value -> Value -> Maybe Text
immutableViolation kind before after = case kind of
  "persistentvolumeclaim"
    | changed ["spec"] -> Just "spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims"
  "job"
    | changed ["spec", "template"] -> Just "spec.template: Invalid value: field is immutable"
  "statefulset"
    | any (changed . (\f -> ["spec", f])) ["selector", "serviceName", "volumeClaimTemplates", "podManagementPolicy"] ->
        Just "spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden"
  "deployment"
    | changed ["spec", "selector"] -> Just "spec.selector: Invalid value: field is immutable"
  _ -> Nothing
  where
    changed path = leafAt path before /= Null && leafAt path before /= leafAt path after

leafAt :: [Text] -> Value -> Value
leafAt path value = foldl' (\v k -> case v of Object fields -> fromMaybe Null (KM.lookup (Key.fromText k) fields); _ -> Null) value path
