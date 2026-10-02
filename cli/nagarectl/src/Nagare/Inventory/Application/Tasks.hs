-- | Tasks responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Tasks
  ( compileApplicationHooks
  , compileApplicationTasks
  , compileTaskMembers
  )
where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.App.Deploy (RolloutEnv, renderTaskObjects)
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Task (Task (..), mkTask, taskResourceName)
import Nagare.Dsl.Types
  ( SecretName
  , namespaceText
  , serviceNameText
  )
import Nagare.Inventory.Application.Environment
  ( reviewedTaskImages
  , runtimeSecretNames
  , secretDependency
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.TaskRun (jobFromCronJob)
import Nagare.Resource.Application
  ( applicationScopeId
  , taskResourceId
  )
import Nagare.Resource.Inventory
  ( Declaration (Managed)
  , DeclaredOperation (DeclaredOperation)
  , ManagedResource (dependencies)
  , OperationInput (ContentInput)
  , OperationKind (PreDeployHook)
  , ResourceBundle (ResourceBundle)
  , ScopeDeclaration
  , mkScopeDeclaration
  , withScopeConfigDigest
  , withScopeOverrides
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (..)
  , LifecyclePolicy (..)
  , RecoveryClass (VerifyBeforeRetry)
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ResourceId
  , ScopeId
  , ScopeKind (Standalone)
  , SourceLocation (path)
  , digestText
  , inventoryError
  , kubernetesAddress
  , mintResourceId
  , mkLogicalKey
  , mkName
  , mkScopeId
  , resourceIdText
  )
import Nagare.Resource.Wire (canonicalValue)

-- | Bind scheduled CronJobs from the same resolved image/env render shown by
-- preview. Executing a hook remains a separate operation with effect proof.
compileApplicationTasks ::
  Application ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationTasks app rollout cluster namespaceId imageId envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  compileTaskMembers
    owner
    ( app ^. #tasks
        <> maybe [] (^. #tasks) (app ^. #service)
    )
    rollout
    cluster
    namespaceId
    imageId
    envSecrets
    source
  where
    invalid message =
      inventoryError "invalid-application-task" message
        & #sources
        .~ [source]
        & (:| [])

-- | Bind each pre-deploy hook to a stable, independent per-tag scope. A new
-- tag leaves prior Jobs and completion proofs in accepted history.
compileApplicationHooks ::
  Application ->
  ScopeId ->
  RolloutEnv ->
  ResourceId ->
  Map ResourceId (ManagedResource, ByteString) ->
  Map T.Text [ResourceId] ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString), [ResourceId])
