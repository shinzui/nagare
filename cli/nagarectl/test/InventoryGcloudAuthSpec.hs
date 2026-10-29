module InventoryGcloudAuthSpec (inventoryGcloudAuthTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store.Counters (collectCommandTrace)
import Nagare.Inventory.Store.GcloudAuth
import Nagare.Inventory.Store.ProjectNumbers
import Nagare.Inventory.Store.Remote (provenOwnership)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
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
        (_, traced) <- collectCommandTrace $ do
          session <- newGcloudSessionWith (readIORef clock) run [] "project" >>= right
          writeIORef clock (addUTCTime 3550 start)
          mapConcurrently (const (sessionToken session)) [1 .. 16 :: Int] >>= (@?= replicate 16 "new")
        readIORef calls >>= (@?= 2)
        -- EP-221: each helper subprocess is one traced credential phase.
        Map.map fst (traced ^. #phases) @?= Map.fromList [("gcloud credential helper", 2)]
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
    , testCase "a missing or expired gcloud login is its own reason; other failures keep their first line (F107)" $ do
        let failed stderrText = "gcloud credential or ownership command failed or timed out\n" <> stderrText
            session stderrText = newGcloudSessionWith (pure start) (\_ _ -> pure (Left (failed stderrText))) [] "project"
            reasonOf = either id (const "accepted")
        forM_ [noAccountStderr, refreshStderr] $ \stderrText ->
          (reasonOf <$> session stderrText) >>= (@?= gcloudLoginRequired)
        (reasonOf <$> session "ERROR: (gcloud.config.config-helper) network unreachable")
          >>= (@?= "gcloud credential or ownership command failed or timed out")
        assertBool "the login reason names gcloud auth login" ("gcloud auth login" `T.isInfixOf` gcloudLoginRequired)
    , testCase "the bucket and project ownership reads overlap, and both must answer and agree (EP-221)" $ do
        -- Each read waits until both have started: in a serial pair the first
        -- read answers nothing and is retried, so it takes three reads.
        arrived <- newIORef (0 :: Int)
        let meeting _ = do
              atomicModifyIORef' arrived (\n -> (n + 1, ()))
              met <- timeout 2000000 (let wait = readIORef arrived >>= \n -> unless (n >= 2) (threadDelay 1000 >> wait) in wait)
              pure ("12345" <$ met)
        provenOwnership noProjectNumbers (const (pure ())) meeting "bucket" "project" >>= (@?= Right ())
        readIORef arrived >>= (@?= 2)
        -- A different, missing, empty or malformed number refuses after the
        -- same bounded retries of that read.
        forM_ [(Just "12345", Just "99999"), (Nothing, Just "12345"), (Just "12345", Just ""), (Just "abc", Just "12345")] $ \(bucketNumber, projectNumber) -> do
          reads <- newIORef (0 :: Int)
          let capture args = do
                atomicModifyIORef' reads (\n -> (n + 1, ()))
                pure (if "buckets" `elem` args then bucketNumber else projectNumber)
              numeric = maybe False (\v -> not (T.null v) && T.all (`elem` ['0' .. '9']) v)
          result <- provenOwnership noProjectNumbers (const (pure ())) capture "bucket" "project"
          assertBool ("ownership accepted " <> show (bucketNumber, projectNumber)) (isLeft result)
          readIORef reads >>= (@?= sum [if numeric value then 1 else 3 | value <- [bucketNumber, projectNumber]])
    , testCase "a remembered project number skips only the project read; disagreement rereads it live (EP-226 M4)" $
        withSystemTempDirectory "project-numbers" $ \directory -> do
          let numbers = projectNumbersAt (directory </> "numbers")
              reader bucketNumber projectNumber = do
                reads <- newIORef []
                let capture args = do
                      atomicModifyIORef' reads (\seen -> (args : seen, ()))
                      pure (if "buckets" `elem` args then bucketNumber else projectNumber)
                pure (reads, capture)
              projectReads = fmap (length . filter ("projects" `elem`)) . readIORef
          -- The first check reads both numbers and remembers the project's.
          (first', capture) <- reader (Just "12345") (Just "12345")
          provenOwnership numbers (const (pure ())) capture "bucket" "project" >>= (@?= Right ())
          projectReads first' >>= (@?= 1)
          (numbers ^. #recall) "project" >>= (@?= Just "12345")
          -- Later checks read only the bucket's owner.
          (second', capture') <- reader (Just "12345") (error "the project must not be read")
          provenOwnership numbers (const (pure ())) capture' "bucket" "project" >>= (@?= Right ())
          projectReads second' >>= (@?= 0)
          (length <$> readIORef second') >>= (@?= 1)
          -- A foreign or unreadable bucket rereads the project and still refuses.
          forM_ [Just "99999", Nothing, Just "abc"] $ \bucketNumber -> do
            (reads, refusing) <- reader bucketNumber (Just "12345")
            result <- provenOwnership numbers (const (pure ())) refusing "bucket" "project"
            assertBool ("ownership accepted " <> show bucketNumber) (isLeft result)
            projectReads reads >>= (@?= 1)
          -- A wrong remembered number costs one live read, never a refusal of
          -- the bucket that the project really owns; the live number replaces it.
          (numbers ^. #remember) "project" "99999"
          (third', capture'') <- reader (Just "12345") (Just "12345")
          provenOwnership numbers (const (pure ())) capture'' "bucket" "project" >>= (@?= Right ())
          projectReads third' >>= (@?= 1)
          (numbers ^. #recall) "project" >>= (@?= Just "12345")
          -- Malformed entries and unsafe project IDs are misses.
          writeFile (directory </> "numbers" </> "project") "not a number"
          (numbers ^. #recall) "project" >>= (@?= Nothing)
          (numbers ^. #remember) "../escape" "12345"
          (numbers ^. #recall) "../escape" >>= (@?= Nothing)
    ]
  where
    right = either (assertFailure . T.unpack) pure

-- | Captured with an empty configuration: @CLOUDSDK_CONFIG=$(mktemp -d)
-- gcloud config config-helper --format=json@ (never @gcloud auth revoke@).
noAccountStderr :: T.Text
noAccountStderr =
  "ERROR: (gcloud.config.config-helper) You do not currently have an active account selected.\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n"

refreshStderr :: T.Text
refreshStderr =
  "ERROR: (gcloud.config.config-helper) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n"

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
