-- | The release transition (EP-172): the compatibility check, the store head
-- marker that admission opens for the first transition review, keeps for the
-- later ones, and that closes the store to every other review, and the
-- rehearsal record a release binds.
module PlatformTransitionSpec (platformTransitionTests) where

import Data.Aeson (eitherDecode, eitherDecodeStrict', encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import InventoryTransactionSpec (preparedFixtureHead)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (AdapterExecution (AdapterEffectCompleted), AdapterRegistry, RecoveryDecision (RecoveryUnresolved))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (AdmissionError (..), applyReviewed)
import Nagare.Inventory.Plan (ReviewedPlan)
import Nagare.Inventory.ReleaseEvidence (validateReleaseEvidence)
import Nagare.Inventory.Store
import Nagare.Platform.Transition
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Resource.DeploymentMeaning (sameDeclarationsModuloSources)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import PlatformIncrementalSpec (platformIncrementalTests)
import PlatformTransitionTableSpec (platformTransitionTableTests)
import Test.Tasty
import Test.Tasty.HUnit

platformTransitionTests :: TestTree
platformTransitionTests = testGroup "release transition (EP-172)" [compatibilityTests, markerTests, releaseEvidenceTests, platformTransitionTableTests, platformIncrementalTests]

-- | The publisher's proof: the rehearsal record binds the candidate and
-- reports the outcome the release rule asks for.
releaseEvidenceTests :: TestTree
releaseEvidenceTests =
  testGroup
    "release evidence"
    [ testCase "a complete proof is accepted" $ validateReleaseEvidence "0.5.0" candidate (assetsWith id) @?= Right ()
    , testCase "a rehearsal of another candidate or from an unaccepted release is refused" $ do
        refuses (assetsWith (set ["candidate", "revision"] (Aeson.String other))) "another candidate"
        refuses (assetsWith (set ["source", "version"] (Aeson.String "0.3.0"))) "does not accept"
        refuses (assetsWith (set ["source", "version"] (Aeson.String "0.5.0"))) "does not accept"
    , testCase "a rehearsal whose outcome is not the release rule's is refused" $ do
        refuses (assetsWith (set ["sentinel", "readBack"] (Aeson.String "other row"))) "read the seeded data back changed"
        refuses (assetsWith (set ["transition", "reviews"] (Aeson.Number 0))) "no transition review"
        refuses (assetsWith (set ["platform", "identities", "cluster", "version"] (Aeson.String "0.4.0"))) "did not end on the candidate"
        refuses (assetsWith (set ["platform", "identities", "context", "version"] (Aeson.String "0.4.0"))) "did not pin the context"
        refuses (assetsWith (set ["inventory", "activeTransaction"] (Aeson.String "tx-1"))) "open transaction"
        refuses (assetsWith (set ["replan", "operations"] (Aeson.Number 1))) "not converged"
        refuses (assetsWith (set ["mode"] (Aeson.String "cloud"))) "unsupported schema or mode"
    , testCase "a missing record, a secret-looking key and foreign native evidence are refused" $ do
        refuses (Map.delete rehearsalName (assetsWith id)) "missing release evidence asset"
        refuses (assetsWith (set ["adminPassword"] (Aeson.String "x"))) "sensitive key"
        refuses (Map.insert "nix-output-x86_64-linux.json" (encoded (output "x86_64-linux" "sha256-linux" other)) (assetsWith id)) "native evidence belongs to another candidate"
    ]
  where
    candidate = "37d8d45da8a0e683208a62cfc59efe8c2831f737"
    other = "0000000000000000000000000000000000000000"
    systems = ["x86_64-linux", "aarch64-darwin"] :: [Text]
    rehearsalName = "nagare-transition-rehearsal-v0.5.0.json"
    identity = Aeson.object ["version" Aeson..= ("0.5.0" :: Text), "revision" Aeson..= candidate]
    refuses assets needle = case validateReleaseEvidence "0.5.0" candidate assets of
      Left reason -> assertBool (T.unpack reason) (needle `T.isInfixOf` reason)
      Right () -> assertFailure ("accepted a proof that should refuse with " <> T.unpack needle)
    encoded = LBS.toStrict . encode
    assetsWith adjust =
      Map.fromList
        ( [ ("nagare-release-0.5.0.json", encoded (Aeson.object ["version" Aeson..= ("0.5.0" :: Text), "revision" Aeson..= candidate, "systems" Aeson..= systems, "payloadDigests" Aeson..= Aeson.object ["x86_64-linux" Aeson..= ("sha256-linux" :: Text), "aarch64-darwin" Aeson..= ("sha256-darwin" :: Text)]]))
          , ("nagare-platform-metadata-v0.5.0.json", encoded (Aeson.object ["platformVersion" Aeson..= ("0.5.0" :: Text), "supportedSystems" Aeson..= systems, "transitionsFrom" Aeson..= (["0.4.0"] :: [Text])]))
          , (rehearsalName, encoded (adjust rehearsal))
          , ("nix-output-x86_64-linux.json", encoded (output "x86_64-linux" "sha256-linux" candidate))
          , ("nix-output-aarch64-darwin.json", encoded (output "aarch64-darwin" "sha256-darwin" candidate))
          ]
            <> [("clone-free-" <> T.unpack system <> ".json", encoded (cloneFree system)) | system <- systems]
        )
    output system digest revision = Aeson.object ["version" Aeson..= ("0.5.0" :: Text), "revision" Aeson..= (revision :: Text), "system" Aeson..= (system :: Text), "outputs" Aeson..= Aeson.object ["nagarectl" Aeson..= Aeson.object ["narHash" Aeson..= ("sha256-cli" :: Text)], "nagare-platform" Aeson..= Aeson.object ["narHash" Aeson..= (digest :: Text)]]]
    cloneFree system = Aeson.object ["version" Aeson..= ("0.5.0" :: Text), "revision" Aeson..= candidate, "system" Aeson..= system, "cloneFree" Aeson..= True, "supportedSystems" Aeson..= systems, "checks" Aeson..= (["version", "context", "typed-config", "inventory-compile", "payload", "operator-recipe"] :: [Text])]
    rehearsal =
      Aeson.object
        [ "schemaVersion" Aeson..= (1 :: Int)
        , "mode" Aeson..= ("local" :: Text)
        , "context" Aeson..= ("transition" :: Text)
        , "source" Aeson..= Aeson.object ["version" Aeson..= ("0.4.0" :: Text), "revision" Aeson..= ("831243962c6b80f91da1028cdab8238ae6acdabd" :: Text)]
        , "candidate" Aeson..= identity
        , "bootstrap" Aeson..= Aeson.object ["reviews" Aeson..= (3 :: Int)]
        , "transition" Aeson..= Aeson.object ["reviews" Aeson..= (3 :: Int), "operations" Aeson..= (1 :: Int)]
        , "sentinel" Aeson..= Aeson.object ["seeded" Aeson..= ("transition 20261011T200000Z" :: Text), "readBack" Aeson..= ("transition 20261011T200000Z" :: Text)]
        , "platform" Aeson..= Aeson.object ["identities" Aeson..= Aeson.object ["cli" Aeson..= identity, "payload" Aeson..= identity, "cluster" Aeson..= identity, "context" Aeson..= Aeson.object ["version" Aeson..= ("0.5.0" :: Text), "revision" Aeson..= Aeson.Null], "host" Aeson..= Aeson.object ["version" Aeson..= Aeson.Null, "revision" Aeson..= Aeson.Null]]]
        , "inventory" Aeson..= Aeson.object ["activeTransaction" Aeson..= Aeson.Null, "transactionStatus" Aeson..= Aeson.Null, "observationComplete" Aeson..= True]
        , "replan" Aeson..= Aeson.object ["operations" Aeson..= (0 :: Int), "reaccepts" Aeson..= (0 :: Int)]
        ]
    set :: [Key.Key] -> Aeson.Value -> Aeson.Value -> Aeson.Value
    set [] new _ = new
    set (key : rest) new (Aeson.Object fields) = Aeson.Object (KM.insert key (set rest new (fromMaybe Aeson.Null (KM.lookup key fields))) fields)
    set _ new _ = new

compatibilityTests :: TestTree
compatibilityTests =
  testGroup
    "compatibility check"
    [ testCase "a payload without the field accepts no source release" $ do
        manifest <- decoded "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.4.0\",\"sourceRevision\":null}"
        manifest ^. #transitionsFrom @?= []
        checkTransition manifest (Just "0.3.0") 1 @?= Left (UnsupportedSource "0.3.0" "0.4.0" [])
    , testCase "a listed source at the current wire version is accepted" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.4.0") 1 @?= Right (TransitionPair "0.4.0" "0.5.0")
    , testCase "an unlisted source, the target itself, and an unpinned context refuse" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.3.0") 1 @?= Left (UnsupportedSource "0.3.0" "0.5.0" ["0.4.0"])
        checkTransition manifest (Just "0.5.0") 1 @?= Left (AlreadyAtTarget "0.5.0")
        checkTransition manifest Nothing 1 @?= Left UnpinnedContext
    , testCase "a head wire version this payload does not read refuses" $ do
        manifest <- decoded current
        checkTransition manifest (Just "0.4.0") 2 @?= Left (UnsupportedStoreVersion 2 1 1)
        checkTransition manifest (Just "0.4.0") 0 @?= Left (UnsupportedStoreVersion 0 1 1)
    , testCase "a transition review's payload identity names the source release and the target payload" $ do
        transitionReviewIdentity "0.4.0" "payload-t" @?= "nagare-transition:0.4.0->payload-t"
        parseTransitionReviewIdentity "nagare-transition:0.4.0->payload-t" @?= Just ("0.4.0", "payload-t")
        parseTransitionReviewIdentity "nagare-bootstrap:payload-t" @?= Nothing
        parseTransitionReviewIdentity "nagare-transition:0.4.0->" @?= Nothing
        parseTransitionReviewIdentity "nagare-transition:->payload-t" @?= Nothing
    , testCase "a platform review expects the payload that planned it and the pin it was planned against" $ do
        manifest <- decoded current
        platformReviewExpectation manifest "nagare-bootstrap:p" @?= Just ("p", "0.5.0")
        platformReviewExpectation manifest (transitionReviewIdentity "0.4.0" "p") @?= Just ("p", "0.4.0")
        platformReviewExpectation manifest "operator-cli" @?= Nothing
    , testCase "declarations that differ only in their members' source are the same scope to a transition" $ do
        let owner = ok (mkScopeId Platform "local-substrate")
            cluster = mintResourceId owner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
            declared file digest =
              Managed
                ManagedResource
                  { identity = mintResourceId owner (ok (mkLogicalKey "registry")) (ok (mkName "resource"))
                  , owner = owner
                  , executor = KubernetesExecutor
                  , address = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "system"))) (ok (mkName "registry"))
                  , aliases = []
                  , spec = NativeObject (contentDigest digest)
                  , lifecycle = Retain
                  , dataPolicy = Stateless
                  , sensitivity = Public
                  , dependencies = []
                  , delegations = []
                  , source = SourceLocation file "local-substrate-v1"
                  }
            scopeFrom file digest = ok (mkScopeDeclaration owner [ResourceBundle [declared file digest] [] [] [] [] []])
        sameDeclarationsModuloSources (scopeFrom "/payload-s/spec.json" "spec") (scopeFrom "/payload-t/spec.json" "spec") @?= True
        sameDeclarationsModuloSources (scopeFrom "/payload-s/spec.json" "spec") (scopeFrom "/payload-s/spec.json" "other") @?= False
    , testCase "the commit waits for its own open marker, an idle head and every moved scope converged" $ do
        recorded <- BS.readFile "test/fixtures/transition-0.4.0/store/head.json" >>= either (assertFailure . show) pure . decodeHead
        let marker = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
            opened = recorded {headTransition = Just marker}
            platform = (== Platform) . scopeKind
            refuses headValue needle = case transitionCommitRefusal "payload-t" platform headValue of
              Just reason -> assertBool (T.unpack reason) (needle `T.isInfixOf` reason)
              Nothing -> assertFailure ("the commit went ahead; expected a refusal naming " <> T.unpack needle)
        transitionCommitRefusal "payload-t" platform opened @?= Nothing
        refuses recorded "no release transition is open"
        refuses opened {headActiveTransaction = Just "tx-1"} "unresolved transaction"
        case transitionCommitRefusal "payload-s" platform opened of
          Just reason -> assertBool (T.unpack reason) ("payload-t" `T.isInfixOf` reason)
          Nothing -> assertFailure "another payload committed the transition"
        let foundation = ok (mkScopeId Platform "foundation")
            unconverged = opened {headConverged = Map.delete foundation (headConverged opened)}
        refuses unconverged "platform:foundation"
        transitionCommitRefusal "payload-t" (const False) unconverged @?= Nothing
    , testCase "only the target payload's nagarectl may continue an open transition" $ do
        let marker = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
        transitionOwnerRefusal marker "payload-t" @?= Nothing
        case transitionOwnerRefusal marker "payload-s" of
          Nothing -> assertFailure "a foreign payload continued the transition"
          Just reason -> assertBool (show reason) ("payload-t" `T.isInfixOf` reason && "payload-s" `T.isInfixOf` reason)
    , testCase "an idle open transition may be continued by a superseding payload (F130)" $ do
        recorded <- BS.readFile "test/fixtures/transition-0.4.0/store/head.json" >>= either (assertFailure . show) pure . decodeHead
        let marker = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
            idle = recorded {headTransition = Just marker, headActiveTransaction = Nothing, headExecutorClaim = Nothing}
        transitionContinueRefusal idle marker "payload-s" @?= Nothing
        case transitionContinueRefusal idle {headActiveTransaction = Just "tx-1"} marker "payload-s" of
          Nothing -> assertFailure "a foreign payload continued a busy transition"
          Just reason -> assertBool (show reason) ("payload-t" `T.isInfixOf` reason)
        transitionContinueRefusal idle {headActiveTransaction = Just "tx-1"} marker "payload-t" @?= Nothing
    ]
  where
    current = "{\"assetSchemaVersion\":1,\"payloadId\":\"p\",\"platformVersion\":\"0.5.0\",\"sourceRevision\":null,\"transitionsFrom\":[\"0.4.0\"]}"
    decoded :: ByteString -> IO PayloadManifest
    decoded = either assertFailure pure . eitherDecodeStrict'
    ok :: (Show e) => Either e a -> a
    ok = either (error . show) id

