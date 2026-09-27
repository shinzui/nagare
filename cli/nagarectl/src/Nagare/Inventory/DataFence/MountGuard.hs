-- | Reviewed admission objects that deny new mounts of an exact live PVC.
-- The native controller must observe both objects active and test admission
-- before it treats this policy as writer-exclusion proof. Existing Pods must
-- still be drained separately.
module Nagare.Inventory.DataFence.MountGuard
  ( MountGuard
  , PodOwnerPermit
  , mkMountGuard
  , withGuardedStatefulSets
  , withGuardedDeployments
  , withGuardedService
  , withGuardedSchedules
  , GuardedStatefulSet (..)
  , GuardedDeployment (..)
  , GuardedService (..)
  , GuardedSchedule (..)
  , guardedStatefulSets
  , guardedDeployments
  , guardedService
  , guardedSchedules
  , mkPodOwnerPermit
  , validUid
  , validGuardSelector
  , mountGuardName
  , guardNamespaceName
  , guardClaimName
  , guardClaimIdentity
  , guardVolumeName
  , guardVolumeIdentity
  , mountGuardObjects
  , pvcMutationGuardObjects
  , pvMutationGuardObjects
  , namespaceDeleteGuardObjects
  , statefulWriterGuardObjects
  , deploymentWriterGuardObjects
  , serviceMutationGuardObjects
  , endpointSliceGuardObjects
  , legacyEndpointsGuardObjects
  , scheduledWriterGuardObjects
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Char (isAlphaNum, isAscii, isAsciiLower)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=), guard)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (Name, digestText, mkName, nameText)

data PodOwnerPermit = PodOwnerPermit
  { permitOwnerKind :: !Text
  , permitOwnerName :: !Name
  , permitOwnerUid :: !Text
  , permitControllerPrincipal :: !Text
  }
  deriving stock (Eq, Show)

data MountGuard = MountGuard
  { guardSession :: !Text
  , guardNamespace :: !Name
  , guardClaim :: !Name
  , guardClaimUid :: !Text
  , guardVolume :: !Name
  , guardVolumeUid :: !Text
  , guardPermits :: ![PodOwnerPermit]
  , guardWriters :: ![GuardedStatefulSet]
  , guardDeployments :: ![GuardedDeployment]
  , guardService :: !(Maybe GuardedService)
  , guardSchedules :: ![GuardedSchedule]
  }
  deriving stock (Eq, Show)

data GuardedStatefulSet = GuardedStatefulSet
  { guardedWriterNamespace :: !Text
  , guardedWriterName :: !Text
  , guardedWriterUid :: !Text
  }
  deriving stock (Eq, Show)

