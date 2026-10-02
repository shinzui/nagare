-- | Bindings responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Bindings
  ( acceptedAccessBinding
  , acceptedApplicationImage
  , acceptedBrokerBindings
  , acceptedDatabaseBindings
  , acceptedImageBuildSecrets
  , acceptedImageResourceForDestination
  , acceptedSecretBindings
  , brokerEvidenceIds
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (Object, String))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve (backendConfigMapNamespace)
import Nagare.Broker.Connection
  ( BrokerConn (..)
  , brokerConnectionEnv
  , mergeBrokerConnectionEnvs
  )
import Nagare.Dsl.Broker
  ( BrokerBinding (..)
  , BrokerName
  , BrokerProvider (Redpanda)
  , TopicName
  , brokerNameText
  , topicNameText
  )
import Nagare.Dsl.Database (dbSecretName, engineToken)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( DatabaseName
  , ScopedEnvVar
  , SecretName
  , databaseNameText
  , mkSecretName
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( databaseCredentialKind
  )
import Nagare.Inventory.Application.Types
  ( AccessBinding (..)
  , DatabaseBinding (..)
  )
import Nagare.Inventory.Environment (acceptedBuildChannelMember)
import Nagare.Resource.Inventory
  ( ContributionGrant (BackendMapGrant, ShomeiSettingsGrant)
  , Declaration (Managed)
  , DesiredSpec (ArtifactPublication, LogicalBrokerTopic)
  , Executor (ArtifactExecutor, BrokerExecutor)
  , ManagedResource
  , ResourceBundle (declarations)
  , ScopeSnapshot
  , scopeBundles
  , scopeId
  , scopeOverrides
  , snapshotScopes
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( ProviderAddress (Artifact, BrokerTopic, Kubernetes)
  , ResourceId
  , ScopeKind (Platform, Publication, Standalone)
  , SourceLocation (path)
  , kubernetesAddress
  , mkContentDigest
  , mkName
  , mkResourceId
  , mkScopeId
  , nameText
  , resourceIdText
  , scopeKind
  , scopeName
  )

-- | A reviewed rollout may depend only on an already accepted OCI publication
-- whose destination is the exact tagged image embedded in its native manifests.
acceptedApplicationImage :: ScopeSnapshot -> ResourceId -> T.Text -> Either T.Text ()
acceptedApplicationImage snapshot imageId taggedImage =
  case [ resource
       | (_, scope) <- Map.elems (snapshotScopes snapshot)
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , resource ^. #identity == imageId
       ] of
    [resource] -> case (resource ^. #executor, resource ^. #address, resource ^. #spec) of
      (ArtifactExecutor, Artifact _ _, ArtifactPublication kind destination _ _)
        | nameText kind == "oci-image" && destination == taggedImage -> Right ()
      _ -> Left "accepted image resource is not the requested OCI publication"
    _ -> Left "image resource is absent or ambiguous in accepted inventory"

-- | The accepted publication explicitly names every Build channel it claims
-- as an input. Its scope pins the revision accepted when the archive was
-- published; a later channel rotation cannot silently change that claim.
-- The current channel is used only to verify its typed name and address.
acceptedImageBuildSecrets ::
  ScopeSnapshot ->
  ResourceId ->
  ResourceId ->
  T.Text ->
  T.Text ->
  Either T.Text (Set.Set SecretName)
acceptedImageBuildSecrets snapshot imageId cluster appName namespaceName = do
  (imageScope, image) <- case [ (scope, resource)
                              | (_, scope) <- Map.elems (snapshotScopes snapshot)
                              , bundle <- scopeBundles scope
                              , Managed resource <- declarations bundle
                              , resource ^. #identity == imageId
                              ] of
    [selected] -> Right selected
    _ -> Left "image publication is absent or ambiguous in accepted inventory"
  unless
    ( scopeKind (scopeId imageScope) == Publication
        && image ^. #owner == scopeId imageScope
        && case image ^. #spec of
          ArtifactPublication kind _ _ _ -> nameText kind == "oci-image"
          _ -> False
    )
    (Left "Build inputs require an accepted OCI publication")
  let inputIds = [resource | OrderedAfter resource <- image ^. #dependencies]
      expectedKeys =
        Set.fromList
          ["build-input." <> resourceIdText resource | resource <- inputIds]
      pinnedKeys =
        Set.fromList
          [ key
          | key <- Map.keys (scopeOverrides imageScope)
          , "build-input." `T.isPrefixOf` key
          ]
  unless
    ( length inputIds == Set.size (Set.fromList inputIds)
        && pinnedKeys == expectedKeys
    )
    (Left "image publication Build input pins differ from its dependencies")
  channels <- traverse (acceptedBuildChannelMember snapshot) inputIds
  names <-
    traverse
      ( \(resourceId, (ownerApp, _, channel)) -> do
          unless
            (ownerApp == appName)
            (Left "image Build channel belongs to another application")
          revisionText <-
            maybe
              (Left "image Build input lacks an accepted revision pin")
              Right
              ( Map.lookup
                  ("build-input." <> resourceIdText resourceId)
                  (scopeOverrides imageScope)
              )
          _ <- mkContentDigest revisionText
          case channel ^. #address of
            Kubernetes boundCluster "" kind (Just ns) name
              | boundCluster == cluster && nameText ns == namespaceName
              , nameText kind == "secret" ->
                  Just <$> mkSecretName (nameText name)
            Kubernetes boundCluster "" kind (Just ns) _
              | boundCluster == cluster && nameText ns == namespaceName
              , nameText kind == "configmap" ->
                  Right Nothing
            _ -> Left "image Build input has a different cluster, namespace, or kind"
      )
      (zip inputIds channels)
  let selectedSecrets = Set.fromList [name | Just name <- names]
  unless
    ( Set.null selectedSecrets
        || Map.lookup "build-method" (scopeOverrides imageScope)
          == Just "dockerfile-buildkit-v1"
    )
    (Left "image Build Secret inputs lack a reviewed local BuildKit build")
  pure selectedSecrets

-- | Select the one accepted OCI publication for an exact tagged destination.
-- The caller still passes its ID to the reviewed command, which rechecks the
-- accepted declaration against the loaded site before planning any mutation.
acceptedImageResourceForDestination :: ScopeSnapshot -> T.Text -> Either T.Text ResourceId
acceptedImageResourceForDestination snapshot taggedImage =
  case [ resource ^. #identity
       | (_, scope) <- Map.elems (snapshotScopes snapshot)
       , bundle <- scopeBundles scope
       , Managed resource <- declarations bundle
       , resource ^. #executor == ArtifactExecutor
       , case (resource ^. #address, resource ^. #spec) of
           (Artifact _ _, ArtifactPublication kind destination _ _) ->
             nameText kind == "oci-image" && destination == taggedImage
           _ -> False
       ] of
    [imageId] -> Right imageId
    [] -> Left "no accepted OCI publication matches the webhook image tag"
    _ -> Left "multiple accepted OCI publications match the webhook image tag"

-- | Resolve operator-supplied Secret identities only from accepted history.
-- Consumers then check that the binding set and exact native address match
-- their declared TLS or runtime environment references.
acceptedSecretBindings ::
  ScopeSnapshot -> [ResourceId] -> Either T.Text (Map SecretName Declaration)
acceptedSecretBindings snapshot ids = do
  pairs <- traverse resolve ids
  let bindings = Map.fromList pairs
  unless
    (length pairs == Map.size bindings)
    (Left "accepted Secret bindings repeat a native name")
  pure bindings
  where
    resources =
      [ resource
      | (_, scope) <- Map.elems (snapshotScopes snapshot)
      , bundle <- scopeBundles scope
      , Managed resource <- declarations bundle
      ]
    resolve resourceId = case filter ((== resourceId) . (^. #identity)) resources of
      [resource] -> case resource ^. #address of
        Kubernetes _ "" kind (Just _) nativeName | nameText kind == "secret" -> do
          secretName <- mkSecretName (nameText nativeName)
          pure (secretName, Managed resource)
        _ -> Left "accepted resource is not a namespaced Kubernetes Secret"
      _ -> Left "Secret resource is absent or ambiguous in accepted inventory"

-- | Resolve Service and topic references from one complete accepted
-- standalone broker scope. A live topic with the same name is not authority.
acceptedBrokerBindings ::
  ScopeSnapshot ->
  ResourceId ->
  T.Text ->
  [BrokerBinding] ->
  Either
    T.Text
    ( Map BrokerName Declaration
    , Map BrokerName (Map TopicName Declaration)
    , Map Dsl.EnvName ScopedEnvVar
    )
acceptedBrokerBindings snapshot cluster namespaceName bindings = do
  pairs <- traverse resolve bindings
  let services = Map.fromList (map fst pairs)
  unless
    (length pairs == Map.size services)
    (Left "application broker bindings repeat a broker")
  env <- mergeBrokerConnectionEnvs [fields | (_, fields) <- pairs]
  let topicBindings =
        Map.fromList
          [(name, topics) | ((name, (_, topics)), _) <- pairs]
  pure (Map.map fst services, topicBindings, env)
  where
    resolve binding = do
      let name = brokerNameText (binding ^. #name)
          expected (kind :: T.Text) =
            kubernetesAddress
              cluster
              (if kind == "statefulset" then "apps/v1" else "v1")
              (if kind == "statefulset" then "StatefulSet" else "Service")
              (Just namespaceName)
              name
      serviceAddress <- expected "service"
      statefulAddress <- expected "statefulset"
      let candidates =
            [ (service, statefulId, scope)
            | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
            , scopeKind owner == Standalone
            , bundle <- scopeBundles scope
            , service@(Managed serviceResource) <- declarations bundle
            , serviceResource ^. #address == serviceAddress
            , Just brokerKey <- [T.stripSuffix "/service" (resourceIdText (serviceResource ^. #identity))]
            , T.isSuffixOf "/broker/service" (path (serviceResource ^. #source))
            , Managed stateful <- concatMap declarations (scopeBundles scope)
            , stateful ^. #address == statefulAddress
            , resourceIdText (stateful ^. #identity) == brokerKey <> "/statefulset"
            , T.isSuffixOf "/broker/statefulset" (path (stateful ^. #source))
            , let statefulId = stateful ^. #identity
            ]
      (service, statefulId, acceptedScope) <- case candidates of
        [found] -> Right found
        _ -> Left "broker has no unique accepted Service and StatefulSet in one standalone scope"
      topicPairs <-
        traverse
          ( \topic -> do
              topicName <- mkName (topicNameText topic)
              let matches =
                    [ declaration
                    | bundle <- scopeBundles acceptedScope
                    , declaration@(Managed resource) <- declarations bundle
                    , resource ^. #address == BrokerTopic statefulId topicName
                    , resource ^. #executor == BrokerExecutor
                    , case resource ^. #spec of LogicalBrokerTopic {} -> True; _ -> False
                    ]
              case matches of
                [declaration] -> Right (topic, declaration)
                _ -> Left "broker topic is absent or ambiguous in accepted logical inventory"
          )
          (binding ^. #topics)
      let topics = Map.fromList topicPairs
      unless
        (length topicPairs == Map.size topics)
        (Left "broker binding repeats a topic")
      env <-
        brokerConnectionEnv
          binding
          BrokerConn
            { provider = Redpanda
            , bootstrapServers = name <> "." <> namespaceName <> ".svc.cluster.local:9092"
            , topics = binding ^. #topics
            }
      pure ((binding ^. #name, (service, topics)), env)

-- | The shared backend owner and enforcer must already be accepted together.
-- A matching live Service or caller-supplied name does not grant access to the
-- shared routing ConfigMap or to the auth namespace.
acceptedAccessBinding :: ScopeSnapshot -> ResourceId -> Either T.Text AccessBinding
acceptedAccessBinding snapshot cluster = do
  authOwner <- mkScopeId Platform "auth"
  authScope <-
    maybe
      (Left "auth owner has no accepted inventory scope")
      (Right . snd)
      (Map.lookup authOwner (snapshotScopes snapshot))
  let grants =
        [ ()
        | bundle <- scopeBundles authScope
        , BackendMapGrant grantedCluster <- bundle ^. #grants
        , grantedCluster == cluster
        ]
  unless
    (length grants == 1)
    (Left "auth owner has no unique accepted backend-map grant for this cluster")
  baseDomain <- case [ base
                     | bundle <- scopeBundles authScope
                     , ShomeiSettingsGrant grantedCluster base <- bundle ^. #grants
                     , grantedCluster == cluster
                     ] of
    [base] -> Right base
    _ -> Left "auth owner has no unique accepted Shomei settings grant for this cluster"
  expected <-
    kubernetesAddress
      cluster
      "serving.knative.dev/v1"
      "Service"
      (Just backendConfigMapNamespace)
      "nagare-access"
  let enforcers =
        [ declaration
        | bundle <- scopeBundles authScope
        , declaration@(Managed resource) <- declarations bundle
        , resource ^. #address == expected
        ]
  case enforcers of
    [enforcer] -> Right (AccessBinding authOwner enforcer baseDomain)
    _ -> Left "auth owner has no unique accepted enforcer Service"

brokerEvidenceIds ::
  ResourceId ->
  T.Text ->
  BrokerBinding ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Either T.Text [ResourceId]
brokerEvidenceIds cluster namespaceName binding services allTopics = do
  service <-
    maybe
      (Left "broker has no typed Service dependency")
      Right
      (Map.lookup (binding ^. #name) services)
  expected <-
    kubernetesAddress
      cluster
      "v1"
      "Service"
      (Just namespaceName)
      (brokerNameText (binding ^. #name))
  managed <- case service of
    Managed resource
      | resource ^. #address == expected
          && scopeKind (resource ^. #owner) == Standalone ->
          Right resource
    _ -> Left "broker dependency is not an accepted standalone Service at the declared address"
  brokerKey <-
    maybe
      (Left "broker Service identity has no stable role")
      Right
      (T.stripSuffix "/service" (resourceIdText (managed ^. #identity)))
  stateful <- mkResourceId (brokerKey <> "/statefulset")
  topics <- case Map.lookup (binding ^. #name) allTopics of
    Just evidence -> Right evidence
    Nothing | null (binding ^. #topics) -> Right Map.empty
    Nothing -> Left "broker has no typed topic evidence"
  selected <-
    traverse
      ( \topic -> do
          declaration <-
            maybe
              (Left "broker topic lacks accepted inventory evidence")
              Right
              (Map.lookup topic topics)
          nativeName <- mkName (topicNameText topic)
          case declaration of
            Managed resource
              | resource ^. #address == BrokerTopic stateful nativeName
              , resource ^. #owner == managed ^. #owner
              , resource ^. #executor == BrokerExecutor
              , LogicalBrokerTopic {} <- resource ^. #spec ->
                  Right (resource ^. #identity)
            _ -> Left "broker topic evidence differs from the accepted broker address"
      )
      (binding ^. #topics)
  pure (managed ^. #identity : selected)

acceptedDatabaseBindings ::
  ScopeSnapshot ->
  Map ResourceId (ManagedResource, ByteString) ->
  ResourceId ->
  T.Text ->
  [DatabaseName] ->
  Either T.Text (Map DatabaseName DatabaseBinding)
acceptedDatabaseBindings snapshot native cluster namespaceName names = do
  pairs <- traverse resolve names
  let bindings = Map.fromList pairs
  unless
    (length pairs == Map.size bindings)
    (Left "database bindings repeat a database")
  pure bindings
  where
    resolve name = do
      let dbName = databaseNameText name
      serviceAddress <- kubernetesAddress cluster "v1" "Service" (Just namespaceName) dbName
      statefulAddress <- kubernetesAddress cluster "apps/v1" "StatefulSet" (Just namespaceName) dbName
      credentialAddress <-
        kubernetesAddress
          cluster
          "v1"
          "Secret"
          (Just namespaceName)
          (dbSecretName dbName)
      let candidates =
            [ (service, stateful, credential)
            | (owner, (_, scope)) <- Map.toList (snapshotScopes snapshot)
            , scopeKind owner == Standalone
            , "database-" `T.isPrefixOf` nameText (scopeName owner)
            , let resources =
                    concatMap
                      (\bundle -> [resource | Managed resource <- declarations bundle])
                      (scopeBundles scope)
            , service <- resources
            , service ^. #address == serviceAddress
            , Just prefix <- [T.stripSuffix "/service" (resourceIdText (service ^. #identity))]
            , stateful <- resources
            , stateful ^. #address == statefulAddress
            , resourceIdText (stateful ^. #identity) == prefix <> "/statefulset"
            , credential <- resources
            , credential ^. #address == credentialAddress
            , resourceIdText (credential ^. #identity) == prefix <> "/credential"
            ]
      (service, stateful, credential) <- case candidates of
        [found] -> Right found
        _ -> Left "database has no unique accepted Service, StatefulSet, and credential in one standalone scope"
      (_, bytes) <- case Map.lookup (credential ^. #identity) native of
        Just pair@(member, _) | member == credential -> Right pair
        _ -> Left "accepted database credential has no matching private native template"
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      engine <-
        databaseCredentialKind value >>= \case
          Just (templateName, templateNamespace, parsed)
            | templateName == dbName && templateNamespace == namespaceName -> Right parsed
          _ -> Left "accepted database credential template differs from the requested database"
      forM_ [service, stateful] (checkNativeLabels dbName engine)
      pure (name, DatabaseBinding service stateful credential engine)
    checkNativeLabels dbName engine member = do
      (_, bytes) <- case Map.lookup (member ^. #identity) native of
        Just pair@(accepted, _) | accepted == member -> Right pair
        _ -> Left "accepted database member has no matching private native object"
      value <- first (T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      case value of
        Object root -> case KM.lookup "metadata" root of
          Just (Object metadata) -> case KM.lookup "labels" metadata of
            Just (Object labels)
              | KM.lookup "nagare.dev/managed-by" labels == Just (String "nagarectl")
                  && KM.lookup "nagare.dev/database" labels == Just (String dbName)
                  && KM.lookup "nagare.dev/engine" labels == Just (String (engineToken engine)) ->
                  Right ()
            _ -> Left "accepted database native labels differ from its credential engine"
          _ -> Left "accepted database native member has no metadata"
        _ -> Left "accepted database native member is not an object"
