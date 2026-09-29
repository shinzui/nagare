module InventoryGcloudAuthSpec (inventoryGcloudAuthTests) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store.GcloudAuth
import Test.Tasty
import Test.Tasty.HUnit

inventoryGcloudAuthTests :: TestTree
inventoryGcloudAuthTests =
  testGroup
    "inventory gcloud identity"
    [ testCase "one token acquisition pins account, impersonation, and absent override settings" $ do
        calls <- newIORef []
        let run variables args = do
              modifyIORef' calls (<> [(variables, args)])
              pure (Right (response start "selected@example.invalid" "delegate@example.invalid" "token-one" []))
        session <- newGcloudSessionWith (pure start) run [("CLOUDSDK_CORE_ACCOUNT", "selected@example.invalid"), ("CLOUDSDK_CORE_LOG_HTTP", "true")] "project" >>= right
        sessionToken session >>= (@?= "token-one")
        sessionToken session >>= (@?= "token-one")
        readIORef calls >>= (\values -> length values @?= 1)
        _ <- sessionCapture session ["projects", "describe", "project"]
        values <- readIORef calls
        let pinned = fst (last values)
        lookup "CLOUDSDK_CORE_ACCOUNT" pinned @?= Just "selected@example.invalid"
        lookup "CLOUDSDK_ACTIVE_CONFIG_NAME" pinned @?= Just "selected-config"
        lookup "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT" pinned @?= Just "delegate@example.invalid"
        lookup "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" pinned @?= Just ""
        lookup "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE" pinned @?= Just ""
        lookup "CLOUDSDK_CORE_PROJECT" pinned @?= Just "project"
        lookup "CLOUDSDK_CORE_LOG_HTTP" pinned @?= Just "false"
        lookup "CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE" pinned @?= Just "https://storage.googleapis.com/storage/v1/"
    , testCase "initial helper cannot override explicit account, configuration or impersonation" $ do
        forM_ ["CLOUDSDK_CORE_ACCOUNT", "CLOUDSDK_ACTIVE_CONFIG_NAME", "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT"] $ \key -> do
          result <- newGcloudSessionWith (pure start) (\_ _ -> pure (Right (response start "selected@example.invalid" "delegate@example.invalid" "private-token" []))) [(key, "different")] "project"
          assertBool "explicit selection ignored" (isLeft result)
    , testCase "concurrent expiry performs one refresh with the original identity" $ do
        clock <- newIORef start
        calls <- newIORef (0 :: Int)
        let run variables _ = do
              n <- atomicModifyIORef' calls (\i -> (i + 1, i + 1))
              when (n > 1) $ do
                lookup "CLOUDSDK_CORE_ACCOUNT" variables @?= Just "selected@example.invalid"
                lookup "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT" variables @?= Just "delegate@example.invalid"
              now <- readIORef clock
              pure (Right (response now "selected@example.invalid" "delegate@example.invalid" (if n == 1 then "old" else "new") []))
        session <- newGcloudSessionWith (readIORef clock) run [] "project" >>= right
        writeIORef clock (addUTCTime 3550 start)
        mapConcurrently (const (sessionToken session)) [1 .. 16 :: Int] >>= (@?= replicate 16 "new")
        readIORef calls >>= (@?= 2)
    , testCase "refresh cannot switch account or impersonated identity" $ do
        forM_ [("other@example.invalid", "delegate@example.invalid"), ("selected@example.invalid", "other@example.invalid")] $ \(account, delegate) -> do
          clock <- newIORef start
          calls <- newIORef (0 :: Int)
          let run _ _ = do
                n <- atomicModifyIORef' calls (\i -> (i + 1, i + 1))
                now <- readIORef clock
                pure (Right (if n == 1 then response now "selected@example.invalid" "delegate@example.invalid" "first" [] else response now account delegate "private-token" []))
          session <- newGcloudSessionWith (readIORef clock) run [] "project" >>= right
          writeIORef clock (addUTCTime 3550 start)
          result <- try (sessionToken session) :: IO (Either IOException T.Text)
          assertBool "foreign token accepted" (isLeft result)
          assertBool "private token leaked" (not ("private-token" `T.isInfixOf` T.pack (show result)))
    , testCase "failed refresh is shared by waiting callers and stays failed for the session" $ do
        forM_ [False, True] $ \throws -> do
          clock <- newIORef start
          calls <- newIORef (0 :: Int)
          let run _ _ = do
                n <- atomicModifyIORef' calls (\i -> (i + 1, i + 1))
                if n == 1
                  then pure (Right (response start "selected@example.invalid" "" "old-private-token" []))
                  else if throws then ioError (userError "private-helper-error") else pure (Left "private-helper-error")
          session <- newGcloudSessionWith (readIORef clock) run [] "project" >>= right
          writeIORef clock (addUTCTime 3550 start)
          results <- mapConcurrently (const (try (sessionToken session) :: IO (Either IOException T.Text))) [1 .. 16 :: Int]
          assertBool "failed refresh returned a token" (all isLeft results)
          assertBool "helper diagnostic leaked" (not ("private" `T.isInfixOf` T.pack (show results)))
          readIORef calls >>= (@?= 2)
          -- A new command must reacquire credentials; clock rollback must not
          -- resurrect the old token in this failed session.
          writeIORef clock start
          result <- try (sessionToken session) :: IO (Either IOException T.Text)
          assertBool "failed session resurrected its old token" (isLeft result)
          readIORef calls >>= (@?= 2)
    , testCase "malformed, expired, wrong-project and unsupported overrides refuse" $ do
        let valid = response start "selected@example.invalid" "" "private-token" []
            candidates =
              ["{}", "private-token", T.replace "project" "foreign" valid, response (addUTCTime (-3590) start) "selected@example.invalid" "" "private-token" []]
                <> [response start "selected@example.invalid" "" "private-token" [(key, "private-path")] | key <- ["credential_file_override", "access_token_file", "access_token"]]
        forM_ candidates $ \value -> do
          result <- newGcloudSessionWith (pure start) (\_ _ -> pure (Right value)) [] "project"
          case result of
            Right _ -> assertFailure "invalid credential context accepted"
            Left reason -> assertBool "credential output leaked" (not ("private" `T.isInfixOf` reason))
    ]
  where
    right = either (assertFailure . T.unpack) pure

start :: UTCTime
start = UTCTime (fromGregorian 2026 9 29) 0

response :: UTCTime -> T.Text -> T.Text -> T.Text -> [(T.Text, T.Text)] -> T.Text
response now account delegate token extra =
  TE.decodeUtf8
    ( LBS.toStrict
        ( encode
            ( object
                [ "credential" .= object ["access_token" .= token, "token_expiry" .= addUTCTime 3600 now]
                , "configuration"
                    .= object
                      [ "active_configuration" .= ("selected-config" :: T.Text)
                      , "properties"
                          .= object
                            [ "core" .= object ["account" .= account, "project" .= ("project" :: T.Text)]
                            , "auth" .= (Map.fromList (("impersonate_service_account", delegate) : extra))
                            ]
                      ]
                ]
            )
        )
    )