data GuardedDeployment = GuardedDeployment
  { guardedDeploymentNamespace :: !Text
  , guardedDeploymentName :: !Text
  , guardedDeploymentUid :: !Text
  , guardedDeploymentSelector :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

data GuardedService = GuardedService
  { guardedServiceNamespace :: !Text
  , guardedServiceName :: !Text
  , guardedServiceUid :: !Text
  }
  deriving stock (Eq, Show)

data GuardedSchedule = GuardedSchedule
  { guardedScheduleNamespace :: !Text
  , guardedScheduleName :: !Text
  , guardedScheduleUid :: !Text
  }
  deriving stock (Eq, Show)

mkPodOwnerPermit :: Text -> Text -> Text -> Text -> Either Text PodOwnerPermit
mkPodOwnerPermit kind owner uid principal = do
  unless (kind `elem` ["Job", "StatefulSet", "ReplicaSet", "DaemonSet"])
    (Left "mount guard Pod owner kind is unsupported")
  name <- mkName owner
  unless (validDnsSubdomain owner) (Left "mount guard Pod owner name is invalid")
  unless (validUid uid)
    (Left "permitted Pod owner UID is not a canonical Kubernetes UUID")
  unless (T.length principal <= 253 && not (T.null principal)
    && T.all (\character -> isAscii character &&
      (isAlphaNum character || character `elem` (":._@/-" :: String))) principal)
    (Left "permitted Pod controller principal is invalid")
  pure (PodOwnerPermit kind name uid principal)

validUid :: Text -> Bool
validUid uid = T.length uid == 36 && all validAt (zip [0 :: Int ..] (T.unpack uid))
  where
    validAt (position, character)
      | position `elem` [8, 13, 18, 23] = character == '-'
      | otherwise = character `elem` ("0123456789abcdef" :: String)

mkMountGuard :: Text -> Text -> Text -> Text -> Text -> Text
  -> [PodOwnerPermit] -> Either Text MountGuard
mkMountGuard session namespace claim claimUid volume volumeUid permits = do
  unless (not (T.null session) && T.length session <= 128
    && T.all (\character -> isAscii character &&
      (isAlphaNum character || character `elem` ("-_." :: String))) session)
    (Left "data fence session is invalid for a mount guard")
  unless (validDnsLabel namespace) (Left "mount guard namespace is not a DNS label")
  unless (validDnsSubdomain claim && validDnsSubdomain volume)
    (Left "mount guard PVC or PV name is not a DNS subdomain")
  unless (validUid claimUid) (Left "fenced PVC UID is not a canonical Kubernetes UUID")
  unless (validUid volumeUid) (Left "fenced PV UID is not a canonical Kubernetes UUID")
  MountGuard session <$> mkName namespace <*> mkName claim <*> pure claimUid
    <*> mkName volume <*> pure volumeUid <*> pure permits <*> pure []
    <*> pure [] <*> pure Nothing <*> pure []

withGuardedStatefulSets :: MountGuard -> [(Text, Text, Text)]
  -> Either Text MountGuard
withGuardedStatefulSets guard writers = do
  validated <- traverse validate writers
  let addresses = [(guardedWriterNamespace writer, guardedWriterName writer)
        | writer <- validated]
  unless (length addresses == Set.size (Set.fromList addresses))
    (Left "fenced StatefulSet address is duplicated")
  pure guard {guardWriters = validated}
  where
    validate (namespace, name, uid) = do
      unless (validDnsLabel namespace && validDnsSubdomain name && validUid uid)
        (Left "fenced StatefulSet address or UID is malformed")
      pure (GuardedStatefulSet namespace name uid)

guardedStatefulSets :: MountGuard -> [GuardedStatefulSet]
guardedStatefulSets = guardWriters

withGuardedDeployments :: MountGuard -> [(Text, Text, Text, Map Text Text)]
  -> Either Text MountGuard
withGuardedDeployments guard deployments = do
  validated <- traverse validate deployments
  let addresses = [(guardedDeploymentNamespace deployment,
        guardedDeploymentName deployment) | deployment <- validated]
  unless (length addresses == Set.size (Set.fromList addresses))
    (Left "fenced Deployment address is duplicated")
  pure guard {guardDeployments = validated}
  where
    validate (namespace, name, uid, selector) = do
      unless (validDnsLabel namespace && validDnsSubdomain name && validUid uid
          && validGuardSelector selector)
        (Left "fenced Deployment address, UID, or selector is malformed")
      pure (GuardedDeployment namespace name uid selector)

guardedDeployments :: MountGuard -> [GuardedDeployment]
guardedDeployments = guardDeployments

validGuardSelector :: Map Text Text -> Bool
validGuardSelector selector = not (Map.null selector)
  && all (\(key, value) -> valid key && valid value) (Map.toList selector)
  where
    valid value = not (T.null value) && T.length value <= 253
      && T.all (\character -> isAscii character &&
        (isAlphaNum character || character `elem` ("-_./" :: String))) value

withGuardedService :: MountGuard -> Text -> Text -> Text
  -> Either Text MountGuard
withGuardedService guard namespace name uid = do
  unless (validDnsLabel namespace && validDnsSubdomain name && validUid uid)
    (Left "fenced Service address or UID is malformed")
  pure guard {guardService = Just (GuardedService namespace name uid)}

guardedService :: MountGuard -> Maybe GuardedService
guardedService = guardService

withGuardedSchedules :: MountGuard -> [(Text, Text, Text)]
  -> Either Text MountGuard
withGuardedSchedules guard schedules = do
  validated <- traverse validate schedules
  let addresses = [(guardedScheduleNamespace schedule, guardedScheduleName schedule)
        | schedule <- validated]
  unless (length addresses == Set.size (Set.fromList addresses))
    (Left "fenced CronJob address is duplicated")
  pure guard {guardSchedules = validated}
  where
    validate (namespace, name, uid) = do
      unless (validDnsLabel namespace && validDnsSubdomain name && validUid uid)
        (Left "fenced CronJob address or UID is malformed")
      pure (GuardedSchedule namespace name uid)

guardedSchedules :: MountGuard -> [GuardedSchedule]
guardedSchedules = guardSchedules

validDnsSubdomain :: Text -> Bool
validDnsSubdomain name = T.length name <= 253
  && all validDnsLabel (T.splitOn "." name)

validDnsLabel :: Text -> Bool
validDnsLabel label = not (T.null label) && T.length label <= 63
  && asciiAlnum (T.head label) && asciiAlnum (T.last label)
  && T.all (\character -> asciiAlnum character || character == '-') label
  where
    asciiAlnum character = isAsciiLower character
      || (character >= '0' && character <= '9')

mountGuardName :: MountGuard -> Text
mountGuardName guard = "nagare-data-fence-" <>
  T.take 32 (digestText (contentDigest (TE.encodeUtf8
    (T.intercalate "/" [guardSession guard, nameText (guardNamespace guard),
      nameText (guardClaim guard), guardClaimUid guard,
      nameText (guardVolume guard), guardVolumeUid guard]))))

guardNamespaceName :: MountGuard -> Text
guardNamespaceName = nameText . guardNamespace

guardClaimName :: MountGuard -> Text
guardClaimName = nameText . guardClaim

guardClaimIdentity :: MountGuard -> Text
guardClaimIdentity = guardClaimUid

guardVolumeName :: MountGuard -> Text
guardVolumeName = nameText . guardVolume

guardVolumeIdentity :: MountGuard -> Text
guardVolumeIdentity = guardVolumeUid

-- | The policy covers Pod CREATE and UPDATE, while the binding enforces Deny.
-- A controller exception requires both the API-authenticated controller user
-- and the exact owning workload UID. An owner reference alone is spoofable.
mountGuardObjects :: MountGuard -> (Value, Value)
mountGuardObjects guard = (policy, binding)
  where
    name = mountGuardName guard
    policy = object
      [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
      , "kind" .= ("ValidatingAdmissionPolicy" :: Text)
      , "metadata" .= object
          [ "name" .= name
          , "annotations" .= object
              [ "nagare.dev/fence-pvc-uid" .= guardClaimUid guard
              , "nagare.dev/fence-pv-uid" .= guardVolumeUid guard
              ]
          ]
      , "spec" .= object
          [ "failurePolicy" .= ("Fail" :: Text)
          , "matchConstraints" .= object
              [ "matchPolicy" .= ("Equivalent" :: Text)
              , "namespaceSelector" .= object []
              , "objectSelector" .= object []
              , "resourceRules" .= [object
                  [ "apiGroups" .= ([""] :: [Text])
                  , "apiVersions" .= (["v1"] :: [Text])
                  , "operations" .= (["CREATE", "UPDATE"] :: [Text])
                  , "resources" .= (["pods"] :: [Text])
                  , "scope" .= ("*" :: Text)
                  ]]
              ]
          , "validations" .= [object
              [ "expression" .= expression
              , "message" .= ("Nagare live PVC is fenced" :: Text)
              ]]
          ]
      ]
    binding = object
      [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
      , "kind" .= ("ValidatingAdmissionPolicyBinding" :: Text)
      , "metadata" .= object ["name" .= name]
      , "spec" .= object
          [ "policyName" .= name
          , "validationActions" .= (["Deny"] :: [Text])
          ]
      ]
    expression =
      "object.metadata.namespace != '" <> nameText (guardNamespace guard)
        <> "' || !has(object.spec.volumes) || object.spec.volumes.all(v, "
        <> "!has(v.persistentVolumeClaim) || v.persistentVolumeClaim.claimName != '"
        <> nameText (guardClaim guard) <> "')"
        <> foldMap permitExpression (guardPermits guard)
    permitExpression permit =
      " || (request.userInfo.username == '" <> permitControllerPrincipal permit
        <> "' && has(object.metadata.ownerReferences) && "
        <> "object.metadata.ownerReferences.exists(r, r.kind == '"
        <> permitOwnerKind permit <> "' && r.name == '"
        <> nameText (permitOwnerName permit) <> "' && r.uid == '"
        <> permitOwnerUid permit <> "'))"

-- | Separate policies protect the bound claim, its PV, and the namespace
-- from deletion while the Pod mount rule is active. The native controller
-- still has to observe exact UIDs and the volume handle before every effect.
pvcMutationGuardObjects :: MountGuard -> (Value, Value)
pvcMutationGuardObjects guard = mutationGuardObjects guard "pvc"
  ["UPDATE", "DELETE"] "" "persistentvolumeclaims" expression
  "Nagare live PVC identity is fenced"
  where
    expression = "oldObject.metadata.namespace != '"
      <> nameText (guardNamespace guard) <> "' || oldObject.metadata.name != '"
      <> nameText (guardClaim guard) <> "'"

pvMutationGuardObjects :: MountGuard -> (Value, Value)
pvMutationGuardObjects guard = mutationGuardObjects guard "pv"
  ["UPDATE", "DELETE"] "" "persistentvolumes" expression
  "Nagare live PV identity is fenced"
  where
    expression = "oldObject.metadata.name != '" <> nameText (guardVolume guard) <> "'"

namespaceDeleteGuardObjects :: MountGuard -> (Value, Value)
namespaceDeleteGuardObjects guard = mutationGuardObjects guard "namespace"
  ["DELETE"] "" "namespaces" expression "Nagare live recovery namespace is fenced"
  where
    expression = "oldObject.metadata.name != '" <> nameText (guardNamespace guard) <> "'"

-- | The saved controllers may only be driven toward zero while recovery is
-- active. The parent resource and /scale subresource have different admission
-- object shapes, so each gets its own rule. DELETE is refused.
statefulWriterGuardObjects :: MountGuard -> [(Value, Value)]
statefulWriterGuardObjects guard = concatMap renderWriter (guardWriters guard)
  where
    renderWriter writer =
      [ render writer "-w-" "statefulsets" parentExpression
      , render writer "-s-" "statefulsets/scale" scaleExpression
      ]
      where
        target = "oldObject.metadata.namespace != '"
          <> guardedWriterNamespace writer
          <> "' || oldObject.metadata.name != '" <> guardedWriterName writer
          <> "' || (request.operation == 'UPDATE' && object.spec.replicas == 0"
        parentExpression = target
          <> " && (oldObject.spec.replicas != 0 || object.spec == oldObject.spec))"
        scaleExpression = "oldObject.metadata.namespace != '"
          <> guardedWriterNamespace writer
          <> "' || oldObject.metadata.name != '" <> guardedWriterName writer
          <> "' || (request.operation == 'UPDATE'"
          <> " && (!has(object.spec.replicas) || object.spec.replicas == 0))"
    render writer suffix resource expression = (policy, binding)
      where
        name = mountGuardName guard <> suffix <> T.take 8
          (digestText (contentDigest (TE.encodeUtf8 (T.intercalate "/"
            [guardedWriterNamespace writer, guardedWriterName writer,
              guardedWriterUid writer]))))
        policy = object
          [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
          , "kind" .= ("ValidatingAdmissionPolicy" :: Text)
          , "metadata" .= object
              [ "name" .= name
              , "annotations" .= object
                  [ "nagare.dev/fence-pvc-uid" .= guardClaimUid guard
                  , "nagare.dev/fence-pv-uid" .= guardVolumeUid guard
                  , "nagare.dev/fence-writer-uid" .= guardedWriterUid writer
                  ]]
          , "spec" .= object
              [ "failurePolicy" .= ("Fail" :: Text)
              , "matchConstraints" .= object
                  [ "matchPolicy" .= ("Equivalent" :: Text)
                  , "namespaceSelector" .= object []
                  , "objectSelector" .= object []
                  , "resourceRules" .= [object
                      [ "apiGroups" .= (["apps"] :: [Text])
                      , "apiVersions" .= (["v1"] :: [Text])
                      , "operations" .= (["UPDATE", "DELETE"] :: [Text])
                      , "resources" .= ([resource] :: [Text])
                      , "scope" .= ("Namespaced" :: Text)
                      ]]
                  ]
              , "validations" .= [object
                  [ "expression" .= expression
                  , "message" .= ("Nagare writer controller is fenced" :: Text)
                  ]]
              ]]
        binding = object
          [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
          , "kind" .= ("ValidatingAdmissionPolicyBinding" :: Text)
          , "metadata" .= object ["name" .= name]
          , "spec" .= object
              [ "policyName" .= name
              , "validationActions" .= (["Deny"] :: [Text])
              ]]

-- | A Deployment may only scale toward zero. Its ReplicaSets cannot change
-- their Pod templates, gain or lose the reviewed owner, or create new client
-- Pods while the fence is active. Existing Pods remain free to terminate.
deploymentWriterGuardObjects :: MountGuard -> [(Value, Value)]
deploymentWriterGuardObjects guard = concatMap render (guardDeployments guard)
  where
    render deployment =
      [ mutationGuardObjects guard ("d-" <> key)
          ["UPDATE", "DELETE"] "apps" "deployments" parentExpression message
      , mutationGuardObjects guard ("x-" <> key)
          ["UPDATE", "DELETE"] "apps" "deployments/scale" scaleExpression message
      , mutationGuardObjects guard ("c-" <> key)
          ["CREATE"] "" "pods" podExpression
          "Nagare database client Pod is fenced"
      , mutationGuardObjects guard ("n-" <> key)
          ["CREATE"] "apps" "replicasets"
          ("request.namespace != '" <> guardedDeploymentNamespace deployment
            <> "' || !" <> owned "object") message
      , mutationGuardObjects guard ("r-" <> key)
          ["UPDATE"] "apps" "replicasets" replicaSetExpression message
      , mutationGuardObjects guard ("z-" <> key)
          ["DELETE"] "apps" "replicasets"
          ("request.namespace != '" <> guardedDeploymentNamespace deployment
            <> "' || !" <> owned "oldObject") message
      ]
      where
        key = T.take 8 (digestText (contentDigest (TE.encodeUtf8
          (T.intercalate "/" [guardedDeploymentNamespace deployment,
            guardedDeploymentName deployment, guardedDeploymentUid deployment]))))
        message = "Nagare database client controller is fenced"
        address = "oldObject.metadata.namespace != '"
          <> guardedDeploymentNamespace deployment
          <> "' || oldObject.metadata.name != '"
          <> guardedDeploymentName deployment <> "' || "
        zero = "(!has(object.spec.replicas) || object.spec.replicas == 0)"
        parentExpression = address
          <> "(request.operation == 'UPDATE' && " <> zero
          <> " && object.spec.selector == oldObject.spec.selector"
          <> " && object.spec.template == oldObject.spec.template"
          <> " && (!has(oldObject.spec.replicas)"
          <> " || oldObject.spec.replicas != 0 || object.spec == oldObject.spec))"
        scaleExpression = address
          <> "(request.operation == 'UPDATE' && " <> zero <> ")"
        selector = T.intercalate " && "
          ["'" <> label <> "' in object.metadata.labels && "
            <> "object.metadata.labels['" <> label <> "'] == '" <> value <> "'"
          | (label, value) <- Map.toAscList
              (guardedDeploymentSelector deployment)]
        podExpression = "request.namespace != '"
          <> guardedDeploymentNamespace deployment
          <> "' || !has(object.metadata.labels) || !(" <> selector <> ")"
        owned target = "(has(" <> target <> ".metadata.ownerReferences) && "
          <> target <> ".metadata.ownerReferences.exists(r, "
          <> "r.kind == 'Deployment' && r.uid == '"
          <> guardedDeploymentUid deployment <> "'))"
        replicaSetExpression = "request.namespace != '"
          <> guardedDeploymentNamespace deployment <> "' || "
          <> "((!" <> owned "oldObject" <> " && !" <> owned "object" <> ")"
          <> " || (" <> owned "oldObject" <> " && " <> owned "object"
          <> " && " <> zero
          <> " && object.spec.selector == oldObject.spec.selector"
          <> " && object.spec.template == oldObject.spec.template))"

-- | The Service route cannot be changed or deleted while exclusion is active.
-- The UID is also observed against the durable pin before every data effect.
serviceMutationGuardObjects :: MountGuard -> Maybe (Value, Value)
serviceMutationGuardObjects guard = fmap render (guardService guard)
  where
    render service = mutationGuardObjects guard "service"
      ["UPDATE", "DELETE"] "" "services" expression
      "Nagare database Service is fenced"
      where
        expression = "oldObject.metadata.namespace != '"
          <> guardedServiceNamespace service
          <> "' || oldObject.metadata.name != '"
          <> guardedServiceName service <> "'"

-- | Allow the endpoint controller to drain existing slices, but refuse any
-- new or updated nonempty slice associated with the fenced Service.
endpointSliceGuardObjects :: MountGuard -> Maybe (Value, Value)
endpointSliceGuardObjects guard = fmap render (guardService guard)
  where
    render service = mutationGuardObjects guard "endpoint-slice"
      ["CREATE", "UPDATE"] "discovery.k8s.io" "endpointslices" expression
      "Nagare database endpoints are fenced"
      where
        expression = "request.namespace != '" <> guardedServiceNamespace service
          <> "' || !has(object.metadata.labels) || "
          <> "!('kubernetes.io/service-name' in object.metadata.labels) || "
          <> "object.metadata.labels['kubernetes.io/service-name'] != '"
          <> guardedServiceName service
          <> "' || !has(object.endpoints) || object.endpoints == null "
          <> "|| size(object.endpoints) == 0"

-- | Legacy Endpoints still provide a Service route on supported clusters.
-- Permit the endpoint controller to drain the exact object, but never to
-- recreate a nonempty address set while the target is fenced.
legacyEndpointsGuardObjects :: MountGuard -> Maybe (Value, Value)
legacyEndpointsGuardObjects guard = fmap render (guardService guard)
  where
    render service = mutationGuardObjects guard "legacy-endpoints"
      ["CREATE", "UPDATE"] "" "endpoints" expression
      "Nagare legacy database endpoints are fenced"
      where
        expression = "request.namespace != '" <> guardedServiceNamespace service
          <> "' || object.metadata.name != '" <> guardedServiceName service
          <> "' || !has(object.subsets) || object.subsets == null "
          <> "|| size(object.subsets) == 0"

-- | Keep schedules suspended and deny new Jobs carrying their exact owner
-- UID. Already-started Jobs and Pods still need separate drain observation.
scheduledWriterGuardObjects :: MountGuard -> [(Value, Value)]
scheduledWriterGuardObjects guard = concatMap render (guardSchedules guard)
  where
    render schedule =
      [ mutationGuardObjects guard (suffix schedule <> "-cronjob")
          ["UPDATE", "DELETE"] "batch" "cronjobs" cronExpression
          "Nagare database schedule is fenced"
      , mutationGuardObjects guard (suffix schedule <> "-job")
          ["CREATE"] "batch" "jobs" jobExpression
          "Nagare scheduled Job creation is fenced"
      ]
      where
        cronExpression = "oldObject.metadata.namespace != '"
          <> guardedScheduleNamespace schedule
          <> "' || oldObject.metadata.name != '"
          <> guardedScheduleName schedule
          <> "' || (request.operation == 'UPDATE' && object.spec.suspend == true"
          <> " && (!has(oldObject.spec.suspend) || oldObject.spec.suspend != true"
          <> " || object.spec == oldObject.spec))"
        jobExpression = "request.namespace != '"
          <> guardedScheduleNamespace schedule
          <> "' || !has(object.metadata.ownerReferences) || "
          <> "object.metadata.ownerReferences.all(r, r.kind != 'CronJob' || "
          <> "r.uid != '" <> guardedScheduleUid schedule <> "')"
    suffix schedule = "schedule-" <> T.take 8
      (digestText (contentDigest (TE.encodeUtf8 (T.intercalate "/"
        [guardedScheduleNamespace schedule, guardedScheduleName schedule,
          guardedScheduleUid schedule]))))

mutationGuardObjects :: MountGuard -> Text -> [Text] -> Text -> Text -> Text -> Text
  -> (Value, Value)
mutationGuardObjects guard suffix operations group resource expression message =
  (policy, binding)
  where
    name = mountGuardName guard <> "-" <> suffix
    policy = object
      [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
      , "kind" .= ("ValidatingAdmissionPolicy" :: Text)
      , "metadata" .= object
          [ "name" .= name
          , "annotations" .= object
              [ "nagare.dev/fence-pvc-uid" .= guardClaimUid guard
              , "nagare.dev/fence-pv-uid" .= guardVolumeUid guard
              ]
          ]
      , "spec" .= object
          [ "failurePolicy" .= ("Fail" :: Text)
          , "matchConstraints" .= object
              [ "matchPolicy" .= ("Equivalent" :: Text)
              , "namespaceSelector" .= object []
              , "objectSelector" .= object []
              , "resourceRules" .= [object
                  [ "apiGroups" .= [group]
                  , "apiVersions" .= (["v1"] :: [Text])
                  , "operations" .= operations
                  , "resources" .= [resource]
                  , "scope" .= ("*" :: Text)
                  ]]
              ]
          , "validations" .= [object
              [ "expression" .= expression
              , "message" .= message
              ]]
          ]
      ]
    binding = object
      [ "apiVersion" .= ("admissionregistration.k8s.io/v1" :: Text)
      , "kind" .= ("ValidatingAdmissionPolicyBinding" :: Text)
      , "metadata" .= object ["name" .= name]
      , "spec" .= object
          [ "policyName" .= name
          , "validationActions" .= (["Deny"] :: [Text])
          ]
      ]
