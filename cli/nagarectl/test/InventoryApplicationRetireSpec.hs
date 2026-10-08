-- | F87: an application drops one of its databases through a reviewed
-- retirement that retains every member.
module InventoryApplicationRetireSpec (inventoryApplicationRetireTests) where

import Data.Either (isLeft)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Application (applicationDatabaseRetirements)
import Nagare.Resource.Types (ResourceId, mkResourceId)
import Test.Tasty
import Test.Tasty.HUnit

inventoryApplicationRetireTests :: TestTree
inventoryApplicationRetireTests =
  testGroup
    "application database retirement (F87)"
    [ testCase "a database the config no longer declares retires all of its accepted members" $
        applicationDatabaseRetirements accepted desired ["upg2-pg"] @?= Right oldMembers
    , testCase "no names retires nothing" $
        applicationDatabaseRetirements accepted desired [] @?= Right []
    , testCase "a database the config still declares refuses" $
        assertBool "a declared database retired" (isLeft (applicationDatabaseRetirements accepted desired ["upg2-pg18"]))
    , testCase "a name with no accepted members refuses" $
        assertBool "an unknown database retired" (isLeft (applicationDatabaseRetirements accepted desired ["upg2-pg17"]))
    , testCase "a repeated name refuses" $
        assertBool "a repeated name retired" (isLeft (applicationDatabaseRetirements accepted desired ["upg2-pg", "upg2-pg"]))
    , testCase "a name only shares a prefix with another member's key" $
        applicationDatabaseRetirements (accepted <> [member "upg2-pg-cache" "statefulset"]) desired ["upg2-pg"] @?= Right oldMembers
    ]
  where
    oldMembers = map (member "upg2-pg") ["statefulset", "service", "pvc", "secret", "backup"]
    newMembers = map (member "upg2-pg18") ["statefulset", "service", "pvc", "secret", "backup"]
    web = member "web" "ksvc"
    accepted = web : oldMembers <> newMembers
    desired = web : newMembers

member :: Text -> Text -> ResourceId
member key role = either (error . show) id (mkResourceId ("application:upg2-app/" <> key <> "/" <> role))
