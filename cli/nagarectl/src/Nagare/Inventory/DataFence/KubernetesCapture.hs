-- | Read the current Kubernetes target and every accepted managed writer into
-- a private review intent. This is planning input, never exclusion proof:
-- acquisition rechecks the exact identities and installs the native guards.
module Nagare.Inventory.DataFence.KubernetesCapture
  ( KubernetesCaptureRequest (..)
  , KubernetesCaptureTransport (..)
  , kubectlKubernetesCaptureTransport
  , captureKubernetesFence
  )
where

import Control.Monad (forM, unless)
import Data.Aeson (Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig
  )
import Nagare.Inventory.DataFence.DeploymentWriter qualified as Deployment
import Nagare.Inventory.DataFence.KubernetesExclusion
import Nagare.Inventory.DataFence.KubernetesIntent
import Nagare.Inventory.DataFence.MountGuardRuntime
import Nagare.Inventory.DataFence.ScheduledWriter
import Nagare.Inventory.DataFence.ServiceState
import Nagare.Inventory.DataFence.StatefulWriter
import Nagare.Inventory.DataFence.VolumeState
import Nagare.Inventory.DataFence.WriterInventory
import Nagare.Inventory.Store
  ( DataFencePhase (FenceAcquiring)
  , DataFenceRecord (..)
  , ScopeRevision
  )
import Nagare.Resource.Inventory (Declaration, ManagedResource (..))
import Nagare.Resource.Types

data KubernetesCaptureRequest = KubernetesCaptureRequest
  { captureBinding :: !ContextBinding
  , captureAccepted :: !(Map ScopeId ScopeRevision)
  , captureSession :: !Text
  , captureVolumeResource :: !ResourceId
  , captureDependencyRoot :: !ResourceId
  , captureServiceResource :: !(Maybe ResourceId)
  , captureRecoveryArtifact :: !Text
  , captureRecoveryDigest :: !ContentDigest
  , captureRestoreJob :: !(Maybe (Text, Text, Text))
  }

data KubernetesCaptureTransport = KubernetesCaptureTransport
  { captureGuardTransport :: !MountGuardTransport
  , captureVolumeTransport :: !VolumeTransport
  , captureStatefulTransport :: !StatefulWriterTransport
  , captureDeploymentTransport :: !Deployment.DeploymentWriterTransport
  , captureScheduleTransport :: !ScheduledWriterTransport
  , captureServiceTransport :: !ServiceTransport
  }

kubectlKubernetesCaptureTransport ::
  KubernetesRuntimeConfig ->
  KubernetesCaptureTransport
kubectlKubernetesCaptureTransport config =
  KubernetesCaptureTransport
    (kubectlMountGuardTransport config)
    (kubectlVolumeTransport config)
    (kubectlStatefulWriterTransport config)
    (Deployment.kubectlDeploymentWriterTransport config)
    (kubectlScheduledWriterTransport config)
    (kubectlServiceTransport config)

captureKubernetesFence ::
  KubernetesCaptureTransport ->
  [Declaration] ->
  Map ResourceId (ManagedResource, ByteString) ->
  KubernetesCaptureRequest ->
  IO (Either Text DataFenceRecord)