compileApplicationHooks app appOwner rollout cluster taskNative effects source =
  go Nothing (app ^. #tasks)
  where
    invalid message =
      inventoryError "invalid-application-hook" message
        & #scopes
        .~ [appOwner]
        & #sources
        .~ [source]
        & (:| [])
    tagSuffix =
      T.take
        12
        ( digestText
            ( contentDigest
                (TE.encodeUtf8 (rollout ^. #effectiveTag))
            )
        )
    go _ [] = Right ([], Map.empty, [])
    go previous (task : rest) = do
      cronRole <- first invalid (mkName "cronjob")
      cronId <- first invalid (taskResourceId appOwner cronRole task)
      (_, cronBytes) <-
        maybe
          (Left (invalid "pre-deploy hook has no reviewed CronJob"))
          Right
          (Map.lookup cronId taskNative)
      cronValue <-
        first
          (invalid . T.pack . show)
          (Yaml.decodeEither' cronBytes :: Either Yaml.ParseException Value)
      let taskName = serviceNameText (task ^. #name)
          cronName = taskResourceName taskName
          jobName =
            T.dropWhileEnd (== '-') (T.take 45 cronName)
              <> "-hook-"
              <> tagSuffix
          scopeSuffix =
            T.take
              40
              ( digestText
                  ( contentDigest
                      (TE.encodeUtf8 (resourceIdText cronId <> ":" <> rollout ^. #effectiveTag))
                  )
              )
      owner <- first invalid (mkScopeId Standalone ("app-hook-" <> scopeSuffix))
      key <- first invalid (mkLogicalKey "run")
      jobValue <-
        first
          invalid
          ( jobFromCronJob
              (Just (rollout ^. #appName))
              cronName
              (rollout ^. #namespace)
              jobName
              cronValue
          )
      canonical <- first invalid (canonicalValue jobValue)
      jobRole <- first invalid (mkName "job")
      proofRole <- first invalid (mkName "completion")
      let jobId = mintResourceId owner key jobRole
          proofId = mintResourceId owner key proofRole
      let hookSource = source {path = path source <> "/hook/" <> taskName}
      (bound, native) <-
        first
          (:| [])
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = jobId
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = jobValue
                , objectDigest = contentDigest canonical
                , lifecyclePolicy = DeleteWhenUnreferenced
                , inputDataPolicy = Stateless
                , inputSensitivity = Private
                , sourceLocation = hookSource
                }
          )
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "batch/v1"
              "Job"
              (Just (rollout ^. #namespace))
              jobName
          )
      unless
        (bound ^. #address == expected)
        (Left (invalid "pre-deploy Job has an unexpected native address"))
      affected <-
        maybe
          (Left (invalid "pre-deploy hook lacks effect declaration"))
          Right
          (Map.lookup taskName effects)
      unless
        ( length affected == Set.size (Set.fromList affected)
            && jobId `notElem` affected
        )
        (Left (invalid "pre-deploy hook repeats an affected resource"))
      let member =
            bound
              { dependencies =
                  map
                    OrderedAfter
                    (cronId : affected <> maybe [] pure previous)
              }
          proof =
            DeclaredOperation
              proofId
              (jobId :| affected)
              [ContentInput (contentDigest native)]
              VerifyBeforeRetry
              PreDeployHook
          bundle = ResourceBundle [Managed member] [] [] [] [proof] []
      scope <-
        withScopeOverrides
          ( Map.fromList
              [ ("tag", rollout ^. #effectiveTag)
              , ("task", taskName)
              , ("affects", T.intercalate "," (map resourceIdText affected))
              ]
          )
          . withScopeConfigDigest (contentDigest canonical)
          <$> mkScopeDeclaration owner [bundle]
      (laterScopes, laterNative, laterProofs) <- go (Just proofId) rest
      unless
        (Map.notMember jobId laterNative)
        (Left (invalid "pre-deploy hooks share a Job identity"))
      pure
        ( scope : laterScopes
        , Map.insert jobId (member, native) laterNative
        , proofId : laterProofs
        )

compileTaskMembers ::
  ScopeId ->
  [Task] ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileTaskMembers owner tasks rollout cluster namespaceId imageId envSecrets source = do
  unless
    (all ((== rollout ^. #namespace) . namespaceText . (^. #namespace)) tasks)
    (Left (invalid "scheduled task namespace differs from rollout"))
  unless
    (all (maybe True ((== rollout ^. #appName) . serviceNameText) . (^. #app)) tasks)
    (Left (invalid "scheduled task references a different application"))
  first
    invalid
    ( reviewedTaskImages
        tasks
        (rollout ^. #taggedAppImage)
        (rollout ^. #effectiveTag)
    )
  members <- traverse compileTask tasks
  let bundle = ResourceBundle (map (Managed . fst) members) [] [] [] [] []
      native = Map.fromList [(member ^. #identity, pair) | pair@(member, _) <- members]
  _ <- mkScopeDeclaration owner [bundle]
  unless
    (Map.size native == length members)
    (Left (invalid "scheduled tasks share an identity"))
  pure (bundle, native)
  where
    invalid message =
      inventoryError "invalid-scheduled-task" message
        & #sources
        .~ [source]
        & (:| [])
    compileTask task = do
      _ <- first invalid (mkTask task)
      secretNames <-
        first
          invalid
          ( runtimeSecretNames
              (Map.elems (rollout ^. #appEnv) <> Map.elems (task ^. #env))
          )
      secretIds <-
        traverse
          ( first invalid
              . secretDependency
                cluster
                (rollout ^. #namespace)
                envSecrets
          )
          secretNames
      role <- first invalid (mkName "cronjob")
      resource <- first invalid (taskResourceId owner role task)
      rendered <- first invalid (renderTaskObjects rollout task)
      bytes <- case rendered of
        [("hook", manifest)] -> Right manifest
        _ -> Left (invalid "task renderer produced unexpected members")
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      let taskSource = source {path = path source <> "/task/" <> serviceNameText (task ^. #name)}
      (declaration, native) <-
        first
          (:| [])
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resource
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest canonical
                , lifecyclePolicy = DeleteWhenUnreferenced
                , inputDataPolicy = Stateless
                , inputSensitivity = Private
                , sourceLocation = taskSource
                }
          )
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "batch/v1"
              "CronJob"
              (Just (rollout ^. #namespace))
              (taskResourceName (serviceNameText (task ^. #name)))
          )
      unless
        (declaration ^. #address == expected)
        (Left (invalid "task render has an unexpected CronJob address"))
      pure (declaration {dependencies = map OrderedAfter ([namespaceId, imageId] <> secretIds)}, native)
