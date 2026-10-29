-- | EP-224 M1: the command trace. Its codec, its span accounting, its file
-- and, through the production planner, driver and Kubernetes runtime over the
-- fake API server, the counts a no-op, a verify sweep and changed rollouts
-- really make.
module TransitionCostSpec (transitionCostTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Exception (AsyncException (UserInterrupt), ErrorCall (..), SomeException, finally, throwIO, try)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Contract.Trace
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterRegistry, mkAdapterRegistry)
import Nagare.Inventory.Adapters.KubernetesApplication (kubernetesApplicationAdapter)
import Nagare.Inventory.Command (applyInventoryWithFactory, convergeInventoryCandidateResult, loadTargetSnapshot, openTargetStore, planInventoryCandidateWith)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.KubernetesSnapshot (snapshotRuntime)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), countedTransport, invokeKubectl, runKubectlWith, withKubectlInterpreter)
import Nagare.Inventory.Store (HeadManifest (headActiveTransaction, headGeneration, headSequence), StoreError (StoreIoError), initializeStore, newObjectStore, readHead)
import Nagare.Inventory.Store.Counters (CommandTrace, collectCommandTrace, labelled, rootContext, withSpan)
import Nagare.Inventory.Store.ObjectOps (ObjectName (..), ObjectOps (..), PutOutcome (PutUnknown))
import Nagare.Inventory.Trace (commandTraceDocument, withCommandTrace)
import Nagare.Ops.ClusterGuard (ClusterGuardOps (..), admitClusterGuard, defaultClusterGuardOps)
import Nagare.Resource.Inventory (CompositionCandidate, Declaration (..), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope), ScopeDeclaration, composeInventory, mkScopeDeclaration)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (ActiveTarget (..), Mode (Local), mkContextName)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Test.World.Adversary (newAdversary)
import Nagare.Test.World.ApiServer (ObjectKey (..), Preconditions (..), Propagation (Background), create, delete, emptyServer, get, patchJson)
import Nagare.Test.World.Cluster (Cluster, clusterAnswer, modifyServer, newCluster, readServer)
import Nagare.Test.World.ObjectStore (fakeObjectOps)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

