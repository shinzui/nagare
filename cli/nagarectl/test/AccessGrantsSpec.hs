module AccessGrantsSpec (accessGrantsTests) where

import Control.Monad (forM)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Access.Grants
import Nagare.Dsl.Prelude
import ShomeiUserSpec (shomeiUserTests)
import Test.Tasty
import Test.Tasty.HUnit

accessGrantsTests :: TestTree
accessGrantsTests =
  testGroup
    "Nagare.Access.Grants"
    [ testCase "accessTuple grants app viewer to a shomei user and canonicalizes host" $
        accessTuple "Tools.Example.com." "alice"
          @?= TupleWire
            { object = ObjectRefWire "app" "tools.example.com"
            , relation = "viewer"
            , subject = SubjectIdWire (ObjectRefWire "user" "alice")
            , caveat = Nothing
            }
    , testCase "access tuple JSON matches en-servant byte for byte" $
        encode (accessTuple "Tools.Example.com." "alice")
          @?= "{\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}"
    , testCase "team membership and team grant JSON match en-servant byte for byte (EP-187)" $ do
        encode (teamMemberTuple "engineering" "alice")
          @?= "{\"object\":{\"objectType\":\"group\",\"objectId\":\"engineering\"},\"relation\":\"member\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null}"
        encode (teamAccessTuple "Tools.Example.com." "engineering")
          @?= "{\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"set\",\"objectType\":\"group\",\"objectId\":\"engineering\",\"relation\":\"member\"},\"caveat\":null}"
    , testCase "listing asks for stored relationships at a fully consistent snapshot, anchored on the object" $ do
        encode (hostGrantsFilter "Tools.Example.com.")
          @?= "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"filter\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\",\"relation\":\"viewer\"}}"
        encode (teamMembersFilter "engineering")
          @?= "{\"consistency\":{\"mode\":\"fullyConsistent\"},\"filter\":{\"objectType\":\"group\",\"objectId\":\"engineering\",\"relation\":\"member\"}}"
    , testCase "a page continues from the server's opaque cursor, URL-encoded" $ do
        relationshipQueryPath Nothing @?= "/v1/relationships/query?first=100"
        relationshipQueryPath (Just "a/b+c=") @?= "/v1/relationships/query?first=100&after=a%2Fb%2Bc%3D"
    , testCase "a relationship page decodes en's Relay connection" $
        eitherDecode relayPageJson
          @?= Right
            RelationshipPage
              { nodes = [accessTuple "tools.example.com" "alice"]
              , hasNextPage = True
              , endCursor = Just "c1"
              }
    , testCase "direct users and team usersets are reported apart; anything else verbatim, never flattened" $
        hostGrantsOf
          "tools.example.com"
          [ accessTuple "tools.example.com" "alice"
          , teamAccessTuple "tools.example.com" "engineering"
          , accessTuple "tools.example.com" "bob"
          , TupleWire (ObjectRefWire "app" "tools.example.com") "viewer" (SubjectWildcardWire "user") Nothing
          , TupleWire (ObjectRefWire "app" "tools.example.com") "viewer" (SubjectIdWire (ObjectRefWire "user" "carol")) (Just ())
          , accessTuple "other.example.com" "dave"
          ]
          @?= HostGrants
            { users = ["alice", "bob"]
            , teams = ["engineering"]
            , other = ["user:*", "app:tools.example.com#viewer@user:carol (caveated)", "app:other.example.com#viewer@user:dave"]
            }
    , testCase "a team's members are its direct user subjects" $
        teamMembersOf "engineering" [teamMemberTuple "engineering" "alice", teamMemberTuple "finance" "bob", teamMemberTuple "engineering" "carol"]
          @?= (["alice", "carol"], ["group:finance#member@user:bob"])
    , testCase "a listing follows endCursor page by page and stops on the exhausted page" $ do
        asked <- newIORef []
        let page1 = RelationshipPage [accessTuple "h" "alice"] True (Just "c1")
            page2 = RelationshipPage [accessTuple "h" "bob"] True (Just "c2")
            page3 = RelationshipPage [accessTuple "h" "carol"] False Nothing
            fetch cursor = do
              modifyIORef' asked (<> [cursor])
              pure (case cursor of Nothing -> page1; Just "c1" -> page2; _ -> page3)
        listed <- listRelationships fetch
        listed @?= Right [accessTuple "h" "alice", accessTuple "h" "bob", accessTuple "h" "carol"]
        readIORef asked >>= (@?= [Nothing, Just "c1", Just "c2"])
    , testCase "a repeated cursor, a missing cursor, or more pages than the cap is an incomplete listing, never a partial one" $ do
        repeated <- listRelationships (\_ -> pure (RelationshipPage [accessTuple "h" "alice"] True (Just "same")))
        assertBool "repeated cursor accepted" (either (T.isInfixOf "repeated") (const False) repeated)
        missing <- listRelationships (\_ -> pure (RelationshipPage [accessTuple "h" "alice"] True Nothing))
        assertBool "missing cursor accepted" (either (T.isInfixOf "without a cursor") (const False) missing)
        pages <- newIORef (0 :: Int)
        capped <-
          listRelationships
            ( \_ -> do
                modifyIORef' pages (+ 1)
                n <- readIORef pages
                pure (RelationshipPage [accessTuple "h" (T.pack (show n))] True (Just (T.pack (show n))))
            )
        assertBool "unbounded listing accepted" (either (T.isInfixOf "pages") (const False) capped)
        readIORef pages >>= (@?= maxListedPages)
    , testCase "a complete listing is empty only when the server returned no relationships" $ do
        listed <- forM [RelationshipPage [] False Nothing] (\page -> listRelationships (\_ -> pure page))
        listed @?= [Right []]
    , shomeiUserTests
    ]

relayPageJson :: ByteString
relayPageJson =
  "{\"edges\":[{\"node\":{\"object\":{\"objectType\":\"app\",\"objectId\":\"tools.example.com\"},\"relation\":\"viewer\",\"subject\":{\"kind\":\"id\",\"objectType\":\"user\",\"objectId\":\"alice\"},\"caveat\":null},\"cursor\":\"c1\"}],"
    <> "\"pageInfo\":{\"hasNextPage\":true,\"hasPreviousPage\":false,\"startCursor\":\"c1\",\"endCursor\":\"c1\"}}"

_unusedText :: Text
_unusedText = ""
