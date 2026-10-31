-- | A recorded inventory for the admin API's tests: an in-memory object
-- store that counts reads and can hang or lose an object, seeded with sites,
-- publications and host grants, and a head that has every kind of open
-- execution state.
module Nagare.Api.Server.Test.Fixture
  ( Fixture (..)
  , fixture
  , churnHead
  , markMigrated
  , replaceScope
  , siteScope
  , fixtureBinding
  , authId
  , seedStore
  , sampleSnapshot
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Data.ByteString (ByteString)
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Contract.Prelude
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Versions
import Nagare.Inventory.Artifact (ArtifactDeclarationBundle (..), ArtifactKind (..), ArtifactOwnership (..), ArtifactResourceSpec (..), ConsumerCoverage (..), compileArtifactScope)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Platform.Versions
import Nagare.Resource.Access (mkTeamKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (DataPolicy (..), LifecyclePolicy (..), Sensitivity (..))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)

data Fixture = Fixture
  { store :: !InventoryStore
  , objectReads :: !(IORef Int)
  , hang :: !(IORef Bool)
  , lost :: !(IORef (Set.Set Text))
  , delay :: !(IORef Int)
  -- ^ Microseconds each read takes, like a remote store.
  , peakReads :: !(IORef Int)
  -- ^ The most reads ever in flight at once.
  , declarations :: ![ScopeDeclaration]
  }

fixtureBinding :: ContextBinding
fixtureBinding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))

foundation :: ScopeId
foundation = ok (mkScopeId Platform "foundation")

clusterId :: ResourceId
clusterId = mintResourceId foundation (ok (mkLogicalKey "cluster")) (ok (mkName "resource"))

authId :: ResourceId
authId = ok (mkResourceId "platform:auth/en/service")

-- | @sites@ site scopes of ten declarations each (a Service, two
-- DomainMappings and seven ConfigMaps), one image publication used by the
-- first application, and a user and a team grant on the first two hosts.
-- Every accepted scope has converged except the last site.
fixture :: Int -> IO Fixture
fixture sites = do
  (ops, counter, hung, missing, latency, peak) <- recordingObjects
  inventory <- newObjectStore ops fixtureBinding "client-fixture" Nothing >>= either (fail . show) pure
  scopes <- seedStore inventory sites
  writeIORef counter 0
  pure (Fixture inventory counter hung missing latency peak scopes)

-- | Seed an empty store with the fixture's scopes and head.
seedStore :: InventoryStore -> Int -> IO [ScopeDeclaration]
seedStore inventory sites = do
  let scopes = [siteScope index 1 | index <- [1 .. sites]] <> [publicationScope, applicationScope, grantScope]
  _ <- initializeStore inventory fixtureBinding "client-fixture" >>= either (fail . show) pure
  for_' scopes (publish inventory)
  current <- readHead inventory >>= either (fail . show) pure >>= maybe (fail "no head") pure
  let accepted = Map.fromList [(scopeId declaration, revisionOf 1 declaration) | declaration <- scopes]
      converged = Map.delete (scopeId (siteScope sites 1)) accepted
  replaceHeadIfGenerationMatches
    inventory
    (Just (headGeneration current))
    current
      { headGeneration = headGeneration current + 1
      , headAccepted = accepted
      , headConverged = converged
      , headActiveTransaction = Just "tx-open"
      , headExecutorClaim = Just (ExecutorClaim "tx-open" "client-fixture" 3 "2026-10-16T12:00:00Z")
      , headDataFence = Just (fence accepted)
      , headTransition = Just (TransitionMarker "0.6.2" "nagare-0.6.3-source" "2026-10-16T11:00:00Z" Nothing)
      }
    >>= either (fail . show) pure
  pure scopes

fence :: Map.Map ScopeId ScopeRevision -> DataFenceRecord
fence accepted =
  DataFenceRecord
    { fenceContext = fixtureBinding
    , fenceSession = "session-1"
    , fenceTransaction = Just "tx-open"
    , fenceAccepted = accepted
    , fencePhysical = Map.singleton fencedDatabase (ok (mkPhysicalIdentity "postgres://fixture/docs"))
    , fenceTargets = Set.singleton fencedDatabase
    , fenceAffected = Set.empty
    , fenceRecoveryArtifact = "recovery"
    , fenceRecoveryDigest = contentDigest "recovery"
    , fenceSavedWriters = Map.empty
    , fenceProviderIntent = Nothing
    , fencePhase = FenceChanging
    , fenceAcquiredAt = "2026-10-16T12:30:00Z"
    }

