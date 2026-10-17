-- | EP-172 M1: the release transition's table against the two-release
-- fixture in test/fixtures/transition-0.4.0. The fixture holds a digest-bound
-- extract of the published v0.4.0 payload and store bytes the v0.4.0 nagarectl
-- wrote (scripts/record-transition-fixture.sh). This suite compiles the local
-- platform scopes from that payload and from this tree, reads the recorded
-- store through this release's codecs, and requires every row's observation
-- to be what the fixture shows.
module PlatformTransitionTableSpec (platformTransitionTableTests) where

import Control.Monad (forM, forM_)
import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.Bootstrap (BootstrapInput (..), bootstrapMarkerValue, bootstrapPreservedScopeVectorDigest, compileBootstrapStamp, compileBootstrapWithAuthAndScopes)
import Nagare.Inventory.Components.Auth (AuthInput (..), AuthMode (LocalAuth))
import Nagare.Inventory.Components.ControllerImage (controllerImageDeclaration)
import Nagare.Inventory.Components.Foundation (FoundationInput (..))
import Nagare.Inventory.Components.LocalObjectStore (LocalMinioImages (..), compileLocalObjectStore)
import Nagare.Inventory.Components.Observability (PackagedHelmInput (..), compilePinnedObservability, pinnedObservabilityInputs)
import Nagare.Inventory.Components.ObservabilityExtras (compileObservabilityExtras)
import Nagare.Inventory.Components.ObservabilitySecrets (compileObservabilitySecrets)
import Nagare.Inventory.Components.PackagedAuth (compilePackagedAuth, packagedAuthInputs)
import Nagare.Inventory.Components.Upstream (IssuerMode (LocalIssuer), bindNetCertManagerControllerImage, configuredUpstreamInputsWithIssuer)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (decodeJournalEvent)
import Nagare.Inventory.Store (HeadManifest (..), ScopeRevision (..), decodeHead)
import Nagare.Platform.Status (identityFromPayload)
import Nagare.Platform.Transition
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (makeRelative, takeBaseName, (</>))
import Test.Tasty
import Test.Tasty.HUnit

