-- | Service responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Service
  ( compileApplicationService
  , compileApplicationServiceWithAccess
  , compileStandaloneService
  , compileStandaloneServiceWithBrokers
  , compileStandaloneServiceWithDependencies
  , compileStandaloneServiceWithRelease
  , compileStandaloneServiceWithReleaseAndBuild
  )
where

import Data.Aeson (Value (Object, String))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve
  ( RouteTarget (..)
  , backendConfigMapNamespace
  , isUnderBaseDomain
  , mkBaseDomain
  , mkPublicHost
  , renderAccessDomainMapping
  , upstreamFor
  )
import Nagare.App.Deploy (RolloutEnv, renderServiceObjects)
import Nagare.Dsl.Access (AccessRole (..))
import Nagare.Dsl.Application (Application (..), mkApplication)
import Nagare.Dsl.Broker (BrokerName, TopicName)
import Nagare.Dsl.Config (encodeDeployment)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Types
  ( DatabaseName
  , Deployment
  , DomainSpec (DomainSpec)
  , DomainTls (AutomaticTls, SuppliedTlsSecret)
  , SecretName
  , VolumeName
  , domainText
  , mkDomain
  , namespaceText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Env.Generated (mergeGenerated)
import Nagare.Inventory.Application.Environment
  ( databaseDependencies
  , runtimeSecretNames
  , runtimeSecretNamesWithBuild
  , secretDependency
  , standaloneBrokerEnvironment
  , standaloneDatabaseEnvironment
  , stripBuildSecretEnv
  )
import Nagare.Inventory.Application.Policy (configDigestOf)
import Nagare.Inventory.Application.Release
  ( compileApplicationRelease
  , standaloneReleaseApplication
  )
import Nagare.Inventory.Application.Tasks (compileTaskMembers)
import Nagare.Inventory.Application.Types
  ( AccessBinding (..)
  , DatabaseBinding (..)
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application
  ( applicationScopeId
  , deploymentResourceId
  , domainMappingResourceId
  , volumeResourceId
  )
import Nagare.Resource.Inventory
  ( BackendRole (PortalBackend, ProtectedBackend)
  , Contribution (RegisterBackend)
  , Declaration (Managed)
  , ManagedResource (aliases, dependencies)
  , ResourceBundle (ResourceBundle, declarations)
  , ScopeDeclaration
  , backendMapResourceId
  , claimsOf
  , mkScopeDeclaration
  , scopeBundles
  , shomeiSettingsResourceId
  , withScopeConfigDigest
  )
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced, Retain)
  , RecoveryIntent
  , Sensitivity (Private)
  )
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress (Hostname, Kubernetes)
  , ResourceId
  , ScopeId
  , ScopeKind (Standalone)
  , SourceLocation (path)
  , inventoryError
  , kubernetesAddress
  , mkLogicalKey
  , mkName
  , nameText
  , scopeIdText
  , scopeKind
  )
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Release (StaticRelease, StaticReleaseLog)

-- | The service, its volume claims, and automatic-TLS domain mappings, all
-- bound to the same render used by preview. Supplied TLS needs an explicit
-- capability dependency and refuses until that witness is available.
compileApplicationService ::
  Application ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationService app rollout cluster namespaceId imageId recoveryByVolume tlsSecrets envSecrets source = do
  compileApplicationServiceWithAccess
    Nothing
    app
    rollout
    cluster
    namespaceId
    imageId
    recoveryByVolume
    tlsSecrets
    envSecrets
    source

