-- | What a tunnel context refuses, and the claim that keeps two workloads off one flattened name.
module Nagare.Test.SiteInventory.Tunnel
  ( tunnelSiteInventoryTests
  )
where

import Data.ByteString (ByteString)
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty ((:|)), toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Deploy (serviceUrl, serviceUrlFor)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Build (defaultBuild)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild), mkFilePathText, mkSiteName)
import Nagare.Dsl.Types
  ( Deployment (..)
  , defaultPort
  , mkDomains
  , mkImageRef
  , mkNamespace
  , mkSecretName
  , mkServiceName
  , withTlsSecret
  )
import Nagare.Inventory.CollectionPolicy (retainedConsumerInert)
import Nagare.Inventory.Site (compileStaticSiteScope)
import Nagare.Inventory.TunnelRoute (checkTunnelRoutes, defaultHostClaims)
import Nagare.Resource.Inventory
  ( Declaration (Managed)
  , Executor (KubernetesExecutor)
  , ManagedResource
  , ScopeChange (ReplaceScope)
  , ScopeDeclaration
  , composeInventory
  , declarations
  , mkScopeSnapshot
  , scopeBundles
  , scopeId
  )
import Nagare.Resource.Types qualified as Resource
import Nagare.Static.Deploy (DeployInputs (..), staticUrlFor)
import Nagare.Static.Release (StaticRelease (StaticRelease), emptyReleaseLog)
import Nagare.Target.Kinds (IngressMode (..), hostShapeFor)
import Nagare.Test.Support.Assertions (unsafe)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tunnelSiteInventoryTests :: [TestTree]
tunnelSiteInventoryTests =
  [ testCase "two workloads that flatten to one name are refused, across namespaces" $ do
      first' <- siteScope IngressCloudflareTunnel "a-b" "c" []
      second' <- siteScope IngressCloudflareTunnel "a" "b-c" []
      other <- siteScope IngressCloudflareTunnel "a" "c" []
      assertComposed first' other
      assertRefused first' second'
  , testCase "a site behind the tunnel declares no Cloudflare resource, so a redeploy makes no Cloudflare call" $ do
      scope <- siteScope IngressCloudflareTunnel "a" "c" [("www.example.com", True)]
      let executors = [resource ^. #executor | bundle <- scopeBundles scope, Managed resource <- declarations bundle]
      assertBool (show executors) (not (null executors) && all (== KubernetesExecutor) executors)
  , testCase "a site's release history does not hold its route for collection, and its route members do (F140)" $ do
      scope <- siteScope IngressCloudflareTunnel "a" "c" [("www.example.com", True)]
      let inert = [Resource.resourceIdText (resource ^. #identity) | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations, retainedConsumerInert resource]
      inert @?= ["standalone:site-a/release-history/configmap"]
  , testCase "a custom domain cannot take another workload's flattened name" $ do
      public <- siteScope IngressCloudflareTunnel "a" "c" []
      claiming <- siteScope IngressCloudflareTunnel "other" "c" [("a-c.example.com", True)]
      assertRefused public claiming
  , testCase "the same names coexist in a direct context, which holds no default-name claim" $ do
      first' <- siteScope IngressDirect "a-b" "c" []
      second' <- siteScope IngressDirect "a" "b-c" []
      assertComposed first' second'
      serviceAliases first' @?= []
  , testCase "a workload may declare its own flattened name as a domain" $ do
      scope <- siteScope IngressCloudflareTunnel "a" "c" [("a-c.example.com", True)]
      serviceAliases scope @?= []
  , testCase "a tenant may not spell a platform service's default name" $ do
      assertBool "reserved" (isLeft (defaultHostClaims FlatHosts "nagared-x" "y-nagare-system" "example.com" []))
      assertBool "reserved" (isLeft (defaultHostClaims FlatHosts "nagare-access-nagare" "system" "example.com" []))
      assertBool "the platform's own" (isRight (defaultHostClaims FlatHosts "nagared" "nagare-system" "example.com" []))
  , testCase "a first label over the DNS limit is refused" $
      assertBool "long" (isLeft (defaultHostClaims FlatHosts (T.replicate 40 "a") (T.replicate 30 "b") "example.com" []))
  , testCase "a domain deeper than the certificate covers names the certificate and its price" $ do
      let refused = checkTunnelRoutes FlatHosts "example.com" False (unsafe (mkDomains [("a.b.example.com", True)]))
      case refused of
        Left message -> assertBool (T.unpack message) ("Advanced Certificate Manager at $10 a month" `T.isInfixOf` message)
        Right () -> assertFailure "a two-label domain was accepted"
  , testCase "the zone, one label below it, and nothing outside it" $ do
      let check domain = checkTunnelRoutes FlatHosts "example.com" False (unsafe (mkDomains [(domain, True)]))
      check "example.com" @?= Right ()
      check "a.example.com" @?= Right ()
      assertBool "outside" (isLeft (check "example.org"))
      assertBool "a suffix is not the zone" (isLeft (check "notexample.com"))
  , testCase "a tunnel context refuses a per-site CDN and a supplied TLS Secret" $ do
      assertBool "cdn" (isLeft (checkTunnelRoutes FlatHosts "example.com" True []))
      let supplied = map (withTlsSecret (unsafe (mkSecretName "demo-tls"))) (unsafe (mkDomains [("a.example.com", True)]))
      assertBool "tls" (isLeft (checkTunnelRoutes FlatHosts "example.com" False supplied))
  , testCase "a direct context takes none of these refusals" $ do
      checkTunnelRoutes NestedHosts "example.com" True (unsafe (mkDomains [("a.b.example.org", True)])) @?= Right ()
      defaultHostClaims NestedHosts (T.replicate 63 "a") "nagare-system" "example.com" [] @?= Right []
  , testCase "an ordinary service's printed URL takes the context's host shape" $ do
      let service = demoService
      serviceUrl service "example.com" @?= "https://notes.personal.example.com"
      serviceUrlFor FlatHosts service "example.com" @?= "https://notes-personal.example.com"
  , testCase "the refusal reaches planning" $ do
      compiled <- pure (compileSite IngressCloudflareTunnel "a" "c" [("a.b.example.com", True)])
      assertBool "planned" (isLeft compiled)
  ]

demoService :: Deployment
demoService =
  Deployment
    { name = unsafe (mkServiceName "notes")
    , logicalKey = Nothing
    , namespace = unsafe (mkNamespace "personal")
    , image = unsafe (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
    , build = unsafe defaultBuild
    , domains = domains
    , port = defaultPort
    , env = Map.empty
    , resources = Nothing
    , scale = Nothing
    , healthCheck = Nothing
    , volumes = []
    , databases = []
    , appDatabases = []
    , appDatabaseReaders = []
    , brokers = []
    , access = Nothing
    , tasks = []
    , cdn = Nothing
    }
  where
    domains = []

assertComposed :: ScopeDeclaration -> ScopeDeclaration -> Assertion
assertComposed accepted next =
  -- The fixture declares no foundation, so only the claim is under test.
  either (\errors -> assertBool (show errors) (not (any ((== "claim-conflict") . (^. #code)) (toList errors)))) pure (compose accepted next)

assertRefused :: ScopeDeclaration -> ScopeDeclaration -> Assertion
assertRefused accepted next = case compose accepted next of
  Left errors -> assertBool (show errors) (any ((== "claim-conflict") . (^. #code)) (toList errors))
  Right () -> assertFailure "the second scope was accepted"

compose :: ScopeDeclaration -> ScopeDeclaration -> Either (NonEmpty Resource.InventoryError) ()
compose accepted next = do
  snapshot <-
    mkScopeSnapshot
      (Resource.ContextBinding (unsafe (Resource.mkContextId "test")) (unsafe (Resource.mkName "project")))
      (Map.singleton (scopeId accepted) (unsafe (Resource.mkScopeGeneration 1), accepted))
      Map.empty
  () <$ composeInventory snapshot (ReplaceScope next :| [])

-- | The aliases of the scope's Knative Service.
serviceAliases :: ScopeDeclaration -> [Resource.ProviderAddress]
serviceAliases scope =
  concat
    [ resource ^. #aliases
    | bundle <- scopeBundles scope
    , Managed resource <- declarations bundle
    , Resource.Kubernetes _ "serving.knative.dev" kind _ _ <- [resource ^. #address]
    , Resource.nameText kind == "service"
    ]

siteScope :: IngressMode -> Text -> Text -> [(Text, Bool)] -> IO ScopeDeclaration
siteScope ingress name ns domains =
  either (fail . show) (pure . fst) (compileSite ingress name ns domains)

compileSite ::
  IngressMode ->
  Text ->
  Text ->
  [(Text, Bool)] ->
  Either
    (NonEmpty Resource.InventoryError)
    (ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))
compileSite ingress name ns domains =
  compileStaticSiteScope inputs (fixtureId "cluster") (fixtureId "namespace") (fixtureId "image") Map.empty emptyReleaseLog release source
  where
    site =
      baseSite (NoBuild (unsafe (mkFilePathText "dist")))
        & #name
        .~ unsafe (mkSiteName name)
        & #namespace
        .~ unsafe (mkNamespace ns)
        & #domains
        .~ (if null domains then [] else unsafe (mkDomains domains))
    inputs = DeployInputs site "v1" "example.com" "." True (initProfile & #ingress .~ ingress)
    release =
      StaticRelease
        "v1"
        name
        ns
        "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo"
        "v1"
        (staticUrlFor (hostShapeFor ingress) site "example.com")
        Nothing
        (UTCTime (fromGregorian 2026 11 3) 0)
    source = Resource.SourceLocation "fixture" "tunnel-site"
    fixtureId key =
      Resource.mintResourceId
        (unsafe (Resource.mkScopeId Resource.Platform "foundation"))
        (unsafe (Resource.mkLogicalKey key))
        (unsafe (Resource.mkName "resource"))