markerTests :: TestTree
markerTests =
  testGroup
    "store head marker"
    [ testCase "admitting a transition review opens the marker, which the head wire keeps" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-t") id store
        _ <- applyReviewed store registry reviewed >>= expectRight
        headValue <- currentHead store
        marker <- maybe (assertFailure "no transition marker after admission" >> error "unreachable") pure (headTransition headValue)
        transitionSource marker @?= "0.4.0"
        transitionTarget marker @?= "payload-t"
        assertBool "the marker records when it opened" (not (T.null (transitionStartedAt marker)))
        eitherDecode (encode headValue) @?= Right headValue
        assertBool "an open transition is substantive history" (hasSubstantiveHistory headValue {headGeneration = 0, headSequence = 0, headAccepted = mempty, headConverged = mempty, headIncarnations = mempty})
    , testCase "while a transition is open, a review that is not its own refuses and names the target payload" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture "operator-cli" withOpen store
        errors <- applyReviewed store registry reviewed >>= expectLeft
        map admissionErrorCode (NE.toList errors) @?= ["open-transition"]
        assertBool (show errors) (all (("payload-t" `T.isInfixOf`) . admissionErrorMessage) errors)
        headValue <- currentHead store
        headTransition headValue @?= Just opened
        headActiveTransaction headValue @?= Nothing
    , testCase "a transition review from another source is refused by the open one" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.3.0" "payload-u") withOpen store
        errors <- applyReviewed store registry reviewed >>= expectLeft
        map admissionErrorCode (NE.toList errors) @?= ["open-transition"]
    , testCase "a review moving the same source to another payload supersedes the open transition (F130)" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-u") withOpen store
        _ <- applyReviewed store registry reviewed >>= expectRight
        headValue <- currentHead store
        fmap transitionSource (headTransition headValue) @?= Just "0.4.0"
        fmap transitionTarget (headTransition headValue) @?= Just "payload-u"
    , testCase "a later review of the open transition is admitted and keeps the marker's start" $ do
        store <- newMemoryStore
        (reviewed, registry) <- fixture (transitionReviewIdentity "0.4.0" "payload-t") withOpen store
        _ <- applyReviewed store registry reviewed >>= expectRight
        headValue <- currentHead store
        headTransition headValue @?= Just opened
    , testCase "the head wire refuses a transition marker with an unknown field" $ do
        store <- newMemoryStore
        (_, _) <- fixture "operator-cli" id store
        headValue <- currentHead store
        let withMarker = headValue {headTransition = Just opened}
            good = TL.toStrict (TLE.decodeUtf8 (encode withMarker))
            bad = T.replace "\"startedAt\"" "\"started\"" good
        assertBool "the marker encodes under the transition key" ("\"transition\"" `T.isInfixOf` good)
        eitherDecode (LBS.fromStrict (TE.encodeUtf8 good)) @?= Right withMarker
        case eitherDecode (LBS.fromStrict (TE.encodeUtf8 bad)) :: Either String HeadManifest of
          Left _ -> pure ()
          Right _ -> assertFailure "a marker with an unknown field decoded"
    ]
  where
    opened = TransitionMarker "0.4.0" "payload-t" "2026-10-11T00:00:00Z"
    withOpen headValue = headValue {headTransition = Just opened}
    fixture :: Text -> (HeadManifest -> HeadManifest) -> InventoryStore -> IO (ReviewedPlan, AdapterRegistry)
    fixture identity adjust store =
      preparedFixtureHead identity adjust store (\_ _ -> pure AdapterEffectCompleted) (\_ _ -> pure (RecoveryUnresolved "no recovery")) (\_ registry -> registry)
    currentHead store = readHead store >>= expectRight >>= maybe (assertFailure "store has no head" >> error "unreachable") pure
    expectRight :: (Show e) => Either e a -> IO a
    expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
    expectLeft :: (Show a) => Either e a -> IO e
    expectLeft = either pure (\value -> assertFailure ("expected a refusal, got " <> show value) >> error "unreachable")
