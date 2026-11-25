-- | The rotation of a signing key set (EP-286), as a pure step.
--
-- A key set has three slots. @next@ is published a whole period before it
-- signs, @active@ signs, and @previous@ is still published for the overlap
-- after it stopped signing. Verifiers accept every published key; signers use
-- @active@. So a verifier whose file is one rotation behind or ahead of the
-- signer's still knows the signer's key, whatever order pods restart or files
-- refresh in.
--
-- 'rotateStep' is the whole policy. The rotator runs it every few minutes
-- with fresh key material and writes the result only when it changed; running
-- it twice at the same instant changes nothing.
module Nagare.KeySet
  ( KeyPair (..)
  , PublishedKey (..)
  , KeyStatus (..)
  , KeySetState (..)
  , Activation (..)
  , RotationEvent (..)
  , emptyKeySet
  , rotateStep
  , publishedKeys
  , keyStatus
  , historyLimit
  , promotionNotice
  , encodePublicKeySet
  , encodePrivateKeySet
  , decodeKeySet
  )
where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Nagare.Dsl.KeySet (RotationPolicy, minutesInt)
import Nagare.Dsl.Prelude hiding ((.=))

-- | Fresh key material: the raw 32-byte Ed25519 public key and seed.
data KeyPair = KeyPair
  { public :: !ByteString
  , secret :: !ByteString
  }
  deriving stock (Generic, Eq, Show)