compileApplicationServiceWithAccess ::
  Maybe AccessBinding ->
  Application ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileApplicationServiceWithAccess accessBinding app rollout cluster namespaceId imageId recoveryByVolume tlsSecrets envSecrets source = do
  _ <- first invalid (mkApplication app)
  owner <- first invalid (applicationScopeId app)
  original <- maybe (Left (invalid "application has no web service")) Right (app ^. #service)
  case (app ^. #access, original ^. #access) of
    (Just appPolicy, Just servicePolicy)
      | appPolicy /= servicePolicy ->
          Left (invalid "application and Service access policies disagree")
    _ -> pure ()
  let effectiveAccess = (app ^. #access) <|> (original ^. #access)
      service = original & #access .~ effectiveAccess
  unless
    (isJust effectiveAccess == isJust accessBinding)
    (Left (invalid "application access requires exactly its accepted auth binding"))
  databasePrerequisites <- databaseDependencies app owner (service ^. #databases) invalid
  compileServiceMembers
    owner
    service
    rollout
    cluster
    namespaceId
    imageId
    databasePrerequisites
    recoveryByVolume
    tlsSecrets
    envSecrets
    accessBinding
    source
  where
    invalid message =
      inventoryError "invalid-application-service" message
        & #sources
        .~ [source]
        & (:| [])

-- | A separately owned web Service uses the same exact native binding as an
-- application service. It carries no application database or shared policy
-- authority; callers must supply the accepted namespace and image identities.
compileStandaloneService ::
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneService owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets source =
  compileStandaloneServiceWithBrokers
    owner
    service
    rollout
    cluster
    namespaceId
    imageId
    recovery
    tlsSecrets
    envSecrets
    Map.empty
    source

compileStandaloneServiceWithBrokers ::
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithBrokers owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices =
  compileStandaloneServiceWithDependencies
    owner
    service
    rollout
    cluster
    namespaceId
    imageId
    recovery
    tlsSecrets
    envSecrets
    brokerServices
    Map.empty
    Map.empty
    Nothing

compileStandaloneServiceWithDependencies ::
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Map DatabaseName DatabaseBinding ->
  Maybe AccessBinding ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithDependencies owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding source = do
  unless
    (scopeKind owner == Standalone)
    (Left (invalid "standalone service requires a standalone scope"))
  unless
    ( rollout ^. #appName == serviceNameText (service ^. #name)
        && rollout ^. #namespace == namespaceText (service ^. #namespace)
        && Map.null (rollout ^. #appEnv)
    )
    (Left (invalid "standalone rollout identity, namespace, or environment differs from its service"))
  (databaseEnv, databaseIds, databaseSecrets) <-
    standaloneDatabaseEnvironment
      cluster
      (service ^. #namespace)
      (service ^. #databases)
      databaseBindings
      invalid
  (brokerEnv, brokerIds) <-
    standaloneBrokerEnvironment
      cluster
      (namespaceText (service ^. #namespace))
      (service ^. #brokers)
      brokerServices
      brokerTopics
      invalid
  let service' =
        service
          & #env
          %~ mergeGenerated (mergeGenerated brokerEnv databaseEnv)
          & #brokers
          .~ []
          & #databases
          .~ []
  requiredEnvSecrets <-
    first
      invalid
      ( runtimeSecretNames
          ( Map.elems (service' ^. #env)
              <> concatMap (Map.elems . (^. #env)) (service ^. #tasks)
          )
      )
  unless
    ( Map.keysSet envSecrets
        == Set.fromList requiredEnvSecrets
          `Set.difference` Map.keysSet databaseSecrets
    )
    (Left (invalid "standalone runtime Secret environment requires exactly its typed dependencies"))
  let allSecrets = Map.union databaseSecrets envSecrets
  (bundle, native) <-
    compileServiceMembers
      owner
      service'
      rollout
      cluster
      namespaceId
      imageId
      databaseIds
      recovery
      tlsSecrets
      allSecrets
      accessBinding
      source
  (taskBundle, taskNative) <-
    compileTaskMembers
      owner
      (service ^. #tasks)
      rollout
      cluster
      namespaceId
      imageId
      allSecrets
      source
  let addBrokerEdges resource = case resource ^. #address of
        Kubernetes _ "serving.knative.dev" kind _ _
          | nameText kind == "service" ->
              resource & #dependencies %~ (<> map OrderedAfter brokerIds)
        _ -> resource
      updatedBundle =
        bundle
          & #declarations
          %~ map
            ( \case
                Managed resource -> Managed (addBrokerEdges resource)
                declaration -> declaration
            )
      updatedNative = Map.map (\(resource, bytes) -> (addBrokerEdges resource, bytes)) native
      allNative = Map.union updatedNative taskNative
  unless
    (Map.size allNative == Map.size native + Map.size taskNative)
    (Left (invalid "standalone Service and tasks share a resource identity"))
  configDigest <- first invalid (configDigestOf (encodeDeployment service))
  scope <- withScopeConfigDigest configDigest <$> mkScopeDeclaration owner [updatedBundle, taskBundle]
  pure (scope, allNative)
  where
    invalid message =
      inventoryError "invalid-standalone-service" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])

-- | The public reviewed Service route also owns the legacy per-Service
-- release-history object. The lower-level member compiler remains available
-- for component tests and callers that compose a larger scope themselves.
compileStandaloneServiceWithRelease ::
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Map DatabaseName DatabaseBinding ->
  Maybe AccessBinding ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithRelease owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding prior release source = do
  (workloads, workloadNative) <-
    compileStandaloneServiceWithDependencies
      owner
      service
      rollout
      cluster
      namespaceId
      imageId
      recovery
      tlsSecrets
      envSecrets
      brokerServices
      brokerTopics
      databaseBindings
      accessBinding
      source
  (releaseBundle, releaseNative) <-
    compileApplicationRelease
      (standaloneReleaseApplication service)
      rollout
      owner
      cluster
      namespaceId
      imageId
      (scopeBundles workloads)
      prior
      release
      source
  let bundles = scopeBundles workloads <> [releaseBundle]
      claims =
        [ claim
        | bundle <- bundles
        , declaration <- declarations bundle
        , (_, claim) <- NE.toList (claimsOf declaration)
        ]
      native = Map.union workloadNative releaseNative
  unless
    (Map.size native == Map.size workloadNative + Map.size releaseNative)
    (Left (invalid "standalone Service release shares a resource identity"))
  unless
    (length claims == Set.size (Set.fromList claims))
    (Left (invalid "standalone Service release claims another native address"))
  configDigest <- first invalid (configDigestOf (encodeDeployment service))
  scope <- withScopeConfigDigest configDigest <$> mkScopeDeclaration owner bundles
  pure (scope, native)
  where
    invalid message =
      inventoryError "invalid-standalone-service-release" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])

compileStandaloneServiceWithReleaseAndBuild ::
  Set.Set SecretName ->
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  Map BrokerName Declaration ->
  Map BrokerName (Map TopicName Declaration) ->
  Map DatabaseName DatabaseBinding ->
  Maybe AccessBinding ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStandaloneServiceWithReleaseAndBuild buildSecrets owner service rollout cluster namespaceId imageId recovery tlsSecrets envSecrets brokerServices brokerTopics databaseBindings accessBinding prior release source = do
  _ <-
    first
      invalid
      ( runtimeSecretNamesWithBuild
          buildSecrets
          ( Map.elems (service ^. #env)
              <> concatMap (Map.elems . (^. #env)) (service ^. #tasks)
          )
      )
  let runtimeService =
        service
          & #env
          %~ stripBuildSecretEnv
          & #tasks
          %~ map (\task -> task & #env %~ stripBuildSecretEnv)
  (scope, native) <-
    compileStandaloneServiceWithRelease
      owner
      runtimeService
      rollout
      cluster
      namespaceId
      imageId
      recovery
      tlsSecrets
      envSecrets
      brokerServices
      brokerTopics
      databaseBindings
      accessBinding
      prior
      release
      source
  digest <- first invalid (configDigestOf (encodeDeployment service))
  pure (withScopeConfigDigest digest scope, native)
  where
    invalid message =
      inventoryError "invalid-standalone-service-release" message
        & #scopes
        .~ [owner]
        & #sources
        .~ [source]
        & (:| [])

compileServiceMembers ::
  ScopeId ->
  Deployment ->
  RolloutEnv ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [ResourceId] ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  Maybe AccessBinding ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ResourceBundle, Map ResourceId (ManagedResource, ByteString))
compileServiceMembers owner service rollout cluster namespaceId imageId databasePrerequisites recoveryByVolume tlsSecrets envSecrets accessBinding source = do
  unless
    (null (service ^. #brokers))
    (Left (invalid "service broker bindings require typed broker dependencies"))
  unless
    (service ^. #cdn == Nothing)
    (Left (invalid "service CDN requires a typed owner"))
  accessIds <- case (service ^. #access, accessBinding) of
    (Nothing, Nothing) -> Right []
    (Just policy, Just binding) -> do
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "serving.knative.dev/v1"
              "Service"
              (Just backendConfigMapNamespace)
              "nagare-access"
          )
      case accessEnforcer binding of
        Managed enforcer
          | accessOwner binding == enforcer ^. #owner
          , scopeIdText (accessOwner binding) == "platform:auth"
          , enforcer ^. #address == expected
          , nameText (accessBaseDomain binding) == rollout ^. #baseDomain ->
              Right
                ( [backendMapResourceId (accessOwner binding), enforcer ^. #identity]
                    <> [shomeiSettingsResourceId (accessOwner binding) | policy ^. #role == AuthPortal]
                )
        _ -> Left (invalid "access binding lacks the accepted auth enforcer")
    _ -> Left (invalid "access intent requires exactly its accepted auth binding")
  unless
    (null accessIds || all ((== AutomaticTls) . (^. #tls)) (service ^. #domains))
    (Left (invalid "central access routes require automatic TLS"))
  domains <- case (accessIds, service ^. #domains) of
    (_ : _, []) -> do
      host <-
        first
          invalid
          ( mkDomain
              ( serviceNameText (service ^. #name)
                  <> "."
                  <> namespaceText (service ^. #namespace)
                  <> "."
                  <> (rollout ^. #baseDomain)
              )
          )
      Right [DomainSpec host Nothing True AutomaticTls]
    (_, existing) -> Right existing
  let renderedService = service & #domains .~ domains
  case service ^. #access of
    Just policy | policy ^. #role == AuthPortal -> do
      unless
        (length domains == 1)
        (Left (invalid "auth portal requires exactly one public hostname"))
      base <- first invalid (mkBaseDomain (rollout ^. #baseDomain))
      host <- case domains of
        [domain] -> first invalid (mkPublicHost (domainText (domain ^. #domain)))
        _ -> Left (invalid "auth portal requires exactly one public hostname")
      unless
        (isUnderBaseDomain base host)
        (Left (invalid "auth portal host must be under the rollout base domain"))
    _ -> pure ()
  let requiredTls =
        Set.fromList
          [ secret
          | domain <- service ^. #domains
          , SuppliedTlsSecret secret <- [domain ^. #tls]
          ]
  unless
    (Map.keysSet tlsSecrets == requiredTls)
    (Left (invalid "supplied TLS domains require exactly their typed Secret dependencies"))
  secretNames <-
    first
      invalid
      ( runtimeSecretNames
          (Map.elems (rollout ^. #appEnv) <> Map.elems (service ^. #env))
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
  resource <- first invalid (deploymentResourceId owner (known "service") service)
  rendered <- first invalid (renderServiceObjects rollout renderedService)
  let volumes = service ^. #volumes
      (volumeRendered, serviceRendered) = splitAt (length volumes) rendered
  renderedServiceBytes <- case serviceRendered of
    ("service", manifest) : _ -> Right manifest
    _ -> Left (invalid "service renderer produced unexpected members")
  serviceBytes <-
    if null accessIds
      then Right renderedServiceBytes
      else do
        value <-
          first
            (invalid . T.pack . show)
            (Yaml.decodeEither' renderedServiceBytes :: Either Yaml.ParseException Value)
        private <- first invalid (privateService value)
        first invalid (canonicalValue private)
  let domainRendered = drop 1 serviceRendered
  unless
    (length domainRendered == length domains && all ((== "service") . fst) domainRendered)
    (Left (invalid "service domain renderer produced unexpected members"))
  unless
    (length volumeRendered == length volumes && all ((== "service") . fst) volumeRendered)
    (Left (invalid "service volume renderer produced unexpected members"))
  volumeMembers <- traverse compileVolume (zip volumes (map snd volumeRendered))
  let volumeIds = map ((^. #identity) . fst) volumeMembers
  serviceMember <-
    bindOne
      resource
      DeleteWhenUnreferenced
      Stateless
      (map OrderedAfter (namespaceId : imageId : volumeIds <> databasePrerequisites <> secretIds))
      source
      serviceBytes
  domainMembers <- traverse (compileDomain accessIds resource) (zip domains (map snd domainRendered))
  contributions <- case (service ^. #access, accessBinding) of
    (Just policy, Just binding) ->
      traverse
        ( \domain -> do
            host <- first invalid (mkName (domainText (domain ^. #domain)))
            key <- first invalid (mkLogicalKey (domainText (domain ^. #domain)))
            let role = if policy ^. #role == AuthPortal then PortalBackend else ProtectedBackend
            pure
              ( RegisterBackend
                  (accessOwner binding)
                  cluster
                  host
                  (upstreamFor (service ^. #namespace) (service ^. #name))
                  role
                  key
              )
        )
        domains
    _ -> Right []
  let members = volumeMembers <> [serviceMember] <> domainMembers
      declarations = [Managed declaration | (declaration, _) <- members]
      native = Map.fromList [(declaration ^. #identity, member) | member@(declaration, _) <- members]
      bundle = ResourceBundle declarations [] [] contributions [] []
  _ <- mkScopeDeclaration owner [bundle]
  unless
    (Map.size native == length members)
    (Left (invalid "service members share an identity"))
  pure (bundle, native)
  where
    known = either (error . T.unpack) id . mkName
    invalid message =
      single
        ( inventoryError "invalid-service-declaration" message
            & #sources
            .~ [source]
        )
    single errorValue = errorValue :| []
    privateService (Object root) = case KM.lookup "metadata" root of
      Just (Object metadata) -> case KM.lookup "labels" metadata of
        Just (Object labels) ->
          Right
            ( Object
                ( KM.insert
                    "metadata"
                    ( Object
                        ( KM.insert
                            "labels"
                            ( Object
                                ( KM.insert
                                    "networking.knative.dev/visibility"
                                    (String "cluster-local")
                                    labels
                                )
                            )
                            metadata
                        )
                    )
                    root
                )
            )
        _ -> Left "protected Service has no object labels"
      _ -> Left "protected Service has no object metadata"
    privateService _ = Left "protected Service native evidence is not an object"
    compileVolume (volume, bytes) = do
      recovery <- case volume ^. #retention of
        Dsl.Retain ->
          Just
            <$> maybe
              (Left (invalid "retained service volume has no recovery intent"))
              Right
              (Map.lookup (volume ^. #name) recoveryByVolume)
        Dsl.Delete -> Right Nothing
      volumeId <- first invalid (volumeResourceId owner (known "service-pvc") volume)
      let volumeSource =
            source
              { path = path source <> "/volume/" <> volumeNameText (volume ^. #name)
              }
          lifecycle = if volume ^. #retention == Dsl.Retain then Retain else DeleteWhenUnreferenced
          dataPolicy = maybe Stateless Durable recovery
      member@(declaration, _) <-
        bindOne
          volumeId
          lifecycle
          dataPolicy
          [OrderedAfter namespaceId]
          volumeSource
          bytes
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "v1"
              "PersistentVolumeClaim"
              (Just (rollout ^. #namespace))
              (pvcName (serviceNameText (service ^. #name)) (volumeNameText (volume ^. #name)))
          )
      unless
        (declaration ^. #address == expected)
        (Left (invalid "service volume render has an unexpected PVC address"))
      pure member
    compileDomain accessIds serviceId (domain, bytes) = do
      domainId <- first invalid (domainMappingResourceId owner domain)
      host <- first invalid (mkName (domainText (domain ^. #domain)))
      let domainSource =
            source
              { path = path source <> "/domain/" <> domainText (domain ^. #domain)
              }
      tlsPrerequisites <- case domain ^. #tls of
        AutomaticTls -> Right []
        SuppliedTlsSecret secretName -> do
          secretId <-
            first
              invalid
              ( secretDependency
                  cluster
                  (rollout ^. #namespace)
                  tlsSecrets
                  secretName
              )
          pure [secretId]
      let reviewedBytes = case accessIds of
            [] -> bytes
            _ ->
              renderAccessDomainMapping
                backendConfigMapNamespace
                (domainText (domain ^. #domain))
                (RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" backendConfigMapNamespace)
          domainNamespace = if null accessIds then rollout ^. #namespace else backendConfigMapNamespace
          prerequisites = namespaceId : serviceId : tlsPrerequisites <> accessIds
      (declaration, native) <-
        bindOne
          domainId
          DeleteWhenUnreferenced
          Stateless
          (map OrderedAfter prerequisites)
          domainSource
          reviewedBytes
      expected <-
        first
          invalid
          ( kubernetesAddress
              cluster
              "serving.knative.dev/v1beta1"
              "DomainMapping"
              (Just domainNamespace)
              (domainText (domain ^. #domain))
          )
      unless
        (declaration ^. #address == expected)
        (Left (invalid "service domain render has an unexpected address"))
      pure (declaration {aliases = [Hostname host]}, native)
    bindOne resource lifecycle dataPolicy dependencies location bytes = do
      value <- first (invalid . T.pack . show) (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
      canonical <- first invalid (canonicalValue value)
      (declaration, native) <-
        first
          single
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resource
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest canonical
                , lifecyclePolicy = lifecycle
                , inputDataPolicy = dataPolicy
                , inputSensitivity = Private
                , sourceLocation = location
                }
          )
      pure (declaration {dependencies = dependencies}, native)
