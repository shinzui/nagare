-- | A single leaf newtype: 'FilePathText', a validated relative project path.
--
-- This lives in its own tiny module — rather than in 'Nagare.Dsl.Static.Types'
-- where it was first defined — so that 'Nagare.Dsl.Build' can reuse it without
-- importing 'Nagare.Dsl.Types'. 'Nagare.Dsl.Static.Types' imports the core leaf
-- newtypes ('Domain'/'ImageRef'/'Namespace') from 'Nagare.Dsl.Types', so if
-- 'FilePathText' stayed there the chain
-- @Types -> Build -> Static.Types -> Types@ would be an import cycle. Hosting
-- 'FilePathText' here, depending on nothing but @text@, breaks that cycle:
-- 'Build' imports only this module, and 'Static.Types' re-exports
-- 'FilePathText' so its existing importers are unaffected.
module Nagare.Dsl.Path
  ( FilePathText
  , mkFilePathText
  , filePathText
  ) where

import Nagare.Dsl.Prelude

import Data.Text qualified as Text

-- | A relative filesystem path inside the project: a build output directory
-- (e.g. @"dist"@), a nested directory (@"build/client"@), a Dockerfile path
-- (@"Dockerfile"@), a build context (@"."@), or a file the site references
-- (@"404.html"@). Constructor hidden; use 'mkFilePathText'.
--
-- Rejects empty paths, absolute paths (a leading @/@), any @..@ path segment,
-- and embedded NUL characters, so a path can never escape the project root or
-- the image build context.
newtype FilePathText = FilePathText Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'FilePathText'.
mkFilePathText :: Text -> Either Text FilePathText
mkFilePathText t
  | Text.null t = Left "path must not be empty"
  | Text.isPrefixOf "/" t = Left ("path must be relative, not absolute: " <> t)
  | "\NUL" `Text.isInfixOf` t = Left ("path must not contain NUL characters: " <> t)
  | ".." `elem` Text.split (== '/') t =
      Left ("path must not contain a '..' segment: " <> t)
  | otherwise = Right (FilePathText t)

filePathText :: FilePathText -> Text
filePathText (FilePathText t) = t
