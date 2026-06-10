-- | The typed build model: /how/ a 'Nagare.Dsl.Types.Deployment' container image
-- is produced.
--
-- A 'Deployment' names a container image by an 'Nagare.Dsl.Types.ImageRef' (a
-- registry repository path with no tag). The 'BuildSpec' here says how the image
-- at that repository comes to exist:
--
--   * 'PrebuiltImage' — it already exists in the registry; deploy the carried
--     'Tag' and build nothing.
--   * 'DockerfileBuild' — build it from a named @Dockerfile@ and build context
--     with @--build-arg@s, then push it under the deploy tag the CLI computes.
--   * 'NixpacksBuild' — build it from source with Nixpacks (no Dockerfile) and
--     push it under the deploy tag. Execution lands in
--     @docs/plans/21-nixpacks-zero-dockerfile-builder.md@ (EP-21); this module
--     only defines the type and its marshalling contract.
--
-- The two pure helpers 'resolveImageTag' and 'requiresBuild' are shared by the
-- renderer ('Nagare.Dsl.Render') and the CLI (EP-20): the first reconciles a
-- prebuilt image's embedded tag with the CLI-computed deploy tag, and the second
-- says whether the CLI must build and push at all.
--
-- The leaf path fields ('dockerfile', 'context') reuse 'FilePathText' from
-- 'Nagare.Dsl.Path' (also re-exported from 'Nagare.Dsl.Static.Types'), which
-- already rejects empty, absolute, and @..@-escaping paths — exactly the
-- validation a build context and Dockerfile path want.
module Nagare.Dsl.Build
  ( -- * Tag
    Tag
  , mkTag
  , tagText

    -- * BuildSpec
  , BuildSpec (..)

    -- * Helpers
  , resolveImageTag
  , requiresBuild
  , defaultBuild
  ) where

import Nagare.Dsl.Prelude

import Data.Char (isSpace)
import Data.Map (Map)
import Data.Text qualified as Text
import Nagare.Dsl.Path (FilePathText, mkFilePathText)

-- | A Docker image tag, e.g. @"v1.2.3"@ or @"20260609-000000"@. The constructor
-- is hidden; use 'mkTag'. Digests (@\@sha256:...@) are out of scope.
newtype Tag = Tag Text
  deriving stock (Generic, Eq, Ord, Show)

-- | Validate and construct a 'Tag'. A Docker tag is 1–128 characters from the
-- set @[A-Za-z0-9_.-]@ and may not begin with a @.@ or @-@. Whitespace and any
-- other character are rejected.
mkTag :: Text -> Either Text Tag
mkTag t
  | Text.null t = Left "tag must not be empty"
  | Text.length t > 128 =
      Left ("tag too long (" <> tshow (Text.length t) <> " chars, max 128)")
  | Text.any isSpace t = Left ("tag must not contain whitespace: " <> t)
  | not (Text.all validTagChar t) =
      Left ("tag contains invalid characters (allowed: A-Z, a-z, 0-9, '_', '.', '-'): " <> t)
  | Text.isPrefixOf "." t = Left "tag must not start with a '.'"
  | Text.isPrefixOf "-" t = Left "tag must not start with a '-'"
  | otherwise = Right (Tag t)

tagText :: Tag -> Text
tagText (Tag t) = t

-- | How a 'Nagare.Dsl.Types.Deployment' image is produced. The repository path
-- is always the deployment's 'Nagare.Dsl.Types.ImageRef'; this type only says
-- what (if anything) to build and which tag to deploy.
data BuildSpec
  = -- | Deploy an image that already exists in a registry. Carries the tag to
    -- deploy; nothing is built or pushed. The full reference is
    -- @imageRef:tag@.
    PrebuiltImage Tag
  | -- | Build from a Dockerfile and push to the deployment's 'ImageRef'.
    DockerfileBuild
      { dockerfile :: !FilePathText
      , context :: !FilePathText
      , buildArgs :: !(Map Text Text)
      }
  | -- | Build from source with Nixpacks (no Dockerfile) and push to the
    -- deployment's 'ImageRef'. Execution lands in EP-21.
    NixpacksBuild
      { context :: !FilePathText
      , buildArgs :: !(Map Text Text)
      }
  deriving stock (Generic, Eq, Show)

-- | The tag to deploy: a prebuilt image carries its own; built images use the
-- deploy tag computed by the CLI.
resolveImageTag :: BuildSpec -> Text -> Text
resolveImageTag (PrebuiltImage t) _ = tagText t
resolveImageTag _ deployTag = deployTag

-- | Whether the CLI must build and push an image. 'False' only for
-- 'PrebuiltImage'.
requiresBuild :: BuildSpec -> Bool
requiresBuild (PrebuiltImage _) = False
requiresBuild _ = True

-- | The default build mode, reproducing Nagare's historical behavior:
-- @docker build -f Dockerfile .@ with no build arguments. Used by the
-- 'Nagare.Dsl.Presets.webService' preset and by example configs that want the
-- pre-'BuildSpec' default.
defaultBuild :: Either Text BuildSpec
defaultBuild = do
  df <- mkFilePathText "Dockerfile"
  ctx <- mkFilePathText "."
  pure (DockerfileBuild {dockerfile = df, context = ctx, buildArgs = mempty})

-- Internal: show a value as Text for error messages.
tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- Internal: a valid Docker tag character.
validTagChar :: Char -> Bool
validTagChar c =
  (c >= 'A' && c <= 'Z')
    || (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9')
    || c == '_'
    || c == '.'
    || c == '-'
