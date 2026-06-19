-- | The typed multi-workload application aggregate (MasterPlan 14, EP-1). An
-- 'Application' is the layer /above/ a single workload: it names an app once and
-- bundles an optional web 'Nagare.Dsl.Types.Deployment' (the request-driven HTTP
-- Service), a list of 'Nagare.Dsl.Worker.Worker's, a list of managed
-- 'Nagare.Dsl.Database.Database's, and a list of 'Nagare.Dsl.Task.Task's. The
-- shared **image**, **env/secret set**, and **database bindings** are declared
-- once here and validated to flow down consistently to every workload.
--
-- There is no hidden constructor for 'Application' — like
-- 'Nagare.Dsl.Types.Deployment' / 'Nagare.Dsl.Worker.Worker' /
-- 'Nagare.Dsl.Database.Database', the per-workload safety comes from the field
-- types, each already smart-constructed by its own module. What a single
-- workload's constructor cannot see — the /cross-workload/ invariants (every
-- workload agreeing on the shared image and namespace, every referenced database
-- being declared, no two workloads sharing a name) — is enforced by
-- 'mkApplication', exactly as 'Nagare.Dsl.Task.mkTask' enforces a 'Task'\'s
-- cross-field invariant.
--
-- This module composes the proven workload types unchanged; it does not redefine
-- or wrap them. Any future field on a 'Worker' (e.g. EP-3's liveness probe,
-- @docs/plans/74-worker-health-and-liveness-probes.md@) therefore flows through
-- the aggregate automatically. This module must NOT import "Nagare.Dsl.Config"
-- or "Nagare.Dsl.Load" (those depend on it), so there is no import cycle.
module Nagare.Dsl.Application
  ( -- * Application
    Application (..)
  , mkApplication

    -- * Shared-identity label
  , appLabelKey
  , appLabel
  ) where

import Data.Generics.Labels ()

import Nagare.Dsl.Prelude

import Data.Map (Map)
import Data.Set qualified as Set
import Nagare.Dsl.Database (Database (..), databaseNameText)
import Nagare.Dsl.Task (Task (..))
import Nagare.Dsl.Types
  ( DatabaseName
  , Deployment (..)
  , EnvName
  , ImageRef
  , Namespace
  , ScopedEnvVar
  , ServiceName
  , imageRefText
  , namespaceText
  , serviceNameText
  )
import Nagare.Dsl.Worker (Worker (..))

-- | A multi-workload application: one shared identity that bundles an optional
-- web Service, a list of Workers, a list of managed Databases, and a list of
-- Tasks, with the image / env / database bindings declared ONCE here and
-- validated to agree with every embedded workload. There is no hidden
-- constructor; the safety guarantee comes from the field types plus the
-- cross-workload invariants enforced by 'mkApplication'.
data Application = Application
  { appName :: !ServiceName
  -- ^ the shared identity; the value of the 'nagare.dev/app' label.
  , namespace :: !Namespace
  -- ^ the shared namespace; every embedded workload must agree (re-checked).
  , image :: !ImageRef
  -- ^ the shared image repository, declared once; every embedded workload's
  -- own image must equal this (the 'image agreement' invariant).
  , env :: !(Map EnvName ScopedEnvVar)
  -- ^ the shared env/secret set declared once on the app. EP-2 fans this down
  -- into every rendered object; the type carries it as the single source of
  -- truth and does not duplicate it into each embedded workload's JSON.
  , appDatabases :: ![Database]
  -- ^ the managed databases this app owns. A workload may only reference a
  -- database whose 'dbName' appears here (the 'declared databases' invariant).
  , service :: !(Maybe Deployment)
  -- ^ the optional request-driven web Service. 'Nothing' for an app with no
  -- HTTP front (e.g. workers + a migration task only).
  , workers :: ![Worker]
  -- ^ the background workers. Carried AS-IS so EP-3's liveness field flows
  -- through automatically.
  , tasks :: ![Task]
  -- ^ co-located tasks (e.g. a migration task that EP-2 runs as a pre-deploy
  -- hook). A task that inherits the app image has taskImage = Nothing and
  -- taskApp = Just appName.
  }
  deriving stock (Generic, Eq, Show)

-- | The shared-identity label KEY every object an 'Application' renders carries.
-- Introduced here (EP-1); stamped onto rendered objects by EP-2. Defined once in
-- the type module so the renderer (EP-2) and the discovery side (kotei) share a
-- single definition rather than a stringly-typed copy.
appLabelKey :: Text
appLabelKey = "nagare.dev/app"

-- | The (key, value) shared-identity label for an 'Application':
-- @("nagare.dev/app", \<appName\>)@.
appLabel :: Application -> (Text, Text)
appLabel app = (appLabelKey, serviceNameText (appName app))

