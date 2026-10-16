{-# LANGUAGE DataKinds #-}

-- | The public document contract (EP-192): the checked-in OpenAPI artifact,
-- the golden samples in @docs/api/samples@, schema conformance, and the
-- problem catalog.
module Nagare.Test.Contract
  ( contractTests
  )
where

import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, toJSON)
import Data.Aeson.Encode.Pretty (Config (..), Indent (..), defConfig, encodePretty')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.OpenApi (ToSchema)
import Data.OpenApi.Schema.Validation (validateToJSON)
import Data.Text qualified as Text
import Nagare.Contract.OpenApi (contractOpenApi, renderOpenApi)
import Nagare.Contract.Problem
import Nagare.Contract.Project
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), Nullable (..))
import Nagare.Contract.V1
import Nagare.Dsl.Prelude
import Nagare.Inventory.Artifact
  ( ArtifactDeclarationBundle (..)
  , ArtifactKind (..)
  , ArtifactOwnership (..)
  , ArtifactResourceSpec (..)
  , ConsumerCoverage (..)
  , compileArtifactScope
  )
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Site.Recorded qualified as Recorded
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision (..))
import Nagare.Resource.Inventory (ScopeDeclaration, mkScopeDeclaration, withScopeConfigDigest, withScopeOverrides)
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (..))
import Nagare.Resource.Types hiding (ScopeKind (..))
import Nagare.Resource.Types qualified as Types
import Nagare.Version (BuildVersion (..))
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
    [ testCase "docs/api/openapi.json equals the generated document" $ do
        checkedIn <- LBS.readFile (repositoryRoot </> "docs/api/openapi.json")
        assertBool
          "docs/api/openapi.json is stale; run: cabal run --project-dir=cli/nagarectl nagare-contract-openapi"
          (checkedIn == renderOpenApi contractOpenApi)
    , testGroup "samples" (concatMap sampleTests samples)
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
  , (404, "Not Found")
  , (409, "Conflict")
  , (500, "Internal Server Error")
  , (503, "Service Unavailable")
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