captureKubernetesFence transport declarations native request = do
  let target = captureVolumeResource request
      root = captureDependencyRoot request
      route = captureServiceResource request
  case do
    unless
      (not (T.null (captureRecoveryArtifact request)))
      (Left "data fence recovery artifact is empty")
    volumeAddress <- acceptedAddress native target "" "persistentvolumeclaim"
    let (cluster, namespace, claim) = volumeAddress
    pure (cluster, namespace, claim) of
    Left reason -> pure (Left reason)
    Right (cluster, namespace, claim) -> do
      claimResult <- readClaim (captureVolumeTransport transport) namespace claim
      case claimResult >>= parseClaim namespace claim of
        Left reason -> pure (Left reason)
        Right (claimUid, volumeName) -> do
          volumeResult <- readVolume (captureVolumeTransport transport) volumeName
          case volumeResult >>= parseVolume volumeName of
            Left reason -> pure (Left reason)
            Right (volumeUid, backing) -> do
              service <- captureService transport native cluster route
              case service of
                Left reason -> pure (Left reason)
                Right servicePin -> do
                  let routes = maybe [] (\(resource, _, _) -> [resource]) servicePin
                      candidates =
                        discoverWriterCandidatesForRoutes
                          root
                          routes
                          cluster
                          claim
                          declarations
                          native
                  case candidates of
                    Left reason -> pure (Left reason)
                    Right selected -> do
                      writers <- forM selected (captureWriter transport)
                      let assembled = do
                            captured <- sequence writers
                            claimPhysical <- mkPhysicalIdentity claimUid
                            let servicePhysical =
                                  maybe
                                    []
                                    ( \(resource, uid, _) ->
                                        [(resource, uid)]
                                    )
                                    servicePin
                                writerPhysical =
                                  [ (resource, uid)
                                  | (resource, uid, _) <- captured
                                  ]
                                physical =
                                  Map.fromList
                                    ( [(target, claimPhysical)]
                                        <> servicePhysical
                                        <> writerPhysical
                                    )
                                provider =
                                  object
                                    ( [ "version" .= (1 :: Int)
                                      , "provider" .= ("kubernetes" :: Text)
                                      , "cluster" .= cluster
                                      , "dependencyRoot" .= root
                                      , "volume"
                                          .= object
                                            [ "resource" .= target
                                            , "namespace" .= namespace
                                            , "claim" .= claim
                                            , "claimUid" .= claimUid
                                            , "pv" .= volumeName
                                            , "pvUid" .= volumeUid
                                            , "backing" .= backingValue backing
                                            ]
                                      ]
                                        <> maybe
                                          []
                                          ( \(_, _, value) ->
                                              ["service" .= value]
                                          )
                                          servicePin
                                        <> maybe
                                          []
                                          ( \(name, uid, principal) ->
                                              [ "restoreJob"
                                                  .= object
                                                    [ "name" .= name
                                                    , "uid" .= uid
                                                    , "controllerPrincipal" .= principal
                                                    ]
                                              ]
                                          )
                                          (captureRestoreJob request)
                                    )
                                record =
                                  DataFenceRecord
                                    { fenceContext = captureBinding request
                                    , fenceSession = captureSession request
                                    , fenceTransaction = Nothing
                                    , fenceAccepted = captureAccepted request
                                    , fencePhysical = physical
                                    , fenceTargets = Set.singleton target
                                    , fenceAffected =
                                        Set.fromList
                                          [resource | (resource, _, _) <- captured]
                                    , fenceRecoveryArtifact = captureRecoveryArtifact request
                                    , fenceRecoveryDigest = captureRecoveryDigest request
                                    , fenceSavedWriters =
                                        Map.fromList
                                          [(resource, value) | (resource, _, value) <- captured]
                                    , fenceProviderIntent = Just provider
                                    , fencePhase = FenceAcquiring
                                    , fenceAcquiredAt = ""
                                    }
                            unless
                              ( Map.size physical
                                  == 1
                                    + length captured
                                    + length servicePhysical
                              )
                              (Left "captured Kubernetes identities overlap")
                            intent <- decodeKubernetesFenceIntent record
                            validateKubernetesWriterInventory intent selected
                            pure record
                      case assembled of
                        Left reason -> pure (Left reason)
                        Right record -> do
                          let ContextBinding context _ = captureBinding request
                              validator =
                                mkKubernetesExclusion
                                  context
                                  (captureAccepted request)
                                  declarations
                                  native
                                  (captureGuardTransport transport)
                                  (captureVolumeTransport transport)
                                  (captureStatefulTransport transport)
                                  (captureDeploymentTransport transport)
                                  (captureServiceTransport transport)
                                  (captureScheduleTransport transport)
                          checked <- validateKubernetesExclusion validator record
                          pure (record <$ checked)

captureService ::
  KubernetesCaptureTransport ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  Maybe ResourceId ->
  IO (Either Text (Maybe (ResourceId, PhysicalIdentity, Value)))
