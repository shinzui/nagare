{-# LANGUAGE PackageImports #-}

-- | Shared managed-database discovery for the @nagarectl db@ commands
-- (MasterPlan 9, EP-45, Integration Point IP4).
--
-- This module owns the database label selector, the defensive
-- @kubectl get statefulset -o json@ parse, and the @db list@ table formatter. The
-- pure parts ('dbLabelSelector', 'extractDbRows', 'formatDbTable') are separated
-- from the @kubectl@ IO so they are unit-testable without a cluster. EP-47
-- (@docs/plans/47-...@) reuses 'listDatabases' / 'dbLabelSelector' / 'getDatabase'
-- to find the same databases by the same labels — it must extend, not fork, this
-- module.
--
-- A database's engine is read from the @nagare.dev/engine@ label EP-44 stamps;
-- its version/size/retention are read from the @nagare.dev/version@ /
-- @nagare.dev/size@ / @nagare.dev/retention@ annotations EP-45's @db create@
-- stamps (with fallbacks: version from the container image tag, size @"?"@,
-- retention @Retain@).
module Nagare.Database.Discover
  ( dbLabelSelector
  , DbRow (..)
  , extractDbRows
  , listDatabases
  , getDatabase
  , lookupConnection
  , formatDbTable
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Database.Connection (ConnIdentity (..))
import Nagare.Dsl.Database (Engine (..), dbSecretName, parseEngine)
import Nagare.Env.Store (extractSecretData)
import System.Exit (ExitCode (..))

-- | The label selector that finds every Nagare-managed database StatefulSet
-- (IP3/IP4): managed by nagarectl AND carrying the @nagare.dev/database@ label.
-- EP-47 queries by this same selector — never by re-deriving names.
dbLabelSelector :: Text
dbLabelSelector = "nagare.dev/managed-by=nagarectl,nagare.dev/database"

-- | One discovered managed database, read back from its StatefulSet.
data DbRow = DbRow
  { drName :: !Text
  , drEngine :: !Text
  , drVersion :: !Text
  , drSize :: !Text
  , drRetention :: !Text
  , drHost :: !Text
  , drReady :: !Bool
  }
  deriving stock (Generic, Eq, Show)

-- | Parse a @kubectl get statefulset -n <ns> -l <dbLabelSelector> -o json@ list
-- into rows. Defensive (mirrors @Nagare.Storage.Discover.extractPVCStatus@): an
-- empty/absent @items@ array is @Right []@, a malformed top-level shape is a
-- 'Left', and an item with no @.metadata.name@ is skipped rather than fatal.
extractDbRows :: ByteString -> Either Text [DbRow]
extractDbRows bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode statefulset list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> Right (foldr step [] (V.toList items))
      _ -> Right []
  where
    step item acc = case rowFromItem item of
      Just r -> r : acc
      Nothing -> acc

rowFromItem :: Aeson.Value -> Maybe DbRow
rowFromItem item = do
  name <- textAt ["metadata", "name"] item
  let ns = fromMaybe "personal" (textAt ["metadata", "namespace"] item)
  pure
    DbRow
      { drName = name
      , drEngine = fromMaybe "?" (labelAt "nagare.dev/engine" item)
      , drVersion =
          fromMaybe
            (versionFromImage item)
            (annotationAt "nagare.dev/version" item)
      , drSize = fromMaybe "?" (annotationAt "nagare.dev/size" item)
      , drRetention = fromMaybe "Retain" (annotationAt "nagare.dev/retention" item)
      , drHost = name <> "." <> ns <> ".svc.cluster.local"
      , drReady = readyReplicas item >= 1
      }

-- | Best-effort version from the first container's image tag (text after the
-- last @:@). @"?"@ when the image or tag is absent.
versionFromImage :: Aeson.Value -> Text
versionFromImage item =
  case firstContainerImage item of
    Just img | T.elem ':' img -> T.takeWhileEnd (/= ':') img
    _ -> "?"

firstContainerImage :: Aeson.Value -> Maybe Text
firstContainerImage item =
  case lookupPath ["spec", "template", "spec", "containers"] item of
    Just (Aeson.Array cs) | not (V.null cs) -> textAt ["image"] (V.head cs)
    _ -> Nothing

readyReplicas :: Aeson.Value -> Int
readyReplicas item =
  case lookupPath ["status", "readyReplicas"] item of
    Just (Aeson.Number n) -> truncate n
    _ -> 0

-- | List managed databases in @ns@ via @kubectl get statefulset -l <selector> -o
-- json@. A failed query (e.g. missing namespace, unreachable cluster) is
-- @Right []@; a present-but-malformed response is a 'Left'.
listDatabases :: Text -> IO (Either Text [DbRow])
listDatabases ns = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "statefulset"
          , "-n"
          , T.unpack ns
          , "-l"
          , T.unpack dbLabelSelector
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Right []
    ExitSuccess -> extractDbRows out

-- | Look up a single database by name in @ns@. @Left@ with a clear message when
-- no managed database of that name exists.
getDatabase :: Text -> Text -> IO (Either Text DbRow)
getDatabase ns name = do
  rows <- listDatabases ns
  pure $ case rows of
    Left e -> Left e
    Right rs -> case find ((== name) . drName) rs of
      Just r -> Right r
      Nothing -> Left ("no managed database named '" <> name <> "' in namespace " <> ns)

-- | Resolve a referenced database (MasterPlan 9, EP-46) to its 'Engine' and the
-- non-secret 'ConnIdentity' (application user and, for Postgres, the logical db),
-- for connection-env injection. The engine comes from the StatefulSet's
-- @nagare.dev/engine@ label (via 'getDatabase'); the user/db are read from the
-- managed Secret's non-secret keys (the authoritative values EP-45 wrote). A
-- 'Left' (not found / unreachable / unknown engine) makes the deploy fail with a
-- clear message rather than render a half-wired Service.
lookupConnection :: Text -> Text -> IO (Either Text (Engine, ConnIdentity))
lookupConnection ns name = do
  erow <- getDatabase ns name
  case erow of
    Left err ->
      pure
        ( Left
            ( err
                <> " (run `nagarectl db create <engine> "
                <> name
                <> "` first, or check the namespace)"
            )
        )
    Right r -> case parseEngine (drEngine r) of
      Nothing -> pure (Left ("database '" <> name <> "' has an unknown engine: " <> drEngine r))
      Just eng -> do
        kvs <- readSecretMap ns name
        pure (Right (eng, identityFor eng kvs))

-- | Build a 'ConnIdentity' from the engine and the Secret's decoded key/value
-- map (absent keys fall back to 'Nothing').
identityFor :: Engine -> Map.Map Text Text -> ConnIdentity
identityFor Postgres kvs =
  ConnIdentity {connUser = Map.lookup "POSTGRES_USER" kvs, connDb = Map.lookup "POSTGRES_DB" kvs}
identityFor Redis _ = ConnIdentity {connUser = Nothing, connDb = Nothing}
identityFor ClickHouse kvs =
  ConnIdentity {connUser = Map.lookup "CLICKHOUSE_USER" kvs, connDb = Nothing}

-- | Read the managed Secret's decoded data map (empty on any failure).
readSecretMap :: Text -> Text -> IO (Map.Map Text Text)
readSecretMap ns name = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs ["get", "secret", T.unpack (dbSecretName name), "-n", T.unpack ns, "-o", "json"]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Map.empty
    ExitSuccess -> either (const Map.empty) id (extractSecretData out)

-- | Render the @db list@ table with @pad@-aligned columns.
formatDbTable :: [DbRow] -> Text
formatDbTable [] = "(no managed databases)\n"
formatDbTable rows = T.unlines (header : map line rows)
  where
    header =
      "  "
        <> pad 16 "NAME"
        <> pad 12 "ENGINE"
        <> pad 10 "VERSION"
        <> pad 8 "SIZE"
        <> pad 8 "STATUS"
        <> "HOST"
    line r =
      T.concat
        [ "  "
        , pad 16 (drName r)
        , pad 12 (drEngine r)
        , pad 10 (drVersion r)
        , pad 8 (drSize r)
        , pad 8 (if drReady r then "Ready" else "Pending")
        , drHost r
        ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- JSON walking (local copies; mirror Nagare.Storage.Discover's private helpers)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

labelAt :: Text -> Aeson.Value -> Maybe Text
labelAt key = textAt ["metadata", "labels", key]

annotationAt :: Text -> Aeson.Value -> Maybe Text
annotationAt key = textAt ["metadata", "annotations", key]