fencedDatabase :: ResourceId
fencedDatabase = ok (mkResourceId "application:docs/database/database")

-- | A head change that leaves every scope revision alone.
churnHead :: Fixture -> IO ()
churnHead (Fixture inventory _ _ _ _ _ _) = do
  current <- readHead inventory >>= either (fail . show) pure >>= maybe (fail "no head") pure
  replaceHeadIfGenerationMatches
    inventory
    (Just (headGeneration current))
    current {headGeneration = headGeneration current + 1, headSequence = headSequence current + 1}
    >>= either (fail . show) pure

-- | Record a store migration on the head. A migrated head refuses every
-- later write, so this is a fixture's last change.
markMigrated :: Fixture -> IO ()
markMigrated (Fixture inventory _ _ _ _ _ _) = do
  current <- readHead inventory >>= either (fail . show) pure >>= maybe (fail "no head") pure
  replaceHeadIfGenerationMatches
    inventory
    (Just (headGeneration current))
    current
      { headGeneration = headGeneration current + 1
      , headMigration = Just (MigrationTombstone "gs://fixture-bucket/nagare/fixture/inventory" (contentDigest "migrated-head"))
      }
    >>= either (fail . show) pure

-- | Accept a new revision of one scope (the open fence records the same
-- accepted vector).
replaceScope :: Fixture -> Integer -> ScopeDeclaration -> IO ()
replaceScope (Fixture inventory _ _ _ _ _ _) generation declaration = do
  publish inventory declaration
  current <- readHead inventory >>= either (fail . show) pure >>= maybe (fail "no head") pure
  let accepted = Map.insert (scopeId declaration) (revisionOf generation declaration) (headAccepted current)
  replaceHeadIfGenerationMatches
    inventory
    (Just (headGeneration current))
    current
      { headGeneration = headGeneration current + 1
      , headAccepted = accepted
      , headDataFence = (\record -> record {fenceAccepted = accepted}) <$> headDataFence current
      }
    >>= either (fail . show) pure

publish :: InventoryStore -> ScopeDeclaration -> IO ()
publish inventory declaration = do
  let bytes = encodeCanonicalScope declaration
  publishIfAbsent inventory (scopeKey (contentDigest bytes)) bytes >>= either (fail . show) (const (pure ()))

revisionOf :: Integer -> ScopeDeclaration -> ScopeRevision
revisionOf generation declaration = ScopeRevision (ok (mkScopeGeneration generation)) (contentDigest (encodeCanonicalScope declaration))

