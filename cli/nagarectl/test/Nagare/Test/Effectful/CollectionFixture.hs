-- | Accepted Knative parent and retained data, at the F20 collection boundary.
module Nagare.Test.Effectful.CollectionFixture
  ( collectionBinding
  , collectionOwner
  , parentId
  , parentKey
  , collectionNative
  , collectionScopes
  )
where

import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Effectful.Fixture (checked)

collectionBinding :: ContextBinding
collectionBinding = ContextBinding (checked (mkContextId "effectful-collection")) (checked (mkName "project"))

collectionOwner :: ScopeId
collectionOwner = checked (mkScopeId Application "web")

parentId :: ResourceId
parentId = mintResourceId collectionOwner (checked (mkLogicalKey "web")) (checked (mkName "service"))

parentKey :: Text
parentKey = "service.serving.knative.dev/web"

collectionNative :: Map ResourceId (ManagedResource, ByteString)
collectionNative = Map.fromList [(member ^. #identity, (member, bytes)) | (member, bytes) <- entries]
  where
    neighbor = checked (mkScopeId Standalone "neighbor")
    clusterOwner = checked (mkScopeId Platform "cluster")
    cluster = mintResourceId clusterOwner (checked (mkLogicalKey "cluster")) (checked (mkName "cluster"))
    bind owner key role api kind name body policy dataPolicy =
      let identity = mintResourceId owner (checked (mkLogicalKey key)) (checked (mkName role))
          value =
            object
              [ "apiVersion" .= (api :: Text)
              , "kind" .= (kind :: Text)
              , "metadata" .= object ["name" .= (name :: Text), "namespace" .= ("personal" :: Text)]
              , "spec" .= body
              ]
          bytes = checked (canonicalValue value)
       in checked
            ( bindKubernetesObject
                ( KubernetesInput
                    identity
                    owner
                    cluster
                    value
                    (contentDigest bytes)
                    policy
                    dataPolicy
                    Private
                    (SourceLocation "effectful" "collection")
                )
            )
    entries =
      [ bind
          collectionOwner
          "web"
          "service"
          "serving.knative.dev/v1"
          "Service"
          "web"
          ( object
              [ "template"
                  .= object
                    [ "spec"
                        .= object
                          [ "containers"
                              .= [object ["name" .= ("web" :: Text), "image" .= ("example.invalid/web:fixture" :: Text)]]
                          ]
                    ]
              ]
          )
          DeleteWhenUnreferenced
          Stateless
      , bind
          collectionOwner
          "database"
          "statefulset"
          "apps/v1"
          "StatefulSet"
          "pg-main"
          (object ["replicas" .= (1 :: Int)])
          Retain
          Stateless
      , bind
          collectionOwner
          "database"
          "pvc"
          "v1"
          "PersistentVolumeClaim"
          "pg-main-data"
          (object ["accessModes" .= ["ReadWriteOnce" :: Text]])
          Retain
          durable
      , bind
          collectionOwner
          "database"
          "backup-job"
          "batch/v1"
          "Job"
          "pg-main-backup"
          ( object
              [ "template"
                  .= object
                    [ "spec"
                        .= object
                          [ "restartPolicy" .= ("Never" :: Text)
                          , "containers" .= [object ["name" .= ("backup" :: Text), "image" .= ("example.invalid/backup:fixture" :: Text)]]
                          ]
                    ]
              ]
          )
          Retain
          Stateless
      , bind neighbor "neighbor" "service" "v1" "Service" "neighbor" (object []) Retain Stateless
      ]
    durable =
      Durable
        ( RecoveryIntent
            (checked (mkName "archive"))
            (mkSecretRef (checked (mkName "restore-key")) (checked (mkName "v1")) :| [])
        )

collectionScopes :: [ScopeDeclaration]
collectionScopes =
  [ checked (mkScopeDeclaration owner [ResourceBundle (map Managed members) [] [] [] [] []])
  | (owner, members) <- Map.toList (Map.fromListWith (<>) [(member ^. #owner, [member]) | (member, _) <- Map.elems collectionNative])
  ]
