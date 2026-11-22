-- | EP-232 M1: a converged application release yields one @app.deployed@
-- event through the real planner, executor, journal and feed; a stopped,
-- repeated or provenance-only transaction yields none.
module EventsDeploymentSpec
  ( eventsDeploymentTests
  , World (..)
  , withWorld
  , deploy
  , deployWith
  , retire
  , resume
  , closeStopped
  , feedEntries
  , notes
  , notesBase
  , docs
  , releaseLog
  , notesScope
  , docsScope
  , binding
  , scopeWith
  , workload
  , history
  , assertConverged
  , checked
  , orFail
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Static.Types (StaticBuild (NoBuild), mkFilePathText)
import Nagare.Events.Deployment (deploymentKey)
import Nagare.Events.Envelope (encodeEnvelope, eventIdFor)
import Nagare.Events.Materialize (defaultBudget, enableFeed, materializeOnce)
import Nagare.Events.Read (FeedEntry, readPage, readRequest)
import Nagare.Events.Source (AppDeployment (..), DeploymentAction (..), DeploymentSubject (..), EventKind (AppDeployed), EventPayload (..), initialCheckpoint, payloadKind)
import Nagare.Events.Store (FeedStore, memoryObjectOps, newFeedStore)
import Nagare.Inventory.Adapter (Adapter (..), AdapterExecution (..), AdapterRegistry, PlannedOperation (..), RecoveryDecision (RecoveryLandedUnready), Settlement (SettledLanded), lookupAdapter, mkAdapterRegistry, observationMap, observeWithRegistry)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesMutation (..), KubernetesState (..), mkKubernetesAdapter, unstamped)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (CloseInput (..), TransactionResult (..), applyReviewed, closeTransaction, resumeTransaction)
import Nagare.Inventory.Journal (TransactionId, reviewDigestOf)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan
import Nagare.Inventory.Site (compileStaticSiteRollbackScope, compileStaticSiteScope)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (Declaration (..), Executor (KubernetesExecutor), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope, RetireScope), ScopeDeclaration, ScopeSnapshot, composeInventory, mkScopeDeclaration, mkScopeSnapshot)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), RetirementIntent (RetainResources), Sensitivity (Private))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Static.Deploy (DeployInputs (..), staticUrl)
import Nagare.Static.Release (StaticRelease (..), StaticReleaseLog (..), addRelease, emptyReleaseLog, extractReleaseLog, renderReleaseConfigMapWith)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.Support.Site (baseSite)
import Test.Tasty
import Test.Tasty.HUnit

