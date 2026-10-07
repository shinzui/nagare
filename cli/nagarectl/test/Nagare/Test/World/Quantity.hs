-- | EP-182: resource quantities as the Kubernetes API server stores them
-- (RES-4 U7, experiments E11 and E15). The fake API server canonicalizes
-- every quantity it is sent, so a value Nagare writes non-canonically reads
-- back changed, as on a real server.
module Nagare.Test.World.Quantity
  ( canonicalize
  , canonicalQuantity
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (listToMaybe)
import Data.Ratio (denominator, numerator, (%))
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | The value under any @requests@, @limits@ or @hard@ map, canonicalized as
-- the API server stores it.
canonicalize :: Value -> Value
canonicalize = go []
  where
    go path = \case
      Object fields -> Object (KM.mapWithKey (\k v -> go (Key.toText k : path) v) fields)
      Array values -> Array (fmap (go path) values)
      String s | quantityPath path -> String (fromMaybe s (canonicalQuantity s))
      other -> other
    quantityPath = \case
      _ : parent : _ -> parent `elem` ["requests", "limits", "hard"]
      _ -> False

-- | Kubernetes' canonical form, as RES-4 E11 and E15 recorded it. The suffix
-- family is kept (binary, decimal SI, or decimal exponent), the value is
-- rounded up to milli precision, and the largest suffix of the family that
-- leaves an integer mantissa is used (@1024Mi@ is @1Gi@, @1000m@ is @1@, @1.5@
-- is @1500m@, @0.1m@ is @1m@, @1500e0@ stays @1500e0@). A binary value that is
-- not a whole number falls back to decimal SI (@1.1Ki@ is @1126400m@).
canonicalQuantity :: Text -> Maybe Text
canonicalQuantity raw = do
  let (number, rest) = T.span (\c -> c `elem` ['0' .. '9'] || c == '.') raw
  amount <- decimalRational number
  (family, scale) <- case T.uncons rest of
    -- An exponent only when a signed integer follows: @1Ei@ is a suffix.
    Just (e, exponent') | e `elem` ['e', 'E'], Just power <- signedInt exponent' -> Just (Exponent, 10 ^^ power)
    _ -> lookup rest suffixes
  let value = roundUpToMilli (amount * scale)
  pure $
    if value == 0
      then "0"
      else case family of
        Exponent -> exponentForm value
        Binary | denominator value == 1 -> largest [(s, f) | (s, (Binary, f)) <- suffixes] value `orPlain` value
        _ -> largest [(s, f) | (s, (Decimal, f)) <- suffixes] value `orPlain` value
  where
    suffixes :: [(Text, (Family, Rational))]
    suffixes =
      [ ("n", (Decimal, 1 % (10 ^ (9 :: Int))))
      , ("u", (Decimal, 1 % (10 ^ (6 :: Int))))
      , ("m", (Decimal, 1 % 1000))
      , ("", (Decimal, 1))
      , ("k", (Decimal, 1000))
      , ("M", (Decimal, 10 ^ (6 :: Int)))
      , ("G", (Decimal, 10 ^ (9 :: Int)))
      , ("T", (Decimal, 10 ^ (12 :: Int)))
      , ("P", (Decimal, 10 ^ (15 :: Int)))
      , ("E", (Decimal, 10 ^ (18 :: Int)))
      , ("Ki", (Binary, 1024))
      , ("Mi", (Binary, 1024 ^ (2 :: Int)))
      , ("Gi", (Binary, 1024 ^ (3 :: Int)))
      , ("Ti", (Binary, 1024 ^ (4 :: Int)))
      , ("Pi", (Binary, 1024 ^ (5 :: Int)))
      , ("Ei", (Binary, 1024 ^ (6 :: Int)))
      ]
    roundUpToMilli value = fromInteger (ceiling (value * 1000)) / 1000
    largest candidates value = listToMaybe [tshow (numerator (value / f)) <> s | (s, f) <- reverse candidates, denominator (value / f) == 1]
    orPlain picked value = fromMaybe (tshow (numerator (value * 1000)) <> "m") picked
    exponentForm value =
      let exponents = [k | k <- [18, 15 .. -3 :: Int], denominator (value / (10 ^^ k)) == 1]
       in case exponents of
            k : _ -> tshow (numerator (value / (10 ^^ k))) <> "e" <> tshow k
            [] -> tshow (numerator (value * 1000)) <> "e-3"
    signedInt text' = case T.uncons text' of
      Just ('-', digits) -> negate <$> unsigned digits
      Just ('+', digits) -> unsigned digits
      _ -> unsigned text'
    unsigned digits
      | not (T.null digits) && T.all (`elem` ['0' .. '9']) digits = Just (read (T.unpack digits) :: Int)
      | otherwise = Nothing
    decimalRational text' = case T.splitOn "." text' of
      [whole] | not (T.null whole) -> Just (fromInteger (read (T.unpack whole)))
      [whole, fraction] | not (T.null fraction) -> Just (fromInteger (read (T.unpack (if T.null whole then "0" else whole))) + fromInteger (read (T.unpack fraction)) % (10 ^ T.length fraction))
      _ -> Nothing

data Family = Binary | Decimal | Exponent
  deriving stock (Eq)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
