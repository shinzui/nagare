-- | The recorded-state reader and recorded sites (EP-193 M1): scopes from the
-- production site compilers are written into a store, then read back by the
-- reader and the site projection without any provider.
module RecordedSiteSpec
  ( recordedSiteTests
  )
where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Project (siteList)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Recorded
import Nagare.Inventory.Site.Recorded
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps (ObjectOps (..))
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId)
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (encodeCanonicalScope)
import Nagare.Test.SiteInventory.Access (SiteFixture (..), protectedSiteFixture)
import Nagare.Test.World.ObjectStore (fakeObjectOps)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

recordedSiteTests :: TestTree
recordedSiteTests =
  testGroup
    "recorded sites"
    [ testCase "a converged public site, a protected site and a preview read back with their hostnames" $ do
        fixture <- protectedSiteFixture
        store <- seededStore fixture [] [] (allConverged fixture)
        sites <- loadSites store fixture
        map (\site -> (site ^. #kind, site ^. #state, site ^. #acceptedService)) sites
          @?= [ (SiteKindSite, RecordConverged, ServiceSummary "demo" "personal" ["demo.example.com"])
              , (SiteKindPreview, RecordConverged, ServiceSummary "demo-pr-branch" "personal" ["branch.demo.preview.example.com"])
              , (SiteKindSite, RecordConverged, ServiceSummary "secure" "personal" ["secure.example.com"])
              ]
        map (^. #lastConverged) sites @?= map (Just . (^. #acceptedService)) sites
    , testCase "a pending update keeps its earlier converged Service; a first install has none" $ do
        fixture <- protectedSiteFixture
        let public = publicSite fixture
            updated = updatedPublicSite fixture
            base = allConverged fixture
            heads =
              base
                { accepted = Map.insert (scopeId updated) (revision 2 updated) (accepted base)
                , converged = Map.delete (scopeId (protectedSite fixture)) (converged base)
                }
        store <- seededStore fixture [updated] [] heads
        sites <- loadSites store fixture
        case [site | site <- sites, site ^. #acceptedService . #name == "demo"] of
          [site] -> do
            site ^. #state @?= RecordPending
            site ^. #acceptedService . #hostnames @?= ["www.demo.example.com"]
            fmap (^. #hostnames) (site ^. #lastConverged) @?= Just ["demo.example.com"]
            site ^. #convergedRevision @?= Just (revision 1 public)
          other -> assertFailure ("expected one demo site, got " <> show other)
        [(site ^. #state, site ^. #lastConverged) | site <- sites, site ^. #acceptedService . #name == "secure"]
          @?= [(RecordNeverConverged, Nothing)]
    , testCase "the platform enforcer is not a site, and an open transaction is a head fact, not a refusal" $ do
        fixture <- protectedSiteFixture
        store <- seededStore fixture [] [] ((allConverged fixture) {transaction = Just "tx-open"})
        recorded <- loadState store fixture
        sites <- either (assertFailure . T.unpack) pure (recordedSites recorded)
        assertBool "the enforcer was listed" (all ((/= "nagare-access") . (^. #acceptedService . #name)) sites)
        let document = siteList (recordedHeadManifest (recordedStateHead recorded)) sites
        document ^. #liveObserved @?= False
        map (^. #resourceId) (document ^. #sites) @?= map (Resource.resourceIdText . (^. #service)) sites
        headActiveTransaction (recordedHeadManifest (recordedStateHead recorded)) @?= Just "tx-open"
    , testCase "a missing scope member is an error, never an omitted site" $ do
        fixture <- protectedSiteFixture
        store <- seededStore fixture [] [protectedSite fixture] (allConverged fixture)
        reader <- newRecordedReader defaultRecordedReaderConfig store (siteContext fixture) (readHead store)
        checked <- readRecordedHead reader >>= either (assertFailure . show) pure
        loadRecordedStateAt reader checked AcceptedOnly >>= assertBool "a missing member loaded" . isLeft
    , testCase "the reader refuses another context's head and an uninitialized store" $ do
        fixture <- protectedSiteFixture
        store <- seededStore fixture [] [] (allConverged fixture)
        let other = Resource.ContextBinding (unsafeRight (Resource.mkContextId "other")) (unsafeRight (Resource.mkName "project"))
        foreignReader <- newRecordedReader defaultRecordedReaderConfig store other (readHead store)
        readRecordedHead foreignReader >>= assertBool "another context's head was accepted" . isLeft
        empty <- newMemoryStore
        absent <- newRecordedReader defaultRecordedReaderConfig empty (siteContext fixture) (readHead empty)
        readRecordedHead absent >>= assertBool "an uninitialized store read as empty" . isLeft
    , testCase "a warm read fetches only the head, and a changed scope only its new member" $ do
        fixture <- protectedSiteFixture
        base <- fakeObjectOps
        reads <- newIORef (0 :: Int)
        let counted = base {getObject = \name -> modifyIORef' reads (+ 1) >> getObject base name}
        store <- newObjectStore counted (siteContext fixture) "client-recorded" Nothing >>= either (assertFailure . show) pure
        seed store fixture [updatedPublicSite fixture] [] (allConverged fixture)
        reader <- newRecordedReader defaultRecordedReaderConfig store (siteContext fixture) (readHead store)
        let load = do
              writeIORef reads 0
              checked <- readRecordedHead reader >>= either (assertFailure . show) pure
              _ <- loadRecordedStateAt reader checked WithConvergedSites >>= either (assertFailure . show) pure
              readIORef reads
        cold <- load
        assertBool ("the cold read fetched " <> show cold <> " objects") (cold > length (members fixture))
        load >>= (@?= 1)
        current <- readHead store >>= either (assertFailure . show) pure >>= maybe (assertFailure "no head") pure
        let updated = updatedPublicSite fixture
        _ <-
          replaceHeadIfGenerationMatches
            store
            (Just (headGeneration current))
            current {headGeneration = headGeneration current + 1, headAccepted = Map.insert (scopeId updated) (revision 2 updated) (headAccepted current)}
            >>= either (assertFailure . show) pure
        -- The head, then the one new accepted member; the earlier converged
        -- revision is the cached accepted one.
        load >>= (@?= 2)
    ]
  where
    revision number declaration = ScopeRevision (unsafeRight (Resource.mkScopeGeneration number)) (contentDigest (encodeCanonicalScope declaration))
    loadState store fixture = readRecordedState store (siteContext fixture) >>= either (assertFailure . show) pure
    loadSites store fixture = loadState store fixture >>= either (assertFailure . T.unpack) pure . recordedSites
    allConverged fixture =
      let revisions = Map.fromList [(scopeId declaration, revision 1 declaration) | declaration <- members fixture]
       in Heads revisions revisions Nothing
    seededStore fixture extra omitted heads = do
      store <- newMemoryStore
      seed store fixture extra omitted heads
      pure store
    seed store fixture extra omitted heads = do
      _ <- initializeStore store (siteContext fixture) "client-recorded" >>= either (assertFailure . show) pure
      forM_ [declaration | declaration <- members fixture <> extra, declaration `notElem` omitted] $ \declaration -> do
        let bytes = encodeCanonicalScope declaration
        publishIfAbsent store (scopeKey (contentDigest bytes)) bytes >>= either (assertFailure . show) (const (pure ()))
      current <- readHead store >>= either (assertFailure . show) pure >>= maybe (assertFailure "no head") pure
      replaceHeadIfGenerationMatches
        store
        (Just (headGeneration current))
        current {headGeneration = headGeneration current + 1, headAccepted = accepted heads, headConverged = converged heads, headActiveTransaction = transaction heads}
        >>= either (assertFailure . show) (const (pure ()))
    members :: SiteFixture -> [ScopeDeclaration]
    members fixture = [publicSite fixture, protectedSite fixture, previewSite fixture] <> platform fixture

data Heads = Heads
  { accepted :: !(Map.Map Resource.ScopeId ScopeRevision)
  , converged :: !(Map.Map Resource.ScopeId ScopeRevision)
  , transaction :: !(Maybe Text)
  }

unsafeRight :: Either Text a -> a
unsafeRight = either (error . T.unpack) id
