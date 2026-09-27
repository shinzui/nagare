-- | Reviewed admission objects that deny new mounts of an exact live PVC.
-- The native controller must observe both objects active and test admission
-- before it treats this policy as writer-exclusion proof. Existing Pods must
-- still be drained separately.
module Nagare.Inventory.DataFence.MountGuard
  ( MountGuard
  , PodOwnerPermit
  , mkMountGuard
  , withGuardedStatefulSets
  , GuardedStatefulSet (..)
  , guardedStatefulSets
  , mkPodOwnerPermit
  , validUid
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
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Char (isAlphaNum, isAscii, isAsciiLower)
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
  }
  deriving stock (Eq, Show)

data GuardedStatefulSet = GuardedStatefulSet
  { guardedWriterNamespace :: !Text
  , guardedWriterName :: !Text
  , guardedWriterUid :: !Text
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
  ["UPDATE", "DELETE"] "persistentvolumeclaims" expression
  "Nagare live PVC identity is fenced"
  where
    expression = "oldObject.metadata.namespace != '"
      <> nameText (guardNamespace guard) <> "' || oldObject.metadata.name != '"
      <> nameText (guardClaim guard) <> "'"

pvMutationGuardObjects :: MountGuard -> (Value, Value)
pvMutationGuardObjects guard = mutationGuardObjects guard "pv"
  ["UPDATE", "DELETE"] "persistentvolumes" expression
  "Nagare live PV identity is fenced"
  where
    expression = "oldObject.metadata.name != '" <> nameText (guardVolume guard) <> "'"

namespaceDeleteGuardObjects :: MountGuard -> (Value, Value)
namespaceDeleteGuardObjects guard = mutationGuardObjects guard "namespace"
  ["DELETE"] "namespaces" expression "Nagare live recovery namespace is fenced"
  where
    expression = "oldObject.metadata.name != '" <> nameText (guardNamespace guard) <> "'"

-- | The saved controllers may only be driven toward zero while recovery is
-- active. This covers both ordinary StatefulSet updates and /scale updates;
-- DELETE is refused. The guard is removed only after verified recovery.
statefulWriterGuardObjects :: MountGuard -> [(Value, Value)]
statefulWriterGuardObjects guard = map render (guardWriters guard)
  where
    render writer = (policy, binding)
      where
        name = mountGuardName guard <> "-w-" <> T.take 8
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
                      , "resources" .= (["statefulsets", "statefulsets/scale"] :: [Text])
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
        expression =
          "oldObject.metadata.namespace != '" <> guardedWriterNamespace writer
            <> "' || oldObject.metadata.name != '" <> guardedWriterName writer
            <> "' || (request.operation == 'UPDATE' && object.spec.replicas == 0)"

mutationGuardObjects :: MountGuard -> Text -> [Text] -> Text -> Text -> Text
  -> (Value, Value)
mutationGuardObjects guard suffix operations resource expression message =
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
                  [ "apiGroups" .= ([""] :: [Text])
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
