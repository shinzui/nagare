-- | Bind production site renders and release history to independent scopes.
-- Image publication is an accepted dependency; building the image remains a
-- separate publication operation. Previews, release history, and member
-- binding live in the @Nagare.Inventory.Site.*@ modules and are re-exported
-- here so commands and tests keep one import.
module Nagare.Inventory.Site
  ( SiteReleaseAction (..)
  , compileStaticSiteScope
  , compileStaticSiteScopeWith
  , compileStaticSiteScopeWithCdn
  , compileStaticSiteScopeWithCloudflare
  , compileStaticSiteRollbackScope
  , compileStaticSiteRollbackScopeWithCdn
  , compileStaticSiteRollbackScopeWithCloudflare
  , compileServerSiteScope
  , compileServerSiteScopeWith
  , compileServerSiteScopeWithCloudflare
  , compileServerSiteScopeWithBuild
  , compileServerSiteRollbackScope
  , compileServerSiteRollbackScopeWithCloudflare
  , compileServerSiteRollbackScopeWithBuild
  , compileStaticSitePreviewScope
  , compileServerSitePreviewScope
  , compileServerSitePreviewScopeWithBuild
  , acceptedSiteReleaseLog
  , acceptedSiteSource
  , acceptedSitePreviewDependencies
  , acceptedSitePreviewStoreIds
  , sitePreviewRetirementScope
  , legacyServerSiteReleaseImport
  , legacyStaticSiteReleaseImport
  , siteVolumeRecoveryBindings
  , siteNativeOwned
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Access.Resolve (backendConfigMapNamespace)
import Nagare.Cdn.Provision (CdnTarget (..), GcpStackRefs (..), planCdn)
import Nagare.Dsl.Access (AccessPolicy)
import Nagare.Dsl.Cdn.Types (Cdn (..), CdnProvider (CloudflareCdn, GcpCloudCdn))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Render (pvcName)
import Nagare.Dsl.Server.Render qualified as ServerRender
import Nagare.Dsl.Server.Types (ServerSite (..))
import Nagare.Dsl.Static.Types (StaticSite (..), siteNameText)
import Nagare.Dsl.Types (DomainSpec (..), DomainTls (..), EnvScope (Runtime), EnvVar (..), ScopedEnvVar (..), SecretName, Volume (..), VolumeName, domainText, imageRefText, mkNamespace, mkServiceName, namespaceText, volumeNameText)
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Application (AccessBinding, CloudflareCdnBinding (..), GoogleCdnBinding (..), ReviewedCdnBinding (..))
import Nagare.Inventory.PreviewOwnership (sitePreviewRetirementScope)
import Nagare.Inventory.ProtectedRoute (ProtectedRoute (..), ProtectedRoutes (..), composeProtectedRoutes, protectedHosts, siteAccessPolicy)
import Nagare.Inventory.Site.Member (bindOne, checkAddress, reviewedBuildReference, siteSecretDependency)
import Nagare.Inventory.Site.Preview (acceptedSitePreviewDependencies, acceptedSitePreviewStoreIds, compileServerSitePreviewScope, compileServerSitePreviewScopeWithBuild, compileStaticSitePreviewScope)
import Nagare.Inventory.Site.Release (SiteReleaseAction (..), acceptedSiteReleaseLog, acceptedSiteSource, legacyServerSiteReleaseImport, legacyStaticSiteReleaseImport, siteReleaseHistory, validLog)
import Nagare.Resource.Application (domainMappingResourceId, volumeResourceId)
import Nagare.Resource.Cdn (compileCloudflareCacheContribution, compileCloudflareDnsRecord, compileGoogleDnsRecord)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Server.Deploy qualified as Server
import Nagare.Static.Deploy (DeployInputs (..), StaticManifests (..), productionManifests)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), renderReleaseConfigMap)

compileStaticSiteScope ::
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteScope = compileStaticSiteScopeWith RecordRelease Nothing Nothing

compileStaticSiteScopeWithCdn ::
  GoogleCdnBinding ->
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteScopeWithCdn binding = compileStaticSiteScopeWith RecordRelease (Just (GoogleCdnBindingFor binding)) Nothing

compileStaticSiteScopeWithCloudflare ::
  CloudflareCdnBinding ->
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteScopeWithCloudflare binding =
  compileStaticSiteScopeWith RecordRelease (Just (CloudflareCdnBindingFor binding)) Nothing

compileStaticSiteRollbackScope ::
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteRollbackScope = compileStaticSiteScopeWith SelectRelease Nothing Nothing

