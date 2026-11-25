-- | Files the platform mounts into a workload (EP-283 M1).
--
-- A 'PlatformMount' is not part of the user's typed surface or of the JSON
-- wire format. An inventory compiler adds it to a workload's manifest after
-- rendering, so a workload with no platform mount keeps the bytes it had.
module Nagare.Dsl.Mounts
  ( MountSource (..)
  , PlatformMount (..)
  , tokenFileName
  , mountVolume
  , mountVolumeMount
  , withPlatformMounts
  , applyPlatformMounts
  )
where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable qualified as Foldable
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Render (knativeConfig)
import Nagare.Dsl.Task.Render (encodeCronJob)
import Nagare.Dsl.Worker.Render (workerConfig)

-- | One source of files in a mount. A ConfigMap or a Secret contributes one
-- file per key. A service-account token contributes the file 'tokenFileName',
-- issued for the audience and renewed by the kubelet before the expiry.
data MountSource
  = ConfigMapSource !Text
  | SecretSource !Text
  | -- | Audience, then expiry in seconds.
    ServiceAccountTokenSource !Text !Int
  deriving stock (Generic, Eq, Show)

-- | A read-only directory the platform mounts into every container of a
-- workload, rendered as one projected volume.
data PlatformMount = PlatformMount
  { volume :: !Text
  , mountPath :: !Text
  , sources :: !(NonEmpty MountSource)
  }
  deriving stock (Generic, Eq, Show)

-- | The file a 'ServiceAccountTokenSource' writes under the mount path.
tokenFileName :: Text
tokenFileName = "token"

-- | The Pod @volumes@ entry of a mount.
mountVolume :: PlatformMount -> Value
mountVolume mount =
  object
    [ "name" .= (mount ^. #volume)
    , "projected" .= object ["sources" .= map sourceValue (NE.toList (mount ^. #sources))]
    ]
  where
    sourceValue = \case
      ConfigMapSource name -> object ["configMap" .= object ["name" .= name]]
      SecretSource name -> object ["secret" .= object ["name" .= name]]
      ServiceAccountTokenSource audience seconds ->
        object
          [ "serviceAccountToken"
              .= object
                [ "audience" .= audience
                , "expirationSeconds" .= seconds
                , "path" .= tokenFileName
                ]
          ]

-- | The container @volumeMounts@ entry of a mount.
mountVolumeMount :: PlatformMount -> Value
mountVolumeMount mount =
  object
    [ "name" .= (mount ^. #volume)
    , "mountPath" .= (mount ^. #mountPath)
    , "readOnly" .= True
    ]

-- | Add the mounts to a rendered Knative Service, Deployment or CronJob: each
-- as a Pod volume and as a read-only mount in every container. Refuses any
-- other kind, and a volume name or mount path the workload already uses.
withPlatformMounts :: [PlatformMount] -> Value -> Either Text Value
withPlatformMounts [] manifest = Right manifest
withPlatformMounts mounts manifest = do
  path <- podSpecPath manifest
  overPath path addToPod manifest
  where
    addToPod = \case
      Object pod -> do
        let existing = entries "volumes" pod
        refuseClash "volume" "name" (map (^. #volume) mounts) existing
        containers <- traverse addToContainer (entries "containers" pod)
        when (null containers) (Left "the workload has no container to mount files into")
        pure
          ( Object
              ( KM.insert "containers" (toJSON containers) $
                  KM.insert "volumes" (toJSON (existing <> map mountVolume mounts)) pod
              )
          )
      _ -> Left "the workload's Pod spec is not an object"
    addToContainer = \case
      Object container -> do
        let existing = entries "volumeMounts" container
        refuseClash "mount path" "mountPath" (map (^. #mountPath) mounts) existing
        pure (Object (KM.insert "volumeMounts" (toJSON (existing <> map mountVolumeMount mounts)) container))
      _ -> Left "a workload container is not an object"
    entries key parent = case KM.lookup key parent of
      Just (Array values) -> Foldable.toList values
      _ -> []
    refuseClash what key wanted existing =
      case [name | name <- wanted, name `elem` taken] <> duplicates wanted of
        [] -> Right ()
        name : _ -> Left ("platform " <> what <> " " <> name <> " is already used by the workload")
      where
        taken = [name | Object entry <- existing, Just (String name) <- [KM.lookup key entry]]
    duplicates values = [value | (index, value) <- zip [0 :: Int ..] values, value `elem` take index values]

-- | 'withPlatformMounts' on rendered bytes, encoded as the kind's own renderer
-- encodes it. With no mount the bytes are returned as they are.
applyPlatformMounts :: [PlatformMount] -> ByteString -> Either Text ByteString
applyPlatformMounts [] bytes = Right bytes
applyPlatformMounts mounts bytes = do
  manifest <- first (Text.pack . Yaml.prettyPrintParseException) (Yaml.decodeEither' bytes)
  mounted <- withPlatformMounts mounts manifest
  encode <- encoderFor manifest
  pure (encode mounted)
  where
    encoderFor manifest = case kindOf manifest of
      Just "Service" -> Right (YP.encodePretty knativeConfig)
      Just "Deployment" -> Right (YP.encodePretty workerConfig)
      Just "CronJob" -> Right encodeCronJob
      other -> Left (unsupported other)

podSpecPath :: Value -> Either Text [Text]
podSpecPath manifest = case kindOf manifest of
  Just "Service" -> Right ["spec", "template", "spec"]
  Just "Deployment" -> Right ["spec", "template", "spec"]
  Just "CronJob" -> Right ["spec", "jobTemplate", "spec", "template", "spec"]
  other -> Left (unsupported other)

unsupported :: Maybe Text -> Text
unsupported kind = "platform mounts are not supported on kind " <> fromMaybe "(none)" kind

kindOf :: Value -> Maybe Text
kindOf = \case
  Object manifest | Just (String kind) <- KM.lookup "kind" manifest -> Just kind
  _ -> Nothing

overPath :: [Text] -> (Value -> Either Text Value) -> Value -> Either Text Value
overPath [] change value = change value
overPath (key : rest) change value = case value of
  Object parent | Just child <- KM.lookup (Key.fromText key) parent -> do
    changed <- overPath rest change child
    pure (Object (KM.insert (Key.fromText key) changed parent))
  _ -> Left ("the workload manifest has no " <> key)
