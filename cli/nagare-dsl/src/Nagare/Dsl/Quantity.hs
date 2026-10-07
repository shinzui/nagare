-- | The form in which the Kubernetes API server stores a resource quantity
-- (RES-4 U7). A quantity Nagare declares is emitted in this form, and one it
-- observes is compared in it, so a non-canonical spelling never reads as
-- drift.
--
-- The evidence is experiment E15
-- (@docs/audits/k8s-semantics-2026-10-06/experiments/e15.out@; k3s v1.34.6,
-- values written through a ResourceQuota's @spec.hard@ and a PVC's
-- @spec.resources.requests@, which stored the same string for every value),
-- and RES-4 E11. The mechanism is
-- @k8s.io/apimachinery@ v0.32.3, @pkg/api/resource@:
--
-- * Parsing (@quantity.go@ 277, @ParseQuantity@) keeps the suffix family
--   (binary @Ki@–@Ei@, decimal @n u m k M G T P E@ or none, or an @e@
--   exponent). On its int64 fast path it also keeps the text as written when
--   that text is already final. That is the case for a decimal whose scale is
--   a multiple of three and whose digits neither end in @000@ nor start with
--   @0@, and for a whole binary value, under a suffix that is a multiple of
--   @Ki@, which eight does not divide. So @1500e0@ is stored as @1500e0@.
-- * A resource list's values are rounded up to milli on admission (E15:
--   @0.1m@ and @100u@ are stored as @1m@). Rounding (@quantity.go@ 581,
--   @RoundUp@) drops the kept text only when the value had digits below milli.
-- * Otherwise the stored text is canonical (@quantity.go@ 424,
--   @CanonicalizeBytes@). Zero is @0@. A binary value is decimal when its
--   magnitude is below 1024 or it is not whole; otherwise every factor of 1024
--   moves into the suffix (@amount.go@ 286). A decimal value moves every factor
--   of ten into its exponent, then lowers the exponent to a multiple of three
--   (@amount.go@ 257). The suffix comes from that exponent (@suffix.go@ 108),
--   or is @e@ and the exponent in the exponent family.
module Nagare.Dsl.Quantity (canonicalQuantity) where

import Data.Bits ((.&.))
import Data.Char (isDigit)
import Data.List (find)
import Data.Ratio (denominator, numerator)
import Data.Text qualified as Text
import Nagare.Dsl.Prelude

data Family = Binary | DecimalSI | DecimalExponent
  deriving stock (Eq, Show)

-- | A parsed quantity: its sign, the digits before and after the point, its
-- suffix family and the power of the suffix's base (two for binary, ten
-- otherwise).
data Parsed = Parsed
  { negative :: !Bool
  , whole :: !Text
  , fraction :: !Text
  , family :: !Family
  , power :: !Integer
  }

-- | The text the API server stores for a well-formed quantity in a resource
-- list, or 'Nothing' when it is malformed or has no suffix the server can
-- write.
canonicalQuantity :: Text -> Maybe Text
canonicalQuantity text
  | text == "0" = Just "0"
  | otherwise = do
      parsed <- parseQuantity text
      let value = valueOf parsed
          sign = if negative parsed then -1 else 1
      if keptAsWritten parsed && scaleOf parsed >= -3
        then Just text
        else canonical (sign * roundUpToMilli value) (if family parsed == Binary && value < 1 then DecimalSI else family parsed)

parseQuantity :: Text -> Maybe Parsed
parseQuantity text = do
  let (isNegative, unsigned) = case Text.uncons text of
        Just ('-', rest) -> (True, rest)
        Just ('+', rest) -> (False, rest)
        _ -> (False, text)
      (wholeDigits, afterWhole) = Text.span isDigit unsigned
      (fractionDigits, suffix) = case Text.uncons afterWhole of
        Just ('.', rest) -> Text.span isDigit rest
        _ -> ("", afterWhole)
  guard (not (Text.null wholeDigits && Text.null fractionDigits))
  (suffixFamily, suffixPower) <- suffixOf suffix
  pure (Parsed isNegative wholeDigits fractionDigits suffixFamily suffixPower)