eventsDeploymentTests :: TestTree
eventsDeploymentTests =
  testGroup
    "Events.Deployment"
    [ testCase "a new release of a two-workload application is one event; rerunning it is none" $ withWorld $ \world -> do
        first' <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        assertConverged first'
        events <- published world
        map summary events @?= [(ApplicationSubject, DeployAction, "r1", Nothing, notesScope)]
        rerun <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        assertConverged rerun
        published world >>= (@?= events)
    , testCase "a later release names the previous one; a re-selection of a recorded release is a rollback" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        _ <- deploy world [notes (releaseLog ["r2", "r1"] "r2") "v2"]
        _ <- deploy world [notes (releaseLog ["r2", "r1"] "r1") "v1"]
        events <- published world
        map summary events
          @?= [ (ApplicationSubject, DeployAction, "r1", Nothing, notesScope)
              , (ApplicationSubject, DeployAction, "r2", Just "r1", notesScope)
              , (ApplicationSubject, RollbackAction, "r1", Just "r2", notesScope)
              ]
    , testCase "a workload change that keeps the release is no deployment event" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        changed <- deploy world [notes (releaseLog ["r1"] "r1") "v1-patched"]
        assertConverged changed
        events <- published world
        length events @?= 1
    , testCase "two subjects in one transaction are two events" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1", docs (releaseLog ["d1"] "d1")]
        events <- published world
        map (\(_, _, release, _, scope) -> (release, scope)) (map summary events) @?= [("d1", docsScope), ("r1", notesScope)]
    , testCase "a stopped rollout announces nothing; its resume announces the release once, under the original identity" $ withWorld $ \world -> do
        writeIORef (world ^. #interruptNext) True
        stopped <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        transaction <- case stopped of
          StoppedAmbiguous token _ _ -> pure token
          other -> assertFailure ("expected the rollout to stop, got " <> show other) >> fail "stop"
        published world >>= (@?= [])
        resumed <- resume world transaction
        resumed @?= Converged transaction
        events <- published world
        map summary events @?= [(ApplicationSubject, DeployAction, "r1", Nothing, notesScope)]
        let expected = eventIdFor (binding ^. #identity) (either (error . T.unpack) id (deploymentKey transaction notesScope))
        map (^. #envelope . #eventId) events @?= [expected]
        -- Materializing again changes nothing.
        published world >>= (@?= events)
    , testCase "pruning recorded releases that keeps the current one is no deployment event" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r2", "r1"] "r2") "v2"]
        pruned <- deploy world [notes (releaseLog ["r2"] "r2") "v2"]
        assertConverged pruned
        events <- published world
        map (\(_, _, release, _, _) -> release) (map summary events) @?= ["r2"]
    , testCase "a static site deploys through its compiler, and its reviewed rollback is a rollback event (M2)" $ withWorld $ \world -> do
        let v1 = siteRelease "v1" 1
            v2 = siteRelease "v2" 2
            logV1 = addRelease v1 emptyReleaseLog
            logV2 = addRelease v2 logV1
        first' <- deploy world [foundation, checked (compileStaticSiteScope (siteInputs "v1") foundationCluster foundationNamespace foundationImage Map.empty emptyReleaseLog v1 siteSource)]
        assertConverged first'
        _ <- deploy world [foundation, checked (compileStaticSiteScope (siteInputs "v2") foundationCluster foundationNamespace foundationImage Map.empty logV1 v2 siteSource)]
        rolled <- deploy world [foundation, checked (compileStaticSiteRollbackScope (siteInputs "v1") foundationCluster foundationNamespace foundationImage Map.empty logV2 v1 siteSource)]
        assertConverged rolled
        events <- published world
        map summary events
          @?= [ (SiteSubject, DeployAction, "v1", Nothing, siteScope)
              , (SiteSubject, DeployAction, "v2", Just "v1", siteScope)
              , (SiteSubject, RollbackAction, "v1", Just "v2", siteScope)
              ]
    , testCase "a standalone service's release is a service event (M2)" $ withWorld $ \world -> do
        let service = checked (mkScopeId Standalone "service-api")
        _ <- deploy world [scopeWith service [workload service "api" "s1", history service "api" (releaseLog ["s1"] "s1")]]
        events <- published world
        map summary events @?= [(ServiceSubject, DeployAction, "s1", Nothing, service)]
    , testCase "a site preview's scope announces nothing" $ withWorld $ \world -> do
        let preview = checked (mkScopeId Standalone "site-preview-demo-pr-1")
        _ <- deploy world [scopeWith preview [workload preview "web" "p1", history preview "release-history" (releaseLog ["p1"] "p1")]]
        published world >>= (@?= [])
    , testCase "an event carries no secret, environment or native payload" $ withWorld $ \world -> do
        _ <- deploy world [notes (releaseLog ["r1"] "r1") "v1"]
        events <- published world
        let encoded = mconcat [encodeEnvelope (entry ^. #envelope) | entry <- events]
        assertBool "the native workload leaked into the event" (not ("example.test/notes" `isInfix` encoded))
        assertBool "the release log leaked into the event" (not ("releases.json" `isInfix` encoded))
    ]
  where
    isInfix needle haystack = T.isInfixOf needle (T.pack (show haystack))

-- * The world

data World = World
  { store :: !InventoryStore
  , feed :: !FeedStore
  , observed :: !(IORef (Map.Map ResourceId KubernetesState))
  , interruptNext :: !(IORef Bool)
  , natives :: !(IORef (Map.Map ResourceId (ManagedResource, ByteString)))
  }
  deriving stock (Generic)

withWorld :: (World -> Assertion) -> Assertion
withWorld action = do
  inventory <- newMemoryStore
  _ <- initializeStore inventory binding "client-events" >>= orFail
  _ <- seedInventoryHistory inventory (checked (composeInventory (snapshot Map.empty) (ReplaceScope (notesBase "v0") :| []))) >>= orFail
  feedStore <- memoryObjectOps >>= newFeedStore
  _ <- enableFeed feedStore binding "deployment-epoch" initialCheckpoint >>= orFail
  world <- World inventory feedStore <$> newIORef Map.empty <*> newIORef False <*> newIORef Map.empty
  action world

-- | Review the scopes against the accepted history and apply the review.
deploy :: World -> [(ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))] -> IO TransactionResult
deploy world = deployWith world id

-- | 'deploy', with the prepared review changed before it is published.
deployWith :: World -> (ReviewBundle -> ReviewBundle) -> [(ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))] -> IO TransactionResult
deployWith world amend scopes = applyChanges world amend (ReplaceScope (fst (headOf scopes)) :| map (ReplaceScope . fst) (drop 1 scopes)) (Map.unions (map snd scopes))
  where
    headOf = \case
      value : _ -> value
      [] -> error "no scope to deploy"

-- | Retire a scope, retaining its members.
retire :: World -> ScopeId -> IO TransactionResult
retire world scope = applyChanges world id (RetireScope scope RetainResources :| []) Map.empty

-- | Review these changes against the accepted history and apply the review.
applyChanges :: World -> (ReviewBundle -> ReviewBundle) -> NonEmpty ScopeChange -> Map.Map ResourceId (ManagedResource, ByteString) -> IO TransactionResult
applyChanges world amend changes native = do
  history <- loadInventoryHistory (world ^. #store) >>= orFail
  let candidate = checked (composeInventory (snapshot (historyAccepted history)) changes)
      selected = registry world native
  facts <- observeWithRegistry selected (requirementsByExecutor (observationRequirements candidate history)) >>= orFail
  -- Every accepted member a retirement leaves out is approved for retirement.
  let retiring = [owner | RetireScope owner _ <- toList changes]
      proposals =
        [ LifecycleProposal resource ApproveRetirement (lifecycleObservationDigest binding resource fact)
        | (resource, fact) <- Map.toAscList (observationMap facts)
        , any (\owner -> (scopeIdText owner <> "/") `T.isPrefixOf` resourceIdText resource) retiring
        ]
  decisions <- if null retiring then pure noLifecycleDecisions else orFail (validateLifecycleDecisions candidate history facts proposals)
  proposal <- orFail (planChanges candidate decisions history facts)
  state <- readStoreSnapshot (world ^. #store) >>= orFail
  bundle <- amend <$> (prepareReview selected state proposal >>= orFail)
  _ <- publishReview (world ^. #store) bundle >>= orFail
  published' <- readStoreSnapshot (world ^. #store) >>= orFail
  reviewed <- orFail (verifyReview published' bundle)
  let bound = checked (kubernetesSpecsFromReview bundle)
  writeIORef (world ^. #natives) bound
  applyReviewed (world ^. #store) (registry world bound) reviewed >>= orFail

resume :: World -> TransactionId -> IO TransactionResult
resume world transaction = do
  bound <- readIORef (world ^. #natives)
  resumeTransaction (world ^. #store) (registry world bound) transaction >>= orFail

-- | Close a stopped transaction by per-operation proof, the interrupted
-- update having landed but never become ready, so resume cannot progress.
closeStopped :: World -> TransactionId -> Assertion
closeStopped world transaction = do
  bound <- readIORef (world ^. #natives)
  review <- maybe (assertFailure "the transaction names no review" >> fail "review") pure (reviewDigestOf transaction)
  let kubernetes = checked (lookupAdapter (registry world bound) KubernetesExecutor)
      landed = checked (mkAdapterRegistry [kubernetes {adapterRecover = \_ _ -> pure (RecoveryLandedUnready (checked (mkPhysicalIdentity "uid-landed"))), adapterSettle = Just (\_ _ -> pure (SettledLanded (checked (mkPhysicalIdentity "uid-landed"))))}])
  closed <- closeTransaction (world ^. #store) landed (CloseInput transaction review False Nothing)
  either (\errors -> assertFailure ("close refused: " <> show errors)) (const (pure ())) closed

-- | A fake Kubernetes API: every write lands; the next one, when armed, loses
-- its acknowledgement.
registry :: World -> Map.Map ResourceId (ManagedResource, ByteString) -> AdapterRegistry
registry world native = checked (mkAdapterRegistry [mkKubernetesAdapter native operations])
  where
    operations =
      KubernetesAdapterOps
        { kubernetesContext = binding ^. #identity
        , kubernetesObserveStamped = unstamped $ \identity -> Map.findWithDefault (KubernetesAbsent (contentDigest "absent")) identity <$> readIORef (world ^. #observed)
        , kubernetesMutateConditional = \mutation -> do
            modifyIORef'
              (world ^. #observed)
              (Map.insert (mutationResource mutation) (KubernetesPresent (checked (mkPhysicalIdentity ("uid-" <> resourceIdText (mutationResource mutation)))) "1" (Just (mutationResource mutation)) (mutationNativeDigest mutation)))
            interrupted <- readIORef (world ^. #interruptNext)
            if interrupted
              then writeIORef (world ^. #interruptNext) False >> pure (AdapterEffectAmbiguous "lost rollout acknowledgement")
              else pure AdapterEffectCompleted
        }

-- | Materialize everything committed so far and read the deployment events
-- back.
published :: World -> IO [FeedEntry]
published world = filter (\entry -> payloadKind (entry ^. #envelope . #payload) == AppDeployed) <$> feedEntries world

-- | Materialize everything committed so far and read the whole feed back.
feedEntries :: World -> IO [FeedEntry]
feedEntries world = do
  _ <- materializeOnce (world ^. #store) (world ^. #feed) binding defaultBudget (pure "2026-11-17T00:00:00Z") >>= orFail
  page <- readPage (world ^. #feed) binding readRequest >>= orFail
  pure (page ^. #entries)

summary :: FeedEntry -> (DeploymentSubject, DeploymentAction, Text, Maybe Text, ScopeId)
summary entry = case entry ^. #envelope . #payload of
  AppDeployedPayload deployment -> (deployment ^. #subject, deployment ^. #action, deployment ^. #release, deployment ^. #previousRelease, entry ^. #envelope . #resource . #scope)
  other -> error ("not a deployment: " <> show other)

assertConverged :: TransactionResult -> Assertion
assertConverged = \case
  Converged _ -> pure ()
  other -> assertFailure ("expected convergence, got " <> show other)

-- * Sites

siteScope :: ScopeId
siteScope = checked (mkScopeId Standalone "site-demo")

foundationScope :: ScopeId
foundationScope = checked (mkScopeId Platform "foundation")

foundationCluster, foundationNamespace, foundationImage :: ResourceId
foundationCluster = mintResourceId foundationScope (checked (mkLogicalKey "cluster")) (checked (mkName "resource"))
foundationNamespace = mintResourceId foundationScope (checked (mkLogicalKey "namespace")) (checked (mkName "resource"))
foundationImage = mintResourceId foundationScope (checked (mkLogicalKey "image")) (checked (mkName "publication"))

-- | The platform members a site depends on.
foundation :: (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
foundation =
  scopeWith
    foundationScope
    [ member foundationScope (checked (mkLogicalKey key)) (checked (mkName role)) (configMap ("foundation-" <> key))
    | (key, role) <- [("cluster", "resource"), ("namespace", "resource"), ("image", "publication")]
    ]
  where
    configMap name = Aeson.object ["apiVersion" Aeson..= ("v1" :: Text), "kind" Aeson..= ("ConfigMap" :: Text), "metadata" Aeson..= Aeson.object ["name" Aeson..= name, "namespace" Aeson..= ("nagare-system" :: Text)], "data" Aeson..= Aeson.object []]

siteInputs :: Text -> DeployInputs
siteInputs tag = DeployInputs (baseSite (NoBuild (checked (mkFilePathText "dist")))) tag "example.com" "." True initProfile

siteRelease :: Text -> Integer -> StaticRelease
siteRelease tag seconds =
  StaticRelease tag "demo" "personal" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/demo" tag (staticUrl (baseSite (NoBuild (checked (mkFilePathText "dist")))) "example.com") Nothing (UTCTime (fromGregorian 2026 11 17) (fromInteger seconds))

siteSource :: SourceLocation
siteSource = SourceLocation "fixture" "static-site"

-- * Scopes

binding :: ContextBinding
binding = ContextBinding (checked (mkContextId "events-deploy")) (checked (mkName "project"))

notesScope, docsScope :: ScopeId
notesScope = checked (mkScopeId Application "notes")
docsScope = checked (mkScopeId Application "docs")

-- | The application before any release: its web workload only.
notesBase :: Text -> ScopeDeclaration
notesBase tag = fst (scopeWith notesScope [workload notesScope "web" tag])

-- | The notes application: a web and a worker workload and its release log.
notes :: StaticReleaseLog -> Text -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
notes logv tag = scopeWith notesScope [workload notesScope "web" tag, workload notesScope "worker" tag, history notesScope "notes" logv]

docs :: StaticReleaseLog -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
docs logv = scopeWith docsScope [workload docsScope "web" "d", history docsScope "docs" logv]

scopeWith :: ScopeId -> [(ResourceId, (ManagedResource, ByteString))] -> (ScopeDeclaration, Map.Map ResourceId (ManagedResource, ByteString))
scopeWith owner members =
  ( checked (mkScopeDeclaration owner [ResourceBundle [Managed managed | (_, (managed, _)) <- members] [] [] [] [] []])
  , Map.fromList members
  )

workload :: ScopeId -> Text -> Text -> (ResourceId, (ManagedResource, ByteString))
workload owner name tag =
  member owner (checked (mkLogicalKey name)) (checked (mkName "service")) $
    Aeson.object
      [ "apiVersion" Aeson..= ("serving.knative.dev/v1" :: Text)
      , "kind" Aeson..= ("Service" :: Text)
      , "metadata" Aeson..= Aeson.object ["name" Aeson..= (nameText (scopeName owner) <> "-" <> name), "namespace" Aeson..= ("personal" :: Text)]
      , "spec" Aeson..= Aeson.object ["template" Aeson..= Aeson.object ["spec" Aeson..= Aeson.object ["containers" Aeson..= [Aeson.object ["image" Aeson..= ("example.test/" <> nameText (scopeName owner) <> ":" <> tag)]]]]]
      ]

-- | The release log member, as the application compiler names it.
history :: ScopeId -> Text -> StaticReleaseLog -> (ResourceId, (ManagedResource, ByteString))
history owner subject logv =
  member owner (checked (mkLogicalKey subject)) (checked (mkName "release-history")) $
    either error id (Aeson.eitherDecodeStrict (renderReleaseConfigMapWith "nagare-app-deployments-" subject "personal" logv))

member :: ScopeId -> LogicalKey -> Name -> Aeson.Value -> (ResourceId, (ManagedResource, ByteString))
member owner key role value =
  let identity = mintResourceId owner key role
      cluster = mintResourceId owner (checked (mkLogicalKey "cluster")) (checked (mkName "cluster"))
      bytes = checked (canonicalValue value)
   in (identity, checked (bindKubernetesObject (KubernetesInput identity owner cluster value (contentDigest bytes) DeleteWhenUnreferenced Stateless Private (SourceLocation "fixture" (resourceIdText identity)))))

-- | A log of these release ids, newest first, with @current@ selected.
releaseLog :: [Text] -> Text -> StaticReleaseLog
releaseLog ids current' =
  (foldr (\(index, releaseId) logv -> addRelease (record index releaseId) logv) emptyReleaseLog (zip [0 :: Integer ..] (reverse ids))) {current = Just current'}
  where
    record index releaseId =
      StaticRelease releaseId "notes" "personal" "example.test/notes" releaseId "https://notes.example.test" Nothing (UTCTime (fromGregorian 2026 11 17) (fromInteger index))

snapshot :: Map.Map ScopeId (ScopeRevision, ScopeDeclaration) -> ScopeSnapshot
snapshot accepted = checked (mkScopeSnapshot binding (Map.map (\(revision, scope) -> (revisionGeneration revision, scope)) accepted) Map.empty)

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

orFail :: (Show e) => Either e a -> IO a
orFail = either (\err -> assertFailure (show err) >> fail "unreachable") pure
