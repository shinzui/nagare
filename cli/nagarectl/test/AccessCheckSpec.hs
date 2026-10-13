-- | The effective-access diagnostic (EP-188 M1): the exact check it sends,
-- every answer it can report, and that no error is ever read as a decision.
module AccessCheckSpec (accessCheckTests) where

import Data.Aeson (encode)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Nagare.Access.Check
import Nagare.Dsl.Prelude
import Test.Tasty
import Test.Tasty.HUnit

accessCheckTests :: TestTree
accessCheckTests =
  testGroup
    "Nagare.Access.Check"
    [ testCase "the check is fully consistent, context-free, and matches en-servant byte for byte" $
        encode (checkRequest "tools.example.com" "user_01h455vb4pex5vsknk084sn02q")
          @?= "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"context\":{\"values\":{}},\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"user_01h455vb4pex5vsknk084sn02q\"},\"permission\":\"access\",\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"}}"
    , testCase "allowed, denied, and conditional answers decode with their snapshot and optional grant generation" $ do
        parseCheckResponse "{\"decision\":{\"result\":\"allowed\"},\"checkedAt\":\"tok-1\"}"
          @?= Right Decided {decision = CheckAllowed, checkedAt = "tok-1", grantGeneration = Nothing}
        parseCheckResponse "{\"decision\":{\"result\":\"denied\"},\"checkedAt\":\"tok-2\",\"grantGeneration\":\"gen-7\"}"
          @?= Right Decided {decision = CheckDenied, checkedAt = "tok-2", grantGeneration = Just "gen-7"}
        parseCheckResponse "{\"decision\":{\"result\":\"conditional\",\"obligations\":[{\"caveat\":\"office_hours\",\"missingContext\":[\"now\"]}]},\"checkedAt\":\"tok-3\"}"
          @?= Right Decided {decision = CheckConditional [Obligation "office_hours" ["now"]], checkedAt = "tok-3", grantGeneration = Nothing}
        assertBool "a malformed answer decoded" (either (const True) (const False) (parseCheckResponse "{\"decision\":{\"result\":\"maybe\"},\"checkedAt\":\"x\"}"))
        assertBool "an answer without a snapshot decoded" (either (const True) (const False) (parseCheckResponse "{\"decision\":{\"result\":\"allowed\"}}"))
    , testCase "one check goes to /v1/check with the exact request and reports what en said" $ do
        sent <- newIORef []
        let call path body = modifyIORef' sent (<> [(path, encode body)]) >> pure (Right (200, "{\"decision\":{\"result\":\"denied\"},\"checkedAt\":\"tok\"}"))
        report <- effectiveAccess call "tools.example.com" "user_01h455vb4pex5vsknk084sn02q"
        report ^. #result @?= Decided {decision = CheckDenied, checkedAt = "tok", grantGeneration = Nothing}
        readIORef sent >>= (@?= [("/v1/check", encode (checkRequest "tools.example.com" "user_01h455vb4pex5vsknk084sn02q"))])
        assertBool "a denied answer failed the command" (checkDecided report)
    , testCase "a transport failure, a problem answer, a bare error, and a malformed body are unavailable, never a decision, and never echo bodies" $ do
        down <- effectiveAccess (\_ _ -> pure (Left "connection refused")) "h" "user_01h455vb4pex5vsknk084sn02q"
        down ^. #result @?= Unavailable "en transport failed: connection refused"
        problem <- effectiveAccess (\_ _ -> pure (Right (503, "{\"type\":\"about:blank\",\"title\":\"Service Unavailable\",\"status\":503,\"code\":\"en.store_unavailable\",\"detail\":\"tuple store unavailable\"}"))) "h" "user_01h455vb4pex5vsknk084sn02q"
        problem ^. #result @?= Unavailable "en answered HTTP 503 en.store_unavailable: tuple store unavailable"
        bare <- effectiveAccess (\_ _ -> pure (Right (500, "Authorization: Bearer super-secret-token"))) "h" "user_01h455vb4pex5vsknk084sn02q"
        bare ^. #result @?= Unavailable "en answered HTTP 500 without a problem detail"
        malformed <- effectiveAccess (\_ _ -> pure (Right (200, "not json"))) "h" "user_01h455vb4pex5vsknk084sn02q"
        malformed ^. #result @?= Unavailable "malformed en check response"
        assertBool "an unavailable answer succeeded the command" (not (checkDecided down))
        assertBool "a secret leaked into a diagnostic" (not (T.isInfixOf "super-secret" (renderCheckReport bare)))
    , testCase "the JSON report names host, subject, permission, decision, snapshot, obligations and diagnostics" $ do
        let decided = CheckReport "tools.example.com" "user_x" Decided {decision = CheckConditional [Obligation "office_hours" ["now"]], checkedAt = "tok", grantGeneration = Just "gen"}
        encode decided
          @?= "{\"checkedAt\":\"tok\",\"decision\":\"conditional\",\"grantGeneration\":\"gen\",\"host\":\"tools.example.com\",\"obligations\":[{\"caveat\":\"office_hours\",\"missingContext\":[\"now\"]}],\"permission\":\"access\",\"subject\":\"user_x\"}"
        encode (CheckReport "tools.example.com" "user_x" (Unavailable "en answered HTTP 503 without a problem detail"))
          @?= "{\"decision\":\"unavailable\",\"diagnostic\":\"en answered HTTP 503 without a problem detail\",\"host\":\"tools.example.com\",\"permission\":\"access\",\"subject\":\"user_x\"}"
    , testCase "the plain report states the answer and the gateway cache caveat" $ do
        let rendered = renderCheckReport (CheckReport "tools.example.com" "user_x" Decided {decision = CheckAllowed, checkedAt = "tok", grantGeneration = Nothing})
        assertBool (T.unpack rendered) (T.isInfixOf "decision: allowed" rendered && T.isInfixOf "NAGARE_ACCESS_DECISION_TTL" rendered && T.isInfixOf "subject: user:user_x" rendered)
        let conditional = renderCheckReport (CheckReport "h" "u" Decided {decision = CheckConditional [Obligation "office_hours" ["now"]], checkedAt = "tok", grantGeneration = Nothing})
        assertBool (T.unpack conditional) (T.isInfixOf "conditional; the enforcer refuses it (office_hours needs now)" conditional)
    ]
