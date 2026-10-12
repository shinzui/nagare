module EnContractSpec (enContractTests) where

import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.Aeson.Types (parseEither, withObject, (.:))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import En.Client (CheckDecisionWire (..), CheckResponseWire (..))
import En.Servant.Problem (ProblemDetails (..))
import Nagare.Access.Auth (AuthenticatedUser (..))
import Nagare.Access.Config (AuthPlaneConfig (..))
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Nagare.Access.En (authorizeWithEn, checkResponseToDecision, enClientEnvFromAuthPlane)
import Nagare.Access.Prelude hiding ((.=))
import Network.HTTP.Client qualified as HC
import Network.HTTP.Types (mkStatus, status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, runSession, setPath, srequest)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | The caller supplies the real En handler with Alice's one host grant.
enContractTests :: IO AuthPlaneConfig -> Wai.Application -> TestTree
enContractTests config enApp =
  testGroup
    "current En HTTP contract"
    [ testCase "all En Problem Details responses remain unavailable" $
        forM_ [400, 412, 422, 500, 503] $ \code -> do
          let problem = ProblemDetails "urn:en:test" "Test refusal" code "bounded diagnostic" "test_refusal" False
              problemApp _ respond = respond (Wai.responseLBS (mkStatus code "") [("Content-Type", "application/problem+json")] (encode problem))
          testWithApplication (pure problemApp) $ \port -> do
            manager <- HC.newManager HC.defaultManagerSettings
            cfg <- config
            clientEnv <- either (fail . show) pure =<< enClientEnvFromAuthPlane manager (cfg & #enUrl .~ localUrl port)
            authorizeWithEn clientEnv AuthenticatedUser {subject = "alice"} "tools.example.com"
              >>= (@?= AuthorizationUnavailable "test_refusal: bounded diagnostic")
    , testCase "reviewed exact-tuple queries receive Relay pages from En" $ do
        -- The HTTP contract used by Inventory.AccessRuntime: exact filters,
        -- first=2, and a complete zero-or-one-node Relay response.
        let query subject =
              object
                [ "consistency" .= object ["mode" .= ("fullyConsistent" :: Text)]
                , "filter"
                    .= object
                      [ "objectType" .= ("app" :: Text)
                      , "objectId" .= ("tools.example.com" :: Text)
                      , "relation" .= ("viewer" :: Text)
                      , "subjectType" .= ("user" :: Text)
                      , "subjectId" .= (subject :: Text)
                      , "subjectRelation" .= object ["match" .= ("none" :: Text)]
                      ]
                ]
            page = withObject "page" $ \o -> do
              edges <- o .: "edges"
              nodes <- traverse (withObject "edge" (.: "node")) edges
              info <- o .: "pageInfo"
              more <- withObject "page info" (.: "hasNextPage") info
              pure (nodes :: [Value], more :: Bool)
        forM_ [("alice", 1), ("bob", 0)] $ \(subject, expectedCount) -> do
          response <-
            runSession
              (srequest (SRequest ((setPath defaultRequest "/v1/relationships/query?first=2") {Wai.requestMethod = "POST", Wai.requestHeaders = [("Content-Type", "application/json")]}) (encode (query subject))))
              enApp
          simpleStatus response @?= status200
          value <- either (fail . show) pure (eitherDecode (simpleBody response))
          (nodes, more) <- either (fail . show) pure (parseEither page value)
          length nodes @?= expectedCount
          more @?= False
    , testCase "maps en decisions into access decisions" $ do
        checkResponseToDecision (CheckResponseWire AllowedWire "checked-at" Nothing) @?= AccessAllowed
        checkResponseToDecision (CheckResponseWire DeniedWire "checked-at" Nothing) @?= AccessDenied
        checkResponseToDecision (CheckResponseWire (ConditionalWire []) "checked-at" Nothing) @?= AccessConditional
    ]
  where
    localUrl port = Text.pack ("http://127.0.0.1:" <> show port)
