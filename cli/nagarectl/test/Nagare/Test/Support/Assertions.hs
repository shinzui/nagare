-- | Support.Assertions responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Assertions
  ( assertBefore
  , assertInfix
  , assertInfixStr
  , assertLeftText
  , single
  , unsafe
  , unsafeS
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((<.>))
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure)

-- | Assert needle @a@ appears before needle @b@ in @hay@.
assertBefore :: ByteString -> ByteString -> ByteString -> Assertion
assertBefore a b hay =
  assertBool
    (show a <> " must appear before " <> show b)
    (idx a < idx b)
  where
    idx n = BS.length (fst (BS.breakSubstring n hay))

assertInfix :: ByteString -> ByteString -> Assertion
assertInfix needle hay
  | needle `BC.isInfixOf` hay = pure ()
  | otherwise =
      assertFailure ("expected " <> show needle <> " in:\n" <> BC.unpack hay)

assertInfixStr :: String -> FilePath -> Assertion
assertInfixStr needle hay
  | T.pack needle `T.isInfixOf` T.pack hay = pure ()
  | otherwise = assertFailure ("expected " <> show needle <> " in path: " <> hay)

assertLeftText :: Either Text a -> Assertion
assertLeftText (Left _) = pure ()
assertLeftText (Right _) = assertFailure "expected Left, got Right"

unsafeS :: Either Text a -> a
unsafeS (Right a) = a
unsafeS (Left e) = error ("test fixture invalid: " <> T.unpack e)

unsafe :: Either Text a -> a
unsafe (Right a) = a
unsafe (Left e) = error ("test fixture invalid: " <> T.unpack e)

-- | The single element a fixture expression must produce. Anything else is a
-- broken fixture, reported with the count, instead of an incomplete pattern.
single :: [a] -> a
single = \case
  [x] -> x
  xs -> error ("fixture: expected exactly one element, got " <> show (length xs))
