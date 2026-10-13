-- | One protected-host contract for every web workload kind (MasterPlan 27,
-- EP-186). A Deployment, Application, StaticSite or ServerSite that opts in
-- with @access = Just requireLogin@ gets the same composition: its origin
-- Service becomes cluster-local, every public hostname gets a DomainMapping in
-- @nagare-system@ whose ref is the nagare-access enforcer, and each hostname is
-- contributed to the auth owner's shared backend map as @app:<host>@. Nothing
-- here writes Kubernetes or En; callers bind the returned bytes into their own
-- scope and order the routes after 'prerequisites'.
module Nagare.Inventory.ProtectedRoute
  ( ProtectedRoute (..)
  , ProtectedRoutes (..)
  , composeProtectedRoutes
  , protectedHosts
  , siteAccessPolicy
  , supportedAccessPolicy
  )
where

import Data.Aeson (Value (Object, String))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve
  ( RouteTarget (..)
  , backendConfigMapNamespace
  , renderAccessDomainMapping
  , upstreamFor
  )
import Nagare.Dsl.Access (AccessPolicy, AccessRole (..), accessPermissionText, audienceText)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (DomainSpec (..), DomainTls (..), Namespace, ServiceName, domainText, mkDomain)
import Nagare.Inventory.Application.Types (AccessBinding (..))
import Nagare.Resource.Inventory
  ( BackendRole (PortalBackend, ProtectedBackend)
  , Contribution (RegisterBackend)
  , Declaration (Managed)
  , backendMapResourceId
  , shomeiSettingsResourceId
  )
import Nagare.Resource.Types
  ( Name
  , ResourceId
  , kubernetesAddress
  , mkLogicalKey
  , mkName
  , nameText
  , scopeIdText
  )
import Nagare.Resource.Wire (canonicalValue)

-- | One public hostname of a protected workload.
data ProtectedRoute = ProtectedRoute
  { domain :: !DomainSpec
  , host :: !Name
  , mapping :: !ByteString
  -- ^ The DomainMapping in @nagare-system@ that targets the enforcer. The
  -- caller binds it like any rendered manifest.
  , contribution :: !Contribution
  -- ^ The @RegisterBackend@ request the auth owner composes into the shared
  -- backend map: this host, this origin, this role.
  }
  deriving stock (Generic, Eq, Show)

data ProtectedRoutes = ProtectedRoutes
  { prerequisites :: ![ResourceId]
  -- ^ Auth-owned identities every route orders after: the shared backend map,
  -- the enforcer Service and, for the portal role, the Shomei settings.
  , origin :: !ByteString
  -- ^ The origin Service with the cluster-local visibility label, canonical.
  , routes :: ![ProtectedRoute]
  }
  deriving stock (Generic, Eq, Show)

-- | The policy subset this release enforces. The enforcer checks permission
-- @access@ on @app:<host>@ and verifies the cluster audience, so a different
-- permission or an explicit audience would be accepted by the config and then
-- silently ignored at the gateway. Planning refuses it instead.
supportedAccessPolicy :: AccessPolicy -> Either Text ()
supportedAccessPolicy policy = do
  let permission = accessPermissionText (policy ^. #permission)
  unless
    (permission == "access")
    ( Left
        ( "access permission "
            <> permission
            <> " is not supported: the enforcer checks permission access on app:<host>; use requireLogin"
        )
    )
  case policy ^. #audience of
    Nothing -> Right ()
    Just audience ->
      Left
        ( "access audience "
            <> audienceText audience
            <> " is not supported: the enforcer verifies the cluster audience; omit the audience"
        )

-- | A dedicated site kind is a protected site only; the auth portal remains a
-- Deployment or Application role.
siteAccessPolicy :: AccessPolicy -> Either Text ()
siteAccessPolicy policy = do
  supportedAccessPolicy policy
  unless
    (policy ^. #role == ProtectedSite)
    (Left "a StaticSite or ServerSite cannot be the auth portal: use requireLogin, and make the portal a Deployment or Application")

-- | The hostnames a protected workload answers on. With no declared domain the
-- public hostname is the Knative default @<name>.<namespace>.<base>@, which
-- must become an explicit enforcer route because the origin stops answering
-- there once it is cluster-local.
protectedHosts :: Text -> Text -> Text -> [DomainSpec] -> Either Text [DomainSpec]
protectedHosts name ns baseDomain [] = do
  host <- mkDomain (name <> "." <> ns <> "." <> baseDomain)
  pure [DomainSpec host Nothing True AutomaticTls]
protectedHosts _ _ _ domains = Right domains

-- | Compose the private origin, one enforcer route per hostname and the
-- backend contributions, after checking that the binding really is the
-- accepted auth owner for this cluster and base domain.
composeProtectedRoutes ::
  AccessBinding ->
  AccessPolicy ->
  ResourceId ->
  Text ->
  Namespace ->
  ServiceName ->
  [DomainSpec] ->
  ByteString ->
  Either Text ProtectedRoutes
composeProtectedRoutes binding policy cluster baseDomain ns name domains originBytes = do
  supportedAccessPolicy policy
  expected <-
    kubernetesAddress
      cluster
      "serving.knative.dev/v1"
      "Service"
      (Just backendConfigMapNamespace)
      "nagare-access"
  prerequisites <- case accessEnforcer binding of
    Managed enforcer
      | accessOwner binding == enforcer ^. #owner
      , scopeIdText (accessOwner binding) == "platform:auth"
      , enforcer ^. #address == expected
      , nameText (accessBaseDomain binding) == baseDomain ->
          Right
            ( [backendMapResourceId (accessOwner binding), enforcer ^. #identity]
                <> [shomeiSettingsResourceId (accessOwner binding) | policy ^. #role == AuthPortal]
            )
    _ -> Left "access binding lacks the accepted auth enforcer"
  when (null domains) (Left "a protected workload requires at least one public hostname")
  unless
    (all ((== AutomaticTls) . (^. #tls)) domains)
    (Left "central access routes require automatic TLS")
  value <- first (T.pack . show) (Yaml.decodeEither' originBytes :: Either Yaml.ParseException Value)
  origin <- canonicalValue =<< privateService value
  routes <- traverse route domains
  pure ProtectedRoutes {prerequisites = prerequisites, origin = origin, routes = routes}
  where
    role = if policy ^. #role == AuthPortal then PortalBackend else ProtectedBackend
    route domain = do
      let hostText = domainText (domain ^. #domain)
      host <- mkName hostText
      key <- mkLogicalKey hostText
      pure
        ProtectedRoute
          { domain = domain
          , host = host
          , mapping = renderAccessDomainMapping backendConfigMapNamespace hostText enforcerTarget
          , contribution = RegisterBackend (accessOwner binding) cluster host (upstreamFor ns name) role key
          }

enforcerTarget :: RouteTarget
enforcerTarget = RouteTarget "serving.knative.dev/v1" "Service" "nagare-access" backendConfigMapNamespace

-- | Mark the origin cluster-local so its generated Knative hostname is not a
-- public alternative to the protected route. Site renders carry no labels
-- object yet; application renders do. Either way the label is added.
privateService :: Value -> Either Text Value
privateService (Object root) = case KM.lookup "metadata" root of
  Just (Object metadata) -> do
    labels <- case KM.lookup "labels" metadata of
      Nothing -> Right KM.empty
      Just (Object existing) -> Right existing
      Just _ -> Left "protected Service labels are not an object"
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
  _ -> Left "protected Service has no object metadata"
privateService _ = Left "protected Service native evidence is not an object"