-- | Validate an assembled 'Application', enforcing the three cross-workload
-- invariants a single workload's own constructor cannot see, plus a cheap
-- namespace-agreement check. Returns the value unchanged on success (mirroring
-- 'Nagare.Dsl.Task.mkTask' / 'Nagare.Dsl.Types.mkScale').
--
--   1. **Image agreement** — every embedded workload's @image@ must equal the
--      'Application'\'s shared @image@ (an image-inheriting task, which pins no
--      image of its own, is exempt).
--   2. **Declared databases** — every 'DatabaseName' any workload references via
--      its @databases@ field must appear in 'appDatabases' (matched by 'dbName').
--   3. **Unique names** — no two embedded workloads (service + workers + tasks)
--      share a 'ServiceName', and no two managed databases share a
--      'DatabaseName'. Workload names and database names live in separate
--      spaces, matching the rest of the DSL.
--   4. **Namespace agreement** — every embedded workload's @namespace@ must
--      equal the 'Application'\'s @namespace@ (belt-and-braces; one comparison
--      per workload, prevents a class of confusing partial deploys).
mkApplication :: Application -> Either Text Application
mkApplication app = do
  checkImageAgreement app
  checkDeclaredDatabases app
  checkUniqueNames app
  checkNamespaceAgreement app
  Right app

-- | The (workload-name, own-image) pair of every workload that pins an image:
-- the service (when present), each worker, and each task that carries its own
-- 'taskImage' (an inheriting task pins no image and is omitted).
workloadImages :: Application -> [(Text, ImageRef)]
workloadImages app =
  [(serviceNameText (svc ^. #name), svc ^. #image) | Just svc <- [app ^. #service]]
    <> [(serviceNameText (w ^. #name), w ^. #image) | w <- app ^. #workers]
    <> [ (serviceNameText (t ^. #taskName), img)
       | t <- app ^. #tasks
       , Just img <- [t ^. #taskImage]
       ]

checkImageAgreement :: Application -> Either Text ()
checkImageAgreement app =
  case filter (\(_, img) -> img /= shared) (workloadImages app) of
    [] -> Right ()
    ((nm, img) : _) ->
      Left
        ( "workload '"
            <> nm
            <> "' declares image '"
            <> imageRefText img
            <> "' but the application's shared image is '"
            <> imageRefText shared
            <> "'"
        )
  where
    shared = app ^. #image

-- | Every 'DatabaseName' any serving workload references (the service and each
-- worker carry a @databases@ field; tasks do not).
referencedDatabases :: Application -> [DatabaseName]
referencedDatabases app =
  maybe [] (^. #databases) (app ^. #service)
    <> concatMap (^. #databases) (app ^. #workers)

checkDeclaredDatabases :: Application -> Either Text ()
checkDeclaredDatabases app =
  case filter (\ref -> databaseNameText ref `Set.notMember` declared) (referencedDatabases app) of
    [] -> Right ()
    (ref : _) ->
      Left
        ( "workload references database '"
            <> databaseNameText ref
            <> "' which is not declared on the application"
        )
  where
    declared =
      Set.fromList (map (\db -> databaseNameText (db ^. #dbName)) (app ^. #appDatabases))

checkUniqueNames :: Application -> Either Text ()
checkUniqueNames app =
  case firstDuplicate workloadNames of
    Just dup -> Left ("duplicate workload name: " <> dup)
    Nothing -> case firstDuplicate dbNames of
      Just dup -> Left ("duplicate database name: " <> dup)
      Nothing -> Right ()
  where
    workloadNames =
      [serviceNameText (svc ^. #name) | Just svc <- [app ^. #service]]
        <> map (\w -> serviceNameText (w ^. #name)) (app ^. #workers)
        <> map (\t -> serviceNameText (t ^. #taskName)) (app ^. #tasks)
    dbNames = map (\db -> databaseNameText (db ^. #dbName)) (app ^. #appDatabases)

checkNamespaceAgreement :: Application -> Either Text ()
checkNamespaceAgreement app =
  case filter (\(_, ns) -> ns /= shared) workloadNamespaces of
    [] -> Right ()
    ((nm, ns) : _) ->
      Left
        ( "workload '"
            <> nm
            <> "' is in namespace '"
            <> namespaceText ns
            <> "' but the application's namespace is '"
            <> namespaceText shared
            <> "'"
        )
  where
    shared = app ^. #namespace
    workloadNamespaces =
      [(serviceNameText (svc ^. #name), svc ^. #namespace) | Just svc <- [app ^. #service]]
        <> map (\w -> (serviceNameText (w ^. #name), w ^. #namespace)) (app ^. #workers)
        <> map (\t -> (serviceNameText (t ^. #taskName), t ^. #taskNamespace)) (app ^. #tasks)

-- | The first element that appears more than once in the list, in order, or
-- 'Nothing' when all elements are unique. (Mirrors the helper in
-- "Nagare.Dsl.Load"; copied here to keep this module free of a load dependency.)
firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `Set.member` seen = Just x
      | otherwise = go (Set.insert x seen) xs
