-- | EP-259 M1: an app database binding names the app database and, optionally,
-- the variable that receives its connection URL, on a Deployment, a Worker and
-- a Task alike.
module AppDatabaseBindingSpec (appDatabaseBindingTests) where

import Data.Aeson (Value (..), decodeStrict, encode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Config (encodeDeployment, encodeTask, encodeWorker)
import Nagare.Dsl.Load (decodeDeployment, decodeTask, decodeWorker)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Presets (webService)
import Nagare.Dsl.Task (mkTask, scheduledTask)
import Nagare.Dsl.Task.Render (renderTask)
import Nagare.Dsl.Types
import Nagare.Dsl.Worker (webWorker)
import Test.Tasty
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit

appDatabaseBindingTests :: TestTree
appDatabaseBindingTests =
  testGroup
    "Nagare.Dsl app database bindings (EP-259)"
    [ testCase "bindings round-trip on a Deployment, a Worker and a Task; urlVariable is emitted only when set" $ do
        let dep = known (webService "notes" "registry.example.com/notes") & #appDatabases .~ [plain, named]
            worker = either error id (webWorker "notes-worker" "registry.example.com/notes") & #appDatabases .~ [plain]
            task = migrate & #appDatabases .~ [named]
        decodeDeployment (toStrict (encodeDeployment dep)) @?= Right dep
        decodeWorker (toStrict (encodeWorker worker)) @?= Right worker
        decodeTask (toStrict (encodeTask task)) @?= Right task
        bindingsJson (toStrict (encodeDeployment dep))
          @?= Just
            [ Object (KeyMap.fromList [("name", String "notes-pg")])
            , Object (KeyMap.fromList [("name", String "notes-pg"), ("urlVariable", String "NOTES_MAINTENANCE_DATABASE_URL")])
            ]
        -- A task without bindings keeps its bytes: no key at all.
        assertBool "an unbound task emits appDatabases" (not ("appDatabases" `Text.isInfixOf` TE.decodeUtf8 (toStrict (encodeTask migrate))))
    , testCase "the bare-name form and a SecretKeyRef env entry are refused at load" $ do
        let worker = either error id (webWorker "notes-worker" "registry.example.com/notes") & #appDatabases .~ [plain]
            bare = withField "appDatabases" (toJSON ["notes-pg" :: Text]) (toStrict (encodeWorker worker))
        assertBool "a bare app database name decoded" (isLeft' (decodeWorker bare))
        let keyed = worker & #env .~ Map.singleton (known (mkEnvName "NOTES_URL")) (runtimeScoped (EnvSecretKeyRef (known (mkSecretName "notes-pg-runtime")) (known (mkEnvName "DATABASE_URL"))))
        case decodeWorker (toStrict (encodeWorker keyed)) of
          Left err -> assertBool (show err) ("urlVariable" `Text.isInfixOf` Text.pack (show err))
          Right _ -> assertFailure "a configuration wrote a SecretKeyRef env entry"
    , testCase "mkTask refuses a urlVariable its env defines, a repeated or reserved urlVariable, and an app database bound twice without one" $ do
        let other = AppDatabaseBinding (known (mkAppDatabaseName "audit-pg")) (Just (known (mkEnvName "NOTES_MAINTENANCE_DATABASE_URL")))
            reserved = AppDatabaseBinding (known (mkAppDatabaseName "notes-pg")) (Just (known (mkEnvName "NAGARE_DATABASE_URL")))
            defined = migrate & #env .~ Map.singleton (known (mkEnvName "NOTES_MAINTENANCE_DATABASE_URL")) (runtimeScoped (EnvLiteral "x"))
        refused "already defined" (mkTask (defined & #appDatabases .~ [named]))
        refused "same urlVariable" (mkTask (migrate & #appDatabases .~ [named, other]))
        refused "reserved NAGARE_" (mkTask (migrate & #appDatabases .~ [reserved]))
        refused "bound twice" (mkTask (migrate & #appDatabases .~ [plain, plain]))
        -- One app database under a fixed set and a named variable, or under two names, is accepted.
        assertBool "a named repeat was refused" (isRight' (mkTask (migrate & #appDatabases .~ [plain, named])))
    , goldenVsString
        "a task env entry reading another Secret key renders that key"
        "test/golden/task-url-variable.cronjob.yaml"
        ( pure
            ( fromStrict
                ( renderTask
                    ( migrate
                        & #env
                        .~ Map.singleton
                          (known (mkEnvName "NOTES_MAINTENANCE_DATABASE_URL"))
                          (runtimeScoped (EnvSecretKeyRef (known (mkSecretName "notes-pg-migration")) (known (mkEnvName "DATABASE_URL"))))
                    )
                )
            )
        )
    ]
  where
    plain = appDatabaseBinding (known (mkAppDatabaseName "notes-pg"))
    named = AppDatabaseBinding (known (mkAppDatabaseName "notes-pg")) (Just (known (mkEnvName "NOTES_MAINTENANCE_DATABASE_URL")))
    migrate = known (scheduledTask "notes-migrate" "0 3 * * *" "registry.example.com/notes" "migrate")
    refused needle = \case
      Left reason -> assertBool (Text.unpack reason) (needle `Text.isInfixOf` reason)
      Right _ -> assertFailure ("accepted; expected a refusal mentioning " <> Text.unpack needle)

-- | The decoded @appDatabases@ array of an encoded workload.
bindingsJson :: ByteString -> Maybe [Value]
bindingsJson bytes = case decodeStrict bytes of
  Just (Object root) | Just (Array items) <- KeyMap.lookup "appDatabases" root -> Just (toList items)
  _ -> Nothing

-- | Replace one top-level field of an encoded document.
withField :: Text -> Value -> ByteString -> ByteString
withField key value bytes = case decodeStrict bytes of
  Just (Object root) -> toStrict (encode (Object (KeyMap.insert (Key.fromText key) value root)))
  _ -> error "not an object"

known :: (Show e) => Either e a -> a
known = either (error . show) id

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)

isRight' :: Either a b -> Bool
isRight' = not . isLeft'
