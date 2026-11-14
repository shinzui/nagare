-- | EP-202: an app database server's access management, a ClickHouse login
-- verdict, and an app database's generated credential Secret.
module AppDatabaseCredentialSpec
  ( appDatabaseCredentialTests
  )
where

import AppDatabaseSpec (alpha, chServer)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.AppDatabase (AppDatabaseRole (RuntimeRole))
import Nagare.Dsl.Database (Engine (ClickHouse))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.AppDatabaseRuntime (clickHouseLoginVerdict)
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, materializeCredential)
import Nagare.Resource.AppDatabase (appDatabaseCredentialTemplate)
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

appDatabaseCredentialTests :: TestTree
appDatabaseCredentialTests =
  testGroup
    "AppDatabase credentials"
    [ testCase "the ClickHouse server enables SQL access management" $ do
        let (_, native) = chServer
        assertBool "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT is set" $
          any (T.isInfixOf "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT" . TE.decodeUtf8 . snd) (Map.elems native)
    , testCase "a ClickHouse login proves the password even before the default database exists" $ do
        clickHouseLoginVerdict ExitSuccess "" @?= Right True
        clickHouseLoginVerdict (ExitFailure 81) "Code: 81. DB::Exception: Database beta does not exist. (UNKNOWN_DATABASE)" @?= Right True
        clickHouseLoginVerdict (ExitFailure 4) "Code: 516. Authentication failed (AUTHENTICATION_FAILED)" @?= Right False
        assertBool "an unknown failure is not a verdict" (isLeft (clickHouseLoginVerdict (ExitFailure 210) "Connection refused"))
    , testGroup
        "credential template"
        [ testCase "a runtime Secret is filled with its own user, database and URL path" $ do
            let template = appDatabaseCredentialTemplate (alpha ClickHouse) RuntimeRole
            native <- either (fail . T.unpack) (pure . TE.decodeUtf8) (canonicalValue template)
            filled <- materializeCredential native >>= either (fail . T.unpack) pure
            value <- either fail pure (eitherDecodeStrict (TE.encodeUtf8 filled))
            fields <- case value of
              Object root | Just (Object entries) <- KM.lookup "data" root -> pure entries
              _ -> fail "filled Secret has no data"
            let decoded key = case KM.lookup key fields of
                  Just (String encoded) -> either (const "") id (b64decode encoded)
                  _ -> ""
            decoded "CLICKHOUSE_USER" @?= "alpha_ch_runtime"
            decoded "CLICKHOUSE_DB" @?= "alpha"
            T.length (decoded "CLICKHOUSE_PASSWORD") @?= 48
            assertBool "URL path selects the database" ("@smoke-ch.personal.svc.cluster.local:9000/alpha" `T.isSuffixOf` decoded "CLICKHOUSE_URL")
            credentialDataMatches template value @?= True
            credentialDataMatches template template @?= False
        ]
    ]
