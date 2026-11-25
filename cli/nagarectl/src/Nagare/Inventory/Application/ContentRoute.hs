-- | EP-285: the members that route requests to an application worker's HTTP
-- port. Every worker with a port gets a ClusterIP Service; a worker with a
-- content route also gets the wildcard Certificate for @*.D@ and @D@ and the
-- Knative Ingress that Kourier serves, ordered after both.
--
-- The Ingress carries the alias @Hostname D@. The composition reads a content
-- Ingress's alias as a claim on every host under @D@, so no other member of
-- any scope can take one host of the domain (the M1 prototype showed Kourier
-- would serve it without complaint).
module Nagare.Inventory.Application.ContentRoute
  ( compileWorkerRoutes
  , contentIssuerName
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.App.Deploy (RolloutEnv)
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.ContentDomain (DomainRelation (Unrelated), WorkerHttp, contentDomainRelation, contentDomainText)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (domainText, serviceNameText)
import Nagare.Dsl.Worker (Worker)
import Nagare.Dsl.Worker.Content (contentCertificateValue, contentIngressValue, workerServiceValue)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Application (workerResourceId)
import Nagare.Resource.Inventory (Declaration (Managed), ManagedResource, ResourceBundle (ResourceBundle))
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
  ( InventoryError
  , ProviderAddress (Hostname)
  , ResourceId
  , ScopeId
  , SourceLocation (path)
  , inventoryError
  , mkName
  )
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (IngressMode (IngressDirect), Mode (Cloud, Local))

-- | The ClusterIssuer a content certificate names: the context's ACME
-- issuer on a cloud context, the local CA on a local one.
contentIssuerName :: Mode -> Text
contentIssuerName = \case
  Cloud -> "letsencrypt-dns"
  Local -> "nagare-local-ca"

-- | The route members of every worker with a port, or the first refusal.
compileWorkerRoutes ::
  Application ->
  RolloutEnv ->
  ScopeId ->
  ResourceId ->
  ResourceId ->
  SourceLocation ->
  Either (NonEmpty InventoryError) ([ResourceBundle], Map ResourceId (ManagedResource, ByteString))
compileWorkerRoutes app rollout owner cluster namespaceId source = do
  let routed = [(worker, http) | worker <- app ^. #workers, Just http <- [worker ^. #http]]
      routes = [(worker, route) | (worker, http) <- routed, Just route <- [http ^. #content]]
      profile = rollout ^. #targetProfile
      domains = [route ^. #domain | (_, route) <- routes]
      ownHosts = maybe [] (map (domainText . (^. #domain)) . (^. #domains)) (app ^. #service)
  forM_ routes $ \(worker, route) -> do
    let domain = route ^. #domain
        named = serviceNameText (worker ^. #name) <> " serves " <> contentDomainText domain
    unless
      (domain `elem` profile ^. #contentDomains)
      (refuse "content-domain-not-listed" (named <> ", which the context does not list in NAGARE_CONTENT_DOMAINS"))
    unless
      (profile ^. #ingress == IngressDirect)
      (refuse "content-route-needs-direct-ingress" (named <> ", but the context serves through a Cloudflare Tunnel, whose ingress rules cover only the base zone"))
    forM_ ownHosts $ \host ->
      unless
        (contentDomainRelation domain host == Unrelated)
        (refuse "content-domain-claimed" (named <> ", but the application's service also claims " <> host))
  unless
    (nub domains == domains)
    (refuse "content-domain-claimed" "two workers of the application serve the same content domain")
  members <- concat <$> traverse (uncurry (workerMembers (contentIssuerName (profile ^. #mode)))) routed
  let declarations = [Managed declaration | (declaration, _) <- members]
      native = Map.fromList [(declaration ^. #identity, member) | member@(declaration, _) <- members]
  pure ([ResourceBundle declarations [] [] [] [] [] | not (null members)], native)
  where
    failure code message = inventoryError code message & #sources .~ [source] & (:| [])
    refuse :: Text -> Text -> Either (NonEmpty InventoryError) ()
    refuse code message = Left (failure code message)
    invalid = failure "invalid-worker-route"
    workerMembers :: Text -> Worker -> WorkerHttp -> Either (NonEmpty InventoryError) [(ManagedResource, ByteString)]
    workerMembers issuer worker http = do
      let idFor role = first invalid (mkName role >>= \named -> workerResourceId owner named worker)
          located suffix = source {path = path source <> "/worker/" <> serviceNameText (worker ^. #name) <> "/" <> suffix}
      serviceId <- idFor "worker-service"
      service <- bind serviceId [namespaceId] (located "service") (workerServiceValue worker http)
      case http ^. #content of
        Nothing -> pure [service]
        Just route -> do
          certificateId <- idFor "content-certificate"
          ingressId <- idFor "content-ingress"
          certificate <- bind certificateId [namespaceId] (located "certificate") (contentCertificateValue issuer worker route)
          (ingress, bytes) <- bind ingressId [namespaceId, certificateId, serviceId] (located "ingress") (contentIngressValue worker http route)
          apex <- first invalid (mkName (contentDomainText (route ^. #domain)))
          pure [service, certificate, (ingress & #aliases .~ [Hostname apex], bytes)]
    bind :: ResourceId -> [ResourceId] -> SourceLocation -> Value -> Either (NonEmpty InventoryError) (ManagedResource, ByteString)
    bind resource prerequisites location value = do
      canonical <- first invalid (canonicalValue value)
      (declaration, bytes) <-
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
                , sourceLocation = location
                }
          )
      pure (declaration & #dependencies .~ map OrderedAfter prerequisites, bytes)
