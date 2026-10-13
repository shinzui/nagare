module InventoryAccessSpec (inventoryAccessTests) where

import Control.Monad (forM_, void)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Access.Grants (accessTuple, teamAccessTuple, teamMemberTuple)
import Nagare.Access.ShomeiUser (ShomeiUser (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Access
import Nagare.Inventory.AccessRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, compileContributedShomeiSettings)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Execute (TransactionResult (..), applyReviewed, resumeTransaction)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), mkOperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Lifecycle (decideRetirement)
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (DriftFinding (..), classifyDrift)
import Nagare.Inventory.Store
import Nagare.Resource.Access (mkTeamKey, teamKeyText)
import Nagare.Resource.Inventory
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAccessTests :: TestTree
inventoryAccessTests =
  testGroup
    "reviewed access"
    [ testCase "compiler selects one tuple without altering accepted auth and neighboring apps" $ do
        let scope = ok (compileAccessScope snapshot "ONE.EXAMPLE.TEST." alice True)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
            originals = Map.map snd (snapshotScopes snapshot)
        Map.restrictKeys (inventoryScopes (candidateInventory candidate)) (Map.keysSet originals) @?= originals
        void (either (fail . show) pure (decodeScope (encodeCanonicalScope scope)))
        let resource = accessResource (accessBinding True)
            reserved =
              ok
                ( mkScopeSnapshot
                    (snapshotBinding snapshot)
                    (snapshotScopes snapshot)
                    ( Map.singleton
                        (canonicalClaim (resource ^. #address))
                        (ClaimHolder (resource ^. #owner) (resource ^. #identity) physical ResourceInventory.RetainedIncarnation)
                    )
                )
            input = CandidateInput reserved (ReplaceScope scope :| [])
        let encoded = ok (canonicalValue (candidateInputValue input))
        decoded <- either (fail . show) pure (decodeCandidateInput encoded)
        ok (canonicalValue (candidateInputValue decoded)) @?= encoded
        case decoded of
          CandidateInput decodedSnapshot _ ->
            snapshotReservations decodedSnapshot @?= snapshotReservations reserved
        assertBool
          "unknown protected hostname accepted"
          ( either
              (const True)
              (const False)
              (compileAccessScope snapshot "foreign.example.test" alice True)
          )
        assertBool
          "a subject that is not a Shomei user id accepted"
          ( either
              (const True)
              (const False)
              (compileAccessScope snapshot "one.example.test" (ShomeiUser "alice" Nothing) True)
          )
    , testCase "a grant accepted through a local en forward is revoked through the context's en (F97)" $ do
        let granted = ok (compileAccessScope snapshot "one.example.test" alice True)
            throughForward = \case
              Managed resource -> Managed (resource & #spec .~ AccessGrantSpec "http://127.0.0.1:28382" True)
              declaration -> declaration
            accepted = ok (mkScopeDeclaration (scopeId granted) [bundle & #declarations %~ map throughForward | bundle <- scopeBundles granted])
            withGrant = ok (mkScopeSnapshot context (Map.insert (scopeId accepted) (generation, accepted) (snapshotScopes snapshot)) Map.empty)
            revoked = ok (compileAccessScope withGrant "one.example.test" alice False)
        scopeId revoked @?= scopeId accepted
        [r ^. #spec | bundle <- scopeBundles revoked, Managed r <- bundle ^. #declarations]
          @?= [AccessGrantSpec "http://en.nagare-system.svc.cluster.local" False]
        -- The old record still binds, so status and review can observe it.
        Map.size (ok (accessBindings (inventoryDeclarations (ok (composeSnapshot withGrant))))) @?= 1
    , testCase "the en forward port is read from kubectl's first forwarding line" $ do
        parseEnForwardPort "Forwarding from 127.0.0.1:53817 -> 8080\n" @?= Just "53817"
        parseEnForwardPort "Forwarding from [::1]:53817 -> 8080" @?= Nothing
        parseEnForwardPort "Forwarding from 127.0.0.1: -> 8080" @?= Nothing
        parseEnForwardPort "Forwarding from 127.0.0.1:53817" @?= Nothing
    , testCase "portal synchronization rolls exactly both accepted startup readers" $ do
        let owner = ok (mkScopeId Platform "auth")
            scope = maybe (error "auth fixture absent") snd (Map.lookup owner (snapshotScopes snapshot))
            readers = [fixtureShomei, fixtureEnforcer]
            (revised, rollout) = ok (compilePortalSyncScope scope readers "bounded-sync")
        scopeId revised @?= owner
        Map.keysSet rollout @?= Set.fromList [resource ^. #identity | (resource, _) <- readers]
        forM_ readers $ \(original, _) -> do
          let (changed, _) = rollout Map.! (original ^. #identity)
          (changed & #spec .~ (original ^. #spec) & #dependencies .~ (original ^. #dependencies)) @?= original
          assertBool "backend-map dependency missing" (OrderedAfter (backendMapResourceId owner) `elem` (changed ^. #dependencies))
          assertBool "Shomei-settings dependency missing" (OrderedAfter (shomeiSettingsResourceId owner) `elem` (changed ^. #dependencies))
        forM_
          [ [fixtureShomei]
          , [fixtureShomei, fixtureShomei]
          , [fixtureShomei, (fst fixtureEnforcer, "changed-image")]
          , [fixtureShomei, (fst fixtureEnforcer & #owner .~ ok (mkScopeId Application "foreign"), snd fixtureEnforcer)]
          ]
          $ \invalid ->
            assertBool
              "foreign, missing, duplicate or changed reader accepted"
              (either (const True) (const False) (compilePortalSyncScope scope invalid "bounded-sync"))
    , testCase "atomic wire uses exact direct-subject filter and fully consistent observation" $ do
        let binding = accessBinding True
            before = AccessFact physical False
        accessQuery binding
          @?= object
            ["consistency" .= object ["mode" .= ("fullyConsistent" :: Text)], "filter" .= exactFilter]
        accessMutation binding before
          @?= object
            [ "tuples" .= [accessTuple "one.example.test" aliceId]
            , "deletes" .= ([] :: [Value])
            , "preconditions" .= [object ["kind" .= ("mustNotExist" :: Text), "filter" .= exactFilter]]
            ]
    , testCase "tuple query refuses caveats, usersets and incomplete pages" $ do
        let binding = accessBinding True
            page nodes more =
              ok
                ( canonicalValue
                    ( object
                        [ "edges" .= [object ["node" .= n] | n <- nodes]
                        , "pageInfo" .= object ["hasNextPage" .= more]
                        ]
                    )
                )
            tuple = toJSON (accessTuple "one.example.test" aliceId)
        parseAccessPage binding (page [tuple] False) @?= Right True
        parseAccessPage binding (page ([] :: [Value]) False) @?= Right False
        forM_ [page [tuple] True, page [tuple, tuple] False, page [object []] False] $ \bytes ->
          assertBool "foreign/incomplete query accepted" (either (const True) (const False) (parseAccessPage binding bytes))
    , testCase "old tuple API without atomic preconditions refuses" $ do
        parseAccessCapabilities "{}" @?= Left "access API lacks reviewed atomic tuple preconditions"
        parseAccessCapabilities
          ( ok
              ( canonicalValue
                  ( object
                      [ "components"
                          .= object
                            [ "schemas"
                                .= object
                                  ["WriteTuplesRequestWire" .= object ["properties" .= object ["preconditions" .= object [], "deletes" .= object []]]]
                            ]
                      ]
                  )
              )
          )
          @?= Right ()
    , testCase "lost grant response recovers observed completion; foreign owner or missing effect refuses" $ do
        state <- newIORef (AccessFact physical False)
        effects <- newIORef (0 :: Int)
        let binding = accessBinding True
            adapter =
              mkAccessAdapter
                Map.empty
                (Map.singleton (accessResource binding ^. #identity) binding)
                AccessOps
                  { accessInspect = \_ -> Right <$> readIORef state
                  , accessWrite = \_ before -> do
                      modifyIORef' effects (+ 1)
                      writeIORef state (before {accessPresent = True})
                      pure (AdapterEffectAmbiguous "lost response")
                  }
            op = operation binding CreateResource
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        preparedPublicSummary prepared @?= "grant " <> aliceId <> " (alice@example.test) viewer on one.example.test"
        adapterExecute adapter op prepared >>= (@?= AdapterEffectAmbiguous "lost response")
        adapterRecover adapter op prepared >>= \case RecoveryProvedComplete _ -> pure (); other -> assertFailure (show other)
        readIORef effects >>= (@?= 1)
        writeIORef state (AccessFact (ok (mkPhysicalIdentity "foreign-owner")) True)
        adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
        writeIORef state (AccessFact physical False)
        adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
    , testCase "revoke and stale tuple refuse without touching a different grant" $ do
        state <- newIORef (AccessFact physical True)
        effects <- newIORef (0 :: Int)
        let binding = accessBinding False
            accepted = accessResource (accessBinding True)
            adapter =
              mkAccessAdapter
                (Map.singleton (accepted ^. #identity) accepted)
                (Map.singleton (accessResource binding ^. #identity) binding)
                AccessOps
                  { accessInspect = \_ -> Right <$> readIORef state
                  , accessWrite = \_ before ->
                      modifyIORef' effects (+ 1)
                        >> writeIORef state (before {accessPresent = False})
                        >> pure AdapterEffectCompleted
                  }
            op = operation binding UpdateResource
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        adapterExecute adapter op prepared >>= (@?= AdapterEffectCompleted)
        adapterRecover adapter op prepared >>= \case RecoveryProvedComplete _ -> pure (); other -> assertFailure (show other)
        adapterPreflight adapter op prepared >>= \result -> assertBool "stale tuple passed preflight" (either (const True) (const False) result)
        readIORef effects >>= (@?= 1)
    , testCase "a revoked access grant is retained when its scope retires; a live one refuses (c3i teardown)" $
        forM_ [False, True] $ \granted -> do
          store <- newMemoryStore
          _ <- initializeStore store context "access-retire" >>= either (fail . show) pure
          let accessScope = ok (compileAccessScope snapshot "one.example.test" alice granted)
              withAccess = ok (mkScopeSnapshot context (Map.insert (scopeId accessScope) (generation, accessScope) (snapshotScopes snapshot)) Map.empty)
              dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
          _ <- seedInventoryHistory store (ok (composeInventory withAccess (ReplaceScope dummy :| []))) >>= either (fail . show) pure
          history <- loadInventoryHistory store >>= either (fail . show) pure
          let accepted = ok (mkScopeSnapshot context (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
              retirement = ok (composeInventory accepted (RetireScope (scopeId accessScope) RetainResources :| []))
          planning <- loadInventoryPlanningHistory store retirement >>= either (fail . show) pure
          -- As the command builds it: the desired tuples, plus the accepted
          -- ones a retirement removes.
          let acceptedDeclarations = ok (composedDeclarations (Map.map snd (historyAccepted planning)))
              members = Map.fromList [(r ^. #identity, r) | Managed r <- acceptedDeclarations, r ^. #executor == AccessExecutor]
              desired = either (const Map.empty) id (accessBindings (inventoryDeclarations (candidateInventory retirement)))
              adapter =
                mkAccessAdapter
                  members
                  (Map.union desired (acceptedAccessBindings acceptedDeclarations))
                  AccessOps
                    { accessInspect = \_ -> pure (Right (AccessFact physical granted))
                    , accessWrite = \_ _ -> assertFailure "a retirement wrote an access tuple" >> pure AdapterEffectCompleted
                    }
              registry = ok (mkAdapterRegistry [adapter])
          observed <- observeWithRegistry registry (requirementsByExecutor (observationRequirements retirement planning)) >>= either (fail . show) pure
          case decideRetirement retirement planning observed >>= \decisions -> planChanges retirement decisions planning observed of
            Right proposal | not granted -> do
              before <- readStoreSnapshot store >>= either (fail . show) pure
              bundle <- prepareReview registry before proposal >>= either (fail . show) pure
              Map.keys (reviewRetentions (reviewBundleDocument bundle)) @?= Map.keys members
            Left errors | granted -> assertBool (show errors) (any ((== "access-grant-live") . planErrorCode) (NE.toList errors))
            Left errors -> assertFailure ("a revoked grant's retirement refused: " <> show errors)
            Right _ -> assertFailure "a live grant's retirement was planned"
    , testCase "a team membership and a team grant are exact typed relationships with their own scopes (EP-187)" $ do
        let engineering = ok (mkTeamKey "engineering")
            member = ok (compileTeamMemberScope snapshot engineering alice True)
            withMember = ok (mkScopeSnapshot context (Map.insert (scopeId member) (generation, member) (snapshotScopes snapshot)) Map.empty)
            team = ok (compileTeamAccessScope withMember "ONE.EXAMPLE.TEST." engineering True)
            memberResource = head [r | bundle <- scopeBundles member, Managed r <- bundle ^. #declarations]
            teamResource = head [r | bundle <- scopeBundles team, Managed r <- bundle ^. #declarations]
        assertBool "team scope collides with the member scope" (scopeId member /= scopeId team)
        assertBool "team scope collides with the direct grant" (scopeId team /= scopeId (ok (compileAccessScope snapshot "one.example.test" alice True)))
        memberResource ^. #address @?= TeamMemberTuple (ok (mkResourceId "platform:auth/en/service")) engineering aliceId
        teamResource ^. #address @?= TeamAccessTuple (ok (mkResourceId "platform:auth/en/service")) (ok (mkName "one.example.test")) engineering
        -- Serialized reviews round-trip the new claims exactly.
        forM_ [member, team] $ \scope -> either (fail . show) (@?= scope) (decodeScope (encodeCanonicalScope scope))
        -- A membership depends on the en Service alone; a team grant also on the exact route.
        let bound = ok (accessBindings (inventoryDeclarations (candidateInventory (ok (composeInventory withMember (ReplaceScope team :| []))))))
            memberBinding = bound Map.! (memberResource ^. #identity)
            teamBinding = bound Map.! (teamResource ^. #identity)
        accessRoute memberBinding @?= Nothing
        fmap (^. #identity) (accessRoute teamBinding) @?= Just (mintResourceId (ok (mkScopeId Application "one")) (ok (mkLogicalKey "web")) (ok (mkName "route")))
        -- A team grant needs accepted membership history for that team.
        assertBool
          "team grant planned for a team nobody reviewed"
          (either (const True) (const False) (compileTeamAccessScope snapshot "one.example.test" engineering True))
        assertBool "team grant accepted a public host" (either (const True) (const False) (compileTeamAccessScope withMember "foreign.example.test" engineering True))
        assertBool "malformed team key accepted" (either (const True) (const False) (mkTeamKey "Engineering"))
        assertBool "subject that is not a Shomei id accepted" (either (const True) (const False) (compileTeamMemberScope snapshot engineering (ShomeiUser "alice" Nothing) True))
    , testCase "team wire pins the exact subject kind and relation, so a user and a userset never collide (EP-187)" $ do
        let engineering = ok (mkTeamKey "engineering")
            member = ok (compileTeamMemberScope snapshot engineering alice True)
            withMember = ok (mkScopeSnapshot context (Map.insert (scopeId member) (generation, member) (snapshotScopes snapshot)) Map.empty)
            team = ok (compileTeamAccessScope withMember "one.example.test" engineering True)
            bound = ok (accessBindings (inventoryDeclarations (candidateInventory (ok (composeInventory withMember (ReplaceScope team :| []))))))
            bindingOf scope = case [binding | Managed r <- concatMap (^. #declarations) (scopeBundles scope), Just binding <- [Map.lookup (r ^. #identity) bound]] of
              [binding] -> binding
              other -> error ("scope has no unique access binding: " <> show (length other))
            memberBinding = bindingOf member
            teamBinding = bindingOf team
            memberFilter =
              object
                [ "objectType" .= ("group" :: Text)
                , "objectId" .= ("engineering" :: Text)
                , "relation" .= ("member" :: Text)
                , "subjectType" .= ("user" :: Text)
                , "subjectId" .= aliceId
                , "subjectRelation" .= object ["match" .= ("none" :: Text)]
                ]
            teamFilter =
              object
                [ "objectType" .= ("app" :: Text)
                , "objectId" .= ("one.example.test" :: Text)
                , "relation" .= ("viewer" :: Text)
                , "subjectType" .= ("group" :: Text)
                , "subjectId" .= ("engineering" :: Text)
                , "subjectRelation" .= object ["match" .= ("exact" :: Text), "relation" .= ("member" :: Text)]
                ]
        accessQuery memberBinding @?= object ["consistency" .= object ["mode" .= ("fullyConsistent" :: Text)], "filter" .= memberFilter]
        accessMutation teamBinding (AccessFact physical False)
          @?= object
            [ "tuples" .= [teamAccessTuple "one.example.test" "engineering"]
            , "deletes" .= ([] :: [Value])
            , "preconditions" .= [object ["kind" .= ("mustNotExist" :: Text), "filter" .= teamFilter]]
            ]
        toJSON (teamAccessTuple "one.example.test" "engineering")
          @?= object
            [ "object" .= object ["objectType" .= ("app" :: Text), "objectId" .= ("one.example.test" :: Text)]
            , "relation" .= ("viewer" :: Text)
            , "subject" .= object ["kind" .= ("set" :: Text), "objectType" .= ("group" :: Text), "objectId" .= ("engineering" :: Text), "relation" .= ("member" :: Text)]
            , "caveat" .= Null
            ]
        let page nodes = ok (canonicalValue (object ["edges" .= [object ["node" .= n] | n <- nodes], "pageInfo" .= object ["hasNextPage" .= False]]))
        parseAccessPage teamBinding (page [toJSON (teamAccessTuple "one.example.test" "engineering")]) @?= Right True
        parseAccessPage memberBinding (page [toJSON (teamMemberTuple "engineering" aliceId)]) @?= Right True
        assertBool "a direct user tuple satisfied the team grant" (either (const True) (const False) (parseAccessPage teamBinding (page [toJSON (accessTuple "one.example.test" aliceId)])))
        assertBool "a team tuple satisfied the direct grant" (either (const True) (const False) (parseAccessPage (accessBinding True) (page [toJSON (teamAccessTuple "one.example.test" "engineering")])))
        -- Review summaries name the relationship, never a key.
        adapter <- pure (mkAccessAdapter Map.empty (Map.fromList [(accessResource b ^. #identity, b) | b <- [memberBinding, teamBinding]]) AccessOps {accessInspect = \_ -> pure (Right (AccessFact physical False)), accessWrite = \_ _ -> pure AdapterEffectCompleted})
        forM_ [(memberBinding, "add " <> aliceId <> " (alice@example.test) to team engineering"), (teamBinding, "grant team engineering viewer on one.example.test")] $ \(binding, expected) -> do
          prepared <- adapterPrepare adapter (operation binding CreateResource) >>= either (fail . show) pure
          preparedPublicSummary prepared @?= expected
    , testCase "every relationship form recovers a lost write from the exact tuple and refuses a foreign or missing effect (EP-187)" $
        forM_ teamBindings $ \(label, binding) -> do
          state <- newIORef (AccessFact physical False)
          effects <- newIORef (0 :: Int)
          let adapter =
                mkAccessAdapter
                  Map.empty
                  (Map.singleton (accessResource binding ^. #identity) binding)
                  AccessOps
                    { accessInspect = \_ -> Right <$> readIORef state
                    , accessWrite = \_ before -> do
                        modifyIORef' effects (+ 1)
                        writeIORef state (before {accessPresent = True})
                        pure (AdapterEffectAmbiguous "lost response")
                    }
              op = operation binding CreateResource
          prepared <- adapterPrepare adapter op >>= either (fail . (label <>) . show) pure
          adapterExecute adapter op prepared >>= (@?= AdapterEffectAmbiguous "lost response")
          adapterRecover adapter op prepared >>= \case RecoveryProvedComplete _ -> pure (); other -> assertFailure (label <> show other)
          readIORef effects >>= (@?= 1)
          writeIORef state (AccessFact (ok (mkPhysicalIdentity "foreign-owner")) True)
          adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (label <> show other)
          writeIORef state (AccessFact physical False)
          adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (label <> show other)
          -- Planning is deterministic: the same inputs compile the same review.
          prepared' <- adapterPrepare adapter op >>= either (fail . show) pure
          preparedPublicSummary prepared' @?= preparedPublicSummary prepared
    , testCase "a live team relationship cannot be retired; a removed one is retained as history (EP-187)" $
        forM_ [("member", memberScopeFor), ("team", teamScopeFor)] $ \(label, scopeFor) ->
          forM_ [False, True] $ \present -> do
            store <- newMemoryStore
            _ <- initializeStore store context ("team-retire-" <> label) >>= either (fail . show) pure
            let (base, target) = scopeFor present
                withTeam = ok (mkScopeSnapshot context (Map.insert (scopeId target) (generation, target) (snapshotScopes base)) Map.empty)
                dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
            _ <- seedInventoryHistory store (ok (composeInventory withTeam (ReplaceScope dummy :| []))) >>= either (fail . show) pure
            history <- loadInventoryHistory store >>= either (fail . show) pure
            let accepted = ok (mkScopeSnapshot context (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
                retirement = ok (composeInventory accepted (RetireScope (scopeId target) RetainResources :| []))
            planning <- loadInventoryPlanningHistory store retirement >>= either (fail . show) pure
            let acceptedDeclarations = ok (composedDeclarations (Map.map snd (historyAccepted planning)))
                members = Map.fromList [(r ^. #identity, r) | Managed r <- acceptedDeclarations, r ^. #executor == AccessExecutor]
                desired = either (const Map.empty) id (accessBindings (inventoryDeclarations (candidateInventory retirement)))
                adapter =
                  mkAccessAdapter
                    members
                    (Map.union desired (acceptedAccessBindings acceptedDeclarations))
                    AccessOps
                      { accessInspect = \_ -> pure (Right (AccessFact physical present))
                      , accessWrite = \_ _ -> assertFailure "a retirement wrote a relationship" >> pure AdapterEffectCompleted
                      }
                registry = ok (mkAdapterRegistry [adapter])
            observed <- observeWithRegistry registry (requirementsByExecutor (observationRequirements retirement planning)) >>= either (fail . show) pure
            case decideRetirement retirement planning observed >>= \decisions -> planChanges retirement decisions planning observed of
              Right _ | not present -> pure ()
              Left errors | present -> assertBool (T.unpack label <> ": " <> show errors) (any ((== "access-grant-live") . planErrorCode) (NE.toList errors))
              Left errors -> assertFailure (T.unpack label <> ": a removed relationship's retirement refused: " <> show errors)
              Right _ -> assertFailure (T.unpack label <> ": a live relationship's retirement was planned")
    , testCase "the team schema the CLI requires is the reviewed bootstrap schema (EP-187)" $ do
        documents <- Yaml.decodeAllFileEither "../../cluster/bootstrap/en/configmap.yaml" >>= either (fail . show) pure
        source <- case [ text
                       | Object root <- documents
                       , Just (Object payload) <- [KM.lookup "data" root]
                       , Just (String text) <- [KM.lookup "app.en" payload]
                       ] of
          [text] -> pure text
          other -> assertFailure ("bootstrap en schema has no unique app.en: " <> show other) >> fail "schema"
        assertBool "bootstrap schema does not declare team membership" (activeSchemaSupportsTeams source)
        assertBool "the old user-only schema passed as supporting teams" (not (activeSchemaSupportsTeams "object user {}\nobject app {\n  relation viewer: user\n  permission access = viewer\n}\n"))
        assertBool "a schema with the names but another permission passed" (not (activeSchemaSupportsTeams "object group { relation member: user }\nobject app { relation viewer: user, group#member\n permission access = viewer + owner }"))
        teamKeyText (ok (mkTeamKey "platform-ops_2")) @?= "platform-ops_2"
    , testCase "planning names why each access observation was unavailable (IR-27)" $
        forM_ [missingKey, "en port-forward failed", "access relationship query refused"] $ \reason -> do
          store <- newMemoryStore
          (_, planned) <- planGrant store AccessOps {accessInspect = \_ -> pure (Left reason), accessWrite = \_ _ -> pure AdapterEffectCompleted}
          case planned of
            Right _ -> assertFailure "an unavailable access observation was planned"
            Left errors -> do
              let rendered = renderPlanErrors errors
              assertBool
                (T.unpack rendered)
                (("observation-unavailable: required resource observation is unavailable: " <> reason <> " (" <> resourceIdText grantId <> ")") `elem` T.lines rendered)
    , testCase "status reports an access observation's reason; other providers stay redacted (IR-27)" $ do
        let findingsFor resource observation =
              [finding | finding <- classifyDrift grantedInventory (ok (observationSet [(resource, observation)])), findingResource finding == resource]
            routeId = head [r ^. #identity | Managed r <- inventoryDeclarations grantedInventory, r ^. #executor == KubernetesExecutor, r ^. #owner == ok (mkScopeId Application "one")]
        map findingReason (findingsFor grantId (ObservationUnavailable missingKey)) @?= [Just missingKey]
        [KM.lookup "reason" fields | finding <- findingsFor grantId (ObservationUnavailable missingKey), Object fields <- [toJSON finding]]
          @?= [Just (String missingKey)]
        map findingReason (findingsFor routeId (ObservationUnavailable "private provider stderr"))
          @?= [Just "provider observation is unavailable"]
    , testCase "an access review refuses before admission without the key; a refused preflight resumes once it is set (IR-27)" $
        withSystemTempDirectory "access-key" $ \root -> do
          let sentinel = "sentinel-en-key-5f1c9a" :: Text
              refusal = Just "reviewed access requires private NAGARE_EN_API_KEY; export it in this shell and rerun this command (the saved review stays valid)"
          key <- newIORef (Just (T.unpack sentinel))
          state <- newIORef (AccessFact physical False)
          let ops =
                AccessOps
                  { accessInspect = \_ ->
                      readIORef key >>= \case
                        Just present | not (null present) -> Right <$> readIORef state
                        _ -> pure (Left missingKey)
                  , accessWrite = \_ before -> writeIORef state (before {accessPresent = True}) >> pure AdapterEffectCompleted
                  }
          store <- openFilesystemStore (root </> "inventory") >>= either (fail . show) pure
          (registry, planned) <- planGrant store ops
          proposal <- either (fail . show) pure planned
          before <- readStoreSnapshot store >>= either (fail . show) pure
          bundle <- prepareReview registry before proposal >>= either (fail . show) pure
          accessKeyRefusal Nothing bundle @?= refusal
          accessKeyRefusal (Just "") bundle @?= refusal
          accessKeyRefusal (Just (T.unpack sentinel)) bundle @?= Nothing
          _ <- publishReview store bundle >>= either (fail . show) pure
          _ <- writeReviewBundle (root </> "review") bundle >>= either (fail . T.unpack) pure
          published <- readStoreSnapshot store >>= either (fail . show) pure
          reviewed <- either (fail . show) pure (verifyReview published bundle)
          -- The key went missing after review: the adapter preflight still refuses.
          writeIORef key Nothing
          transaction <-
            applyReviewed store registry reviewed >>= either (fail . show) pure >>= \case
              StoppedFailed token _ (KnownNoEffect reason) -> do
                assertBool (T.unpack reason) (missingKey `T.isInfixOf` reason)
                pure token
              other -> assertFailure ("a missing key did not stop the access operation: " <> show other) >> fail "expected a refused preflight"
          writeIORef key (Just (T.unpack sentinel))
          resumeTransaction store registry transaction >>= either (fail . show) pure >>= (@?= Converged transaction)
          readIORef state >>= (@?= AccessFact physical True)
          -- A review without access operations never needs the key.
          withoutAccess <- do
            history <- loadInventoryHistory store >>= either (fail . show) pure
            let accepted = ok (mkScopeSnapshot context (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
                candidate = ok (composeInventory accepted (ReplaceScope (ok (mkScopeDeclaration (ok (mkScopeId Standalone "other")) [])) :| []))
            planning <- loadInventoryPlanningHistory store candidate >>= either (fail . show) pure
            observed <- observeWithRegistry registry (requirementsByExecutor (observationRequirements candidate planning)) >>= either (fail . show) pure
            empty <- either (fail . show) pure (planChanges candidate noLifecycleDecisions planning observed)
            current <- readStoreSnapshot store >>= either (fail . show) pure
            prepareReview registry current empty >>= either (fail . show) pure
          forM_ [Nothing, Just "", Just (T.unpack sentinel)] $ \value -> accessKeyRefusal value withoutAccess @?= Nothing
          -- The key has no channel into a review, the store, the journal,
          -- a rendered plan error or a status finding.
          writeIORef key Nothing
          unavailable <- newMemoryStore >>= \fresh -> snd <$> planGrant fresh ops
          let finding = classifyDrift grantedInventory (ok (observationSet [(grantId, ObservationUnavailable missingKey)]))
              outputs = [either (TE.encodeUtf8 . renderPlanErrors) (const "") unavailable, BS.toStrict (encode finding)]
          files <- filesUnder root
          assertBool "no store or review file was written" (not (null files))
          written <- traverse BS.readFile files
          forM_ (outputs <> written) $ \bytes ->
            assertBool "the private key reached a record or output" (not (TE.encodeUtf8 sentinel `BS.isInfixOf` bytes))
    , testCase "seed complete public command fixture from typed declarations" $
        lookupEnv "MP23_ACCESS_FIXTURE_ROOT"
          >>= maybe
            (withSystemTempDirectory "access-public-seed" writeFixture)
            writeFixture
    ]
  where
    physical = ok (mkPhysicalIdentity "access-owner://en-uid/one-route-uid")
    missingKey = "reviewed access requires private NAGARE_EN_API_KEY"
    grantId = accessResource (accessBinding True) ^. #identity
    grantScope = ok (compileAccessScope snapshot "one.example.test" alice True)
    grantedInventory = ok (composeSnapshot (ok (mkScopeSnapshot context (Map.insert (scopeId grantScope) (generation, grantScope) (snapshotScopes snapshot)) Map.empty)))
    -- Alice's grant on host one, planned against the accepted fixture and
    -- observed only through @ops@.
    planGrant store ops = do
      _ <- initializeStore store context "access-grant" >>= either (fail . show) pure
      let dummy = ok (mkScopeDeclaration (ok (mkScopeId Standalone "dummy")) [])
      _ <- seedInventoryHistory store (ok (composeInventory snapshot (ReplaceScope dummy :| []))) >>= either (fail . show) pure
      history <- loadInventoryHistory store >>= either (fail . show) pure
      let accepted = ok (mkScopeSnapshot context (Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)) (historyReservations history))
          candidate = ok (composeInventory accepted (ReplaceScope (ok (compileAccessScope accepted "one.example.test" alice True)) :| []))
      planning <- loadInventoryPlanningHistory store candidate >>= either (fail . show) pure
      let bindings = ok (accessBindings (inventoryDeclarations (candidateInventory candidate)))
          registry = ok (mkAdapterRegistry [mkAccessAdapter Map.empty bindings ops])
      observed <- observeWithRegistry registry (requirementsByExecutor (observationRequirements candidate planning)) >>= either (fail . show) pure
      pure (registry, planChanges candidate noLifecycleDecisions planning observed)
    exactFilter =
      object
        [ "objectType" .= ("app" :: Text)
        , "objectId" .= ("one.example.test" :: Text)
        , "relation" .= ("viewer" :: Text)
        , "subjectType" .= ("user" :: Text)
        , "subjectId" .= aliceId
        , "subjectRelation" .= object ["match" .= ("none" :: Text)]
        ]
    operation binding action =
      PlannedOperation
        (ok (mkOperationId "op-access"))
        action
        AccessExecutor
        (accessResource binding ^. #identity :| [])
        (contentDigest "review")
        []
        VerifyBeforeRetry

-- The two team forms, bound against the fixture: a membership for Alice and
-- engineering's grant on host one, each with its accepted prerequisites.
teamBindings :: [(String, AccessBinding)]
teamBindings =
  [ ("member: ", bindingOf memberSnapshot memberScope)
  , ("team: ", bindingOf memberSnapshot teamScope)
  ]
  where
    engineering = ok (mkTeamKey "engineering")
    memberScope = ok (compileTeamMemberScope snapshot engineering alice True)
    memberSnapshot = ok (mkScopeSnapshot context (Map.insert (scopeId memberScope) (generation, memberScope) (snapshotScopes snapshot)) Map.empty)
    teamScope = ok (compileTeamAccessScope memberSnapshot "one.example.test" engineering True)
    bindingOf base scope =
      let bound = ok (accessBindings (inventoryDeclarations (candidateInventory (ok (composeInventory base (ReplaceScope scope :| []))))))
       in case [binding | Managed r <- concatMap (^. #declarations) (scopeBundles scope), Just binding <- [Map.lookup (r ^. #identity) bound]] of
            [binding] -> binding
            other -> error ("scope has no unique access binding: " <> show (length other))

-- A membership, present or removed, over the fixture; and a team grant over
-- a fixture that already accepted the membership.
memberScopeFor, teamScopeFor :: Bool -> (ScopeSnapshot, ScopeDeclaration)
memberScopeFor present = (snapshot, ok (compileTeamMemberScope snapshot (ok (mkTeamKey "engineering")) alice present))
teamScopeFor present =
  let engineering = ok (mkTeamKey "engineering")
      member = ok (compileTeamMemberScope snapshot engineering alice True)
      base = ok (mkScopeSnapshot context (Map.insert (scopeId member) (generation, member) (snapshotScopes snapshot)) Map.empty)
   in (base, ok (compileTeamAccessScope base "one.example.test" engineering present))

-- The fixture subject as an email resolves it: the typed id and the address.
alice :: ShomeiUser
alice = ShomeiUser aliceId (Just "alice@example.test")

aliceId :: Text
aliceId = "user_01h455vb4pex5vsknk084sn02q"

accessBinding :: Bool -> AccessBinding
accessBinding granted =
  let scope = ok (compileAccessScope snapshot "one.example.test" alice granted)
      candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
   in head (Map.elems (ok (accessBindings (inventoryDeclarations (candidateInventory candidate)))))

snapshot :: ScopeSnapshot
snapshot = ok (mkScopeSnapshot context (Map.fromList [(scopeId scope, (generation, scope)) | scope <- fixtures]) Map.empty)

context :: ContextBinding
context = ContextBinding (ok (mkContextId "access-test")) (ok (mkName "project"))

generation :: ScopeGeneration
generation = ok (mkScopeGeneration 1)

fixtures :: [ScopeDeclaration]
fixtures = [clusterScope, authScope, bootstrapScope, app "one", app "two"]
  where
    cluster = ok (mkResourceId "platform:cluster/cluster/local")
    clusterOwner = ok (mkScopeId Platform "cluster")
    clusterScope =
      ok
        ( mkScopeDeclaration
            clusterOwner
            [ ResourceBundle
                [External cluster (Artifact (ok (mkName "local-cluster")) (contentDigest "cluster")) [] source]
                []
                []
                []
                []
                []
            ]
        )
    authOwner = ok (mkScopeId Platform "auth")
    authId = ok (mkResourceId "platform:auth/en/service")
    auth =
      ManagedResource
        authId
        authOwner
        KubernetesExecutor
        (ok (kubernetesAddress cluster "v1" "Service" (Just "nagare-system") "en"))
        []
        (NativeObject (contentDigest "en-service"))
        Protect
        Stateless
        Public
        [OrderedAfter cluster]
        []
        source
    authScope =
      ok
        ( mkScopeDeclaration
            authOwner
            [ ResourceBundle
                [Managed auth, Managed (fst fixtureShomei), Managed (fst fixtureEnforcer)]
                []
                []
                []
                []
                [BackendMapGrant cluster, ShomeiSettingsGrant cluster (ok (mkName "example.test"))]
            ]
        )
    -- An admitted bootstrap marker remains in ordinary application/access
    -- reviews. Its presence alone must not select a new bootstrap verification.
    bootstrapOwner = ok (mkScopeId Platform "bootstrap-stamp")
    bootstrapId = mintResourceId bootstrapOwner (ok (mkLogicalKey "bootstrap")) (ok (mkName "version"))
    bootstrapObject =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata" .= object ["name" .= ("nagare-platform-version" :: Text), "namespace" .= ("nagare-system" :: Text)]
        ]
    bootstrapResource =
      fst
        ( ok
            ( bindKubernetesObject
                KubernetesInput
                  { resourceId = bootstrapId
                  , ownerScope = bootstrapOwner
                  , clusterId = cluster
                  , inputObject = bootstrapObject
                  , objectDigest = contentDigest (ok (canonicalValue bootstrapObject))
                  , lifecyclePolicy = Retain
                  , inputDataPolicy = Stateless
                  , inputSensitivity = Public
                  , sourceLocation = SourceLocation "generated:bootstrap" "platform-version"
                  }
            )
        )
    bootstrapScope =
      ok
        ( mkScopeDeclaration
            bootstrapOwner
            [ResourceBundle [Managed (bootstrapResource {dependencies = [OrderedAfter authId]})] [] [] [] [] []]
        )
    app label =
      let owner = ok (mkScopeId Application label)
          host = ok (mkName (label <> ".example.test"))
          key = ok (mkLogicalKey "web")
          route =
            ManagedResource
              (mintResourceId owner key (ok (mkName "route")))
              owner
              KubernetesExecutor
              (ok (kubernetesAddress cluster "serving.knative.dev/v1beta1" "DomainMapping" (Just "nagare-system") (nameText host)))
              [Hostname host]
              (NativeObject (contentDigest ("route-" <> TE.encodeUtf8 label)))
              Retain
              Stateless
              Public
              [OrderedAfter cluster, OrderedAfter (backendMapResourceId authOwner)]
              []
              source
       in ok
            ( mkScopeDeclaration
                owner
                [ ResourceBundle
                    [Managed route]
                    []
                    []
                    ( [RegisterBackend authOwner cluster host ("http://" <> label <> ".svc") ProtectedBackend key]
                        <> [ RegisterBackend
                               authOwner
                               cluster
                               (ok (mkName "portal.example.test"))
                               "http://portal.svc"
                               PortalBackend
                               key
                           | label == "two"
                           ]
                    )
                    []
                    []
                ]
            )
    source = SourceLocation "fixture" "access"

fixtureShomei :: (ManagedResource, BS.ByteString)
fixtureShomei =
  ok
    ( bindKubernetesObject
        KubernetesInput
          { resourceId = ok (mkResourceId "platform:auth/shomei/deployment")
          , ownerScope = ok (mkScopeId Platform "auth")
          , clusterId = ok (mkResourceId "platform:cluster/cluster/local")
          , inputObject = value
          , objectDigest = contentDigest bytes
          , lifecyclePolicy = Protect
          , inputDataPolicy = Stateless
          , inputSensitivity = Public
          , sourceLocation = SourceLocation "fixture" "shomei"
          }
    )
  where
    bytes = ok (canonicalValue value)
    value =
      object
        [ "apiVersion" .= ("apps/v1" :: Text)
        , "kind" .= ("Deployment" :: Text)
        , "metadata" .= object ["name" .= ("shomei" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "spec"
            .= object
              [ "replicas" .= (1 :: Int)
              , "selector" .= object ["matchLabels" .= object ["app" .= ("shomei" :: Text)]]
              , "template" .= template
              ]
        ]
    template =
      object
        [ "metadata" .= object ["labels" .= object ["app" .= ("shomei" :: Text)]]
        , "spec" .= object ["containers" .= [container]]
        ]
    container =
      object
        [ "name" .= ("shomei" :: Text)
        , "image" .= ("fixture-only/shomei:bound" :: Text)
        , "env"
            .= [ setting "SHOMEI_WEBAUTHN_ORIGINS" "webauthn-origins"
               , setting "SHOMEI_PUBLIC_BASE_URL" "public-base-url"
               ]
        ]
    setting :: Text -> Text -> Value
    setting variable key =
      object
        [ "name" .= variable
        , "valueFrom"
            .= object
              [ "configMapKeyRef"
                  .= object
                    ["name" .= ("nagare-shomei-settings" :: Text), "key" .= key]
              ]
        ]

fixtureEnforcer :: (ManagedResource, BS.ByteString)
fixtureEnforcer =
  ok
    ( bindKubernetesObject
        KubernetesInput
          { resourceId = ok (mkResourceId "platform:auth/nagare-access/service")
          , ownerScope = ok (mkScopeId Platform "auth")
          , clusterId = ok (mkResourceId "platform:cluster/cluster/local")
          , inputObject = value
          , objectDigest = contentDigest bytes
          , lifecyclePolicy = Protect
          , inputDataPolicy = Stateless
          , inputSensitivity = Public
          , sourceLocation = SourceLocation "fixture" "nagare-access"
          }
    )
  where
    bytes = ok (canonicalValue value)
    value =
      object
        [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
        , "kind" .= ("Service" :: Text)
        , "metadata" .= object ["name" .= ("nagare-access" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "spec"
            .= object
              [ "template"
                  .= object
                    [ "metadata" .= object ["annotations" .= object []]
                    , "spec" .= object ["containers" .= [object ["image" .= ("fixture-enforcer:accepted" :: Text)]]]
                    ]
              ]
        ]

writeFixture :: FilePath -> IO ()
writeFixture root = do
  createDirectoryIfMissing True root
  store <- openFilesystemStore (root </> "state/nagare/access-test/inventory") >>= either (fail . show) pure
  initial <- initializeStore store context "access-fixture" >>= either (fail . show) pure
  let revision scope = ScopeRevision generation (contentDigest (encodeCanonicalScope scope))
      revisions = Map.fromList [(scopeId scope, revision scope) | scope <- fixtures]
  forM_ fixtures $ \scope ->
    void
      ( publishIfAbsent
          store
          (scopeKey (revisionDigest (revision scope)))
          (encodeCanonicalScope scope)
          >>= either (fail . show) pure
      )
  forM_ [fixtureShomei, fixtureEnforcer] $ \(_, bytes) ->
    void
      ( publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes
          >>= either (fail . show) pure
      )
  void
    ( replaceHeadIfGenerationMatches
        store
        (Just (headGeneration initial))
        initial
          { headGeneration = headGeneration initial + 1
          , headAccepted = revisions
          , headConverged = revisions
          }
        >>= either (fail . show) pure
    )
  let inventory = ok (composeSnapshot snapshot)
      objects =
        [ object
            [ "kind" .= kind
            , "name" .= name
            , "namespace" .= namespace
            , "resource" .= (resource ^. #identity)
            , "digest" .= digest
            ]
        | Managed resource <- inventoryDeclarations inventory
        , Kubernetes _ _ kind (Just namespace) name <- [resource ^. #address]
        , NativeObject digest <- [resource ^. #spec]
        ]
  BS.writeFile (root </> "owners.json") (ok (canonicalValue (toJSON objects)))
  let native =
        Map.union
          (ok (compileContributedBackendMaps (inventoryDeclarations inventory)))
          (ok (compileContributedShomeiSettings (inventoryDeclarations inventory)))
  BS.writeFile
    (root </> "maps.json")
    ( ok
        ( canonicalValue
            ( toJSON
                [ object ["resource" .= resourceId, "native" .= TE.decodeUtf8 bytes]
                | (resourceId, (_, bytes)) <-
                    Map.toAscList
                      ( Map.union
                          (Map.fromList [(resource ^. #identity, member) | member@(resource, _) <- [fixtureShomei, fixtureEnforcer]])
                          native
                      )
                ]
            )
        )
    )
  void (loadInventoryHistory store >>= either (fail . show) pure)

filesUnder :: FilePath -> IO [FilePath]
filesUnder path = do
  directory <- doesDirectoryExist path
  if directory
    then listDirectory path >>= fmap concat . traverse (filesUnder . (path </>))
    else pure [path]

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
