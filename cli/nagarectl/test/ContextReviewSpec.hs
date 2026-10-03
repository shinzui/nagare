module ContextReviewSpec (contextReviewTests) where

import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Context.Review
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (HeadManifest (..), MigrationTombstone (..), ScopeRevision (..))
import Nagare.Resource.Types
import Nagare.Target (ContextName, mkContextName, parseContextEnv, profileFromContextMap)
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

contextReviewTests :: TestTree
contextReviewTests =
  testGroup
    "local context review"
    [ testCase "operational update and receipt replay preserve later local inputs" $
        withSystemTempDirectory "context-review" $ \root -> do
          let path = root </> "fixture.env"
          BS.writeFile path (TE.encodeUtf8 original)
          plan <- right (prepareProfileReviewAt name path original (Just updated) headValue)
          applyProfileReview path observe plan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 updated)
          bytes <- right (profileReviewBytes plan)
          let receipt = path <> ".reviews" </> T.unpack (digestText (contentDigest bytes)) </> "completed"
          removeFile receipt
          applyProfileReview path (const (pure (Left "history unavailable after local effect"))) plan >>= (@?= Right ())
          BS.writeFile path "later profile"
          applyProfileReview path observe plan >>= (@?= Right ())
          BS.readFile path >>= (@?= "later profile")
    , testCase "removal retains authority and restores exact bytes" $
        withSystemTempDirectory "context-remove" $ \root -> do
          let path = root </> "fixture.env"
          BS.writeFile path (TE.encodeUtf8 original)
          plan <- right (prepareProfileReviewAt name path original Nothing headValue)
          applyProfileReview path observe plan >>= (@?= Right ())
          doesFileExist path >>= (@?= False)
          doesFileExist (profileRemovalMarker path) >>= (@?= True)
          restoreProfileReview path observe plan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 original)
          doesFileExist (profileRemovalMarker path) >>= (@?= False)
          bytes <- right (profileReviewBytes plan)
          BS.writeFile (profileRemovalMarker path) bytes
          restoreProfileReview path observe plan >>= (@?= Right ())
          doesFileExist (profileRemovalMarker path) >>= (@?= False)
          applyProfileReview path observe plan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 original)
          restoreProfileReview path observe plan >>= (@?= Right ())
    , testCase "builder transport values survive update and exact removal restoration" $
        withSystemTempDirectory "context-builder-inputs" $ \root -> do
          let path = root </> "fixture.env"
              before = original <> "NAGARE_BUILDER_PROJECT=project\nNAGARE_BUILDER_ZONE=zone\nNAGARE_BUILDER_INSTANCE=builder\nNIX_BUILDER_SSH_KEY=/private/key\nNIX_BUILDER_HOST_KEY_B64=cHVibGlj\nNIX_BUILDER_TUNNEL_PORT=28157\n"
          after <- right (renderProfileReplacementPreserving before (profileFromContextMap (parseContextEnv updated)))
          plan <- right (prepareProfileReviewAt name path before (Just after) headValue)
          assertBool "stripped builder inputs accepted" (isLeft (prepareProfileReviewAt name path before (Just updated) headValue))
          assertBool "changed builder accepted" (isLeft (prepareProfileReviewAt name path before (Just (T.replace "='builder'" "='foreign'" after)) headValue))
          BS.writeFile path (TE.encodeUtf8 before)
          applyProfileReview path observe plan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 after)
          removal <- right (prepareProfileReviewAt name path after Nothing headValue)
          applyProfileReview path observe removal >>= (@?= Right ())
          restoreProfileReview path observe removal >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 after)
    , testCase "foreign profile and changed history refuse without writing" $
        withSystemTempDirectory "context-refuse" $ \root -> do
          let path = root </> "fixture.env"
          BS.writeFile path (TE.encodeUtf8 original)
          plan <- right (prepareProfileReviewAt name path original (Just updated) headValue)
          applyProfileReview path (const (pure (Right headValue {headGeneration = 2}))) plan >>= assertBool "stale history" . isLeft
          BS.readFile path >>= (@?= TE.encodeUtf8 original)
          BS.writeFile path "foreign"
          applyProfileReview path observe plan >>= assertBool "foreign profile" . isLeft
          BS.readFile path >>= (@?= "foreign")
    , testCase "authority changes and active history cannot be reviewed" $ do
        assertBool "project" (isLeft (prepareProfileReviewAt name "/fixture.env" original (Just "CLOUDSDK_CORE_PROJECT=foreign\nNAGARE_MODE=local\n") headValue))
        assertBool "store" (isLeft (prepareProfileReviewAt name "/fixture.env" original (Just (original <> "NAGARE_INVENTORY_STORE_URL=gs://foreign/history\n")) headValue))
        assertBool "transaction" (isLeft (prepareProfileReviewAt name "/fixture.env" original Nothing headValue {headActiveTransaction = Just "active"}))
    , testCase "removal restore refuses occupying bytes and foreign roots" $
        withSystemTempDirectory "context-restore-conflict" $ \root -> do
          let path = root </> "fixture.env"
          BS.writeFile path (TE.encodeUtf8 original)
          plan <- right (prepareProfileReviewAt name path original Nothing headValue)
          applyProfileReview path observe plan >>= (@?= Right ())
          BS.writeFile path "foreign"
          restoreProfileReview path observe plan >>= assertBool "occupied" . isLeft
          removeFile path
          restoreProfileReview (root </> "other.env") observe plan >>= assertBool "root" . isLeft
    , testCase "replacement decoder rejects extra executable lines and invalid shapes" $ do
        assertBool "extra command" (isLeft (prepareProfileReviewAt name "/fixture.env" original (Just (updated <> "exit 99\n")) headValue))
        let invalid = either (error . show) id (renderProfileReplacement (profileFromContextMap (parseContextEnv (original <> "NAGARE_BOOT_DISK_SIZE_GB=broken\n"))))
        assertBool "invalid shape" (isLeft (prepareProfileReviewAt name "/fixture.env" original (Just invalid) headValue))
    , testCase "canonical quoted replacement preserves shell substitution as literal data" $
        withSystemTempDirectory "context-shell-data" $ \root -> do
          let path = root </> "fixture.env"
              email = "a$(false)@example.com"
              profile = profileFromContextMap (Map.insert "NAGARE_ACME_EMAIL" email (parseContextEnv original))
          replacement <- right (renderProfileReplacement profile)
          plan <- right (prepareProfileReviewAt name path original (Just replacement) headValue)
          BS.writeFile path (TE.encodeUtf8 original)
          applyProfileReview path observe plan >>= (@?= Right ())
          (status, output, _) <- readProcessWithExitCode "bash" ["-c", "source \"$1\"; printf '%s' \"$NAGARE_ACME_EMAIL\"", "profile-test", path] ""
          status @?= ExitSuccess
          output @?= T.unpack email
    , testCase "local foundation authority excludes other scopes and migration" $ do
        let cloud = "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=cloud\nNAGARE_INVENTORY_STORE=gcs\n"
            other = either (error . show) id (mkScopeId Platform "host")
            generation = either (error . show) id (mkScopeGeneration 1)
            revision = ScopeRevision generation (contentDigest "other")
        void (right (prepareProfileReviewAt name "/fixture.env" cloud Nothing headValue))
        assertBool "foreign scope" (isLeft (prepareProfileReviewAt name "/fixture.env" cloud Nothing headValue {headAccepted = Map.singleton other revision}))
        assertBool "migration" (isLeft (prepareProfileReviewAt name "/fixture.env" cloud Nothing headValue {headMigration = Just (MigrationTombstone "gs://elsewhere/history" (contentDigest "old"))}))
    , testCase "fresh request permits returning to a previous profile without replaying old reviews" $
        withSystemTempDirectory "context-repeat-inputs" $ \root -> do
          let path = root </> "fixture.env"
          BS.writeFile path (TE.encodeUtf8 original)
          firstPlan <- right (prepareProfileReview "first" name path original (Just updated) (Just "/fixture-history") headValue)
          applyProfileReview path observe firstPlan >>= (@?= Right ())
          BS.writeFile path (TE.encodeUtf8 original)
          applyProfileReview path observe firstPlan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 original)
          secondPlan <- right (prepareProfileReview "second" name path original (Just updated) (Just "/fixture-history") headValue)
          applyProfileReview path observe secondPlan >>= (@?= Right ())
          BS.readFile path >>= (@?= TE.encodeUtf8 updated)
    , testCase "review roundtrip validates version and binding" $ do
        plan <- right (prepareProfileReviewAt name "/fixture.env" original Nothing headValue)
        bytes <- right (profileReviewBytes plan)
        decoded <- right (decodeProfileReview bytes)
        profileReviewBytes decoded @?= Right bytes
        assertBool "invalid wire" (isLeft (decodeProfileReview "{}"))
    ]
  where
    observe _ = pure (Right headValue)

original, updated :: Text
original = "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
updated = either (error . show) id (renderProfileReplacement (profileFromContextMap (parseContextEnv (original <> "NAGARE_MACHINE_TYPE=e2-standard-4\n"))))

name :: ContextName
name = either (error . show) id (mkContextName "fixture")

headValue :: HeadManifest
headValue =
  HeadManifest
    1
    1
    0
    (ContextBinding (either (error . show) id (mkContextId "fixture")) (either (error . show) id (mkName "project")))
    "fixture"
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Nothing
    Nothing
    Nothing
    Nothing

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> error "unreachable") pure

prepareProfileReviewAt :: ContextName -> FilePath -> Text -> Maybe Text -> HeadManifest -> Either Text ProfileReview
prepareProfileReviewAt context location before after head =
  prepareProfileReview "fixture-request" context location before after (Just "/fixture-history") head