transitionCostTests :: TestTree
transitionCostTests =
  testGroup
    "TransitionCost (EP-224 M1)"
    [ testCase "a trace document round-trips and an unknown schema version refuses" $ do
        let document = sampleDocument
        decodeTraceDocument (LBS.toStrict (Aeson.encode document)) @?= Right document
        let future = LBS.toStrict (Aeson.encode (document & #schemaVersion .~ 2))
        assertBool "a future schema decoded" (either ("unsupported trace schema version 2" `T.isInfixOf`) (const False) (decodeTraceDocument future))
    , testCase "uncovered time subtracts overlapping root spans once and ignores children" $ do
        let at identity parent start end = TraceSpan identity parent "step" noLabels start end ResultSucceeded
            document =
              sampleDocument
                & #elapsedNanos
                .~ 100
                & #spans
                .~ [at 0 Nothing 10 40, at 1 Nothing 30 50, at 2 (Just 0) 0 100, at 3 Nothing 70 80]
        -- Roots cover 10..50 and 70..80: 50 of 100 nanoseconds.
        uncoveredNanos document @?= 50
    , testCase "a thrown phase is recorded as thrown and its exception propagates unchanged" $ do
        (outcome, traced) <- collectCommandTrace (try (withSpan rootContext "doomed" (const (throwIO (ErrorCall "boom")))))
        case outcome of
          Left (ErrorCall message) -> message @?= "boom"
          Right () -> assertFailure "the exception was swallowed"
        map (\recorded -> (recorded ^. #phase, recorded ^. #result)) (traced ^. #spans) @?= [("doomed", ResultThrew)]
    , testCase "overlapping operations keep their own labels and parents" $ do
        let step name = withSpan (labelled (noLabels & #operation ?~ name)) ("operation " <> name) $ \context ->
              withSpan context "effect" (const (threadDelay 20000))
        (_, traced) <- collectCommandTrace (concurrently_ (step "a") (step "b"))
        let recorded = traced ^. #spans
            byId = Map.fromList [(entry ^. #spanId, entry) | entry <- recorded]
            effects = [entry | entry <- recorded, entry ^. #phase == "effect"]
        length effects @?= 2
        forM_ effects $ \effect -> case effect ^. #parent >>= (`Map.lookup` byId) of
          Just parent -> (effect ^. #labels, parent ^. #phase) @?= (parent ^. #labels, "operation " <> fromMaybe "" (parent ^. #labels . #operation))
          Nothing -> assertFailure "an effect span lost its parent"
        -- The two operations overlapped; their spans say so.
        case [entry | entry <- recorded, entry ^. #parent == Nothing] of
          [one, two] -> assertBool "operations did not overlap" (one ^. #startNanos < two ^. #endNanos && two ^. #startNanos < one ^. #endNanos)
          other -> assertFailure ("expected two operation spans, got " <> show (length other))
    , testCase "NAGARE_TRACE_FILE alone writes a private document however the command ends" $
        withSystemTempDirectory "trace-file" $ \directory -> do
          let path = directory </> "trace.json"
              secret = "do-not-trace-this-argument"
          completed <- tracedRun path (withSpan rootContext "work" (const (pure ())))
          (completed ^. #command, completed ^. #outcome, map (^. #phase) (completed ^. #spans)) @?= ("PlatformTransitionPlan", OutcomeCompleted, ["work"])
          failed <- tracedRun path (throwIO (ExitFailure 3))
          failed ^. #outcome @?= OutcomeFailed
          cancelled <- tracedRun path (throwIO UserInterrupt)
          cancelled ^. #outcome @?= OutcomeCancelled
          refused <- tracedRun path (throwIO (userError secret))
          refused ^. #outcome @?= OutcomeFailed
          status <- getFileStatus path
          intersectFileModes (fileMode status) 0o077 @?= 0
          bytes <- BS.readFile path
          assertBool "an argument reached the trace" (not (T.pack secret `T.isInfixOf` T.pack (show bytes)))
    , testCase "a snapshot hit is reuse, not transport" $ do
        let names = ["one", "two", "three"]
            listed = "{\"kind\":\"List\",\"items\":[" <> T.unpack (T.intercalate "," [T.pack (configMapYaml name) | name <- names]) <> "]}"
            config =
              withKubectlInterpreter
                (runKubectlWith (countedTransport (\_ -> pure (Right (ExitSuccess, listed, "")))))
                (KubernetesRuntimeConfig context "fake" (pure (Right ())))
        (_, traced) <- collectCommandTrace $ do
          snapshot <- snapshotRuntime config [configMapAddress name | name <- names]
          forM_ names $ \name -> invokeKubectl snapshot ["get", "configmap", T.unpack name, "--namespace", "default", "-o", "json", "--ignore-not-found"] ""
        document <- documentOf traced
        -- One grouped read leaves the process; the three single reads reuse it.
        (lookup "get configmap" (countsIn CategoryKubernetesTransport document), lookup "get configmap" (countsIn CategoryKubernetesReuse document), lookup "get configmap" (countsIn CategoryKubernetesLogical document))
          @?= (Just 1, Just 3, Just 4)
    , testCase "a denied guard is one refused admission and the programs it started" $
        withSystemTempDirectory "trace-guard" $ \directory -> do
          let ops = defaultClusterGuardOps & #kubectlExecutable .~ (directory </> "absent-kubectl")
          document <- tracedRun (directory </> "trace.json") $ do
            admitted <- admitClusterGuard ops "intranet" "nagare-01"
            assertBool "an unobservable cluster was admitted" (isLeft admitted)
          (countsIn CategoryGuard document, countsIn CategoryProcess document) @?= ([("refused", 1)], [("kubectl", 1)])
          map (\recorded -> (recorded ^. #phase, recorded ^. #result)) (document ^. #spans) @?= [("cluster guard", ResultSucceeded)]
    , testCase "a lost store reply is recorded as the put it was, not as success or silence" $
        withSystemTempDirectory "trace-store" $ \directory -> do
          base <- fakeObjectOps
          -- The head write lands, but its reply is lost.
          let lossy =
                base
                  { putObject = \condition name bytes -> do
                      outcome <- putObject base condition name bytes
                      pure (if name == ObjectName "head.json" then PutUnknown "reply lost" else outcome)
                  }
          seen <- newIORef Nothing
          document <- tracedRun (directory </> "trace.json") $ do
            store <- newObjectStore lossy (Resource.ContextBinding context (ok (Resource.mkName "project"))) "client" Nothing >>= either (fail . show) pure
            initialized <- withSpan rootContext "store initialization" (const (initializeStore store (Resource.ContextBinding context (ok (Resource.mkName "project"))) "client"))
            writeIORef seen (Just (either show (const "initialized") initialized))
          -- The store refuses: an unknown write is never reported as success.
          readIORef seen >>= (@?= Just (show (StoreIoError "reply lost")))
          document ^. #outcome @?= OutcomeCompleted
          assertBool "the put was not counted" (maybe False (> 0) (lookup "puts" (countsIn CategoryStore document)))
          map (^. #phase) (document ^. #spans) @?= ["store initialization"]
    , testCase "the production path counts a no-op, a verify sweep and changed rollouts" productionCosts
    , testCase "a marker sweep's journal writes do not grow with members and unrelated scopes cost nothing" structuralGrowth
    ]

-- | A command run under 'withCommandTrace' with only @NAGARE_TRACE_FILE@.
tracedRun :: FilePath -> IO () -> IO TraceDocument
tracedRun path action = do
  previous <- lookupEnv "NAGARE_TRACE_FILE"
  setEnv "NAGARE_TRACE_FILE" path
  _ <- try @SomeException (withCommandTrace "PlatformTransitionPlan" action) `finally` maybe (unsetEnv "NAGARE_TRACE_FILE") (setEnv "NAGARE_TRACE_FILE") previous
  BS.readFile path >>= either (\reason -> assertFailure (T.unpack reason) >> fail "decode") pure . decodeTraceDocument

-- | The document of a collected trace: its counts as the producer files them.
documentOf :: CommandTrace -> IO TraceDocument
documentOf = commandTraceDocument "fixture" OutcomeCompleted

sampleDocument :: TraceDocument
sampleDocument =
  TraceDocument
    traceSchemaVersion
    "PlatformTransitionPlan"
    OutcomeCompleted
    1000
    [TraceSpan 0 Nothing "observation" (noLabels & #stage ?~ "2") 0 900 ResultSucceeded]
    [TraceCount CategoryKubernetesTransport "get configmap" 3 400 0 0]
    [OperationCount RecordPlanned "VerifyResource" "KubernetesExecutor" 205]

-- * The production path

-- | Converge @members@ ConfigMaps and one bootstrap marker; then measure an
-- unchanged replan, a verify sweep (the marker changes, as a platform stage
-- does), one changed member and four independent changed members.
productionCosts :: Assertion
productionCosts = withSystemTempDirectory "transition-cost" $ \root -> do
  previous <- lookupEnv "XDG_STATE_HOME"
  setEnv "XDG_STATE_HOME" root
  flip finally (maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME") previous) $ do
    cluster <- newCluster emptyServer =<< newAdversary []
    store <- openTargetStore target
    _ <- initializeStore store (Resource.ContextBinding context (ok (Resource.mkName "project"))) "transition-cost" >>= either (fail . show) pure
    let members = 205
        plan registry candidate output = planInventoryCandidateWith (\_ _ -> pure registry) target candidate output
        registryFor specs = mkAdapterRegistry [kubernetesApplicationAdapter False (worldConfig cluster) (const (pure (Left "no cache"))) specs]
        planRegistry declared = either (error . show) id (registryFor (Map.fromList [(member ^. #identity, (member, native)) | (member, native) <- declared]))
        applyFactory _ bundle = pure (either (error . show) id (registryFor (either (error . show) id (kubernetesSpecsFromReview bundle))))
        candidateOf declared = do
          before <- loadTargetSnapshot target
          pure (either (error . show) id (composeInventory before (ReplaceScope (scopeOf declared) :| [])))
        initial = marker "first" : [configMap n "value" | n <- [1 .. members]]
        measured label declared = do
          candidate <- candidateOf declared
          (_, planned) <- collectCommandTrace (plan (planRegistry declared) candidate (root </> label))
          plannedDocument <- documentOf planned
          (_, applied) <- collectCommandTrace (applyInventoryWithFactory applyFactory target (root </> label) True)
          appliedDocument <- documentOf applied
          pure (plannedDocument, appliedDocument)
    first' <- candidateOf initial
    (_, converged) <- convergeInventoryCandidateResult (\_ _ -> pure (planRegistry initial)) applyFactory target first'
    case converged of
      Converged _ -> pure ()
      other -> assertFailure ("the fixture did not converge: " <> show other)
    -- Each step's costs, as observed on this path. The 2026-10-29 baseline
    -- (EP-224 M1) journaled a verification of every member for a marker
    -- change, and for any member change while the marker is unsettled.
    -- EP-225 M2 turns those into validations proved at admission: no
    -- operation and no journal entry, the same reads. Lower rows deliberately.
    unchanged <- do
      candidate <- candidateOf initial
      (_, planned) <- collectCommandTrace (plan (planRegistry initial) candidate (root </> "unchanged"))
      documentOf planned
    sweep <- measured "sweep" (marker "second" : drop 1 initial)
    -- EP-225 M3: once the sweep applied, the same declarations replan to
    -- nothing: no operation, no validation, the marker settled.
    settled <- do
      candidate <- candidateOf (marker "second" : drop 1 initial)
      (_, planned) <- collectCommandTrace (plan (planRegistry (marker "second" : drop 1 initial)) candidate (root </> "settled"))
      documentOf planned
    summary settled @?= Summary 0 0 0 0 0 0 206 206 0 0
    let changed n = marker "second" : [configMap k (if k <= n then "changed" else "value") | k <- [1 .. members]]
    one <- measured "one" (changed 1)
    four <- measured "four" (changed 4)
    -- A review without validations encodes as before; one with them carries
    -- a field the v0.11.1 decoder refuses as unknown.
    let validating label = ("\"validations\"" `BS.isInfixOf`) <$> BS.readFile (root </> label </> "review.json")
    traverse validating ["unchanged", "sweep"] >>= (@?= [False, True])
    let costs (planned, applied) = (summary planned, summary applied)
        rows = [("unchanged", (summary unchanged, emptySummary)), ("sweep", costs sweep), ("one", costs one), ("four", costs four)]
    forM_ rows $ \(label, row) -> putStrLn (label <> ": " <> show row)
    rows
      @?= [ ("unchanged", (Summary 0 0 0 0 0 0 206 206 0 0, emptySummary))
          , ("sweep", (Summary 0 1 205 0 0 0 412 412 0 0, Summary 0 0 0 0 1 205 414 414 1 0))
          , ("one", (Summary 0 1 205 0 0 0 412 412 0 0, Summary 0 0 0 0 1 205 414 414 1 0))
          , ("four", (Summary 0 3 203 0 0 0 412 412 0 0, Summary 0 0 0 0 3 203 418 418 3 0))
          ]
    -- Every executed operation is one root span labelled with its operation;
    -- validations are not operations.
    length [entry | entry <- snd sweep ^. #spans, isJust (entry ^. #labels . #operation), isNothing (entry ^. #parent)] @?= 1
    -- EP-225 M2: a validation proves the member at admission. A member that
    -- drifted, vanished or was replaced after the plan refuses the review
    -- before any transaction starts, and the marker stays unpublished.
    candidate <- candidateOf (marker "third" : drop 1 (changed 4))
    _ <- collectCommandTrace (plan (planRegistry (marker "third" : drop 1 (changed 4))) candidate (root </> "refused"))
    before <- openTargetStore target >>= readHead >>= either (fail . show) (maybe (fail "no head") pure)
    let key name = ObjectKey "" "configmap" (Just "default") name
        server change = modifyServer cluster (either (error . show) id . change)
        refuses label = do
          applied <- try @ExitCode (applyInventoryWithFactory applyFactory target (root </> "refused") True)
          assertBool (label <> " was admitted") (either (/= ExitSuccess) (const False) applied)
          after <- openTargetStore target >>= readHead >>= either (fail . show) (maybe (fail "no head") pure)
          (headGeneration after, headActiveTransaction after) @?= (headGeneration before, Nothing)
          published <- get False (key "marker") <$> readServer cluster
          assertBool (label <> " published the marker") (maybe False (not . ("third" `T.isInfixOf`) . T.pack . show) published)
    server (fmap fst . patchJson "out-of-band" (key "member-7") [Aeson.object ["op" Aeson..= ("replace" :: Text), "path" Aeson..= ("/data/key" :: Text), "value" Aeson..= ("drifted" :: Text)]])
    refuses "a drifted member"
    server (fmap fst . patchJson "out-of-band" (key "member-7") [Aeson.object ["op" Aeson..= ("replace" :: Text), "path" Aeson..= ("/data/key" :: Text), "value" Aeson..= ("value" :: Text)]])
    original <- get False (key "member-9") <$> readServer cluster >>= maybe (fail "member-9 is absent") pure
    server (delete (Preconditions Nothing Nothing) Background (key "member-9"))
    refuses "a deleted member"
    server (fmap fst . create "out-of-band" original)
    refuses "a replaced member"

-- | What one plan or apply did: planned verifies, updates and validations,
-- executed verifies, updates and validations, logical and transported
-- @get configmap@ reads, transported applies and reused reads.
data Summary = Summary !Int !Int !Int !Int !Int !Int !Int !Int !Int !Int
  deriving stock (Eq, Show)

emptySummary :: Summary
emptySummary = Summary 0 0 0 0 0 0 0 0 0 0

summary :: TraceDocument -> Summary
summary document =
  Summary
    (operationTotal RecordPlanned "VerifyResource" document)
    (operationTotal RecordPlanned "UpdateResource" document)
    (operationTotal RecordPlanned "ValidateResource" document)
    (operationTotal RecordExecuted "VerifyResource" document)
    (operationTotal RecordExecuted "UpdateResource" document)
    (operationTotal RecordExecuted "ValidateResource" document)
    (named CategoryKubernetesLogical "get configmap")
    (named CategoryKubernetesTransport "get configmap")
    (named CategoryKubernetesTransport "apply")
    (sum (map snd (countsIn CategoryKubernetesReuse document)))
  where
    named category name = fromMaybe 0 (lookup name (countsIn category document))

target :: ActiveTarget
target = ActiveTarget (ok (mkContextName "transition-cost")) (initProfile & #project .~ "project" & #mode .~ Local)

context :: Resource.ContextId
context = ok (Resource.mkContextId "transition-cost")

worldConfig :: Cluster -> KubernetesRuntimeConfig
worldConfig cluster =
  withKubectlInterpreter
    (runKubectlWith (countedTransport (clusterAnswer cluster)))
    (KubernetesRuntimeConfig context "world" (pure (Right ())))

owner :: Resource.ScopeId
owner = ok (Resource.mkScopeId Resource.Application "cost-fixture")

scopeOf :: [(ManagedResource, ByteString)] -> ScopeDeclaration
scopeOf = scopeOwnedBy owner

scopeOwnedBy :: Resource.ScopeId -> [(ManagedResource, ByteString)] -> ScopeDeclaration
scopeOwnedBy scope declared = ok (mkScopeDeclaration scope [ResourceBundle [Managed member | (member, _) <- declared] [] [] [] [] []])

-- | The marker stands for a platform stage's generated record: changing it
-- asks for the bootstrap-wide verification.
marker :: Text -> (ManagedResource, ByteString)
marker value = configMapFrom "marker" value "generated:bootstrap"

configMap :: Int -> Text -> (ManagedResource, ByteString)
configMap n value = configMapFrom ("member-" <> T.pack (show n)) value "fixture/Config.hs"

configMapFrom :: Text -> Text -> Text -> (ManagedResource, ByteString)
configMapFrom = configMapOf owner

configMapOf :: Resource.ScopeId -> Text -> Text -> Text -> (ManagedResource, ByteString)
configMapOf scope name value source =
  ok
    ( bindKubernetesObject
        ( KubernetesInput
            identity
            scope
            cluster
            object
            (contentDigest (ok (canonicalValue object)))
            DeleteWhenUnreferenced
            Stateless
            Private
            (Resource.SourceLocation source "fixture")
        )
    )
  where
    identity = Resource.mintResourceId scope (ok (Resource.mkLogicalKey name)) (ok (Resource.mkName "configmap"))
    foundation = ok (Resource.mkScopeId Resource.Platform "foundation")
    cluster = Resource.mintResourceId foundation (ok (Resource.mkLogicalKey "cluster")) (ok (Resource.mkName "resource"))
    object =
      Aeson.object
        [ "apiVersion" Aeson..= ("v1" :: Text)
        , "kind" Aeson..= ("ConfigMap" :: Text)
        , "metadata" Aeson..= Aeson.object ["name" Aeson..= name, "namespace" Aeson..= ("default" :: Text)]
        , "data" Aeson..= Aeson.object ["key" Aeson..= value]
        ]

configMapAddress :: Text -> Resource.ProviderAddress
configMapAddress name = (fst (configMapFrom name "value" "fixture/Config.hs")) ^. #address

configMapYaml :: Text -> String
configMapYaml name = "{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"" <> T.unpack name <> "\",\"namespace\":\"default\"},\"data\":{\"key\":\"value\"}}"

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- * Structural growth (EP-224 M2)

-- | One marker sweep over @members@ accepted members, beside @unrelated@
-- accepted application scopes of one member each: its planned verifies and
-- validations, executed verifies, journal events the apply appended and
-- transported Kubernetes reads while planning.
data Growth = Growth !Int !Int !Int !Int !Int
  deriving stock (Eq, Show)

sweepGrowth :: Int -> Int -> IO Growth
sweepGrowth members unrelated = withSystemTempDirectory "transition-growth" $ \root -> do
  previous <- lookupEnv "XDG_STATE_HOME"
  setEnv "XDG_STATE_HOME" root
  flip finally (maybe (unsetEnv "XDG_STATE_HOME") (setEnv "XDG_STATE_HOME") previous) $ do
    cluster <- newCluster emptyServer =<< newAdversary []
    store <- openTargetStore target
    _ <- initializeStore store (Resource.ContextBinding context (ok (Resource.mkName "project"))) "transition-growth" >>= either (fail . show) pure
    let registryFor specs = mkAdapterRegistry [kubernetesApplicationAdapter False (worldConfig cluster) (const (pure (Left "no cache"))) specs]
        registryOf declared = either (error . show) id (registryFor (Map.fromList [(member ^. #identity, (member, native)) | (member, native) <- declared]))
        applyFactory _ bundle = pure (either (error . show) id (registryFor (either (error . show) id (kubernetesSpecsFromReview bundle))))
        others =
          [ (scope, [configMapOf scope ("unrelated-" <> T.pack (show k)) "value" "fixture/Other.hs"])
          | k <- [1 .. unrelated]
          , let scope = ok (Resource.mkScopeId Resource.Application ("unrelated-" <> T.pack (show k)))
          ]
        fixture label = marker label : [configMap n "value" | n <- [1 .. members]]
    before <- loadTargetSnapshot target
    let initial = fixture "first"
        everything = initial <> concatMap snd others
        first' = ok (composeInventory before (ReplaceScope (scopeOf initial) :| [ReplaceScope (scopeOwnedBy scope declared) | (scope, declared) <- others]))
    (_, converged) <- convergeInventoryCandidateResult (\_ _ -> pure (registryOf everything)) applyFactory target first'
    case converged of
      Converged _ -> pure ()
      other -> assertFailure ("the growth fixture did not converge: " <> show other)
    accepted <- loadTargetSnapshot target
    let swept = fixture "second"
        candidate = ok (composeInventory accepted (ReplaceScope (scopeOf swept) :| []))
    (_, planned) <- collectCommandTrace (planInventoryCandidateWith (\_ _ -> pure (registryOf swept)) target candidate (root </> "sweep"))
    plannedDocument <- documentOf planned
    let sequenceNow = headSequence <$> (openTargetStore target >>= readHead >>= either (fail . show) (maybe (fail "no head") pure))
    journalBefore <- sequenceNow
    (_, applied) <- collectCommandTrace (applyInventoryWithFactory applyFactory target (root </> "sweep") True)
    journalAfter <- sequenceNow
    appliedDocument <- documentOf applied
    pure
      ( Growth
          (operationTotal RecordPlanned "VerifyResource" plannedDocument)
          (operationTotal RecordPlanned "ValidateResource" plannedDocument)
          (operationTotal RecordExecuted "VerifyResource" appliedDocument)
          (fromIntegral (journalAfter - journalBefore))
          (fromMaybe 0 (lookup "get configmap" (countsIn CategoryKubernetesTransport plannedDocument)))
      )

-- | A marker sweep journals no per-member work, so its journal events do not
-- grow from 205 to 2,050 members; its proofs and reads still do, until
-- EP-226 groups the reads. Unrelated accepted scopes cost the sweep nothing.
structuralGrowth :: Assertion
structuralGrowth = do
  small <- sweepGrowth 205 0
  large <- sweepGrowth 2050 0
  beside <- sweepGrowth 205 50
  let Growth smallVerifies smallValidations smallExecuted smallPuts smallReads = small
      Growth largeVerifies largeValidations largeExecuted largePuts largeReads = large
  putStrLn ("growth: " <> show (small, large, beside))
  (smallVerifies, largeVerifies, smallExecuted, largeExecuted) @?= (0, 0, 0, 0)
  (smallValidations, largeValidations) @?= (205, 2050)
  largePuts @?= smallPuts
  -- Reads are still per member (two each): the bound EP-226 must lower.
  (smallReads, largeReads) @?= (2 * 206, 2 * 2051)
  beside @?= small