-- | One key of the set, with its private seed.
data PublishedKey = PublishedKey
  { kid :: !Text
  , key :: !KeyPair
  , publishedAt :: !UTCTime
  , activatedAt :: !(Maybe UTCTime)
  , supersededAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

data KeyStatus = NextKey | ActiveKey | PreviousKey
  deriving stock (Generic, Eq, Ord, Show)

-- | One activation of a key, the newest first in the history.
data Activation = Activation
  { kid :: !Text
  , at :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data KeySetState = KeySetState
  { next :: !(Maybe PublishedKey)
  , active :: !(Maybe PublishedKey)
  , previous :: !(Maybe PublishedKey)
  , serial :: !Int
  -- ^ the number of keys ever generated; the next key is @k\<serial + 1\>@
  , history :: ![Activation]
  -- ^ at most 'historyLimit' activations, newest first
  }
  deriving stock (Generic, Eq, Show)

data RotationEvent
  = Generated !Text
  | Activated !Text
  | Superseded !Text
  | Withdrawn !Text
  deriving stock (Generic, Eq, Show)

emptyKeySet :: KeySetState
emptyKeySet = KeySetState Nothing Nothing Nothing 0 []

historyLimit :: Int
historyLimit = 20

-- | A key published as @next@ for less than this is not promoted, so even a
-- verifier that refreshes its file late has seen it before it signs.
promotionNotice :: NominalDiffTime
promotionNotice = 5 * 60

-- | One step at @now@. In order: withdraw @previous@ once its overlap has
-- passed; create @active@ and @next@ for an empty set; promote @next@ once
-- @active@ has served a period, @next@ has been published for the notice
-- and @previous@ is gone. It takes fresh keys from the list and uses at most
-- two; a step that would need a key it was not given leaves that part
-- undone.
rotateStep :: UTCTime -> RotationPolicy -> [KeyPair] -> KeySetState -> (KeySetState, [RotationEvent])
rotateStep now policy fresh state0 =
  let (state1, withdrawn) = withdraw state0
      (state2, created, fresh') = create state1 fresh
      (state3, promoted) = promote state2 fresh'
   in (state3, withdrawn <> created <> promoted)
  where
    overlap = minutes (policy ^. #overlap)
    period = minutes (policy ^. #period)
    minutes = fromIntegral . (* 60) . minutesInt
    withdraw state = case state ^. #previous of
      Just old
        | Just stopped <- old ^. #supersededAt
        , addUTCTime overlap stopped <= now ->
            (state & #previous .~ Nothing, [Withdrawn (old ^. #kid)])
      _ -> (state, [])
    create state keys = case (state ^. #active, keys) of
      (Nothing, signing : waiting : rest) ->
        let first' = generated state signing
            second' = generated (state & #serial +~ 1) waiting
         in ( state
                & #active
                ?~ (first' & #activatedAt ?~ now)
                & #next
                ?~ second'
                & #serial
                +~ 2
                & #history
                %~ record (first' ^. #kid)
            , [Generated (first' ^. #kid), Generated (second' ^. #kid), Activated (first' ^. #kid)]
            , rest
            )
      _ -> (state, [], keys)
    promote state keys = case (state ^. #active, state ^. #next, state ^. #previous, keys) of
      (Just current, Just waiting, Nothing, replacement : _)
        | maybe False (\since -> addUTCTime period since <= now) (current ^. #activatedAt)
        , addUTCTime promotionNotice (waiting ^. #publishedAt) <= now ->
            let fresh'' = generated state replacement
             in ( state
                    & #previous
                    ?~ (current & #supersededAt ?~ now)
                    & #active
                    ?~ (waiting & #activatedAt ?~ now)
                    & #next
                    ?~ fresh''
                    & #serial
                    +~ 1
                    & #history
                    %~ record (waiting ^. #kid)
                , [Superseded (current ^. #kid), Activated (waiting ^. #kid), Generated (fresh'' ^. #kid)]
                )
      _ -> (state, [])
    generated state pair = PublishedKey ("k" <> T.show (state ^. #serial + 1)) pair now Nothing Nothing
    record kid' = take historyLimit . (Activation kid' now :)

-- | Every published key with its status: @next@, @active@, @previous@.
publishedKeys :: KeySetState -> [(KeyStatus, PublishedKey)]
publishedKeys state =
  catMaybes [(NextKey,) <$> state ^. #next, (ActiveKey,) <$> state ^. #active, (PreviousKey,) <$> state ^. #previous]

keyStatus :: KeyStatus -> Text
keyStatus = \case
  NextKey -> "next"
  ActiveKey -> "active"
  PreviousKey -> "previous"

-- | The file a verifier reads: a JWK Set of RFC 8037 keys with their status
-- and times, the policy and the history. It holds no private key.
encodePublicKeySet :: RotationPolicy -> KeySetState -> LBS.ByteString
encodePublicKeySet = encodeWith False

-- | The file a signer reads: the public file with each key's private @d@.
-- It alone reproduces the whole state ('decodeKeySet').
encodePrivateKeySet :: RotationPolicy -> KeySetState -> LBS.ByteString
encodePrivateKeySet = encodeWith True

encodeWith :: Bool -> RotationPolicy -> KeySetState -> LBS.ByteString
encodeWith private policy state =
  Aeson.encode
    ( object
        [ "keys" .= [jwk status published | (status, published) <- publishedKeys state]
        , "policy" .= object ["periodMinutes" .= minutesInt (policy ^. #period), "overlapMinutes" .= minutesInt (policy ^. #overlap)]
        , "serial" .= (state ^. #serial)
        , "history" .= [object ["kid" .= (entry ^. #kid), "at" .= (entry ^. #at)] | entry <- state ^. #history]
        ]
    )
  where
    jwk status published =
      object
        ( [ "kty" .= ("OKP" :: Text)
          , "crv" .= ("Ed25519" :: Text)
          , "use" .= ("sig" :: Text)
          , "alg" .= ("EdDSA" :: Text)
          , "kid" .= (published ^. #kid)
          , "x" .= base64Url (published ^. #key . #public)
          , "status" .= keyStatus status
          , "publishedAt" .= (published ^. #publishedAt)
          ]
            <> maybe [] (\time -> ["activatedAt" .= time]) (published ^. #activatedAt)
            <> maybe [] (\time -> ["supersededAt" .= time]) (published ^. #supersededAt)
            <> ["d" .= base64Url (published ^. #key . #secret) | private]
        )

-- | The state a private file holds. A public file is refused: it has no
-- seeds, so it cannot sign.
decodeKeySet :: ByteString -> Either Text KeySetState
decodeKeySet bytes = do
  value <- first T.pack (Aeson.eitherDecodeStrict bytes :: Either String Value)
  first T.pack (parseEither parser value)
  where
    parser = withObject "key set" $ \o -> do
      keys <- o .: "keys" >>= traverse parseKey
      serial' <- o .: "serial"
      history' <- o .: "history" >>= traverse (withObject "activation" (\entry -> Activation <$> entry .: "kid" <*> entry .: "at"))
      let slot status = case [published | (status', published) <- keys, status' == status] of
            [] -> pure Nothing
            [published] -> pure (Just published)
            _ -> fail ("key set has more than one " <> T.unpack (keyStatus status) <> " key")
      next' <- slot NextKey
      active' <- slot ActiveKey
      previous' <- slot PreviousKey
      pure (KeySetState next' active' previous' serial' history')
    parseKey :: Value -> Parser (KeyStatus, PublishedKey)
    parseKey = withObject "key" $ \o -> do
      status <-
        o .: "status" >>= \case
          ("next" :: Text) -> pure NextKey
          "active" -> pure ActiveKey
          "previous" -> pure PreviousKey
          other -> fail ("unknown key status " <> T.unpack other)
      public' <- o .: "x" >>= decodeBase64Url
      secret' <- o .:? "d" >>= maybe (fail "a key has no private part; decode the private file") decodeBase64Url
      published <- PublishedKey <$> o .: "kid" <*> pure (KeyPair public' secret') <*> o .: "publishedAt" <*> o .:? "activatedAt" <*> o .:? "supersededAt"
      pure (status, published)
    decodeBase64Url :: Text -> Parser ByteString
    decodeBase64Url text = either fail pure (convertFromBase Base64URLUnpadded (TE.encodeUtf8 text))

base64Url :: ByteString -> Text
base64Url = TE.decodeUtf8 . convertToBase Base64URLUnpadded
