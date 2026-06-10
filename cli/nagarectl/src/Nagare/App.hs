{-# LANGUAGE PackageImports #-}

-- | Application lifecycle helpers for the @nagarectl app@ commands (EP-30).
--
-- This module owns the shared @kubectl@ plumbing and the pure parse/format
-- helpers behind @app list/get/logs/restart/stop/delete@. The pure parts
-- ('parseServiceNames', 'logArgs', 'restartPatch', 'extractAppSummary',
-- 'extractAppSummaries', 'formatAppList') are separated from the @kubectl@ IO so
-- they are unit-testable without a cluster.
--
-- Integration points (MasterPlan 6): 'streamServiceLogs' and 'appIdentityOrDie'
-- are reused by the sibling @deployments@ commands
-- (@docs/plans/31-application-deployment-history-and-deployments-commands.md@);
-- 'restartApp'/'stopApp'/'deleteApp' implement the lifecycle semantics fixed in
-- the MasterPlan Decision Log.
module Nagare.App
  ( -- * Identity
    appIdentityOrDie

    -- * Log streaming
  , LogTarget (..)
  , streamServiceLogs
  , logArgs

    -- * Live-state queries
  , AppSummary (..)
  , listManagedApps
  , listAppSummaries
  , getAppSummary
  , extractAppSummary
  , extractAppSummaries
  , parseServiceNames
  , formatAppList

    -- * Lifecycle operations
  , restartApp
  , restartPatch
  , stopApp
  , deleteApp
  , appDomains
  , extractDomainsFor
  ) where

import Nagare.Dsl.Prelude

import "generic-lens" Data.Generics.Labels ()

import Cradle
import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Nagare.Dsl.Load qualified as Load
import Nagare.Dsl.Types (namespaceText, serviceNameText)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)

-- ---------------------------------------------------------------------------
-- Identity

-- | Print @nagarectl: \<msg\>@ to stderr and exit non-zero. A local copy of the
-- tiny die helper in @app/Main.hs@ so this library module stays self-contained.
dieApp :: Text -> IO a
dieApp msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