captureService _ _ _ Nothing = pure (Right Nothing)
captureService transport native cluster (Just resource) =
  case acceptedAddress native resource "" "service" of
    Left reason -> pure (Left reason)
    Right (owner, namespace, name)
      | owner /= cluster -> pure (Left "fenced Service belongs to another cluster")
      | otherwise -> do
          current <- readService (captureServiceTransport transport) namespace name
          pure $ do
            value <- current
            metadata <- objectField "metadata" =<< asObject "Service" value
            exactName namespace name metadata
            uid <- textField "uid" metadata
            spec <- objectField "spec" =<< asObject "Service" value
            clusterIP <- textField "clusterIP" spec
            selector <- textMap =<< objectField "selector" spec
            pin <- mkServicePin resource namespace name uid clusterIP selector
            physical <- mkPhysicalIdentity uid
            pure
              ( Just
                  ( resource
                  , physical
                  , object
                      [ "resource" .= resource
                      , "namespace" .= serviceNamespace pin
                      , "name" .= serviceName pin
                      , "uid" .= serviceUid pin
                      , "clusterIP" .= serviceClusterIP pin
                      , "selector" .= serviceSelector pin
                      ]
                  )
              )

captureWriter ::
  KubernetesCaptureTransport ->
  WriterCandidate ->
  IO (Either Text (ResourceId, PhysicalIdentity, Value))
captureWriter transport candidate = case candidateAddress candidate of
  Kubernetes _ _ _ (Just namespace) name -> do
    let ns = nameText namespace
        nativeName = nameText name
        resource = candidateResource candidate
        mounted = candidateByMount candidate
    current <- case candidateKind candidate of
      StatefulSetWriter ->
        readStatefulWriter
          (captureStatefulTransport transport)
          ns
          nativeName
      DeploymentWriter ->
        Deployment.readDeploymentWriter
          (captureDeploymentTransport transport)
          ns
          nativeName
      CronJobWriter ->
        readScheduledWriter
          (captureScheduleTransport transport)
          ns
          nativeName
      _ -> pure (Left "accepted writer has no capture control")
    pure $ do
      value <- current
      metadata <- objectField "metadata" =<< asObject "writer" value
      exactName ns nativeName metadata
      uid <- textField "uid" metadata
      physical <- mkPhysicalIdentity uid
      spec <- objectField "spec" =<< asObject "writer" value
      saved <- case candidateKind candidate of
        StatefulSetWriter -> do
          replicas <- intField "replicas" spec
          digest <- digestStatefulWriterSpec value
          _ <- mkStatefulWriterPin ns nativeName uid replicas digest
          pure
            ( object
                [ "kind" .= ("StatefulSet" :: Text)
                , "namespace" .= ns
                , "name" .= nativeName
                , "uid" .= uid
                , "replicas" .= replicas
                , "specDigest" .= digest
                , "mountsTarget" .= mounted
                ]
            )
        DeploymentWriter -> do
          replicas <- intField "replicas" spec
          selectorRoot <- objectField "selector" spec
          unless
            (not (KM.member "matchExpressions" selectorRoot))
            (Left "Deployment selector expressions lack a drain proof")
          selector <- textMap =<< objectField "matchLabels" selectorRoot
          digest <- Deployment.digestDeploymentWriterSpec value
          _ <-
            Deployment.mkDeploymentWriterPin
              ns
              nativeName
              uid
              replicas
              digest
              selector
          pure
            ( object
                [ "kind" .= ("Deployment" :: Text)
                , "namespace" .= ns
                , "name" .= nativeName
                , "uid" .= uid
                , "replicas" .= replicas
                , "specDigest" .= digest
                , "selector" .= selector
                , "mountsTarget" .= mounted
                ]
            )
        CronJobWriter -> do
          suspend <- case KM.lookup "suspend" spec of
            Nothing -> Right Nothing
            Just (Bool value') -> Right (Just value')
            _ -> Left "CronJob suspend is malformed"
          digest <- digestScheduledWriterSpec value
          _ <- mkScheduledWriterPin ns nativeName uid suspend digest
          pure
            ( object
                [ "kind" .= ("CronJob" :: Text)
                , "namespace" .= ns
                , "name" .= nativeName
                , "uid" .= uid
                , "suspend" .= suspend
                , "specDigest" .= digest
                , "mountsTarget" .= mounted
                ]
            )
        _ -> Left "accepted writer has no capture control"
      pure (resource, physical, saved)
  _ -> pure (Left "accepted writer has no namespaced Kubernetes address")

