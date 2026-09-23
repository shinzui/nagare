module Nagare.Inventory.BackendMap
  ( renderBackendMapObject
  , renderBackendMapNative
  , compileContributedBackendMaps
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types (Name, ProviderAddress (..), ResourceId, nameText)
import Nagare.Resource.Wire (canonicalValue)

renderBackendMapNative :: [(Name, Text, BackendRole)] -> Either Text ByteString
renderBackendMapNative entries = canonicalValue =<< renderBackendMapObject entries

compileContributedBackendMaps ::
  [Declaration] -> Either Text (Map ResourceId (ManagedResource, ByteString))
compileContributedBackendMaps declarations = Map.fromList <$> traverse compileOne contributed
  where
    contributed =
      [ resource
      | Managed resource <- declarations
      , BackendMapSpec _ <- [resource ^. #spec]
      , resource ^. #source . #file == "contribution"
      ]
    compileOne resource = do
      entries <- case resource ^. #spec of
        BackendMapSpec values -> Right values
        _ -> Left "contributed backend map has no typed entries"
      bytes <- renderBackendMapNative entries
      value <- renderBackendMapObject entries
      cluster <- case resource ^. #address of
        Kubernetes target "" kind (Just namespace) name
          | nameText kind == "configmap" && nameText namespace == "nagare-system"
          , nameText name == "nagare-access-backends" ->
              Right target
        _ -> Left "contributed backend map has an unexpected address"
      (compiled, bound) <-
        first
          (T.pack . show)
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resource ^. #identity
                , ownerScope = resource ^. #owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest bytes
                , lifecyclePolicy = resource ^. #lifecycle
                , inputDataPolicy = resource ^. #dataPolicy
                , inputSensitivity = resource ^. #sensitivity
                , sourceLocation = resource ^. #source
                }
          )
      unless
        (compiled ^. #address == resource ^. #address && bound == bytes)
        (Left "contributed backend map native binding changed its address or bytes")
      pure (resource ^. #identity, (resource, bytes))

renderBackendMapObject :: [(Name, Text, BackendRole)] -> Either Text Value
renderBackendMapObject entries = do
  let hosts = map (nameText . first3) entries
      portals = [() | (_, _, PortalBackend) <- entries]
  if length hosts /= Map.size (Map.fromList [(host, ()) | host <- hosts])
    then Left "backend map repeats a public host"
    else pure ()
  if length portals > 1 then Left "backend map has more than one portal" else pure ()
  if any
    ( \(_, upstream, _) ->
        not
          ( "http://" `T.isPrefixOf` upstream
              || "https://" `T.isPrefixOf` upstream
          )
    )
    entries
    then Left "backend map contains a non-HTTP upstream"
    else pure ()
  encoded <-
    canonicalValue
      ( object
          [Key.fromText (nameText host) .= backendEntry upstream role | (host, upstream, role) <- entries]
      )
  -- The full native object is canonicalized by the caller. The JSON string is
  -- itself canonical, so contributor ordering never changes the desired digest.
  pure
    ( object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata"
            .= object
              [ "name" .= ("nagare-access-backends" :: Text)
              , "namespace" .= ("nagare-system" :: Text)
              , "labels"
                  .= object
                    [ "app.kubernetes.io/name" .= ("nagare-access" :: Text)
                    , "app.kubernetes.io/part-of" .= ("nagare-auth-plane" :: Text)
                    , "nagare.dev/managed-by" .= ("nagarectl" :: Text)
                    ]
              ]
        , "data" .= object ["backends.json" .= TE.decodeUtf8 encoded]
        ]
    )
  where
    first3 (value, _, _) = value
    backendEntry upstream ProtectedBackend = String upstream
    backendEntry upstream PortalBackend =
      object
        ["upstream" .= upstream, "role" .= ("portal" :: Text)]
