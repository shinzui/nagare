-- | A bounded F20 model: the API accepts Orphan deletion, but the webhook
-- prevents detaching controller children. Every unmodeled request is an error.
module Nagare.Test.Effectful.CollectionModel
  ( CollectionFault (..)
  , CollectionWorld (..)
  , seedCollectionWorld
  , readCollectionWorld
  , writeCollectionWorld
  , collectionRequest
  , finishOrphan
  , replaceParent
  , field
  , setField
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.KubernetesTransport
import Nagare.Resource.Types hiding (resources)
import Nagare.Test.Effectful.CollectionFixture
import Nagare.Test.Effectful.Fixture (checked)
import Nagare.Test.Effectful.Model (field, textField)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data CollectionFault = Normal | BeforeDelete | LostDeleteAck | LyingWait | ImmediateDeletion | RaceUid | RaceVersion | Cascade | CascadeLostAck | IncompleteList | DiscoveryFailure | ListFailure | MalformedList | ListWarning
  deriving stock (Eq, Show)

data CollectionWorld = CollectionWorld
  { resources :: !(Map.Map Text Value)
  , descendants :: !(Map.Map Text Value)
  , deleteBodies :: ![Value]
  , requests :: ![[String]]
  , virtualSeconds :: !Int
  , discoveredApis :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

setField :: Text -> Value -> Value -> Value
setField key value (Object fields) = Object (KM.insert (Key.fromText key) value fields)
setField _ _ _ = error "model expected object"

readCollectionWorld :: FilePath -> IO CollectionWorld
readCollectionWorld root = checked . eitherDecodeStrict <$> BS.readFile (root </> "collection-world.json")

writeCollectionWorld :: FilePath -> CollectionWorld -> IO ()
writeCollectionWorld root = BL.writeFile (root </> "collection-world.json") . encode

seedCollectionWorld :: FilePath -> IO ()
seedCollectionWorld root = writeCollectionWorld root (CollectionWorld (Map.fromList entries) children [] [] 0 modelApis)
  where
    entries = map seed (Map.toList collectionNative)
    seed (identity, (_, bytes)) =
      let value = checked (eitherDecodeStrict bytes)
          meta = field "metadata" value
          name = textField "name" meta
          kind = textField "kind" value
          api = textField "apiVersion" value
          group = if api == "v1" then "" else "." <> T.takeWhile (/= '/') api
          key = T.toLower kind <> group <> "/" <> name
          metadata =
            setField "uid" (String (name <> "-uid")) $
              setField "resourceVersion" (String "10") $
                setField "generation" (Number 1) $
                  setField
                    "annotations"
                    ( object
                        [ "nagare.dev/context-id" .= ("effectful-collection" :: Text)
                        , "nagare.dev/resource-id" .= resourceIdText identity
                        , "nagare.dev/spec-digest" .= digestText (contentDigest bytes)
                        ]
                    )
                    meta
          status =
            object
              [ "observedGeneration" .= (1 :: Int)
              , "readyReplicas" .= (1 :: Int)
              , "updatedReplicas" .= (1 :: Int)
              , "conditions"
                  .= [object ["type" .= (if kind == "Job" then "Complete" else "Ready" :: Text), "status" .= ("True" :: Text)]]
              ]
       in (key, setField "status" status (setField "metadata" metadata value))
    -- Representative direct and transitive controller edges, not a claim to
    -- reproduce all sixteen objects in the frozen native evidence.
    child name kind owner =
      ( name
      , object
          [ "apiVersion" .= (if kind `elem` ["Route", "Configuration", "Revision"] then "serving.knative.dev/v1" else if kind == "Deployment" then "apps/v1" else "v1" :: Text)
          , "kind" .= (kind :: Text)
          , "metadata"
              .= object
                [ "name" .= (name :: Text)
                , "namespace" .= ("personal" :: Text)
                , "resourceVersion" .= ("10" :: Text)
                , "uid" .= (name <> "-uid")
                , "labels" .= object ["serving.knative.dev/service" .= ("web" :: Text)]
                , "ownerReferences" .= [object ["uid" .= (owner :: Text), "controller" .= True]]
                ]
          ]
      )
    children =
      Map.fromList
        [ child "route" "Route" "web-uid"
        , child "configuration" "Configuration" "web-uid"
        , child "revision" "Revision" "configuration-uid"
        , child "deployment" "Deployment" "revision-uid"
        , child "pod" "Pod" "deployment-uid"
        ]

collectionRequest :: FilePath -> CollectionFault -> KubectlRequest -> IO KubectlResult
collectionRequest root fault request = do
  unless (request ^. #context == "effectful-local") (fail "unexpected context")
  initial <- readCollectionWorld root
  let args = request ^. #arguments
      world = initial {requests = requests initial <> [args]}
      success value = Right (ExitSuccess, T.unpack (TE.decodeUtf8 (BL.toStrict (encode value))), "")
      listSuccess resource value = case success value of
        Right (code, output, _)
          | fault == ListWarning && resource == "endpoints" ->
              Right (code, output, "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice\n")
        result -> result
      failure message = Right (ExitFailure 1, "", message)
  writeCollectionWorld root world
  case args of
    ["api-resources", "--namespaced=true", "--verbs=list", "-o", "name"] ->
      pure (if fault == DiscoveryFailure then Right (ExitFailure 1, T.unpack (T.unlines (take 74 (discoveredApis world))), "partial discovery unavailable") else Right (ExitSuccess, T.unpack (T.unlines (discoveredApis world)), ""))
    ["get", resource, "--namespace", "personal", "-o", "json"]
      | T.pack resource `elem` discoveredApis world ->
          pure
            ( if fault == ListFailure && resource == "services"
                then failure "Forbidden"
                else
                  if fault == MalformedList && resource == "services"
                    then success (object ["items" .= ([] :: [Value])])
                    else
                      listSuccess
                        resource
                        ( object
                            [ "apiVersion" .= ("v1" :: Text)
                            , "kind" .= ("List" :: Text)
                            , "metadata" .= object ["continue" .= (if fault == IncompleteList then "next-page" else "" :: Text)]
                            , "items" .= [value | value <- Map.elems (resources world) <> Map.elems (descendants world), modelToken value == T.pack resource]
                            ]
                        )
            )
    ["get", kind, name, "--namespace", "personal", "-o", "json", "--ignore-not-found"] -> do
      unless (null (request ^. #input)) (fail "get with stdin")
      let key = T.pack (kind <> "/" <> name)
      case Map.lookup key (resources world) of
        Just value -> pure (success value)
        Nothing | key == parentKey -> pure (Right (ExitSuccess, "", ""))
        _ -> fail ("unmodeled get: " <> show args)
    ["delete", "--raw", "/apis/serving.knative.dev/v1/namespaces/personal/services/web", "-f", "-"] -> do
      let body = checked (eitherDecodeStrict (TE.encodeUtf8 (T.pack (request ^. #input))))
          expected =
            object
              [ "apiVersion" .= ("meta.k8s.io/v1" :: Text)
              , "kind" .= ("DeleteOptions" :: Text)
              , "preconditions" .= object ["uid" .= ("web-uid" :: Text), "resourceVersion" .= ("10" :: Text)]
              , "propagationPolicy" .= (if fault `elem` [Cascade, CascadeLostAck] then "Background" else "Orphan" :: Text)
              ]
      unless (body == expected) (fail "delete exceeded exact reviewed parent authority or changed preconditions")
      when (fault `elem` [RaceUid, RaceVersion]) $
        replaceParent root (if fault == RaceUid then "replacement-uid" else "web-uid") "11"
      raced <- readCollectionWorld root
      let parent = Map.lookup parentKey (resources raced)
          agrees value =
            field "uid" (field "metadata" value) == String "web-uid"
              && field "resourceVersion" (field "metadata" value) == String "10"
      if fault == BeforeDelete
        then pure (Left "failure before sending delete")
        else
          if maybe False agrees parent
            then do
              let value = maybe (error "missing parent") id parent
                  pending =
                    setField
                      "metadata"
                      ( setField "resourceVersion" (String "11") $
                          setField "deletionTimestamp" (String "2026-10-02T00:00:00Z") $
                            setField "finalizers" (toJSON ["orphan" :: Text]) (field "metadata" value)
                      )
                      value
                  next =
                    if fault `elem` [ImmediateDeletion, Cascade, CascadeLostAck]
                      then Map.delete parentKey (resources raced)
                      else Map.insert parentKey pending (resources raced)
              writeCollectionWorld root raced {resources = next, deleteBodies = deleteBodies raced <> [body]}
              pure (if fault `elem` [LostDeleteAck, CascadeLostAck] then Left "accepted delete; reply lost" else success (object []))
            else pure (failure "Conflict: UID or resourceVersion precondition failed")
    ["wait", "--for=delete", "service.serving.knative.dev/web", "--timeout=30s", "--namespace", "personal"] -> do
      unless (null (request ^. #input)) (fail "wait with stdin")
      writeCollectionWorld root world {virtualSeconds = virtualSeconds world + 30}
      pure
        ( if fault == LyingWait || Map.notMember parentKey (resources world)
            then success (object [])
            else failure "orphan finalizer blocked by child admission"
        )
    _ -> fail ("unmodeled collection effect: " <> show args)

replaceParent :: FilePath -> Text -> Text -> IO ()
replaceParent root uid version = do
  world <- readCollectionWorld root
  unless (Map.member parentKey (resources world)) (fail "parent missing")
  let change value =
        setField
          "metadata"
          ( setField "uid" (String uid) $
              setField "resourceVersion" (String version) (field "metadata" value)
          )
          value
  writeCollectionWorld root world {resources = Map.adjust change parentKey (resources world)}

-- An explicit external model event: admission now permits orphaning. Only the
-- direct owner links detach; children survive and transitive links stay intact.
-- This is not a proposed live workaround, finalizer patch or cascade operation.
finishOrphan :: FilePath -> IO ()
finishOrphan root = do
  world <- readCollectionWorld root
  parent <- maybe (fail "missing pending parent") pure (Map.lookup parentKey (resources world))
  unless (field "finalizers" (field "metadata" parent) == toJSON ["orphan" :: Text]) (fail "parent not pending")
  let orphan name value
        | name `elem` ["route", "configuration"] =
            setField
              "metadata"
              (setField "ownerReferences" (toJSON ([] :: [Value])) (field "metadata" value))
              value
        | otherwise = value
  writeCollectionWorld
    root
    world
      { resources = Map.delete parentKey (resources world)
      , descendants = Map.mapWithKey orphan (descendants world)
      }

modelApis :: [Text]
modelApis =
  [ "services.serving.knative.dev"
  , "statefulsets.apps"
  , "persistentvolumeclaims"
  , "jobs.batch"
  , "services"
  , "routes.serving.knative.dev"
  , "configurations.serving.knative.dev"
  , "revisions.serving.knative.dev"
  , "deployments.apps"
  , "pods"
  ]

modelToken :: Value -> Text
modelToken value = case textField "kind" value of
  "Service" | field "apiVersion" value == String "serving.knative.dev/v1" -> "services.serving.knative.dev"
  "Service" -> "services"
  "StatefulSet" -> "statefulsets.apps"
  "PersistentVolumeClaim" -> "persistentvolumeclaims"
  "Job" -> "jobs.batch"
  "Route" -> "routes.serving.knative.dev"
  "Configuration" -> "configurations.serving.knative.dev"
  "Revision" -> "revisions.serving.knative.dev"
  "Deployment" -> "deployments.apps"
  "Pod" -> "pods"
  "ReplicaSet" -> "replicasets.apps"
  "Endpoints" -> "endpoints"
  "EndpointSlice" -> "endpointslices.discovery.k8s.io"
  "Image" -> "images.caching.internal.knative.dev"
  "Ingress" -> "ingresses.networking.internal.knative.dev"
  "PodAutoscaler" -> "podautoscalers.autoscaling.internal.knative.dev"
  "Metric" -> "metrics.autoscaling.internal.knative.dev"
  "ServerlessService" -> "serverlessservices.networking.internal.knative.dev"
  "PodMetrics" -> "pods.metrics.k8s.io"
  "ConfigMap" -> "configmaps"
  other -> error ("unmodeled kind " <> T.unpack other)