compileStaticSiteRollbackScopeWithCdn ::
  GoogleCdnBinding ->
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteRollbackScopeWithCdn binding = compileStaticSiteScopeWith SelectRelease (Just (GoogleCdnBindingFor binding)) Nothing

compileStaticSiteRollbackScopeWithCloudflare ::
  CloudflareCdnBinding ->
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteRollbackScopeWithCloudflare binding =
  compileStaticSiteScopeWith SelectRelease (Just (CloudflareCdnBindingFor binding)) Nothing

compileStaticSiteScopeWith ::
  SiteReleaseAction ->
  Maybe ReviewedCdnBinding ->
  Maybe AccessBinding ->
  DeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileStaticSiteScopeWith action cdnBinding accessBinding inputs cluster namespaceId imageId tlsSecrets prior release source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      tag = inputs ^. #imageTag
      rendered = productionManifests inputs
      invalid message =
        inventoryError "invalid-static-site-scope" message
          & #sources
          .~ [source]
          & (:| [])
  unless
    ( release ^. #releaseId == tag
        && release ^. #imageTag == tag
        && release ^. #image == imageRefText (site ^. #image)
        && release ^. #siteName == name
        && release ^. #namespace == ns
        && release ^. #url == rendered ^. #url
    )
    (Left (invalid "static-site release differs from its selected image or render"))
  unless
    (validLog name ns prior)
    (Left (invalid "static-site prior release history is inconsistent"))
  history <- first invalid (siteReleaseHistory action prior release)
  compileSiteRenderedScope
    name
    ns
    (site ^. #domains)
    (site ^. #cdn)
    cdnBinding
    (site ^. #access)
    accessBinding
    (inputs ^. #baseDomain)
    (rendered ^. #service)
    (rendered ^. #domainMappings)
    []
    Map.empty
    []
    tlsSecrets
    cluster
    namespaceId
    imageId
    history
    source

siteVolumeRecoveryBindings ::
  ServerSite -> [T.Text] -> Either T.Text (Map VolumeName RecoveryIntent)
siteVolumeRecoveryBindings site raw = do
  pairs <- traverse parseOne raw
  let bindings = Map.fromList pairs
      expected =
        Set.fromList
          [ volume ^. #name
          | volume <- site ^. #volumes
          , volume ^. #retention == Dsl.Retain
          ]
  unless
    (length pairs == Map.size bindings && Map.keysSet bindings == expected)
    (Left "server-site recovery must cover exactly its retained volumes")
  pure bindings
  where
    parseOne value = case T.splitOn "=" value of
      [volumeText, recoveryText] -> do
        volume <-
          maybe
            (Left "server-site recovery names an undeclared volume")
            Right
            (find ((== volumeText) . volumeNameText . (^. #name)) (site ^. #volumes))
        case T.splitOn ":" recoveryText of
          [backupText, keyText, versionText] -> do
            backup <- mkName backupText
            key <- mkName keyText
            version <- mkName versionText
            pure
              ( volume ^. #name
              , RecoveryIntent backup (mkSecretRef key version :| [])
              )
          _ -> Left "server-site recovery must be VOLUME=BACKUP:KEY:VERSION"
      _ -> Left "server-site recovery must be VOLUME=BACKUP:KEY:VERSION"

-- | Server sites share the site ownership and release protocol. Runtime and
-- supplied TLS Secret references bind accepted declarations in the same
-- cluster and namespace.
compileServerSiteScope ::
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteScope = compileServerSiteScopeWith RecordRelease Nothing Nothing Set.empty

compileServerSiteScopeWithCloudflare ::
  CloudflareCdnBinding ->
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteScopeWithCloudflare binding =
  compileServerSiteScopeWith RecordRelease (Just (CloudflareCdnBindingFor binding)) Nothing Set.empty

compileServerSiteScopeWithBuild ::
  Set.Set SecretName ->
  Maybe ReviewedCdnBinding ->
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteScopeWithBuild buildSecrets cdnBinding =
  compileServerSiteScopeWith RecordRelease cdnBinding Nothing buildSecrets

compileServerSiteRollbackScope ::
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteRollbackScope = compileServerSiteScopeWith SelectRelease Nothing Nothing Set.empty

compileServerSiteRollbackScopeWithCloudflare ::
  CloudflareCdnBinding ->
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteRollbackScopeWithCloudflare binding =
  compileServerSiteScopeWith SelectRelease (Just (CloudflareCdnBindingFor binding)) Nothing Set.empty

compileServerSiteRollbackScopeWithBuild ::
  Set.Set SecretName ->
  Maybe ReviewedCdnBinding ->
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteRollbackScopeWithBuild buildSecrets cdnBinding =
  compileServerSiteScopeWith SelectRelease cdnBinding Nothing buildSecrets

compileServerSiteScopeWith ::
  SiteReleaseAction ->
  Maybe ReviewedCdnBinding ->
  Maybe AccessBinding ->
  Set.Set SecretName ->
  Server.ServerDeployInputs ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  Map VolumeName RecoveryIntent ->
  Map SecretName Declaration ->
  Map SecretName Declaration ->
  StaticReleaseLog ->
  StaticRelease ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileServerSiteScopeWith action cdnBinding accessBinding buildSecrets inputs cluster namespaceId imageId recovery envSecrets tlsSecrets prior release source = do
  let site = inputs ^. #site
      name = siteNameText (site ^. #name)
      ns = namespaceText (site ^. #namespace)
      tag = inputs ^. #imageTag
      rendered = Server.serverManifests inputs
      invalid message =
        inventoryError "invalid-server-site-scope" message
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
    (Left (invalid "server-site recovery does not cover exactly its retained volumes"))
  let secretRefs =
        [ (secret, entry ^. #scopes)
        | entry <- Map.elems (site ^. #env)
        , EnvSecretRef secret <- [entry ^. #value]
        ]
  unless
    (all (reviewedBuildReference buildSecrets) secretRefs)
    (Left (invalid "server-site Build Secret references need exact image publication inputs"))
  let runtimeSecretRefs =
        [ secret
        | (secret, scopes) <- secretRefs
        , Set.member Runtime scopes
        ]
  unless
    (Map.keysSet envSecrets == Set.fromList runtimeSecretRefs)
    (Left (invalid "server-site runtime Secret references require exactly their typed dependencies"))
  secretIds <-
    traverse
      (first invalid . siteSecretDependency cluster ns envSecrets)
      (Set.toAscList (Set.fromList runtimeSecretRefs))
  unless
    ( release ^. #releaseId == tag
        && release ^. #imageTag == tag
        && release ^. #image == imageRefText (site ^. #image)
        && release ^. #siteName == name
        && release ^. #namespace == ns
        && release ^. #url == rendered ^. #url
    )
    (Left (invalid "server-site release differs from its selected image or render"))
  unless
    (validLog name ns prior)
    (Left (invalid "server-site prior release history is inconsistent"))
  history <- first invalid (siteReleaseHistory action prior release)
  let volumeBytes =
        ServerRender.renderServerVolumeClaims
          site
          (ServerRender.ServerDeployContext tag Nothing)
  unless
    (length volumeBytes == length (site ^. #volumes))
    (Left (invalid "server-site volume renderer changed membership"))
  compileSiteRenderedScope
    name
    ns
    (site ^. #domains)
    (site ^. #cdn)
    cdnBinding
    (site ^. #access)
    accessBinding
    (inputs ^. #baseDomain)
    (rendered ^. #service)
    (rendered ^. #domainMappings)
    (zip (site ^. #volumes) volumeBytes)
    recovery
    secretIds
    tlsSecrets
    cluster
    namespaceId
    imageId
    history
    source

compileSiteRenderedScope ::
  T.Text ->
  T.Text ->
  [DomainSpec] ->
  Maybe Cdn ->
  Maybe ReviewedCdnBinding ->
  Maybe AccessPolicy ->
  Maybe AccessBinding ->
  T.Text ->
  ByteString ->
  [ByteString] ->
  [(Volume, ByteString)] ->
  Map VolumeName RecoveryIntent ->
  [ResourceId] ->
  Map SecretName Declaration ->
  ResourceId ->
  ResourceId ->
  ResourceId ->
  StaticReleaseLog ->
  SourceLocation ->
  Either
    (NonEmpty InventoryError)
    (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileSiteRenderedScope
  name
  ns
  domains
  cdn
  cdnBinding
  access
  accessBinding
  baseDomain
  serviceBytes
  domainBytes
  volumeInputs
  recovery
  secretIds
  tlsSecrets
  cluster
  namespaceId
  imageId
  history
  source = do
    let invalid message =
          inventoryError "invalid-site-scope" message
            & #sources
            .~ [source]
            & (:| [])
        requiredTls =
          Set.fromList
            [ secret
            | domain <- domains
            , SuppliedTlsSecret secret <- [domain ^. #tls]
            ]
    unless
      (Map.keysSet tlsSecrets == requiredTls)
      (Left (invalid "site TLS requires exactly its accepted Secret dependencies"))
    unless
      (length domains == length domainBytes)
      (Left (invalid "site domain renderer changed membership"))
    -- EP-186: a protected site keeps its rendered origin private and answers
    -- only through enforcer routes in nagare-system, one per hostname, each
    -- contributed to the auth owner's backend map. Its policy is the supported
    -- subset only, and a CDN would cache content past the identity check.
    protection <- case (access, accessBinding) of
      (Nothing, Nothing) -> Right Nothing
      (Just policy, Just binding) -> do
        first invalid (siteAccessPolicy policy)
        when
          (isJust cdn)
          (Left (invalid "a protected site cannot be served through a CDN: remove cdn, or keep the site public"))
        hosts <- first invalid (protectedHosts name ns baseDomain domains)
        namespace <- first invalid (mkNamespace ns)
        serviceName <- first invalid (mkServiceName name)
        Just
          <$> first
            invalid
            (composeProtectedRoutes binding policy cluster baseDomain namespace serviceName hosts serviceBytes)
      _ -> Left (invalid "site access requires exactly its accepted auth binding")
    let originBytes = maybe serviceBytes (^. #origin) protection
        routeDomains = maybe domains (map (^. #domain) . (^. #routes)) protection
        routeBytes = maybe domainBytes (map (^. #mapping) . (^. #routes)) protection
        routeNamespace = maybe ns (const backendConfigMapNamespace) protection
        routePrerequisites = maybe [] (^. #prerequisites) protection
        contributions = maybe [] (map (^. #contribution) . (^. #routes)) protection
    owner <- first invalid (mkScopeId Standalone ("site-" <> name))
    serviceKey <- first invalid (mkLogicalKey name)
    serviceRole <- first invalid (mkName "service")
    releaseKey <- first invalid (mkLogicalKey "release-history")
    releaseRole <- first invalid (mkName "configmap")
    volumeRole <- first invalid (mkName "site-pvc")
    let serviceId = mintResourceId owner serviceKey serviceRole
        historyId = mintResourceId owner releaseKey releaseRole
        serviceSource = source {path = path source <> "/service"}
    volumeMembers <-
      traverse
        ( \(volume, bytes) -> do
            volumeId <- first invalid (volumeResourceId owner volumeRole volume)
            (lifecycle, policy) <- case volume ^. #retention of
              Dsl.Retain -> do
                intent <-
                  maybe
                    (Left (invalid "retained site volume lacks recovery"))
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
              (pvcName name (volumeNameText (volume ^. #name)))
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
        (map OrderedAfter ([namespaceId, imageId] <> volumeIds <> secretIds))
        serviceSource
        originBytes
    checkAddress invalid cluster "serving.knative.dev/v1" "Service" ns name serviceMember
    domainMembers <-
      traverse
        ( \(domain, bytes) -> do
            domainId <- first invalid (domainMappingResourceId owner domain)
            host <- first invalid (mkName (domainText (domain ^. #domain)))
            tlsIds <- case domain ^. #tls of
              AutomaticTls -> Right []
              SuppliedTlsSecret secret -> do
                secretId <- first invalid (siteSecretDependency cluster ns tlsSecrets secret)
                pure [secretId]
            let domainSource = source {path = path source <> "/domain/" <> domainText (domain ^. #domain)}
            member <-
              bindOne
                owner
                cluster
                domainId
                DeleteWhenUnreferenced
                Stateless
                (map OrderedAfter ([namespaceId, serviceId] <> tlsIds <> routePrerequisites))
                domainSource
                bytes
            checkAddress
              invalid
              cluster
              "serving.knative.dev/v1beta1"
              "DomainMapping"
              routeNamespace
              (domainText (domain ^. #domain))
              member
            pure (first (\resource -> resource {aliases = [Hostname host]}) member)
        )
        (zip routeDomains routeBytes)
    cdnBundles <- case (cdn, cdnBinding) of
      (Nothing, Nothing) -> Right []
      (Just requested, Just (GoogleCdnBindingFor binding)) -> do
        unless
          (requested ^. #provider == GcpCloudCdn)
          (Left (invalid "Google CDN intent requires a Google backend binding"))
        let refs = googleCdnRefs binding
            hosts = map (domainText . (^. #domain)) domains
            target = CdnTarget hosts "" ns name baseDomain
        unless
          (not (null domains) && all (/= baseDomain) hosts)
          (Left (invalid "Google CDN requires non-apex application hostnames"))
        _ <- first invalid (planCdn requested target refs)
        backendId <- case googleCdnBackend binding of
          Managed backend
            | backend ^. #executor == PulumiExecutor
            , scopeKind (backend ^. #owner) == Platform
            , (case backend ^. #spec of NativeObject {} -> True; _ -> False)
            , any
                (T.isInfixOf "gcp:compute/backendService:BackendService")
                [urn | PulumiUrn urn <- backend ^. #address : backend ^. #aliases] ->
                Right (backend ^. #identity)
          _ -> Left (invalid "CDN backend is not an accepted platform Pulumi BackendService")
        traverse
          ( \domain -> do
              domainId <- first invalid (domainMappingResourceId owner domain)
              key <-
                first
                  invalid
                  ( maybe
                      (mkLogicalKey (domainText (domain ^. #domain)))
                      Right
                      (domain ^. #logicalKey)
                  )
              project <- first invalid (mkName (refs ^. #project))
              zone <- first invalid (mkName (refs ^. #dnsZone))
              host <- first invalid (mkName (domainText (domain ^. #domain)))
              compileGoogleDnsRecord
                owner
                key
                project
                zone
                host
                (refs ^. #globalIp)
                domainId
                backendId
                source
          )
          domains
      (Just requested, Just (CloudflareCdnBindingFor binding)) -> do
        unless
          ( requested ^. #provider == CloudflareCdn
              && scopeKind (cloudflareCdnOwner binding) == Platform
              && validDnsIpv4 (cloudflareCdnOriginIp binding)
              && not (null domains)
          )
          (Left (invalid "Cloudflare CDN requires a platform zone owner, origin IPv4, and hostnames"))
        let zone = cloudflareCdnZone binding
            ruleset = cloudflareRulesResourceId (cloudflareCdnOwner binding) zone
        fmap concat $
          traverse
            ( \domain -> do
                domainId <- first invalid (domainMappingResourceId owner domain)
                key <-
                  first
                    invalid
                    ( maybe
                        (mkLogicalKey (domainText (domain ^. #domain)))
                        Right
                        (domain ^. #logicalKey)
                    )
                host <- first invalid (mkName (domainText (domain ^. #domain)))
                cache <-
                  compileCloudflareCacheContribution
                    owner
                    (cloudflareCdnOwner binding)
                    zone
                    host
                    requested
                    domainId
                    source
                dns <-
                  compileCloudflareDnsRecord
                    owner
                    key
                    zone
                    host
                    (cloudflareCdnOriginIp binding)
                    domainId
                    ruleset
                    source
                pure [cache, dns]
            )
            domains
      _ -> Left (invalid "site CDN requires exactly one matching typed binding")
    let historyBytes = renderReleaseConfigMap name ns history
        historySource = source {path = path source <> "/release-history"}
        -- Retained history never orders after edge DNS records, or they could not be collected (F46).
        workloadIds = volumeIds <> [serviceId] <> map ((^. #identity) . fst) domainMembers
    historyMember <-
      bindOne
        owner
        cluster
        historyId
        Retain
        Stateless
        (map OrderedAfter (namespaceId : imageId : workloadIds))
        historySource
        historyBytes
    checkAddress
      invalid
      cluster
      "v1"
      "ConfigMap"
      ns
      ("nagare-static-releases-" <> name)
      historyMember
    let members = volumeMembers <> [serviceMember] <> domainMembers <> [historyMember]
        ids = map ((^. #identity) . fst) members
        native =
          Map.fromList
            [ (resource ^. #identity, (resource, bytes))
            | (resource, bytes) <- members
            ]
    unless
      (length ids == Set.size (Set.fromList ids))
      (Left (invalid "site members share a resource identity"))
    scope <-
      mkScopeDeclaration
        owner
        (ResourceBundle (map (Managed . fst) members) [] [] contributions [] [] : cdnBundles)
    pure (scope, native)

-- | Direct site commands must check every native address they may write,
-- including release history retained after the Service has been collected.
siteNativeOwned ::
  T.Text ->
  T.Text ->
  [T.Text] ->
  [T.Text] ->
  Bool ->
  [ManagedResource] ->
  Bool
siteNativeOwned name ns domains volumes writesHistory = any matches
  where
    targets =
      Set.fromList
        ( [("serving.knative.dev", "service", name)]
            <> [("serving.knative.dev", "domainmapping", domain) | domain <- domains]
            <> [("", "persistentvolumeclaim", pvcName name volume) | volume <- volumes]
            <> [("", "configmap", "nagare-static-releases-" <> name) | writesHistory]
        )
    matches resource = case resource ^. #address of
      Kubernetes _ group kind (Just namespaceName) nativeName ->
        nameText namespaceName == ns
          && Set.member (group, nameText kind, nameText nativeName) targets
      _ -> False
