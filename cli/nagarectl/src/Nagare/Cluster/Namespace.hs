-- | The public-certificate namespace boundary. Nagare-created application
-- workloads opt their namespace into Knative wildcard certificates; platform,
-- Kubernetes, and observability namespaces are refused.
module Nagare.Cluster.Namespace
  ( NamespacePurpose (..)
  , applicationNamespaceLabel
  , renderNamespace
  , ensureNamespace
  )
where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Deploy (applyManifests)
import Nagare.Dsl.Prelude hiding ((.=))

data NamespacePurpose = ApplicationNamespace
  deriving stock (Eq, Show)

applicationNamespaceLabel :: Text
applicationNamespaceLabel = "nagare.dev/app-namespace"

-- | Render the convergent Namespace apply. Kubernetes' apply merge adds or
-- updates Nagare's label without deleting labels owned by other controllers.
renderNamespace :: NamespacePurpose -> Text -> Either Text BS.ByteString
renderNamespace ApplicationNamespace namespace
  | namespace `Set.member` reservedNamespaces =
      Left
        ( "refusing to opt system or observability namespace '"
            <> namespace
            <> "' into public wildcard certificates"
        )
  | T.null namespace = Left "application namespace must not be empty"
  | otherwise =
      Right . LBS.toStrict . encode $
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("Namespace" :: Text)
          , "metadata"
              .= object
                [ "name" .= namespace
                , "labels" .= object [Key.fromText applicationNamespaceLabel .= ("true" :: Text)]
                ]
          ]

-- | Create a missing application namespace or add the opt-in label to an
-- existing one. Re-applying preserves unrelated labels.
ensureNamespace :: NamespacePurpose -> Text -> IO (Either Text ())
ensureNamespace purpose namespace =
  case renderNamespace purpose namespace of
    Left err -> pure (Left err)
    Right manifest -> Right <$> applyManifests [manifest]

reservedNamespaces :: Set.Set Text
reservedNamespaces =
  Set.fromList
    [ "default"
    , "kube-system"
    , "kube-public"
    , "kube-node-lease"
    , "cert-manager"
    , "knative-serving"
    , "kourier-system"
    , "nagare-system"
    , "monitoring"
    , "observability"
    , "logging"
    ]
