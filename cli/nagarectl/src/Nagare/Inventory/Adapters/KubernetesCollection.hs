-- | The conditional DELETE request for reviewed retained collection. Server
-- preconditions bind the exact UID and resourceVersion; propagation follows
-- each admitted kind's controller children.
module Nagare.Inventory.Adapters.KubernetesCollection
  ( collectionDeleteRequest
  )
where

import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

collectionDeleteRequest :: ProviderAddress -> PhysicalIdentity -> Text -> Either Text ([String], Text)
collectionDeleteRequest address uid revision = case address of
  Kubernetes _ "serving.knative.dev" kind (Just _) _
    | nameText kind == "domainmapping" ->
        Left "an Orphan DomainMapping DELETE strands its gateway KIngress; collect it with its controller descendants"
  Kubernetes _ group kind (Just namespace) name
    | Just prefix <- collectionPathPrefix group (nameText kind) -> do
        bytes <-
          canonicalValue
            ( object
                [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
                , "kind" .= ("DeleteOptions" :: Text)
                , "preconditions"
                    .= object
                      ["uid" .= physicalIdentityText uid, "resourceVersion" .= revision]
                , "propagationPolicy" .= collectionPropagation group (nameText kind)
                ]
            )
        let path =
              prefix
                <> "/namespaces/"
                <> T.unpack (nameText namespace)
                <> "/"
                <> T.unpack (nameText kind)
                <> "s/"
                <> T.unpack (nameText name)
        pure (["delete", "--raw", path, "-f", "-"], TE.decodeUtf8 bytes)
  _ -> Left "conditional collection does not support this Kubernetes kind"

-- | Job and StatefulSet Pods are exclusive controller children: orphaning them
-- would leave a running database writer on a retained PVC after its
-- StatefulSet is gone. Other admitted kinds have no controlled children.
collectionPropagation :: Text -> Text -> Text
collectionPropagation "batch" "job" = "Background"
collectionPropagation "apps" "statefulset" = "Background"
collectionPropagation _ _ = "Orphan"

collectionPathPrefix :: Text -> Text -> Maybe String
collectionPathPrefix "" kind
  | kind `elem` ["configmap", "service", "persistentvolumeclaim", "serviceaccount"] = Just "/api/v1"
collectionPathPrefix "apps" "statefulset" = Just "/apis/apps/v1"
collectionPathPrefix "rbac.authorization.k8s.io" kind
  | kind `elem` ["role", "rolebinding"] = Just "/apis/rbac.authorization.k8s.io/v1"
collectionPathPrefix "batch" "cronjob" = Just "/apis/batch/v1"
collectionPathPrefix "batch" "job" = Just "/apis/batch/v1"
collectionPathPrefix "serving.knative.dev" "service" = Just "/apis/serving.knative.dev/v1"
collectionPathPrefix _ _ = Nothing
