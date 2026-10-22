-- | The recorded-state reader and recorded sites (EP-193 M1): scopes from the
-- production site compilers are written into a store, then read back by the
-- reader and the site projection without any provider.
module RecordedSiteSpec
  ( recordedSiteTests
  , runRecordedSitesFixture
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
import Nagare.Resource.Inventory qualified as InventoryModel
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Public))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (encodeCanonicalScope)
import Nagare.Test.SiteInventory.Access (SiteFixture (..), protectedSiteFixture, publicSiteScope)
import Nagare.Test.World.ObjectStore (fakeObjectOps, immutableThroughGet)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>))
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
    , testCase "a site query over an object store never writes, lists or reads a batch" $ do
        fixture <- protectedSiteFixture
        base <- fakeObjectOps
        writer <- newObjectStore base (siteContext fixture) "client-recorded" Nothing >>= either (assertFailure . show) pure
        seed writer fixture [] [] (allConverged fixture)
        let refused label = assertFailure ("the recorded reader attempted " <> label) >> fail label
            recording =
              base
                { putObject = \_ _ _ -> refused "a write"
                , getObjects = \_ -> refused "a batch (journal or archive) read"
                , listObjects = \_ -> refused "a listing"
                }
        reader <- newObjectStore recording (siteContext fixture) "client-reader" Nothing >>= either (assertFailure . show) pure
        recorded <- readRecordedState reader (siteContext fixture) >>= either (assertFailure . show) pure
        sites <- either (assertFailure . T.unpack) pure (recordedSites recorded)
        length sites @?= 3
    , testCase "a warm read fetches only the head, and a changed scope only its new member" $ do
        fixture <- protectedSiteFixture
        base <- fakeObjectOps
        reads <- newIORef (0 :: Int)
        let counted = immutableThroughGet base {getObject = \name -> modifyIORef' reads (+ 1) >> getObject base name}
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

-- | @NAGARE_RECORDED_SITES_FIXTURE=DIR@: write a local context
-- @recorded-sites-fixture@ under @DIR/config@ and seed its store under
-- @DIR/state@ with production-compiled public, protected and preview sites,
-- a hundred more public sites, an application web service and a worker-only
-- application, then exit without running the tests.
runRecordedSitesFixture :: FilePath -> IO ExitCode
runRecordedSitesFixture root = do
  fixture <- protectedSiteFixture
  extra <- traverse (\index -> publicSiteScope ("bulk" <> T.pack (show index))) [1 .. 100 :: Int]
  let contextName = "recorded-sites-fixture"
      binding = Resource.ContextBinding (unsafeRight (Resource.mkContextId contextName)) (unsafeRight (Resource.mkName "project"))
      scopes = [publicSite fixture, protectedSite fixture, previewSite fixture, applicationWeb, workerOnly] <> extra <> platform fixture
      revisions = Map.fromList [(scopeId declaration, ScopeRevision (unsafeRight (Resource.mkScopeGeneration 1)) (contentDigest (encodeCanonicalScope declaration))) | declaration <- scopes]
  createDirectoryIfMissing True (root </> "config/nagare/contexts")
  writeFile (root </> "config/nagare/contexts" </> T.unpack contextName <.> "env") "export CLOUDSDK_CORE_PROJECT=project\nexport NAGARE_MODE=local\n"
  store <- openFilesystemStore (root </> "state/nagare" </> T.unpack contextName </> "inventory") >>= either (fail . show) pure
  _ <- initializeStore store binding "client-fixture" >>= either (fail . show) pure
  forM_ scopes $ \declaration -> do
    let bytes = encodeCanonicalScope declaration
    publishIfAbsent store (scopeKey (contentDigest bytes)) bytes >>= either (fail . show) (const (pure ()))
  current <- readHead store >>= either (fail . show) pure >>= maybe (fail "no head") pure
  replaceHeadIfGenerationMatches store (Just (headGeneration current)) current {headGeneration = headGeneration current + 1, headAccepted = revisions, headConverged = Map.delete (scopeId workerOnly) revisions}
    >>= either (fail . show) pure
  pure ExitSuccess
  where
    cluster = Resource.mintResourceId (unsafeRight (Resource.mkScopeId Resource.Platform "foundation")) (unsafeRight (Resource.mkLogicalKey "cluster")) (unsafeRight (Resource.mkName "resource"))
    managed owner key address aliases spec dependencies =
      InventoryModel.ManagedResource (Resource.mintResourceId owner (unsafeRight (Resource.mkLogicalKey key)) (unsafeRight (Resource.mkName "resource"))) owner InventoryModel.KubernetesExecutor address aliases spec Retain Stateless Public dependencies [] (Resource.SourceLocation "fixture" key)
    applicationWeb =
      let owner = unsafeRight (Resource.mkScopeId Resource.Application "notes")
          service = managed owner "web" (unsafeRight (Resource.kubernetesAddress cluster "serving.knative.dev/v1" "Service" (Just "team") "notes")) [] (InventoryModel.KnativeService (contentDigest "notes")) [OrderedAfter cluster]
          route = managed owner "notes-route" (unsafeRight (Resource.kubernetesAddress cluster "serving.knative.dev/v1beta1" "DomainMapping" (Just "team") "notes.example.com")) [Resource.Hostname (unsafeRight (Resource.mkName "notes.example.com"))] (InventoryModel.NativeObject (contentDigest "notes-route")) [OrderedAfter cluster, OrderedAfter (service ^. #identity)]
       in unsafeInventory (InventoryModel.mkScopeDeclaration owner [InventoryModel.ResourceBundle [InventoryModel.Managed service, InventoryModel.Managed route] [] [] [] [] []])
    workerOnly =
      let owner = unsafeRight (Resource.mkScopeId Resource.Application "indexer")
          worker = managed owner "worker" (unsafeRight (Resource.kubernetesAddress cluster "apps/v1" "Deployment" (Just "team") "indexer")) [] (InventoryModel.NativeObject (contentDigest "indexer")) [OrderedAfter cluster]
       in unsafeInventory (InventoryModel.mkScopeDeclaration owner [InventoryModel.ResourceBundle [InventoryModel.Managed worker] [] [] [] [] []])
    unsafeInventory = either (error . show) id
