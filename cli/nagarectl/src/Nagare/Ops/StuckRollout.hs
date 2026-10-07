-- | EP-181 (RES-4 G3): the doctor probe for a Nagare-managed StatefulSet whose
-- rollout is stuck behind a pod that is not Ready. It reads the cluster once
-- and classes each StatefulSet with the same rule inventory planning uses
-- ('stuckPod').
module Nagare.Ops.StuckRollout
  ( probeStuckRollouts
  , parseStuckRollouts
  , isStuckRollout
  )
where

import Data.Aeson (decodeStrict)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesStuckPod (stuckPod)
import Nagare.Ops.Probe

-- | One failing probe per stuck StatefulSet, one unknown probe per
-- StatefulSet whose state cannot be classed, and one passing probe when
-- nothing is stuck.
probeStuckRollouts :: IO [Probe]
probeStuckRollouts = do
  sets <- captureTool "kubectl" ["get", "statefulsets", "--all-namespaces", "-o", "json"]
  pods <- captureTool "kubectl" ["get", "pods", "--all-namespaces", "-o", "json"]
  pure (fromMaybe [Probe "stuck rollouts" StatusUnknown "no kubeconfig / not reachable"] (parseStuckRollouts <$> sets <*> pods >>= id))

-- | Class the StatefulSets Nagare stamped (@nagare.dev/resource-id@) from
-- @kubectl get statefulsets -A -o json@ and @kubectl get pods -A -o json@.
-- 'Nothing' on malformed JSON.
parseStuckRollouts :: ByteString -> ByteString -> Maybe [Probe]
parseStuckRollouts setsJson podsJson = do
  sets <- decodeStrict setsJson
  pods <- decodeStrict podsJson
  Aeson.Array items <- lookupPath ["items"] sets
  let managed = [set' | set' <- V.toList items, isJust (textAt ["metadata", "annotations", "nagare.dev/resource-id"] set')]
      classed = [(set', stuckPod set' pods) | set' <- managed]
      found =
        [ Probe (probeName set') StatusFail (pod' ^. #pod <> " at revision " <> short set' (pod' ^. #podRevision) <> " is not Ready and blocks the rollout to " <> short set' (pod' ^. #updateRevision))
        | (set', Right (Just pod')) <- classed
        ]
      unknown = [Probe (probeName set') StatusUnknown reason | (set', Left reason) <- classed]
  pure (if null (found <> unknown) then [Probe "stuck rollouts" StatusOk "none"] else found <> unknown)
  where
    nameOf set' = fromMaybe "?" (textAt ["metadata", "name"] set')
    probeName set' = "stuck rollout " <> fromMaybe "?" (textAt ["metadata", "namespace"] set') <> "/" <> nameOf set'
    -- A revision is named <statefulset>-<hash>.
    short set' revision = fromMaybe revision (T.stripPrefix (nameOf set' <> "-") revision)

-- | Whether a probe name is a stuck-rollout probe.
isStuckRollout :: Text -> Bool
isStuckRollout name = "stuck rollout" `T.isPrefixOf` name
