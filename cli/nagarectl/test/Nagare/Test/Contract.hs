{-# LANGUAGE DataKinds #-}

-- | The public document contract (EP-192): the golden samples in
-- @docs/api/samples@, schema conformance, and the problem catalog. The
-- OpenAPI artifact's own test is in nagare-api-server-test, beside its
-- generator.
module Nagare.Test.Contract
  ( contractTests
  )
where

import Control.Exception (try)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, toJSON)
import Data.Aeson.Encode.Pretty (Config (..), Indent (..), defConfig, encodePretty')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.OpenApi (ToSchema)
import Data.OpenApi.Schema.Validation (validateToJSON)
import Data.Text qualified as Text
import Nagare.Contract.Problem
import Nagare.Contract.Project
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), Nullable (..), fromNullable)
import Nagare.Contract.Sink (clearContractSink, markExecuting, refuseWith, setContractSinkTo, transactionExitCode, transactionOutcome)
import Nagare.Contract.V1
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (ReviewBarrier (..))
import Nagare.Inventory.Artifact
  ( ArtifactDeclarationBundle (..)
  , ArtifactKind (..)
  , ArtifactOwnership (..)
  , ArtifactResourceSpec (..)
  , ConsumerCoverage (..)
  , compileArtifactScope
  )
import Nagare.Inventory.Command (applyInventoryWithFactory, renderTransactionResult)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..))
import Nagare.Inventory.Journal (FailureClass (..), mkOperationId, mkTransactionId, transactionIdText)
import Nagare.Inventory.Site.Recorded qualified as Recorded
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision (..))
import Nagare.Resource.Inventory (ScopeDeclaration, mkScopeDeclaration, withScopeConfigDigest, withScopeOverrides)
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (..))
import Nagare.Resource.Types hiding (ScopeKind (..))
import Nagare.Resource.Types qualified as Types
import Nagare.Target (ActiveTarget (..), mkContextName)
import Nagare.Test.ContractCommands (contractCommandTests)
import Nagare.Test.Support.Profiles (initProfile)
import Nagare.Version (BuildVersion (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

-- | The repository root, relative to @cli/nagarectl@ (the Nix build
-- substitutes its copy of the published artifacts).
repositoryRoot :: FilePath
repositoryRoot = "../.."

contractTests :: TestTree
contractTests =
  testGroup
    "Contract"
    [ testGroup "samples" (concatMap sampleTests samples)
    , contractCommandTests
    , testCase "a base problem has exactly the RFC 9457 members and the two extensions" $ do
        let base = problemFor unknownScope "application:nope is not accepted"
        objectKeys (toJSON base) @?= sort ["type", "title", "status", "detail", "code", "retryable"]
        let gateway = base {gatewayError = Just "unauthenticated", login = Just "https://auth.example/login"}
        objectKeys (toJSON gateway) @?= sort ["type", "title", "status", "detail", "code", "retryable", "error", "login"]
        eitherDecode (encodeSample gateway) @?= Right gateway
        validateToJSON gateway @?= []
    , testCase "every catalog code has one status and one title" $ do
        let codes = map (^. #code) problemCatalog
        assertEqual "duplicate problem codes" (nub codes) codes
        for_ problemCatalog $ \spec ->
          assertBool (Text.unpack (spec ^. #code) <> " has no status title") (not (Text.null (spec ^. #title)))
        for_ problemCatalog $ \spec ->
          lookup (spec ^. #status) statusTitles @?= Just (spec ^. #title)
    , testCase "every transaction result has its outcome document and exit code" $ do
        let transaction = ok (mkTransactionId ("tx-" <> Text.replicate 64 "a"))
            operationValue = ok (mkOperationId "op-1")
            cases =
              [ (Converged transaction, OutcomeConverged, ExitSuccess)
              , (PausedAtBarrier transaction (ReviewBarrier operationValue "operator decision" :| []), OutcomePaused, ExitFailure 3)
              , (StoppedFailed transaction operationValue (PartialOrUnknown "rollout stalled"), OutcomeStopped, ExitFailure 4)
              , (StoppedAmbiguous transaction operationValue "the timer reverted the host", OutcomeAmbiguous, ExitFailure 5)
              , (Closed transaction, OutcomeClosed, ExitFailure 6)
              ]
        for_ cases $ \(result, expected, code) -> do
          let document = transactionOutcome result
          (document ^. #outcome, transactionExitCode result) @?= (expected, code)
          validateToJSON document @?= []
        (transactionOutcome (StoppedAmbiguous transaction operationValue "the timer reverted the host") ^. #detail) @?= Nullable (Just "the timer reverted the host")
        renderTransactionResult (StoppedAmbiguous transaction operationValue "the timer reverted the host")
          @?= "ambiguous " <> transactionIdText transaction <> " at op-1: the timer reverted the host"
    , testCase "under the sink a refusal is refused before admission and interrupted after it" $ do
        printed <- newIORef []
        setContractSinkTo (\line -> modifyIORef' printed (line :))
        before <- try (refuseWith "unused" wrongContext "the review targets another project")
        markExecuting "tx-running"
        after <- try (refuseWith "unused" unclassified "the provider connection dropped")
        clearContractSink
        (before :: Either ExitCode ()) @?= Left (ExitFailure 2)
        (after :: Either ExitCode ()) @?= Left (ExitFailure 7)
        documents <- traverse (either (\failure -> assertFailure failure >> fail "json") pure . eitherDecode) . reverse =<< readIORef printed
        map (\document -> (document ^. #outcome, document ^. #transaction, fmap (^. #code) (fromNullable (document ^. #problem)))) (documents :: [TransactionOutcome])
          @?= [(OutcomeRefused, Nullable Nothing, Just "wrong_context"), (OutcomeInterrupted, Nullable (Just "tx-running"), Nothing)]
    , testCase "inventory apply without --yes is a refused outcome with exit 2" $ do
        printed <- newIORef []
        setContractSinkTo (\line -> modifyIORef' printed (line :))
        let target = ActiveTarget (ok (mkContextName "contract-fixture")) initProfile
        refused <- try (applyInventoryWithFactory (\_ _ -> fail "no registry") target "/nonexistent" False)
        clearContractSink
        (refused :: Either ExitCode ()) @?= Left (ExitFailure 2)
        documents <- traverse (either (\failure -> assertFailure failure >> fail "json") pure . eitherDecode) =<< readIORef printed
        map (\document -> (document ^. #outcome, fmap (^. #code) (fromNullable (document ^. #problem)))) (documents :: [TransactionOutcome])
          @?= [(OutcomeRefused, Just "unclassified")]
    , testCase "scope states read only the head and report the last converged revision" $
        map (\item -> (item ^. #scope, item ^. #converged)) (scopeStates sampleHead)
          @?= [("application:kizashi", False), ("publication:app-image-kizashi-v1", True)]
    ]
  where
    for_ items action = mapM_ action items

-- | The HTTP status phrases RFC 9457 @about:blank@ problems use as titles.
statusTitles :: [(Int, Text)]
statusTitles =
  [ (400, "Bad Request")
  , (401, "Unauthorized")
  , (403, "Forbidden")
  , (404, "Not Found")
  , (405, "Method Not Allowed")
  , (406, "Not Acceptable")
  , (409, "Conflict")
  , (500, "Internal Server Error")
  , (502, "Bad Gateway")
  , (503, "Service Unavailable")
  , (504, "Gateway Timeout")
  ]

objectKeys :: Value -> [Text]
objectKeys (Object fields) = sort (map Key.toText (KeyMap.keys fields))
objectKeys _ = []

data Sample = forall a. (Eq a, Show a, ToJSON a, FromJSON a, ToSchema a) => Sample !FilePath !a

-- | A golden file per sample, schema conformance and a decode round trip.
sampleTests :: Sample -> [TestTree]
sampleTests (Sample file value) =
  [ goldenVsString file (repositoryRoot </> "docs/api/samples" </> file) (pure (encodeSample value))
  , testCase (file <> " validates against its schema") $ validateToJSON value @?= []
  , testCase (file <> " decodes to the same value") $ do
      stored <- LBS.readFile (repositoryRoot </> "docs/api/samples" </> file)
      case eitherDecode stored of
        Left failure -> assertFailure failure
        Right decoded -> decoded @?= value
  ]

encodeSample :: (ToJSON a) => a -> LBS.ByteString
encodeSample value = encodePretty' defConfig {confIndent = Spaces 2, confCompare = compare} value <> "\n"

samples :: [Sample]
samples =
  [ Sample "version-info.json" (versionInfo (BuildVersion "0.6.3" (Just "0123456789abcdef")) Nothing)
  , Sample "publication-list.json" samplePublications
  , Sample "inventory-status.json" sampleStatus
  , Sample "transaction-outcome-converged.json" (outcomeSample OutcomeConverged)
  , Sample "transaction-outcome-stopped.json" stoppedSample
  , Sample "transaction-outcome-refused.json" refusedSample
  , Sample "saved-review.json" savedReviewSample
  , Sample "image-publication-result.json" imagePublicationSample
  , Sample "site-publish-result.json" sitePublishSample
  , Sample "deploy-preview.json" deployPreviewSample
  , Sample "site-list.json" (siteList sampleHead [sampleSite])
  , Sample "problem.json" (problemFor unknownScope "application:nope is not an accepted scope")
  ]

-- The recorded inventory the projection samples read: one image publication
-- and the application whose accepted image resource names it.

publicationScope, applicationScope :: ScopeId
publicationScope = ok (mkScopeId Types.Publication "app-image-kizashi-v1")
applicationScope = ok (mkScopeId Types.Application "kizashi")

imageResourceId :: ResourceId
imageResourceId = mintResourceId publicationScope (ok (mkLogicalKey "kizashi-v1")) (ok (mkName "oci-image"))

acceptedDeclarations :: Map.Map ScopeId (ScopeGeneration, ScopeDeclaration)
acceptedDeclarations =
  Map.fromList
    [ (publicationScope, (ok (mkScopeGeneration 1), publication))
    ,
      ( applicationScope
      ,
        ( ok (mkScopeGeneration 3)
        , withScopeOverrides
            (Map.fromList [("imageResource", resourceIdText imageResourceId), ("tag", "v1")])
            (withScopeConfigDigest (contentDigest "kizashi-config") (ok (mkScopeDeclaration applicationScope [])))
        )
      )
    ]
  where
    publication =
      ok
        ( compileArtifactScope
            ( ArtifactDeclarationBundle
                1
                publicationScope
                ( ArtifactResourceSpec
                    { artifactLogicalKey = ok (mkLogicalKey "kizashi-v1")
                    , artifactRole = ok (mkName "oci-image")
                    , artifactName = ok (mkName "kizashi-v1")
                    , artifactDestination = "registry.example/kizashi:v1"
                    , artifactContentDigest = contentDigest "kizashi-manifest"
                    , artifactSpecDigest = contentDigest "kizashi-archive"
                    , artifactKind = OciImageArtifact
                    , artifactOwnership = OwnedArtifact
                    , artifactLifecycle = Retain
                    , artifactDataPolicy = Stateless
                    , artifactSensitivity = Private
                    , artifactDependencies = []
                    , artifactConsumers = ConsumerCompletenessUnknown
                    , artifactPublishOperation = True
                    , artifactSource = SourceLocation "kizashi.tar" "oci-archive-v1"
                    }
                    :| []
                )
            )
        )

samplePublications :: PublicationList
samplePublications = either (error . Text.unpack) id (publicationList acceptedDeclarations)

sampleBinding :: ContextBinding
sampleBinding = ContextBinding (ok (mkContextId "intranet")) (ok (mkName "example-project"))

-- | A head where the application has a pending third revision over its
-- converged second one.
sampleHead :: HeadManifest
sampleHead =
  HeadManifest
    { headSchemaVersion = 1
    , headGeneration = 12
    , headSequence = 40
    , headBinding = sampleBinding
    , headClientIdentity = "client-sample"
    , headAccepted = Map.fromList [(publicationScope, revision 1 "kizashi-publication"), (applicationScope, revision 3 "kizashi-v3")]
    , headConverged = Map.fromList [(publicationScope, revision 1 "kizashi-publication"), (applicationScope, revision 2 "kizashi-v2")]
    , headRetained = Map.empty
    , headCollected = Map.empty
    , headActiveTransaction = Just "tx-sample"
    , headExecutorClaim = Nothing
    , headMigration = Nothing
    , headDataFence = Nothing
    , headIncarnations = Map.empty
    , headTransition = Nothing
    }
  where
    revision number seed = ScopeRevision (ok (mkScopeGeneration number)) (contentDigest seed)

sampleStatus :: InventoryStatusReport
sampleStatus =
  InventoryStatusReport
    { contractVersion = ContractVersion1
    , document = DocumentName
    , context = contextRef sampleBinding
    , observedAt = "2026-10-16T12:00:00Z"
    , observationComplete = False
    , activeTransaction = Nullable (headActiveTransaction sampleHead)
    , scopes = scopeStates sampleHead
    , findings =
        [ Finding
            { scope = "application:kizashi"
            , resource = "application:kizashi/web/service"
            , category = CategoryConfigurationDrift
            , health = HealthReady
            , reason = Nullable (Just "the live Service differs from the accepted declaration")
            }
        ]
    }

outcomeSample :: Outcome -> TransactionOutcome
outcomeSample result =
  TransactionOutcome
    { contractVersion = ContractVersion1
    , document = DocumentName
    , outcome = result
    , transaction = Nullable (Just "tx-0f3a")
    , operation = Nullable Nothing
    , failureClass = Nullable Nothing
    , barriers = []
    , detail = Nullable Nothing
    , problem = Nullable Nothing
    }

stoppedSample :: TransactionOutcome
stoppedSample =
  (outcomeSample OutcomeStopped)
    { operation = Nullable (Just "op-2")
    , failureClass = Nullable (Just FailurePartialOrUnknown)
    , detail = Nullable (Just "the rollout did not become ready")
    }

refusedSample :: TransactionOutcome
refusedSample =
  (outcomeSample OutcomeRefused)
    { transaction = Nullable Nothing
    , problem = Nullable (Just (problemFor unclassified "inventory apply requires --yes"))
    }

savedReviewSample :: SavedReview
savedReviewSample =
  SavedReview
    { contractVersion = ContractVersion1
    , document = DocumentName
    , review = ReviewLocation {sha256 = digestText (contentDigest "review"), directory = "/tmp/kizashi-review"}
    , scopes = ["application:kizashi"]
    , rebinds = []
    , rebuilds = []
    }

imagePublicationSample :: ImagePublicationResult
imagePublicationSample =
  ImagePublicationResult
    { contractVersion = ContractVersion1
    , document = DocumentName
    , imageResource = resourceIdText imageResourceId
    , review = PublishedReview {sha256 = digestText (contentDigest "image-review"), directory = Nullable Nothing}
    , transaction = Nullable (Just (outcomeSample OutcomeConverged))
    }

sitePublishSample :: SitePublishResult
sitePublishSample =
  SitePublishResult
    { contractVersion = ContractVersion1
    , document = DocumentName
    , stage = "deployed"
    , tag = "20261030-182904-000839"
    , url = Nullable (Just "https://notes.personal.127-0-0-1.sslip.io")
    , imageResource = Nullable (Just (resourceIdText imageResourceId))
    , releaseDirectory = Nullable (Just "/home/dev/.local/state/nagare/local/static-releases/notes/20261030-182904-000839")
    , content = Nullable (Just (digestText (contentDigest "site-content")))
    , failure = Nullable Nothing
    , resume = Nullable Nothing
    }

deployPreviewSample :: DeployPreview
deployPreviewSample =
  DeployPreview
    { contractVersion = ContractVersion1
    , document = DocumentName
    , application =
        PreviewScope
          { scope = "application:kizashi"
          , configDigest = Nullable (Just (digestText (contentDigest "kizashi-config")))
          , overrides = Map.fromList [("imageResource", resourceIdText imageResourceId), ("tag", "v1")]
          }
    , hooks = []
    , scopeDocuments = [Object (KeyMap.fromList [("scope", String "application:kizashi")])]
    }

-- | A protected site whose accepted update is pending over its converged
-- revision.
sampleSite :: Recorded.RecordedSite
sampleSite =
  Recorded.RecordedSite
    { scope = ok (mkScopeId Types.Standalone "site-docs")
    , service = ok (mkResourceId "standalone:site-docs/site/service")
    , kind = Recorded.SiteKindSite
    , state = Recorded.RecordPending
    , acceptedRevision = ScopeRevision (ok (mkScopeGeneration 4)) (contentDigest "docs-v4")
    , convergedRevision = Just (ScopeRevision (ok (mkScopeGeneration 3)) (contentDigest "docs-v3"))
    , acceptedService = Recorded.ServiceSummary "docs" "personal" ["docs.example.com", "www.docs.example.com"]
    , lastConverged = Just (Recorded.ServiceSummary "docs" "personal" ["docs.example.com"])
    }

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
