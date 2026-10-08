-- | F86: an accepted database StatefulSet keeps its engine, and PostgreSQL its
-- major version, in place; a change is a side-by-side migration.
module InventoryDatabaseEngineSpec (inventoryDatabaseEngineTests) where

import Data.Aeson (Key, Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DatabaseEngine (databaseEngineUnchanged)
import Test.Tasty
import Test.Tasty.HUnit

inventoryDatabaseEngineTests :: TestTree
inventoryDatabaseEngineTests =
  testGroup
    "database engine in place (F86)"
    [ testCase "the same PostgreSQL image is unchanged" $
        databaseEngineUnchanged (database "postgres" "postgres:17") (database "postgres" "postgres:17") @?= Right ()
    , testCase "a PostgreSQL minor update within one major is allowed" $
        databaseEngineUnchanged (database "postgres" "postgres:17") (database "postgres" "postgres:17.6-alpine") @?= Right ()
    , testCase "a PostgreSQL major change refuses" $
        assertBool "17 to 18 was allowed" (isLeft (databaseEngineUnchanged (database "postgres" "postgres:17") (database "postgres" "postgres:18")))
    , testCase "a PostgreSQL major change behind a variant suffix refuses" $
        assertBool "17-alpine to 18-alpine was allowed" (isLeft (databaseEngineUnchanged (database "postgres" "postgres:17-alpine") (database "postgres" "postgres:18-alpine")))
    , testCase "a PostgreSQL tag whose major cannot be read refuses a change" $
        assertBool "latest to 17 was allowed" (isLeft (databaseEngineUnchanged (database "postgres" "postgres:latest") (database "postgres" "postgres:17")))
    , testCase "an engine change on the same StatefulSet refuses" $
        assertBool "postgres to redis was allowed" (isLeft (databaseEngineUnchanged (database "postgres" "postgres:17") (database "redis" "redis:8")))
    , testCase "a Redis version change stays an in-place update" $
        databaseEngineUnchanged (database "redis" "redis:7") (database "redis" "redis:8") @?= Right ()
    , testCase "a database's other labelled members, such as its backup CronJob, are not checked" $
        databaseEngineUnchanged backupCronJob backupCronJob @?= Right ()
    , testCase "a StatefulSet that is not a managed database is not checked" $
        databaseEngineUnchanged (statefulSet Nothing "nats:2") (statefulSet Nothing "nats:3") @?= Right ()
    ]

database :: Text -> Text -> ByteString
database engine = statefulSet (Just engine)

-- A managed database's container is named after its engine label.
statefulSet :: Maybe Text -> Text -> ByteString
statefulSet engine image =
  BL.toStrict
    ( encode
        ( object
            [ "apiVersion" .= ("apps/v1" :: Text)
            , "kind" .= ("StatefulSet" :: Text)
            , "metadata" .= object ["name" .= ("pg" :: Text), "labels" .= object labels]
            , "spec"
                .= object
                  [ "template"
                      .= object
                        [ "spec"
                            .= object
                              [ "containers"
                                  .= [ object ["name" .= ("sidecar" :: Text), "image" .= ("busybox:1" :: Text)]
                                     , object ["name" .= maybe "nats" id engine, "image" .= image]
                                     ]
                              ]
                        ]
                  ]
            ]
        )
    )
  where
    labels :: [(Key, Value)]
    labels = maybe [] (\token -> ["nagare.dev/engine" .= token, "nagare.dev/database" .= ("pg" :: Text)]) engine

backupCronJob :: ByteString
backupCronJob =
  BL.toStrict
    ( encode
        ( object
            [ "apiVersion" .= ("batch/v1" :: Text)
            , "kind" .= ("CronJob" :: Text)
            , "metadata" .= object ["name" .= ("pg-backup" :: Text), "labels" .= object ["nagare.dev/engine" .= ("postgres" :: Text)]]
            , "spec" .= object ["schedule" .= ("0 * * * *" :: Text)]
            ]
        )
    )
