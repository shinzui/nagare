{-# LANGUAGE OverloadedStrings #-}

module InventoryPublicationSpec (inventoryPublicationTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding (first, review)
import Nagare.Inventory.Adapters.GitHubRelease
import Nagare.Inventory.Artifact
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (digestText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

inventoryPublicationTests :: TestTree
inventoryPublicationTests =
  testGroup
    "GitHub release publication recovery"
    [ testCase "review binds exact EP-146 artifact bytes and safe provider names" $ do
        let badDigest =
              sampleAsset
                { productSpec =
                    (productSpec sampleAsset)
                      { executionArtifactContentDigest = contentDigest "other"
                      }
                }
            badName = sampleAsset {productName = "../probe.txt"}
        assertLeft "reviewed digest" (reviewWith [badDigest])
        assertLeft "provider name" (reviewWith [badName])
        case reviewWith [sampleAsset] of
          Left err -> assertFailure (T.unpack err)
          Right review -> do
            assertBool
              "body carries the exact review envelope"
              ("<!-- nagare-release-intent-v1" `T.isInfixOf` publicationBody review)
            assertBool "digest is complete" (T.length (publicationDigest review) == 64)
    , testCase "provider writes are reconstructed after create, each upload, and publish" $ do
        review <-
          either
            (assertFailure . T.unpack)
            pure
            (reviewWith [sampleAsset, secondaryAsset])
        mapM_
          (checkRecovery review)
          [ Nothing
          , Just "create"
          , Just "upload:probe.txt"
          , Just "upload:second.txt"
          , Just "upload:receipt"
          , Just "publish"
          ]
    , testCase "different candidate, unreviewed asset, starter, and incomplete publication refuse" $ do
        review <- either (assertFailure . T.unpack) pure (reviewWith [sampleAsset])
        (ops, state) <- fakeProvider Nothing
        first <- publishReviewedRelease ops review
        _ <- either (assertFailure . T.unpack) pure first
        before <- readIORef state
        let changedBytes = BC.pack "changed candidate\n"
            changedSpec =
              (productSpec sampleAsset)
                { executionArtifactContentDigest = contentDigest changedBytes
                }
            changedAsset =
              sampleAsset
                { productBytes = changedBytes
                , productSpec = changedSpec
                }
        changed <- either (assertFailure . T.unpack) pure (reviewWith [changedAsset])
        publishReviewedRelease ops changed >>= assertLeft "changed same-tag review"
        after <- readIORef state
        fakeWrites after @?= fakeWrites before

        (extraOps, extraState) <- fakeProvider Nothing
        writeIORef
          extraState
          ( seedDraft
              review
              [asset 90 "unreviewed.txt" "uploaded" "foreign"]
          )
        publishReviewedRelease extraOps review >>= assertLeft "unreviewed provider asset"

        (starterOps, starterState) <- fakeProvider Nothing
        writeIORef
          starterState
          ( seedDraft
              review
              [asset 91 "probe.txt" "starter" (productBytes sampleAsset)]
          )
        publishReviewedRelease starterOps review >>= assertLeft "failed upload placeholder"

        (incompleteOps, incompleteState) <- fakeProvider Nothing
        let incomplete = seedDraft review [asset 92 "probe.txt" "uploaded" (productBytes sampleAsset)]
        writeIORef
          incompleteState
          incomplete
            { fakeRelease = fmap (\release -> release {providerReleaseDraft = False}) (fakeRelease incomplete)
            }
        publishReviewedRelease incompleteOps review >>= assertLeft "published without receipt"
        readIORef incompleteState >>= (\observed -> fakeWrites observed @?= [])
    , testCase "unknown reads and a moved tag refuse before the first write" $ do
        review <- either (assertFailure . T.unpack) pure (reviewWith [sampleAsset])
        (ops, state) <- fakeProvider Nothing
        publishReviewedRelease
          (ops {readProviderTag = \_ _ -> pure (Left "tag read timed out")})
          review
          >>= assertLeft "unknown tag read"
        publishReviewedRelease
          (ops {readProviderTag = \_ _ -> pure (Right (T.replicate 40 "c", T.replicate 40 "b"))})
          review
          >>= assertLeft "moved tag object"
        publishReviewedRelease
          (ops {listProviderReleases = \_ -> pure (Left "release list timed out")})
          review
          >>= assertLeft "unknown release list"
        readIORef state >>= (\observed -> fakeWrites observed @?= [])
    , testCase "all present products and receipt names are checked before uploads" $ do
        review <-
          either
            (assertFailure . T.unpack)
            pure
            (reviewWith [sampleAsset, secondaryAsset])
        (changedOps, changedState) <- fakeProvider Nothing
        writeIORef
          changedState
          ( seedDraft
              review
              [asset 93 "second.txt" "uploaded" "foreign"]
          )
        publishReviewedRelease changedOps review
          >>= assertLeft "different existing product before a missing upload"
        readIORef changedState >>= (\observed -> fakeWrites observed @?= [])

        (receiptOps, receiptState) <- fakeProvider Nothing
        writeIORef
          receiptState
          ( seedDraft
              review
              [asset 94 "nagare-verification-foreign.json" "uploaded" "foreign"]
          )
        publishReviewedRelease receiptOps review
          >>= assertLeft "foreign receipt before a missing upload"
        readIORef receiptState >>= (\observed -> fakeWrites observed @?= [])
    , testCase "failed upload cleanup requires the exact draft and asset identity" $ do
        review <- either (assertFailure . T.unpack) pure (reviewWith [sampleAsset])
        (ops, state) <- fakeProvider Nothing
        writeIORef
          state
          ( seedDraft
              review
              [asset 91 "probe.txt" "starter" (productBytes sampleAsset)]
          )
        cleanupReviewedStarter ops review 42 92 "probe.txt"
          >>= assertLeft "wrong physical asset"
        cleanupReviewedStarter ops review 43 91 "probe.txt"
          >>= assertLeft "wrong physical release"
        readIORef state >>= (\observed -> fakeWrites observed @?= [])
        cleanupReviewedStarter ops review 42 91 "probe.txt"
          >>= either (assertFailure . T.unpack) pure
        observed <- readIORef state
        fakeWrites observed @?= ["delete:91"]
        fmap providerReleaseAssets (fakeRelease observed) @?= Just []
    ]

checkRecovery :: PublicationReview -> Maybe Text -> Assertion
checkRecovery review fault = do
  (ops, state) <- fakeProvider fault
  published <- publishReviewedRelease ops review >>= either (assertFailure . T.unpack) pure
  providerReleaseDraft published @?= False
  providerReleaseId published @?= 42
  map providerAssetId (providerReleaseAssets published) @?= [100, 101, 102]
  let expected =
        ["create", "upload:probe.txt", "upload:second.txt", "upload:receipt", "publish"]
  observed <- readIORef state
  fakeWrites observed @?= expected
  -- A new runner has no journal. The same reviewed candidate and provider
  -- record must prove completion without another provider write.
  restarted <- publishReviewedRelease ops review >>= either (assertFailure . T.unpack) pure
  providerReleaseId restarted @?= providerReleaseId published
  providerReleaseAssets restarted @?= providerReleaseAssets published
  readIORef state >>= (\result -> fakeWrites result @?= expected)

sampleAsset :: ProductAsset
sampleAsset =
  let bytes = BC.pack "probe asset\n"
      digest = contentDigest bytes
      spec =
        ArtifactExecutionSpec
          ReleasePayloadArtifact
          "github-release://shinzui/release-probe/v1/probe.txt"
          digest
          digest
          True
          Nothing
   in ProductAsset "probe.txt" spec bytes

secondaryAsset :: ProductAsset
secondaryAsset =
  let bytes = BC.pack "second asset\n"
      digest = contentDigest bytes
      spec =
        ArtifactExecutionSpec
          ReleasePayloadArtifact
          "github-release://shinzui/release-probe/v1/second.txt"
          digest
          digest
          True
          Nothing
   in ProductAsset "second.txt" spec bytes

reviewWith :: [ProductAsset] -> Either Text PublicationReview
reviewWith =
  compilePublicationReview
    "shinzui/release-probe"
    "v1"
    (T.replicate 40 "a")
    (T.replicate 40 "b")
    "payload-1"
    "Exact pre-generated notes."

data Fake = Fake
  { fakeRelease :: !(Maybe PublicationRelease)
  , fakeBytes :: !(Map.Map Integer ByteString)
  , fakeNextId :: !Integer
  , fakeWrites :: ![Text]
  , fakeFault :: !(Maybe Text)
  }

fakeProvider :: Maybe Text -> IO (GitHubReleaseOps, IORef Fake)
fakeProvider fault = do
  state <- newIORef (Fake Nothing Map.empty 100 [] fault)
  let ops =
        GitHubReleaseOps
          { readProviderTag = \_ _ -> pure (Right (T.replicate 40 "a", T.replicate 40 "b"))
          , listProviderReleases = \_ -> do
              observed <- readIORef state
              pure (Right (maybe [] pure (fakeRelease observed)))
          , createProviderDraft = \review -> modifyIORefResult state $ \observed ->
              let release =
                    PublicationRelease
                      42
                      (publicationTag review)
                      (publicationBody review)
                      True
                      []
                  next =
                    observed
                      { fakeRelease = Just release
                      , fakeWrites = fakeWrites observed <> ["create"]
                      }
               in maybeFault "create" next
          , uploadProviderAsset = \releaseId name bytes -> modifyIORefResult state $ \observed ->
              case fakeRelease observed of
                Just release
                  | providerReleaseId release == releaseId
                      && providerReleaseDraft release ->
                      let identifier = fakeNextId observed
                          uploaded = asset identifier name "uploaded" bytes
                          nextRelease =
                            release
                              { providerReleaseAssets = providerReleaseAssets release <> [uploaded]
                              }
                          action =
                            if "nagare-verification-" `T.isPrefixOf` name
                              then "upload:receipt"
                              else "upload:" <> name
                          next =
                            observed
                              { fakeRelease = Just nextRelease
                              , fakeBytes = Map.insert identifier bytes (fakeBytes observed)
                              , fakeNextId = identifier + 1
                              , fakeWrites = fakeWrites observed <> [action]
                              }
                       in maybeFault action next
                _ -> (Left "draft is absent", observed)
          , downloadProviderAsset = \identifier -> do
              observed <- readIORef state
              pure
                ( maybe
                    (Left "asset is absent")
                    Right
                    (Map.lookup identifier (fakeBytes observed))
                )
          , publishProviderDraft = \releaseId _ -> modifyIORefResult state $ \observed ->
              case fakeRelease observed of
                Just release
                  | providerReleaseId release == releaseId
                      && providerReleaseDraft release ->
                      let next =
                            observed
                              { fakeRelease = Just release {providerReleaseDraft = False}
                              , fakeWrites = fakeWrites observed <> ["publish"]
                              }
                       in maybeFault "publish" next
                _ -> (Left "draft is absent", observed)
          , deleteProviderAsset = \identifier -> modifyIORefResult state $ \observed ->
              case fakeRelease observed of
                Just release
                  | providerReleaseDraft release ->
                      let retained = filter ((/= identifier) . providerAssetId) (providerReleaseAssets release)
                          next =
                            observed
                              { fakeRelease = Just release {providerReleaseAssets = retained}
                              , fakeBytes = Map.delete identifier (fakeBytes observed)
                              , fakeWrites = fakeWrites observed <> ["delete:" <> T.pack (show identifier)]
                              }
                       in maybeFault "delete" next
                _ -> (Left "draft is absent", observed)
          }
  pure (ops, state)

modifyIORefResult :: IORef Fake -> (Fake -> (Either Text (), Fake)) -> IO (Either Text ())
modifyIORefResult ref action =
  atomicModifyIORef'
    ref
    ( \observed ->
        let (result, next) = action observed in (next, result)
    )

maybeFault :: Text -> Fake -> (Either Text (), Fake)
maybeFault action next
  | fakeFault next == Just action =
      (Left ("acknowledgement lost after " <> action), next {fakeFault = Nothing})
  | otherwise = (Right (), next)

asset :: Integer -> Text -> Text -> ByteString -> PublicationAsset
asset identifier name state bytes =
  PublicationAsset
    identifier
    name
    state
    (fromIntegral (BS.length bytes))
    (Just ("sha256:" <> digestText (contentDigest bytes)))

seedDraft :: PublicationReview -> [PublicationAsset] -> Fake
seedDraft review assets =
  Fake
    (Just (PublicationRelease 42 (publicationTag review) (publicationBody review) True assets))
    ( Map.fromList
        [ ( providerAssetId member
          , if providerAssetName member == "probe.txt"
              then productBytes sampleAsset
              else "foreign"
          )
        | member <- assets
        ]
    )
    100
    []
    Nothing

assertLeft :: String -> Either Text a -> Assertion
assertLeft label = either (const (pure ())) (const (assertFailure (label <> " was accepted")))
