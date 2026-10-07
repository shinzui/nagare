-- | EP-182 M2: the recovery model's fake API server reproduces what a real
-- one did. Every step of @test/fixtures/kubernetes-semantics/traces.json@
-- (recorded from k3s v1.34.6 and Knative 1.22 by
-- @docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh@) is
-- replayed against 'ApiServer' in order. Real UIDs and resourceVersions in the
-- recorded actions are mapped to the world's own through the observations at
-- the same steps.
--
-- What is compared depends on the step. After a write: whether the object is
-- present, whether resourceVersion and generation moved, its deletion state,
-- the refusal class, and its non-status writers. After a step that lets the
-- controllers settle: also conditions, replica counters, revisions and pods.
-- What a controller had done "immediately" after a write is racy in a real
-- cluster and is never compared, except while a controller is frozen.
module InventoryWorldConformanceSpec (inventoryWorldConformanceTests) where

import Data.Aeson (Value (..), decodeStrict, eitherDecodeFileStrict', eitherDecodeStrict, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Kubernetes (KubernetesState (..), kubernetesObserve)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..))
import Nagare.Resource.Types (ResourceId, contextIdText, digestText, resourceIdText)
import Nagare.Test.Model.Fixtures (bindMember, serviceDigest, serviceId, serviceValue)
import Nagare.Test.World.Adversary (newAdversary)
import Nagare.Test.World.ApiServer
import Nagare.Test.World.Cluster (clusterOps, newCluster)
import Nagare.Test.World.Cluster qualified as Cluster
import Nagare.Test.World.Kinds (KindSemantics (..), ReadinessModel (..))
import Nagare.Test.World.Kubectl (Response (..), kubectlResponse)
import Test.Tasty
import Test.Tasty.HUnit

tracesPath :: FilePath
tracesPath = "test/fixtures/kubernetes-semantics/traces.json"

inventoryWorldConformanceTests :: TestTree
inventoryWorldConformanceTests =
  testGroup
    "world conformance"
    [ testCase "the fake API server reproduces the recorded traces" $ do
        steps <- loadSteps
        let found = replay steps
        assertBool (T.unpack (T.unlines (take 40 found) <> summary found)) (null found)
    , testCase "quantities are canonicalized as the API server stores them (RES-4 E11, E15)" $ do
        recorded <- mapMaybe (decodeStrict . TE.encodeUtf8) . T.lines . T.pack <$> readFile "test/fixtures/kubernetes-semantics/quantities.jsonl"
        assertBool "the quantity trace is empty" (not (null recorded))
        [ (sent, stored, canonicalQuantity sent)
          | row <- recorded
          , let sent = text (field "sent" row)
                stored = text (field "memory" row)
          , canonicalQuantity sent /= Just stored
          ]
          @?= []
    , testCase "the production runtime reads the fake server: Present, not Present while its controller lags (F69), then NotReady" $ do
        cluster <- newCluster emptyServer =<< newAdversary []
        let context = fixtureBinding ^. #identity
            key = ObjectKey "serving.knative.dev" "service" (Just "personal") "web"
            write image = do
              let stamped = stamp (contextIdText context) serviceId (snd (bindMember serviceId (serviceValue image)))
              Cluster.modifyServer cluster (\server' -> either (error . show) fst (applyServerSide "nagare-inventory" True stamped server'))
            observeAt image = kubernetesObserve (fst (clusterOps context cluster (Map.fromList [(serviceId, bindMember serviceId (serviceValue image))]))) serviceId
        write "v1"
        observeAt "v1" >>= \case
          KubernetesPresent _ _ (Just owner) digest -> (owner, digest) @?= (serviceId, serviceDigest "v1")
          other -> assertFailure ("after a good create: " <> show other)
        Cluster.modifyServer cluster (\server' -> server' & #outcomes %~ Map.insert (digestText (serviceDigest "bad")) Unready & #frozen %~ Set.insert key)
        write "bad"
        stale <- get False key <$> Cluster.readServer cluster
        -- RES-4 E4: the spec moved on, the controller has not observed it, and
        -- the old Ready=True stands. How the parser reads this is G2's
        -- question (EP-180); the server's state is what this asserts.
        (field "generation" . field "metadata" <$> stale, field "observedGeneration" . field "status" <$> stale, conditionMet "Ready" <$> stale)
          @?= (Just (Number 2), Just (Number 1), Just False)
        assertBool "the stale object still reports Ready=True" (maybe False (\o -> any (\c -> field "type" c == String "Ready" && field "status" c == String "True") (arrayOf (field "conditions" (field "status" o)))) stale)
        -- F69 (EP-180): the production parser does not accept the stale Ready.
        observeAt "bad" >>= \case
          KubernetesPresent {} -> assertFailure "a lagging controller's stale Ready=True was read as Present (F69)"
          _ -> pure ()
        Cluster.modifyServer cluster (\server' -> settleControllers (server' & #frozen %~ Set.delete key))
        observeAt "bad" >>= \case
          KubernetesNotReady _ _ (Just owner) digest -> (owner, digest) @?= (serviceId, serviceDigest "bad")
          other -> assertFailure ("after the controller observed a bad update: " <> show other)
    ]
  where
    summary found = if length found > 40 then "… and " <> T.pack (show (length found - 40)) <> " more" else ""

data Step = Step
  { experiment :: !Text
  , kindToken :: !Text
  , label :: !Text
  , action :: !Value
  , observation :: !Value
  , refusal :: !Value
  }

loadSteps :: IO [Step]
loadSteps =
  eitherDecodeFileStrict' tracesPath >>= \case
    Left err -> assertFailure ("cannot read " <> tracesPath <> ": " <> err) >> pure []
    Right document -> pure [toStep value | value <- arrayOf (field "steps" document)]
  where
    toStep value = Step (text (field "experiment" value)) (text (field "kind" value)) (text (field "step" value)) (field "action" value) (field "observation" value) (field "refusal" value)

data Replay = Replay
  { server :: !ApiServer
  , identities :: !(Map.Map Text Text)
  -- ^ Real UID or resourceVersion to the world's.
  , current :: !(Map.Map (Text, Text) ObjectKey)
  -- ^ The object each experiment's kind last acted on.
  , previousReal :: !(Map.Map ObjectKey Value)
  , previousWorld :: !(Map.Map ObjectKey Value)
  , found :: ![Text]
  }
  deriving stock (Generic)

replay :: [Step] -> [Text]
replay steps = reverse (found (foldl' replayStep (Replay emptyServer Map.empty Map.empty Map.empty Map.empty []) steps))

replayStep :: Replay -> Step -> Replay
replayStep state step
  | experiment step == "E0" = state
  -- An observation the recorder took only so that later actions' UIDs and
  -- resourceVersions can be mapped.
  | text (field "op" (action step)) == "observe" = case targetOf' of
      Just key -> state & #identities %~ learn (normalize (observation step)) (maybe absent (abstract key (server state)) (get True key (server state)))
      Nothing -> state
  | otherwise = case targetOf of
      Nothing -> state & #found %~ (describe "cannot tell which object the step acts on" :)
      Just key ->
        let translated = translate (identities state) (action step)
            server0 = registerOutcome translated (server state)
            (server1, worldRefusal) = perform key translated server0
            worldSeen = observe key server1
            realSeen = normalize (observation step)
            mismatches = compareStep key worldRefusal realSeen worldSeen state <> kubectlMismatch key translated server0
         in state
              & #server
              .~ server1
              & #current
              %~ Map.insert (experiment step, kindToken step) key
              & #identities
              %~ learn realSeen worldSeen
              & #previousReal
              %~ Map.insert key realSeen
              & #previousWorld
              %~ Map.insert key worldSeen
              & #found
              %~ (reverse (map describe mismatches) <>)
  where
    targetOf' = keyFromTarget (field "target" (action step))
    verb = text (field "op" (action step))
    describe message = experiment step <> " " <> kindToken step <> " '" <> label step <> "': " <> message
    targetOf
      | verb == "deletePod" = statefulSetOf <$> keyFromTarget (field "target" (action step))
      | otherwise =
          (keyOf =<< nonNull (field "manifest" (action step)))
            <|> keyFromTarget (field "target" (action step))
            <|> Map.lookup (experiment step, kindToken step) (current state)

    perform key translated server' = case verb of
      "apply" -> fromWrite (applyServerSide (manager "exp") (field "force" translated == Bool True) (field "manifest" translated) server')
      "create" -> fromWrite (create (manager "kubectl-create") (field "manifest" translated) server')
      "replace" -> replaceObject key (field "manifest" translated) server'
      "patchJson" -> fromWrite (patchJson (manager "kubectl-patch") key (arrayOf (field "operations" translated)) server')
      "patchMerge" -> fromWrite (patchUpdate (manager "kubectl-patch") key (field "patch" translated) server')
      "statusWrite" -> fromWrite (writeStatus (manager "kubectl-patch") key (field "patch" translated) server')
      "delete" -> fromDelete (delete (preconditionsOf translated) (propagationOf translated) key server')
      "deletePod" -> fromDelete (deletePod (Preconditions Nothing Nothing) (key ^. #namespace) (text (field "name" (field "target" translated))) server')
      "mountPvc" -> (mountClaim key server', Nothing)
      "deleteConsumer" -> (settleControllers (releaseConsumer key server'), Nothing)
      "freezeController" -> (server' & #frozen %~ Set.insert key, Nothing)
      "resumeController" -> (server' & #frozen %~ Set.delete key, Nothing)
      "unattended" -> (settleControllers (churnOnce key server'), Nothing)
      "kubectlWait" ->
        let settled = settleControllers server'
         in (settled, if maybe False (conditionMet (text (field "condition" translated))) (get False key settled) then Nothing else Just Null)
      "rolloutStatus" ->
        let settled = settleControllers server'
         in (settled, if maybe False (rolloutComplete key) (get False key settled) then Nothing else Just Null)
      _ -> (settleControllers server', Nothing)
      where
        manager fallback = maybe fallback id (nonEmpty (text (field "manager" translated)))
        fromWrite = \case
          Left refused -> (server', Just (Number (fromIntegral (refused ^. #httpStatus))))
          Right (written, _) -> (written, Nothing)
        fromDelete = \case
          Left refused -> (server', Just (Number (fromIntegral (refused ^. #httpStatus))))
          Right written -> (written, Nothing)

    -- A PUT with the recorded resourceVersion as its precondition. Only its
    -- refusal is in the traces.
    replaceObject key manifest server' = case get False key server' of
      Nothing -> (server', Just (Number 404))
      Just live
        | field "resourceVersion" (field "metadata" manifest) /= field "resourceVersion" (field "metadata" live) -> (server', Just (Number 409))
        | otherwise -> case applyServerSide "kubectl-replace" True manifest server' of
            Left refused -> (server', Just (Number (fromIntegral (refused ^. #httpStatus))))
            Right (written, _) -> (written, Nothing)

    registerOutcome translated server'
      | text (field "outcome" translated) == "Unready" = server' & #outcomes %~ Map.insert (outcomeKey (field "manifest" translated)) Unready
      | otherwise = server'

    -- What the world shows, abstracted like the recorder's observation.
    statefulSetOf podKey = ObjectKey "apps" "statefulset" (podKey ^. #namespace) (T.dropWhileEnd (== '-') (T.dropWhileEnd (`elem` ['0' .. '9']) (podKey ^. #name)))
    observe key server' = case key ^. #kind of
      "pod" -> maybe absent (const (Object (KM.fromList [("present", Bool True)]))) (getPod (key ^. #namespace) (key ^. #name) server')
      _ -> maybe absent (abstract key server') (get True key server')

    compareStep key worldRefusal realSeen worldSeen state' =
      let settled = verb `elem` ["wait", "kubectlWait", "rolloutStatus", "deletePod", "deleteConsumer", "unattended", "none"]
          frozenNow = Set.member key (frozen (server state'))
          realRefused = refusal step /= Null
          realStatus = field "status" (refusal step)
          refusalMismatch = case (worldRefusal, realRefused) of
            (Nothing, False) -> []
            (Just worldStatus, True)
              | verb `elem` ["kubectlWait", "rolloutStatus"] || worldStatus == realStatus -> []
              | otherwise -> ["refusal: real " <> render realStatus <> ", world " <> render worldStatus]
            (Nothing, True) -> ["the real server refused (" <> render realStatus <> ": " <> text (field "stderr" (refusal step)) <> "), the world accepted"]
            (Just worldStatus, False) -> ["the world refused (" <> render worldStatus <> "), the real server accepted"]
          presence = differ "present" (field "present" realSeen) (field "present" worldSeen)
          bothPresent = field "present" realSeen == Bool True && field "present" worldSeen == Bool True
          moved which seen previous = case previous of
            Just before | field "present" before == Bool True -> Bool (field which seen /= field which before)
            _ -> Null
          -- A refused write leaves the object unchanged (U4). In a real cluster a
          -- controller may still write status around it, so the recorded
          -- movement is compared only for kinds without a controller.
          refusedWrite = isJust worldRefusal && realRefused
          controlled = maybe False ((/= NoReadinessModel) . (^. #readinessModel)) (semanticsFor key)
          movement which
            | refusedWrite =
                [which <> " moved under a refused write" | moved which worldSeen (Map.lookup key (previousWorld state')) == Bool True]
                  <> (if controlled then [] else differ (which <> " moved") (moved which realSeen (Map.lookup key (previousReal state'))) (moved which worldSeen (Map.lookup key (previousWorld state'))))
            | verb `elem` ["apply", "create", "patchJson", "patchMerge", "statusWrite", "delete", "replace", "unattended"] =
                differ (which <> " moved") (moved which realSeen (Map.lookup key (previousReal state') <|> beforeOf)) (moved which worldSeen (Map.lookup key (previousWorld state')))
            | otherwise = []
          beforeOf = nonNull (field "before" (action step))
          detail = settled || frozenNow
          compared names = concat [differ name (field name realSeen) (field name worldSeen) | name <- names]
          -- A namespace the real controller had not finished emptying after a
          -- timed wait is gone in the world, whose controllers do not take
          -- time; only that outcome depends on controller speed.
          timedNamespace = verb == "wait" && field "seconds" (action step) /= Null && key ^. #kind == "namespace"
          -- An unused claim's protection finalizer goes asynchronously in a
          -- real cluster; the world releases it at the DELETE. Right after
          -- the DELETE, the real claim may still show as Terminating.
          releasingClaim = verb == "delete" && key ^. #kind == "persistentvolumeclaim" && field "present" worldSeen == Bool False && field "deletionTimestamp" realSeen == Bool True
       in refusalMismatch
            <> (if timedNamespace || releasingClaim then [] else presence)
            <> ( if experiment step == "E11"
                   then compared ["resources"]
                   else
                     if bothPresent
                       then
                         movement "resourceVersion"
                           <> (if verb == "unattended" then [] else movement "generation")
                           <> compared ["generationPresent", "deletionTimestamp"]
                           <> (if field "writers" realSeen /= Null then compared ["writers"] else [])
                           <> (if detail then compared ["conditions", "reasons", "counters", "revisionsEqual", "observedCurrent"] else [])
                           <> (if detail && field "pods" realSeen /= Null then compared ["pods"] else [])
                       else []
               )
    differ name real world = [name <> ": real " <> render real <> ", world " <> render world | real /= world]

    -- The same request through the fake kubectl prints what the real kubectl
    -- printed for a refusal (EP-180's refusal mapping reads this line).
    kubectlMismatch key translated server' = case (kubectlArguments key translated, refusal step) of
      (Just (arguments', input'), recorded@(Object _)) | text (field "stderr" recorded) /= "" ->
        case snd (kubectlResponse (KubectlRequest "world" (map T.unpack arguments') (T.unpack input')) server') of
          Answered _ _ stderr'
            | normalizeLine stderr' == normalizeLine (text (field "stderr" recorded)) -> []
            | otherwise -> ["kubectl stderr: real \"" <> text (field "stderr" recorded) <> "\", world \"" <> stderr' <> "\""]
          Unsupported argv -> ["the fake kubectl does not support: " <> argv]
      _ -> []
    kubectlArguments key translated = case verb of
      "apply" -> Just (["apply", "--server-side"] <> ["--force-conflicts" | field "force" translated == Bool True] <> ["--field-manager=" <> text (field "manager" translated), "-f", "-"], encodeValue (field "manifest" translated))
      "create" -> Just (["create", "--field-manager=" <> text (field "manager" translated), "-f", "-"], encodeValue (field "manifest" translated))
      "patchJson" -> Just (["patch", token key, key ^. #name] <> namespaced key <> ["--type=json", "-p", encodeValue (field "operations" translated)], "")
      "delete" -> Just (["delete", "--raw", apiPath key, "-f", "-"], encodeValue (field "options" translated))
      "kubectlWait" -> Just (["wait", "--for=condition=" <> text (field "condition" translated), token key <> "/" <> key ^. #name] <> namespaced key <> ["--timeout=5s"], "")
      "rolloutStatus" -> Just (["rollout", "status", key ^. #kind <> "/" <> key ^. #name] <> namespaced key <> ["--timeout=5s"], "")
      _ -> Nothing
    token key = if key ^. #group == "" then key ^. #kind else key ^. #kind <> "." <> key ^. #group
    namespaced key = maybe [] (\ns -> ["--namespace", ns]) (key ^. #namespace)
    apiPath key =
      let plural = if key ^. #kind == "networkpolicy" then "networkpolicies" else key ^. #kind <> "s"
          prefix = if key ^. #group == "" then "/api/v1" else "/apis/" <> key ^. #group <> "/v1"
       in prefix <> maybe "" (\ns -> "/namespaces/" <> ns) (key ^. #namespace) <> "/" <> plural <> "/" <> key ^. #name

-- | A native object with Nagare's reserved stamp, as the adapter writes it.
stamp :: Text -> ResourceId -> ByteString -> Value
stamp context resource native = case eitherDecodeStrict native of
  Right (Object root) ->
    let metadata = objectOf (field "metadata" (Object root))
        annotations =
          KM.fromList
            [ ("nagare.dev/context-id", String context)
            , ("nagare.dev/resource-id", String (resourceIdText resource))
            , ("nagare.dev/spec-digest", String (digestText (contentDigest native)))
            ]
     in Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object annotations) metadata)) root)
  _ -> Null

-- | The recorder's observation, from a rendered object, reduced to what the
-- comparison uses. A recorded observation goes through 'normalize' instead.
abstract :: ObjectKey -> ApiServer -> Value -> Value
abstract key server' rendered =
  normalize
    ( Object
        ( KM.fromList
            [ ("present", Bool True)
            , ("uid", field "uid" (field "metadata" rendered))
            , ("resourceVersion", field "resourceVersion" (field "metadata" rendered))
            , ("generation", field "generation" (field "metadata" rendered))
            , ("observedGeneration", field "observedGeneration" (field "status" rendered))
            , ("conditions", Object (KM.fromList [(Key.fromText (text (field "type" c)), field "status" c) | c <- arrayOf (field "conditions" (field "status" rendered))]))
            , ("reasons", Object (KM.fromList [(Key.fromText (text (field "type" c)), field "reason" c) | c <- arrayOf (field "conditions" (field "status" rendered)), field "reason" c /= Null]))
            , ("counters", Object (KM.fromList [(k, v) | (k, v) <- KM.toList (objectOf (field "status" rendered)), k `elem` ["replicas", "updatedReplicas", "readyReplicas", "availableReplicas", "currentReplicas", "unavailableReplicas"]]))
            , ("revisionsEqual", case field "updateRevision" (field "status" rendered) of Null -> Null; updateRevision -> Bool (updateRevision == field "currentRevision" (field "status" rendered)))
            , ("deletionTimestamp", Bool (field "deletionTimestamp" (field "metadata" rendered) /= Null))
            , ("finalizers", field "finalizers" (field "metadata" rendered))
            , ("managers", Array (V.fromList [String (text (field "manager" e) <> "/" <> text (field "operation" e) <> "/" <> maybe "-" id (nonEmpty (text (field "subresource" e)))) | e <- arrayOf (field "managedFields" (field "metadata" rendered))]))
            , ("pods", podsOf)
            , ("resources", resourcesOf)
            ]
        )
    )
  where
    podsOf
      | key ^. #kind == "statefulset" = Array (V.fromList [Object (KM.fromList [("ready", field "status" c)]) | ordinal <- [0 :: Int .. 9], Just pod <- [getPod (key ^. #namespace) (key ^. #name <> "-" <> T.pack (show ordinal)) server'], c <- arrayOf (field "conditions" (field "status" pod))])
      | otherwise = Null
    resourcesOf = case key ^. #kind of
      "persistentvolumeclaim" -> field "resources" (field "spec" rendered)
      _ -> case arrayOf (field "containers" (field "spec" (field "template" (field "spec" rendered)))) of
        container : _ -> field "resources" container
        [] -> Null

-- | Both sides in one shape: generation presence instead of its value,
-- observedGeneration as "current or not", non-status writers as a set, pods
-- as their readiness.
normalize :: Value -> Value
normalize seen
  | field "present" seen /= Bool True = absent
  | otherwise =
      Object
        ( KM.fromList
            [ ("present", Bool True)
            , ("uid", field "uid" seen)
            , ("resourceVersion", field "resourceVersion" seen)
            , ("generation", field "generation" seen)
            , ("generationPresent", Bool (field "generation" seen /= Null))
            , ("observedCurrent", if field "observedGeneration" seen == Null then Null else Bool (field "observedGeneration" seen == field "generation" seen))
            , ("conditions", keep ["Ready", "Available", "Progressing", "Complete", "Failed", "Suspended"] (field "conditions" seen))
            , ("reasons", keep ["Available", "Progressing"] (field "reasons" seen))
            , ("counters", keep ["replicas", "updatedReplicas", "readyReplicas", "availableReplicas"] (field "counters" seen))
            , ("revisionsEqual", field "revisionsEqual" seen)
            , ("deletionTimestamp", field "deletionTimestamp" seen)
            , ("writers", if field "managers" seen == Null then Null else Array (V.fromList (map String (Set.toList (Set.fromList [m | String m <- arrayOf (field "managers" seen), not ("/status" `T.isSuffixOf` m)])))))
            , ("pods", case field "pods" seen of Null -> Null; pods -> Array (V.fromList [if field "ready" pod == Null then String "False" else field "ready" pod | pod <- arrayOf pods]))
            , ("resources", field "resources" seen)
            ]
        )
  where
    keep names = \case
      Object fields -> Object (KM.filterWithKey (\k _ -> Key.toText k `elem` names) fields)
      other -> other

absent :: Value
absent = Object (KM.fromList [("present", Bool False)])

-- | Learn which world UID and resourceVersion stand for the real ones.
learn :: Value -> Value -> Map.Map Text Text -> Map.Map Text Text
learn real world identities'
  | field "present" real == Bool True && field "present" world == Bool True =
      foldr
        (\(r, w) -> Map.insert r w)
        identities'
        [(r, w) | name <- ["uid", "resourceVersion"], String r <- [field name real], String w <- [field name world]]
  | otherwise = identities'

-- | Replace every real UID and resourceVersion the action carries with the
-- world's.
translate :: Map.Map Text Text -> Value -> Value
translate identities' = go []
  where
    go path = \case
      Object fields -> Object (KM.mapWithKey (\k v -> go (Key.toText k : path) v) fields)
      Array values -> Array (fmap (go path) values)
      String s | identifying path, Just worldIdentity <- Map.lookup s identities' -> String worldIdentity
      other -> other
    identifying = \case
      name : _ | name `elem` ["uid", "resourceVersion", "value"] -> True
      _ -> False

keyFromTarget :: Value -> Maybe ObjectKey
keyFromTarget target = case target of
  Object _ -> Just (ObjectKey (text (field "group" target)) (text (field "kind" target)) (nonEmpty (text (field "namespace" target))) (text (field "name" target)))
  _ -> Nothing

preconditionsOf :: Value -> Preconditions
preconditionsOf translated =
  let given = field "preconditions" (field "options" translated)
   in Preconditions (nonEmpty (text (field "uid" given))) (nonEmpty (text (field "resourceVersion" given)))

propagationOf :: Value -> Propagation
propagationOf translated = case text (field "propagationPolicy" (field "options" translated)) of
  "Orphan" -> Orphan
  "Foreground" -> Foreground
  _ -> Background

-- * JSON helpers

field :: Text -> Value -> Value
field key = \case
  Object fields -> fromMaybe Null (KM.lookup (Key.fromText key) fields)
  _ -> Null

text :: Value -> Text
text = \case
  String value -> value
  _ -> ""

arrayOf :: Value -> [Value]
arrayOf = \case
  Array values -> toList values
  _ -> []

objectOf :: Value -> KM.KeyMap Value
objectOf = \case
  Object fields -> fields
  _ -> KM.empty

nonNull :: Value -> Maybe Value
nonNull = \case
  Null -> Nothing
  value -> Just value

nonEmpty :: Text -> Maybe Text
nonEmpty value = if T.null value then Nothing else Just value

encodeValue :: Value -> Text
encodeValue = TE.decodeUtf8 . LBS.toStrict . encode

-- | A stderr line with UIDs, resourceVersions and other numbers masked, so a
-- replay's own identities compare equal to the recorded ones.
normalizeLine :: Text -> Text
normalizeLine = T.unwords . map mask . T.words . T.replace "\"/dev/fd/63\"" "\"STDIN\"" . T.takeWhile (/= '\n')
  where
    mask word
      | T.any (`elem` ['0' .. '9']) word && T.length (T.filter (`elem` ['0' .. '9']) word) >= 3 = "#"
      | otherwise = word

render :: Value -> Text
render = \case
  String s -> s
  Null -> "null"
  other -> T.pack (show other)
