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
import Nagare.Inventory.Store (StoreError (StoreIoError), initializeStore, newObjectStore)
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
import Nagare.Test.World.ApiServer (emptyServer)
import Nagare.Test.World.Cluster (Cluster, clusterAnswer, newCluster)
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
    -- Each step's costs, as observed on this path at the 2026-10-29 baseline
    -- (EP-224 M1). A one-member change still verifies every member because
    -- the scope's bootstrap marker is unsettled while any member differs;
    -- EP-225 owns that cost and must lower these rows deliberately.
    unchanged <- do
      candidate <- candidateOf initial
      (_, planned) <- collectCommandTrace (plan (planRegistry initial) candidate (root </> "unchanged"))
      documentOf planned
    sweep <- measured "sweep" (marker "second" : drop 1 initial)
    let changed n = marker "second" : [configMap k (if k <= n then "changed" else "value") | k <- [1 .. members]]
    one <- measured "one" (changed 1)
    four <- measured "four" (changed 4)
    let costs (planned, applied) = (summary planned, summary applied)
        rows = [("unchanged", (summary unchanged, emptySummary)), ("sweep", costs sweep), ("one", costs one), ("four", costs four)]
    forM_ rows $ \(label, row) -> putStrLn (label <> ": " <> show row)
    rows
      @?= [ ("unchanged", (Summary 0 0 0 0 206 206 0 0, emptySummary))
          , ("sweep", (Summary 205 1 0 0 412 412 0 0, Summary 0 0 205 1 414 414 1 0))
          , ("one", (Summary 205 1 0 0 412 412 0 0, Summary 0 0 205 1 414 414 1 0))
          , ("four", (Summary 203 3 0 0 412 412 0 0, Summary 0 0 203 3 418 418 3 0))
          ]
    -- Every executed operation is one root span labelled with its operation.
    length [entry | entry <- snd sweep ^. #spans, isJust (entry ^. #labels . #operation), isNothing (entry ^. #parent)] @?= members + 1

-- | What one plan or apply did: planned verifies and updates, executed
-- verifies and updates, logical and transported @get configmap@ reads,
-- transported applies and reused reads.
data Summary = Summary !Int !Int !Int !Int !Int !Int !Int !Int
  deriving stock (Eq, Show)

emptySummary :: Summary
emptySummary = Summary 0 0 0 0 0 0 0 0

summary :: TraceDocument -> Summary
summary document =
  Summary
    (operationTotal RecordPlanned "VerifyResource" document)
    (operationTotal RecordPlanned "UpdateResource" document)
    (operationTotal RecordExecuted "VerifyResource" document)
    (operationTotal RecordExecuted "UpdateResource" document)
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
scopeOf declared = ok (mkScopeDeclaration owner [ResourceBundle [Managed member | (member, _) <- declared] [] [] [] [] []])

-- | The marker stands for a platform stage's generated record: changing it
-- asks for the bootstrap-wide verification.
marker :: Text -> (ManagedResource, ByteString)
marker value = configMapFrom "marker" value "generated:bootstrap"

configMap :: Int -> Text -> (ManagedResource, ByteString)
configMap n value = configMapFrom ("member-" <> T.pack (show n)) value "fixture/Config.hs"

configMapFrom :: Text -> Text -> Text -> (ManagedResource, ByteString)
configMapFrom name value source =
  ok
    ( bindKubernetesObject
        ( KubernetesInput
            identity
            owner
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
    identity = Resource.mintResourceId owner (ok (Resource.mkLogicalKey name)) (ok (Resource.mkName "configmap"))
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