acceptedAddress ::
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  Text ->
  Text ->
  Either Text (ResourceId, Text, Text)
acceptedAddress native resource group kind = do
  (member, _) <-
    maybe
      (Left "fenced resource lacks accepted native evidence")
      Right
      (Map.lookup resource native)
  case address member of
    Kubernetes cluster actualGroup actualKind (Just namespace) name
      | actualGroup == group && nameText actualKind == kind ->
          Right (cluster, nameText namespace, nameText name)
    _ -> Left "fenced resource has another accepted Kubernetes address"

parseClaim :: Text -> Text -> Value -> Either Text (Text, Text)
parseClaim namespace name value = do
  root <- asObject "PVC" value
  metadata <- objectField "metadata" root
  exactName namespace name metadata
  uid <- textField "uid" metadata
  spec <- objectField "spec" root
  volumeName <- textField "volumeName" spec
  pure (uid, volumeName)

parseVolume :: Text -> Value -> Either Text (Text, VolumeBacking)
parseVolume name value = do
  root <- asObject "PV" value
  metadata <- objectField "metadata" root
  unless
    (textField "name" metadata == Right name)
    (Left "bound PV name changed during capture")
  uid <- textField "uid" metadata
  spec <- objectField "spec" root
  backing <- case (KM.lookup "csi" spec, KM.lookup "local" spec) of
    (Just (Object csi), Nothing) ->
      CsiVolume
        <$> textField "driver" csi
        <*> textField "volumeHandle" csi
    (Nothing, Just (Object local)) -> do
      path <- textField "path" local
      affinity <- objectField "nodeAffinity" spec
      required <- objectField "required" affinity
      terms <- arrayField "nodeSelectorTerms" required
      case terms of
        [Object term] -> do
          expressions <- arrayField "matchExpressions" term
          case expressions of
            [Object expression] -> do
              values <- arrayField "values" expression
              case values of
                [String node] -> Right (LocalVolume path node)
                _ -> Left "local PV has no unique node"
            _ -> Left "local PV has no unique node expression"
        _ -> Left "local PV has no unique node term"
    _ -> Left "PV has an unsupported or ambiguous backing"
  pure (uid, backing)

backingValue :: VolumeBacking -> Value
backingValue (CsiVolume driver handle) =
  object
    ["kind" .= ("csi" :: Text), "driver" .= driver, "handle" .= handle]
backingValue (LocalVolume path node) =
  object
    ["kind" .= ("local" :: Text), "path" .= path, "node" .= node]

exactName :: Text -> Text -> KM.KeyMap Value -> Either Text ()
exactName namespace name metadata =
  unless
    ( textField "namespace" metadata == Right namespace
        && textField "name" metadata == Right name
    )
    (Left "captured Kubernetes address changed")

asObject :: Text -> Value -> Either Text (KM.KeyMap Value)
asObject _ (Object root) = Right root
asObject label _ = Left (label <> " is not an object")

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("Kubernetes capture lacks " <> key)

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("Kubernetes capture lacks " <> key)

intField :: Text -> KM.KeyMap Value -> Either Text Int
intField key root = case KM.lookup (Key.fromText key) root of
  Just value
    | Success number <- (fromJSON value :: Result Int)
    , number >= 0 ->
        Right number
  _ -> Left ("Kubernetes capture lacks " <> key)

arrayField :: Text -> KM.KeyMap Value -> Either Text [Value]
arrayField key root = case KM.lookup (Key.fromText key) root of
  Just (Array values) -> Right (V.toList values)
  _ -> Left ("Kubernetes capture lacks " <> key)

textMap :: KM.KeyMap Value -> Either Text (Map Text Text)
textMap fields =
  Map.fromList
    <$> forM
      (KM.toList fields)
      ( \(key, value) ->
          case value of
            String selected -> Right (Key.toText key, selected)
            _ -> Left "Kubernetes capture has a malformed selector"
      )
