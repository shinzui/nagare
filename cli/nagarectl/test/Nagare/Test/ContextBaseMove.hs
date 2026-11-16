-- | EP-246 D1: the host map of a move to a new base domain, over a fixture holding every web kind,
-- and each refusal naming its host.
module Nagare.Test.ContextBaseMove
  ( contextBaseMoveTests
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Text qualified as T
import Nagare.Access.ShomeiMove (parseOAuthClients, parsePasskeyHolders)
import Nagare.Context.BaseMove
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory (BackendRole (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

old, new :: Text
old = "labs.example.net"
new = "examplelabs.com"

-- | Every kind of web name a context serves.
everyKind :: HostFacts
everyKind =
  HostFacts
    { services = [("team", "kansoku"), ("team", "docs"), ("personal", "nagared")]
    , mappings = [old, "hooks." <> old, "kansoku." <> old, "docs.team." <> old, "pr-7.site.preview." <> old]
    , backends =
        [ ("auth." <> old, PortalBackend)
        , ("admin." <> old, ApiBackend)
        , (old, ProtectedBackend)
        , ("docs.team." <> old, ProtectedBackend)
        ]
    , userGrants = [("docs.team." <> old, "user_b"), ("docs.team." <> old, "user_a"), (old, "user_a")]
    , teamGrants = [("docs.team." <> old, "eng")]
    }

contextBaseMoveTests :: TestTree
contextBaseMoveTests =
  testGroup
    "context move to a new base domain (EP-246 D1)"
    [ testCase "every web kind gets its name under the new base" $ do
        hosts <- either (assertFailure . show) pure (movedHosts old new everyKind)
        sort [(h ^. #oldName, h ^. #newName, h ^. #kind) | h <- hosts]
          @?= sort
            [ (old, new, ApexHost)
            , ("auth." <> old, "auth." <> new, AuthPortalHost)
            , ("admin." <> old, "admin." <> new, AdminApiHost)
            , ("hooks." <> old, "hooks." <> new, HooksHost)
            , ("kansoku." <> old, "kansoku." <> new, CustomHost)
            , ("kansoku.team." <> old, "kansoku-team." <> new, DefaultHost)
            , ("docs.team." <> old, "docs-team." <> new, DefaultHost)
            , ("nagared.personal." <> old, "nagared-personal." <> new, DefaultHost)
            , ("pr-7.site.preview." <> old, "pr-7-site-preview." <> new, PreviewHost)
            ]
    , testCase "a protected host carries its direct and team grants; a public one carries none" $ do
        hosts <- either (assertFailure . show) pure (movedHosts old new everyKind)
        let find name = filter ((== name) . (^. #oldName)) hosts
        [(h ^. #protected, h ^. #users, h ^. #teams) | h <- find ("docs.team." <> old)] @?= [(True, ["user_a", "user_b"], ["eng"])]
        [(h ^. #protected, h ^. #users) | h <- find old] @?= [(True, ["user_a"])]
        [(h ^. #protected, h ^. #users) | h <- find ("kansoku." <> old)] @?= [(False, [])]
    , testCase "a name outside the old base is refused by name" $
        refusedNaming "other.example.org" (everyKind & #mappings %~ ("other.example.org" :))
    , testCase "a custom domain two labels below the base is refused by name" $
        refusedNaming ("a.b." <> old) (everyKind & #mappings %~ (("a.b." <> old) :))
    , testCase "two names that map to one are refused, naming both" $ do
        let facts = everyKind & #services %~ (("c", "a-b") :) & #mappings %~ (("a.b-c." <> old) :)
        -- a-b in c and a in b-c both flatten to a-b-c
        let crossed = facts & #services %~ (("b-c", "a") :)
        case movedHosts old new crossed of
          Left reasons ->
            assertBool (show reasons) (any (\r -> "a-b.c." `T.isInfixOf` r && "a.b-c." `T.isInfixOf` r) reasons)
          Right _ -> assertFailure "accepted a collision"
    , testCase "a flattened name longer than one DNS label is refused" $
        refusedNaming (T.replicate 40 "n" <> "." <> T.replicate 30 "s" <> "." <> old) (everyKind & #services %~ ((T.replicate 30 "s", T.replicate 40 "n") :))
    , testCase "a name that would spell a platform host is refused" $ do
        refusedNaming ("a.b-nagare-system." <> old) (everyKind & #services %~ (("b-nagare-system", "a") :))
        let customAuth = everyKind & #backends %~ filter ((/= PortalBackend) . snd) & #mappings %~ (("auth." <> old) :)
        refusedNaming ("auth." <> old) customAuth
    , testCase "the new base must differ from the old and must not nest with it" $ do
        isLeft (movedHosts old old everyKind) @?= True
        isLeft (movedHosts old ("x." <> old) everyKind) @?= True
        isLeft (movedHosts old "example.net" everyKind) @?= True
    , testCase "En and the ledger agreeing on a host's grants is no drift; each difference is named" $ do
        hosts <- either (assertFailure . show) pure (movedHosts old new everyKind)
        let docs = [h | h <- hosts, h ^. #oldName == "docs.team." <> old]
        map (`grantDrift` (["user_b", "user_a"], ["eng"])) docs @?= [[]]
        map (length . (`grantDrift` (["user_a", "user_c"], []))) docs @?= [3]
    , testCase "the list names every changed URL, the OAuth clients, the passkey holders and the webhooks" $ do
        hosts <- either (assertFailure . show) pure (movedHosts old new everyKind)
        let text =
              renderManifest
                ( MoveManifest
                    old
                    new
                    hosts
                    [OAuthClient "oauthclient_1" "wiki" ["https://wiki." <> old <> "/callback"]]
                    [PasskeyHolder "user_a" "a@example.com" 1 False]
                )
        forM_ (map (^. #oldName) hosts <> ["wiki", "a@example.com", "https://hooks." <> new]) $ \needle ->
          assertBool (T.unpack needle) (needle `T.isInfixOf` text)
    , testCase "only OAuth redirect URIs on the old base are listed, and a client with none is left out" $ do
        let rows =
              "[{\"clientId\":\"oauthclient_1\",\"displayName\":\"wiki\",\"redirectUris\":[\"https://wiki.labs.example.net/cb\",\"https://elsewhere.org/cb\"]},"
                <> "{\"clientId\":\"oauthclient_2\",\"displayName\":\"cli\",\"redirectUris\":[\"http://127.0.0.1:8080/cb\"]},"
                <> "{\"clientId\":\"oauthclient_3\",\"displayName\":\"apex\",\"redirectUris\":[\"https://user@LABS.example.net:443/cb\"]},"
                <> "{\"clientId\":\"oauthclient_4\",\"displayName\":\"lookalike\",\"redirectUris\":[\"https://evillabs.example.net/cb\"]}]"
        parseOAuthClients old rows
          @?= Right
            [ OAuthClient "oauthclient_1" "wiki" ["https://wiki.labs.example.net/cb"]
            , OAuthClient "oauthclient_3" "apex" ["https://user@LABS.example.net:443/cb"]
            ]
        parseOAuthClients old "[]\n" @?= Right []
    , testCase "passkey holders carry their Shomei user id and whether TOTP still covers them" $ do
        let rows = "[{\"userId\":\"0190a2b4-0000-7000-8000-000000000001\",\"email\":\"a@example.com\",\"passkeys\":2,\"totp\":true}]"
        fmap (map (\p -> (p ^. #email, p ^. #passkeys, p ^. #hasTotp, "user_" `T.isPrefixOf` (p ^. #userId)))) (parsePasskeyHolders rows)
          @?= Right [("a@example.com", 2, True, True)]
        isLeft (parsePasskeyHolders "[{\"userId\":\"not-a-uuid\",\"email\":\"a@example.com\",\"passkeys\":1,\"totp\":false}]") @?= True
    ]

refusedNaming :: Text -> HostFacts -> IO ()
refusedNaming host facts = case movedHosts old new facts of
  Left reasons -> assertBool (show reasons) (any (host `T.isInfixOf`) reasons)
  Right _ -> assertFailure ("accepted " <> T.unpack host)
