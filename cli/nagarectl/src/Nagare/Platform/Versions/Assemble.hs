-- | Assemble the platform-versions sections from what was read (EP-236),
-- without IO. Declared versions and images come from accepted members only,
-- never from this binary's pins; observed values come from provider reads,
-- each with the time it was attempted. A provider's error text never enters
-- a fact: a failure is one of 'ProviderFailure' and becomes a reason code.
module Nagare.Platform.Versions.Assemble
  ( ProviderFailure (..)
  , failureReason
  , Reading (..)

    -- * Accepted inputs
  , AcceptedMember (..)
  , WorkloadKind (..)
  , DeclaredWorkload (..)
  , declaredWorkloads
  , isPlatformScope
  , isDatabaseServer

    -- * Observations
  , Pod (..)
  , PodContainer (..)
  , parsePods
  , selects
  , EngineReading (..)
  , engineProbe
  , parseEngineVersion

    -- * Sections
  , installedSection
  , hostsSection
  , componentsSection
  , databasesSection
  , databaseTargets
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Versions
import Nagare.Dsl.Prelude
import Nagare.Platform.Versions

-- | Why a provider read produced no value.
data ProviderFailure
  = ProviderDenied
  | ProviderUnreadable
  | ProviderMissing
  | ProviderDeadline
  | ProviderUnsupported
  | ProviderProbeFailed
  deriving stock (Eq, Show)

failureReason :: ProviderFailure -> Text
failureReason = \case
  ProviderDenied -> reasonDenied
  ProviderUnreadable -> reasonUnreadable
  ProviderMissing -> reasonNotRecorded
  ProviderDeadline -> reasonCollectionDeadline
  ProviderUnsupported -> reasonProbeUnsupported
  ProviderProbeFailed -> reasonProbeFailed

-- | One provider read and when it was attempted.
data Reading a = Reading
  { attempted :: !Text
  , result :: !(Either ProviderFailure a)
  }
  deriving stock (Eq, Show, Generic, Functor)

-- | An accepted Kubernetes or Helm member of a @platform:@ or @database:@
-- scope, with its private native object or release contract. Only names,
-- labels, images and chart paths are ever read from them.
data AcceptedMember
  = KubernetesMember !Text !Text !ByteString
  | -- | Scope, resource, namespace, release name, contract.
    HelmMember !Text !Text !Text !Text !ByteString
  deriving stock (Eq, Show)

data WorkloadKind
  = KindDeployment
  | KindStatefulSet
  | KindDaemonSet
  | KindHelmRelease
  deriving stock (Eq, Ord, Show)

kindText :: WorkloadKind -> Text
kindText = \case
  KindDeployment -> "Deployment"
  KindStatefulSet -> "StatefulSet"
  KindDaemonSet -> "DaemonSet"
  KindHelmRelease -> "HelmRelease"

-- | What an accepted workload declares. @understood@ is false when its
-- native object lacks the shape this reader knows; it is reported as
-- @probe_unsupported@, never dropped.
data DeclaredWorkload = DeclaredWorkload
  { scope :: !Text
  , resource :: !Text
  , kind :: !WorkloadKind
  , namespace :: !Text
  , name :: !Text
  , labels :: !(Map Text Text)
  , selector :: !(Map Text Text)
  , images :: ![(Text, Text)]
  , version :: !(Maybe Text)
  , chartVersion :: !(Maybe Text)
  , understood :: !Bool
  }
  deriving stock (Eq, Show, Generic)

isPlatformScope :: Text -> Bool
isPlatformScope = T.isPrefixOf "platform:"

-- | A managed database server is an accepted StatefulSet labelled with its
-- engine, in whichever scope owns it: a platform component (@en-db@), a
-- shared standalone server or an application's own database. Tenant
-- databases are not StatefulSets and never match.
isDatabaseServer :: DeclaredWorkload -> Bool
isDatabaseServer = isJust . databaseEngine

-- | The workloads among accepted members: Deployments, StatefulSets,
-- DaemonSets and Helm releases. Every other member kind is not a component.
declaredWorkloads :: [AcceptedMember] -> [DeclaredWorkload]
declaredWorkloads = sortOn (\workload -> (workload ^. #scope, workload ^. #resource)) . concatMap declared
  where
    declared = \case
      KubernetesMember scopeText resourceText bytes -> case eitherDecodeStrict' bytes of
        Left _ -> []
        Right object -> case textAt ["kind"] object >>= workloadKind of
          Nothing -> []
          Just workloadKindValue ->
            let templateSpec = valueAt ["spec", "template", "spec"] object
                containers = [(containerName, image) | Just items <- [templateSpec >>= arrayAt ["containers"]], item <- items, Just containerName <- [textAt ["name"] item], Just image <- [textAt ["image"] item]]
                selectorLabels = stringMap (valueAt ["spec", "selector", "matchLabels"] object)
                objectLabels = stringMap (valueAt ["metadata", "labels"] object)
                templateLabels = stringMap (valueAt ["spec", "template", "metadata", "labels"] object)
             in [ DeclaredWorkload
                    { scope = scopeText
                    , resource = resourceText
                    , kind = workloadKindValue
                    , namespace = fromMaybe "" (textAt ["metadata", "namespace"] object)
                    , name = fromMaybe "" (textAt ["metadata", "name"] object)
                    , labels = objectLabels
                    , selector = selectorLabels
                    , images = containers
                    , version = Map.lookup "app.kubernetes.io/version" objectLabels <|> Map.lookup "app.kubernetes.io/version" templateLabels
                    , chartVersion = Nothing
                    , understood = not (null containers) && not (Map.null selectorLabels)
                    }
                ]
      HelmMember scopeText resourceText namespaceText release bytes ->
        let chartPath = either (const Nothing) (textAt ["chartPath"]) (eitherDecodeStrict' bytes)
         in [ DeclaredWorkload
                { scope = scopeText
                , resource = resourceText
                , kind = KindHelmRelease
                , namespace = namespaceText
                , name = release
                , labels = Map.empty
                , selector = Map.singleton "app.kubernetes.io/instance" release
                , images = []
                , version = Nothing
                , chartVersion = chartPath >>= chartVersionOf
                , understood = True
                }
            ]
    workloadKind = \case
      "Deployment" -> Just KindDeployment
      "StatefulSet" -> Just KindStatefulSet
      "DaemonSet" -> Just KindDaemonSet
      _ -> Nothing

-- | @vendor/grafana-9.3.1.tgz@ is chart version @9.3.1@: the vendored
-- archive's name, which Helm packaging writes as name-version.
chartVersionOf :: Text -> Maybe Text
chartVersionOf path = do
  archive <- T.stripSuffix ".tgz" (last' (T.splitOn "/" path))
  let candidates = [T.intercalate "-" (drop index parts) | let parts = T.splitOn "-" archive, index <- [1 .. length parts - 1]]
  case filter startsWithDigit candidates of
    found : _ -> Just found
    [] -> Nothing
  where
    startsWithDigit candidate = maybe False (\(c, _) -> c >= '0' && c <= '9') (T.uncons candidate)
    last' xs = if null xs then "" else xs !! (length xs - 1)

-- | One pod as its status reports it.
data Pod = Pod
  { name :: !Text
  , uid :: !Text
  , labels :: !(Map Text Text)
  , running :: !Bool
  , containers :: ![PodContainer]
  , owner :: !(Maybe (Text, Text))
  -- ^ The controlling owner's kind and name.
  }
  deriving stock (Eq, Show, Generic)

data PodContainer = PodContainer
  { name :: !Text
  , image :: !(Maybe Text)
  , imageId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The pods of a @kubectl get pods -o json@ list. Container status is used
-- when present (it names the running image and its digest); a pending pod
-- reports its declared containers without a digest.
parsePods :: ByteString -> Maybe [Pod]
parsePods bytes = do
  object <- either (const Nothing) Just (eitherDecodeStrict' bytes)
  items <- arrayAt ["items"] object
  pure (sortOn (^. #name) (mapMaybe' pod items))
  where
    pod item = do
      podName <- textAt ["metadata", "name"] item
      podUid <- textAt ["metadata", "uid"] item
      let statuses = fromMaybe [] (arrayAt ["status", "containerStatuses"] item)
          declaredContainers = fromMaybe [] (arrayAt ["spec", "containers"] item)
          fromStatus status = PodContainer <$> textAt ["name"] status <*> pure (textAt ["image"] status) <*> pure (textAt ["imageID"] status)
          fromSpec spec = PodContainer <$> textAt ["name"] spec <*> pure (textAt ["image"] spec) <*> pure Nothing
          containersFound = if null statuses then mapMaybe' fromSpec declaredContainers else mapMaybe' fromStatus statuses
      pure
        Pod
          { name = podName
          , uid = podUid
          , labels = stringMap (valueAt ["metadata", "labels"] item)
          , running = textAt ["status", "phase"] item == Just "Running"
          , containers = containersFound
          , owner = controller item
          }
    controller item =
      listToMaybe'
        [ (ownerKind, ownerName)
        | reference <- fromMaybe [] (arrayAt ["metadata", "ownerReferences"] item)
        , valueAt ["controller"] reference == Just (Bool True)
        , Just ownerKind <- [textAt ["kind"] reference]
        , Just ownerName <- [textAt ["name"] reference]
        ]

-- | Whether a pod belongs to a workload: its labels include the selector
-- and its controller is the workload (a Deployment through its ReplicaSet).
-- A pod run by a Job, such as a scheduled database backup carrying the
-- server's labels, never belongs; a pod with no controller recorded is
-- judged by its labels alone.
selects :: DeclaredWorkload -> Pod -> Bool
selects workload pod =
  not (Map.null (workload ^. #selector))
    && Map.isSubmapOf (workload ^. #selector) (pod ^. #labels)
    && maybe True ownedBy (pod ^. #owner)
  where
    ownedBy (ownerKind, ownerName) = case workload ^. #kind of
      KindDeployment -> ownerKind == "ReplicaSet" && (workload ^. #name <> "-") `T.isPrefixOf` ownerName
      KindStatefulSet -> ownerKind == "StatefulSet" && ownerName == workload ^. #name
      KindDaemonSet -> ownerKind == "DaemonSet" && ownerName == workload ^. #name
      KindHelmRelease -> ownerKind /= "Job"

-- | The reported engine version of one database pod, and the pod's UID
-- read again after the probe.
data EngineReading = EngineReading
  { version :: !(Reading Text)
  , uidAfter :: !(Reading Text)
  }
  deriving stock (Eq, Show, Generic)

-- | The fixed read-only statement each engine answers inside its own pod,
-- with the credentials of the pod's environment, and the source it names.
engineProbe :: Text -> Maybe ([String], Text)
engineProbe = \case
  "postgres" -> Just (["sh", "-c", "psql -X -q -A -t -U \"$POSTGRES_USER\" -d postgres -c 'SELECT version()'"], "SELECT version()")
  "clickhouse" -> Just (["sh", "-c", "clickhouse-client --user \"$CLICKHOUSE_USER\" --password \"$CLICKHOUSE_PASSWORD\" --query 'SELECT version()'"], "SELECT version()")
  "redis" -> Just (["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" --no-auth-warning INFO server"], "INFO server")
  _ -> Nothing

-- | The version an engine's probe output reports: the first line of a
-- @SELECT version()@, or Redis's @redis_version@. Anything else, or an
-- implausibly long answer, is not a version.
parseEngineVersion :: Text -> Text -> Maybe Text
parseEngineVersion engineText output = case engineText of
  "redis" -> bounded =<< listToMaybe' [T.strip value | line <- T.lines output, Just value <- [T.stripPrefix "redis_version:" (T.strip line)]]
  _ -> bounded =<< listToMaybe' (filter (not . T.null) (map T.strip (T.lines output)))
  where
    bounded value
      | T.null value || T.length value > 200 = Nothing
      | otherwise = Just value

-- | The release the stamp records. A field the stamp does not carry (a
-- legacy stamp's payload ID) is @not_recorded@.
installedSection :: Reading ByteString -> InstalledRelease
installedSection reading = case result reading of
  Right bytes
    | Just fields <- configMapData bytes ->
        let fact key = recordedFact stampSource (attempted reading) (Map.lookup key fields)
         in InstalledRelease (fact "version") (fact "revision") (fact "payloadId") (fact "installedAt")
    | otherwise -> missingAll reasonUnreadable
  Left failure -> missingAll (failureReason failure)
  where
    stampSource = "configmap nagare-system/nagare-platform-version"
    missingAll why = let fact = missingFact SourceRecorded stampSource (attempted reading) why in InstalledRelease fact fact fact fact

-- | The cluster's nodes and, for a NixOS node, the identity its host
-- module recorded. A node whose OS image is not NixOS has no NixOS facts.
hostsSection :: Reading ByteString -> Reading ByteString -> ([HostVersions], Maybe Text)
hostsSection nodesReading identityReading = case result nodesReading of
  Left failure -> ([], Just (failureReason failure))
  Right bytes -> case parseNodes bytes of
    Nothing -> ([], Just reasonUnreadable)
    Just nodes -> (map host nodes, Nothing)
  where
    nodeSource = "node status.nodeInfo"
    identitySource = "configmap kube-system/nagare-host-identity"
    host (nodeName, nodeUid, osImageValue, kernelValue, kubeletValue) =
      HostVersions
        { node = nodeName
        , uid = nodeUid
        , osImage = observedFact nodeSource (attempted nodesReading) osImageValue
        , kernel = observedFact nodeSource (attempted nodesReading) kernelValue
        , kubernetes = observedFact nodeSource (attempted nodesReading) kubeletValue
        , nixos = nixosIdentity nodeName (maybe False (T.isPrefixOf "NixOS") osImageValue)
        }
    nixosIdentity nodeName isNixos
      | not isNixos = uniform (missingFact SourceRecorded identitySource (attempted identityReading) reasonNotApplicable)
      | otherwise = case result identityReading of
          Left failure -> uniform (missingFact SourceRecorded identitySource (attempted identityReading) (failureReason failure))
          Right bytes -> case configMapData bytes of
            Nothing -> uniform (missingFact SourceRecorded identitySource (attempted identityReading) reasonUnreadable)
            Just fields
              | maybe False (/= nodeName) (Map.lookup "hostname" fields) ->
                  uniform (missingFact SourceRecorded identitySource (attempted identityReading) reasonNotRecorded)
              | otherwise ->
                  let fact key = recordedFact identitySource (attempted identityReading) (Map.lookup key fields)
                   in NixosIdentity (fact "release") (fact "codeName") (fact "version") (fact "revision")
    uniform fact = NixosIdentity fact fact fact fact

parseNodes :: ByteString -> Maybe [(Text, Text, Maybe Text, Maybe Text, Maybe Text)]
parseNodes bytes = do
  object <- either (const Nothing) Just (eitherDecodeStrict' bytes)
  items <- arrayAt ["items"] object
  pure . sortOn (\(nodeName, _, _, _, _) -> nodeName) $
    [ (nodeName, nodeUid, textAt ["status", "nodeInfo", "osImage"] item, textAt ["status", "nodeInfo", "kernelVersion"] item, textAt ["status", "nodeInfo", "kubeletVersion"] item)
    | item <- items
    , Just nodeName <- [textAt ["metadata", "name"] item]
    , Just nodeUid <- [textAt ["metadata", "uid"] item]
    ]

-- | Every accepted platform workload other than a database server, with the
-- pods that run it.
componentsSection :: [DeclaredWorkload] -> Map Text (Reading [Pod]) -> Text -> [ComponentVersions]
componentsSection workloads podsByNamespace declaredAt =
  [ ComponentVersions
      { scope = workload ^. #scope
      , resource = workload ^. #resource
      , kind = kindText (workload ^. #kind)
      , namespace = workload ^. #namespace
      , name = workload ^. #name
      , declaredVersion = declaredVersionFact workload
      , declaredChartVersion =
          if workload ^. #kind == KindHelmRelease
            then recordedFact declaredSource declaredAt (workload ^. #chartVersion)
            else missingFact SourceRecorded declaredSource declaredAt reasonNotApplicable
      , declaredImages = [DeclaredImage containerName (recordedFact declaredSource declaredAt (Just image)) | (containerName, image) <- workload ^. #images]
      , workloads = [running' pod | pod <- podsOf, selects workload pod]
      , workloadsReason = Nullable podsReason
      }
  | workload <- workloads
  , isPlatformScope (workload ^. #scope)
  , not (isDatabaseServer workload)
  , let (podsOf, podsReason, running') = observedPods workload podsByNamespace
  ]
  where
    declaredVersionFact workload
      | not (workload ^. #understood) = missingFact SourceRecorded declaredSource declaredAt reasonProbeUnsupported
      | workload ^. #kind == KindHelmRelease = missingFact SourceRecorded declaredSource declaredAt reasonNotApplicable
      | otherwise = recordedFact declaredSource declaredAt (workload ^. #version)

-- | The pods listed in a workload's namespace, a reason when the list could
-- not be read, and how one pod is reported.
observedPods :: DeclaredWorkload -> Map Text (Reading [Pod]) -> ([Pod], Maybe Text, Pod -> Workload)
observedPods workload podsByNamespace = case Map.lookup (workload ^. #namespace) podsByNamespace of
  Nothing -> ([], Just reasonCollectionDeadline, report "")
  Just reading -> case result reading of
    Left failure -> ([], Just (failureReason failure), report (attempted reading))
    Right pods
      | not (workload ^. #understood) -> ([], Just reasonProbeUnsupported, report (attempted reading))
      | otherwise -> (pods, Nothing, report (attempted reading))
  where
    report readAt pod =
      Workload
        { pod = pod ^. #name
        , podUid = pod ^. #uid
        , containers = [ObservedContainer (container ^. #name) (imageFact readAt container) (digestFact readAt container) | container <- pod ^. #containers]
        }

imageFact :: Text -> PodContainer -> Fact
imageFact readAt container = observedFact podSource readAt (container ^. #image)

-- | The digest part of a container's @imageID@ (@repository\@sha256:…@).
digestFact :: Text -> PodContainer -> Fact
digestFact readAt container = observedFact podSource readAt (container ^. #imageId >>= digestOf)
  where
    digestOf imageId = case T.breakOnEnd "@" imageId of
      ("", _) -> if "sha256:" `T.isPrefixOf` imageId then Just imageId else Nothing
      (_, digest) | not (T.null digest) -> Just digest
      _ -> Nothing

-- | The database pods whose engine version is probed: every running pod of
-- an accepted database server, with its engine.
databaseTargets :: [DeclaredWorkload] -> Map Text (Reading [Pod]) -> [(Text, Text, Pod)]
databaseTargets workloads podsByNamespace =
  [ (engineText, workload ^. #namespace, pod)
  | workload <- workloads
  , Just engineText <- [databaseEngine workload]
  , Just reading <- [Map.lookup (workload ^. #namespace) podsByNamespace]
  , Right pods <- [result reading]
  , pod <- pods
  , selects workload pod
  , pod ^. #running
  ]

databaseEngine :: DeclaredWorkload -> Maybe Text
databaseEngine workload
  | workload ^. #kind == KindStatefulSet = Map.lookup "nagare.dev/engine" (workload ^. #labels)
  | otherwise = Nothing

-- | Every accepted database server: its declared engine, version literal and
-- image beside each running instance and the version it reported, keyed by
-- namespace and pod. Tenant databases are not servers and never appear.
databasesSection :: [DeclaredWorkload] -> Map Text (Reading [Pod]) -> Map (Text, Text) EngineReading -> Text -> [DatabaseVersions]
databasesSection workloads podsByNamespace readings declaredAt =
  [ DatabaseVersions
      { scope = workload ^. #scope
      , namespace = workload ^. #namespace
      , server = workload ^. #name
      , engine = engineText
      , declaredVersion = recordedFact declaredSource declaredAt (declaredImage >>= tagOf)
      , declaredImage = recordedFact declaredSource declaredAt declaredImage
      , instances = [instanceOf engineText (workload ^. #namespace) readAt pod | pod <- podsOf, selects workload pod]
      , instancesReason = Nullable podsReason
      }
  | workload <- workloads
  , Just engineText <- [databaseEngine workload]
  , let declaredImage = snd <$> listToMaybe' (workload ^. #images)
        (podsOf, podsReason, _) = observedPods workload podsByNamespace
        readAt = maybe "" attempted (Map.lookup (workload ^. #namespace) podsByNamespace)
  ]
  where
    -- The declared version is the image tag, kept literally: @postgres:18@
    -- declares @18@, not the running minor.
    tagOf image = case T.breakOnEnd ":" (fst (T.breakOn "@" image)) of
      (prefix, tag) | not (T.null prefix) && not (T.null tag) && not ("/" `T.isInfixOf` tag) -> Just tag
      _ -> Nothing
    instanceOf engineText namespaceText readAt pod =
      let primary = listToMaybe' (pod ^. #containers)
       in DatabaseInstance
            { pod = pod ^. #name
            , podUid = pod ^. #uid
            , image = maybe (missingFact SourceObserved podSource readAt reasonNotRecorded) (imageFact readAt) primary
            , imageDigest = maybe (missingFact SourceObserved podSource readAt reasonNotRecorded) (digestFact readAt) primary
            , reportedVersion = reported engineText namespaceText readAt pod
            }
    reported engineText namespaceText readAt pod =
      let probeSource = maybe "engine probe" snd (engineProbe engineText)
       in case engineProbe engineText of
            Nothing -> missingFact SourceObserved probeSource readAt reasonProbeUnsupported
            Just _
              | not (pod ^. #running) -> missingFact SourceObserved probeSource readAt reasonProbeFailed
              | otherwise -> case Map.lookup (namespaceText, pod ^. #name) readings of
                  Nothing -> missingFact SourceObserved probeSource readAt reasonCollectionDeadline
                  Just reading -> case (result (reading ^. #version), result (reading ^. #uidAfter)) of
                    (Left failure, _) -> missingFact SourceObserved probeSource (attempted (reading ^. #version)) (failureReason failure)
                    (_, Left failure) -> missingFact SourceObserved probeSource (attempted (reading ^. #version)) (failureReason failure)
                    (Right output, Right after)
                      | after /= pod ^. #uid -> missingFact SourceObserved probeSource (attempted (reading ^. #version)) reasonIdentityChanged
                      | otherwise -> case parseEngineVersion engineText output of
                          Nothing -> missingFact SourceObserved probeSource (attempted (reading ^. #version)) reasonProbeFailed
                          found -> observedFact probeSource (attempted (reading ^. #version)) found

declaredSource, podSource :: Text
declaredSource = "accepted declaration"
podSource = "pod status"

configMapData :: ByteString -> Maybe (Map Text Text)
configMapData bytes = do
  object <- either (const Nothing) Just (eitherDecodeStrict' bytes)
  pure (stringMap (valueAt ["data"] object))

valueAt :: [Text] -> Value -> Maybe Value
valueAt [] value = Just value
valueAt (key : rest) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= valueAt rest
valueAt _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case valueAt path value of
  Just (String text) -> Just text
  _ -> Nothing

arrayAt :: [Text] -> Value -> Maybe [Value]
arrayAt path value = case valueAt path value of
  Just (Array items) -> Just (toList items)
  _ -> Nothing

stringMap :: Maybe Value -> Map Text Text
stringMap = \case
  Just (Object fields) -> Map.fromList [(Key.toText key, text) | (key, String text) <- KeyMap.toList fields]
  _ -> Map.empty

mapMaybe' :: (a -> Maybe b) -> [a] -> [b]
mapMaybe' f = foldr (\x acc -> maybe acc (: acc) (f x)) []

listToMaybe' :: [a] -> Maybe a
listToMaybe' = \case
  [] -> Nothing
  x : _ -> Just x
