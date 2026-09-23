-- | Resolve packaged Kubernetes source members during review preparation.
-- The exact bytes are retained in the private review; apply never reopens the
-- source file. Sources must resolve within the immutable platform workspace.
module Nagare.Inventory.KubernetesSources (loadKubernetesSources, validateSuppliedKubernetesMembers) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.BackendMap (renderBackendMapNative)
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

-- | Generated members enter the planner directly. Rebind their exact bytes so
-- a caller cannot pair a valid declaration with different native content.
validateSuppliedKubernetesMembers
  :: [ManagedResource]
  -> Map ResourceId (ManagedResource, BS.ByteString)
  -> Either Text ()
validateSuppliedKubernetesMembers declarations supplied =
  mapM_ validateOne (Map.toList supplied)
  where
    byId = Map.fromList [(resource ^. #identity, resource) | resource <- declarations]
    validateOne (resource, (declaration, bytes)) = do
      unless (Map.lookup resource byId == Just declaration)
        (Left "generated native member differs from the composed declaration")
      value <- first T.pack (eitherDecodeStrict' bytes)
      canonical <- canonicalValue value
      unless (canonical == bytes) (Left "generated native member is not canonical")
      cluster <- case declaration ^. #address of
        Kubernetes target _ _ _ _ -> Right target
        _ -> Left "generated native member has no Kubernetes address"
      (recompiled, rebound) <- first (T.pack . show) $ bindKubernetesObject
        KubernetesInput
          { resourceId = resource
          , ownerScope = declaration ^. #owner
          , clusterId = cluster
          , inputObject = value
          , objectDigest = contentDigest bytes
          , lifecyclePolicy = declaration ^. #lifecycle
          , inputDataPolicy = declaration ^. #dataPolicy
          , inputSensitivity = declaration ^. #sensitivity
          , sourceLocation = declaration ^. #source
          }
      let generatedNamespace = declaration ^. #spec == NamespaceSpec Nothing
            && declaration ^. #source . #file == "contribution"
          generatedBackend = case declaration ^. #spec of
            BackendMapSpec _ -> declaration ^. #source . #file == "contribution"
            _ -> False
      when generatedBackend $ case declaration ^. #spec of
        BackendMapSpec entries -> do
          expected <- renderBackendMapNative entries
          unless (expected == bytes) (Left "generated backend map differs from typed contributions")
        _ -> pure ()
      let
          reboundDeclaration = recompiled
            { dependencies = declaration ^. #dependencies
            , spec = if generatedNamespace || generatedBackend
                then declaration ^. #spec else recompiled ^. #spec
            }
      unless (reboundDeclaration == declaration && rebound == bytes)
        (Left "generated native member does not match its typed declaration")
