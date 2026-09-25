-- | Compile one manual task run from an accepted CronJob template. The run ID
-- fixes both the Job's native name and its independent reviewed scope, so a
-- saved review can be retried without submitting a second Job.
module Nagare.Inventory.TaskRun
  ( compileTaskRunScope
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (ServiceName, mkServiceName, serviceNameText)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

compileTaskRunScope ::
  Maybe T.Text ->
  ManagedResource ->
  ByteString ->
  T.Text ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileTaskRunScope appName cronJob cronBytes runId source = do
  let invalid message =
        inventoryError "invalid-task-run" message
          & #sources
          .~ [source]
          & (:| [])
  (cluster, ns, cronName) <- case cronJob ^. #address of
    Kubernetes cluster "batch" kind (Just ns) name
      | nameText kind == "cronjob" && cronJob ^. #executor == KubernetesExecutor ->
          Right (cluster, nameText ns, nameText name)
    _ -> Left (invalid "task run needs an accepted namespaced CronJob")
  _ <- first invalid (mkServiceName runId)
  key <- first invalid (mkLogicalKey runId)
  jobName <- first invalid (manualJobName cronName runId)
  owner <- first invalid (mkScopeId Standalone ("task-run-" <> ns <> "-" <> runId <> "-" <> cronName))
  role <- first invalid (mkName "job")
  value <-
    first
      (invalid . T.pack . show)
      (Yaml.decodeEither' cronBytes :: Either Yaml.ParseException Value)
  cronCanonical <- first invalid (canonicalValue value)
  unless
    (cronJob ^. #spec == NativeObject (contentDigest cronCanonical))
    (Left (invalid "accepted task template bytes differ from its declaration"))
  (labels, jobSpec) <- case value of
    Object top -> do
      unless
        ( KM.lookup "apiVersion" top == Just (String "batch/v1")
            && KM.lookup "kind" top == Just (String "CronJob")
        )
        (Left (invalid "accepted task template is not a batch/v1 CronJob"))
      metadata <- objectField invalid "metadata" top
      unless
        ( KM.lookup "name" metadata == Just (String cronName)
            && KM.lookup "namespace" metadata == Just (String ns)
        )
        (Left (invalid "accepted task template differs from its native address"))
      labels <- case KM.lookup "labels" metadata of
        Just (Object values)
          | KM.lookup "nagare.dev/app" values == (String <$> appName) ->
              Right (Object values)
        _ -> Left (invalid "accepted task template app label differs from requested APP")
      spec <- objectField invalid "spec" top
      jobTemplate <- objectField invalid "jobTemplate" spec
      unless
        (KM.lookup "metadata" jobTemplate == Nothing)
        (Left (invalid "task Job template metadata needs an explicit binding"))
      jobSpec <- case KM.lookup "spec" jobTemplate of
        Just jobSpec@(Object _) -> Right jobSpec
        _ -> Left (invalid "accepted task template has no Job spec")
      pure (labels, jobSpec)
    _ -> Left (invalid "accepted task template is not a YAML object")
  let resourceId = mintResourceId owner key role
      job =
        object
          [ "apiVersion" .= ("batch/v1" :: T.Text)
          , "kind" .= ("Job" :: T.Text)
          , "metadata"
              .= object
                ["name" .= serviceNameText jobName, "namespace" .= ns, "labels" .= labels]
          , "spec" .= jobSpec
          ]
  canonical <- first invalid (canonicalValue job)
  (bound, native) <-
    first
      (:| [])
      ( bindKubernetesObject
          KubernetesInput
            { resourceId = resourceId
            , ownerScope = owner
            , clusterId = cluster
            , inputObject = job
            , objectDigest = contentDigest canonical
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = source
            }
      )
  expected <-
    first
      invalid
      ( kubernetesAddress
          cluster
          "batch/v1"
          "Job"
          (Just ns)
          (serviceNameText jobName)
      )
  unless
    (bound ^. #address == expected)
    (Left (invalid "task run Job has a different native address"))
  let member = bound {dependencies = [OrderedAfter (cronJob ^. #identity)]}
  scope <-
    mkScopeDeclaration
      owner
      [ResourceBundle [Managed member] [] [] [] [] []]
  pure (scope, Map.singleton resourceId (member, native))

objectField ::
  (T.Text -> NonEmpty InventoryError) ->
  T.Text ->
  KM.KeyMap Value ->
  Either (NonEmpty InventoryError) (KM.KeyMap Value)
objectField invalid key fields = case KM.lookup (K.fromText key) fields of
  Just (Object value) -> Right value
  _ -> Left (invalid ("accepted task template has no object " <> key))

-- Keep the run suffix when it fits. Long, otherwise valid CronJob names use a
-- digest of the full task/run pair so truncation cannot discard the run ID.
manualJobName :: T.Text -> T.Text -> Either T.Text ServiceName
manualJobName cronName runId =
  mkServiceName $
    if T.length full <= 63
      then full
      else
        T.dropWhileEnd (== '-') (T.take 42 cronName)
          <> "-"
          <> T.take 20 (digestText (contentDigest (TE.encodeUtf8 full)))
  where
    full = cronName <> "-manual-" <> runId
