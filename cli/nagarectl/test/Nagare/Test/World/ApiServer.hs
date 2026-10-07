-- | EP-182: a pure, in-memory Kubernetes API server whose behaviour comes from
-- the validated semantics (RES-4, the kind table's 'KindSemantics' and the
-- recorded traces). It knows nothing about Nagare's adapter: it stores and
-- renders objects as the real server does and answers writes with the same
-- refusal classes, and the production runtime interprets what it returns.
--
-- Modelled, as validated:
--
-- * a global resourceVersion that moves on every persisted write and never on
--   a no-op (U2);
-- * @metadata.generation@ per the kind's 'GenerationRule' (U8);
-- * per-field ownership in @managedFields@ with server-side apply's conflict
--   rules: create records an Update entry, a forced apply moves only the
--   fields it changes, an Update takes the fields it changes (U10);
-- * refusals that leave the object unchanged: 409 AlreadyExists, 409 Conflict
--   (stale resourceVersion, delete preconditions, apply with a UID on an
--   absent object, apply conflicts), 422 Invalid (wrong UID while present, a
--   failed JSON-patch test), 404 (U4, U5);
-- * deletion per the kind's 'DeletionRule' (U6);
-- * quantity canonicalization (U7);
-- * one controller per readiness model, run by 'controllerStep' (RES-4 §2).
--
-- Simplified, and documented as such: lists are owned atomically (no
-- associative-list merge keys), time does not pass (a broken Deployment is at
-- once past its progress deadline), and a revision's outcome is decided by the
-- spec digest Nagare stamps on the object.
module Nagare.Test.World.ApiServer
  ( ApiServer (..)
  , ObjectKey (..)
  , Stored (..)
  , Pod (..)
  , Outcome (..)
  , Operation (..)
  , FieldsEntry (..)
  , ApiRefusal (..)
  , Propagation (..)
  , Preconditions (..)
  , emptyServer
  , keyOf
  , semanticsFor
  , create
  , applyServerSide
  , patchJson
  , patchUpdate
  , writeStatus
  , delete
  , deletePod
  , releaseConsumer
  , mountClaim
  , get
  , getPod
  , listPods
  , controllerStep
  , settleControllers
  , churnOnce
  , specDigestOf
  , outcomeKey
  , effectiveOutcome
  , templateOf
  , conditionMet
  , rolloutComplete
  , statusManager
  , apiVersionOf
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Test.World.Kinds
import Nagare.Test.World.Quantity (canonicalize)

-- | An object's address: API group, lower-case kind, namespace and name.
data ObjectKey = ObjectKey
  { group :: !Text
  , kind :: !Text
  , namespace :: !(Maybe Text)
  , name :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | What a written spec does once its controller acts on it.
data Outcome
  = Good
  | -- | Never becomes Ready (a crash loop, an unschedulable pod).
    Unready
  | -- | Fails terminally (a Job).
    Failed
  deriving stock (Eq, Show)

data Operation = Apply | Update
  deriving stock (Eq, Ord, Show)

-- | One @managedFields@ entry: who owns which leaf paths.
data FieldsEntry = FieldsEntry
  { manager :: !Text
  , operation :: !Operation
  , subresource :: !(Maybe Text)
  , fields :: !(Set.Set [Text])
  }
  deriving stock (Eq, Show, Generic)

-- | A StatefulSet's pod, which the StatefulSet controller owns.
data Pod = Pod
  { uid :: !Text
  , resourceVersion :: !Int
  , revision :: !Text
  , ready :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data Stored = Stored
  { uid :: !Text
  , resourceVersion :: !Int
  , generation :: !(Maybe Int)
  , content :: !Value
  -- ^ The object without status and server metadata: apiVersion, kind,
  -- metadata (name, namespace, labels, annotations) and its spec or data.
  , status :: !Value
  , deleting :: !Bool
  , finalizers :: ![Text]
  , managed :: ![FieldsEntry]
  , memory :: !(Map.Map Text Value)
  -- ^ Controller memory: a Deployment's last available template, a
  -- StatefulSet's current revision, a revision's outcome.
  , pods :: ![Pod]
  }
  deriving stock (Eq, Show, Generic)

data ApiServer = ApiServer
  { objects :: !(Map.Map ObjectKey Stored)
  , nextResourceVersion :: !Int
  , nextUid :: !Int
  , outcomes :: !(Map.Map Text Outcome)
  -- ^ By the @nagare.dev/spec-digest@ stamp of the written object; a spec
  -- without an entry is 'Good'.
  , inUse :: !(Set.Set ObjectKey)
  -- ^ PersistentVolumeClaims a running pod mounts.
  , frozen :: !(Set.Set ObjectKey)
  -- ^ Objects whose controller has not yet observed the latest write.
  }
  deriving stock (Eq, Show, Generic)

data ApiRefusal = ApiRefusal
  { httpStatus :: !Int
  , reason :: !Text
  , message :: !Text
  }
  deriving stock (Eq, Show, Generic)

data Propagation = Orphan | Background | Foreground
  deriving stock (Eq, Show)

data Preconditions = Preconditions
  { uidIs :: !(Maybe Text)
  , resourceVersionIs :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

emptyServer :: ApiServer
emptyServer = ApiServer Map.empty 1000 1 Map.empty Set.empty Set.empty

keyOf :: Value -> Maybe ObjectKey
keyOf value = do
  apiVersion <- textAt ["apiVersion"] value
  kindText <- textAt ["kind"] value
  metadata <- objectField "metadata" value
  objectName <- textField "name" metadata
  let group' = case T.breakOn "/" apiVersion of
        (_, "") -> ""
        (prefix, _) -> prefix
  pure (ObjectKey group' (T.toLower kindText) (textField "namespace" metadata) objectName)

semanticsFor :: ObjectKey -> Maybe KindSemantics
semanticsFor key = case [row | row <- kindTable, kubernetesKind row == Just (key ^. #group, key ^. #kind)] of
  row : _ -> row ^. #semantics
  [] -> Nothing

-- * Writes

-- | @kubectl create@: refused when the address is taken; the creator owns
-- every field through an Update entry.
create :: Text -> Value -> ApiServer -> Either ApiRefusal (ApiServer, Value)
create managerName submitted server = do
  key <- maybe (Left (invalid "the object has no apiVersion, kind or name")) Right (keyOf submitted)
  when (Map.member key (objects server)) $
    Left (ApiRefusal 409 "AlreadyExists" (plural key <> " \"" <> key ^. #name <> "\" already exists"))
  let written = canonicalize (contentOf submitted)
  requireFields key written
  pure (insertNew key written (FieldsEntry managerName Update Nothing (leafSet written)) server)

-- | Server-side apply, with the request's UID and resourceVersion as
-- preconditions. Without @force@, changing a field another entry owns is a
-- conflict.
applyServerSide :: Text -> Bool -> Value -> ApiServer -> Either ApiRefusal (ApiServer, Value)
applyServerSide managerName force submitted server = do
  key <- maybe (Left (invalid "the object has no apiVersion, kind or name")) Right (keyOf submitted)
  let metadata = fromMaybe KM.empty (objectField "metadata" submitted)
      wantUid = textField "uid" metadata
      wantVersion = textField "resourceVersion" metadata
      written = canonicalize (contentOf submitted)
      applied = leafSet written
  case Map.lookup key (objects server) of
    Nothing -> case wantUid of
      Just expected ->
        Left
          ( ApiRefusal 409 "Conflict" $
              "Operation cannot be fulfilled on "
                <> plural key
                <> " \""
                <> key ^. #name
                <> "\": uid mismatch: the provided object specified uid "
                <> expected
                <> ", and no existing object was found"
          )
      -- An apply's resourceVersion does not stop it creating (U5).
      Nothing -> do
        requireFields key written
        pure (insertNew key written (FieldsEntry managerName Apply Nothing applied) server)
    Just stored -> do
      for_ wantUid $ \expected ->
        unless (expected == stored ^. #uid) $
          Left (invalid ("metadata.uid: Invalid value: \"" <> expected <> "\": field is immutable"))
      for_ wantVersion $ \expected ->
        unless (expected == "0" || expected == tshow (stored ^. #resourceVersion)) $
          Left (modified key)
      let current = stored ^. #content
          changed = Set.filter (\path -> lastSegment path /= "." && leafAt path written /= leafAt path current) applied
          self entry = entry ^. #manager == managerName && entry ^. #operation == Apply && isNothing (entry ^. #subresource)
          conflicts =
            [ (entry ^. #manager, path)
            | entry <- stored ^. #managed
            , not (self entry)
            , isNothing (entry ^. #subresource)
            , path <- Set.toList (Set.intersection changed (entry ^. #fields))
            ]
      unless (force || null conflicts) $ Left (applyConflict key conflicts)
      let previouslyApplied = maybe Set.empty (^. #fields) (find self (stored ^. #managed))
          dropped = Set.filter (\path -> lastSegment path /= "." && not (ownedByOther path)) (previouslyApplied `Set.difference` applied)
          ownedByOther path = any (\entry -> not (self entry) && Set.member path (entry ^. #fields)) (stored ^. #managed)
          kept = Set.fromList [path | path <- Set.toList dropped, leafAt path (withDefaults key (admissionDefaults key (Object KM.empty))) /= Null]
          content' = foldr removeLeaf (foldr (\path -> setLeaf path (leafAt path written)) current [path | path <- Set.toList applied, lastSegment path /= "."]) (Set.toList (dropped `Set.difference` kept))
          others =
            [ entry & #fields %~ (if force then (`Set.difference` changed) else id)
            | entry <- stored ^. #managed
            , not (self entry)
            ]
          managed' = normalizeEntries (others <> [FieldsEntry managerName Apply Nothing applied])
      for_ (immutableViolation key current content') (Left . invalid)
      pure (replaceContent key stored (withDefaults key content') managed' server)

-- | A JSON patch, as @kubectl patch --type=json@ sends it: @test@ operations
-- are preconditions (422 when one fails), @add@ and @replace@ write. The
-- writer takes the fields it changes through an Update entry.
patchJson :: Text -> ObjectKey -> [Value] -> ApiServer -> Either ApiRefusal (ApiServer, Value)
patchJson managerName key operations server = do
  stored <- maybe (Left (notFound key)) Right (Map.lookup key (objects server))
  let rendered = render False stored
  for_ operations $ \operation' -> case (textAt ["op"] operation', textAt ["path"] operation') of
    (Just "test", Just path) ->
      unless (leafAt (pointer path) rendered == fromMaybe Null (field "value" operation')) $
        Left (invalid "the server rejected our request due to an error in our request")
    _ -> Right ()
  let writes' = [(pointer path, fromMaybe Null (field "value" operation')) | operation' <- operations, Just verb <- [textAt ["op"] operation'], verb `elem` ["add", "replace"], Just path <- [textAt ["path"] operation']]
      content' = canonicalize (foldl' (\value (path, new) -> setLeaf path new value) (stored ^. #content) writes')
  for_ (immutableViolation key (stored ^. #content) content') (Left . invalid)
  pure (updateBy managerName key stored content' server)

-- | A merge patch through an Update operation, as @kubectl patch
-- --type=merge@ or @kubectl edit@ writes: the writer takes the fields it
-- changes.
patchUpdate :: Text -> ObjectKey -> Value -> ApiServer -> Either ApiRefusal (ApiServer, Value)
patchUpdate managerName key patch server = do
  stored <- maybe (Left (notFound key)) Right (Map.lookup key (objects server))
  let content' = canonicalize (mergePatch (stored ^. #content) patch)
  for_ (immutableViolation key (stored ^. #content) content') (Left . invalid)
  pure (updateBy managerName key stored content' server)

-- | A write to the status subresource. It moves resourceVersion when it
-- changes the status, and never generation.
writeStatus :: Text -> ObjectKey -> Value -> ApiServer -> Either ApiRefusal (ApiServer, Value)
writeStatus managerName key patch server = do
  stored <- maybe (Left (notFound key)) Right (Map.lookup key (objects server))
  unless (maybe False (^. #hasStatusSubresource) (semanticsFor key)) $
    Left (ApiRefusal 404 "NotFound" ("the server could not find the requested resource (patch " <> plural key <> " " <> key ^. #name <> ")"))
  let server' = persistStatus managerName key stored (mergePatch (stored ^. #status) patch) server
  pure (server', maybe Null (render False) (Map.lookup key (objects server')))

-- | DELETE with UID and resourceVersion preconditions and a propagation
-- policy. What remains follows the kind's 'DeletionRule'.
delete :: Preconditions -> Propagation -> ObjectKey -> ApiServer -> Either ApiRefusal ApiServer
delete preconditions propagation key server = do
  stored <- maybe (Left (notFound key)) Right (Map.lookup key (objects server))
  for_ (preconditions ^. #uidIs) $ \expected ->
    unless (expected == stored ^. #uid) $
      Left (preconditionFailed key ("the UID in the precondition (" <> expected <> ") does not match the UID in record (" <> stored ^. #uid <> "). The object might have been deleted and then recreated"))
  for_ (preconditions ^. #resourceVersionIs) $ \expected ->
    unless (expected == tshow (stored ^. #resourceVersion)) $
      Left (preconditionFailed key ("the ResourceVersion in the precondition (" <> expected <> ") does not match the ResourceVersion in record (" <> tshow (stored ^. #resourceVersion) <> "). The object might have been modified"))
  let rule = maybe Immediate (^. #deletionRule) (semanticsFor key)
      -- Setting deletionTimestamp also moves generation (RES-4 E7).
      hold finalizer = Right (bumped key (stored & #deleting .~ True & #generation %~ fmap (+ 1) & #finalizers %~ (\present -> present <> [finalizer | finalizer `notElem` present])) server)
  if stored ^. #deleting
    then Right server
    else case rule of
      _
        | not (null (controllerFinalizers key)) ->
            -- The controller finalizes at once unless it is lagging.
            if Set.member key (frozen server) then hold (fromMaybe "" (listToMaybe (controllerFinalizers key))) else Right (server & #objects %~ Map.delete key)
      OrphanBlocked | propagation == Orphan -> hold "orphan"
      -- Held while a pod mounts the claim; an unused claim's protection
      -- finalizer goes at once (in a real cluster within the second).
      HeldWhileInUse | claimInUse server key -> hold "kubernetes.io/pvc-protection"
      HeldUntilEmpty -> hold "kubernetes"
      _ -> Right (server & #objects %~ Map.delete key)

-- | Delete a StatefulSet's pod by name, with its UID and resourceVersion as
-- preconditions. The controller recreates it at the update revision on its
-- next step.
deletePod :: Preconditions -> Maybe Text -> Text -> ApiServer -> Either ApiRefusal ApiServer
deletePod preconditions podNamespace podName server =
  case [(key, stored, ordinal) | (key, stored) <- Map.toList (objects server), key ^. #kind == "statefulset", key ^. #namespace == podNamespace, Just ordinal <- [ordinalOf key], ordinal < length (stored ^. #pods)] of
    (key, stored, ordinal) : _ -> do
      let pod = (stored ^. #pods) !! ordinal
          podKey = ObjectKey "" "pod" podNamespace podName
      for_ (preconditions ^. #uidIs) $ \expected -> unless (expected == pod ^. #uid) (Left (preconditionFailed podKey "the UID in the precondition does not match the UID in record"))
      for_ (preconditions ^. #resourceVersionIs) $ \expected -> unless (expected == tshow (pod ^. #resourceVersion)) (Left (preconditionFailed podKey "the ResourceVersion in the precondition does not match the ResourceVersion in record"))
      let remaining = take ordinal (stored ^. #pods) <> drop (ordinal + 1) (stored ^. #pods)
      Right (controllerStep key (server & #objects %~ Map.insert key (stored & #pods .~ remaining)))
    [] -> Left (notFound (ObjectKey "" "pod" podNamespace podName))
  where
    ordinalOf key = do
      suffix <- T.stripPrefix (key ^. #name <> "-") podName
      either (const Nothing) (\(n, rest) -> if T.null rest then Just n else Nothing) (TR.decimal suffix)

-- | A running pod mounts a PersistentVolumeClaim: the volume controller binds
-- it, writing its bind annotations and @spec.volumeName@ as @k3s@ (RES-4 E7),
-- and a delete is held while the pod lives.
mountClaim :: ObjectKey -> ApiServer -> ApiServer
mountClaim key server = case Map.lookup key (objects server) of
  Nothing -> server
  Just stored ->
    let annotations =
          object
            [ "pv.kubernetes.io/bind-completed" .= ("yes" :: Text)
            , "pv.kubernetes.io/bound-by-controller" .= ("yes" :: Text)
            , "volume.beta.kubernetes.io/storage-provisioner" .= ("rancher.io/local-path" :: Text)
            , "volume.kubernetes.io/selected-node" .= ("node" :: Text)
            , "volume.kubernetes.io/storage-provisioner" .= ("rancher.io/local-path" :: Text)
            ]
        bound = mergePatch (stored ^. #content) (object ["metadata" .= object ["annotations" .= annotations], "spec" .= object ["volumeName" .= ("pvc-" <> stored ^. #uid)]])
        (server', _) = updateBy "k3s" key stored bound (server & #inUse %~ Set.insert key)
     in case Map.lookup key (objects server') of
          Just updated -> persistStatus "k3s" key updated (object ["phase" .= ("Bound" :: Text)]) server'
          Nothing -> server'

-- | Whether a pod mounts the claim: one marked mounted ('mountClaim'), or one
-- a workload in its namespace runs with the claim in its pod template (a
-- StatefulSet with pods, a Deployment with replicas, a Knative Service).
claimInUse :: ApiServer -> ObjectKey -> Bool
claimInUse server key =
  Set.member key (inUse server)
    || or
      [ String (key ^. #name) `elem` [leafAt ["persistentVolumeClaim", "claimName"] volume | volume <- arrayValues (leafAt templateVolumes (stored ^. #content))]
      | (workload, stored) <- Map.toList (objects server)
      , workload ^. #namespace == key ^. #namespace
      , not (stored ^. #deleting)
      , running workload stored
      ]
  where
    templateVolumes = ["spec", "template", "spec", "volumes"]
    running workload stored = case (workload ^. #group, workload ^. #kind) of
      ("apps", "statefulset") -> not (null (stored ^. #pods))
      ("apps", "deployment") -> maybe True (> 0) (numberField "replicas" (leafAt ["spec"] (stored ^. #content)))
      ("serving.knative.dev", "service") -> True
      _ -> False

-- | The pod that mounted a PersistentVolumeClaim is gone; a delete it held
-- completes.
releaseConsumer :: ObjectKey -> ApiServer -> ApiServer
releaseConsumer key server =
  let released = server & #inUse %~ Set.delete key
   in case Map.lookup key (objects released) of
        Just stored | stored ^. #deleting && not (claimInUse released key) -> released & #objects %~ Map.delete key
        _ -> released

-- * Reads

-- | The object as @kubectl get -o json@ returns it; with managed fields when
-- asked for (@--show-managed-fields@).
get :: Bool -> ObjectKey -> ApiServer -> Maybe Value
get withManagedFields key server = render withManagedFields <$> Map.lookup key (objects server)

getPod :: Maybe Text -> Text -> ApiServer -> Maybe Value
getPod podNamespace podName server =
  listToMaybe [rendered | rendered <- listPods podNamespace server, pathValue ["metadata", "name"] rendered == Just (String podName)]

-- | EP-181: the pods of every StatefulSet in a namespace, as the API server
-- serves them. Each is controlled by its StatefulSet (an owner reference with
-- @controller: true@) and carries the template's labels and its
-- @controller-revision-hash@.
listPods :: Maybe Text -> ApiServer -> [Value]
listPods podNamespace server =
  [ object
      [ "apiVersion" .= ("v1" :: Text)
      , "kind" .= ("Pod" :: Text)
      , "metadata"
          .= object
            [ "name" .= (key ^. #name <> "-" <> tshow ordinal)
            , "namespace" .= podNamespace
            , "uid" .= (pod ^. #uid)
            , "resourceVersion" .= tshow (pod ^. #resourceVersion)
            , "labels" .= Object (KM.insert "controller-revision-hash" (String (pod ^. #revision)) (templateLabels stored))
            , "ownerReferences" .= [object ["apiVersion" .= ("apps/v1" :: Text), "kind" .= ("StatefulSet" :: Text), "name" .= (key ^. #name), "uid" .= (stored ^. #uid), "controller" .= True]]
            ]
      , "status" .= object ["phase" .= ("Running" :: Text), "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= boolText (pod ^. #ready)]]]
      ]
  | (key, stored) <- Map.toList (objects server)
  , key ^. #kind == "statefulset"
  , key ^. #namespace == podNamespace
  , (ordinal, pod) <- zip [0 :: Int ..] (stored ^. #pods)
  ]
  where
    templateLabels stored = case pathValue ["spec", "template", "metadata", "labels"] (stored ^. #content) of
      Just (Object labels) -> labels
      _ -> KM.empty

-- | The value at a path of object keys.
pathValue :: [Text] -> Value -> Maybe Value
pathValue path value = foldl (\found step -> found >>= \case Object fields -> KM.lookup (Key.fromText step) fields; _ -> Nothing) (Just value) path

render :: Bool -> Stored -> Value
render withManagedFields stored =
  let base = objectOf (stored ^. #content)
      metadata = fromMaybe KM.empty (objectField "metadata" (stored ^. #content))
      serverMetadata =
        [ ("uid", String (stored ^. #uid))
        , ("resourceVersion", String (tshow (stored ^. #resourceVersion)))
        , ("creationTimestamp", String "2026-10-06T00:00:00Z")
        ]
          <> [("generation", Number (fromIntegral g)) | Just g <- [stored ^. #generation]]
          <> [("deletionTimestamp", String "2026-10-06T00:00:01Z") | stored ^. #deleting]
          <> [("finalizers", Array (V.fromList (map String (stored ^. #finalizers)))) | not (null (stored ^. #finalizers))]
          <> [("managedFields", Array (V.fromList (map renderEntry (stored ^. #managed)))) | withManagedFields]
      metadata' = foldr (\(k, v) -> KM.insert (Key.fromText k) v) metadata serverMetadata
      withStatus = if stored ^. #status == Null then id else KM.insert "status" (stored ^. #status)
   in Object (withStatus (KM.insert "metadata" (Object metadata') base))

renderEntry :: FieldsEntry -> Value
renderEntry entry =
  object
    ( [ "manager" .= (entry ^. #manager)
      , "operation" .= tshow (entry ^. #operation)
      , "apiVersion" .= ("v1" :: Text)
      , "time" .= ("2026-10-06T00:00:00Z" :: Text)
      , "fieldsType" .= ("FieldsV1" :: Text)
      , "fieldsV1" .= fieldsTree (Set.toList (entry ^. #fields))
      ]
        <> ["subresource" .= s | Just s <- [entry ^. #subresource]]
    )
  where
    fieldsTree paths =
      Object
        ( KM.fromList
            [ (Key.fromText (if head' == "." then "." else "f:" <> head'), fieldsTree [rest | (h : rest) <- paths, h == head', not (null rest)])
            | head' <- nubOrd [h | h : _ <- paths]
            ]
        )

-- * Controllers

-- | Every controller acts once on everything it owns that is not frozen.
settleControllers :: ApiServer -> ApiServer
settleControllers server = foldr controllerStep server (Map.keys (objects server))

-- | One controller pass over one object: status per its readiness model,
-- written (and resourceVersion moved) only when it changes. A frozen object's
-- controller has not observed its latest generation (a lagging controller).
controllerStep :: ObjectKey -> ApiServer -> ApiServer
controllerStep key server = case (Map.lookup key (objects server), semanticsFor key) of
  (Just stored, Just semantics')
    | Set.member key (frozen server) -> server
    -- A controller stops reconciling an object being deleted; only the
    -- finalizers below still act (RES-4 E7: observedGeneration stays behind
    -- the generation the deletion moved).
    | stored ^. #deleting && semantics' ^. #readinessModel /= NoReadinessModel -> server
    | otherwise -> case semantics' ^. #readinessModel of
        KnativeConditions -> persistStatus (statusManager key) key (withControllerFinalizer key stored) (knativeStatus server key stored) server
        DeploymentRollout -> deploymentStep server key stored
        StatefulSetRollout -> statefulSetStep server key stored
        JobTerminal -> persistStatus (statusManager key) key stored (jobStatus server stored) server
        NoReadinessModel
          | semantics' ^. #deletionRule == HeldWhileInUse && stored ^. #deleting && not (claimInUse server key) ->
              server & #objects %~ Map.delete key
          | semantics' ^. #deletionRule == HeldUntilEmpty && stored ^. #deleting ->
              -- The namespace controller deletes the contents, then the namespace.
              server & #objects %~ Map.filterWithKey (\k _ -> k /= key && k ^. #namespace /= Just (key ^. #name))
          | otherwise -> server
  _ -> server

-- | A steady-state status write by the kind's churn source (RES-4 E10).
churnOnce :: ObjectKey -> ApiServer -> ApiServer
churnOnce key server = case (Map.lookup key (objects server), (^. #churnSource) <$> semanticsFor key) of
  (Just stored, Just source)
    | source /= NoChurn && not (boolField ["spec", "suspend"] (stored ^. #content)) ->
        let tick = maybe 0 (+ 1) (numberField "churn" (stored ^. #status))
         in persistStatus (statusManager key) key stored (mergePatch (stored ^. #status) (object ["churn" .= tick])) server
  _ -> server

-- | A Knative Service whose name an unowned core Service already holds stays
-- @Ready=False/NotOwned@ (RES-4 E1, G8).
knativeStatus :: ApiServer -> ObjectKey -> Stored -> Value
knativeStatus server key stored =
  object
    [ "observedGeneration" .= (stored ^. #generation)
    , "conditions"
        .= [ condition "ConfigurationsReady" ready reason'
           , condition "Ready" ready reason'
           , condition "RoutesReady" "True" Nothing
           ]
    ]
  where
    (ready, reason')
      | key ^. #kind == "service" && Map.member (key & #group .~ "") (objects server) = ("False", Just "NotOwned")
      | otherwise = case outcomeOf server stored of
          Good -> ("True", Nothing)
          _ -> ("False", Just "RevisionFailed")

-- | A Job that was suspended and resumed keeps @Suspended=False@ beside its
-- outcome (RES-4 E1).
jobStatus :: ApiServer -> Stored -> Value
jobStatus server stored
  | boolField ["spec", "suspend"] (stored ^. #content) = object ["conditions" .= [condition "Suspended" "True" (Just "JobSuspended")]]
  | otherwise = case outcomeOf server stored of
      Good -> object ["conditions" .= (resumed <> [condition "SuccessCriteriaMet" "True" (Just "CompletionsReached"), condition "Complete" "True" (Just "CompletionsReached")]), "succeeded" .= (1 :: Int)]
      Failed -> object ["conditions" .= (resumed <> [condition "FailureTarget" "True" (Just "BackoffLimitExceeded"), condition "Failed" "True" (Just "BackoffLimitExceeded")]), "failed" .= (1 :: Int)]
      Unready -> object ["conditions" .= resumed, "active" .= (1 :: Int)]
  where
    resumed = [condition "Suspended" "False" (Just "JobResumed") | wasSuspended]
    wasSuspended = any (\c -> textAt ["type"] c == Just "Suspended") (arrayValues (leafAt ["conditions"] (stored ^. #status)))

-- | A Deployment keeps its last available template's pods during a broken
-- update, so it stays Available (RES-4 E5); the update is at once past its
-- progress deadline.
deploymentStep :: ApiServer -> ObjectKey -> Stored -> ApiServer
deploymentStep server key stored =
  let replicas = fromMaybe 1 (numberField "replicas" (fieldPath ["spec"] (stored ^. #content)))
      template = fieldPath ["spec", "template"] (stored ^. #content)
      good = outcomeOf server stored == Good
      previous = Map.lookup "availableTemplate" (stored ^. #memory)
      oldAvailable = isJust previous && previous /= Just template
      status'
        | replicas == 0 = counters 0 0 0 0 0 "True" "MinimumReplicasAvailable" "True" "NewReplicaSetAvailable"
        | good = counters replicas replicas replicas replicas 0 "True" "MinimumReplicasAvailable" "True" "NewReplicaSetAvailable"
        | oldAvailable = counters (replicas + 1) 1 replicas replicas 1 "True" "MinimumReplicasAvailable" "False" "ProgressDeadlineExceeded"
        | otherwise = counters replicas replicas 0 0 replicas "False" "MinimumReplicasUnavailable" "False" "ProgressDeadlineExceeded"
      counters total updated readyCount available unavailable availableStatus availableReason progressStatus progressReason =
        object
          ( [ "observedGeneration" .= (stored ^. #generation)
            , "replicas" .= total
            , "updatedReplicas" .= updated
            , "readyReplicas" .= readyCount
            , "availableReplicas" .= available
            , "conditions" .= [condition "Available" availableStatus (Just availableReason), condition "Progressing" progressStatus (Just progressReason)]
            ]
              <> ["unavailableReplicas" .= unavailable | unavailable > 0]
          )
      remembered = if good then stored & #memory %~ Map.insert "availableTemplate" template else stored
   in persistStatus (statusManager key) key remembered status' server

-- | OrderedReady and RollingUpdate, as Nagare renders them: a pod at another
-- revision is replaced only when it is Ready; a pod that is not Ready blocks
-- every later template change until it is deleted (RES-4 E6).
statefulSetStep :: ApiServer -> ObjectKey -> Stored -> ApiServer
statefulSetStep server key stored =
  let replicas = fromMaybe 1 (numberField "replicas" (fieldPath ["spec"] (stored ^. #content)))
      parallel = textAt ["spec", "podManagementPolicy"] (stored ^. #content) == Just "Parallel"
      updateRevision = revisionOf (fieldPath ["spec", "template"] (stored ^. #content))
      outcome = outcomeOf server stored
      fresh n = Pod (uidText (nextUid server + n)) (nextResourceVersion server + n) updateRevision (outcome == Good)
      step (podsSoFar, blocked, n) ordinal = case drop ordinal (stored ^. #pods) of
        current : _
          | blocked -> (podsSoFar <> [current], True, n)
          | current ^. #revision == updateRevision -> (podsSoFar <> [current], not (current ^. #ready) && not parallel, n)
          | current ^. #ready || parallel -> let pod = fresh n in (podsSoFar <> [pod], not (pod ^. #ready) && not parallel, n + 1)
          | otherwise -> (podsSoFar <> [current], True, n)
        []
          | blocked -> (podsSoFar, True, n)
          | otherwise -> let pod = fresh n in (podsSoFar <> [pod], not (pod ^. #ready) && not parallel, n + 1)
      (pods', _, created) = foldl' step ([], False, 0 :: Int) [0 .. replicas - 1]
      updated = length [pod | pod <- pods', pod ^. #revision == updateRevision]
      readyCount = length [pod | pod <- pods', pod ^. #ready]
      currentRevision
        | updated == replicas = updateRevision
        | otherwise = fromMaybe updateRevision (textValue =<< Map.lookup "currentRevision" (stored ^. #memory))
      status' =
        object
          ( [ "observedGeneration" .= (stored ^. #generation)
            , "replicas" .= length pods'
            , "currentRevision" .= currentRevision
            , "updateRevision" .= updateRevision
            , "availableReplicas" .= readyCount
            ]
              <> ["updatedReplicas" .= updated | updated > 0]
              <> ["currentReplicas" .= current' | let current' = length [pod | pod <- pods', pod ^. #revision == currentRevision], current' > 0]
              <> ["readyReplicas" .= readyCount | readyCount > 0]
          )
      stored' = stored & #pods .~ pods' & #memory %~ Map.insert "currentRevision" (String currentRevision)
      server' = server & #nextUid %~ (+ created) & #nextResourceVersion %~ (+ created)
   in persistStatus (statusManager key) key stored' status' server'

-- | Finalizers a kind's controller adds as soon as it sees the object, and
-- removes when it finalizes a deletion (RES-4 E1, E14: a DomainMapping).
controllerFinalizers :: ObjectKey -> [Text]
controllerFinalizers key = ["domainmappings.serving.knative.dev" | key ^. #group == "serving.knative.dev" && key ^. #kind == "domainmapping"]

withControllerFinalizer :: ObjectKey -> Stored -> Stored
withControllerFinalizer key stored = case controllerFinalizers key of
  [] -> stored
  wanted
    | all (`elem` (stored ^. #finalizers)) wanted -> stored
    | otherwise ->
        stored
          & #finalizers
          %~ (<> [f | f <- wanted, f `notElem` (stored ^. #finalizers)])
          & #managed
          %~ (normalizeEntries . (<> [FieldsEntry (statusManager key) Update Nothing (Set.fromList [["metadata", "finalizers"]])]))

-- | The manager a kind's controller writes status as: Knative's controllers
-- are @controller@, k3s's built-in ones @k3s@.
statusManager :: ObjectKey -> Text
statusManager key = if key ^. #group == "serving.knative.dev" then "controller" else "k3s"

-- * kubectl's client-side checks (RES-4 U9)

-- | @kubectl wait --for=condition=<c>@: the condition is True and the
-- controller has observed the current generation.
conditionMet :: Text -> Value -> Bool
conditionMet conditionType rendered =
  let generation' = leafAt ["metadata", "generation"] rendered
      observed = leafAt ["status", "observedGeneration"] rendered
      holds = any (\c -> T.toLower (fromMaybe "" (textAt ["type"] c)) == T.toLower conditionType && textAt ["status"] c == Just "True") (arrayValues (leafAt ["status", "conditions"] rendered))
   in holds && (generation' == Null || observed == Null || generation' == observed)

-- | @kubectl rollout status@ for a Deployment or StatefulSet.
rolloutComplete :: ObjectKey -> Value -> Bool
rolloutComplete key rendered =
  let n path = numberField' path rendered
      desired = fromMaybe 1 (n ["spec", "replicas"])
      observedCurrent = leafAt ["metadata", "generation"] rendered == leafAt ["status", "observedGeneration"] rendered
      updated = fromMaybe 0 (n ["status", "updatedReplicas"])
   in observedCurrent && case key ^. #kind of
        "deployment" -> updated == desired && fromMaybe 0 (n ["status", "replicas"]) == updated && fromMaybe 0 (n ["status", "availableReplicas"]) == updated
        "statefulset" -> updated == desired && fromMaybe 0 (n ["status", "readyReplicas"]) == desired && textAt ["status", "currentRevision"] rendered == textAt ["status", "updateRevision"] rendered
        _ -> False
  where
    numberField' path value = case leafAt path value of
      Number x -> Just (round x :: Int)
      _ -> Nothing

-- * Internals

insertNew :: ObjectKey -> Value -> FieldsEntry -> ApiServer -> (ApiServer, Value)
insertNew key written0 entry0 server =
  let admitted = admissionDefaults key written0
      written = withDefaults key admitted
      -- Admission mutations belong to the request's manager; defaulting only
      -- to an Update, whose ownership is the diff from an empty object.
      attributed = if entry0 ^. #operation == Update then written else admitted
      entry = entry0 & #fields %~ (<> (leafSet attributed `Set.difference` leafSet written0))
      stored =
        Stored
          { uid = uidText (nextUid server)
          , resourceVersion = nextResourceVersion server
          , generation = if hasGeneration key then Just 1 else Nothing
          , content = written
          , status = Null
          , deleting = False
          , finalizers = ["kubernetes.io/pvc-protection" | key ^. #kind == "persistentvolumeclaim"]
          , managed = normalizeEntries [entry]
          , memory = Map.empty
          , pods = []
          }
          & withTemplateOutcome server written
      server' = controllerStep key (server & #objects %~ Map.insert key stored & #nextUid %~ (+ 1) & #nextResourceVersion %~ (+ 1))
   in (server', maybe Null (render False) (Map.lookup key (objects server')))

-- | Fields a mutating admission plugin sets at create, which the API server
-- attributes to the creating manager: a PVC's default StorageClass. A later
-- apply that omits one releases its ownership but keeps the field, so even a
-- repeated apply of the same manifest moves resourceVersion once (RES-4 E1).
admissionDefaults :: ObjectKey -> Value -> Value
admissionDefaults key value
  | key ^. #kind == "persistentvolumeclaim" && leafAt ["spec", "storageClassName"] value == Null = setLeaf ["spec", "storageClassName"] (String "local-path") value
  | otherwise = value

-- | Fields the API server's defaulting sets on every write: a Namespace's
-- @kubernetes.io/metadata.name@ label (RES-4 E1, E12).
withDefaults :: ObjectKey -> Value -> Value
withDefaults key value
  | key ^. #kind == "namespace" = setLeaf ["metadata", "labels", "kubernetes.io/metadata.name"] (String (key ^. #name)) value
  | otherwise = value

-- | Persist new content and ownership: resourceVersion moves when anything
-- changed, generation per the kind's rule; then the controller acts.
replaceContent :: ObjectKey -> Stored -> Value -> [FieldsEntry] -> ApiServer -> (ApiServer, Value)
replaceContent key stored content' managed' server
  | content' == stored ^. #content && managed' == stored ^. #managed = (server, render False stored)
  | otherwise =
      let generation' = case (stored ^. #generation, (^. #generationRule) <$> semanticsFor key) of
            (Just g, Just rule) | generationMoves rule (stored ^. #content) content' -> Just (g + 1)
            (current, _) -> current
          rolled = if templateOf content' /= templateOf (stored ^. #content) then withTemplateOutcome server content' else id
          stored' = rolled stored & #content .~ content' & #managed .~ managed' & #generation .~ generation' & #resourceVersion .~ nextResourceVersion server
          server' = controllerStep key (server & #objects %~ Map.insert key stored' & #nextResourceVersion %~ (+ 1))
       in (server', maybe Null (render False) (Map.lookup key (objects server')))

updateBy :: Text -> ObjectKey -> Stored -> Value -> ApiServer -> (ApiServer, Value)
updateBy managerName key stored content' server =
  let changed = Set.filter (\path -> lastSegment path /= "." && leafAt path content' /= leafAt path (stored ^. #content)) (leafSet content' <> leafSet (stored ^. #content))
      self entry = entry ^. #manager == managerName && entry ^. #operation == Update && isNothing (entry ^. #subresource)
      others = [entry & #fields %~ (`Set.difference` changed) | entry <- stored ^. #managed, not (self entry)]
      mine = maybe Set.empty (^. #fields) (find self (stored ^. #managed))
      containersOfChanged = Set.fromList [prefix <> ["."] | path <- Set.toList changed, n <- [1 .. length path - 1], let prefix = take n path, prefix /= ["metadata"]]
      managed' = normalizeEntries (others <> [FieldsEntry managerName Update Nothing (Set.filter (\path -> lastSegment path == "." || leafAt path content' /= Null) (mine <> changed <> containersOfChanged))])
   in replaceContent key stored content' managed' server

persistStatus :: Text -> ObjectKey -> Stored -> Value -> ApiServer -> ApiServer
persistStatus managerName key stored status' server
  | status' == stored ^. #status = server & #objects %~ Map.insert key stored
  | otherwise =
      let entry = FieldsEntry managerName Update (Just "status") (Set.map ("status" :) (leafSet status'))
          others = [e | e <- stored ^. #managed, not (e ^. #manager == managerName && e ^. #subresource == Just "status")]
       in server
            & #objects
            %~ Map.insert key (stored & #status .~ status' & #managed .~ normalizeEntries (others <> [entry]) & #resourceVersion .~ nextResourceVersion server)
            & #nextResourceVersion
            %~ (+ 1)

bumped :: ObjectKey -> Stored -> ApiServer -> ApiServer
bumped key stored server = server & #objects %~ Map.insert key (stored & #resourceVersion .~ nextResourceVersion server) & #nextResourceVersion %~ (+ 1)

normalizeEntries :: [FieldsEntry] -> [FieldsEntry]
normalizeEntries = sortOn (\entry -> (entry ^. #manager, entry ^. #operation, entry ^. #subresource)) . filter (not . Set.null . (^. #fields))

generationMoves :: GenerationRule -> Value -> Value -> Bool
generationMoves rule before after = case rule of
  NoGeneration -> False
  SpecOnly -> withoutMetadata before /= withoutMetadata after
  SpecAndAnnotations -> withoutMetadata before /= withoutMetadata after || annotations before /= annotations after
  where
    withoutMetadata = Object . KM.delete "metadata" . objectOf
    annotations = fieldPath ["metadata", "annotations"]

hasGeneration :: ObjectKey -> Bool
hasGeneration key = maybe False ((/= NoGeneration) . (^. #generationRule)) (semanticsFor key)

outcomeOf :: ApiServer -> Stored -> Outcome
outcomeOf = effectiveOutcome

-- | The outcome of the pod template the object runs: decided when a write
-- created the object or changed its template, by that write's stamp. A
-- write that leaves the template alone (an annotation, a label) rolls out
-- nothing, so it keeps the previous outcome.
effectiveOutcome :: ApiServer -> Stored -> Outcome
effectiveOutcome server stored = case Map.lookup "templateOutcome" (stored ^. #memory) of
  Just (String "Unready") -> Unready
  Just (String "Failed") -> Failed
  Just _ -> Good
  Nothing -> lookupOutcome server (stored ^. #content)

lookupOutcome :: ApiServer -> Value -> Outcome
lookupOutcome server content' = fromMaybe Good (Map.lookup (outcomeKey content') (outcomes server))

-- | What a controller rolls out: a workload's pod template, or else its spec.
templateOf :: Value -> Value
templateOf content' = case leafAt ["spec", "template"] content' of
  Null -> leafAt ["spec"] content'
  template -> template

withTemplateOutcome :: ApiServer -> Value -> Stored -> Stored
withTemplateOutcome server content' = #memory %~ Map.insert "templateOutcome" (String (tshow (lookupOutcome server content')))

-- | What 'outcomes' is keyed by: the object's @nagare.dev/spec-digest@ stamp,
-- or, for an unstamped object, its content without metadata.
outcomeKey :: Value -> Text
outcomeKey value = fromMaybe ("content:" <> tshow (Object (KM.delete "metadata" (objectOf value)))) (specDigestOf value)

-- | A new object must carry the fields its kind requires, or the API server
-- refuses it (422): a workload's selector and pod template, a CronJob's
-- schedule and Job template, a PVC's access modes and requested storage.
requireFields :: ObjectKey -> Value -> Either ApiRefusal ()
requireFields key value = case [path | path <- required, leafAt path value == Null] of
  [] -> Right ()
  missing ->
    Left (invalid ("The " <> kindName key <> " \"" <> key ^. #name <> "\" is invalid: " <> T.intercalate ", " [T.intercalate "." path <> ": Required value" | path <- missing]))
  where
    required = case (key ^. #group, key ^. #kind) of
      ("apps", "statefulset") -> [["spec", "selector"], ["spec", "template"]]
      ("apps", "deployment") -> [["spec", "selector"], ["spec", "template"]]
      ("batch", "job") -> [["spec", "template"]]
      ("batch", "cronjob") -> [["spec", "schedule"], ["spec", "jobTemplate"]]
      ("", "persistentvolumeclaim") -> [["spec", "accessModes"], ["spec", "resources", "requests", "storage"]]
      _ -> []

-- | Fields the API server refuses to change (422), as validated: a PVC's spec
-- while unbound (E1), a Job's template (E8), a StatefulSet's identity fields
-- and a Deployment's selector.
immutableViolation :: ObjectKey -> Value -> Value -> Maybe Text
immutableViolation key before after = case key ^. #kind of
  "persistentvolumeclaim"
    | changed ["spec"] -> Just "spec: Forbidden: spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims"
  "job"
    | changed ["spec", "template"] -> Just "spec.template: Invalid value: field is immutable"
  "statefulset"
    | any (changed . (\f -> ["spec", f])) ["selector", "serviceName", "volumeClaimTemplates", "podManagementPolicy"] ->
        Just "spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden"
  "deployment"
    | changed ["spec", "selector"] -> Just "spec.selector: Invalid value: field is immutable"
  _ -> Nothing
  where
    changed path = leafAt path before /= Null && leafAt path before /= leafAt path after

-- | The @nagare.dev/spec-digest@ stamp a reviewed write carries.
specDigestOf :: Value -> Maybe Text
specDigestOf = textAt ["metadata", "annotations", "nagare.dev/spec-digest"]

revisionOf :: Value -> Text
revisionOf template = T.take 10 (T.filter (`elem` ['0' .. '9']) (tshow (hashText (tshow template))))
  where
    hashText = T.foldl' (\h c -> (h * 33 + fromEnum c) `mod` 1000000007) (5381 :: Int)

-- | What a submitted object stores: everything but status and server-set
-- metadata.
contentOf :: Value -> Value
contentOf submitted =
  let root = KM.delete "status" (objectOf submitted)
      metadata = maybe KM.empty (KM.filterWithKey (\k _ -> k `elem` ["name", "namespace", "labels", "annotations"])) (objectField "metadata" submitted)
   in Object (KM.insert "metadata" (Object metadata) root)

-- | Paths a writer owns: every leaf but identity, with lists atomic, and the
-- map containers that hold them (as a trailing @"."@, the way managedFields
-- records them). A container is never a conflict, but it keeps its creator's
-- entry alive after a forced apply took every leaf (RES-4 E13).
leafSet :: Value -> Set.Set [Text]
leafSet value = Set.fromList (filter owned (map fst (leaves [] value)) <> containers)
  where
    owned path = path `notElem` [["apiVersion"], ["kind"], ["metadata", "name"], ["metadata", "namespace"]]
    containers =
      [ prefix <> ["."]
      | (path, _) <- leaves [] value
      , owned path
      , prefix <- drop 1 (inits' path)
      , prefix `notElem` [[], ["metadata"]]
      ]
    inits' path = [take n path | n <- [0 .. length path - 1]]

leaves :: [Text] -> Value -> [([Text], Value)]
leaves prefix = \case
  Object fields | not (KM.null fields) -> concat [leaves (prefix <> [Key.toText k]) v | (k, v) <- KM.toList fields]
  value -> [(prefix, value) | not (null prefix)]

leafAt :: [Text] -> Value -> Value
leafAt path value = foldl' (\v k -> fromMaybe Null (field k v)) value path

setLeaf :: [Text] -> Value -> Value -> Value
setLeaf path new value = case path of
  [] -> new
  k : rest -> Object (KM.insert (Key.fromText k) (setLeaf rest new (fromMaybe Null (field k value))) (objectOf value))

removeLeaf :: [Text] -> Value -> Value
removeLeaf path value = case path of
  [] -> value
  [k] -> Object (KM.delete (Key.fromText k) (objectOf value))
  k : rest -> case field k value of
    Just child -> Object (KM.insert (Key.fromText k) (removeLeaf rest child) (objectOf value))
    Nothing -> value

mergePatch :: Value -> Value -> Value
mergePatch target patch = case patch of
  Object fields -> Object (foldl' (\acc (k, v) -> if v == Null then KM.delete k acc else KM.insert k (mergePatch (fromMaybe Null (KM.lookup k acc)) v) acc) (objectOf target) (KM.toList fields))
  other -> other

pointer :: Text -> [Text]
pointer = map (T.replace "~1" "/" . T.replace "~0" "~") . filter (not . T.null) . T.splitOn "/"

-- * Refusals

invalid :: Text -> ApiRefusal
invalid = ApiRefusal 422 "Invalid"

notFound :: ObjectKey -> ApiRefusal
notFound key = ApiRefusal 404 "NotFound" (plural key <> " \"" <> key ^. #name <> "\" not found")

modified :: ObjectKey -> ApiRefusal
modified key = ApiRefusal 409 "Conflict" ("Operation cannot be fulfilled on " <> plural key <> " \"" <> key ^. #name <> "\": the object has been modified; please apply your changes to the latest version and try again")

preconditionFailed :: ObjectKey -> Text -> ApiRefusal
preconditionFailed key detail = ApiRefusal 409 "Conflict" ("Operation cannot be fulfilled on " <> kindName key <> " \"" <> key ^. #name <> "\": " <> detail)

applyConflict :: ObjectKey -> [(Text, [Text])] -> ApiRefusal
applyConflict key conflicts =
  let count = length conflicts
      owner = maybe "" fst (listToMaybe conflicts)
      noun = if count == 1 then "conflict" else "conflicts"
      paths = ["." <> T.intercalate "." path | (_, path) <- conflicts]
      -- One conflict stays on the first line; several follow it, one per line.
      listed = if count == 1 then " " <> T.concat paths else T.concat ["\n- " <> path | path <- paths]
   in ApiRefusal 409 "Conflict" ("Apply failed with " <> tshow count <> " " <> noun <> ": " <> noun <> " with \"" <> owner <> "\" using " <> apiVersionOf key <> ":" <> listed)

plural :: ObjectKey -> Text
plural key =
  let base = case key ^. #kind of
        "networkpolicy" -> "networkpolicies"
        other -> other <> "s"
   in if key ^. #group == "" then base else base <> "." <> key ^. #group

kindName :: ObjectKey -> Text
kindName key = case key ^. #kind of
  "configmap" -> "ConfigMap"
  "persistentvolumeclaim" -> "PersistentVolumeClaim"
  "statefulset" -> "StatefulSet"
  "service" | key ^. #group == "serving.knative.dev" -> "Service.serving.knative.dev"
  other -> T.toTitle other

apiVersionOf :: ObjectKey -> Text
apiVersionOf key = case key ^. #group of
  "" -> "v1"
  "serving.knative.dev" | key ^. #kind == "domainmapping" -> "serving.knative.dev/v1beta1"
  group' -> group' <> "/v1"

-- * JSON helpers

condition :: Text -> Text -> Maybe Text -> Value
condition conditionType conditionStatus reason' = object (["type" .= conditionType, "status" .= conditionStatus] <> ["reason" .= r | Just r <- [reason']])

lastSegment :: [Text] -> Text
lastSegment = maybe "" fst . uncons . reverse

arrayValues :: Value -> [Value]
arrayValues = \case
  Array values -> V.toList values
  _ -> []

boolText :: Bool -> Text
boolText b = if b then "True" else "False"

uidText :: Int -> Text
uidText n = "00000000-0000-4000-8000-" <> T.justifyRight 12 '0' (tshow n)

field :: Text -> Value -> Maybe Value
field key = \case
  Object fields -> KM.lookup (Key.fromText key) fields
  _ -> Nothing

fieldPath :: [Text] -> Value -> Value
fieldPath path value = leafAt path value

objectOf :: Value -> KM.KeyMap Value
objectOf = \case
  Object fields -> fields
  _ -> KM.empty

objectField :: Text -> Value -> Maybe (KM.KeyMap Value)
objectField key value = case field key value of
  Just (Object fields) -> Just fields
  _ -> Nothing

textField :: Text -> KM.KeyMap Value -> Maybe Text
textField key fields = case KM.lookup (Key.fromText key) fields of
  Just (String s) -> Just s
  _ -> Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = textValue (leafAt path value)

textValue :: Value -> Maybe Text
textValue = \case
  String s -> Just s
  _ -> Nothing

numberField :: Text -> Value -> Maybe Int
numberField key value = case field key value of
  Just (Number n) -> Just (round n)
  _ -> Nothing

boolField :: [Text] -> Value -> Bool
boolField path value = leafAt path value == Bool True

nubOrd :: (Ord a) => [a] -> [a]
nubOrd = Set.toList . Set.fromList

tshow :: (Show a) => a -> Text
tshow = T.pack . show
