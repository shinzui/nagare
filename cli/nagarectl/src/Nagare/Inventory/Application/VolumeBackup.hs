-- | Scheduled backups of an application's backup-included volumes (EP-183
-- M3). Every retained, durable PVC the application compiled gets the same
-- producer a database has: a dedicated reader account that may read only that
-- claim, a generated HMAC signing Secret, and a CronJob that archives the claim
-- read-only and uploads a signed version-5 receipt. The members share the
-- claim's scope and logical key; their roles extend the claim's role, so a
-- service volume and a worker volume of the same name never collide.
module Nagare.Inventory.Application.VolumeBackup
  ( compileVolumeBackups
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Database.Backup (renderInventoryVolumeBackupCronJob, volumeBackupScheduleName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Render (pvcName)
import Nagare.Inventory.Database (DatabaseBackupTarget)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource (dependencies), ResourceBundle (ResourceBundle))
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced, Retain)
  , Sensitivity (Private, Secret)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress (Kubernetes)
  , ResourceId
  , SourceLocation (path)
  , inventoryError
  , mkResourceId
  , nameText
  , resourceIdText
  )
import Nagare.Resource.Wire (canonicalValue)

-- | Add one backup bundle per retained, durable PVC among the compiled
-- members. Throwaway volumes and members of other kinds are ignored.
compileVolumeBackups ::
  DatabaseBackupTarget ->
  ResourceId ->
  SourceLocation ->
  Map ResourceId (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) [(ResourceBundle, Map ResourceId (ManagedResource, ByteString))]
compileVolumeBackups target namespaceId source native =
  traverse
    (compileOne target namespaceId source)
    [ (claim, bytes)
    | (claim, bytes) <- Map.elems native
    , Kubernetes _ "" kind (Just _) _ <- [claim ^. #address]
    , nameText kind == "persistentvolumeclaim"
    , claim ^. #lifecycle == Retain
    , Durable _ <- [claim ^. #dataPolicy]
    ]

compileOne ::
  DatabaseBackupTarget ->
  ResourceId ->
  SourceLocation ->
  (ManagedResource, ByteString) ->
  Either (NonEmpty InventoryError) (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileOne target namespaceId source (claim, claimBytes) = do
  recovery <- case claim ^. #dataPolicy of
    Durable intent -> Right intent
    Stateless -> Left (invalid "a backed-up volume must be durable")
  claimValue <- first (invalid . T.pack . show) (Yaml.decodeEither' claimBytes :: Either Yaml.ParseException Value)
  (app, volume, namespaceName, claimName) <- case claimValue of
    Object root
      | Just (Object metadata) <- KM.lookup "metadata" root
      , Just (String name) <- KM.lookup "name" metadata
      , Just (String ns) <- KM.lookup "namespace" metadata
      , Just (Object labels) <- KM.lookup "labels" metadata
      , Just (String appName) <- KM.lookup "nagare.dev/app" labels
      , Just (String volumeName) <- KM.lookup "nagare.dev/volume" labels
      , name == pvcName appName volumeName ->
          Right (appName, volumeName, ns, name)
    _ -> Left (invalid "a backed-up volume claim lacks its app and volume labels")
  (scope, key, role) <- case T.splitOn "/" (resourceIdText (claim ^. #identity)) of
    [scopePart, keyPart, rolePart] -> Right (scopePart, keyPart, rolePart)
    _ -> Left (invalid "a backed-up volume claim has a malformed identity")
  let schedule = volumeBackupScheduleName app volume
      memberId suffix = first invalid (mkResourceId (scope <> "/" <> key <> "/" <> role <> suffix))
      metadata = object ["name" .= schedule, "namespace" .= namespaceName]
      accountObject =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("ServiceAccount" :: Text)
          , "metadata" .= metadata
          ]
      roleObject =
        object
          [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
          , "kind" .= ("Role" :: Text)
          , "metadata" .= metadata
          , "rules"
              .= toJSON
                [ object
                    [ "apiGroups" .= toJSON ([""] :: [Text])
                    , "resources" .= toJSON (["persistentvolumeclaims"] :: [Text])
                    , "resourceNames" .= toJSON [claimName]
                    , "verbs" .= toJSON (["get"] :: [Text])
                    ]
                ]
          ]
      bindingObject =
        object
          [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
          , "kind" .= ("RoleBinding" :: Text)
          , "metadata" .= metadata
          , "subjects"
              .= toJSON
                [object ["kind" .= ("ServiceAccount" :: Text), "name" .= schedule, "namespace" .= namespaceName]]
          , "roleRef"
              .= object
                [ "apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
                , "kind" .= ("Role" :: Text)
                , "name" .= schedule
                ]
          ]
      signingObject =
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("Secret" :: Text)
          , "type" .= ("Opaque" :: Text)
          , "metadata"
              .= object
                [ "name" .= (schedule <> "-signing")
                , "namespace" .= namespaceName
                , "labels" .= object ["nagare.dev/volume-backup" .= schedule]
                , "annotations" .= object ["nagare.dev/backup-signing-template" .= ("v1" :: Text)]
                ]
          ]
  cronValue <-
    first
      (invalid . T.pack . show)
      ( Yaml.decodeEither'
          ( renderInventoryVolumeBackupCronJob
              (target ^. #objective)
              namespaceName
              app
              volume
              (target ^. #backend)
              7
          ) ::
          Either Yaml.ParseException Value
      )
  cluster <- case claim ^. #address of
    Kubernetes clusterId _ _ _ _ -> Right clusterId
    _ -> Left (invalid "a backed-up volume claim has no Kubernetes address")
  accountId <- memberId "-backup-account"
  roleId <- memberId "-backup-read-role"
  bindingId <- memberId "-backup-read-binding"
  signingId <- memberId "-backup-signing-key"
  cronId <- memberId "-backup"
  let namespaceDeps extra = map OrderedAfter (namespaceId : extra)
      location suffix = source {path = path source <> "/volume/" <> volume <> "/" <> suffix}
  let bindOne = bindMember cluster
  members <-
    sequence
      [ bindOne accountId DeleteWhenUnreferenced Stateless Private (namespaceDeps []) (location "backup-account") accountObject
      , bindOne roleId DeleteWhenUnreferenced Stateless Private (namespaceDeps []) (location "backup-read-role") roleObject
      , bindOne bindingId DeleteWhenUnreferenced Stateless Private (namespaceDeps [accountId, roleId]) (location "backup-read-binding") bindingObject
      , bindOne signingId Retain (Durable recovery) Secret (namespaceDeps []) (location "backup-signing-key") signingObject
      , bindOne cronId DeleteWhenUnreferenced Stateless Private (namespaceDeps [claim ^. #identity, bindingId, signingId]) (location "backup") cronValue
      ]
  pure
    ( ResourceBundle [Managed member | (member, _) <- members] [] [] [] [] []
    , Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
    )
  where
    invalid message =
      inventoryError "invalid-volume-backup" message
        & #sources
        .~ [source]
        & (:| [])
    bindMember cluster resource lifecycle dataPolicy sensitivity dependencies location value = do
      canonical <- first invalid (canonicalValue value)
      (declaration, bytes) <-
        first
          (:| [])
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resource
                , ownerScope = claim ^. #owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest canonical
                , lifecyclePolicy = lifecycle
                , inputDataPolicy = dataPolicy
                , inputSensitivity = sensitivity
                , sourceLocation = location
                }
          )
      pure (declaration {dependencies = dependencies}, bytes)
