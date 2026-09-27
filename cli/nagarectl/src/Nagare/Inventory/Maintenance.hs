-- | Compile one PostgreSQL maintenance session as a reviewed operation over
-- an existing accepted database. The operation owns no duplicate StatefulSet;
-- its private fence captures the source and every affected writer at planning.
module Nagare.Inventory.Maintenance
  ( MaintenanceRequest (..)
  , MaintenanceSourceProof (..)
  , maintenanceSourceProof
  , compileMaintenanceScope
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Database.Render (dbPvcName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (mkServiceName)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data MaintenanceRequest = MaintenanceRequest
  { maintenanceDatabase :: !Text
  , maintenanceNamespace :: !Text
  , maintenanceSession :: !Text
  , maintenanceTargetRevision :: !ScopeRevision
  , maintenanceStatefulUid :: !PhysicalIdentity
  , maintenancePvcUid :: !PhysicalIdentity
  , maintenancePodUid :: !PhysicalIdentity
  , maintenanceRecoveryScope :: !ScopeDeclaration
  , maintenanceRecoveryRevision :: !ScopeRevision
  , maintenanceRecoveryJobUid :: !PhysicalIdentity
  , maintenanceRecoveryId :: !Text
  , maintenanceSource :: !SourceLocation
  }
  deriving stock (Eq, Show)

data MaintenanceSourceProof = MaintenanceSourceProof
  { maintenanceSourceScope :: !Text
  , maintenanceSourceGeneration :: !Integer
  , maintenanceSourceDigest :: !ContentDigest
  , maintenanceSourceStateful :: !ResourceId
  , maintenanceSourceStatefulUid :: !PhysicalIdentity
  , maintenanceSourcePvc :: !ResourceId
  , maintenanceSourcePvcUid :: !PhysicalIdentity
  , maintenanceSourcePodUid :: !PhysicalIdentity
  , maintenanceSourceRecovery :: !Text
  , maintenanceSourceRecoveryGeneration :: !Integer
  , maintenanceSourceRecoveryDigest :: !ContentDigest
  , maintenanceSourceRecoveryJob :: !ResourceId
  , maintenanceSourceRecoveryJobUid :: !PhysicalIdentity
  }
  deriving stock (Eq, Show)

maintenanceSourceProof :: ScopeDeclaration -> Either Text (Maybe MaintenanceSourceProof)
maintenanceSourceProof scope
  | Map.notMember "maintenance.session" fields = Right Nothing
  | otherwise = Just <$> do
      generationText <- required "maintenance.target.generation"
      generation <- case reads (T.unpack generationText) of
        [(value, "")] | value > 0 -> Right value
        _ -> Left "maintenance target generation is invalid"
      MaintenanceSourceProof
        <$> required "maintenance.target.scope"
        <*> pure generation
        <*> (required "maintenance.target.revision" >>= mkContentDigest)
        <*> (required "maintenance.target.statefulset" >>= mkResourceId)
        <*> (required "maintenance.target.statefulset.uid" >>= mkPhysicalIdentity)
        <*> (required "maintenance.target.pvc" >>= mkResourceId)
        <*> (required "maintenance.target.pvc.uid" >>= mkPhysicalIdentity)
        <*> (required "maintenance.target.pod.uid" >>= mkPhysicalIdentity)
        <*> required "maintenance.recovery.scope"
        <*> (required "maintenance.recovery.generation" >>= parseGeneration)
        <*> (required "maintenance.recovery.revision" >>= mkContentDigest)
        <*> (required "maintenance.recovery.job" >>= mkResourceId)
        <*> (required "maintenance.recovery.job.uid" >>= mkPhysicalIdentity)
  where
    fields = scopeOverrides scope
    required key = maybe (Left ("maintenance scope lacks " <> key)) Right
      (Map.lookup key fields)
    parseGeneration value = case reads (T.unpack value) of
      [(number, "")] | number > 0 -> Right number
      _ -> Left "maintenance recovery generation is invalid"

compileMaintenanceScope
  :: MaintenanceRequest -> ScopeDeclaration
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either (NonEmpty InventoryError) ScopeDeclaration
compileMaintenanceScope request accepted native = do
  let invalid message = inventoryError "invalid-maintenance" message
        & #scopes .~ [scopeId accepted, scopeId (maintenanceRecoveryScope request)]
        & #sources .~ [maintenanceSource request]
        & (:| [])
      db = maintenanceDatabase request
      ns = maintenanceNamespace request
      recovery = maintenanceRecoveryScope request
      select scope group kind name =
        [member | bundle <- scopeBundles scope,
          Managed member <- declarations bundle,
          case member ^. #address of
            Kubernetes _ api nativeKind (Just nativeNamespace) nativeName ->
              api == group && nameText nativeKind == kind
                && nameText nativeNamespace == ns && nameText nativeName == name
            _ -> False]
      one label = \case
        [member] -> Right member
        _ -> Left (invalid ("maintenance requires one accepted " <> label))
      nativeValue member = case Map.lookup (member ^. #identity) native of
        Just (bound, bytes) | bound == member ->
          first (invalid . T.pack) (eitherDecodeStrict' bytes)
        _ -> Left (invalid "maintenance lacks matching accepted private native bytes")
  _ <- first invalid (mkServiceName db)
  _ <- first invalid (mkServiceName ns)
  _ <- first invalid (mkServiceName (maintenanceSession request))
  unless (T.length (maintenanceSession request) <= 20)
    (Left (invalid "maintenance session ID exceeds 20 characters"))
  unless (scopeKind (scopeId accepted) `elem` [Application, Standalone])
    (Left (invalid "maintenance requires an accepted database scope"))
  stateful <- one "database StatefulSet" (select accepted "apps" "statefulset" db)
  pvc <- one "database PVC" (select accepted "" "persistentvolumeclaim" (dbPvcName db))
  backupJob <- case [member | bundle <- scopeBundles recovery,
    Managed member <- declarations bundle,
    case member ^. #address of
      Kubernetes _ "batch" kind (Just namespace) _ ->
        nameText kind == "job" && nameText namespace == ns
      _ -> False] of
    [member] -> Right member
    _ -> Left (invalid "maintenance recovery has no unique accepted Job")
  statefulValue <- nativeValue stateful
  _ <- nativeValue pvc
  _ <- nativeValue backupJob
  unless (case (stateful ^. #address, pvc ^. #address,
      backupJob ^. #address) of
      (Kubernetes statefulCluster _ _ _ _, Kubernetes pvcCluster _ _ _ _,
        Kubernetes backupCluster _ _ _ _) ->
          statefulCluster == pvcCluster && pvcCluster == backupCluster
      _ -> False)
    (Left (invalid "maintenance target and recovery belong to different clusters"))
  let expectedSource = scopeIdText (scopeId accepted)
      recoveryFields = scopeOverrides recovery
      sourceScope = Map.lookup "backup.source.scope" recoveryFields
        <|> Map.lookup "scheduled.backup.source.scope" recoveryFields
      recoveryId = Map.lookup "backup.id" recoveryFields
        <|> Map.lookup "scheduled.backup.id" recoveryFields
      sourceStateful = Map.lookup "backup.source.statefulset" recoveryFields
        <|> Map.lookup "scheduled.backup.source.statefulset" recoveryFields
      sourceStatefulUid = Map.lookup "backup.source.statefulset.uid" recoveryFields
        <|> Map.lookup "scheduled.backup.source.statefulset.uid" recoveryFields
      sourcePvc = Map.lookup "backup.source.pvc" recoveryFields
        <|> Map.lookup "scheduled.backup.source.pvc" recoveryFields
      sourcePvcUid = Map.lookup "backup.source.pvc.uid" recoveryFields
        <|> Map.lookup "scheduled.backup.source.pvc.uid" recoveryFields
      sourceGeneration = Map.lookup "backup.source.generation" recoveryFields
        <|> Map.lookup "scheduled.backup.source.generation" recoveryFields
      sourceRevision = Map.lookup "backup.source.revision" recoveryFields
        <|> Map.lookup "scheduled.backup.source.revision" recoveryFields
  unless (sourceScope == Just expectedSource
      && recoveryId == Just (maintenanceRecoveryId request)
      && sourceGeneration == Just (T.pack (show (generationNumber
        (revisionGeneration (maintenanceTargetRevision request)))))
      && sourceRevision == Just (digestText
        (revisionDigest (maintenanceTargetRevision request)))
      && sourceStateful == Just (resourceIdText (stateful ^. #identity))
      && sourceStatefulUid == Just (physicalIdentityText
        (maintenanceStatefulUid request))
      && sourcePvc == Just (resourceIdText (pvc ^. #identity))
      && sourcePvcUid == Just (physicalIdentityText (maintenancePvcUid request)))
    (Left (invalid "maintenance recovery belongs to another target incarnation or ID"))
  unless (case statefulValue of
      Object root | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object labels) <- KM.lookup "labels" metadata ->
            KM.lookup "nagare.dev/engine" labels == Just (String "postgres")
      _ -> False)
    (Left (invalid "reviewed maintenance currently requires PostgreSQL"))
  owner <- first invalid (mkScopeId Standalone
    ("database-maintenance-" <> ns <> "-" <> db <> "-"
      <> maintenanceSession request))
  key <- first invalid (mkLogicalKey (maintenanceSession request))
  role <- first invalid (mkName "session")
  let operationId = mintResourceId owner key role
      intent = object
        [ "session" .= maintenanceSession request
        , "database" .= db
        , "namespace" .= ns
        , "target" .= resourceIdText (stateful ^. #identity)
        , "targetRevision" .= digestText
            (revisionDigest (maintenanceTargetRevision request))
        , "targetUid" .= physicalIdentityText (maintenanceStatefulUid request)
        , "pvc" .= resourceIdText (pvc ^. #identity)
        , "pvcUid" .= physicalIdentityText (maintenancePvcUid request)
        , "podUid" .= physicalIdentityText (maintenancePodUid request)
        , "recovery" .= scopeIdText (scopeId recovery)
        , "recoveryRevision" .= digestText
            (revisionDigest (maintenanceRecoveryRevision request))
        , "recoveryJob" .= resourceIdText (backupJob ^. #identity)
        , "recoveryJobUid" .= physicalIdentityText
            (maintenanceRecoveryJobUid request)
        , "recoveryId" .= maintenanceRecoveryId request ]
  intentBytes <- first invalid (canonicalValue intent)
  let operation = DeclaredOperation operationId (stateful ^. #identity :| [])
        (sort [ContentInput (contentDigest intentBytes),
          ContentInput (revisionDigest (maintenanceRecoveryRevision request))])
        OperatorRecovery MaintainData
      overrides = Map.fromList
        [ ("maintenance.session", maintenanceSession request)
        , ("maintenance.database", db)
        , ("maintenance.namespace", ns)
        , ("maintenance.target.scope", expectedSource)
        , ("maintenance.target.generation", T.pack (show (generationNumber
            (revisionGeneration (maintenanceTargetRevision request)))))
        , ("maintenance.target.revision", digestText
            (revisionDigest (maintenanceTargetRevision request)))
        , ("maintenance.target.statefulset", resourceIdText (stateful ^. #identity))
        , ("maintenance.target.statefulset.uid", physicalIdentityText
            (maintenanceStatefulUid request))
        , ("maintenance.target.pvc", resourceIdText (pvc ^. #identity))
        , ("maintenance.target.pvc.uid", physicalIdentityText (maintenancePvcUid request))
        , ("maintenance.target.pod.uid", physicalIdentityText (maintenancePodUid request))
        , ("maintenance.recovery.scope", scopeIdText (scopeId recovery))
        , ("maintenance.recovery.generation", T.pack (show (generationNumber
            (revisionGeneration (maintenanceRecoveryRevision request)))))
        , ("maintenance.recovery.revision", digestText
            (revisionDigest (maintenanceRecoveryRevision request)))
        , ("maintenance.recovery.job", resourceIdText (backupJob ^. #identity))
        , ("maintenance.recovery.job.uid", physicalIdentityText
            (maintenanceRecoveryJobUid request))
        , ("maintenance.recovery.id", maintenanceRecoveryId request)
        ]
  base <- mkScopeDeclaration owner [ResourceBundle [] [] [] [] [operation] []]
  pure (withScopeOverrides overrides
    (withScopeConfigDigest (contentDigest intentBytes) base))
