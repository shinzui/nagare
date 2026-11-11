-- | EP-247: a bounded teamDelegation for a named deployer. The bounds are pure
-- (D4) and run again at admission against the admitted head (D5); every
-- review records its actor and source (D6); a deployer context runs only its
-- commands (D3); a stale review is retryable (D11).
module Nagare.Test.Delegation
  ( delegationTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Contract.Delegation (ActorSummary (..), TransactionHistory (..), TransactionSummary (..))
import Nagare.Contract.Problem (admissionRefused, problemCatalog, reviewChanged, reviewStale)
import Nagare.Contract.Schema (fromNullable)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Actor
import Nagare.Inventory.Adapter
import Nagare.Inventory.Command (admissionProblem, unverifiedReviewProblem)
import Nagare.Inventory.DataService (acceptedAppNamespace)
import Nagare.Inventory.DelegatedPlanning (attributeReview, delegatedCandidate)
import Nagare.Inventory.DeployerCommands (commandWords, contextArgument, guardDeployerCommand)
import Nagare.Inventory.DeployerDelegation
import Nagare.Inventory.Digest
import Nagare.Inventory.Execute
import Nagare.Inventory.Journal
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.TransactionHistory (readTransactionHistory)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.SiteInventory.Access (SiteFixture (..), protectedSiteFixture, publicSiteScope)
import Test.Tasty
import Test.Tasty.HUnit

delegationTests :: TestTree
delegationTests =
  testGroup
    "Delegation"
    [ testGroup "scope" scopeTests
    , testGroup "bounds" boundsTests
    , testCase "a revoked delegation refuses a saved deployer review at admission; an operator review is still admitted; history names each actor" admissionAndHistory
    , testGroup "commands" commandTests
    , testGroup "actor wire" actorTests
    , testCase "review_stale is a retryable 409 for refusals caused only by another change landing first" $ do
        assertBool "catalogued" (reviewStale `elem` problemCatalog)
        (reviewStale ^. #status, reviewStale ^. #retryable) @?= (409, True)
        let refusal code = AdmissionError code "refused"
        forM_ ["stale-head", "stale-base", "head-condition"] $ \code -> admissionProblem (refusal code :| []) @?= reviewStale
        admissionProblem (refusal "stale-head" :| [refusal "stale-base"]) @?= reviewStale
        forM_ ["delegation-revoked", "delegation-bounds", "active-transaction", "context-binding"] $ \code -> admissionProblem (refusal code :| []) @?= admissionRefused
        admissionProblem (refusal "stale-head" :| [refusal "delegation-revoked"]) @?= admissionRefused
    , testCase "a review saved before another change landed is review_stale at apply, unless its delegation refuses it" $ do
        let stale code = ReviewError code "stale"
            revoked = AdmissionError "delegation-revoked" "revoked" :| []
        unverifiedReviewProblem (stale "stale-head" :| [stale "stale-base"]) Nothing @?= reviewStale
        unverifiedReviewProblem (stale "stale-head" :| [stale "stale-base"]) (Just revoked) @?= admissionRefused
        unverifiedReviewProblem (stale "stale-head" :| [stale "scope-member"]) Nothing @?= reviewChanged
        unverifiedReviewProblem (stale "unpublished-review" :| []) Nothing @?= reviewChanged
    ]

-- ---------------------------------------------------------------------------
-- D1: the teamDelegation scope.

teamDelegation :: DeployerDelegation
teamDelegation =
  DeployerDelegation
    { name = "kotei"
    , state = DelegationActive
    , namespaces = "team-a" :| ["team-b"]
    , hostSuffixes = ["-docs"]
    , kinds = DelegatedWebApp :| [DelegatedStaticSite]
    , imageRepository = "registry.example.test/project/nagare/team"
    , team = "engineering"
    , buildNamespace = Just "team-build"
    , quota = defaultQuota
    , baseDomain = "example.com"
    , hostShape = NestedHosts
    }

scopeTests :: [TestTree]
scopeTests =
  [ testCase "compiles each namespace with a quota and limits, the build namespace, and the record, all Retain" $ do
      (scope, native) <- expectRight (compileDelegationScope fixtureCluster systemNamespace teamDelegation)
      scopeIdText (scopeId scope) @?= "platform:delegation-kotei"
      let members = [resource | bundle <- scopeBundles scope, Managed resource <- bundle ^. #declarations]
          kinds' = [(nameText kind, maybe "" nameText ns, nameText n) | resource <- members, Kubernetes _ _ kind ns n <- [resource ^. #address]]
      length members @?= 10
      all ((== Retain) . (^. #lifecycle)) members @? "every member is Retain"
      [n | ("namespace", _, n) <- kinds'] @?= ["team-a", "team-b", "team-build"]
      length [() | ("resourcequota", _, _) <- kinds'] @?= 3
      length [() | ("limitrange", _, _) <- kinds'] @?= 3
      [(ns, n) | ("configmap", ns, n) <- kinds'] @?= [("nagare-system", "nagare-delegation-kotei")]
      Map.size native @?= 10
      let labels name' = [labelsOf bytes | (resource, bytes) <- Map.elems native, Kubernetes _ _ kind Nothing n <- [resource ^. #address], nameText kind == "namespace", nameText n == name']
      labels "team-a" @?= [Map.fromList [("app.kubernetes.io/part-of", "nagare"), ("nagare.dev/app-namespace", "true"), ("nagare.dev/delegation", "kotei")]]
      labels "team-build" @?= [Map.fromList [("app.kubernetes.io/part-of", "nagare"), ("nagare.dev/build-namespace", "true"), ("nagare.dev/delegation", "kotei")]]
  , testCase "the accepted head alone answers the teamDelegation, through the scope's overrides" $ do
      (scope, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace teamDelegation)
      Map.lookup "kotei" (acceptedDelegations (Map.singleton (scopeId scope) scope)) @?= Just teamDelegation
      decoded <- expectRight (encodeDelegation teamDelegation >>= decodeDelegation)
      decoded @?= teamDelegation
  , testCase "app commands accept an active delegation's namespace and no other" $ do
      (scope, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace teamDelegation)
      (revoked, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace (teamDelegation & #state .~ DelegationRevoked))
      let snapshotOf delegationScope = ok (mkScopeSnapshot binding' (Map.fromList [(scopeId s', (generationOne, s')) | s' <- [foundationScope, delegationScope]]) Map.empty)
      acceptedAppNamespace (snapshotOf scope) "team-a" @?= Right (fixtureCluster, delegatedNamespaceId)
      assertBool "a namespace no accepted scope owns" (isLeft (acceptedAppNamespace (snapshotOf scope) "team-z"))
      assertBool "the build namespace runs no apps" (isLeft (acceptedAppNamespace (snapshotOf scope) "team-build"))
      assertBool "a revoked delegation's namespace" (isLeft (acceptedAppNamespace (snapshotOf revoked) "team-a"))
  , testCase "refuses reserved, duplicate and malformed namespaces and names"
      $ forM_
        [ teamDelegation & #namespaces .~ ("nagare-system" :| [])
        , teamDelegation & #namespaces .~ ("kube-system" :| [])
        , teamDelegation & #namespaces .~ ("personal" :| [])
        , teamDelegation & #namespaces .~ ("team-a" :| ["team-a"])
        , teamDelegation & #buildNamespace .~ Just "team-a"
        , teamDelegation & #name .~ "Kotei"
        , teamDelegation & #imageRepository .~ "registry.example.test/team:latest"
        , teamDelegation & #imageRepository .~ "k3d-registry.localhost:5000/project/team@sha256"
        , teamDelegation & #imageRepository .~ "k3d-registry.localhost:5000/project/team:v1"
        , teamDelegation & #imageRepository .~ "k3d-registry.localhost:port/project/team"
        , teamDelegation & #imageRepository .~ "registry.example.test/team/"
        , teamDelegation & #imageRepository .~ "registry.example.test"
        , teamDelegation & #team .~ ""
        ]
      $ \candidate -> assertBool (show candidate) (isLeft (validateDelegation candidate))
  , testCase "accepts a registry host with a port, as a local registry has" $
      fmap (^. #imageRepository) (validateDelegation (teamDelegation & #imageRepository .~ "k3d-registry.localhost:5000/tan-nb-exp/nagare/team-a"))
        @?= Right "k3d-registry.localhost:5000/tan-nb-exp/nagare/team-a"
  , testCase "the generated protected route's digest matches the production site compiler" $ do
      fixture <- protectedSiteFixture
      let routes = [digest | bundle <- scopeBundles (protectedSite fixture), Managed resource <- bundle ^. #declarations, Kubernetes _ _ kind (Just ns) host <- [resource ^. #address], nameText kind == "domainmapping", nameText ns == "nagare-system", NativeObject digest <- [resource ^. #spec], nameText host == "secure.example.com"]
      expected <- expectRight (expectedProtectedMappingDigest "secure.example.com")
      routes @?= [expected]
  ]
  where
    labelsOf bytes = case eitherDecode (LBS.fromStrict bytes) of
      Right (Object root)
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object labels) <- KM.lookup "labels" metadata ->
            Map.fromList [(Key.toText key, value) | (key, String value) <- KM.toList labels]
      _ -> Map.empty :: Map.Map Text Text

-- ---------------------------------------------------------------------------
-- D4: one passing proposal and one per bound, on the production compiler's
-- protected and public static sites. The fixture deploys into @personal@ at
-- @*.example.com@, so the bound teamDelegation names that namespace directly.

siteDelegation :: DeployerDelegation
siteDelegation =
  teamDelegation
    & #namespaces
    .~ ("personal" :| [])
    & #hostSuffixes
    .~ ["secure"]

checkWith :: DeployerDelegation -> Map.Map ScopeId ScopeDeclaration -> [ScopeDeclaration] -> Either (NonEmpty DelegationViolation) ()
checkWith d acceptedScopes replacedScopes =
  checkDelegatedProposal
    DelegationCheck
      { deployer = "kotei"
      , delegations = Map.singleton "kotei" d
      , replaced = replacedScopes
      , retired = []
      , collected = []
      , accepted = acceptedScopes
      }

bounds' :: Either (NonEmpty DelegationViolation) () -> [Text]
bounds' = either (map (^. #bound) . NE.toList) (const [])

boundsTests :: [TestTree]
boundsTests =
  [ testCase "a protected site inside the delegation passes, including its generated route in nagare-system" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      checkWith siteDelegation Map.empty [site] @?= Right ()
  , testCase "(a) a platform scope is refused" $ do
      (scope, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace teamDelegation)
      assertBool "scope-kind" ("scope-kind" `elem` bounds' (checkWith siteDelegation Map.empty [stamped scope]))
  , testCase "(b) members outside the delegated namespaces are refused" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      assertBool "namespace" ("namespace" `elem` bounds' (checkWith (siteDelegation & #namespaces .~ ("team-a" :| [])) Map.empty [site]))
  , testCase "(c) a hostname outside the delegation is refused" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      assertBool "hostname" ("hostname" `elem` bounds' (checkWith (siteDelegation & #hostSuffixes .~ ["-docs"]) Map.empty [site]))
  , testCase "(d) a public site is refused" $ do
      site <- stamped <$> publicSiteScope "demo"
      let found = bounds' (checkWith (siteDelegation & #hostSuffixes .~ ["demo"]) Map.empty [site])
      assertBool (show found) ("access" `elem` found && "member-kind" `elem` found)
  , testCase "(e) volumes, namespace requests and undelegated kinds are refused" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      let withVolume = addMember site (kubernetesMember (scopeId site) "v1" "PersistentVolumeClaim" (Just "personal") "data")
          withNamespace = addContribution site (RegisterNamespace authOwnerScope fixtureCluster (known "extra") (ok (mkLogicalKey "extra")))
      assertBool "volume" ("member-kind" `elem` bounds' (checkWith siteDelegation Map.empty [withVolume]))
      assertBool "namespace request" ("member-kind" `elem` bounds' (checkWith siteDelegation Map.empty [withNamespace]))
      assertBool "kind" ("scope-kind" `elem` bounds' (checkWith (siteDelegation & #kinds .~ (DelegatedWorker :| [])) Map.empty [site]))
  , testCase "(f) an image outside the delegation's repository is refused" $ do
      let inside = imageScope "registry.example.test/project/nagare/team/web:v1"
          outside = imageScope "registry.example.test/project/nagare/other/web:v1"
          prefixOnly = imageScope "registry.example.test/project/nagare/teamwork/web:v1"
      checkWith teamDelegation Map.empty [inside] @?= Right ()
      bounds' (checkWith teamDelegation Map.empty [outside]) @?= ["image-repository"]
      bounds' (checkWith teamDelegation Map.empty [prefixOnly]) @?= ["image-repository"]
  , testCase "(g) a scope another actor wrote is refused, and so is an unstamped proposal" $ do
      fixture <- protectedSiteFixture
      let operatorSite = protectedSite fixture
      assertBool "accepted by the operator" ("ownership" `elem` bounds' (checkWith siteDelegation (Map.singleton (scopeId operatorSite) operatorSite) [stamped operatorSite]))
      assertBool "unstamped" ("ownership" `elem` bounds' (checkWith siteDelegation Map.empty [operatorSite]))
      checkWith siteDelegation (Map.singleton (scopeId operatorSite) (stamped operatorSite)) [stamped operatorSite] @?= Right ()
  , testCase "a route in nagare-system targeting another Service, a foreign host's route, and an unrelated system object are refused" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      let retargeted = mapMembers (\resource -> if isRoute resource then resource & #spec .~ NativeObject (contentDigest "another-target") else resource) site
          foreign' = addMember site ((kubernetesMember (scopeId site) "serving.knative.dev/v1beta1" "DomainMapping" (Just "nagare-system") "secure-other.example.com") & #spec .~ NativeObject (ok (expectedProtectedMappingDigest "secure-other.example.com")))
          systemObject = addMember site (kubernetesMember (scopeId site) "v1" "ConfigMap" (Just "nagare-system") "nagare-shomei-settings")
          broad = siteDelegation & #hostSuffixes .~ ["secure", "other"]
      bounds' (checkWith siteDelegation Map.empty [retargeted]) @?= ["namespace"]
      bounds' (checkWith broad Map.empty [foreign']) @?= ["namespace"]
      bounds' (checkWith siteDelegation Map.empty [systemObject]) @?= ["namespace"]
  , testCase "a revoked or absent teamDelegation refuses everything; collections are refused" $ do
      site <- stamped . protectedSite <$> protectedSiteFixture
      map (^. #code) (either NE.toList (const []) (checkWith (siteDelegation & #state .~ DelegationRevoked) Map.empty [site])) @?= ["delegation-revoked"]
      let check' = DelegationCheck "kotei" Map.empty [site] [] [] Map.empty
      map (^. #code) (either NE.toList (const []) (checkDelegatedProposal check')) @?= ["delegation-revoked"]
      let collecting = DelegationCheck "kotei" (Map.singleton "kotei" siteDelegation) [] [] [ok (mkResourceId "application:web/data/volume")] Map.empty
      bounds' (checkDelegatedProposal collecting) @?= ["member-kind"]
  , testCase "hostnames: a delegated namespace's default name, one suffixed label, and nothing deeper or foreign" $ do
      let allowed = hostWithinDelegation teamDelegation NestedHosts "example.com" False
          flat = hostWithinDelegation teamDelegation FlatHosts "example.com" False
      map allowed ["web.team-a.example.com", "api-docs.example.com"] @?= [True, True]
      map allowed ["web.other.example.com", "a.web.team-a.example.com", "docs.example.com", "web.team-a.example.org"] @?= [False, False, False, False]
      map flat ["web-team-a.example.com", "web.team-a.example.com"] @?= [True, False]
  ]
  where
    stamped = stampDeployerScope "kotei"
    isRoute resource = case resource ^. #address of
      Kubernetes _ _ kind (Just ns) _ -> nameText kind == "domainmapping" && nameText ns == "nagare-system"
      _ -> False

-- ---------------------------------------------------------------------------
-- D5 and D6 through the store: admission rechecks the teamDelegation of the
-- admitted head, and history reads each transaction's actor from its review.

admissionAndHistory :: Assertion
admissionAndHistory = do
  store <- newMemoryStore
  _ <- initializeStore store binding' "delegation" >>= expectRight
  (delegationScope, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace teamDelegation)
  accept store anonymousOperator Nothing [ReplaceScope foundationScope, ReplaceScope delegationScope]
  accept store (DeployerActor "kotei") (Just (ReviewSource (Just "https://forge.example.test/team/site") (Just "abc123") (Just "https://ci.example.test/runs/7"))) [ReplaceScope (stampDeployerScope "kotei" (appScope "v1"))]
  -- D4 through the preparation path: the deployer's candidate is stamped,
  -- and an out-of-bounds one is refused before anything is published.
  history <- loadInventoryHistory store >>= expectRight
  let candidateOf scope = ok (composeInventory (ok (mkScopeSnapshot binding' (Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)) (historyReservations history))) (ReplaceScope scope :| []))
  stampedCandidate <- expectRight (delegatedCandidate (DeployerActor "kotei") history (candidateOf (appScope "v2")))
  fmap (Map.lookup deployerOverrideKey . scopeOverrides) (Map.lookup (ok (mkScopeId Application "web")) (inventoryScopes (candidateInventory stampedCandidate))) @?= Just (Just "kotei")
  objectsBefore <- readStoreSnapshot store >>= expectRight
  case delegatedCandidate (DeployerActor "kotei") history (candidateOf (appScopeIn "team-z" "v2")) of
    Left reason -> assertBool (T.unpack reason) ("delegation-bounds" `T.isInfixOf` reason)
    Right _ -> assertFailure "a member outside the delegation was planned"
  objectsAfter <- readStoreSnapshot store >>= expectRight
  assertBool "a refused proposal writes nothing" (storeSnapshotReviewDigests objectsBefore == storeSnapshotReviewDigests objectsAfter && storeSnapshotHead objectsBefore == storeSnapshotHead objectsAfter)
  saved <- prepared store (DeployerActor "kotei") Nothing [ReplaceScope (stampDeployerScope "kotei" (appScope "v2"))]
  (revoked, _) <- expectRight (compileDelegationScope fixtureCluster systemNamespace (teamDelegation & #state .~ DelegationRevoked))
  accept store (OperatorActor (Just "alice")) Nothing [ReplaceScope revoked]
  before <- readHead store >>= expectRight
  refused <- applyReviewed store registry saved
  case refused of
    Left errors -> assertBool (show errors) ("delegation-revoked" `elem` map admissionErrorCode (NE.toList errors))
    Right _ -> assertFailure "a deployer review saved before the revocation was admitted"
  after <- readHead store >>= expectRight
  fmap headSequence after @?= fmap headSequence before
  accept store anonymousOperator Nothing [ReplaceScope (appScope "v3")]
  headValue <- readHead store >>= expectRight >>= maybe (assertFailure "no head") pure
  history <- readTransactionHistory store headValue 10 >>= either (assertFailure . T.unpack) pure
  let actors = [(summary ^. #actor . #kind, fromNullable (summary ^. #actor . #name), summary ^. #state) | summary <- history ^. #transactions]
  actors
    @?= [ ("operator", Nothing, "converged")
        , ("operator", Just "alice", "converged")
        , ("deployer", Just "kotei", "converged")
        , ("operator", Nothing, "converged")
        ]
  map (^. #scopes) (history ^. #transactions)
    @?= [["application:web"], ["platform:delegation-kotei"], ["application:web"], ["platform:delegation-kotei", "platform:foundation"]]
  where
    candidateFor store changes = do
      history <- loadInventoryHistory store >>= expectRight
      let accepted = Map.map (\(revision, declaration) -> (revisionGeneration revision, declaration)) (historyAccepted history)
      candidate <- expectRight (composeInventory (ok (mkScopeSnapshot binding' accepted (historyReservations history))) (NE.fromList changes))
      let absent = ok (observationSet [(resource ^. #identity, ConfirmedAbsent (contentDigest "absent")) | Managed resource <- inventoryDeclarations (candidateInventory candidate)])
      proposal <- expectRight (planChanges candidate noLifecycleDecisions history absent)
      pure proposal
    prepared store actor source changes = do
      proposal <- candidateFor store changes
      snapshot <- readStoreSnapshot store >>= expectRight
      review <- attributeReview actor source <$> (prepareReview registry snapshot proposal >>= expectRight)
      _ <- publishReview store review >>= expectRight
      published <- readStoreSnapshot store >>= expectRight
      expectRight (verifyReview published review)
    accept store actor source changes = do
      reviewed <- prepared store actor source changes
      -- D8: only a deployer or a named operator writes an actor, so an
      -- unnamed operator's review keeps the bytes an older reader accepts.
      let written = "\"actor\"" `T.isInfixOf` TE.decodeUtf8 (encodeReviewDocument (reviewedDocument reviewed))
      written @?= (actor /= anonymousOperator)
      _ <- applyReviewed store registry reviewed >>= expectRight
      pure ()

-- A web app's configuration in the delegated namespace.
appScope :: Text -> ScopeDeclaration
appScope = appScopeIn "team-a"

appScopeIn :: Text -> Text -> ScopeDeclaration
appScopeIn ns version =
  let owner = ok (mkScopeId Application "web")
      member = kubernetesMemberWith owner "v1" "ConfigMap" (Just ns) "web-config" (object ["data" .= object ["version" .= version]])
   in ok (mkScopeDeclaration owner [ResourceBundle [Managed (member & #dependencies .~ [OrderedAfter delegatedNamespaceId])] [] [] [] [] []])

delegatedNamespaceId :: ResourceId
delegatedNamespaceId = mintResourceId (ok (delegationScopeId "kotei")) (ok (mkLogicalKey "delegation")) (known "namespace-team-a")

registry :: AdapterRegistry
registry =
  ok
    ( mkAdapterRegistry
        [ Adapter
            { adapterExecutor = KubernetesExecutor
            , adapterIdentity = "recording"
            , adapterVersion = "1"
            , adapterObserve = \resources -> pure (observationSet [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- resources])
            , adapterPrepare = \operation -> pure (Right (PreparedNative (ok (canonicalValue (toJSON operation))) "recording adapter"))
            , adapterPreflight = \_ _ -> pure (Right ())
            , adapterExecute = \_ _ -> pure AdapterEffectCompleted
            , adapterVerify = \operation _ -> pure (Right (proof operation))
            , adapterSettle = Nothing
            , adapterRecover = \operation _ -> pure (RecoveryProvedComplete (proof operation))
            }
        ]
    )
  where
    proof = contentDigest . TE.encodeUtf8 . operationIdText . plannedOperationId

-- ---------------------------------------------------------------------------
-- D3: every top-level command in a deployer context.

commandTests :: [TestTree]
commandTests =
  [ testCase "a deployer context runs only its delegated commands" $
      forM_ table $ \(arguments, allowed) ->
        assertEqual (T.unpack (T.unwords arguments)) allowed (isRight (guardDeployerCommand (DeployerActor "kotei") arguments))
  , testCase "an operator runs everything" $
      forM_ table $
        \(arguments, _) -> guardDeployerCommand anonymousOperator arguments @?= Right ()
  , testCase "the global --context is skipped and read" $ do
      commandWords ["--context", "ci", "app", "deploy", "-f", "x"] @?= ["app", "deploy"]
      contextArgument ["--context=ci", "app", "deploy"] @?= Just "ci"
      contextArgument ["app", "deploy"] @?= Nothing
  , testCase "a refusal names the command" $
      guardDeployerCommand (DeployerActor "kotei") ["env", "set", "X=1"] @?= Left (T.concat ["nagarectl env set is not available in deployer context kotei; ", allowedText])
  ]
  where
    allowedText = "a delegated deployer may run app image-plan|check|deploy|delete, worker deploy, task run|delete, site deploy|rollback|preview, inventory apply|resume|status|publications|history, delegation show and version"
    table =
      [ (["version"], True)
      , (["release", "publish"], False)
      , (["inventory", "apply", "dir", "--yes"], True)
      , (["inventory", "resume", "tx"], True)
      , (["inventory", "status"], True)
      , (["inventory", "publications"], True)
      , (["inventory", "history"], True)
      , (["inventory", "plan"], False)
      , (["inventory", "retire"], False)
      , (["platform", "status"], False)
      , (["host", "status"], False)
      , (["kubeconfig", "fetch"], False)
      , (["cluster", "status"], False)
      , (["deploy"], False)
      , (["site", "deploy"], True)
      , (["site", "rollback", "v1"], True)
      , (["site", "preview", "deploy", "--name", "x"], True)
      , (["site", "package"], False)
      , (["site", "publish"], False)
      , (["env", "set"], False)
      , (["secret", "set"], False)
      , (["app", "deploy"], True)
      , (["app", "check"], True)
      , (["app", "delete"], True)
      , (["app", "image-plan"], True)
      , (["app", "logs"], False)
      , (["app", "restart"], False)
      , (["deployments", "list"], False)
      , (["storage", "list"], False)
      , (["broker", "create"], False)
      , (["db", "create"], False)
      , (["task", "run"], True)
      , (["task", "delete"], True)
      , (["task", "list"], False)
      , (["worker", "deploy"], True)
      , (["worker", "delete"], False)
      , (["access", "grant"], False)
      , (["server", "status"], False)
      , (["doctor"], False)
      , (["context", "use", "x"], False)
      , (["init"], False)
      , (["infra", "up"], False)
      , (["domains", "list"], False)
      , (["cdn", "plan"], False)
      , (["tunnel", "status"], False)
      , (["cleanup"], False)
      , (["nix-cache", "token"], False)
      , (["delegation", "show", "kotei"], True)
      , (["delegation", "create", "kotei"], False)
      , (["delegation", "revoke", "kotei"], False)
      , (["--context", "ci", "env", "set"], False)
      , (["--context", "ci", "app", "deploy"], True)
      ]

-- ---------------------------------------------------------------------------
-- D6: the actor and source on the wire.

actorTests :: [TestTree]
actorTests =
  [ testCase "a deployer actor needs a name; an operator's is optional" $ do
      (eitherDecode "{\"kind\":\"deployer\",\"name\":null}" :: Either String Actor) @?= Left "Error in $: a deployer actor requires a name"
      (eitherDecode "{\"kind\":\"operator\",\"name\":null}" :: Either String Actor) @?= Right (OperatorActor Nothing)
      (eitherDecode "{\"kind\":\"operator\"}" :: Either String Actor) @?= Right (OperatorActor Nothing)
      (eitherDecode "{\"kind\":\"operator\",\"name\":\"alice\"}" :: Either String Actor) @?= Right (OperatorActor (Just "alice"))
      (eitherDecode "{\"kind\":\"deployer\",\"name\":\"kotei\"}" :: Either String Actor) @?= Right (DeployerActor "kotei")
      assertBool "unknown kind" (isLeft (eitherDecode "{\"kind\":\"robot\",\"name\":\"x\"}" :: Either String Actor))
  , testCase "a source records only what it names" $ do
      encode (ReviewSource (Just "r") Nothing (Just "u")) @?= "{\"repository\":\"r\",\"run\":\"u\"}"
      assertBool "an empty source is not recorded" (isLeft (eitherDecode "{}" :: Either String ReviewSource))
  , testCase "a context names a deployer or an operator, never both" $ do
      actorFromNames (Just "kotei") Nothing @?= Right (DeployerActor "kotei")
      actorFromNames Nothing (Just "alice") @?= Right (OperatorActor (Just "alice"))
      actorFromNames Nothing Nothing @?= Right anonymousOperator
      assertBool "both" (isLeft (actorFromNames (Just "kotei") (Just "alice")))
      assertBool "not a label" (isLeft (actorFromNames (Just "Kotei!") Nothing))
  ]

-- ---------------------------------------------------------------------------
-- Fixtures.

generationOne :: ScopeGeneration
generationOne = ok (mkScopeGeneration 1)

binding' :: ContextBinding
binding' = ContextBinding (ok (mkContextId "delegation-test")) (ok (mkName "project"))

foundationOwner, clusterOwner, authOwnerScope :: ScopeId
foundationOwner = ok (mkScopeId Platform "foundation")
clusterOwner = ok (mkScopeId Platform "cluster")
authOwnerScope = ok (mkScopeId Platform "auth")

fixtureCluster, systemNamespace :: ResourceId
fixtureCluster = mintResourceId clusterOwner (ok (mkLogicalKey "cluster")) (known "cluster")
systemNamespace = mintResourceId foundationOwner (ok (mkLogicalKey "foundation")) (known "namespace-nagare-system")

-- The accepted fixtureCluster and @nagare-system@ a teamDelegation binds against.
foundationScope :: ScopeDeclaration
foundationScope =
  ok
    ( mkScopeDeclaration
        foundationOwner
        [ ResourceBundle
            [ External fixtureCluster (Artifact (known "local-cluster") (contentDigest "cluster")) [] fixtureSource
            , External systemNamespace (ok (kubernetesAddress fixtureCluster "v1" "Namespace" Nothing "nagare-system")) [] fixtureSource
            ]
            []
            []
            []
            []
            []
        ]
    )

imageScope :: Text -> ScopeDeclaration
imageScope destination =
  let owner = ok (mkScopeId Publication "app-image-web")
      resource =
        ManagedResource
          { identity = mintResourceId owner (ok (mkLogicalKey "web")) (known "oci-image")
          , owner = owner
          , executor = ArtifactExecutor
          , address = Artifact (known "web") (contentDigest "manifest")
          , aliases = []
          , spec = ArtifactPublication (known "oci-image") destination (contentDigest "archive") True
          , lifecycle = Retain
          , dataPolicy = Stateless
          , sensitivity = Private
          , dependencies = []
          , delegations = []
          , source = fixtureSource
          }
   in stampDeployerScope "kotei" (ok (mkScopeDeclaration owner [ResourceBundle [Managed resource] [] [] [] [] []]))

kubernetesMember :: ScopeId -> Text -> Text -> Maybe Text -> Text -> ManagedResource
kubernetesMember owner apiVersion kind ns objectName = kubernetesMemberWith owner apiVersion kind ns objectName (object [])

kubernetesMemberWith :: ScopeId -> Text -> Text -> Maybe Text -> Text -> Value -> ManagedResource
kubernetesMemberWith owner apiVersion kind ns objectName extra =
  let value = case object ["apiVersion" .= apiVersion, "kind" .= kind, "metadata" .= object (["name" .= objectName] <> ["namespace" .= n | Just n <- [ns]])] of
        Object base | Object more <- extra -> Object (base <> more)
        other -> other
      resourceId = mintResourceId owner (ok (mkLogicalKey "member")) (known (T.toLower kind <> "-" <> objectName))
   in fst
        ( ok
            ( bindKubernetesObject
                KubernetesInput
                  { resourceId = resourceId
                  , ownerScope = owner
                  , clusterId = fixtureCluster
                  , inputObject = value
                  , objectDigest = contentDigest (ok (canonicalValue value))
                  , lifecyclePolicy = Retain
                  , inputDataPolicy = Stateless
                  , inputSensitivity = Private
                  , sourceLocation = fixtureSource
                  }
            )
        )

addMember :: ScopeDeclaration -> ManagedResource -> ScopeDeclaration
addMember scope resource = rebuild scope (scopeBundles scope <> [ResourceBundle [Managed (resource & #owner .~ scopeId scope)] [] [] [] [] []])

addContribution :: ScopeDeclaration -> Contribution -> ScopeDeclaration
addContribution scope contribution = rebuild scope (scopeBundles scope <> [ResourceBundle [] [] [] [contribution] [] []])

mapMembers :: (ManagedResource -> ManagedResource) -> ScopeDeclaration -> ScopeDeclaration
mapMembers f scope = rebuild scope [bundle & #declarations %~ map (\case Managed r -> Managed (f r); other -> other) | bundle <- scopeBundles scope]

rebuild :: ScopeDeclaration -> [ResourceBundle] -> ScopeDeclaration
rebuild scope bundles = withScopeOverrides (scopeOverrides scope) (ok (mkScopeDeclaration (scopeId scope) bundles))

fixtureSource :: SourceLocation
fixtureSource = SourceLocation "fixture" "delegation"

known :: Text -> Name
known = ok . mkName

expectRight :: (Show e) => Either e a -> IO a
expectRight = either (assertFailure . show) pure

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
