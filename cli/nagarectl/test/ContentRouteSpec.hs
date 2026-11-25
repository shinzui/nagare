-- | EP-285 M3: an application worker's content route compiles to a Service,
-- a wildcard Certificate and a Kourier Ingress; the compile refuses an unlisted
-- domain, a tunnel context and a host the application also claims; and the
-- composition keeps every host under the domain to that one worker.
module ContentRouteSpec (contentRouteTests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import InventoryTransactionSpec (fixtureBinding)
import ManagedEnvScopeSpec (input, scopedApp)
import Nagare.App.Deploy (RolloutEnv (..))
import Nagare.Dsl.Application qualified as DslApp
import Nagare.Dsl.ContentDomain
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types (HealthScheme (HTTP))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (defaultProbeTiming, mkHttpProbe, webWorker)
import Nagare.Dsl.Worker qualified as Dsl
import Nagare.Inventory.Adapters.KubernetesCollection (collectionDeleteRequest)
import Nagare.Inventory.Adapters.KubernetesReadiness (readinessForAddress)
import Nagare.Inventory.Application (ApplicationScopeInput (..), compileApplicationDeployment, compileStandaloneWorkerWithDependencies, contentRouteRetirements)
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Command.Effects (collectionEffects)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (IngressMode (IngressCloudflareTunnel), Mode (Local))
import Nagare.Test.Support.Profiles (tnbProfile)
import Test.Tasty
import Test.Tasty.HUnit

contentRouteTests :: TestTree
contentRouteTests =
  testGroup
    "content route"
    [ testCase "a content worker gets its Service, a wildcard Certificate and an Ingress after both" $ do
        (scope, native) <- compiled (routedApp [])
        let service = memberAt ("", "service", "scoped-worker") native
            certificate = memberAt ("cert-manager.io", "certificate", "nagare-content-scoped-worker") native
            ingress = memberAt ("networking.internal.knative.dev", "ingress", "nagare-content-scoped-worker") native
        assertBool "the Ingress is not after the Certificate and the Service" (all ((`elem` fst ingress ^. #dependencies) . OrderedAfter . (^. #identity) . fst) [certificate, service])
        fst ingress ^. #aliases @?= [Hostname (ok (mkName "content.example"))]
        textAt ["spec", "issuerRef", "name"] (snd certificate) @?= Just "letsencrypt-dns"
        textAt ["metadata", "labels", "nagare.dev/content-domain"] (snd certificate) @?= Just "content.example"
        -- Every member is the application's, and none is durable.
        assertBool "a route member is not the application's" (all ((== scopeId scope) . (^. #owner) . fst) [service, certificate, ingress])
        assertBool "a route member is durable" (all ((== Stateless) . (^. #dataPolicy) . fst) [service, certificate, ingress])
    , testCase "a local context's certificate is signed by the local CA" $ do
        (_, native) <- compiledWith (& #targetProfile . #mode .~ Local) (routedApp [])
        textAt ["spec", "issuerRef", "name"] (snd (memberAt ("cert-manager.io", "certificate", "nagare-content-scoped-worker") native)) @?= Just "nagare-local-ca"
    , testCase "a worker with a port and no route gets only its Service" $ do
        (_, native) <- compiled (scopedApp Dsl.NoManagedEnv & #workers %~ map (#http ?~ WorkerHttp port8080 Nothing))
        _ <- pure (memberAt ("", "service", "scoped-worker") native)
        [() | (resource, _) <- Map.elems native, kindOf resource `elem` ["certificate", "ingress"]] @?= []
    , testCase "adding a route changes no member of the application but the worker's Deployment" $ do
        (_, without) <- compiled (scopedApp Dsl.NoManagedEnv)
        (_, with) <- compiled (routedApp [])
        let unchanged = Map.filter ((/= "deployment") . kindOf . fst) without
        Map.intersectionWith (\a b -> snd a == snd b) unchanged with @?= Map.map (const True) unchanged
        Map.keysSet unchanged `subsetOf` Map.keysSet with @?= True
    , testCase "an unlisted domain, a tunnel context and the application's own host under the domain are refused" $ do
        codes (compileWith (& #targetProfile . #contentDomains .~ []) (routedApp [])) @?= ["content-domain-not-listed"]
        codes (compileWith (& #targetProfile . #ingress .~ IngressCloudflareTunnel) (routedApp [])) @?= ["content-route-needs-direct-ingress"]
        let ownHost = routedApp [] & #service %~ fmap (#domains .~ ok (Dsl.mkDomains [("share.content.example", True)]))
        codes (compileWith id ownHost) @?= ["content-domain-claimed"]
    , testCase "another scope's host under the domain, or the domain itself, is refused by the composition" $ do
        (scope, _) <- compiled (routedApp [])
        let compose others = composeInventory (ok (mkScopeSnapshot fixtureBinding Map.empty Map.empty)) (ReplaceScope scope :| map ReplaceScope others)
            hasCode code = either (elem code . map (^. #code) . NE.toList) (const False)
        assertBool "the route alone is refused for its domain" (not (hasCode "content-domain-claimed" (compose [])))
        assertBool "a mapping under the domain was accepted" (hasCode "content-domain-claimed" (compose [mappingScope "other" "x.content.example"]))
        assertBool "a mapping for the apex was accepted" (hasCode "claim-conflict" (compose [mappingScope "other" "content.example"]))
        assertBool "a mapping outside the domain was refused" (not (hasCode "content-domain-claimed" (compose [mappingScope "other" "x.elsewhere.example"])))
    , testCase "a standalone worker with a port is refused" $
        either (map (^. #code) . NE.toList) (const []) (standalone (worker & #http ?~ WorkerHttp port8080 Nothing))
          @?= ["worker-http-needs-application"]
    , testCase "a content route's members are collectable, and the Certificate goes with its Secret" $ do
        (_, native) <- compiled (routedApp [])
        let service = fst (memberAt ("", "service", "scoped-worker") native)
            certificate = fst (memberAt ("cert-manager.io", "certificate", "nagare-content-scoped-worker") native)
            ingress = fst (memberAt ("networking.internal.knative.dev", "ingress", "nagare-content-scoped-worker") native)
            uid = ok (mkPhysicalIdentity "uid-1")
        assertBool "a route member is not collectable" (all supportsRetainedCollection [service, certificate, ingress])
        (certificateArgs, certificateBody) <- either (assertFailure . T.unpack) pure (collectionDeleteRequest (certificate ^. #address) uid "7")
        certificateArgs @?= ["delete", "--raw", "/apis/cert-manager.io/v1/namespaces/personal/certificates/nagare-content-scoped-worker", "-f", "-"]
        assertBool "the Certificate is not deleted in the Background" ("\"propagationPolicy\":\"Background\"" `T.isInfixOf` certificateBody)
        (ingressArgs, _) <- either (assertFailure . T.unpack) pure (collectionDeleteRequest (ingress ^. #address) uid "7")
        ingressArgs @?= ["delete", "--raw", "/apis/networking.internal.knative.dev/v1alpha1/namespaces/personal/ingresses/nagare-content-scoped-worker", "-f", "-"]
    , testCase "retiring a worker's content route selects its Certificate and Ingress, and its Service once the port goes" $ do
        (_, routed) <- compiled (routedApp [])
        (_, portOnly) <- compiled (scopedApp Dsl.NoManagedEnv & #workers %~ map (#http ?~ WorkerHttp port8080 Nothing))
        (_, plain) <- compiled (scopedApp Dsl.NoManagedEnv)
        let accepted = Map.keys routed
            identity' key = fst (memberAt key routed) ^. #identity
            certificate = identity' ("cert-manager.io", "certificate", "nagare-content-scoped-worker")
            ingress = identity' ("networking.internal.knative.dev", "ingress", "nagare-content-scoped-worker")
            service = identity' ("", "service", "scoped-worker")
        fmap Data.Set.fromList (contentRouteRetirements accepted (Map.keys portOnly) ["scoped-worker"]) @?= Right (Data.Set.fromList [certificate, ingress])
        fmap Data.Set.fromList (contentRouteRetirements accepted (Map.keys plain) ["scoped-worker"]) @?= Right (Data.Set.fromList [certificate, ingress, service])
        assertBool "a still-declared route was retired" (either (const True) (const False) (contentRouteRetirements accepted accepted ["scoped-worker"]))
        assertBool "a worker with no route was retired" (either (const True) (const False) (contentRouteRetirements (Map.keys plain) (Map.keys plain) ["scoped-worker"]))
        -- The collect review that deletes them says what goes.
        map (^. #loses) (collectionEffects [fst (memberAt ("networking.internal.knative.dev", "ingress", "nagare-content-scoped-worker") routed), fst (memberAt ("cert-manager.io", "certificate", "nagare-content-scoped-worker") routed), fst (memberAt ("", "service", "scoped-worker") routed)])
          @?= [ "*.content.example and content.example stop being served (Ingress personal/nagare-content-scoped-worker)"
              , "the certificate personal/nagare-content-scoped-worker and the Secret holding its private key are deleted"
              ]
    , testCase "an Ingress is ready only once Kourier has observed its generation and reports Ready" $ do
        let address = Kubernetes testCluster "networking.internal.knative.dev" (ok (mkName "ingress")) (Just (ok (mkName "personal"))) (ok (mkName "nagare-content-scoped-worker"))
            status generation observed ready =
              object
                [ "metadata" .= object ["generation" .= (generation :: Int)]
                , "status" .= object ["observedGeneration" .= (observed :: Int), "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= (ready :: Text)]]]
                ]
        readinessForAddress address (status 2 2 "True") @?= Just True
        readinessForAddress address (status 2 1 "True") @?= Just False
        readinessForAddress address (status 2 2 "False") @?= Just False
    ]

port8080 :: Dsl.Port
port8080 = ok (Dsl.mkPort 8080)

contentDomain :: ContentDomain
contentDomain = ok (mkContentDomain "content.example")

-- | The fixture application with its worker serving @*.content.example@.
routedApp :: [Text] -> DslApp.Application
routedApp hosts =
  scopedApp Dsl.NoManagedEnv
    & #workers
    %~ map
      ( \w ->
          w
            & #http
            ?~ WorkerHttp port8080 (Just (ok (mkContentRoute contentDomain (map (ok . Dsl.mkDomain) hosts))))
            & #readiness
            ?~ ok (mkHttpProbe "/healthz" (Just port8080) HTTP defaultProbeTiming)
      )

profileWithDomain :: RolloutEnv -> RolloutEnv
profileWithDomain = #targetProfile . #contentDomains .~ [contentDomain]

compileWith :: (RolloutEnv -> RolloutEnv) -> DslApp.Application -> Either (NonEmpty InventoryError) ([ScopeDeclaration], Map ResourceId (ManagedResource, ByteString))
compileWith change app = compileApplicationDeployment base {scopeRollout = change (profileWithDomain (scopeRollout base))}
  where
    base = input app

compiledWith :: (RolloutEnv -> RolloutEnv) -> DslApp.Application -> IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compiledWith change app = case compileWith change app of
  Right (scope : _, native) -> pure (scope, native)
  Right ([], _) -> assertFailure "no scope" >> error "unreachable"
  Left errors -> assertFailure (show (NE.toList errors)) >> error "unreachable"

compiled :: DslApp.Application -> IO (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compiled = compiledWith id

codes :: Either (NonEmpty InventoryError) a -> [Text]
codes = either (map (^. #code) . NE.toList) (const [])

kindOf :: ManagedResource -> Text
kindOf resource = case resource ^. #address of
  Kubernetes _ _ kind _ _ -> nameText kind
  _ -> ""

memberAt :: (Text, Text, Text) -> Map ResourceId (ManagedResource, ByteString) -> (ManagedResource, ByteString)
memberAt (group, kind, name) native =
  case [pair | pair@(resource, _) <- Map.elems native, Kubernetes _ g k _ n <- [resource ^. #address], g == group, nameText k == kind, nameText n == name] of
    [found] -> found
    other -> error ("members at " <> show (group, kind, name) <> ": " <> show (length other))

textAt :: [Text] -> ByteString -> Maybe Text
textAt keys bytes = case Yaml.decodeEither' bytes :: Either Yaml.ParseException Value of
  Right value -> go keys value
  Left _ -> Nothing
  where
    go [] (String found) = Just found
    go (key : rest) (Object fields) = KM.lookup (fromString' key) fields >>= go rest
    go _ _ = Nothing
    fromString' = Data.Aeson.Key.fromText

-- | Another application's scope holding one DomainMapping for a host.
mappingScope :: Text -> Text -> ScopeDeclaration
mappingScope owner host = ok (mkScopeDeclaration scope [ResourceBundle [Managed mapping] [] [] [] [] []])
  where
    scope = ok (mkScopeId Application owner)
    value =
      object
        [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
        , "kind" .= ("DomainMapping" :: Text)
        , "metadata" .= object ["name" .= host, "namespace" .= owner]
        , "spec" .= object ["ref" .= object ["name" .= owner, "kind" .= ("Service" :: Text), "apiVersion" .= ("serving.knative.dev/v1" :: Text)]]
        ]
    mapping =
      fst . ok $
        bindKubernetesObject
          KubernetesInput
            { resourceId = mintResourceId scope (ok (mkLogicalKey host)) (ok (mkName "domain"))
            , ownerScope = scope
            , clusterId = testCluster
            , inputObject = value
            , objectDigest = contentDigest (ok (canonicalValue value))
            , lifecyclePolicy = DeleteWhenUnreferenced
            , inputDataPolicy = Stateless
            , inputSensitivity = Private
            , sourceLocation = SourceLocation "test" "mapping"
            }

worker :: Dsl.Worker
worker = either error id (webWorker "content-gateway" "registry.example.com/content")

standalone :: Dsl.Worker -> Either (NonEmpty InventoryError) (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
standalone w =
  compileStandaloneWorkerWithDependencies
    (ok (mkScopeId Standalone "worker-content-gateway"))
    w
    RolloutEnv
      { appName = "content-gateway"
      , qualifiedImage = ok (Dsl.mkImageRef "registry.example.com/content")
      , imageTag = "v1"
      , effectiveTag = "v1"
      , taggedAppImage = "registry.example.com/content:v1"
      , appEnv = Map.empty
      , namespace = "personal"
      , baseDomain = "apps.example.com"
      , targetProfile = tnbProfile
      }
    testCluster
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "foundation")) (ok (mkName "namespace-personal")))
    (mintResourceId (ok (mkScopeId Platform "foundation")) (ok (mkLogicalKey "image")) (ok (mkName "publication")))
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    (SourceLocation "test" "worker")

testCluster :: ResourceId
testCluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

subsetOf :: (Ord a) => Data.Set.Set a -> Data.Set.Set a -> Bool
subsetOf = Data.Set.isSubsetOf

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
