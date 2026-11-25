-- | A workload's binding to a signing key set (EP-286), apart from the key
-- set document so the workload records can hold it.
module Nagare.Dsl.KeySet.Binding
  ( KeySetName
  , mkKeySetName
  , keySetNameText
  , KeySetUse (..)
  , keySetUseToken
  , parseKeySetUse
  , KeySetBinding (..)
  , keySetEnvPrefix
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Nagare.Dsl.Prelude

-- | A DNS label of at most 30 characters that starts with a letter, so the
-- Secret @nagare-keyset-\<name\>@ and the ConfigMap
-- @nagare-keyset-\<name\>-public@ are valid object names. Constructor hidden;
-- use 'mkKeySetName'.
newtype KeySetName = KeySetName Text
  deriving stock (Eq, Ord, Show)

mkKeySetName :: Text -> Either Text KeySetName
mkKeySetName t
  | Text.null t || Text.length t > 30 = Left ("key set name must have 1 to 30 characters: " <> t)
  | not (isAsciiLower (Text.head t)) = Left ("key set name must start with a lower-case letter: " <> t)
  | Text.last t == '-' = Left ("key set name must not end with -: " <> t)
  | not (Text.all (\c -> isAsciiLower c || isDigit c || c == '-') t) = Left ("key set name must be lower-case letters, digits and -: " <> t)
  | otherwise = Right (KeySetName t)

keySetNameText :: KeySetName -> Text
keySetNameText (KeySetName t) = t

-- | A signer reads the private keys and the public ones; a verifier only the
-- public ones.
data KeySetUse = Sign | Verify
  deriving stock (Generic, Eq, Ord, Show)

keySetUseToken :: KeySetUse -> Text
keySetUseToken = \case
  Sign -> "sign"
  Verify -> "verify"

parseKeySetUse :: Text -> Maybe KeySetUse
parseKeySetUse = \case
  "sign" -> Just Sign
  "verify" -> Just Verify
  _ -> Nothing

data KeySetBinding = KeySetBinding
  { name :: !KeySetName
  , use :: !KeySetUse
  }
  deriving stock (Generic, Eq, Show)

-- | The prefix of a bound workload's variable: @NAGARE_KEYSET_@, then the
-- key set name upper-cased with @-@ as @_@.
keySetEnvPrefix :: KeySetName -> Text
keySetEnvPrefix name' = "NAGARE_KEYSET_" <> Text.toUpper (Text.replace "-" "_" (keySetNameText name'))
