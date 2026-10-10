-- | The enforcer's backend map: decoding and lookup, and the live map
-- (EP-183 M1) that serves a route added after startup without a restart.
module BackendMapSpec (backendMapTests, backendSourceTests) where

import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Nagare.Access.App (appWithBackends)
import Nagare.Access.BackendMap
import Nagare.Access.BackendSource
import Nagare.Access.Prelude
import Network.HTTP.Types (hHost, status502)
import Network.Wai (requestHeaders)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Test.Tasty
import Test.Tasty.HUnit

backendMapTests :: TestTree
backendMapTests =
  testGroup
    "backend map"
    [ testCase "decodes host to upstream JSON" $ do
        backends <- assertRight (decodeBackendMap "{\"Tools.Example.com\":\"http://tools.personal.svc.cluster.local\"}")
        lookupBackend "tools.example.com" backends @?= Just (BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend)
    , testCase "decodes object targets with protected and portal roles" $ do
        backends <-
          assertRight
            ( decodeBackendMap
                "{\"tools.example.com\":{\"upstream\":\"http://tools.personal.svc.cluster.local\",\"role\":\"protected\"},\"auth.example.com\":{\"upstream\":\"http://auth.personal.svc.cluster.local\",\"role\":\"portal\"}}"
            )
        lookupBackend "tools.example.com" backends
          @?= Just (BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend)
        lookupBackend "auth.example.com" backends
          @?= Just (BackendTarget "http://auth.personal.svc.cluster.local" PortalBackend)
        portal <- maybe (assertFailure "expected portal") pure (findPortal backends)
        publicHostText (portal ^. #host) @?= "auth.example.com"
    , testCase "rejects a second portal and names its host" $
        case decodeBackendMap
          "{\"auth-a.example.com\":{\"upstream\":\"http://auth-a.personal.svc.cluster.local\",\"role\":\"portal\"},\"auth-b.example.com\":{\"upstream\":\"http://auth-b.personal.svc.cluster.local\",\"role\":\"portal\"}}" of
          Left err -> assertBool "expected offending host in error" ("auth-b.example.com" `Text.isInfixOf` err)
          Right _ -> assertFailure "expected duplicate portals to fail"
    , testCase "rejects an unknown backend role" $
        assertBool
          "expected Left"
          (isLeft (decodeBackendMap "{\"tools.example.com\":{\"upstream\":\"http://tools.personal.svc.cluster.local\",\"role\":\"admin\"}}"))
    , testCase "lookup strips Host header port" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        lookupBackend "tools.example.com:443" backends @?= Just (BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend)
    , testCase "lookup can return the canonical host used for auth decisions" $ do
        backends <- assertRight (backendMapFromList [("tools.example.com", "http://tools.personal.svc.cluster.local")])
        (host, target) <- maybe (assertFailure "expected backend") pure (lookupBackendWithHost "Tools.Example.com:443" backends)
        publicHostText host @?= "tools.example.com"
        target @?= BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend
    , testCase "rejects non-object JSON" $
        assertBool "expected Left" (isLeft (decodeBackendMap "[]"))
    , testCase "rejects non-string upstreams" $
        assertBool "expected Left" (isLeft (decodeBackendMap "{\"tools.example.com\": 7}"))
    , testCase "rejects upstreams without an HTTP scheme" $
        assertBool "expected Left" (isLeft (backendMapFromList [("tools.example.com", "tools.personal")]))
    ]

backendSourceTests :: TestTree
backendSourceTests =
  testGroup
    "backend source"
    [ testCase "a route added to the mounted map is served without a restart" $ do
        file <- newIORef "{\"tools.example.com\":\"http://tools.personal.svc.cluster.local\"}"
        source <- assertRight =<< newBackendSource (readIORef file)
        let live = liveApplication source appWithBackends
            get host = runSession (request ((setPath defaultRequest "/") {requestHeaders = [(hHost, host)]})) live
        unknownRoute <- get "scenario-a.example.com"
        simpleStatus unknownRoute @?= status502
        writeIORef file "{\"tools.example.com\":\"http://tools.personal.svc.cluster.local\",\"scenario-a.example.com\":\"http://scenario-a.personal.svc.cluster.local\"}"
        refreshBackends source >>= (@?= Reloaded)
        servedRoute <- get "scenario-a.example.com"
        simpleBody servedRoute /= "no backend configured for host scenario-a.example.com" @? "the added route is still unknown"
        simpleStatus servedRoute /= status502 @? "the added route still answers 502"
    , testCase "unchanged bytes are not reloaded" $ do
        file <- newIORef "{\"tools.example.com\":\"http://tools.personal.svc.cluster.local\"}"
        source <- assertRight =<< newBackendSource (readIORef file)
        refreshBackends source >>= (@?= Unchanged)
    , testCase "a map that does not decode keeps the previous routes" $ do
        file <- newIORef "{\"tools.example.com\":\"http://tools.personal.svc.cluster.local\"}"
        source <- assertRight =<< newBackendSource (readIORef file)
        writeIORef file "[]"
        result <- refreshBackends source
        case result of
          Rejected _ -> pure ()
          other -> assertFailure ("expected Rejected, got " <> show other)
        backends <- currentBackends source
        lookupBackend "tools.example.com" backends @?= Just (BackendTarget "http://tools.personal.svc.cluster.local" ProtectedBackend)
    , testCase "a map that does not decode at startup is refused" $
        assertBool "expected Left" . isLeft =<< newBackendSource (pure "[]")
    ]

assertRight :: (HasCallStack, Show a) => Either a b -> IO b
assertRight (Left err) = assertFailure ("expected Right, got Left " <> show err)
assertRight (Right value) = pure value

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