-- | Load a 'Nagare.Dsl.Types.Deployment' config and return its
-- @(name, namespace)@. Mirrors @siteIdentityOrDie@ in @app/Main.hs@ but for the
-- app (Deployment) path. On a load failure, prints the rendered 'Load.LoadError'
-- and exits non-zero. (IP2: consumed by the sibling @deployments@ commands.)
appIdentityOrDie :: FilePath -> IO (Text, Text)
appIdentityOrDie file = do
  edep <- Load.loadDeployment file
  case edep of
    Right dep -> pure (serviceNameText (dep ^. #name), namespaceText (dep ^. #namespace))
    Left err -> dieApp (Load.renderLoadError err)

-- ---------------------------------------------------------------------------
-- Log streaming

-- | What to stream logs for: a Service in a namespace, optionally pinned to one
-- revision, optionally following, optionally tail-limited.
data LogTarget = LogTarget
  { ltNamespace :: !Text
  , ltService :: !Text
  , ltRevision :: !(Maybe Text)
  , ltFollow :: !Bool
  , ltTail :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

-- | The @kubectl logs@ argument vector for a 'LogTarget'. Pure so it is unit
-- testable. Selects pods by @serving.knative.dev/service=\<name\>@ (plus
-- @serving.knative.dev/revision=\<rev\>@ when a revision is pinned) and reads the
-- @user-container@.
logArgs :: LogTarget -> [String]
logArgs t =
  [ "logs"
  , "-l"
  , T.unpack (selector t)
  , "-n"
  , T.unpack (ltNamespace t)
  , "-c"
  , "user-container"
  ]
    <> maybe [] (\n -> ["--tail", show n]) (ltTail t)
    <> ["--follow" | ltFollow t]
  where
    selector x =
      "serving.knative.dev/service="
        <> ltService x
        <> maybe "" (\r -> ",serving.knative.dev/revision=" <> r) (ltRevision x)

-- | Stream (or print) a Knative Service's user-container logs, inheriting the
-- child's stdout/stderr so @--follow@ tails live. (IP2: the sibling
-- @deployments logs@ command reuses this by passing a 'ltRevision'.)
streamServiceLogs :: LogTarget -> IO ()
streamServiceLogs t = run_ $ cmd "kubectl" & addArgs (logArgs t)

-- ---------------------------------------------------------------------------
-- Live-state queries

-- | A one-line summary of a deployed app's live Knative state.
data AppSummary = AppSummary
  { asName :: !Text
  , asUrl :: !(Maybe Text)
  , asReady :: !(Maybe Bool)
  , asLatestRevision :: !(Maybe Text)
  , asImage :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Split @kubectl get … -o name@ output into Service names: one per line, blanks
-- dropped, the @service.serving.knative.dev/@ resource prefix stripped. Pure and
-- unit tested.
parseServiceNames :: Text -> [Text]
parseServiceNames out =
  [ stripResourcePrefix line
  | line <- T.lines out
  , not (T.null (T.strip line))
  ]
  where
    -- kubectl `-o name` prints e.g. "service.serving.knative.dev/<name>".
    stripResourcePrefix line = case T.breakOnEnd "/" line of
      (_, n) -> T.strip n

-- | List Nagare-managed app Service names in @ns@ via
-- @kubectl get ksvc -n \<ns\> [-l nagare.dev/managed-by=nagarectl] -o name@. With
-- @allUnfiltered = True@ the label selector is dropped (lists every Knative
-- Service). Returns @[]@ when the namespace has none or the query fails.
listManagedApps :: Text -> Bool -> IO [Text]
listManagedApps ns allUnfiltered = do
  (exitCode, StdoutUntrimmed out) <-
    run $
      cmd "kubectl"
        & addArgs (["get", "ksvc", "-n", T.unpack ns] <> labelArgs <> ["-o", "name"])
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> []
    ExitSuccess -> parseServiceNames out
  where
    labelArgs = if allUnfiltered then [] else ["-l", "nagare.dev/managed-by=nagarectl"]

-- | The label selector args for @app list@ (empty when unfiltered).
listLabelArgs :: Bool -> [String]
listLabelArgs allUnfiltered =
  if allUnfiltered then [] else ["-l", "nagare.dev/managed-by=nagarectl"]

-- | List app summaries in @ns@ in a single @kubectl get ksvc … -o json@ call,
-- mapping 'extractAppSummary' over @.items@. With @allUnfiltered = True@ the
-- managed-by label selector is dropped. A failed query (e.g. missing namespace)
-- yields @Right []@; a present-but-malformed response is a 'Left'.
listAppSummaries :: Text -> Bool -> IO (Either Text [AppSummary])
listAppSummaries ns allUnfiltered = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs (["get", "ksvc", "-n", T.unpack ns] <> listLabelArgs allUnfiltered <> ["-o", "json"])
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Right []
    ExitSuccess -> extractAppSummaries out

-- | Fetch one app's summary via @kubectl get ksvc \<name\> -n \<ns\> -o json@. A
-- non-zero exit (no such Service) is reported as @Left "no such app: \<name\>"@.
getAppSummary :: Text -> Text -> IO (Either Text AppSummary)
getAppSummary ns name = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "ksvc", T.unpack name, "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Left ("no such app: " <> name)
    ExitSuccess -> extractAppSummary out

-- | Decode one Knative Service JSON object into an 'AppSummary'. Defensive: a
-- malformed shape is a 'Left', never a crash. Pure and unit tested.
extractAppSummary :: ByteString -> Either Text AppSummary
extractAppSummary bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode service JSON: " <> T.pack e)
    Right v -> summaryFromValue v

-- | Decode a @kubectl get ksvc … -o json@ list response (an object with an
-- @items@ array) into summaries, one per item. Pure and unit tested.
extractAppSummaries :: ByteString -> Either Text [AppSummary]
extractAppSummaries bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode service list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> traverse summaryFromValue (V.toList items)
      _ -> Right [] -- an empty list response has no/empty items

-- | Pull an 'AppSummary' out of one decoded Service 'Aeson.Value'.
summaryFromValue :: Aeson.Value -> Either Text AppSummary
summaryFromValue v =
  case textAt ["metadata", "name"] v of
    Nothing -> Left "service JSON missing .metadata.name"
    Just name ->
      Right
        AppSummary
          { asName = name
          , asUrl = textAt ["status", "url"] v
          , asReady = readyOf v
          , asLatestRevision = textAt ["status", "latestReadyRevisionName"] v
          , asImage = imageOf v
          }

-- | The first container's image, from @.spec.template.spec.containers[0].image@.
imageOf :: Aeson.Value -> Maybe Text
imageOf v = do
  Aeson.Array cs <- lookupPath ["spec", "template", "spec", "containers"] v
  first <- cs V.!? 0
  textAt ["image"] first

-- | Whether the Service's @Ready@ condition is @"True"@, from
-- @.status.conditions[] | select(.type=="Ready") | .status@. 'Nothing' when no
-- Ready condition is present yet.
readyOf :: Aeson.Value -> Maybe Bool
readyOf v = do
  Aeson.Array conds <- lookupPath ["status", "conditions"] v
  cond <- find (\c -> textAt ["type"] c == Just "Ready") (V.toList conds)
  st <- textAt ["status"] cond
  pure (st == "True")

-- | Walk a chain of object keys, returning the value at the end (or 'Nothing' if
-- any key is missing or a non-object is hit).
lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

-- | The 'Text' at an object path, or 'Nothing'.
textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

-- | Format app summaries as an aligned @NAME / READY / URL@ table. Pure and unit
-- tested.
formatAppList :: [AppSummary] -> Text
formatAppList [] = "(no apps)\n"
formatAppList apps = T.unlines (header : map row apps)
  where
    header = "  " <> pad 18 "NAME" <> pad 8 "READY" <> "URL"
    row a =
      T.concat
        [ "  "
        , pad 18 (asName a)
        , pad 8 (maybe "?" boolText (asReady a))
        , fromMaybe "-" (asUrl a)
        ]
    boolText True = "True"
    boolText False = "False"
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- Lifecycle operations

-- | A JSON merge patch that forces a fresh Knative revision (by stamping a
-- Nagare-owned @spec.template.metadata.annotations.nagare.dev/restartedAt@) and
-- clears the @networking.knative.dev/visibility@ label (a @null@ value in a merge
-- patch deletes the key), so a restart also brings a stopped app back online.
-- Pure and unit tested.
restartPatch :: Text -> Text
restartPatch stamp =
  "{\"metadata\":{\"labels\":{\"networking.knative.dev/visibility\":null}},"
    <> "\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"nagare.dev/restartedAt\":\""
    <> stamp
    <> "\"}}}}}"

-- | Roll a fresh revision for @name@ in @ns@ by applying 'restartPatch' (whose
-- @stamp@ the caller supplies, keeping this clock-free).
restartApp :: Text -> Text -> Text -> IO ()
restartApp ns name stamp =
  run_ $
    cmd "kubectl"
      & addArgs
        ["patch", "ksvc", T.unpack name, "-n", T.unpack ns, "--type=merge", "-p", T.unpack (restartPatch stamp)]

-- | Take @name@ offline (recoverably) by labelling its Service
-- @networking.knative.dev/visibility: cluster-local@, which removes the public
-- route. Reversed by 'restartApp' or @nagarectl deploy@.
stopApp :: Text -> Text -> IO ()
stopApp ns name =
  run_ $
    cmd "kubectl"
      & addArgs
        [ "patch"
        , "ksvc"
        , T.unpack name
        , "-n"
        , T.unpack ns
        , "--type=merge"
        , "-p"
        , "{\"metadata\":{\"labels\":{\"networking.knative.dev/visibility\":\"cluster-local\"}}}"
        ]

-- | Delete an app: its Service, each named DomainMapping, and its
-- deployment-history ConfigMap (@nagare-app-deployments-\<name\>@, owned by EP-31).
-- Every call uses @--ignore-not-found@ so a repeat (or a missing history store) is
-- a clean no-op.
deleteApp :: Text -> Text -> [Text] -> IO ()
deleteApp ns name domains = do
  run_ $
    cmd "kubectl"
      & addArgs ["delete", "ksvc", T.unpack name, "-n", T.unpack ns, "--ignore-not-found"]
  forM_ domains $ \d ->
    run_ $
      cmd "kubectl"
        & addArgs ["delete", "domainmapping", T.unpack d, "-n", T.unpack ns, "--ignore-not-found"]
  run_ $
    cmd "kubectl"
      & addArgs
        ["delete", "configmap", T.unpack ("nagare-app-deployments-" <> name), "-n", T.unpack ns, "--ignore-not-found"]

-- | The DomainMapping hostnames pointing at Service @name@ in @ns@, discovered
-- from the cluster via @kubectl get domainmapping -n \<ns\> -o json@ (those whose
-- @.spec.ref.name == name@). Used by @app delete@ when no config file is given.
appDomains :: Text -> Text -> IO [Text]
appDomains ns name = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "domainmapping", "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> []
    ExitSuccess -> either (const []) id (extractDomainsFor name out)

-- | The DomainMapping names (@.metadata.name@) whose @.spec.ref.name@ equals
-- @name@, from a @kubectl get domainmapping … -o json@ list. Pure.
extractDomainsFor :: Text -> ByteString -> Either Text [Text]
extractDomainsFor name bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode domainmapping list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) ->
        Right
          [ dn
          | item <- V.toList items
          , textAt ["spec", "ref", "name"] item == Just name
          , Just dn <- [textAt ["metadata", "name"] item]
          ]
      _ -> Right []
