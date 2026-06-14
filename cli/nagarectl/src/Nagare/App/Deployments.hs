-- | Per-app deployment history (EP-31).
--
-- Applications get the same release history static sites already have: every
-- successful @nagarectl deploy@ records a deployment in a per-app Kubernetes
-- ConfigMap, and @nagarectl deployments list/logs@ read it. Rather than duplicate
-- the proven store, this module reuses the pure layer and the prefix-parameterized
-- IO of 'Nagare.Static.Release' under a distinct ConfigMap-name prefix
-- (@"nagare-app-deployments-"@), and adds the deployment-id → Knative-revision
-- mapping that @deployments logs NAME ID@ needs.
module Nagare.App.Deployments
  ( appDeploymentsPrefix
  , appConfigMapName
  , readDeployments
  , writeDeployments
  , recordDeploymentFor
  , findDeployment
  , formatDeploymentsTable
  , resolveRevisionForTag
  , revisionForTag
  ) where

import Nagare.Dsl.Prelude

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Static.Release
  ( StaticRelease
  , StaticReleaseLog
  , configMapNameWith
  , findRelease
  , formatReleasesTable
  , readReleaseLogWith
  , recordReleaseForWith
  , writeReleaseLogWith
  )
import System.Exit (ExitCode (..))

-- | The ConfigMap-name prefix for app deployment histories. The full name is
-- @"nagare-app-deployments-" <> app@; this is the contract
-- @nagarectl app delete@ deletes (see @cli/nagarectl/src/Nagare/App.hs@).
appDeploymentsPrefix :: Text
appDeploymentsPrefix = "nagare-app-deployments-"

-- | The ConfigMap name holding an app's deployment history, e.g.
-- @"nagare-app-deployments-notes"@.
appConfigMapName :: Text -> Text
appConfigMapName = configMapNameWith appDeploymentsPrefix

-- | Read an app's deployment history. A missing ConfigMap is an empty log; a
-- present-but-malformed one is a 'Left'.
readDeployments :: Text -> Text -> IO (Either Text StaticReleaseLog)
readDeployments = readReleaseLogWith appDeploymentsPrefix

-- | Persist an app's deployment history.
writeDeployments :: Text -> Text -> StaticReleaseLog -> IO ()
writeDeployments = writeReleaseLogWith appDeploymentsPrefix

-- | Record a deployment for @(image, tag, url, name, ns, source)@ (newest-first,
-- deduped on id, capped). Non-fatal: a malformed existing history is returned as
-- a 'Left' and not overwritten.
recordDeploymentFor :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> IO (Either Text ())
recordDeploymentFor = recordReleaseForWith appDeploymentsPrefix

-- | Find one deployment by id (re-export of 'findRelease').
findDeployment :: Text -> StaticReleaseLog -> Maybe StaticRelease
findDeployment = findRelease

-- | Format the deployment history as a table (re-export of 'formatReleasesTable').
formatDeploymentsTable :: StaticReleaseLog -> Text
formatDeploymentsTable = formatReleasesTable

-- ---------------------------------------------------------------------------
-- Deployment id -> Knative revision

-- | Resolve a deployment id (an image tag) to the Knative revision name whose
-- container image carries that tag, for app @name@ in @ns@, via
-- @kubectl get revisions -n \<ns\> -l serving.knative.dev/service=\<name\> -o json@.
-- 'Nothing' when no current revision matches (e.g. Knative garbage-collected it).
resolveRevisionForTag :: Text -> Text -> Text -> IO (Maybe Text)
resolveRevisionForTag ns name tag = do
  (exitCode, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "revisions"
          , "-n"
          , T.unpack ns
          , "-l"
          , "serving.knative.dev/service=" <> T.unpack name
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case exitCode of
    ExitFailure _ -> Nothing
    ExitSuccess -> revisionForTag tag out

-- | Pure core of 'resolveRevisionForTag': from a @kubectl get revisions … -o json@
-- list, return the @.metadata.name@ of the item whose
-- @.spec.containers[0].image@ ends with @":\<tag\>"@. 'Nothing' on a decode
-- failure or no match. Unit tested.
revisionForTag :: Text -> ByteString -> Maybe Text
revisionForTag tag bs = do
  v <- either (const Nothing) Just (eitherDecodeStrict bs :: Either String Aeson.Value)
  Aeson.Array items <- lookupPath ["items"] v
  item <- find matches (V.toList items)
  textAt ["metadata", "name"] item
  where
    matches item = case revisionImage item of
      Just img -> (":" <> tag) `T.isSuffixOf` img
      Nothing -> False
    revisionImage item = do
      Aeson.Array cs <- lookupPath ["spec", "containers"] item
      c0 <- cs V.!? 0
      textAt ["image"] c0

-- | Walk a chain of object keys to the value at the end (or 'Nothing').
lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

-- | The 'Text' at an object path, or 'Nothing'.
textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing
