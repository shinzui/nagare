-- | Resolve packaged Kubernetes source members during review preparation.
-- The exact bytes are retained in the private review; apply never reopens the
-- source file. Sources must resolve within the immutable platform workspace.
module Nagare.Inventory.KubernetesSources (loadKubernetesSources) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import System.Directory (canonicalizePath)
import System.FilePath (isRelative, makeRelative, splitDirectories, (</>))

loadKubernetesSources
  :: FilePath
  -> [ManagedResource]
  -> IO (Either Text (Map ResourceId (ManagedResource, BS.ByteString)))
loadKubernetesSources workspace declarations = do
  root <- canonicalizePath workspace
  loaded <- forM declarations (loadOne root)
  pure (Map.fromList <$> sequence loaded)
  where
    loadOne root declaration = case address declaration of
      Kubernetes cluster _ _ _ _ -> do
        let location = declaration ^. #source
            sourceFile = T.unpack (file location)
            (basePath, suffix) = T.breakOn "#document[" (path location)
        if T.null suffix || null sourceFile || not (isRelative sourceFile)
          then pure (Left "Kubernetes declaration lacks a packaged document source")
          else do
            canonical <- try (canonicalizePath (root </> sourceFile))
            case canonical of
              Left (_ :: IOException) -> pure (Left "Kubernetes source file is missing")
              Right fullPath
                | let relative = makeRelative root fullPath
                , not (isRelative relative) || ".." `elem` splitDirectories relative ->
                    pure (Left "Kubernetes source file escapes the platform workspace")
                | otherwise -> do
                    result <- try (BS.readFile fullPath) :: IO (Either IOException BS.ByteString)
                    pure $ do
                      bytes <- first (const "could not read packaged Kubernetes source") result
                      members <- first (T.pack . show) (parseKubernetesManifest (SourceLocation (file location) basePath) bytes)
                      value <- case [member | (memberSource, member) <- members, memberSource == location] of
                        [one] -> Right one
                        _ -> Left "Kubernetes source member is missing or duplicated"
                      native <- canonicalValue value
                      (recompiled, bound) <- first (T.pack . show) $ bindKubernetesObject
                        KubernetesInput
                          { resourceId = declaration ^. #identity
                          , ownerScope = declaration ^. #owner
                          , clusterId = cluster
                          , inputObject = value
                          , objectDigest = contentDigest native
                          , lifecyclePolicy = declaration ^. #lifecycle
                          , inputDataPolicy = declaration ^. #dataPolicy
                          , inputSensitivity = declaration ^. #sensitivity
                          , sourceLocation = location
                          }
                      unless (address recompiled == address declaration && spec recompiled == spec declaration && bound == native)
                        (Left "packaged Kubernetes source differs from the typed declaration")
                      pure (declaration ^. #identity, (declaration, bound))
      _ -> pure (Left "Kubernetes source loader received a non-Kubernetes resource")