suffixOf :: Text -> Maybe (Family, Integer)
suffixOf suffix
  | Just multiple <- lookup suffix binarySuffixes = Just (Binary, 10 * multiple)
  | Just tens <- lookup suffix decimalSuffixes = Just (DecimalSI, tens)
  | Just (marker, rest) <- Text.uncons suffix
  , marker `elem` ['e', 'E']
  , Just tens <- signedInteger rest =
      Just (DecimalExponent, tens)
  | otherwise = Nothing
  where
    signedInteger digits = case Text.uncons digits of
      Just ('-', rest) -> negate <$> unsigned rest
      Just ('+', rest) -> unsigned rest
      _ -> unsigned digits
    unsigned digits
      | not (Text.null digits) && Text.all isDigit digits = Just (digitsValue digits)
      | otherwise = Nothing

binarySuffixes :: [(Text, Integer)]
binarySuffixes = zip ["Ki", "Mi", "Gi", "Ti", "Pi", "Ei"] [1 ..]

decimalSuffixes :: [(Text, Integer)]
decimalSuffixes = [("n", -9), ("u", -6), ("m", -3), ("", 0), ("k", 3), ("M", 6), ("G", 9), ("T", 12), ("P", 15), ("E", 18)]

-- | The magnitude of a parsed quantity.
valueOf :: Parsed -> Rational
valueOf parsed =
  fromInteger (digitsValue (whole parsed <> fraction parsed))
    / 10 ^ Text.length (fraction parsed)
    * (if family parsed == Binary then 2 ^ power parsed else 10 ^^ power parsed)

-- | The decimal scale of the digits as written; a binary value has none.
scaleOf :: Parsed -> Integer
scaleOf parsed
  | family parsed == Binary = 0
  | otherwise = power parsed - toInteger (Text.length (fraction parsed))

-- | @ParseQuantity@'s int64 fast path, and whether it keeps the text as
-- written.
keptAsWritten :: Parsed -> Bool
keptAsWritten parsed = case family parsed of
  Binary ->
    Text.null (fraction parsed)
      && 15 - digits - (power parsed * 3) `div` 10 - 1 >= 0
      && power parsed `mod` 10 == 0
      && digitsValue shifted .&. 7 /= 0
  _ ->
    18 - digits >= 0
      && scaleOf parsed >= -9
      && scaleOf parsed `mod` 3 == 0
      && not ("000" `Text.isSuffixOf` shifted)
      && Text.take 1 shifted /= "0"
  where
    shifted = whole parsed <> fraction parsed
    digits = toInteger (Text.length shifted)

digitsValue :: Text -> Integer
digitsValue = Text.foldl' (\acc digit -> acc * 10 + toInteger (fromEnum digit - fromEnum '0')) 0

-- | Round a magnitude up to a multiple of 10^-3.
roundUpToMilli :: Rational -> Rational
roundUpToMilli value = fromInteger (ceiling (value * 1000)) / 1000

canonical :: Rational -> Family -> Maybe Text
canonical value valueFamily
  | value == 0 = Just "0"
  | valueFamily == Binary && abs value >= 1024 && denominator value == 1 = binary (numerator value)
  | valueFamily == Binary = decimal DecimalSI
  | otherwise = decimal valueFamily
  where
    binary wholeValue =
      let (mantissa, multiple) = removeFactors 1024 wholeValue
       in if multiple == 0
            then Just (showInteger mantissa)
            else (showInteger mantissa <>) . fst <$> find ((== multiple) . snd) binarySuffixes
    decimal decimalFamily =
      let (stripped, tens) = removeFactors 10 (numerator (value * 1000))
          raised = tens - 3
          lowered = raised - raised `mod` 3
          mantissa = stripped * 10 ^ (raised - lowered)
       in (showInteger mantissa <>) <$> case decimalFamily of
            DecimalExponent -> Just (if lowered == 0 then "" else "e" <> showInteger lowered)
            _ -> fst <$> find ((== lowered) . snd) decimalSuffixes
    showInteger = Text.pack . show

-- | Move every factor of the base out of a nonzero integer, as apimachinery's
-- @removeInt64Factors@ does: only while the magnitude is at least the base.
removeFactors :: Integer -> Integer -> (Integer, Integer)
removeFactors base = go 0
  where
    go times n
      | abs n >= base && n `mod` base == 0 = go (times + 1) (n `div` base)
      | otherwise = (n, times)
