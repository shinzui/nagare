-- | What a workload's key set bindings put into it (EP-286): one read-only
-- directory per key set at @/var/run/nagare/keysets/NAME/@, and the
-- variable @NAGARE_KEYSET_NAME_DIR@ naming it. A signer's directory holds
-- @public.json@ and @private.json@; a verifier's only @public.json@, so a
-- verifier's manifest never names the key set's Secret (ADR 38).
module Nagare.Dsl.KeySet.Mount
  ( keySetSecretName
  , keySetPublicName
  , keySetMountPath
  , keySetMounts
  , keySetEnv
  )
where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Nagare.Dsl.KeySet.Binding
import Nagare.Dsl.Mounts (MountSource (..), PlatformMount (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (EnvName, EnvVar (EnvLiteral), ScopedEnvVar, mkEnvName, runtimeScoped)

-- | The Secret that holds the private file.
keySetSecretName :: KeySetName -> Text
keySetSecretName name = "nagare-keyset-" <> keySetNameText name

-- | The ConfigMap that holds the public file and the reviewed policy.
keySetPublicName :: KeySetName -> Text
keySetPublicName name = keySetSecretName name <> "-public"

keySetMountPath :: KeySetName -> Text
keySetMountPath name = "/var/run/nagare/keysets/" <> keySetNameText name

keySetMounts :: [KeySetBinding] -> [PlatformMount]
keySetMounts = map mount
  where
    mount binding =
      let name = binding ^. #name
          public = ConfigMapSource (keySetPublicName name)
       in PlatformMount
            { volume = "keyset-" <> keySetNameText name
            , mountPath = keySetMountPath name
            , sources = case binding ^. #use of
                Sign -> public :| [SecretSource (keySetSecretName name)]
                Verify -> public :| []
            }

keySetEnv :: [KeySetBinding] -> Either Text (Map EnvName ScopedEnvVar)
keySetEnv bindings =
  Map.fromList
    <$> traverse
      (\binding -> (,runtimeScoped (EnvLiteral (keySetMountPath (binding ^. #name)))) <$> mkEnvName (keySetEnvPrefix (binding ^. #name) <> "_DIR"))
      bindings
