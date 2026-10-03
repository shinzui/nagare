-- | Install and reobserve a live-volume admission guard through one explicit
-- Kubernetes context. A successful create response alone is never a proof
-- that admission is enforcing the guard.
module Nagare.Inventory.DataFence.MountGuardRuntime
  ( MountGuardTransport (..)
  , kubectlMountGuardTransport
  , installMountGuard
  , observeMountGuard
  , removeMountGuard
  , observeMountGuardAbsent
  , guardObjectAddresses
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding (guard, (.=))
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( KubernetesRuntimeConfig (..)
  )
import Nagare.Inventory.DataFence.MountGuard
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data MountGuardTransport = MountGuardTransport
  { readGuardObject :: !(Text -> Text -> IO (Either Text (Maybe Value)))
  , createGuardObject :: !(Value -> IO (Either Text ()))
  , deleteGuardObject :: !(Text -> Text -> Text -> Text -> IO (Either Text ()))
  , probeForeignMountDenied :: !(MountGuard -> IO (Either Text Bool))
  , probeWriterScaleDenied :: !(MountGuard -> IO (Either Text Bool))
  , probeServiceMutationDenied :: !(MountGuard -> IO (Either Text Bool))
  , probeEndpointSliceDenied :: !(MountGuard -> IO (Either Text Bool))
  , probeLegacyEndpointsDenied :: !(MountGuard -> IO (Either Text Bool))
  , probeScheduleDenied :: !(MountGuard -> IO (Either Text Bool))
  }

-- | Existing objects are accepted only when their effective policy and
-- binding match the reviewed request. A partly installed set is recoverable:
-- a fresh process can create the missing members and reobserve all of them.
installMountGuard :: MountGuardTransport -> MountGuard -> IO (Either Text ())
installMountGuard transport guard = installAll (guardObjects guard)
  where
    installAll [] = pure (Right ())
    installAll (expected : rest) = do
      installed <- installOne expected
      case installed of
        Left reason -> pure (Left reason)
        Right () -> installAll rest
    installOne expected = case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        case current of
          Left reason -> pure (Left reason)
          Right (Just observed) -> pure (matchingObject expected observed)
          Right Nothing -> createGuardObject transport expected

-- | Proof is made from current API objects plus a server-side dry-run Pod
-- admission request with no permitted owner. This is one component of the
-- full fence proof; existing Pods, attachments, and database writers need
-- separate observations.
observeMountGuard :: MountGuardTransport -> MountGuard -> IO (Either Text Bool)
observeMountGuard transport guard = do
  observed <- forM (guardObjects guard) $ \expected -> do
    case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        pure $ case current of
          Left reason -> Left reason
          Right Nothing -> Right False
          Right (Just actual) -> case matchingObject expected actual of
            Left _ -> Right False
            Right () -> Right True
  case sequence observed of
    Left reason -> pure (Left reason)
    Right matches | not (and matches) -> pure (Right False)
    Right _ -> do
      foreignDenied <- probeForeignMountDenied transport guard
      case foreignDenied of
        Left reason -> pure (Left reason)
        Right False -> pure (Right False)
        Right True -> do
          scaleDenied <- probeWriterScaleDenied transport guard
          case scaleDenied of
            Left reason -> pure (Left reason)
            Right False -> pure (Right False)
            Right True -> do
              serviceDenied <- probeServiceMutationDenied transport guard
              case serviceDenied of
                Left reason -> pure (Left reason)
                Right False -> pure (Right False)
                Right True -> do
                  endpointsDenied <- probeEndpointSliceDenied transport guard
                  case endpointsDenied of
                    Left reason -> pure (Left reason)
                    Right False -> pure (Right False)
                    Right True -> do
                      legacyDenied <- probeLegacyEndpointsDenied transport guard
                      case legacyDenied of
                        Left reason -> pure (Left reason)
                        Right False -> pure (Right False)
                        Right True -> probeScheduleDenied transport guard

-- | Only the explicit verified-release path may call this. Bindings go first
-- so no policy can remain unexpectedly active after release. Each deletion is
-- conditional on the current UID and resourceVersion; an uncertain response
-- is resolved by re-reading the object on restart.
removeMountGuard :: MountGuardTransport -> MountGuard -> IO (Either Text ())
removeMountGuard transport guard = removeAll (reverse (guardObjects guard))
  where
    removeAll [] = do
      absent <- observeMountGuardAbsent transport guard
      pure $ case absent of
        Right True -> Right ()
        Right False -> Left "Kubernetes mount guard removal is not yet observed"
        Left reason -> Left reason
    removeAll (expected : rest) = case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        case current of
          Left reason -> pure (Left reason)
          Right Nothing -> removeAll rest
          Right (Just observed) -> case do
            matchingObject expected observed
            metadata <- case observed of
              Object root -> objectField "metadata" root
              _ -> Left "mount guard object is not a JSON object"
            uid <- textField "uid" metadata
            revision <- textField "resourceVersion" metadata
            pure (uid, revision) of
            Left reason -> pure (Left reason)
            Right (uid, revision) -> do
              deleted <- deleteGuardObject transport kind name uid revision
              case deleted of
                Left reason -> pure (Left reason)
                Right () -> removeAll rest

observeMountGuardAbsent ::
  MountGuardTransport ->
  MountGuard ->
  IO (Either Text Bool)
observeMountGuardAbsent transport guard = do
  observed <- forM (guardObjects guard) $ \expected ->
    case objectAddress expected of
      Left reason -> pure (Left reason)
      Right (kind, name) -> do
        current <- readGuardObject transport kind name
        pure (maybe True (const False) <$> current)
  pure (and <$> sequence observed)

guardObjects :: MountGuard -> [Value]
guardObjects guard =
  let (podPolicy, podBinding) = mountGuardObjects guard
      (pvcPolicy, pvcBinding) = pvcMutationGuardObjects guard
      (pvPolicy, pvBinding) = pvMutationGuardObjects guard
      (namespacePolicy, namespaceBinding) = namespaceDeleteGuardObjects guard
      writerPairs = statefulWriterGuardObjects guard
      deploymentPairs = deploymentWriterGuardObjects guard
      servicePairs = maybe [] (: []) (serviceMutationGuardObjects guard)
      slicePairs = maybe [] (: []) (endpointSliceGuardObjects guard)
      legacyPairs = maybe [] (: []) (legacyEndpointsGuardObjects guard)
      schedulePairs = scheduledWriterGuardObjects guard
   in [podPolicy, pvcPolicy, pvPolicy, namespacePolicy]
        <> map fst writerPairs
        <> map fst deploymentPairs
        <> map fst servicePairs
        <> map fst slicePairs
        <> map fst legacyPairs
        <> map fst schedulePairs
        <> [podBinding, pvcBinding, pvBinding, namespaceBinding]
        <> map snd writerPairs
        <> map snd deploymentPairs
        <> map snd servicePairs
        <> map snd slicePairs
        <> map snd legacyPairs
        <> map snd schedulePairs

-- | Exact cluster-scoped policy and binding names used by authorization
-- checks. A broad resource-only check misses name-scoped RBAC grants.
guardObjectAddresses :: MountGuard -> Either Text [(Text, Text)]
guardObjectAddresses = traverse objectAddress . guardObjects

objectAddress :: Value -> Either Text (Text, Text)
objectAddress (Object root) = do
  kind <- textField "kind" root
  metadata <- objectField "metadata" root
  name <- textField "name" metadata
  pure (kind, name)
objectAddress _ = Left "mount guard object is not a JSON object"

matchingObject :: Value -> Value -> Either Text ()
matchingObject (Object expected) (Object observed) = do
  unless
    ( KM.lookup "kind" expected == KM.lookup "kind" observed
        && KM.lookup "apiVersion" expected == KM.lookup "apiVersion" observed
        && KM.lookup "spec" expected == KM.lookup "spec" observed
    )
    (Left "mount guard policy or binding differs from the reviewed object")
  expectedMeta <- objectField "metadata" expected
  observedMeta <- objectField "metadata" observed
  unless
    ( KM.lookup "name" expectedMeta == KM.lookup "name" observedMeta
        && KM.lookup "annotations" expectedMeta == KM.lookup "annotations" observedMeta
    )
    (Left "mount guard metadata differs from the reviewed object")
matchingObject _ _ = Left "mount guard object is not a JSON object"

objectField :: Text -> KM.KeyMap Value -> Either Text (KM.KeyMap Value)
objectField key root = case KM.lookup (Key.fromText key) root of
  Just (Object value) -> Right value
  _ -> Left ("mount guard " <> key <> " is missing")

textField :: Text -> KM.KeyMap Value -> Either Text Text
textField key root = case KM.lookup (Key.fromText key) root of
  Just (String value) | not (T.null value) -> Right value
  _ -> Left ("mount guard " <> key <> " is missing")

kubectlMountGuardTransport :: KubernetesRuntimeConfig -> MountGuardTransport
kubectlMountGuardTransport config =
  MountGuardTransport
    readOne
    createOne
    deleteOne
    probe
    probeScale
    probeService
    probeSlice
    probeLegacy
    probeSchedule
  where
    invoke arguments input = do
      guarded <- runtimeGuard config
      case guarded of
        Left reason -> pure (Left ("cluster guard refused: " <> reason))
        Right () -> do
          result <-
            try
              ( readProcessWithExitCode
                  "kubectl"
                  ( [ "--context"
                    , T.unpack (runtimeKubectlContext config)
                    , "--request-timeout=10s"
                    ]
                      <> arguments
                  )
                  input
              )
          pure $ case result of
            Left (_ :: IOException) -> Left "could not invoke kubectl"
            Right output -> Right output
    readOne kind name = do
      result <-
        invoke
          [ "get"
          , T.unpack kind
          , T.unpack name
          , "-o"
          , "json"
          , "--ignore-not-found"
          ]
          ""
      pure $ case result of
        Left reason -> Left reason
        Right (ExitFailure _, _, _) -> Left "could not read mount guard object"
        Right (ExitSuccess, output, _) | T.null (T.strip (T.pack output)) -> Right Nothing
        Right (ExitSuccess, output, _) ->
          Just <$> first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    createOne value = do
      result <- invoke ["create", "-f", "-"] (T.unpack (TE.decodeUtf8 (BL.toStrict (encode value))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure _, _, _) -> Left "could not create mount guard object"
    deleteOne kind name uid revision = case kind of
      "ValidatingAdmissionPolicy" -> invokeDelete "validatingadmissionpolicies" name uid revision
      "ValidatingAdmissionPolicyBinding" ->
        invokeDelete "validatingadmissionpolicybindings" name uid revision
      _ -> pure (Left "unsupported mount guard kind for conditional deletion")
    invokeDelete plural name uid revision = do
      let path = "/apis/admissionregistration.k8s.io/v1/" <> plural <> "/" <> name
          options =
            object
              [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
              , "kind" .= ("DeleteOptions" :: Text)
              , "preconditions"
                  .= object
                    [ "uid" .= uid
                    , "resourceVersion" .= revision
                    ]
              ]
      result <-
        invoke
          ["delete", "--raw", T.unpack path, "-f", "-"]
          (T.unpack (TE.decodeUtf8 (BL.toStrict (encode options))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right ()
        Right (ExitFailure _, _, _) -> Left "conditional mount guard deletion failed"
    probe guard = do
      let name = mountGuardName guard <> "-foreign-probe"
          pod =
            object
              [ "apiVersion" .= ("v1" :: Text)
              , "kind" .= ("Pod" :: Text)
              , "metadata" .= object ["name" .= name]
              , "spec"
                  .= object
                    [ "containers"
                        .= [ object
                               [ "name" .= ("probe" :: Text)
                               , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                               , "volumeMounts"
                                   .= [ object
                                          [ "name" .= ("data" :: Text)
                                          , "mountPath" .= ("/data" :: Text)
                                          ]
                                      ]
                               ]
                           ]
                    , "volumes"
                        .= [ object
                               [ "name" .= ("data" :: Text)
                               , "persistentVolumeClaim"
                                   .= object
                                     ["claimName" .= guardClaimName guard]
                               ]
                           ]
                    ]
              ]
      result <-
        invoke
          [ "--namespace"
          , T.unpack (guardNamespaceName guard)
          , "create"
          , "-f"
          , "-"
          , "--dry-run=server"
          ]
          (T.unpack (TE.decodeUtf8 (BL.toStrict (encode pod))))
      pure $ case result of
        Left reason -> Left reason
        Right (ExitSuccess, _, _) -> Right False
        Right (ExitFailure _, _, errors) ->
          Right ("Nagare live PVC is fenced" `T.isInfixOf` T.pack errors)
    probeScale guard = do
      statefulResults <- forM (guardedStatefulSets guard) $ \writer -> do
        let patch =
              toJSON
                [ object
                    [ "op" .= ("test" :: Text)
                    , "path" .= ("/metadata/uid" :: Text)
                    , "value" .= guardedWriterUid writer
                    ]
                , object
                    [ "op" .= ("replace" :: Text)
                    , "path" .= ("/spec/replicas" :: Text)
                    , "value" .= (1 :: Int)
                    ]
                ]
        parent <-
          invoke
            [ "--namespace"
            , T.unpack (guardedWriterNamespace writer)
            , "patch"
            , "statefulset"
            , T.unpack (guardedWriterName writer)
            , "--type=json"
            , "-p"
            , T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))
            , "--dry-run=server"
            ]
            ""
        scale <-
          invoke
            [ "--namespace"
            , T.unpack (guardedWriterNamespace writer)
            , "scale"
            , "statefulset"
            , T.unpack (guardedWriterName writer)
            , "--replicas=1"
            , "--dry-run=server"
            ]
            ""
        deletion <-
          invoke
            [ "--namespace"
            , T.unpack (guardedWriterNamespace writer)
            , "delete"
            , "statefulset"
            , T.unpack (guardedWriterName writer)
            , "--dry-run=server"
            ]
            ""
        pure $ and <$> traverse denied [parent, scale, deletion]
      deploymentResults <- forM (guardedDeployments guard) $ \deployment -> do
        let namespace = T.unpack (guardedDeploymentNamespace deployment)
            name = T.unpack (guardedDeploymentName deployment)
            patch =
              toJSON
                [ object
                    [ "op" .= ("test" :: Text)
                    , "path" .= ("/metadata/uid" :: Text)
                    , "value" .= guardedDeploymentUid deployment
                    ]
                , object
                    [ "op" .= ("replace" :: Text)
                    , "path" .= ("/spec/replicas" :: Text)
                    , "value" .= (1 :: Int)
                    ]
                ]
            selector = guardedDeploymentSelector deployment
            probeName = T.take 40 (mountGuardName guard) <> "-client-probe"
            pod =
              object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("Pod" :: Text)
                , "metadata"
                    .= object
                      [ "name" .= probeName
                      , "labels" .= selector
                      ]
                , "spec"
                    .= object
                      [ "containers"
                          .= [ object
                                 [ "name" .= ("probe" :: Text)
                                 , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                                 ]
                             ]
                      ]
                ]
            replicaSet =
              object
                [ "apiVersion" .= ("apps/v1" :: Text)
                , "kind" .= ("ReplicaSet" :: Text)
                , "metadata"
                    .= object
                      [ "name" .= (T.take 40 (mountGuardName guard) <> "-rs-probe")
                      , "labels" .= selector
                      , "ownerReferences"
                          .= [ object
                                 [ "apiVersion" .= ("apps/v1" :: Text)
                                 , "kind" .= ("Deployment" :: Text)
                                 , "name" .= guardedDeploymentName deployment
                                 , "uid" .= guardedDeploymentUid deployment
                                 , "controller" .= True
                                 ]
                             ]
                      ]
                , "spec"
                    .= object
                      [ "replicas" .= (0 :: Int)
                      , "selector" .= object ["matchLabels" .= selector]
                      , "template"
                          .= object
                            [ "metadata" .= object ["labels" .= selector]
                            , "spec"
                                .= object
                                  [ "containers"
                                      .= [ object
                                             [ "name" .= ("probe" :: Text)
                                             , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                                             ]
                                         ]
                                  ]
                            ]
                      ]
                ]
        parent <-
          invoke
            [ "--namespace"
            , namespace
            , "patch"
            , "deployment"
            , name
            , "--type=json"
            , "-p"
            , T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))
            , "--dry-run=server"
            ]
            ""
        scale <-
          invoke
            [ "--namespace"
            , namespace
            , "scale"
            , "deployment"
            , name
            , "--replicas=1"
            , "--dry-run=server"
            ]
            ""
        deletion <-
          invoke
            [ "--namespace"
            , namespace
            , "delete"
            , "deployment"
            , name
            , "--dry-run=server"
            ]
            ""
        podCreate <-
          invoke
            [ "--namespace"
            , namespace
            , "create"
            , "-f"
            , "-"
            , "--dry-run=server"
            ]
            (T.unpack (TE.decodeUtf8 (BL.toStrict (encode pod))))
        replicaSetCreate <-
          invoke
            [ "--namespace"
            , namespace
            , "create"
            , "-f"
            , "-"
            , "--dry-run=server"
            ]
            (T.unpack (TE.decodeUtf8 (BL.toStrict (encode replicaSet))))
        pure $
          and
            <$> sequence
              [ deniedWith "Nagare database client controller is fenced" parent
              , deniedWith "Nagare database client controller is fenced" scale
              , deniedWith "Nagare database client controller is fenced" deletion
              , deniedWith "Nagare database client Pod is fenced" podCreate
              , deniedWith
                  "Nagare database client controller is fenced"
                  replicaSetCreate
              ]
      pure (and <$> sequence (statefulResults <> deploymentResults))
    probeService guard = case guardedService guard of
      Nothing -> pure (Right True)
      Just service -> do
        let patch =
              toJSON
                [ object
                    [ "op" .= ("test" :: Text)
                    , "path" .= ("/metadata/uid" :: Text)
                    , "value" .= guardedServiceUid service
                    ]
                , object
                    [ "op" .= ("add" :: Text)
                    , "path" .= ("/metadata/annotations" :: Text)
                    , "value"
                        .= object
                          ["nagare.dev/fence-probe" .= ("true" :: Text)]
                    ]
                ]
        update <-
          invoke
            [ "--namespace"
            , T.unpack (guardedServiceNamespace service)
            , "patch"
            , "service"
            , T.unpack (guardedServiceName service)
            , "--type=json"
            , "-p"
            , T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))
            , "--dry-run=server"
            ]
            ""
        deletion <-
          invoke
            [ "--namespace"
            , T.unpack (guardedServiceNamespace service)
            , "delete"
            , "service"
            , T.unpack (guardedServiceName service)
            , "--dry-run=server"
            ]
            ""
        pure (and <$> traverse serviceDenied [update, deletion])
    probeSlice guard = case guardedService guard of
      Nothing -> pure (Right True)
      Just service -> do
        let slice =
              object
                [ "apiVersion" .= ("discovery.k8s.io/v1" :: Text)
                , "kind" .= ("EndpointSlice" :: Text)
                , "metadata"
                    .= object
                      [ "name" .= (T.take 40 (mountGuardName guard) <> "-endpoint-probe")
                      , "labels"
                          .= object
                            [ "kubernetes.io/service-name" .= guardedServiceName service
                            , "endpointslice.kubernetes.io/managed-by" .= ("nagare-fence-probe" :: Text)
                            ]
                      ]
                , "addressType" .= ("IPv4" :: Text)
                , "ports"
                    .= [ object
                           [ "port" .= (5432 :: Int)
                           , "protocol" .= ("TCP" :: Text)
                           ]
                       ]
                , "endpoints"
                    .= [ object
                           ["addresses" .= (["10.9.8.7"] :: [Text])]
                       ]
                ]
        result <-
          invoke
            [ "--namespace"
            , T.unpack (guardedServiceNamespace service)
            , "create"
            , "-f"
            , "-"
            , "--dry-run=server"
            ]
            (T.unpack (TE.decodeUtf8 (BL.toStrict (encode slice))))
        pure $ case result of
          Left reason -> Left reason
          Right (ExitSuccess, _, _) -> Right False
          Right (ExitFailure _, _, errors) ->
            Right ("Nagare database endpoints are fenced" `T.isInfixOf` T.pack errors)
    probeLegacy guard = case guardedService guard of
      Nothing -> pure (Right True)
      Just service -> do
        let namespace = T.unpack (guardedServiceNamespace service)
            name = T.unpack (guardedServiceName service)
            endpoints =
              object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("Endpoints" :: Text)
                , "metadata" .= object ["name" .= guardedServiceName service]
                , "subsets"
                    .= [ object
                           [ "addresses" .= [object ["ip" .= ("10.9.8.7" :: Text)]]
                           , "ports" .= [object ["port" .= (5432 :: Int)]]
                           ]
                       ]
                ]
            patch =
              object
                [ "subsets"
                    .= [ object
                           [ "addresses" .= [object ["ip" .= ("10.9.8.7" :: Text)]]
                           , "ports" .= [object ["port" .= (5432 :: Int)]]
                           ]
                       ]
                ]
        existing <-
          invoke
            [ "--namespace"
            , namespace
            , "get"
            , "endpoints"
            , name
            , "-o"
            , "json"
            , "--ignore-not-found"
            ]
            ""
        case existing of
          Left reason -> pure (Left reason)
          Right (ExitFailure _, _, _) -> pure (Left "could not read legacy Endpoints")
          Right (ExitSuccess, output, _) -> do
            let input =
                  T.unpack
                    ( TE.decodeUtf8
                        ( BL.toStrict
                            ( encode
                                (if T.null (T.strip (T.pack output)) then endpoints else patch)
                            )
                        )
                    )
                arguments =
                  if T.null (T.strip (T.pack output))
                    then ["--namespace", namespace, "create", "-f", "-", "--dry-run=server"]
                    else
                      [ "--namespace"
                      , namespace
                      , "patch"
                      , "endpoints"
                      , name
                      , "--type=merge"
                      , "-p"
                      , input
                      , "--dry-run=server"
                      ]
            result <- invoke arguments (if T.null (T.strip (T.pack output)) then input else "")
            pure $ case result of
              Left reason -> Left reason
              Right (ExitSuccess, _, _) -> Right False
              Right (ExitFailure _, _, errors) ->
                Right
                  ("Nagare legacy database endpoints are fenced" `T.isInfixOf` T.pack errors)
    probeSchedule guard = do
      results <- forM (guardedSchedules guard) $ \schedule -> do
        let namespace = T.unpack (guardedScheduleNamespace schedule)
            name = T.unpack (guardedScheduleName schedule)
            patch =
              toJSON
                [ object
                    [ "op" .= ("test" :: Text)
                    , "path" .= ("/metadata/uid" :: Text)
                    , "value" .= guardedScheduleUid schedule
                    ]
                , object
                    [ "op" .= ("add" :: Text)
                    , "path" .= ("/spec/suspend" :: Text)
                    , "value" .= False
                    ]
                ]
            job =
              object
                [ "apiVersion" .= ("batch/v1" :: Text)
                , "kind" .= ("Job" :: Text)
                , "metadata"
                    .= object
                      [ "name" .= (T.take 40 (mountGuardName guard) <> "-job-probe")
                      , "ownerReferences"
                          .= [ object
                                 [ "apiVersion" .= ("batch/v1" :: Text)
                                 , "kind" .= ("CronJob" :: Text)
                                 , "name" .= guardedScheduleName schedule
                                 , "uid" .= guardedScheduleUid schedule
                                 , "controller" .= True
                                 ]
                             ]
                      ]
                , "spec"
                    .= object
                      [ "template"
                          .= object
                            [ "spec"
                                .= object
                                  [ "containers"
                                      .= [ object
                                             [ "name" .= ("probe" :: Text)
                                             , "image" .= ("registry.k8s.io/pause:3.9" :: Text)
                                             ]
                                         ]
                                  , "restartPolicy" .= ("Never" :: Text)
                                  ]
                            ]
                      ]
                ]
        update <-
          invoke
            [ "--namespace"
            , namespace
            , "patch"
            , "cronjob"
            , name
            , "--type=json"
            , "-p"
            , T.unpack (TE.decodeUtf8 (BL.toStrict (encode patch)))
            , "--dry-run=server"
            ]
            ""
        deletion <-
          invoke
            [ "--namespace"
            , namespace
            , "delete"
            , "cronjob"
            , name
            , "--dry-run=server"
            ]
            ""
        creation <-
          invoke
            [ "--namespace"
            , namespace
            , "create"
            , "-f"
            , "-"
            , "--dry-run=server"
            ]
            (T.unpack (TE.decodeUtf8 (BL.toStrict (encode job))))
        pure $
          and
            <$> sequence
              [ deniedWith "Nagare database schedule is fenced" update
              , deniedWith "Nagare database schedule is fenced" deletion
              , deniedWith "Nagare scheduled Job creation is fenced" creation
              ]
      pure (and <$> sequence results)
    deniedWith message result = case result of
      Left reason -> Left reason
      Right (ExitSuccess, _, _) -> Right False
      Right (ExitFailure _, _, errors) ->
        Right (message `T.isInfixOf` T.pack errors)
    serviceDenied result = case result of
      Left reason -> Left reason
      Right (ExitSuccess, _, _) -> Right False
      Right (ExitFailure _, _, errors) ->
        Right ("Nagare database Service is fenced" `T.isInfixOf` T.pack errors)
    denied result = case result of
      Left reason -> Left reason
      Right (ExitSuccess, _, _) -> Right False
      Right (ExitFailure _, _, errors) ->
        Right ("Nagare writer controller is fenced" `T.isInfixOf` T.pack errors)
