module ShomeiUserSpec (shomeiUserTests) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Nagare.Access.ShomeiUser
import Nagare.Dsl.Prelude
import Test.Tasty
import Test.Tasty.HUnit

shomeiUserTests :: TestTree
shomeiUserTests =
  testGroup
    "Nagare.Access.ShomeiUser"
    [ testCase "a Shomei user id passes through; an email is normalized as Shomei stores it" $ do
        parseUserRef " user_01h455vb4pex5vsknk084sn02q " @?= Right (UserById "user_01h455vb4pex5vsknk084sn02q")
        parseUserRef "Nadeem@Example.COM" @?= Right (UserByEmail "nadeem@example.com")
    , testCase "anything that cannot be a Shomei subject refuses"
        $ forM_
          [ "alice"
          , ""
          , "user_01h455vb4pex5vsknk084sn02"
          , "user_81h455vb4pex5vsknk084sn02q"
          , "user_01H455VB4PEX5VSKNK084SN02Q"
          , "user_01h455vb4pex5vsknk084sn0iq"
          , "01890a5d-ac96-774b-bcce-b302099a8057"
          , "a@b@example.com"
          , "@example.com"
          , "alice@localhost"
          , "al ice@example.com"
          ]
        $ \raw -> assertBool (show raw <> " accepted") (isLeft (parseUserRef raw))
    , testCase "a stored UUID renders as its TypeID (typeid spec vectors)" $ do
        shomeiUserIdFromUuid "01890a5d-ac96-774b-bcce-b302099a8057" @?= Right "user_01h455vb4pex5vsknk084sn02q"
        shomeiUserIdFromUuid "00000000-0000-0000-0000-000000000000" @?= Right "user_00000000000000000000000000"
        shomeiUserIdFromUuid "ffffffff-ffff-ffff-ffff-ffffffffffff" @?= Right "user_7zzzzzzzzzzzzzzzzzzzzzzzzz"
        assertBool "malformed UUID accepted" (isLeft (shomeiUserIdFromUuid "01890a5dac96774bbcceb302099a8057"))
    , testCase "an email resolves only to exactly one Shomei user" $ do
        parseEmailLookup "a@example.com" "01890a5d-ac96-774b-bcce-b302099a8057\n" @?= Right "user_01h455vb4pex5vsknk084sn02q"
        parseEmailLookup "a@example.com" ""
          @?= Left "no Shomei user has the email a@example.com; the person signs up first, then grant again"
        parseEmailLookup "a@example.com" "01890a5d-ac96-774b-bcce-b302099a8057\n00000000-0000-0000-0000-000000000000\n"
          @?= Left "a@example.com matches 2 Shomei users; grant one by its user_… id"
    , testCase "the email reaches psql as a positional argument, never as SQL" $ do
        let args = emailLookupArgs "ctx" "o'brien@example.com"
        take 2 args @?= ["--context", "ctx"]
        last args @?= "o'brien@example.com"
        assertBool "email embedded in the script" (not (any (\arg -> "o'brien" `isInfixOf` arg) (init args)))
        assertBool "lookup is not parameterized" (":'email'" `isInfixOf` emailLookupSql)
    ]
  where
    isLeft = either (const True) (const False)
