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
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.OpenApi (validateToJSON)
import Data.Text qualified as T
import Nagare.Contract.Problem (ProblemDetails, unknownScope)
import Nagare.Contract.Project (deployPreview, imagePublicationResult, inventoryStatusReport, storeRefusal)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Sink (clearContractSink, refuseWith, setContractSinkTo, withReadContract)
import Nagare.Contract.V1 (ImagePublicationResult (..), Outcome (..), PublishedReview (..), ReviewLocation (..), SavedReview (..), TransactionOutcome (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterExecution (..), AdapterRegistry, mkAdapterRegistry)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps (..), KubernetesMutation (..), KubernetesState (..), mkKubernetesAdapter, unstamped)
import Nagare.Inventory.Command (convergeInventoryCandidateResult, loadTargetSnapshot, openTargetStore, planInventoryCandidateWith)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.KubernetesReview (kubernetesSpecsFromReview)
import Nagare.Inventory.Plan (InventoryHistory, ReviewBundle)
import Nagare.Inventory.Publications (readPublications)
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store (InventoryStore, StoreError (StoreAuthRequired), initializeStore, readHead)
import Nagare.Inventory.Store.GcloudAuth (gcloudLoginRequired)
import Nagare.Resource.Inventory (CompositionCandidate, Declaration (..), Executor (KubernetesExecutor), ManagedResource, ResourceBundle (..), ScopeChange (ReplaceScope), ScopeDeclaration, composeInventory, mkScopeDeclaration, withScopeConfigDigest, withScopeOverrides)
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (DeleteWhenUnreferenced), Sensitivity (Private))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Target (ActiveTarget (..), Mode (Local), mkContextName)
import Nagare.Test.Support.Profiles (initProfile)
import System.Directory (makeAbsolute)
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
    , testCase "inventory publications reads the recorded state alone" $ withFixture $ \fixture -> do
        listing <- readPublications (fixtureTarget fixture) >>= either (\(_, reason) -> fail (T.unpack reason)) pure
        listing ^. #publications @?= []
        validateToJSON listing @?= []
    ]
  where
    fromNullable' (Nullable value) = value

data Fixture = Fixture
  { fixtureRoot :: !FilePath
  , fixtureTarget :: !ActiveTarget
  , fixtureCandidate :: !CompositionCandidate
  , fixturePlan :: !(CompositionCandidate -> InventoryHistory -> IO AdapterRegistry)
  , fixtureApply :: !(InventoryStore -> ReviewBundle -> IO AdapterRegistry)
  , fixtureResource :: !Resource.ResourceId
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
