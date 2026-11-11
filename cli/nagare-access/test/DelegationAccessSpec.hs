-- | EP-250 D4: a delegated host opens for its delegation's team. The host's
-- own grant is asked first; the delegation only on its refusal; an
-- unavailable answer is an outage, never a refusal.
module DelegationAccessSpec (delegationAccessTests) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.IORef
import Nagare.Access.App (authorizeHost)
import Nagare.Access.Auth (AccessServices (..), AuthenticatedUser (..))
import Nagare.Access.BackendMap (decodeBackendMap, lookupDelegation, mkPublicHost)
import Nagare.Access.DecisionCache (AccessDecision (..), AuthorizationResult (..))
import Nagare.Access.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TestServices (testServices)

delegationAccessTests :: TestTree
delegationAccessTests =
  testGroup
    "delegation access"
    [ testCase "a protected entry may name its delegation; a bare upstream and other roles name none" $ do
        backends <-
          either (assertFailure . show) pure $
            decodeBackendMap
              (BC.pack "{\"docs.team-a.example.com\":{\"upstream\":\"http://docs.team-a.svc.cluster.local\",\"role\":\"protected\",\"delegation\":\"kotei\"},\"tools.example.com\":\"http://tools.personal.svc.cluster.local\"}")
        docs <- either (assertFailure . show) pure (mkPublicHost "docs.team-a.example.com")
        tools <- either (assertFailure . show) pure (mkPublicHost "tools.example.com")
        lookupDelegation docs backends @?= Just "kotei"
        lookupDelegation tools backends @?= Nothing
        assertBool "a portal names a delegation" (isLeft (decodeBackendMap (BC.pack "{\"login.example.com\":{\"upstream\":\"http://shomei\",\"role\":\"portal\",\"delegation\":\"kotei\"}}")))
        assertBool "a delegation that is not a label" (isLeft (decodeBackendMap (BC.pack "{\"a.example.com\":{\"upstream\":\"http://a\",\"role\":\"protected\",\"delegation\":\"Kotei!\"}}")))
    , testCase "allowed by the host: the delegation is never asked" $ do
        (result, calls) <- run allowed denied (Just "kotei")
        (result, calls) @?= (AuthorizationDecision AccessAllowed, ["app:docs"])
    , testCase "allowed by the delegation when the host refuses" $ do
        (result, calls) <- run denied allowed (Just "kotei")
        (result, calls) @?= (AuthorizationDecision AccessAllowed, ["app:docs", "delegation:kotei"])
    , testCase "denied by both is a refusal" $ do
        (result, calls) <- run denied denied (Just "kotei")
        (result, calls) @?= (AuthorizationDecision AccessDenied, ["app:docs", "delegation:kotei"])
    , testCase "an unavailable delegation check is an outage, not a refusal" $ do
        (result, _) <- run denied (AuthorizationUnavailable "en down") (Just "kotei")
        result @?= AuthorizationUnavailable "en down"
    , testCase "an unavailable host check is an outage and asks nothing more" $ do
        (result, calls) <- run (AuthorizationUnavailable "en down") allowed (Just "kotei")
        (result, calls) @?= (AuthorizationUnavailable "en down", ["app:docs"])
    , testCase "a host without a delegation never makes the second call" $ do
        (result, calls) <- run denied allowed Nothing
        (result, calls) @?= (AuthorizationDecision AccessDenied, ["app:docs"])
    ]
  where
    allowed = AuthorizationDecision AccessAllowed
    denied = AuthorizationDecision AccessDenied
    run :: AuthorizationResult -> AuthorizationResult -> Maybe Text -> IO (AuthorizationResult, [Text])
    run host delegation named = do
      calls <- newIORef []
      let record call answer = modifyIORef' calls (<> [call]) >> pure answer
          services =
            testServices
              { authorizeUser = \_ _ -> record "app:docs" host
              , authorizeDelegation = \_ name -> record ("delegation:" <> name) delegation
              }
      result <- authorizeHost services AuthenticatedUser {subject = "user:alice"} "docs.team-a.example.com" named
      (result,) <$> readIORef calls
