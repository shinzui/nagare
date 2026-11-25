-- | EP-285 M3: a worker's HTTP port and content route, from the typed value to
-- the rendered Deployment, Service, Certificate and Ingress, and back through
-- the loader.
module ContentRouteSpec (contentRouteTests) where

import Control.Lens ((&), (.~), (?~))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Config (encodeWorker)
import Nagare.Dsl.ContentDomain
import Nagare.Dsl.Load (LoadError (..), decodeWorker)
import Nagare.Dsl.Prelude hiding ((&), (.~), (?~))
import Nagare.Dsl.Types (HealthScheme (HTTP), Port, mkDomain, mkPort)
import Nagare.Dsl.Worker
import Nagare.Dsl.Worker.Content (renderWorkerRoute)
import Nagare.Dsl.Worker.Render (renderWorkerDeployment)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

contentRouteTests :: TestTree
contentRouteTests =
  testGroup
    "content route (EP-285)"
    [ goldenVsString
        "a content worker's Deployment carries its port"
        "test/golden/worker-content.deployment.yaml"
        (pure (fromStrict (renderWorkerDeployment contentWorker "20261125-120000")))
    , goldenVsString
        "a content worker's Service, Certificate and Ingress"
        "test/golden/worker-content.route.yaml"
        (pure (fromStrict (BS.intercalate "---\n" (renderWorkerRoute "letsencrypt-dns" contentWorker))))
    , testCase "a worker with a port and no route renders only its Service" $
        length (renderWorkerRoute "letsencrypt-dns" (contentWorker & #http .~ Just (WorkerHttp port8080 Nothing))) @?= 1
    , testCase "a worker with no port renders no route and no port" $ do
        renderWorkerRoute "letsencrypt-dns" plainWorker @?= []
        assertBool "a plain worker has a port" (not (BS.isInfixOf "containerPort" (renderWorkerDeployment plainWorker "20261125-120000")))
    , testCase "a worker with no port encodes as before, with no http key" $
        assertBool "http key emitted" (not (BS.isInfixOf "\"http\"" (toStrict (encodeWorker plainWorker))))
    , testCase "a content worker round-trips through its JSON" $
        decodeWorker (toStrict (encodeWorker contentWorker)) @?= Right contentWorker
    , testCase "the loader refuses a content route without a readiness probe" $
        case decodeWorker (toStrict (encodeWorker (contentWorker & #readiness .~ Nothing))) of
          Left (MarshalError field _) -> field @?= "http.content"
          other -> assertFailure ("expected a refusal, got " <> show other)
    , testCase "a fixed host must be the domain or one label below it" $ do
        domain <- expectRight (mkContentDomain "content.example")
        let route hosts = mkContentRoute domain =<< traverse mkDomain hosts
        assertBool "apex refused" (not (isLeft (route ["content.example"])))
        assertBool "one label refused" (not (isLeft (route ["share.content.example"])))
        assertBool "two labels accepted" (isLeft (route ["a.share.content.example"]))
        assertBool "another domain accepted" (isLeft (route ["share.example"]))
        assertBool "a repeat accepted" (isLeft (route ["share.content.example", "share.content.example"]))
    , testCase "a content domain is a plain multi-label name" $ do
        assertBool "wildcard accepted" (isLeft (mkContentDomain "*.content.example"))
        assertBool "one label accepted" (isLeft (mkContentDomain "content"))
        fmap contentDomainText (mkContentDomain "Content.Example.") @?= Right "content.example"
    ]

port8080 :: Port
port8080 = either (error . Text.unpack) id (mkPort 8080)

plainWorker :: Worker
plainWorker = either error id (webWorker "content-gateway" "registry.example/content-gateway")

contentWorker :: Worker
contentWorker =
  plainWorker
    & #http ?~ WorkerHttp port8080 (Just route)
    & #readiness ?~ either (error . Text.unpack) id (mkHttpProbe "/healthz" (Just port8080) HTTP defaultProbeTiming)
  where
    route = either (error . Text.unpack) id $ do
      domain <- mkContentDomain "content.example"
      share <- mkDomain "share.content.example"
      mkContentRoute domain [share]

expectRight :: Either Text a -> IO a
expectRight = either (assertFailure . Text.unpack) pure