platformTransitionTableTests :: TestTree
platformTransitionTableTests =
  testGroup
    "transition table (EP-172 M1)"
    [ testCase "the v0.4.0 payload extract is the recorded one, file for file" $ do
        recorded <- readManifest
        present <- filesUnder sourceRoot
        sort (Map.keys recorded) @?= present
        forM_ (Map.toList recorded) $ \(file, digest) -> do
          bytes <- BS.readFile (sourceRoot </> file)
          assertEqual file digest (sha256 bytes)
    , testCase "the recorded v0.4.0 store reads back under this release's codecs" $ do
        target <- manifestAt targetRoot
        forM_ ["head-initial.json", "head.json"] $ \name -> do
          bytes <- BS.readFile (storeRoot </> name)
          headValue <- expectRight (decodeHead bytes)
          checkTransition target (Just "0.4.0") (headSchemaVersion headValue) @?= Right (TransitionPair "0.4.0" (target ^. #platformVersion))
          headTransition headValue @?= Nothing
        events <- listDirectory (storeRoot </> "journal")
        assertBool "the journal sample is empty" (not (null events))
        forM_ events $ \name -> BS.readFile (storeRoot </> "journal" </> name) >>= either (assertFailure . ((name <> ": ") <>) . T.unpack) (const (pure ())) . decodeJournalEvent
        scopes <- recordedScopes
        assertBool "no scope revision was recorded" (not (Map.null scopes))
    , testCase "every row's observation is what the fixture shows" $ do
        observed <- observeFixture
        Map.fromList [(row ^. #state, row ^. #observed) | row <- transitionTable] @?= observed
    , testCase "the pin moves last, the stamp after every scope it covers, and every state that differs is moved" $ do
        let stepOf wanted = [row ^. #step | row <- transitionTable, row ^. #state == wanted]
            moving = [row | row <- transitionTable, row ^. #observed `notElem` [Unchanged, NotInLocalContext] || row ^. #step > 0]
            scopeSteps = [row ^. #step | row@TransitionRow {state = PlatformScope _} <- transitionTable]
        stepOf ContextPin @?= [maximum (map (^. #step) transitionTable)]
        assertBool "the stamp moves before a scope it covers" (and [scope < stamp | scope <- scopeSteps, stamp <- stepOf ClusterStamp])
        assertBool "the workspace is not prepared first" (and [row ^. #step > first' | row <- moving, row ^. #state /= PayloadWorkspace, first' <- stepOf PayloadWorkspace])
        assertBool
          "a state that differs has no step that moves it"
          (and [row ^. #step > 0 | row <- transitionTable, row ^. #observed `elem` [SourcePathsOnly, Changed]])
        assertBool "a state is listed twice" (Map.size (Map.fromList [(row ^. #state, ()) | row <- transitionTable]) == length transitionTable)
    , testCase "the rendering has one line per row" $
        length (T.lines (renderTransitionTable transitionTable)) @?= length transitionTable + 2
    ]

-- | What the fixture shows for each state, from v0.4.0 to this payload.
observeFixture :: IO (Map TransitionState TransitionDelta)
observeFixture = do
  source <- manifestAt sourceRoot
  target <- manifestAt targetRoot
  -- This release pins the digests of its own MinIO and auth manifests (F41)
  -- and refuses the source payload's, which is why the workspace moves with
  -- the CLI; the source side takes those components from this tree. The auth
  -- manifests differ since EP-187 changed the En schema.
  refused <- compileLocalObjectStore sourceCompileRoot (sourceFoundation sourceCompileRoot) localStore minioImages
  case refused of
    Left errors | any ((== "invalid-local-object-store") . (^. #code)) errors -> pure ()
    other -> assertFailure ("this release compiled the v0.4.0 MinIO manifest: " <> either show (const "accepted") other)
  refusedAuth <- compilePackagedAuth sourceCompileRoot (sourceFoundation sourceCompileRoot) LocalAuth "127-0-0-1.sslip.io" fixtureAuthImages (DatabaseBackupTarget (MinioBackend localStore) HourlyRecoveryPoint)
  case refusedAuth of
    Left errors | any ((== "invalid-auth-component") . (^. #code)) errors -> pure ()
    other -> assertFailure ("this release compiled the v0.4.0 auth manifests: " <> either show (const "accepted") other)
  sourceScopes <- compileLocalPlatform sourceCompileRoot targetRoot source
  targetScopes <- compileLocalPlatform targetRoot targetRoot target
  recorded <- recordedPairs
  compiled <-
    forM (Map.keys (Map.union sourceScopes targetScopes)) $ \name ->
      pure (name, deltaOf (Map.lookup name sourceScopes) (Map.lookup name targetScopes))
  -- Both views of a scope must agree: this release compiling either payload,
  -- and what each release accepted in the rehearsal.
  forM_ compiled $ \(name, delta) -> case Map.lookup name recorded of
    Just accepted -> assertEqual ("scope " <> T.unpack name <> ": compiled and recorded deltas") accepted delta
    Nothing -> pure ()
  let scopes = Map.union (Map.fromList compiled) recorded
  nixos <- (==) <$> treeDigest (sourceRoot </> "nixos") <*> treeDigest (targetRoot </> "nixos")
  headValue <- BS.readFile (storeRoot </> "head.json") >>= expectRight . decodeHead
  let cloudAccepted = [scope | (scope, _) <- Map.toList (headAccepted headValue), nameText (scopeName scope) `elem` cloudScopeNames]
      differs a b = if a == b then Unchanged else Changed
  pure $
    Map.fromList
      ( [ (PayloadWorkspace, differs (source ^. #payloadId) (target ^. #payloadId))
        , -- The two reads above re-encode the recorded heads and events
          -- byte for byte, or fail.
          (StoreHead, Unchanged)
        , (JournalWire, Unchanged)
        , (CloudScopes, if null cloudAccepted then NotInLocalContext else Changed)
        , (HostClosure, if nixos then Unchanged else Changed)
        , (ClusterStamp, Map.findWithDefault Unchanged "bootstrap-stamp" scopes)
        , (ContextPin, differs (source ^. #platformVersion) (target ^. #platformVersion))
        , -- Opt-in per context (EP-198); the fixture's context does not enable it.
          (PlatformScope "admin-api", Map.findWithDefault NotInLocalContext "admin-api" scopes)
        ]
          <> [(PlatformScope name, delta) | (name, delta) <- Map.toList scopes, name /= "bootstrap-stamp"]
      )
  where
    cloudScopeNames = ["cloud-foundation", "cloud", "host-image-build", "host-image", "host", "cache", "cache-image"]

deltaOf :: Maybe ScopeDeclaration -> Maybe ScopeDeclaration -> TransitionDelta
deltaOf (Just a) (Just b)
  | encodeCanonicalScope a == encodeCanonicalScope b = Unchanged
  | sameDeclarationsModuloSource a b = SourcePathsOnly
deltaOf _ _ = Changed

-- | Each platform scope's delta between the revision v0.4.0 last accepted
-- and the one the rehearsal ended on, from revisions.json and the recorded
-- scope files.
recordedPairs :: IO (Map Text TransitionDelta)
recordedPairs = do
  scopes <- recordedScopes
  revisions :: Value <- BS.readFile (storeRoot </> "revisions.json") >>= expectRight . eitherDecodeStrict'
  pairs :: [Value] <- expectRight (parseEither (Aeson.withObject "revisions" (Aeson..: "scopes")) revisions)
  fmap Map.fromList . forM pairs $ \pair -> do
    (name, sourceDigest, targetDigest) <- expectRight (parseEither (Aeson.withObject "pair" (\o -> (,,) <$> o Aeson..: "scope" <*> o Aeson..: "source" <*> o Aeson..: "target")) pair)
    pure
      ( name
      , if sourceDigest == (targetDigest :: Text)
          then Unchanged
          else deltaOf (Map.lookup sourceDigest scopes) (Map.lookup targetDigest scopes)
      )

-- | The recorded scope revisions by digest; each file is named by the digest
-- of its bytes and re-encodes to them.
recordedScopes :: IO (Map Text ScopeDeclaration)
recordedScopes = do
  names <- listDirectory (storeRoot </> "scopes")
  fmap Map.fromList . forM names $ \name -> do
    bytes <- BS.readFile (storeRoot </> "scopes" </> name)
    let digest = T.pack (takeBaseName name)
    digestText (contentDigest bytes) @?= digest
    scope <- either (\err -> assertFailure (name <> ": " <> show err) >> error "unreachable") pure (decodeScope bytes)
    encodeCanonicalScope scope @?= bytes
    pure (digest, scope)

-- | The local platform scopes this release compiles from a payload root, the
-- stamp included, with the fixed inputs of a local context: the scopes
-- `platform bootstrap plan` composes in its platform stage. Components whose
-- manifests this release pins (the object store and the auth plane) come
-- from @pinnedRoot@.
compileLocalPlatform :: FilePath -> FilePath -> PayloadManifest -> IO (Map Text ScopeDeclaration)
compileLocalPlatform root pinnedRoot manifest = do
  let observabilityInputs = pinnedObservabilityInputs platformCluster root "v1.32.0"
      foundation = sourceFoundation root
      store = localStore
      snapshot = ok (mkScopeSnapshot (ContextBinding (ok (mkContextId "transition")) (ok (mkName "project"))) Map.empty Map.empty)
  rawUpstream <- configuredUpstreamInputsWithIssuer platformCluster root "127-0-0-1.sslip.io" "k3d-registry.localhost:5000" LocalIssuer >>= expectRight
  (controllerScope, controllerImage, publication) <-
    expectRight (controllerImageDeclaration "k3d-registry.localhost:5000" (ok (mkContentDigest (T.replicate 64 "a"))) (ok (mkContentDigest (T.replicate 64 "b"))))
  upstream <- expectRight (bindNetCertManagerControllerImage platformCluster controllerImage publication rawUpstream)
  (localScope, localNative) <- compileLocalObjectStore pinnedRoot foundation store minioImages >>= expectRight
  bucketJob <- case [resource ^. #identity | (resource, _) <- Map.elems localNative, isBucketJob resource] of
    [job] -> pure job
    other -> assertFailure ("expected one bucket Job, got " <> show other) >> error "unreachable"
  (auth, databases) <-
    expectRight (packagedAuthInputs pinnedRoot foundation LocalAuth "127-0-0-1.sslip.io" fixtureAuthImages (DatabaseBackupTarget (MinioBackend store) HourlyRecoveryPoint))
  (base, _) <-
    compileBootstrapWithAuthAndScopes snapshot (BootstrapInput foundation Nothing upstream [controllerScope]) auth {authExtraPrerequisites = [bucketJob]} databases [localScope]
      >>= expectRight
  (secretScope, _, secretIds) <- compileObservabilitySecrets foundation [(SourceLocation "fixture:grafana" "Secret", grafanaSecret)] >>= expectRight
  let ordered = case observabilityInputs of
        firstRelease : rest -> firstRelease {packagedDependencies = map OrderedAfter secretIds <> packagedDependencies firstRelease} : rest
        [] -> []
  (observability, _) <- compilePinnedObservability platformFoundationOwner ordered >>= expectRight
  metrics <- case observabilityInputs of
    firstRelease : _ -> pure (packagedReleaseId firstRelease)
    [] -> assertFailure "no pinned metrics release" >> error "unreachable"
  (extras, _) <- compileObservabilityExtras root foundation metrics >>= expectRight
  complete <-
    expectRight
      ( composeInventory
          snapshot
          (candidateChanges base <> (ReplaceScope extras :| map ReplaceScope (observability <> [secretScope])))
      )
  vector <- expectRight (bootstrapPreservedScopeVectorDigest snapshot complete)
  let marker = bootstrapMarkerValue (manifest ^. #payloadId) vector (identityFromPayload manifest) "2026-10-11T00:00:00Z"
  (stampScope, _) <- expectRight (compileBootstrapStamp platformCluster marker complete)
  pure
    ( Map.fromList
        [ (nameText (scopeName owner), scope)
        | (owner, scope) <- Map.toList (inventoryScopes (candidateInventory complete)) <> [(scopeId stampScope, stampScope)]
        ]
    )
  where
    isBucketJob resource = case resource ^. #address of
      Kubernetes _ "batch" kind _ name -> nameText kind == "job" && nameText name == "minio-make-bucket"
      _ -> False
    grafanaSecret :: Value
    grafanaSecret =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Secret" :: Text)
        , "metadata" .= object ["name" .= ("grafana-admin" :: Text), "namespace" .= ("monitoring" :: Text)]
        , "stringData" .= object ["admin-user" .= ("admin" :: Text), "admin-password" .= ("fixture-canary" :: Text)]
        ]

platformFoundationOwner :: ScopeId
platformFoundationOwner = ok (mkScopeId Platform "foundation")

fixtureAuthImages :: Map Text Text
fixtureAuthImages = Map.fromList [(name, "k3d-registry.localhost:5000/" <> name <> "@sha256:" <> T.replicate 64 "c") | name <- ["en", "shomei", "nagare-access"]]

platformCluster :: ResourceId
platformCluster = mintResourceId (ok (mkScopeId Platform "cluster")) (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))

-- | The platform foundation a payload root declares, granted to its pinned
-- observability releases.
sourceFoundation :: FilePath -> FoundationInput
sourceFoundation root =
  FoundationInput
    platformFoundationOwner
    platformCluster
    (root </> "cluster/bootstrap/job-runs/resourcequota.yaml")
    (map packagedOwner (pinnedObservabilityInputs platformCluster root "v1.32.0"))

localStore :: MinioRef
localStore = MinioRef "http://minio.nagare-system.svc.cluster.local:9000" "nagare-backups" "nagare-minio-credentials"

minioImages :: LocalMinioImages
minioImages =
  LocalMinioImages
    ("k3d-registry.localhost:5000/nagare-minio@sha256:" <> T.replicate 64 "a")
    ("k3d-registry.localhost:5000/nagare-mc@sha256:" <> T.replicate 64 "b")

-- | The extract the compiles read. The Nix build points it at a copy whose
-- scripts run in the Linux sandbox (patched shebangs); the digest check reads
-- 'sourceRoot' itself.
sourceCompileRoot :: FilePath
sourceCompileRoot = sourceRoot

fixtureRoot, sourceRoot, storeRoot, targetRoot :: FilePath
fixtureRoot = "test/fixtures/transition-0.4.0"
sourceRoot = fixtureRoot </> "payload"
storeRoot = fixtureRoot </> "store"
targetRoot = "../.."

manifestAt :: FilePath -> IO PayloadManifest
manifestAt root = BS.readFile (root </> "release.json") >>= expectRight . eitherDecodeStrict'

-- | payload.sha256: `shasum -a 256` lines, relative to the extract.
readManifest :: IO (Map FilePath Text)
readManifest = do
  lines' <- T.lines . TE.decodeUtf8 <$> BS.readFile (fixtureRoot </> "payload.sha256")
  fmap Map.fromList . forM lines' $ \line -> case T.breakOn "  " line of
    (digest, rest) | not (T.null rest) -> pure (T.unpack (T.drop 2 rest), digest)
    _ -> assertFailure ("unreadable payload.sha256 line: " <> T.unpack line) >> error "unreachable"

-- | Every regular file under a directory, relative to it, sorted.
filesUnder :: FilePath -> IO [FilePath]
filesUnder root = sort . map (makeRelative root) <$> go root
  where
    go dir = do
      entries <- listDirectory dir
      concat
        <$> forM
          entries
          ( \entry -> do
              let path = dir </> entry
              isDir <- doesDirectoryExist path
              if isDir then go path else pure [path]
          )

-- | A digest of a directory's files and their relative paths.
treeDigest :: FilePath -> IO Text
treeDigest root = do
  files <- filesUnder root
  entries <- forM files $ \file -> do
    bytes <- BS.readFile (root </> file)
    pure (T.pack file <> " " <> sha256 bytes)
  pure (sha256 (TE.encodeUtf8 (T.unlines entries)))

sha256 :: ByteString -> Text
sha256 = digestText . contentDigest

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\err -> assertFailure (show err) >> error "unreachable") pure
