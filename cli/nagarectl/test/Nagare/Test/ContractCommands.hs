-- | EP-192 M3 and M4: the saved-review, image-publication, deploy-preview,
-- inventory-status and publication-list documents and the read refusals,
-- produced by the library calls the commands make under @--contract 1@.
module Nagare.Test.ContractCommands
  ( contractCommandTests
  )
where

import Control.Exception (finally, try)
import Data.Aeson (Value (..), eitherDecode, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.OpenApi (validateToJSON)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Nagare.Contract.Problem (ProblemDetails, unknownScope)
import Nagare.Contract.Project (deployPreview, imagePublicationResult, inventoryStatusReport, storeRefusal)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Sink (clearContractSink, emitDocument, refuseWith, setContractSinkTo, withReadContract)
import Nagare.Contract.V1 (DeployPreview, ImagePublicationResult (..), Outcome (..), PublishedReview (..), ReviewLocation (..), SavedReview (..), TransactionOutcome (..))
import Nagare.Dsl.Config (encodeStaticSite)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild), StaticSite, mkFilePathText)
import Nagare.Inventory.Adapter (AdapterExecution (..), AdapterRegistry, mkAdapterRegistry)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesMutation (..), KubernetesState (..), mkKubernetesAdapter, unstamped)
import Nagare.Inventory.Command (applyInventoryWithFactory, convergeInventoryCandidateResult, loadTargetSnapshot, openInventoryForPlanning, openTargetStore, openedSnapshot, planInventoryCandidateLoaded, planInventoryCandidateWith)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan (InventoryHistory, ReviewBundle, ReviewDocument (..), ReviewInventory, loadReviewBundle, reviewBundleDocument)
import Nagare.Inventory.Publications (readPublications)
import Nagare.Inventory.Site (compileStaticSiteScope, recordReviewedSiteInputs)
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store (InventoryStore, ScopeRevision (..), StoreError (StoreAuthRequired), initializeStore, readHead)
import Nagare.Inventory.Store.Counters (Counter (..), collectStoreCounters, countOf)
import Nagare.Inventory.Store.GcloudAuth (gcloudLoginRequired)
import Nagare.Resource.Inventory (CompositionCandidate, Declaration (..), Executor (KubernetesExecutor), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope), ScopeDeclaration, composeInventory, mkScopeDeclaration, scopeConfigDigest, scopeOverrides, snapshotScopes, withScopeConfigDigest, withScopeOverrides)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Deploy (DeployInputs (..), staticUrl)
import Nagare.Static.Release (StaticRelease (..), emptyReleaseLog)
import Nagare.Target (ActiveTarget (..), Mode (Local), mkContextName)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

