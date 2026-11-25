-- | The digest-pinned image reference an operator hands to a release or a
-- deploy: a qualified repository, then @\@sha256:@ and a manifest digest.
module Nagare.Target.ImageReference
  ( parseImageDigestReference
  )
where

import Data.Char (isAsciiLower)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Types qualified as Resource

parseImageDigestReference :: Text -> Either Text (Text, Resource.ContentDigest)
parseImageDigestReference reference = case T.splitOn "@sha256:" reference of
  [repository, digest] | validRepository repository -> (repository,) <$> Resource.mkContentDigest digest
  _ -> Left "image reference must be a qualified repository followed by @sha256 and a manifest digest"
  where
    validRepository repository =
      T.length repository <= 512 && case T.splitOn "/" repository of
        host : path@(_ : _) -> validHost host && all component path
        _ -> False
    validHost host = case T.splitOn ":" host of
      [name] -> all component (T.splitOn "." name)
      [name, port] -> all component (T.splitOn "." name) && validPort port
      _ -> False
    validPort port =
      not (T.null port)
        && T.length port <= 5
        && T.all digit port
        && let value = read (T.unpack port) :: Int in value > 0 && value <= 65535
    digit c = c >= '0' && c <= '9'
    alphanumeric c = isAsciiLower c || digit c
    component name =
      not (T.null name)
        && alphanumeric (T.head name)
        && alphanumeric (T.last name)
        && T.all (\c -> alphanumeric c || c `elem` ("._-" :: String)) name
