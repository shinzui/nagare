-- | Stable inventory identity and direct Kubernetes declarations for a database.
-- Credential material is generated at guarded execution from a data-free
-- template; the backend-specific backup CronJob is supplied as a typed object.
module Nagare.Resource.Database
  ( databaseResourceId
  , DatabaseDirectInput (..)
  , compileDatabaseDirect
  , compileDatabaseBundle
  ) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Nagare.Dsl.Database (Database (..), engineMemoryConfig)
import Nagare.Dsl.Database.Render (databaseCredentialTemplate, databaseObjects, dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (databaseNameText, namespaceText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types

databaseResourceId :: ScopeId -> Name -> Database -> Either Text ResourceId
databaseResourceId owner role database =
  mintResourceId owner <$> key <*> pure role
  where
    key = maybe (mkLogicalKey (databaseNameText (database ^. #name))) Right (database ^. #logicalKey)

-- | The digest callback is supplied by nagarectl, which owns content hashing.
-- The resulting values must be bound to canonical bytes by its native adapter.
data DatabaseDirectInput = DatabaseDirectInput
  { directDatabase :: !Database
  , directOwnerScope :: !ScopeId
  , directClusterId :: !ResourceId
  , directNamespaceId :: !(Maybe ResourceId)
  , directRecoveryIntent :: !RecoveryIntent
  , directSourceLocation :: !SourceLocation
  }

-- | Compile the credential template and every direct object emitted by the
-- database renderer, preserving one stable logical key across all roles.
-- The returned objects are the native members corresponding to the bundle.
compileDatabaseDirect
  :: (Value -> Either Text ContentDigest)
  -> DatabaseDirectInput
  -> Either (NonEmpty InventoryError) (ResourceBundle, [(ResourceId, Value)])
compileDatabaseDirect digestOf input = do
  let objects = databaseCredentialTemplate (directDatabase input) : databaseObjects (directDatabase input)
  unless (length objects == length roles)
    (Left (invalid "database renderer membership differs from the declared roles"))
  members <- traverse compileOne (zip roles objects)
  pure
    ( ResourceBundle (map (Managed . fst) members) [] [] [] [] []
    , [(resource ^. #identity, value) | (resource, value) <- members]
    )
  where
    roles = ["credential", "pvc"]
      <> maybe [] (const ["configmap"]) (engineMemoryConfig (directDatabase input ^. #engine))
      <> ["service", "statefulset"]
    compileOne (roleText, value) = do
      role <- first invalid (mkName roleText)
      resource <- first invalid (databaseResourceId (directOwnerScope input) role (directDatabase input))
      prerequisites <- if roleText == "statefulset"
        then traverse prerequisite (["credential", "pvc"] <> maybe [] (const ["configmap"]) (engineMemoryConfig (directDatabase input ^. #engine)) <> ["service"])
        else pure []
      digest <- first invalid (digestOf value)
      declaration <- first single $ compileKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = directOwnerScope input
          , clusterId = directClusterId input
          , inputObject = value
          , objectDigest = digest
          , lifecyclePolicy = if not isThrowaway && roleText `elem` ["credential", "pvc"]
              then Retain else DeleteWhenUnreferenced
          , inputDataPolicy = if roleText `elem` ["pvc", "credential"] && not isThrowaway then Durable (directRecoveryIntent input) else Stateless
          , inputSensitivity = if roleText == "credential" then Secret else Private
          , sourceLocation = directSourceLocation input
          }
      pure (declaration {dependencies = map OrderedAfter (maybe [] pure (directNamespaceId input) <> prerequisites)}, value)
    prerequisite roleText = do
      role <- first invalid (mkName roleText)
      first invalid (databaseResourceId (directOwnerScope input) role (directDatabase input))
    isThrowaway = directDatabase input ^. #retention == Dsl.Delete
    invalid message = inventoryError "invalid-database-declaration" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input]
      & single
    single err = err :| []

-- | Extend the direct database objects with the exact scheduled backup
-- CronJob supplied by the caller's selected storage backend. Checking its
-- address here prevents a backend renderer from silently adding a different
-- resource after the inventory has validated ownership.
compileDatabaseBundle
  :: (Value -> Either Text ContentDigest)
  -> DatabaseDirectInput
  -> Value
  -> Either (NonEmpty InventoryError) (ResourceBundle, [(ResourceId, Value)])
compileDatabaseBundle digestOf input backupObject = do
  when (directDatabase input ^. #retention == Dsl.Delete)
    (Left (invalid "throwaway database must not declare a scheduled backup"))
  (bundle, native) <- compileDatabaseDirect digestOf input
  role <- first invalid (mkName "backup")
  resource <- first invalid (databaseResourceId (directOwnerScope input) role (directDatabase input))
  credential <- first invalid (databaseResourceId (directOwnerScope input) (known "credential") (directDatabase input))
  stateful <- first invalid (databaseResourceId (directOwnerScope input) (known "statefulset") (directDatabase input))
  let accountName = "nagare-dbbackup-" <> databaseNameText (directDatabase input ^. #name)
      databaseName = databaseNameText (directDatabase input ^. #name)
      namespaceName = namespaceText (directDatabase input ^. #namespace)
      metadata = object ["name" .= accountName, "namespace" .= namespaceName]
      accountObject = object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ServiceAccount" :: Text)
        , "metadata" .= metadata
        ]
      signingObject = object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Secret" :: Text)
        , "type" .= ("Opaque" :: Text)
        , "metadata" .= object
            [ "name" .= (accountName <> "-signing")
            , "namespace" .= namespaceName
            , "labels" .= object ["nagare.dev/database" .= databaseName]
            , "annotations" .= object ["nagare.dev/backup-signing-template" .= ("v1" :: Text)]
            ]
        ]
      roleObject = object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("Role" :: Text)
        , "metadata" .= metadata
        , "rules" .= toJSON
            [ object ["apiGroups" .= toJSON (["apps"] :: [Text]), "resources" .= toJSON (["statefulsets"] :: [Text])
                , "resourceNames" .= toJSON [databaseName], "verbs" .= toJSON (["get"] :: [Text])]
            , object ["apiGroups" .= toJSON ([""] :: [Text]), "resources" .= toJSON (["persistentvolumeclaims"] :: [Text])
                , "resourceNames" .= toJSON [dbPvcName databaseName], "verbs" .= toJSON (["get"] :: [Text])]
            ]
        ]
      bindingObject = object
        [ "apiVersion" .= ("rbac.authorization.k8s.io/v1" :: Text)
        , "kind" .= ("RoleBinding" :: Text)
        , "metadata" .= metadata
        , "subjects" .= toJSON [object
            ["kind" .= ("ServiceAccount" :: Text), "name" .= accountName, "namespace" .= namespaceName]]
        , "roleRef" .= object ["apiGroup" .= ("rbac.authorization.k8s.io" :: Text)
            , "kind" .= ("Role" :: Text), "name" .= accountName]
        ]
  (accountId, accountDeclaration) <- compileCompanion "backup-account" accountObject []
  (roleId, roleDeclaration) <- compileCompanion "backup-read-role" roleObject []
  (bindingId, bindingDeclaration) <- compileCompanion "backup-read-binding" bindingObject [accountId, roleId]
  signingId <- first invalid (databaseResourceId (directOwnerScope input) (known "backup-signing-key") (directDatabase input))
  signingDigest <- first invalid (digestOf signingObject)
  signing <- first single $ compileKubernetesObject KubernetesInput
    { resourceId = signingId
    , ownerScope = directOwnerScope input
    , clusterId = directClusterId input
    , inputObject = signingObject
    , objectDigest = signingDigest
    , lifecyclePolicy = Retain
    , inputDataPolicy = Durable (directRecoveryIntent input)
    , inputSensitivity = Secret
    , sourceLocation = directSourceLocation input
    }
  let signingDeclaration = signing
        {dependencies = map OrderedAfter (maybe [] pure (directNamespaceId input))}
  digest <- first invalid (digestOf backupObject)
  declaration <- first single $ compileKubernetesObject
    KubernetesInput
      { resourceId = resource
      , ownerScope = directOwnerScope input
      , clusterId = directClusterId input
      , inputObject = backupObject
      , objectDigest = digest
      , lifecyclePolicy = DeleteWhenUnreferenced
      , inputDataPolicy = Stateless
      , inputSensitivity = Private
      , sourceLocation = directSourceLocation input
      }
  expectedName <- first invalid (mkName ("nagare-dbbackup-" <> databaseNameText (directDatabase input ^. #name)))
  expectedNamespace <- first invalid (mkName (namespaceText (directDatabase input ^. #namespace)))
  unless (address declaration == Kubernetes (directClusterId input) "batch" (known "cronjob") (Just expectedNamespace) expectedName)
    (Left (invalid "database backup CronJob has an unexpected address"))
  unless (backupUsesAccount accountName backupObject)
    (Left (invalid "database backup CronJob does not use its dedicated source reader account"))
  let guarded = declaration {dependencies = map OrderedAfter (maybe [] pure (directNamespaceId input) <> [credential, stateful, bindingId, signingId])}
  pure ( bundle {declarations = declarations bundle <>
           map Managed [accountDeclaration, roleDeclaration, bindingDeclaration, signingDeclaration, guarded]}
       , native <> [(accountId, accountObject), (roleId, roleObject), (bindingId, bindingObject)
           , (signingId, signingObject), (resource, backupObject)] )
  where
    known value = either (error . show) id (mkName value)
    invalid :: Text -> NonEmpty InventoryError
    invalid message = single (inventoryError "invalid-database-backup" message
      & #scopes .~ [directOwnerScope input]
      & #sources .~ [directSourceLocation input])
    single err = err :| []
    backupUsesAccount accountName (Object root)
      | Just (Object cronSpec) <- KeyMap.lookup "spec" root
      , Just (Object jobTemplate) <- KeyMap.lookup "jobTemplate" cronSpec
      , Just (Object jobSpec) <- KeyMap.lookup "spec" jobTemplate
      , Just (Object podTemplate) <- KeyMap.lookup "template" jobSpec
      , Just (Object podSpec) <- KeyMap.lookup "spec" podTemplate =
          KeyMap.lookup "serviceAccountName" podSpec == Just (String accountName)
    backupUsesAccount _ _ = False
    compileCompanion roleName value predecessors = do
      companionId <- first invalid (databaseResourceId (directOwnerScope input) (known roleName) (directDatabase input))
      companionDigest <- first invalid (digestOf value)
      companion <- first single $ compileKubernetesObject
        KubernetesInput
          { resourceId = companionId
          , ownerScope = directOwnerScope input
          , clusterId = directClusterId input
          , inputObject = value
          , objectDigest = companionDigest
          , lifecyclePolicy = DeleteWhenUnreferenced
          , inputDataPolicy = Stateless
          , inputSensitivity = Private
          , sourceLocation = directSourceLocation input
          }
      pure (companionId, companion
        {dependencies = map OrderedAfter (maybe [] pure (directNamespaceId input) <> predecessors)})