contractCommandTests :: TestTree
contractCommandTests =
  testGroup
    "contract commands (EP-192 M3, M4)"
    [ testCase "a saved review under --contract 1 is one saved-review document" $ withFixture $ \fixture -> do
        let directory = fixtureRoot fixture </> "review"
        documents <- collecting (planInventoryCandidateWith (fixturePlan fixture) (fixtureTarget fixture) (fixtureCandidate fixture) directory)
        saved :: SavedReview <- decodeOne documents
        absolute <- makeAbsolute directory
        (saved ^. #review . #directory, saved ^. #scopes, T.length (saved ^. #review . #sha256)) @?= (T.pack absolute, ["application:command-fixture"], 64)
        validateToJSON saved @?= []
    , testCase "a saved review keeps a release-only hook's trigger override on the desired application scope (EP-269)" $ withFixture $ \fixture -> do
        let directory = fixtureRoot fixture </> "review-release-only"
            triggered = withScopeOverrides (Map.fromList [("tag", "v1"), ("hookTrigger/migrate", "release-only")]) fixtureScope
        before <- loadTargetSnapshot (fixtureTarget fixture)
        _ <- collecting (planInventoryCandidateWith (fixturePlan fixture) (fixtureTarget fixture) (ok (composeInventory before (ReplaceScope triggered :| []))) directory)
        bundle <- loadReviewBundle directory >>= either (fail . T.unpack) pure
        revision <- maybe (fail "no desired application revision") pure (Map.lookup fixtureOwner (reviewDesiredRevisions (reviewBundleDocument bundle)))
        -- The scope document a reviewer reads as scopes/DIGEST.json.
        scopeBytes <- BS.readFile (directory </> "scopes" </> (T.unpack (Resource.digestText (revisionDigest revision)) <> ".json"))
        case Aeson.decodeStrict scopeBytes of
          Just (Object members) -> KeyMap.lookup "overrides" members @?= Just (toJSON (Map.fromList [("hookTrigger/migrate" :: Text, "release-only" :: Text), ("tag", "v1")]))
          _ -> assertFailure "saved scope document is not an object"
    , testCase "an in-process publication prints only its image-publication document" $ withFixture $ \fixture -> do
        printed <- newIORef []
        setContractSinkTo (\line -> modifyIORef' printed (line :))
        (digest, result) <-
          convergeInventoryCandidateResult (fixturePlan fixture) (fixtureApply fixture) (fixtureTarget fixture) (fixtureCandidate fixture)
            `finally` clearContractSink
        readIORef printed >>= (@?= [])
        case result of
          Converged _ -> pure ()
          other -> assertFailure ("fixture did not converge: " <> show other)
        let document = imagePublicationResult (fixtureResource fixture) digest Nothing (Just result)
        (document ^. #review . #directory, fmap (^. #outcome) (fromNullable' (document ^. #transaction))) @?= (Nullable Nothing, Just OutcomeConverged)
        validateToJSON document @?= []
    , testCase "a deploy preview has the same keys with and without hooks" $ do
        let digest = contentDigest "typed-config"
            application = withScopeOverrides (Map.fromList [("tag", "v1")]) (withScopeConfigDigest digest fixtureScope)
            keys shown = case toJSON shown of
              Object members -> KeyMap.keys members
              _ -> []
            alone = deployPreview application []
            hooked = deployPreview application [fixtureScope]
        keys alone @?= keys hooked
        (alone ^. #application . #configDigest, alone ^. #application . #overrides, length (hooked ^. #scopeDocuments))
          @?= (Nullable (Just (Resource.digestText digest)), Map.fromList [("tag", "v1")], 2)
        validateToJSON alone @?= []
        validateToJSON hooked @?= []
    , testCase "a scoped status report lists only that scope's state and findings" $ withFixture $ \fixture -> do
        (_, result) <- convergeInventoryCandidateResult (fixturePlan fixture) (fixtureApply fixture) (fixtureTarget fixture) (fixtureCandidate fixture)
        store <- openTargetStore (fixtureTarget fixture)
        headValue <- readHead store >>= either (fail . show) (maybe (fail "no head") pure)
        let other = ok (Resource.mkScopeId Resource.Application "other")
            finding owner resource =
              Status.DriftFinding resource owner KubernetesExecutor (member ^. #address) Status.ConfigurationDrift Status.HealthReady Nothing Nothing (Just "changed")
            drift = [finding fixtureOwner fixtureMember, finding other (Resource.mintResourceId other (ok (Resource.mkLogicalKey "config")) (ok (Resource.mkName "configmap")))]
            scoped = inventoryStatusReport fixtureBinding "2026-10-16T12:00:00Z" True headValue (Just fixtureOwner) drift
            everything = inventoryStatusReport fixtureBinding "2026-10-16T12:00:00Z" True headValue Nothing drift
        assertBool "fixture converged" (case result of Converged _ -> True; _ -> False)
        (map (^. #scope) (scoped ^. #scopes), map (^. #scope) (scoped ^. #findings), length (everything ^. #findings))
          @?= (["application:command-fixture"], ["application:command-fixture"], 2)
        validateToJSON scoped @?= []
    , testCase "a read refusal is a bare problem document with exit 2 (unknown scope, F107)" $ do
        let refuse spec detailText = do
              printed <- newIORef []
              setContractSinkTo (\line -> modifyIORef' printed (line :))
              exited <- try (withReadContract (Just 1) (refuseWith "unused" spec detailText)) `finally` clearContractSink
              (,) exited . map (eitherDecode @ProblemDetails) <$> readIORef printed
        refuse unknownScope "application:absent is not an accepted scope"
          >>= \(exited, documents) -> (exited, fmap (^. #code) <$> documents) @?= (Left (ExitFailure 2), [Right "unknown_scope"])
        let (spec, detailText) = storeRefusal StoreAuthRequired
        refuse spec detailText
          >>= \(exited, documents) -> (exited, fmap (\problem -> (problem ^. #code, problem ^. #detail)) <$> documents) @?= (Left (ExitFailure 2), [Right ("reauthentication_required", gcloudLoginRequired)])
    , testCase "a plan opens one store, one head and one history and lists nothing; its apply loads one history (EP-212)" $ withFixture $ \fixture -> do
        _ <- convergeInventoryCandidateResult (fixturePlan fixture) (fixtureApply fixture) (fixtureTarget fixture) (fixtureCandidate fixture)
        let target = fixtureTarget fixture
            directory = fixtureRoot fixture </> "second"
        (_, planned) <- collectStoreCounters . collecting $ do
          opened <- openInventoryForPlanning target
          snapshot <- openedSnapshot opened
          planInventoryCandidateLoaded (fixturePlan fixture) target opened (ok (composeInventory snapshot (ReplaceScope fixtureScope :| []))) directory
        map (\counts -> map (`countOf` counts) [StoreOpen, HeadRead, HistoryLoad, Listing]) planned @?= [[1, 1, 1, 0]]
        (_, applied) <- collectStoreCounters (collecting (applyInventoryWithFactory (fixtureApply fixture) target directory True))
        map (\counts -> map (`countOf` counts) [StoreOpen, HistoryLoad, Listing]) applied @?= [[1, 1, 0]]
    , testCase "inventory publications reads the recorded state alone" $ withFixture $ \fixture -> do
        listing <- readPublications (fixtureTarget fixture) >>= either (\(_, reason) -> fail (T.unpack reason)) pure
        listing ^. #publications @?= []
        validateToJSON listing @?= []
    , testCase "a site's deploy preview names its scope, configuration digest and reviewed inputs (EP-263)" $ do
        let shown = deployPreview siteStamped []
            typed = ok (canonicalValue (ok (eitherDecode @Value (encodeStaticSite fixtureSite))))
        (shown ^. #application . #scope, shown ^. #application . #configDigest, shown ^. #application . #overrides, length (shown ^. #hooks))
          @?= ("standalone:site-demo", Nullable (Just (Resource.digestText (contentDigest typed))), siteInputs, 0)
        validateToJSON shown @?= []
    , testCase "reviewed site inputs go only on a site scope and are tag, imageResource and an optional baseDomain (EP-263)" $ do
        let record inputs = recordReviewedSiteInputs (encodeStaticSite fixtureSite) inputs
        map
          isLeft
          [ record siteInputs fixtureScope
          , record (Map.insert "cdnBackend" "x" siteInputs) siteScope
          , record (Map.delete "tag" siteInputs) siteScope
          , record (Map.insert "baseDomain" "example.com" siteInputs) siteScope
          ]
          @?= [True, True, True, False]
    , testCase "a site's saved review applies, and the accepted scope agrees with the preview a client decoded (EP-263)" $ withFixture $ \fixture -> do
        acceptFoundation fixture
        -- The client reads only the two documents: the preview's scope, digest
        -- and inputs, and the saved review's scopes and directory.
        shown :: DeployPreview <- decodeOne =<< collecting (emitDocument (deployPreview siteStamped []))
        candidate <- siteCandidate fixture siteStamped
        saved :: SavedReview <- decodeOne =<< collecting (planInventoryCandidateWith (sitePlan fixture) (fixtureTarget fixture) candidate (fixtureRoot fixture </> "site-review"))
        saved ^. #scopes @?= [shown ^. #application . #scope]
        applied :: TransactionOutcome <- decodeOne =<< collecting (applyInventoryWithFactory (fixtureApply fixture) (fixtureTarget fixture) (T.unpack (saved ^. #review . #directory)) True)
        applied ^. #outcome @?= OutcomeConverged
        accepted <- acceptedSiteScope fixture
        (Nullable (Resource.digestText <$> scopeConfigDigest accepted), scopeOverrides accepted)
          @?= (shown ^. #application . #configDigest, shown ^. #application . #overrides)
    , testCase "stamping an accepted unstamped site scope is a review with no member operation (EP-263)" $ withFixture $ \fixture -> do
        acceptFoundation fixture
        unstamped' <- siteCandidate fixture siteScope
        (_, first') <- convergeInventoryCandidateResult (sitePlan fixture) (fixtureApply fixture) (fixtureTarget fixture) unstamped'
        assertBool "unstamped site converged" (case first' of Converged _ -> True; _ -> False)
        let directory = fixtureRoot fixture </> "stamp-review"
        candidate <- siteCandidate fixture siteStamped
        saved :: SavedReview <- decodeOne =<< collecting (planInventoryCandidateWith (sitePlan fixture) (fixtureTarget fixture) candidate directory)
        bundle <- loadReviewBundle directory >>= either (fail . T.unpack) pure
        (saved ^. #scopes, length (reviewOperations (reviewBundleDocument bundle))) @?= (["standalone:site-demo"], 0)
        applied :: TransactionOutcome <- decodeOne =<< collecting (applyInventoryWithFactory (fixtureApply fixture) (fixtureTarget fixture) directory True)
        applied ^. #outcome @?= OutcomeConverged
        accepted <- acceptedSiteScope fixture
        (isJust (scopeConfigDigest accepted), scopeOverrides accepted) @?= (True, siteInputs)
    , testCase "a deployer's site plan outside its delegation is one refused outcome and publishes nothing (EP-263)" $ withFixture $ \fixture -> do
        acceptFoundation fixture
        store <- openTargetStore (fixtureTarget fixture)
        before <- readHead store >>= either (fail . show) pure
        let deployer = fixtureTarget fixture & #profile . #deployer .~ Just "kotei"
            directory = fixtureRoot fixture </> "refused-review"
        candidate <- siteCandidate fixture siteStamped
        printed <- newIORef []
        setContractSinkTo (\line -> modifyIORef' printed (line :))
        exited <- try (planInventoryCandidateWith (sitePlan fixture) deployer candidate directory) `finally` clearContractSink
        refused :: TransactionOutcome <- decodeOne . reverse =<< readIORef printed
        (exited, refused ^. #outcome) @?= (Left (ExitFailure 2), OutcomeRefused)
        after <- readHead store >>= either (fail . show) pure
        reviewed <- doesDirectoryExist directory
        (after == before, reviewed) @?= (True, False)
    ]
  where
    fromNullable' (Nullable value) = value

data Fixture = Fixture
  { fixtureRoot :: !FilePath
  , fixtureTarget :: !ActiveTarget
  , fixtureCandidate :: !CompositionCandidate
  , fixturePlan :: !(CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  , fixtureApply :: !(ReviewInventory -> ReviewBundle -> IO AdapterRegistry)
  , fixtureResource :: !Resource.ResourceId
  , fixturePlanFor :: !(Map.Map Resource.ResourceId (ManagedResource, ByteString) -> CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  }

-- | A local context with one ConfigMap scope to accept, under a temporary
-- XDG_STATE_HOME (each shard runs one test at a time).
withFixture :: (Fixture -> IO ()) -> IO ()
withFixture body = withSystemTempDirectory "contract-commands" $ \root -> do
  previous <- lookupEnv "XDG_STATE_HOME"
  setEnv "XDG_STATE_HOME" root
  (setup root >>= body) `finally` maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME") previous
  where
    setup root = do
      observed <- newIORef Map.empty
      let operations =
            KubernetesAdapterOps
              { kubernetesContext = fixtureContext
              , kubernetesObserveStamped = unstamped $ \identity ->
                  Map.findWithDefault (KubernetesAbsent (contentDigest "absent")) identity <$> readIORef observed
              , kubernetesMutateConditional = \mutation -> do
                  let identity = mutationResource mutation
                  modifyIORef' observed (Map.insert identity (KubernetesPresent (ok (Resource.mkPhysicalIdentity "uid-contract")) "1" (Just identity) (mutationNativeDigest mutation)))
                  pure AdapterEffectCompleted
              }
          registryFor specs = ok (mkAdapterRegistry [mkKubernetesAdapter specs operations])
      store <- openTargetStore fixtureActive
      _ <- initializeStore store fixtureBinding "contract-commands" >>= either (fail . show) pure
      before <- loadTargetSnapshot fixtureActive
      pure
        Fixture
          { fixtureRoot = root
          , fixtureTarget = fixtureActive
          , fixtureCandidate = ok (composeInventory before (ReplaceScope fixtureScope :| []))
          , fixturePlan = \_ _ -> pure (registryFor (Map.singleton fixtureMember (member, native)))
          , fixtureApply = \_ bundle -> pure (registryFor (ok (kubernetesSpecsFromReview bundle)))
          , fixtureResource = fixtureMember
          , fixturePlanFor = \specs _ _ -> pure (registryFor specs)
          }

fixtureContext :: Resource.ContextId
fixtureContext = ok (Resource.mkContextId "contract-commands")

fixtureBinding :: Resource.ContextBinding
fixtureBinding = Resource.ContextBinding fixtureContext (ok (Resource.mkName "project"))

fixtureActive :: ActiveTarget
fixtureActive = ActiveTarget (ok (mkContextName "contract-commands")) (initProfile & #project .~ "project" & #mode .~ Local)

fixtureOwner :: Resource.ScopeId
fixtureOwner = ok (Resource.mkScopeId Resource.Application "command-fixture")

fixtureMember :: Resource.ResourceId
fixtureMember = Resource.mintResourceId fixtureOwner (ok (Resource.mkLogicalKey "config")) (ok (Resource.mkName "configmap"))

member :: ManagedResource
native :: ByteString
(member, native) =
  ok
    ( bindKubernetesObject
        ( KubernetesInput
            fixtureMember
            fixtureOwner
            cluster
            value
            (contentDigest (ok (canonicalValue value)))
            DeleteWhenUnreferenced
            Stateless
            Private
            (Resource.SourceLocation "absent-source/Config.hs" "command")
        )
    )
  where
    foundation = ok (Resource.mkScopeId Resource.Platform "foundation")
    cluster = Resource.mintResourceId foundation (ok (Resource.mkLogicalKey "cluster")) (ok (Resource.mkName "resource"))
    value =
      Aeson.object
        [ "apiVersion" Aeson..= ("v1" :: Text)
        , "kind" Aeson..= ("ConfigMap" :: Text)
        , "metadata" Aeson..= Aeson.object ["name" Aeson..= ("contract-commands" :: Text), "namespace" Aeson..= ("default" :: Text)]
        , "data" Aeson..= Aeson.object ["key" Aeson..= ("value" :: Text)]
        ]

fixtureScope :: ScopeDeclaration
fixtureScope = ok (mkScopeDeclaration fixtureOwner [ResourceBundle [Managed member] [] [] [] [] []])

-- ---------------------------------------------------------------------------
-- EP-263: a static site, compiled as the production site deploy compiles it,
-- against a foundation that declares its cluster, namespace and image.

fixtureSite :: StaticSite
fixtureSite = baseSite (NoBuild (ok (mkFilePathText "dist")))

siteFoundation :: Resource.ScopeId
siteFoundation = ok (Resource.mkScopeId Resource.Platform "foundation")

siteDependency :: Text -> Text -> Resource.ResourceId
siteDependency key name = Resource.mintResourceId siteFoundation (ok (Resource.mkLogicalKey key)) (ok (Resource.mkName name))

siteCluster, siteNamespace, siteImage :: Resource.ResourceId
siteCluster = siteDependency "cluster" "resource"
siteNamespace = siteDependency "namespace" "resource"
siteImage = siteDependency "image" "publication"

siteInputs :: Map.Map Text Text
siteInputs = Map.fromList [("imageResource", Resource.resourceIdText siteImage), ("tag", "v1")]

siteCompiled :: (ScopeDeclaration, Map.Map Resource.ResourceId (ManagedResource, ByteString))
siteCompiled =
  ok
    ( compileStaticSiteScope
        (DeployInputs fixtureSite "v1" "example.com" "." True initProfile)
        siteCluster
        siteNamespace
        siteImage
        Map.empty
        emptyReleaseLog
        (StaticRelease "v1" "demo" "personal" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo" "v1" (staticUrl fixtureSite "example.com") Nothing (UTCTime (fromGregorian 2026 11 18) 0))
        (Resource.SourceLocation "fixture" "static-site")
    )

siteScope, siteStamped :: ScopeDeclaration
siteScope = fst siteCompiled
siteStamped = ok (recordReviewedSiteInputs (encodeStaticSite fixtureSite) siteInputs siteScope)

siteOwner :: Resource.ScopeId
siteOwner = ok (Resource.mkScopeId Resource.Standalone "site-demo")

sitePlan :: Fixture -> CompositionCandidate -> InventoryHistory -> IO AdapterRegistry
sitePlan fixture = fixturePlanFor fixture (snd siteCompiled)

siteCandidate :: Fixture -> ScopeDeclaration -> IO CompositionCandidate
siteCandidate fixture scope = do
  before <- loadTargetSnapshot (fixtureTarget fixture)
  pure (ok (composeInventory before (ReplaceScope scope :| [])))

-- | Accept the foundation the site depends on; it declares only externals.
acceptFoundation :: Fixture -> IO ()
acceptFoundation fixture = do
  before <- loadTargetSnapshot (fixtureTarget fixture)
  let external resource name = External resource (Resource.Artifact (ok (Resource.mkName name)) (contentDigest (TE.encodeUtf8 name))) [] (Resource.SourceLocation "fixture" "foundation")
      foundation = ok (mkScopeDeclaration siteFoundation [ResourceBundle [external siteCluster "cluster", external siteNamespace "namespace", external siteImage "image"] [] [] [] [] []])
  (_, result) <-
    convergeInventoryCandidateResult (fixturePlanFor fixture Map.empty) (fixtureApply fixture) (fixtureTarget fixture) (ok (composeInventory before (ReplaceScope foundation :| [])))
  case result of
    Converged _ -> pure ()
    other -> assertFailure ("foundation did not converge: " <> show other)

acceptedSiteScope :: Fixture -> IO ScopeDeclaration
acceptedSiteScope fixture = do
  accepted <- loadTargetSnapshot (fixtureTarget fixture)
  maybe (assertFailure "the site scope was not accepted" >> fail "absent") (pure . snd) (Map.lookup siteOwner (snapshotScopes accepted))

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

collecting :: IO () -> IO [LBS.ByteString]
collecting action = do
  printed <- newIORef []
  setContractSinkTo (\line -> modifyIORef' printed (line :))
  action `finally` clearContractSink
  reverse <$> readIORef printed

decodeOne :: (Aeson.FromJSON a) => [LBS.ByteString] -> IO a
decodeOne = \case
  [line] -> either (\failure -> assertFailure failure >> fail "decode") pure (eitherDecode line)
  other -> assertFailure ("expected one document, got " <> show (length other)) >> fail "documents"
