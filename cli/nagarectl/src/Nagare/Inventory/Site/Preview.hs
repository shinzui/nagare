-- | Preview scopes: an independent short-lived Service and hostname per
-- preview, bound to the four accepted Runtime/Preview environment stores.
module Nagare.Inventory.Site.Preview
  ( compileStaticSitePreviewScope
  , compileServerSitePreviewScope
  , compileServerSitePreviewScopeWithBuild
  , acceptedSitePreviewDependencies
  , acceptedSitePreviewStoreIds
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Access.Resolve (backendConfigMapNamespace)
import Nagare.Dsl.Access (AccessPolicy)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (managedConfigMapName, managedSecretName, pvcName)
import Nagare.Dsl.Server.Render qualified as ServerRender
import Nagare.Dsl.Static.Types (siteNameText)
import Nagare.Dsl.Types (EnvScope (Preview, Runtime), EnvVar (..), ScopedEnvVar (..), SecretName, Volume (..), VolumeName, mkDomains, mkNamespace, mkServiceName, namespaceText, volumeNameText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application (AccessBinding)
import Nagare.Inventory.ProtectedRoute (ProtectedRoute (..), ProtectedRoutes (..), composeProtectedRoutes, siteAccessPolicy)
import Nagare.Inventory.Site.Member (bindOne, checkAddress, reviewedBuildReference, siteSecretDependency)
import Nagare.Resource.Application (domainMappingResourceId, volumeResourceId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), RecoveryIntent (..))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Server.Deploy qualified as Server
import Nagare.Static.Deploy (DeployInputs (..), StaticManifests (..), previewManifests)
import Nagare.Static.Preview (previewDomain)

-- | A preview is an independent short-lived scope. The exact rendered
-- envFrom references require all four accepted Runtime/Preview stores.
compileStaticSitePreviewScope ::
  Maybe AccessBinding ->
  DeployInputs ->
  T.Text ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [Declaration] ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSitePreviewScope accessBinding inputs raw cluster namespaceId imageId stores source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      invalid message =
        inventoryError "invalid-site-preview-scope" message
          & #sources
          .~ [source]
          & (:| [])
  rendered <- first invalid (previewManifests inputs raw)
  host <- first invalid (previewDomain name raw (inputs ^. #baseDomain))
  compileRenderedSitePreviewScope
    name
    ns
    (site ^. #access)
    accessBinding
    (inputs ^. #baseDomain)
    (rendered ^. #serviceName)
    host
    (rendered ^. #service)
    (rendered ^. #domainMappings)
    []
    Map.empty
    cluster
    namespaceId
    imageId
    stores
    []
    source

compileServerSitePreviewScope ::
  Maybe AccessBinding ->
  Server.ServerDeployInputs ->
  T.Text ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [Declaration] ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSitePreviewScope accessBinding = compileServerSitePreviewScopeWithBuild accessBinding Set.empty

compileServerSitePreviewScopeWithBuild ::
  Maybe AccessBinding ->
  Set.Set SecretName ->
  Server.ServerDeployInputs ->
  T.Text ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [Declaration] ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSitePreviewScopeWithBuild accessBinding buildSecrets inputs raw cluster namespaceId imageId stores recovery envSecrets source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      invalid message =
        inventoryError "invalid-server-preview-scope" message
          & #sources
          .~ [source]
          & (:| [])
  unless
    ( Map.keysSet recovery
        == Set.fromList
          [ volume ^. #name
          | volume <- site ^. #volumes
          , volume ^. #retention == Dsl.Retain
          ]
    )
    (Left (invalid "server preview recovery does not cover exactly its retained volumes"))
  let secretRefs =
        [ (secret, entry ^. #scopes)
        | entry <- Map.elems (site ^. #env)
        , EnvSecretRef secret <- [entry ^. #value]
        ]
  unless
    (all (reviewedBuildReference buildSecrets) secretRefs)
    (Left (invalid "server preview Build Secret references need exact image publication inputs"))
  let activeSecretRefs =
        [ secret
        | (secret, scopes) <- secretRefs
        , Set.member Runtime scopes || Set.member Preview scopes
        ]
  unless
    (Map.keysSet envSecrets == Set.fromList activeSecretRefs)
    (Left (invalid "server preview Runtime and Preview Secret references require exact dependencies"))
  secretIds <-
    traverse
      (first invalid . siteSecretDependency cluster ns envSecrets)
      (Set.toAscList (Set.fromList activeSecretRefs))
  rendered <- first invalid (Server.serverPreviewManifests inputs raw)
  host <- first invalid (previewDomain name raw (inputs ^. #baseDomain))
  let previewName = rendered ^. #serviceName
      volumeBytes =
        ServerRender.renderServerVolumeClaims
          site
          (ServerRender.ServerDeployContext (inputs ^. #imageTag) (Just previewName))
  unless
    (length volumeBytes == length (site ^. #volumes))
    (Left (invalid "server preview volume renderer changed membership"))
  compileRenderedSitePreviewScope
    name
    ns
    (site ^. #access)
    accessBinding
    (inputs ^. #baseDomain)
    (rendered ^. #serviceName)
    host
    (rendered ^. #service)
    (rendered ^. #domainMappings)
    (zip (site ^. #volumes) volumeBytes)
    recovery
    cluster
    namespaceId
    imageId
    stores
    secretIds
    source

compileRenderedSitePreviewScope ::
  T.Text ->
  T.Text ->
  Maybe AccessPolicy ->
  Maybe AccessBinding ->
  T.Text ->
  T.Text ->
  T.Text ->
  ByteString ->
  [ByteString] ->
  [(Volume, ByteString)] ->
  Map VolumeName RecoveryIntent ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  [Declaration] ->
  [ResourceId] ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileRenderedSitePreviewScope
  name
  ns
  access
  accessBinding
  baseDomain
  serviceName
  host
  serviceBytes
  domainManifests
  volumeInputs
  recovery
  cluster
  namespaceId
  imageId
  stores
  secretIds
  source = do
    let invalid message =
          inventoryError "invalid-site-preview-scope" message
            & #sources
            .~ [source]
            & (:| [])
    envIds <- first invalid (sitePreviewStoreIds cluster name ns stores)
    domains <- first invalid (mkDomains [(host, True)])
    domain <- case domains of
      [one] -> Right one
      _ -> Left (invalid "preview renderer changed domain membership")
    domainBytes <- case domainManifests of
      [bytes] -> Right bytes
      _ -> Left (invalid "preview renderer changed domain manifest membership")
    -- EP-186: a preview inherits the production policy, but its hostname is an
    -- independent authorization object with its own route and backend entry.
    protection <- case (access, accessBinding) of
      (Nothing, Nothing) -> Right Nothing
      (Just policy, Just binding) -> do
        first invalid (siteAccessPolicy policy)
        namespace <- first invalid (mkNamespace ns)
        previewService <- first invalid (mkServiceName serviceName)
        Just
          <$> first
            invalid
            (composeProtectedRoutes binding policy cluster baseDomain namespace previewService [domain] serviceBytes)
      _ -> Left (invalid "site preview access requires exactly its accepted auth binding")
    let originBytes = maybe serviceBytes (^. #origin) protection
        routeBytes = maybe domainBytes (\routes -> fromMaybe domainBytes (listToMaybe (map (^. #mapping) (routes ^. #routes)))) protection
        routeNamespace = maybe ns (const backendConfigMapNamespace) protection
        routePrerequisites = maybe [] (^. #prerequisites) protection
        contributions = maybe [] (map (^. #contribution) . (^. #routes)) protection
    owner <- first invalid (mkScopeId Standalone ("site-preview-" <> serviceName))
    serviceKey <- first invalid (mkLogicalKey serviceName)
    serviceRole <- first invalid (mkName "service")
    volumeRole <- first invalid (mkName "site-pvc")
    let serviceId = mintResourceId owner serviceKey serviceRole
    volumeMembers <-
      traverse
        ( \(volume, bytes) -> do
            volumeId <- first invalid (volumeResourceId owner volumeRole volume)
            (lifecycle, policy) <- case volume ^. #retention of
              Dsl.Retain -> do
                intent <-
                  maybe
                    (Left (invalid "retained preview volume lacks recovery"))
                    Right
                    (Map.lookup (volume ^. #name) recovery)
                pure (Retain, Durable intent)
              Dsl.Delete -> pure (DeleteWhenUnreferenced, Stateless)
            let volumeSource =
                  source
                    { path = path source <> "/volume/" <> volumeNameText (volume ^. #name)
                    }
            member <-
              bindOne
                owner
                cluster
                volumeId
                lifecycle
                policy
                [OrderedAfter namespaceId]
                volumeSource
                bytes
            checkAddress
              invalid
              cluster
              "v1"
              "PersistentVolumeClaim"
              ns
              (pvcName serviceName (volumeNameText (volume ^. #name)))
              member
            pure member
        )
        volumeInputs
    let volumeIds = map ((^. #identity) . fst) volumeMembers
    serviceMember <-
      bindOne
        owner
        cluster
        serviceId
        DeleteWhenUnreferenced
        Stateless
        (map OrderedAfter ([namespaceId, imageId] <> volumeIds <> envIds <> secretIds))
        (source {path = path source <> "/service"})
        originBytes
    checkAddress
      invalid
      cluster
      "serving.knative.dev/v1"
      "Service"
      ns
      serviceName
      serviceMember
    domainId <- first invalid (domainMappingResourceId owner domain)
    hostname <- first invalid (mkName host)
    domainMember <-
      bindOne
        owner
        cluster
        domainId
        DeleteWhenUnreferenced
        Stateless
        (map OrderedAfter ([namespaceId, serviceId] <> routePrerequisites))
        (source {path = path source <> "/domain/" <> host})
        routeBytes
    checkAddress invalid cluster "serving.knative.dev/v1beta1" "DomainMapping" routeNamespace host domainMember
    let members =
          volumeMembers
            <> [serviceMember, first (\resource -> resource {aliases = [Hostname hostname]}) domainMember]
        native =
          Map.fromList
            [ (resource ^. #identity, (resource, bytes))
            | (resource, bytes) <- members
            ]
    scope <-
      mkScopeDeclaration
        owner
        [ResourceBundle (map (Managed . fst) members) [] [] contributions [] []]
    pure (scope, native)

-- | Resolve all four preview overlay stores from accepted Managed resources.
-- Their names and addresses are fixed by the renderer, so an optional
-- envFrom reference cannot later resolve to an unreviewed store.
acceptedSitePreviewDependencies ::
  ScopeSnapshot ->
  ResourceId ->
  T.Text ->
  T.Text ->
  [ResourceId] ->
  Either T.Text [Declaration]
acceptedSitePreviewDependencies snapshot cluster name ns ids = do
  stores <- traverse resolve ids
  _ <- sitePreviewStoreIds cluster name ns stores
  pure (stores)
  where
    resources =
      [ resource
      | (_, scope) <- Map.elems (snapshotScopes snapshot)
      , bundle <- scopeBundles scope
      , Managed resource <- declarations bundle
      ]
    resolve resourceId = case filter ((== resourceId) . (^. #identity)) resources of
      [resource] -> Right (Managed resource)
      _ -> Left "site preview environment resource is absent or ambiguous in accepted inventory"

-- | Discover the four accepted environment stores rendered into a static
-- preview. Webhook submissions use their exact IDs and the CLI verifies them
-- again against the current accepted snapshot.
acceptedSitePreviewStoreIds ::
  ScopeSnapshot -> ResourceId -> T.Text -> T.Text -> Either T.Text [ResourceId]
acceptedSitePreviewStoreIds snapshot cluster name ns = do
  addresses <-
    traverse
      ( \(kind, nativeName) ->
          kubernetesAddress cluster "v1" kind (Just ns) nativeName
      )
      [ ("ConfigMap", managedConfigMapName name Runtime)
      , ("Secret", managedSecretName name Runtime)
      , ("ConfigMap", managedConfigMapName name Preview)
      , ("Secret", managedSecretName name Preview)
      ]
  ids <- traverse select addresses
  _ <- acceptedSitePreviewDependencies snapshot cluster name ns ids
  pure ids
  where
    members =
      [ resource
      | (_, scope) <- Map.elems (snapshotScopes snapshot)
      , bundle <- scopeBundles scope
      , Managed resource <- declarations bundle
      ]
    select address = case [ resource ^. #identity
                          | resource <- members
                          , resource ^. #address == address
                          ] of
      [resourceId] -> Right resourceId
      _ -> Left "site preview requires one accepted resource for each rendered environment store"

-- | Select only the exact reviewed preview scope requested by a delete
-- command. Retirement retains its native members for later collection.
sitePreviewStoreIds ::
  ResourceId ->
  T.Text ->
  T.Text ->
  [Declaration] ->
  Either T.Text [ResourceId]
sitePreviewStoreIds cluster name ns stores = do
  unless
    (length stores == 4 && Set.size (Set.fromList (map declarationId stores)) == 4)
    (Left "site preview requires four distinct accepted environment resources")
  addresses <-
    traverse
      ( \case
          Managed resource -> Right (resource ^. #address)
          _ -> Left "site preview environment store must be Managed"
      )
      stores
  expected <-
    Set.fromList
      <$> traverse
        ( \(kind, nativeName) ->
            kubernetesAddress cluster "v1" kind (Just ns) nativeName
        )
        [ ("ConfigMap", managedConfigMapName name Runtime)
        , ("Secret", managedSecretName name Runtime)
        , ("ConfigMap", managedConfigMapName name Preview)
        , ("Secret", managedSecretName name Preview)
        ]
  unless
    (Set.fromList addresses == expected)
    (Left "site preview environment resources differ from its four rendered stores")
  pure (Set.toAscList (Set.fromList (map declarationId stores)))