-- | Site @index@ at revision @version@; the version changes its second host.
siteScope :: Int -> Int -> ScopeDeclaration
siteScope index version =
  ok
    ( mkScopeDeclaration
        owner
        [ResourceBundle ([Managed service] <> [Managed (route host) | host <- hosts] <> [Managed (configMap n) | n <- [1 .. 7 :: Int]]) [] [] [] [] []]
    )
  where
    name' = "s" <> Text.pack (show index)
    owner = ok (mkScopeId Standalone ("site-" <> name'))
    serviceId = mintResourceId owner (ok (mkLogicalKey "site")) (ok (mkName "service"))
    hosts = [name' <> ".example.com", name' <> "-v" <> Text.pack (show version) <> ".example.com"]
    managed identity address aliases spec dependencies =
      ManagedResource identity owner KubernetesExecutor address aliases spec Retain Stateless Public dependencies [] (SourceLocation "fixture" name')
    service =
      managed serviceId (ok (kubernetesAddress clusterId "serving.knative.dev/v1" "Service" (Just "personal") name')) [] (KnativeService (contentDigest (encodeUtf8' name'))) [OrderedAfter clusterId]
    route host =
      managed
        (mintResourceId owner (ok (mkLogicalKey (Text.replace "." "-" host))) (ok (mkName "route")))
        (ok (kubernetesAddress clusterId "serving.knative.dev/v1beta1" "DomainMapping" (Just "personal") host))
        [Hostname (ok (mkName host))]
        (NativeObject (contentDigest (encodeUtf8' host)))
        [OrderedAfter clusterId, OrderedAfter serviceId]
    configMap n =
      managed
        (mintResourceId owner (ok (mkLogicalKey ("config-" <> Text.pack (show n)))) (ok (mkName "configmap")))
        (ok (kubernetesAddress clusterId "v1" "ConfigMap" (Just "personal") (name' <> "-config-" <> Text.pack (show n))))
        []
        (NativeObject (contentDigest (encodeUtf8' (name' <> Text.pack (show n)))))
        [OrderedAfter clusterId]

publicationScope :: ScopeDeclaration
publicationScope =
  ok
    ( compileArtifactScope
        ( ArtifactDeclarationBundle
            1
            (ok (mkScopeId Publication "app-image-docs-v1"))
            ( ArtifactResourceSpec
                { artifactLogicalKey = ok (mkLogicalKey "docs-v1")
                , artifactRole = ok (mkName "oci-image")
                , artifactName = ok (mkName "docs-v1")
                , artifactDestination = "registry.example/docs:v1"
                , artifactContentDigest = contentDigest "docs-manifest"
                , artifactSpecDigest = contentDigest "docs-archive"
                , artifactKind = OciImageArtifact
                , artifactOwnership = OwnedArtifact
                , artifactLifecycle = Retain
                , artifactDataPolicy = Stateless
                , artifactSensitivity = Private
                , artifactDependencies = []
                , artifactConsumers = ConsumerCompletenessUnknown
                , artifactPublishOperation = True
                , artifactSource = SourceLocation "docs.tar" "oci-archive-v1"
                }
                :| []
            )
        )
    )

applicationScope :: ScopeDeclaration
applicationScope =
  withScopeOverrides
    (Map.fromList [("imageResource", "publication:app-image-docs-v1/docs-v1/oci-image"), ("tag", "v1")])
    (ok (mkScopeDeclaration (ok (mkScopeId Application "docs")) []))

-- | A user grant on @s1.example.com@, a team grant on @s2.example.com@, and a
-- user grant on a host whose route no longer exists.
grantScope :: ScopeDeclaration
grantScope =
  ok
    ( mkScopeDeclaration
        owner
        [ ResourceBundle
            [ Managed (grant "user" (AccessTuple authId (ok (mkName "s1.example.com")) "user_1"))
            , Managed (grant "team" (TeamAccessTuple authId (ok (mkName "s2.example.com")) (ok (mkTeamKey "editors"))))
            , Managed (grant "retired" (AccessTuple authId (ok (mkName "gone.example.com")) "user_2"))
            ]
            []
            []
            []
            []
            []
        ]
    )
  where
    owner = ok (mkScopeId Standalone "access-fixture")
    grant key address =
      ManagedResource
        (mintResourceId owner (ok (mkLogicalKey key)) (ok (mkName "grant")))
        owner
        AccessExecutor
        address
        []
        (AccessGrantSpec "http://en.nagare-system.svc.clusterId.local" True)
        Retain
        Stateless
        Private
        []
        []
        (SourceLocation "fixture" key)

-- | Objects in memory. Every read is counted; a hung store blocks reads; a
-- lost key reads as absent.
recordingObjects :: IO (ObjectOps, IORef Int, IORef Bool, IORef (Set.Set Text), IORef Int, IORef Int)
recordingObjects = do
  state <- newIORef (0 :: Integer, Map.empty :: Map.Map ObjectName (Generation, ByteString))
  counter <- newIORef 0
  hung <- newIORef False
  missing <- newIORef Set.empty
  latency <- newIORef 0
  inFlight <- newIORef (0 :: Int)
  peak <- newIORef 0
  let blockWhileHung = do
        isHung <- readIORef hung
        when isHung (threadDelay 100000 >> blockWhileHung)
      measured action = do
        now <- atomicModifyIORef' inFlight (\count -> (count + 1, count + 1))
        atomicModifyIORef' peak (\highest -> (max highest now, ()))
        action `finally` atomicModifyIORef' inFlight (\count -> (count - 1, ()))
      get name@(ObjectName key) = measured $ do
        modifyIORef' counter (+ 1)
        blockWhileHung
        readIORef latency >>= \micros -> when (micros > 0) (threadDelay micros)
        gone <- Set.member key <$> readIORef missing
        (_, objects) <- readIORef state
        pure (if gone then ObjectAbsent else maybe ObjectAbsent (uncurry ObjectFound) (Map.lookup name objects))
  pure
    ( ObjectOps
        { getObject = get
        , getImmutableObject = fmap immutableGet . get
        , getObjects = \_ -> pure (Left "the fixture store does not list")
        , putObject = \condition name bytes -> atomicModifyIORef' state $ \(lastGeneration, objects) ->
            let existing = Map.lookup name objects
                matches = case condition of
                  IfAbsent -> isNothing existing
                  IfGenerationMatches expected -> maybe False ((== expected) . fst) existing
             in if matches
                  then ((lastGeneration + 1, Map.insert name (Generation (lastGeneration + 1), bytes) objects), PutWritten (Generation (lastGeneration + 1)))
                  else ((lastGeneration, objects), PutPreconditionFailed)
        , listObjects = \_ -> pure (Left "the fixture store does not list")
        , pauseBeforeRetry = threadDelay
        }
    , counter
    , hung
    , missing
    , latency
    , peak
    )

encodeUtf8' :: Text -> ByteString
encodeUtf8' = TE.encodeUtf8

for_' :: [a] -> (a -> IO ()) -> IO ()
for_' xs action = mapM_ action xs

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

-- | A platform-versions snapshot of the fixture context (EP-236): release
-- 0.13.0 installed from a legacy stamp without a payload ID, one NixOS
-- node, one component mid-rollout with two digests, and one PostgreSQL
-- server declared @18@.
sampleSnapshot :: VersionSnapshot
sampleSnapshot =
  VersionSnapshot
    { snapshotSchema = snapshotSchemaVersion
    , context = "fixture"
    , project = "project"
    , collectedAt = "2026-10-31T16:00:02Z"
    , completedAt = "2026-10-31T16:00:09Z"
    , inventoryRevision = Nullable (Just "sha256:head")
    , reason = Nullable Nothing
    , installed =
        Nullable
          ( Just
              InstalledRelease
                { version = stamp (Just "0.13.0")
                , revision = stamp (Just "0123456789abcdef0123456789abcdef01234567")
                , payloadId = stamp Nothing
                , installedAt = stamp (Just "2026-10-30T09:00:00Z")
                }
          )
    , pins =
        Nullable
          ( Just
              Pins
                { context = recordedFact "context profile" at (Just "0.13.0")
                , hostVersion = recordedFact "generated host flake" at (Just "0.13.0")
                , hostRevision = recordedFact "generated host flake" at Nothing
                }
          )
    , hosts =
        [ HostVersions
            { node = "nagare-01"
            , uid = "node-uid-1"
            , osImage = node' (Just "NixOS 26.11 (Zebra)")
            , kernel = node' (Just "6.12.40")
            , kubernetes = node' (Just "v1.33.4+k3s1")
            , nixos =
                NixosIdentity
                  { release = identity (Just "26.11")
                  , codename = identity (Just "Zebra")
                  , version = identity (Just "26.11.20261020.eaad089")
                  , nixpkgsRevision = identity (Just "eaad0894")
                  }
            }
        ]
    , hostsReason = Nullable Nothing
    , components =
        [ ComponentVersions
            { scope = "platform:upstream"
            , resource = "platform:upstream/knative-controller/deployment"
            , kind = "Deployment"
            , namespace = "knative-serving"
            , name = "controller"
            , declaredVersion = declared (Just "1.19.0")
            , declaredChartVersion = missingFact SourceRecorded "accepted declaration" at reasonNotApplicable
            , declaredImages = [DeclaredImage "controller" (declared (Just "gcr.io/knative-releases/controller@sha256:new"))]
            , workloads = [workload "controller-a" "pod-a" "sha256:old", workload "controller-b" "pod-b" "sha256:new"]
            , workloadsReason = Nullable Nothing
            }
        ]
    , componentsReason = Nullable Nothing
    , databases =
        [ DatabaseVersions
            { scope = "standalone:labs-postgres"
            , namespace = "databases"
            , server = "labs-postgres"
            , engine = "postgres"
            , declaredVersion = declared (Just "18")
            , declaredImage = declared (Just "postgres:18")
            , instances =
                [ DatabaseInstance
                    { pod = "labs-postgres-0"
                    , podUid = "pod-pg"
                    , image = pods (Just "postgres:18")
                    , imageDigest = pods (Just "sha256:pg")
                    , reportedVersion = observedFact "SELECT version()" "2026-10-31T16:00:06Z" (Just "PostgreSQL 18.1 on aarch64-unknown-linux-gnu")
                    }
                ]
            , instancesReason = Nullable Nothing
            }
        ]
    , databasesReason = Nullable Nothing
    }
  where
    at = "2026-10-31T16:00:02Z"
    stamp = recordedFact "configmap nagare-system/nagare-platform-version" at
    node' = observedFact "node status.nodeInfo" at
    identity = recordedFact "configmap kube-system/nagare-host-identity" at
    declared = recordedFact "accepted declaration" at
    pods = observedFact "pod status" "2026-10-31T16:00:04Z"
    workload podName podId digest =
      Workload podName podId [ObservedContainer "controller" (pods (Just "gcr.io/knative-releases/controller")) (pods (Just digest))]
